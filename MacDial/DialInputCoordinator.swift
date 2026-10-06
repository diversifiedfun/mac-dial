import Foundation

// Routes entire HID reports on the main queue. Presentation and system events
// are injected, so routing can be checked without a device.
final class DialInputCoordinator {
    static let idleTimeout: TimeInterval = 10
    var onPressBegan: (() -> Void)?
    var onShortPress: (() -> Void)?
    var onRotation: ((Dial.Rotation, Int) -> Void)?
    var onCancelAction: (() -> Void)?
    var onCommit: ((Mode) -> Bool)?
    var onCommitSlice: ((SliceID) -> Bool)?
    // Production supplies a configuration snapshot; legacy tests can continue
    // using currentMode/currentProfile. Snapshot is captured only on opening.
    var currentPicker: (() -> ModePickerState)?
    var onConfirmation: ((ModePickerState) -> Void)?
    var onPickerChanged: ((ModePickerState?) -> Void)?
    var onFeedback: (() -> Void)?
    var onMenuNavigationChanged: ((Bool) -> Bool)?
    private(set) var picker: ModePickerState?
    // Read only when opening; changing this never moves an existing highlight.
    var radialMenuStartPosition: RadialMenuStartPosition = .lastSelected

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

    func handle(button state: Dial.ButtonState, rotation: Dial.Rotation?, rotationIsCurrent: Bool = true,
                scrollDirection: Int, timestamp: TimeInterval? = nil) {
        let rotation = rotationIsCurrent ? rotation : nil
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

        if changed, pressed, wasArmed {
            commitSelection()
            return // Consume this press, its rotation, and the eventual release.
        }

        if changed {
            if pressed {
                if picker == nil { onPressBegan?() }
                button.pressed(at: timestamp)
            }
            else { button.released(at: timestamp) }
        } else if pressed {
            button.advance(at: timestamp)
        }

        // A confirming/cancelling report must not reach the new controller.
        if hadPicker || picker != nil || initialPickerGeneration != pickerGeneration {
            if picker != nil {
                if changed || rotation != nil { activity() }
                if wasArmed, !pressed, !changed, let rotation = rotation,
                   picker?.rotate(rotation) == true {
                    // Rotation already carries the hardware's automatic click.
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

    func highlight(_ mode: Mode, feedback: Bool = true) {
        highlightSlice(.builtIn(mode), feedback: feedback)
    }

    func highlightSlice(_ id: SliceID, feedback: Bool = true) {
        guard picker?.isArmed == true, !physicallyPressed else { return }
        if picker?.selectSlice(id) == true {
            if feedback { onFeedback?() }
            publish()
        } else {
            activity()
        }
    }

    func confirmSelection(_ selectedMode: Mode? = nil) {
        confirmSlice(selectedMode.map(SliceID.builtIn))
    }

    func confirmSlice(_ id: SliceID? = nil) {
        if let id = id {
            guard picker?.dial.contains(id) == true else { return }
            guard picker?.isArmed == true, !physicallyPressed else { return }
            picker?.selectSlice(id)
        }
        guard let picker = picker, picker.isArmed, !physicallyPressed else { return }
        commitSelection(picker)
    }

    private func commitSelection(_ selection: ModePickerState? = nil) {
        guard let picker = selection ?? picker, picker.isArmed,
              let id = picker.selectedSliceID else { return }
        clearPicker(restoreHardware: false)
        // Enqueue the confirmation pulse before restoring normal sensitivity.
        // The production callbacks perform HID work away from the UI thread.
        defer { if self.picker == nil { _ = onMenuNavigationChanged?(false) } }
        let generation = pickerGeneration
        let committed: Bool
        if let onCommitSlice = onCommitSlice { committed = onCommitSlice(id) }
        else if let mode = picker.selectedSlice?.builtInMode { committed = onCommit?(mode) == true }
        else { committed = false }
        if committed, generation == pickerGeneration {
            onConfirmation?(picker)
            guard generation == pickerGeneration else { return }
            onFeedback?()
        } else if generation == pickerGeneration {
            onPickerChanged?(nil)
        }
    }

    func cancel() {
        let wasOpen = picker != nil
        clearPicker()
        if wasOpen { onPickerChanged?(nil) }
    }

    private func clearPicker(restoreHardware: Bool = true) {
        button.cancel()
        suppressUntilRelease = suppressUntilRelease || physicallyPressed
        idleTimer?.cancel()
        idleTimer = nil
        idleGeneration += 1
        let wasOpen = picker != nil
        picker = nil
        pickerGeneration += 1
        onCancelAction?()
        if wasOpen && restoreHardware {
            _ = onMenuNavigationChanged?(false)
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
        if picker == nil {
            onCancelAction?()
            if let currentPicker = currentPicker {
                let snapshot = currentPicker()
                picker = ModePickerState(dial: snapshot.dial, application: snapshot.application,
                    selectedSliceID: snapshot.selectedSliceID, startPosition: radialMenuStartPosition)
            } else {
                picker = ModePickerState(selectedMode: currentMode(), profile: currentProfile(),
                                         startPosition: radialMenuStartPosition)
            }
            pickerGeneration += 1
            guard onMenuNavigationChanged?(true) ?? true else {
                cancel()
                return
            }
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
