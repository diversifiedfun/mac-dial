import AppKit

private final class RadialPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class RadialMenuController: NSObject, NSWindowDelegate {
    let view = RadialMenuView()
    private let panel: NSPanel
    private weak var previousKeyWindow: NSWindow?
    private var monitors: [Any] = []
    private(set) var isShowing = false

    override init() {
        panel = RadialPanel(contentRect: view.bounds, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        super.init()
        panel.title = "Mac Dial modes"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.acceptsMouseMovedEvents = true
        panel.contentView = view
        panel.delegate = self
    }

    deinit {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
    }

    func show(_ state: ModePickerState) {
        view.update(state)
        guard !isShowing else { return }
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else {
            view.onCancel?()
            return
        }
        previousKeyWindow = NSApp.keyWindow
        isShowing = true
        panel.setFrame(view.menuLayout.frame(around: pointer, in: screen.visibleFrame), display: true)
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = animate ? 0 : 1
        // This gives the panel keyboard focus without activating Mac Dial or
        // changing the foreground application that receives later dial input.
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        panel.invalidateShadow()
        installMonitors()
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    func dismiss() {
        guard isShowing else { return }
        isShowing = false
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        let restoreKey = panel.isKeyWindow
        panel.orderOut(nil)
        if restoreKey, let previousKeyWindow = previousKeyWindow, previousKeyWindow.isVisible {
            previousKeyWindow.makeKey()
        }
        previousKeyWindow = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        if isShowing { view.onCancel?() }
    }

    private func installMonitors() {
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mouse, handler: { [weak self] _ in
            self?.view.onCancel?()
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mouse, handler: { [weak self] event in
            guard let self = self, self.isShowing else { return event }
            if event.window !== self.panel { self.view.onCancel?() }
            return event
        }) { monitors.append(monitor) }
    }
}
