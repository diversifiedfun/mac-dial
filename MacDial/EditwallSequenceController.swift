import AppKit
import Carbon.HIToolbox

final class EditwallSequenceController: Controller {
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

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         doubleClickInterval: @escaping () -> TimeInterval = { NSEvent.doubleClickInterval },
         schedule: @escaping (TimeInterval, DispatchWorkItem) -> Void = {
             DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1)
         },
         targetProcess: @escaping () -> pid_t? = {
             guard let app = NSWorkspace.shared.frontmostApplication,
                   app.bundleIdentifier == AppProfile.editwall.bundleIdentifier else { return nil }
             return app.processIdentifier
         },
         post: @escaping (CGEvent, pid_t) -> Void = { $0.postToPid($1) }) {
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
                send(steps: 1, key: kVK_LeftArrow, to: pending.pid)
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
        send(steps: 1, key: kVK_RightArrow, to: pending.pid)
    }

    func onRotate(_ rotation: Dial.Rotation, _ scrollDirection: Int) {
        switch rotation {
        case .Clockwise(let count):
            rotate(steps: count, key: kVK_DownArrow)
        case .CounterClockwise(let count):
            rotate(steps: count, key: kVK_UpArrow)
        }
    }

    private func rotate(steps: Int, key: Int) {
        guard steps > 0 else { return }
        // Rotation takes over immediately; no delayed click may arrive later.
        onCancel()
        guard let pid = targetProcess() else { return }
        send(steps: steps, key: key, to: pid)
    }

    private func send(steps: Int, key: Int, to pid: pid_t) {
        for _ in 0..<steps {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: false),
                  targetProcess() == pid else { return }
            down.flags = []
            up.flags = []
            // Finish this pair at its original destination even if focus changes
            // during posting. Remaining steps must never spill into another app.
            post(down, pid)
            post(up, pid)
        }
    }
}
