import Foundation

// Identity is independent of a slice's title, icon, position and enabled state.
struct SliceID: RawRepresentable, Hashable, Codable {
    let rawValue: String

    static func builtIn(_ mode: Mode) -> SliceID {
        SliceID(rawValue: "builtin.\(mode.rawValue)")
    }

    static func custom(_ uuid: UUID = UUID()) -> SliceID {
        SliceID(rawValue: "custom.\(uuid.uuidString.lowercased())")
    }

    var isCustom: Bool {
        rawValue.hasPrefix("custom.") && UUID(uuidString: String(rawValue.dropFirst(7))) != nil
    }
}

struct ShortcutModifiers: OptionSet, Codable, Equatable {
    let rawValue: UInt8
    static let command = ShortcutModifiers(rawValue: 1 << 0)
    static let option = ShortcutModifiers(rawValue: 1 << 1)
    static let control = ShortcutModifiers(rawValue: 1 << 2)
    static let shift = ShortcutModifiers(rawValue: 1 << 3)
    static let supported: ShortcutModifiers = [.command, .option, .control, .shift]
}

// Store the physical key rather than a localized character. The recorder will
// supply the display label for the current keyboard layout, not persisted text.
struct KeyboardShortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: ShortcutModifiers = []

    var isValid: Bool {
        // Modifier-only keys, Caps Lock, Fn and media volume keys aren't actions.
        keyCode <= 127 && !(54...63).contains(keyCode) && !(72...74).contains(keyCode)
            && modifiers.subtracting(.supported).isEmpty
    }
}

enum MacOSAction: String, Codable, CaseIterable {
    case brightnessDown, brightnessUp
    case volumeDown, volumeUp, mute
    case playPause, previousTrack, nextTrack
    case keyboardBacklightDown, keyboardBacklightUp, keyboardBacklightToggle
    case missionControl, showDesktop, spotlight

    var title: String {
        switch self {
        case .brightnessDown: return "Brightness Down"
        case .brightnessUp: return "Brightness Up"
        case .volumeDown: return "Volume Down"
        case .volumeUp: return "Volume Up"
        case .mute: return "Mute / Unmute"
        case .playPause: return "Play / Pause"
        case .previousTrack: return "Previous Track"
        case .nextTrack: return "Next Track"
        case .keyboardBacklightDown: return "Keyboard Backlight Down"
        case .keyboardBacklightUp: return "Keyboard Backlight Up"
        case .keyboardBacklightToggle: return "Toggle Keyboard Backlight"
        case .missionControl: return "Mission Control"
        case .showDesktop: return "Show Desktop"
        case .spotlight: return "Spotlight"
        }
    }

    // macOS lets users change these shortcuts. Display the defaults in the UI
    // so customized shortcuts can be assigned via Keyboard Shortcut instead.
    var desktopShortcut: KeyboardShortcut? {
        switch self {
        case .missionControl: return KeyboardShortcut(keyCode: 126, modifiers: [.control])
        case .showDesktop: return KeyboardShortcut(keyCode: 103)
        case .spotlight: return KeyboardShortcut(keyCode: 49, modifiers: [.command])
        default: return nil
        }
    }
}

enum SliceAction: Codable, Equatable {
    case noAction
    case keyboardShortcut(KeyboardShortcut)
    case macOSAction(MacOSAction)
    // Retain decoding of brightness actions saved by version 2.
    case brightnessDown
    case brightnessUp

    var systemAction: MacOSAction? {
        switch self {
        case .macOSAction(let action): return action
        case .brightnessDown: return .brightnessDown
        case .brightnessUp: return .brightnessUp
        default: return nil
        }
    }
}

struct SliceGestures: Codable, Equatable {
    var rotateLeft: SliceAction = .noAction
    var rotateRight: SliceAction = .noAction
    var click: SliceAction = .noAction
    var doubleClick: SliceAction = .noAction

    var actions: [SliceAction] { [rotateLeft, rotateRight, click, doubleClick] }
}

struct CustomSlice: Codable, Equatable {
    static let maximumNameLength = 20

    var name = "New Slice"
    var symbolName = "star"
    var gestures = SliceGestures()
}

enum SliceContent: Codable, Equatable {
    case builtIn(Mode)
    case custom(CustomSlice)
}

