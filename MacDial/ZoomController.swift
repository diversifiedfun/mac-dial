import AppKit
import Carbon.HIToolbox

final class ZoomController: Controller {
    private let eventSource = CGEventSource(stateID: .hidSystemState)
    private let post: (CGEvent) -> Void

    init(post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.post = post
    }

    func onDown() {}

    func onUp() {
        sendShortcut(kVK_ANSI_0)
    }

    func onRotate(_ rotation: Dial.Rotation, _ scrollDirection: Int) {
        let key: Int
        let steps: Int
        switch rotation {
        case .Clockwise(let count):
            key = kVK_ANSI_Equal
            steps = count
        case .CounterClockwise(let count):
            key = kVK_ANSI_Minus
            steps = count
        }
        for _ in 0..<max(0, steps) { sendShortcut(key) }
    }

    // Common app zoom shortcuts: Command+=, Command+-, Command+0.
    // Send both edges with explicit flags so physical modifiers do not leak in.
    private func sendShortcut(_ key: Int) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: eventSource,
                                      virtualKey: CGKeyCode(key), keyDown: down) else { continue }
            event.flags = .maskCommand
            post(event)
        }
    }
}
