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
    private let schedule: (TimeInterval, DispatchWorkItem) -> Void
    private let reduceMotion: () -> Bool
    private var animationWork: [DispatchWorkItem] = []
    private var presentationGeneration = 0
    private(set) var isShowing = false
    private(set) var isConfirming = false

    override convenience init() {
        self.init(schedule: { DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1) },
                  reduceMotion: { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion })
    }

    init(schedule: @escaping (TimeInterval, DispatchWorkItem) -> Void,
         reduceMotion: @escaping () -> Bool) {
        self.schedule = schedule
        self.reduceMotion = reduceMotion
        panel = RadialPanel(contentRect: view.bounds, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        super.init()
        panel.title = "Mac Dial modes"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.acceptsMouseMovedEvents = true
        panel.contentView = view
        panel.delegate = self
        view.onMaterialChanged = { [weak self] nativeGlass in
            self?.updateWindowShadow(nativeGlass: nativeGlass)
        }
        updateWindowShadow(nativeGlass: view.isUsingLiquidGlass)
    }

    private func updateWindowShadow(nativeGlass: Bool) {
        // Liquid Glass renders its own elevation around the custom contour.
        // Avoid a second window-server silhouette around that same contour.
        // Keep the normal panel shadow for Classic and the opaque fallback.
        panel.hasShadow = !nativeGlass
        panel.invalidateShadow()
    }

    deinit {
        animationWork.forEach { $0.cancel() }
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
    }

    func show(_ state: ModePickerState) {
        if isConfirming { dismiss() }
        view.update(state)
        guard !isShowing else { return }
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else {
            view.onCancel?()
            return
        }
        previousKeyWindow = NSApp.keyWindow
        isShowing = true
        panel.setFrame(view.menuLayout.frame(around: pointer, in: screen.visibleFrame,
                                             padding: RadialMenuLayout.effectPadding), display: true)
        let animate = !reduceMotion()
        panel.ignoresMouseEvents = false
        panel.alphaValue = animate ? 0 : 1
        // This gives the panel keyboard focus without activating Mac Dial or
        // changing the foreground application that receives later dial input.
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        panel.invalidateShadow()
        installMonitors()
        if animate {
            for frame in 1...8 {
                enqueue(after: 0.12 * Double(frame) / 8) { controller in
                    controller.panel.alphaValue = CGFloat(frame) / 8
                }
            }
        }
    }

    func confirm(_ state: ModePickerState) {
        guard isShowing, !isConfirming else { return }
        cancelAnimation()
        isConfirming = true
        removeMonitors()
        panel.alphaValue = 1
        panel.ignoresMouseEvents = true
        view.showConfirmation(state)
        restoreFocus()
        if reduceMotion() {
            view.setConfirmationProgress(1)
            enqueue(after: 0.3) { $0.dismiss() }
        } else {
            // Explicit, generation-guarded frames also cancel an in-flight fade on reopen.
            for frame in 1...18 {
                let elapsed = Double(frame) / 60
                enqueue(after: elapsed) { controller in
                    controller.view.setConfirmationProgress(CGFloat(elapsed / 0.1))
                    controller.panel.alphaValue = CGFloat(max(0, min(1, (0.3 - elapsed) / 0.1)))
                    if frame == 18 { controller.dismiss() }
                }
            }
        }
    }

    func dismiss() {
        cancelAnimation()
        view.finishSelectionAnimation()
        guard isShowing else { return }
        isShowing = false
        isConfirming = false
        removeMonitors()
        restoreFocus()
        panel.orderOut(nil)
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
    }

    private func removeMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }

    private func restoreFocus() {
        if panel.isKeyWindow {
            panel.resignKey()
            if let previousKeyWindow = previousKeyWindow, previousKeyWindow.isVisible {
                previousKeyWindow.makeKey()
            }
        }
        previousKeyWindow = nil
    }

    private func cancelAnimation() {
        presentationGeneration += 1
        animationWork.forEach { $0.cancel() }
        animationWork.removeAll()
    }

    private func enqueue(after delay: TimeInterval, action: @escaping (RadialMenuController) -> Void) {
        let generation = presentationGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.presentationGeneration == generation else { return }
            action(self)
        }
        animationWork.append(work)
        schedule(delay, work)
    }

    func windowDidResignKey(_ notification: Notification) {
        if isShowing && !isConfirming { view.onCancel?() }
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
