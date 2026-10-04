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
    }

    func shutdown() {
        lock.lock(); defer { lock.unlock() }
        menuActive = false
        generation &+= 1
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
        lock.lock(); defer { lock.unlock() }
        return connected && applied != nil && generation == reportGeneration
    }

    func performFeedback(_ impact: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        if connected && haptics && applied != nil { impact() }
    }

    private func configure() -> Bool {
        guard connected else { return true }
        guard applied != desired else { return true }
        generation &+= 1
        applied = nil
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
}