struct SliceDefinition: Codable, Equatable, Identifiable {
    let id: SliceID
    var isEnabled: Bool
    var content: SliceContent

    static func builtIn(_ mode: Mode) -> SliceDefinition {
        SliceDefinition(id: .builtIn(mode), isEnabled: true, content: .builtIn(mode))
    }

    static func custom(_ value: CustomSlice = CustomSlice()) -> SliceDefinition {
        SliceDefinition(id: .custom(), isEnabled: true, content: .custom(value))
    }

    var title: String {
        switch content {
        case .builtIn(let mode): return mode.title
        case .custom(let value): return value.name
        }
    }

    var symbolName: String {
        switch content {
        case .builtIn(let mode): return mode.symbolName
        case .custom(let value): return value.symbolName
        }
    }

    var builtInMode: Mode? {
        if case .builtIn(let mode) = content { return mode }
        return nil
    }

    var usageHelp: String? {
        if let mode = builtInMode { return mode.usageHelp }
        return "Custom actions. Hold to choose a slice."
    }
}

struct ApplicationConfiguration: Codable, Equatable, Identifiable {
    var id: String { bundleIdentifier }
    let bundleIdentifier: String
    var displayName: String
    var applicationURL: URL?
    var slices: [SliceDefinition] = []
    // May point to either a standard slice or an action belonging to this app.
    var selectedSliceID: SliceID?
}

enum SliceVisibility: Equatable {
    case displayed
    case disabled
    case overflow
}

// Pure snapshot; contains no event delivery, OS application lookup or UI state.
struct ResolvedDial: Equatable {
    static let capacity = 18
    let bundleIdentifier: String?
    let standardSlices: [SliceDefinition]
    // App actions remain in their priority/list order, not their painted order.
    let applicationSlices: [SliceDefinition]
    let visibility: [SliceID: SliceVisibility]

    var clockwiseSlices: [SliceDefinition] {
        if !standardSlices.isEmpty { return standardSlices + applicationSlices.reversed() }
        guard let first = applicationSlices.first else { return [] }
        // App-only wheel starts on the top-priority item at twelve o'clock.
        return [first] + applicationSlices.dropFirst().reversed()
    }

    var fallbackSelection: SliceID? { (standardSlices.first ?? applicationSlices.first)?.id }
    var actionCount: Int { standardSlices.count + applicationSlices.count }
    // Standard slices have twice the angular weight of application children.
    // App-only and standard-only configurations still fill the entire circle.
    var standardSliceAngle: Double {
        let weight = Double(standardSlices.count) + Double(applicationSlices.count) / 2
        return weight == 0 ? 0 : 360 / weight
    }
    var applicationSliceAngle: Double { standardSliceAngle / 2 }

    func contains(_ id: SliceID) -> Bool { visibility[id] == .displayed }
}

struct SliceConfiguration: Codable, Equatable {
    static let currentVersion = 3
    var version = Self.currentVersion
    var standardSlices: [SliceDefinition]
    var applications: [ApplicationConfiguration]
    var selectedStandardSliceID: SliceID?

    // Pure defaults for previews and compatibility callers; never touches prefs.
    static var builtInDefaults: SliceConfiguration {
        SliceConfiguration(standardSlices: Mode.generalModes.map(SliceDefinition.builtIn),
            applications: [AppProfile.lightroom, .editwall].map {
                ApplicationConfiguration(bundleIdentifier: $0.bundleIdentifier, displayName: $0.title,
                                         slices: $0.modes.map(SliceDefinition.builtIn))
            }, selectedStandardSliceID: .builtIn(.scrolling))
    }

    func hasSameContent(as other: SliceConfiguration) -> Bool {
        var left = self, right = other
        left.selectedStandardSliceID = nil
        right.selectedStandardSliceID = nil
        for index in left.applications.indices { left.applications[index].selectedSliceID = nil }
        for index in right.applications.indices { right.applications[index].selectedSliceID = nil }
        return left == right
    }

