import AppKit

// Rotation follows the Mac's brightness keys. Clicks use a native brightness
// value so restoring does not depend on counting key presses or rounding steps.
final class BrightnessController: Controller {
    private let post: (Int32, [NSEvent.ModifierFlags], Int) -> Void
    private let displays: DisplayBrightnessAccess
    private let defaults: UserDefaults
    private let unavailable: () -> Void
    private var pendingClick = false
    private static let restoreKey = "brightnessRestore"

    init(displays: DisplayBrightnessAccess = SystemDisplayBrightness.shared,
         defaults: UserDefaults = .standard,
         unavailable: @escaping () -> Void = { NSSound.beep() },
         post: @escaping (Int32, [NSEvent.ModifierFlags], Int) -> Void = {
        HIDPostAuxKey(key: $0, modifiers: $1, _repeat: $2)
    }) {
        self.displays = displays
        self.defaults = defaults
        self.unavailable = unavailable
        self.post = post
    }

    func onDown() { pendingClick = true }
    func onCancel() { pendingClick = false }

    func onUp() {
        guard pendingClick else { return }
        pendingClick = false

        guard let display = displays.preferredDisplay() else {
            unavailable()
            return
        }
        var saved = savedLevels()
        if let number = saved[display.identifier],
           number.doubleValue.isFinite, number.doubleValue > 0, number.doubleValue <= 1 {
            guard displays.setBrightness(number.floatValue, for: display) else {
                unavailable()
                return // Keep the restore value available for another click.
            }
            saved.removeValue(forKey: display.identifier)
            saveLevels(saved)
            return
        }

        guard let level = displays.brightness(of: display),
              level.isFinite, (0...1).contains(level) else {
            unavailable()
            return
        }
        // Already at zero without a saved value: there is nothing to restore.
        guard level > 0 else { return }
        saved[display.identifier] = NSNumber(value: level)
        saveLevels(saved)
        if !displays.setBrightness(0, for: display) {
            // Retain the snapshot even on failure; a driver may partially apply
            // a write. The next click can still recover the original level.
            unavailable()
        }
    }

    private func savedLevels() -> [String: NSNumber] {
        guard let saved = defaults.dictionary(forKey: Self.restoreKey) else { return [:] }
        // Preserve a pending restore from the original single-display version.
        if let identifier = saved["display"] as? String,
           let level = saved["brightness"] as? NSNumber {
            return [identifier: level]
        }
        return saved.compactMapValues { $0 as? NSNumber }
    }

    private func saveLevels(_ levels: [String: NSNumber]) {
        if levels.isEmpty { defaults.removeObject(forKey: Self.restoreKey) }
        else { defaults.set(levels, forKey: Self.restoreKey) }
    }

    func onRotate(_ rotation: Dial.Rotation, _ scrollDirection: Int) {
        let key: Int32
        let count: Int
        switch rotation {
        case .Clockwise(let ticks): key = NX_KEYTYPE_BRIGHTNESS_UP; count = ticks
        case .CounterClockwise(let ticks): key = NX_KEYTYPE_BRIGHTNESS_DOWN; count = ticks
        }
        guard count > 0 else { return }
        post(key, [.shift, .option], count)
    }
}
