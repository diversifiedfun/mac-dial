import AppKit
import Carbon.HIToolbox

final class LightroomController: Controller {
    let mode: Mode
    private let source = CGEventSource(stateID: .hidSystemState)
    private let targetProcess: () -> pid_t?
    private let post: (CGEvent, pid_t) -> Void

    init(mode: Mode,
         targetProcess: @escaping () -> pid_t? = {
             guard let app = NSWorkspace.shared.frontmostApplication,
                   app.bundleIdentifier == AppProfile.lightroom.bundleIdentifier else { return nil }
             return app.processIdentifier
         },
         post: @escaping (CGEvent, pid_t) -> Void = { $0.postToPid($1) }) {
        precondition(mode.isLightroom)
        self.mode = mode
        self.targetProcess = targetProcess
        self.post = post
    }

    func onDown() {}

    func onUp() {
        switch mode {
        case .lightroomCrop: send(kVK_ANSI_R)
        case .lightroomFineTune: send(kVK_ANSI_Backslash)
        case .lightroomBrush: send(kVK_ANSI_Q)
        default: break
        }
    }

    func onRotate(_ rotation: Dial.Rotation, _ scrollDirection: Int) {
        let clockwise: Bool
        let count: Int
        switch rotation {
        case .Clockwise(let value): clockwise = true; count = value
        case .CounterClockwise(let value): clockwise = false; count = value
        }
        let key: Int
        switch mode {
        case .lightroomCrop: key = clockwise ? kVK_RightArrow : kVK_LeftArrow
        // Lightroom accepts the unshifted US +/= key for small increments.
        // Shift would request the coarse increment instead.
        case .lightroomFineTune: key = clockwise ? kVK_ANSI_Equal : kVK_ANSI_Minus
        case .lightroomBrush: key = clockwise ? kVK_ANSI_RightBracket : kVK_ANSI_LeftBracket
        default: return
        }
        for _ in 0..<max(0, count) {
            if !send(key, flags: mode == .lightroomCrop ? .maskCommand : []) { break }
        }
    }

    @discardableResult
    private func send(_ key: Int, flags: CGEventFlags = []) -> Bool {
        guard let pid = targetProcess(),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        // Both edges go to the verified process, even if focus changes between
        // them. Never leave a key held or redirect its release to another app.
        post(down, pid)
        post(up, pid)
        return true
    }
}