    static func migrating(_ defaults: UserDefaults) -> SliceConfiguration {
        let general = Mode.generalModes.first { $0.savedValue == defaults.string(forKey: "mode") } ?? .scrolling
        let apps = [AppProfile.lightroom, .editwall].map { profile -> ApplicationConfiguration in
            let saved = defaults.string(forKey: "appMode.\(profile.bundleIdentifier)")
            let selection = profile.availableModes.first { $0.savedValue == saved }
            return ApplicationConfiguration(bundleIdentifier: profile.bundleIdentifier,
                                            displayName: profile.title,
                                            slices: profile.modes.map(SliceDefinition.builtIn),
                                            selectedSliceID: selection.map(SliceID.builtIn))
        }
        return SliceConfiguration(standardSlices: Mode.generalModes.map(SliceDefinition.builtIn),
                                  applications: apps, selectedStandardSliceID: .builtIn(general))
    }

    func resolved(for bundleIdentifier: String? = nil) -> ResolvedDial {
        let app = applications.first { $0.bundleIdentifier == bundleIdentifier }
        let children = Array((app?.slices ?? []).filter(\.isEnabled).prefix(ResolvedDial.capacity))
        let standard = Array(standardSlices.filter(\.isEnabled).prefix(ResolvedDial.capacity - children.count))
        let displayed = Set((standard + children).map(\.id))
        let visibility = Dictionary(uniqueKeysWithValues: (standardSlices + (app?.slices ?? [])).map {
            ($0.id, !$0.isEnabled ? SliceVisibility.disabled : displayed.contains($0.id) ? .displayed : .overflow)
        })
        return ResolvedDial(bundleIdentifier: app?.bundleIdentifier, standardSlices: standard,
                            applicationSlices: children, visibility: visibility)
    }

    func selectedSlice(in dial: ResolvedDial) -> SliceID? {
        let app = applications.first { $0.bundleIdentifier == dial.bundleIdentifier }
        let remembered = app?.selectedSliceID ?? selectedStandardSliceID
        if let remembered = remembered, dial.contains(remembered) { return remembered }
        return dial.fallbackSelection
    }

    // Selection does not overwrite another application's remembered choice.
    @discardableResult
    mutating func select(_ id: SliceID, for bundleIdentifier: String? = nil) -> Bool {
        let dial = resolved(for: bundleIdentifier)
        guard dial.contains(id) else { return false }
        if let index = applications.firstIndex(where: { $0.bundleIdentifier == dial.bundleIdentifier }) {
            applications[index].selectedSliceID = id
        } else {
            selectedStandardSliceID = id
        }
        return true
    }

    func validate() throws {
        guard version == Self.currentVersion else { throw ConfigurationError.unsupportedVersion(version) }
        var identifiers = Set<SliceID>()
        var bundleIdentifiers = Set<String>()
        func validateSlices(_ slices: [SliceDefinition], allowedBuiltIns: [Mode]) throws {
            for slice in slices {
                guard identifiers.insert(slice.id).inserted else { throw ConfigurationError.duplicateSlice(slice.id) }
                switch slice.content {
                case .builtIn(let mode):
                    guard slice.id == .builtIn(mode), allowedBuiltIns.contains(mode) else {
                        throw ConfigurationError.invalidSlice(slice.id)
                    }
                case .custom(let value):
                    guard slice.id.isCustom, !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          !value.symbolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ConfigurationError.invalidSlice(slice.id)
                    }
                    for action in value.gestures.actions {
                        if case .keyboardShortcut(let shortcut) = action, !shortcut.isValid {
                            throw ConfigurationError.invalidShortcut(slice.id)
                        }
                    }
                }
            }
        }
        try validateSlices(standardSlices, allowedBuiltIns: Mode.generalModes)
        for app in applications {
            guard !app.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !app.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  bundleIdentifiers.insert(app.bundleIdentifier).inserted,
                  app.applicationURL == nil || app.applicationURL?.isFileURL == true else {
                throw ConfigurationError.invalidApplication(app.bundleIdentifier)
            }
            try validateSlices(app.slices, allowedBuiltIns: AppProfile.matching(app.bundleIdentifier)?.modes ?? [])
        }
        // Stale selections are deliberately valid: deletions/overflow fall back
        // at resolution time instead of rejecting the entire saved document.
    }
}

enum ConfigurationError: Error, Equatable {
    case unsupportedVersion(Int)
    case duplicateSlice(SliceID)
    case invalidSlice(SliceID)
    case invalidShortcut(SliceID)
    case invalidApplication(String)
    case unsupportedConfigurationIsReadOnly
}
