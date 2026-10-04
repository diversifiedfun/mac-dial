import Foundation

// Main-queue model. App-specific choices never overwrite the legacy general
// preference, including when a general mode is selected inside an app profile.
final class AppModeContext {
    private let defaults: UserDefaults
    private(set) var profile: AppProfile?

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var generalMode: Mode {
        let saved = Mode(savedValue: defaults.string(forKey: "mode"))
        return Mode.generalModes.contains(saved) ? saved : .scrolling
    }

    var currentMode: Mode {
        guard let profile = profile,
              let saved = defaults.string(forKey: preferenceKey(profile)) else { return generalMode }
        return profile.availableModes.first { $0.savedValue == saved } ?? generalMode
    }

    func activate(bundleIdentifier: String?) {
        profile = AppProfile.matching(bundleIdentifier)
    }

    @discardableResult
    func select(_ mode: Mode) -> Bool {
        guard (profile?.availableModes ?? Mode.generalModes).contains(mode) else { return false }
        defaults.set(mode.savedValue, forKey: profile.map(preferenceKey) ?? "mode")
        return true
    }

    private func preferenceKey(_ profile: AppProfile) -> String {
        "appMode.\(profile.bundleIdentifier)"
    }
}

// The HID callback runs off the main queue. Stamp each report before enqueueing
// it, then reject reports that predate a cancellation or foreground transition.
final class InputContextGate {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var validAfter: TimeInterval = 0

    var token: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    func invalidate(at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        validAfter = timestamp
    }

    func accepts(_ token: UInt64, timestamp: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return token == generation && timestamp >= validAfter
    }
}
