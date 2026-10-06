import Foundation

// Main-queue context backed by the shared customization store. Selection changes
// never modify another context or rewrite the legacy preference keys.
final class AppModeContext {
    let store: SliceConfigurationStore
    private(set) var bundleIdentifier: String?

    init(defaults: UserDefaults = .standard) throws {
        store = try SliceConfigurationStore(defaults: defaults)
    }

    init(store: SliceConfigurationStore) { self.store = store }

    var application: ApplicationConfiguration? {
        store.configuration.applications.first { $0.bundleIdentifier == bundleIdentifier }
    }
    var profile: AppProfile? { AppProfile.matching(application?.bundleIdentifier) }
    var resolvedDial: ResolvedDial { store.configuration.resolved(for: bundleIdentifier) }
    var currentSlice: SliceDefinition? {
        let dial = resolvedDial
        let id = store.configuration.selectedSlice(in: dial)
        return dial.clockwiseSlices.first { $0.id == id }
    }
    var pickerState: ModePickerState {
        ModePickerState(dial: resolvedDial, application: application, selectedSliceID: currentSlice?.id)
    }
    // Built-in compatibility accessors; runtime routes currentSlice, not this fallback.
    var generalMode: Mode {
        let dial = store.configuration.resolved()
        let id = store.configuration.selectedSlice(in: dial)
        return dial.clockwiseSlices.first { $0.id == id }?.builtInMode ?? .scrolling
    }
    var currentMode: Mode { currentSlice?.builtInMode ?? .scrolling }

    func activate(bundleIdentifier: String?) { self.bundleIdentifier = bundleIdentifier }

    @discardableResult
    func selectSlice(_ id: SliceID) -> Bool {
        (try? store.select(id, for: bundleIdentifier)) ?? false
    }

    @discardableResult
    func select(_ mode: Mode) -> Bool { selectSlice(.builtIn(mode)) }
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
