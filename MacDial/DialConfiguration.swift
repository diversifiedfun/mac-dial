import Foundation

enum WheelSensitivity: String, CaseIterable {
    case low, medium, high, extreme

    var normalTicksPerRevolution: Int {
        switch self {
        case .low: return 18
        case .medium: return 36
        case .high: return 72
        case .extreme: return 360
        }
    }

    var menuTicksPerRevolution: Int {
        switch self {
        case .low: return 12
        case .medium: return 18
        case .high: return 24
        case .extreme: return 36
        }
    }
}

struct DialHardwareConfiguration: Equatable {
    let ticksPerRevolution: Int
    let haptics: Bool

    var featureReport: [UInt8] {
        [1, UInt8(ticksPerRevolution & 0xff), UInt8((ticksPerRevolution >> 8) & 0xff),
         0, haptics ? 0x03 : 0x02, 0, 0, 0]
    }
}

// Serializes configuration writes with bounded HID reads. A report retains the
// generation under which it was read, even while waiting on the main queue.
// This owns runtime state only; the status menu owns persisted preferences.
final class DialConfigurationController {
    private let lock = NSRecursiveLock()
    private let apply: (DialHardwareConfiguration) -> Bool
    private var sensitivity: WheelSensitivity = .medium
    private var haptics = false
    private var menuActive = false
    private var connected = false
    private var applied: DialHardwareConfiguration?
    private var generation: UInt64 = 0
    // UI queries must never wait for a HID read, write, or haptic to finish.
    private let snapshotLock = NSLock()
    private var rotationGeneration: UInt64?
    private var hapticGeneration: UInt64?

    init(apply: @escaping (DialHardwareConfiguration) -> Bool) {
        self.apply = apply
    }

    private var desired: DialHardwareConfiguration {
        DialHardwareConfiguration(ticksPerRevolution: menuActive
                                  ? sensitivity.menuTicksPerRevolution
                                  : sensitivity.normalTicksPerRevolution,
                                  haptics: haptics)
    }

    @discardableResult
    func update(sensitivity: WheelSensitivity? = nil, haptics: Bool? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let sensitivity = sensitivity { self.sensitivity = sensitivity }
        if let haptics = haptics { self.haptics = haptics }
        return configure()
    }

    @discardableResult
    func setMenuNavigationActive(_ active: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard connected || !active else { return false }
        if menuActive != active {
            menuActive = active
            generation &+= 1
        }
        return configure()
    }

    @discardableResult
    func didConnect() -> Bool {
        lock.lock(); defer { lock.unlock() }
        connected = true
        menuActive = false
        applied = nil
        generation &+= 1
        return configure()
    }

    func didDisconnect() {
        lock.lock(); defer { lock.unlock() }
        connected = false
        menuActive = false
        applied = nil
        generation &+= 1
        publishSnapshot()
    }

    func shutdown() {
        lock.lock(); defer { lock.unlock() }
        menuActive = false
        generation &+= 1
        applied = nil
        publishSnapshot()
        if connected {
            // Restore normal spacing and silence the device, without changing
            // either saved preference or the next connection's desired state.
            _ = apply(DialHardwareConfiguration(ticksPerRevolution: sensitivity.normalTicksPerRevolution,
                                                haptics: false))
        }
        connected = false
        applied = nil
    }

    func withInputContext<T>(_ read: () -> T) -> (value: T, generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        return (read(), generation)
    }

    func acceptsRotation(_ reportGeneration: UInt64) -> Bool {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return rotationGeneration == reportGeneration
    }

    var feedbackToken: UInt64? {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return hapticGeneration
    }

    func performFeedback(ifGeneration token: UInt64? = nil, _ impact: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        if let token = token, token != generation { return }
        if connected && haptics && applied != nil { impact() }
    }

    private func configure() -> Bool {
        defer { publishSnapshot() }
        guard connected else { return true }
        guard applied != desired else { return true }
        generation &+= 1
        applied = nil
        publishSnapshot()
        if apply(desired) {
            applied = desired
            return true
        }
        // A failed menu write cannot leave the picker navigating at normal
        // spacing. Report failure so its owner cancels, and restore if possible.
        if menuActive {
            menuActive = false
            generation &+= 1
            if apply(desired) { applied = desired }
        }
        return false
    }

    private func publishSnapshot() {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        rotationGeneration = connected && applied != nil ? generation : nil
        hapticGeneration = connected && haptics && applied != nil ? generation : nil
    }
}

// Queues feedback and menu-exit writes in order without blocking presentation.
// Entering the menu still reports configuration failures synchronously.
final class DialHardwareCommands {
    private let configuration: DialConfigurationController
    private let schedule: (@escaping () -> Void) -> Void
    private let impact: () -> Void
    private let lock = NSLock()
    private let executionLock = NSLock()
    private var menuRequest = 0
    private var feedbackRequest = 0
    private var restoring = false

    init(configuration: DialConfigurationController,
         schedule: @escaping (@escaping () -> Void) -> Void,
         impact: @escaping () -> Void) {
        self.configuration = configuration
        self.schedule = schedule
        self.impact = impact
    }

    @discardableResult
    func setMenuNavigationActive(_ active: Bool) -> Bool {
        lock.lock()
        menuRequest += 1
        let request = menuRequest
        restoring = true
        lock.unlock()
        if active {
            executionLock.lock(); defer { executionLock.unlock() }
            let success = configuration.setMenuNavigationActive(true)
            finishRestoring(request)
            return success
        }
        schedule { [weak self] in
            guard let self = self else { return }
            self.executionLock.lock(); defer { self.executionLock.unlock() }
            self.lock.lock()
            let current = request == self.menuRequest
            self.lock.unlock()
            guard current else { return }
            _ = self.configuration.setMenuNavigationActive(false)
            self.finishRestoring(request)
        }
        return true
    }

    func acceptsRotation(_ generation: UInt64) -> Bool {
        lock.lock()
        let pending = restoring
        lock.unlock()
        return !pending && configuration.acceptsRotation(generation)
    }

    func feedback() {
        guard let token = configuration.feedbackToken else { return }
        lock.lock()
        feedbackRequest += 1
        let request = feedbackRequest
        lock.unlock()
        schedule { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let current = request == self.feedbackRequest
            self.lock.unlock()
            guard current else { return }
            self.configuration.performFeedback(ifGeneration: token) {
                // Cancellation can arrive while this job waits for the HID lock.
                self.lock.lock()
                let stillCurrent = request == self.feedbackRequest
                self.lock.unlock()
                if stillCurrent { self.impact() }
            }
        }
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        menuRequest += 1
        feedbackRequest += 1
        restoring = false
    }

    func cancelFeedback() {
        lock.lock(); defer { lock.unlock() }
        feedbackRequest += 1
    }

    private func finishRestoring(_ request: Int) {
        lock.lock(); defer { lock.unlock() }
        if request == menuRequest { restoring = false }
    }
}
