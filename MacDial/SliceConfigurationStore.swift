import Foundation

// Main-thread owned. Inject a UserDefaults suite for tests and isolated previews.
// Production creates this store at launch; legacy preferences remain intact
// after migration into the versioned configuration.
final class SliceConfigurationStore {
    static let storageKey = "dialCustomization.configuration"
    static let recoveryPrefix = "dialCustomization.recovery."

    enum LoadStatus: Equatable {
        case loaded
        case migratedLegacy
        case recovered(backupKey: String)
        case unsupportedVersion(Int, backupKey: String)
    }

    private let defaults: UserDefaults
    private(set) var configuration: SliceConfiguration
    private(set) var loadStatus: LoadStatus
    var onChange: ((SliceConfiguration) -> Void)?

    init(defaults: UserDefaults = .standard) throws {
        self.defaults = defaults
        guard let stored = defaults.object(forKey: Self.storageKey) else {
            let migrated = SliceConfiguration.migrating(defaults)
            try migrated.validate()
            let data = try Self.encode(migrated)
            configuration = migrated
            loadStatus = .migratedLegacy
            defaults.set(data, forKey: Self.storageKey)
            return
        }

        do {
            guard let data = stored as? Data else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Expected configuration data"))
            }
            // Read the envelope first: future payload fields may not decode in
            // this version, but must still be recognized as a newer document.
            struct Envelope: Decodable { let version: Int }
            let version = try JSONDecoder().decode(Envelope.self, from: data).version
            guard version == SliceConfiguration.currentVersion else {
                throw ConfigurationError.unsupportedVersion(version)
            }
            let decoded = try JSONDecoder().decode(SliceConfiguration.self, from: data)
            try decoded.validate()
            configuration = decoded
            loadStatus = .loaded
        } catch {
            // Keep the original key untouched until an explicit edit, and keep
            // a recoverable copy even after that edit. Reopening doesn't create
            // repeated backups of identical data.
            let backupKey = Self.backup(stored, in: defaults)
            configuration = SliceConfiguration.migrating(defaults)
            if case ConfigurationError.unsupportedVersion(let version) = error {
                loadStatus = .unsupportedVersion(version, backupKey: backupKey)
            } else {
                loadStatus = .recovered(backupKey: backupKey)
            }
        }
    }

    func replace(with candidate: SliceConfiguration) throws {
        if case .unsupportedVersion = loadStatus { throw ConfigurationError.unsupportedConfigurationIsReadOnly }
        try candidate.validate()
        let data = try Self.encode(candidate)
        if candidate == configuration {
            // Recovery may intentionally replace the invalid original with the
            // in-memory fallback. All ordinary unchanged edits are true no-ops.
            if case .recovered = loadStatus {} else { return }
        }
        // Validate and encode before modifying either in-memory or saved state.
        defaults.set(data, forKey: Self.storageKey)
        configuration = candidate
        loadStatus = .loaded
        onChange?(candidate)
    }

    func edit(_ update: (inout SliceConfiguration) -> Void) throws {
        var candidate = configuration
        update(&candidate)
        try replace(with: candidate)
    }

    @discardableResult
    func select(_ id: SliceID, for bundleIdentifier: String? = nil) throws -> Bool {
        var candidate = configuration
        guard candidate.select(id, for: bundleIdentifier) else { return false }
        try replace(with: candidate)
        return true
    }

    private static func encode(_ configuration: SliceConfiguration) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(configuration)
    }

    private static func backup(_ value: Any, in defaults: UserDefaults) -> String {
        for (key, existing) in defaults.dictionaryRepresentation() where key.hasPrefix(recoveryPrefix) {
            if let object = value as? NSObject, object.isEqual(existing) { return key }
        }
        let key = recoveryPrefix + UUID().uuidString.lowercased()
        defaults.set(value, forKey: key)
        return key
    }
}
