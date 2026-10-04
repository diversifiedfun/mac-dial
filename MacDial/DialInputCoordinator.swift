import Foundation

// Routes entire HID reports on the main queue. Presentation and system events
// are injected, so routing can be checked without a device.
final class DialInputCoordinator {
    static let idleTimeout: TimeInterval = 10
    var onShortPress: (() -> Void)?
    var onRotation: ((Dial.Rotation, Int) -> Void)?
    var onCancelAction: (() -> Void)?
    var onCommit: ((Mode) -> Void)?
    var onPickerChanged: ((ModePickerState?) -> Void)?
    var onFeedback: (() -> Void)?
    private(set) var picker: ModePickerState?

    var menuPressDuration: MenuPressDuration {
        get { button.menuPressDuration }
        set { button.menuPressDuration = newValue }
    }

    private let currentMode: () -> Mode
    private let currentProfile: () -> AppProfile?
    private let button: DialButtonHandler
    private let schedule: (TimeInterval, DispatchWorkItem) -> Void
    private var physicallyPressed = false
    private var suppressUntilRelease = false
    private var idleTimer: DispatchWorkItem?
    private var idleGeneration = 0
    private var pickerGeneration = 0

    init(currentMode: @escaping () -> Mode,
         currentProfile: @escaping () -> AppProfile? = { nil },
         button: DialButtonHandler = DialButtonHandler(),
         schedule: @escaping (TimeInterval, DispatchWorkItem) -> Void = {
             DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1)
         }) {
        self.currentMode = currentMode
        self.currentProfile = currentProfile
        self.button = button
        self.schedule = schedule
        button.onShortPress = { [weak self] in
            guard let self = self else { return }
            if self.picker != nil { self.confirmSelection() }
            else { self.onShortPress?() }
        }
        button.onLongPress = { [weak self] in self?.longPressed() }
        button.onLongPressRelease = { [weak self] in
            guard let self = self, self.picker != nil else { return }
            self.picker?.isArmed = true
            self.publish()
        }
    }

    deinit {
        idleTimer?.cancel()
        button.cancel()
    }

    func handle(button state: Dial.ButtonState, rotation: Dial.Rotation?,
                sensitivity: Int, scrollDirection: Int, timestamp: TimeInterval? = nil) {
        let hadPicker = picker != nil
        let initialPickerGeneration = pickerGeneration
        let wasArmed = picker?.isArmed == true
        let pressed = state == .pressed
        let changed = pressed != physicallyPressed
        physicallyPressed = pressed

        if suppressUntilRelease {
            if !pressed { suppressUntilRelease = false }
            return // Consume the release report's rotation too.
        }

        if changed {
            if pressed { button.pressed(at: timestamp) }
            else { button.released(at: timestamp) }
        } else if pressed {
            button.advance(at: timestamp)
        }

        // A confirming/cancelling report must not reach the new controller.
        if hadPicker || picker != nil || initialPickerGeneration != pickerGeneration {
            if picker != nil {
                if changed || rotation != nil { activity() }
                if wasArmed, !pressed, !changed, let rotation = rotation,
                   picker?.rotate(rotation, sensitivity: sensitivity) == true {
                    onFeedback?()
                    publish()
                }
            }
            return
        }
        if !suppressUntilRelease, let rotation = rotation {
            onRotation?(rotation, scrollDirection)
        }
    }

    func moveSelection(by steps: Int) {
        guard picker?.isArmed == true, !physicallyPressed else { return }
        if picker?.move(by: steps) == true { onFeedback?() }
        publish()
    }

    func highlight(_ mode: Mode) {
        guard picker?.isArmed == true, !physicallyPressed else { return }
        if picker?.select(mode) == true {
            onFeedback?()
            publish()
        } else {
            activity()
        }
    }

    func confirmSelection() {
        guard let picker = picker, picker.isArmed, !physicallyPressed else { return }
        let mode = picker.selectedMode
        cancel()
        onCommit?(mode)
        onFeedback?()
    }

    func cancel() {
        button.cancel()
        suppressUntilRelease = suppressUntilRelease || physicallyPressed
        idleTimer?.cancel()
        idleTimer = nil
        idleGeneration += 1
        let wasOpen = picker != nil
        picker = nil
        onCancelAction?()
        if wasOpen {
            pickerGeneration += 1
            onPickerChanged?(nil)
        }
    }

    // Stale reports still describe the physical button. Consume their edges
    // without creating a new press in the new app's context.
    func discard(button state: Dial.ButtonState) {
        cancel()
        physicallyPressed = state == .pressed
        suppressUntilRelease = physicallyPressed
    }

    private func longPressed() {
        if picker != nil {
            cancel()
        } else {
            onCancelAction?()
            picker = ModePickerState(selectedMode: currentMode(), profile: currentProfile())
            pickerGeneration += 1
            onFeedback?()
            publish()
        }
    }

    private func publish() {
        onPickerChanged?(picker)
        activity()
    }

    private func activity() {
        guard picker != nil else { return }
        idleTimer?.cancel()
        idleGeneration += 1
        let generation = idleGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.idleGeneration == generation else { return }
            self.cancel()
        }
        idleTimer = work
        schedule(Self.idleTimeout, work)
    }
}
