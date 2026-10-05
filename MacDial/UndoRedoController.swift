import AppKit
import Carbon.HIToolbox

final class UndoRedoController: Controller {
    private let source = CGEventSource(stateID: .hidSystemState)
    private let targetProcess: () -> pid_t?
    private let post: (CGEvent, pid_t) -> Void

    init(targetProcess: @escaping () -> pid_t? = {
             NSWorkspace.shared.frontmostApplication?.processIdentifier
         },
         post: @escaping (CGEvent, pid_t) -> Void = { $0.postToPid($1) }) {
        self.targetProcess = targetProcess
        self.post = post
    }

    func onDown() {}

    func onUp() {
        send(steps: 1, flags: .maskCommand)
    }

    func onRotate(_ rotation: Dial.Rotation, _ scrollDirection: Int) {
        switch rotation {
        case .Clockwise(let count):
            send(steps: count, flags: [.maskCommand, .maskShift])
        case .CounterClockwise(let count):
            send(steps: count, flags: .maskCommand)
        }
    }

    private func send(steps: Int, flags: CGEventFlags) {
        guard steps > 0, let pid = targetProcess() else { return }
        for _ in 0..<steps {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_Z), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_Z), keyDown: false),
                  targetProcess() == pid else { return }
            down.flags = flags
            up.flags = flags
            // Finish this pair at its original destination even if focus changes
            // during posting. Remaining steps must never spill into another app.
            post(down, pid)
            post(up, pid)
        }
    }
}
