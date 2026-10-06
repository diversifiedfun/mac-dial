import AppKit
import Carbon.HIToolbox

final class ZoomController: Controller {
    private let eventSource = CGEventSource(stateID: .hidSystemState)
    private let targetProcess: () -> pid_t?
    private let post: (CGEvent, pid_t) -> Void
    private var generation = 0

    init(targetProcess: @escaping () -> pid_t? = {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }, post: @escaping (CGEvent, pid_t) -> Void = { $0.postToPid($1) }) {
        self.targetProcess = targetProcess
        self.post = post
    }

    func onDown() {}
    func onCancel() { generation += 1 }
    func onUp() { sendShortcut(kVK_ANSI_0, steps: 1) }

    func onRotate(_ rotation: Dial.Rotation, _ scrollDirection: Int) {
        switch rotation {
        case .Clockwise(let count): sendShortcut(kVK_ANSI_Equal, steps: count)
        case .CounterClockwise(let count): sendShortcut(kVK_ANSI_Minus, steps: count)
        }
    }

    // Finish each key pair in its original process. Stop the batch if focus
    // changes or input is cancelled, so a release cannot reach another app.
    private func sendShortcut(_ key: Int, steps: Int) {
        guard steps > 0, let pid = targetProcess() else { return }
        let token = generation
        for _ in 0..<steps {
            guard targetProcess() == pid, generation == token,
                  let down = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(key), keyDown: true),
                  let up = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(key), keyDown: false) else { return }
            down.flags = .maskCommand
            up.flags = .maskCommand
            post(down, pid)
            post(up, pid)
        }
    }
}
