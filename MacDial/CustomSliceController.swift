import AppKit

final class CustomSliceController: Controller {
    private let gestures: SliceGestures
    private let source = CGEventSource(stateID: .hidSystemState)
    private let targetProcess: () -> pid_t?
    private let post: (CGEvent, pid_t) -> Void
    private let now: () -> TimeInterval
    private let doubleClickInterval: () -> TimeInterval
    private let schedule: (TimeInterval, DispatchWorkItem) -> Void
    private var pendingClick: (pid: pid_t, deadline: TimeInterval)?
    private var secondPress = false
    private var clickTimer: DispatchWorkItem?
    private var clickGeneration = 0

    init(gestures: SliceGestures, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         doubleClickInterval: @escaping () -> TimeInterval = { NSEvent.doubleClickInterval },
         schedule: @escaping (TimeInterval, DispatchWorkItem) -> Void = {
             DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1)
         },
         targetProcess: @escaping () -> pid_t? = {
             NSWorkspace.shared.frontmostApplication?.processIdentifier
         },
         post: @escaping (CGEvent, pid_t) -> Void = { $0.postToPid($1) }) {
        self.gestures = gestures
        self.targetProcess = targetProcess
        self.post = post
        self.now = now
        self.doubleClickInterval = doubleClickInterval
        self.schedule = schedule
    }

    deinit { clickTimer?.cancel() }

    func onPressBegan() {
        guard let pending = pendingClick else { return }
        guard targetProcess() == pending.pid else { onCancel(); return }
        if now() <= pending.deadline {
            // Wait for short-release versus long-hold classification. A hold
            // must cancel this click even if its threshold exceeds the window.
            invalidateTimer()
            secondPress = true
        } else {
            finishSingleClick()
        }
    }

    func onDown() {}

    func onUp() {
        if let pending = pendingClick {
            if secondPress || now() <= pending.deadline {
                onCancel()
                send(gestures.doubleClick, steps: 1, to: pending.pid)
                return
            }
            finishSingleClick()
        }
        guard let pid = targetProcess() else { return }
        let interval = doubleClickInterval()
        pendingClick = (pid, now() + interval)
        let generation = clickGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.clickGeneration == generation else { return }
            self.finishSingleClick()
        }
        clickTimer = work
        schedule(interval, work)
    }

    func onCancel() {
        invalidateTimer()
        pendingClick = nil
        secondPress = false
    }

    private func invalidateTimer() {
        clickTimer?.cancel()
        clickTimer = nil
        clickGeneration += 1
    }

    private func finishSingleClick() {
        guard let pending = pendingClick else { return }
        onCancel()
        send(gestures.click, steps: 1, to: pending.pid)
    }

    func onRotate(_ rotation: Dial.Rotation, _ scrollDirection: Int) {
        switch rotation {
        case .Clockwise(let count):
            rotate(steps: count, action: gestures.rotateRight)
        case .CounterClockwise(let count):
            rotate(steps: count, action: gestures.rotateLeft)
        }
    }

    private func rotate(steps: Int, action: SliceAction) {
        guard steps > 0 else { return }
        // Rotation takes over immediately; no delayed click may arrive later.
        onCancel()
        guard let pid = targetProcess() else { return }
        send(action, steps: steps, to: pid)
    }

    private func send(_ action: SliceAction, steps: Int, to pid: pid_t) {
        guard case .keyboardShortcut(let shortcut) = action, shortcut.isValid else { return }
        var flags: CGEventFlags = []
        if shortcut.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if shortcut.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if shortcut.modifiers.contains(.control) { flags.insert(.maskControl) }
        if shortcut.modifiers.contains(.shift) { flags.insert(.maskShift) }
        let generation = clickGeneration
        for _ in 0..<steps {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: false),
                  targetProcess() == pid, generation == clickGeneration else { return }
            down.flags = flags
            up.flags = flags
            // Finish this pair at its original destination even if focus changes
            // during posting. Remaining steps must never spill into another app.
            post(down, pid)
            post(up, pid)
        }
    }
}
