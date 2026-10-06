import AppKit

// A hardware-free preview of the production UI/router. Never opens a HID
// device, changes saved modes, requests permissions, or posts system input.
enum Dial {
    enum ButtonState { case pressed, released }
    enum Rotation { case Clockwise(Int), CounterClockwise(Int) }
}

// Reproducible visual checks without changing system preferences or production defaults.
func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

final class ContrastBackdrop: NSView {
    let style: String
    let image = argument("--backdrop-image").flatMap { NSImage(contentsOfFile: $0) }
    init(style: String) { self.style = style; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        (style == "dark" ? NSColor(calibratedWhite: 0.08, alpha: 1) : .white).setFill()
        bounds.fill()
        if let image = image, image.size.width > 0, image.size.height > 0 {
            let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = NSSize(width: bounds.width / scale, height: bounds.height / scale)
            let crop = NSRect(x: (image.size.width - size.width) / 2, y: (image.size.height - size.height) / 2,
                              width: size.width, height: size.height)
            image.draw(in: bounds, from: crop, operation: .copy, fraction: 1)
            return
        }
        if style == "busy" {
            let colors: [NSColor] = [.systemBlue, .systemOrange, .black, .white]
            for x in stride(from: 0, to: Int(bounds.width), by: 24) {
                colors[(x / 24) % colors.count].setFill()
                NSRect(x: CGFloat(x), y: 0, width: 24, height: bounds.height).fill()
            }
        }
    }
}

final class PreviewDelegate: NSObject, NSApplicationDelegate {
    let menu = RadialMenuController()
    var mode = Mode.lightroomCrop
    var profile: AppProfile? = .lightroom
    var status: NSStatusItem!
    var backdrop: NSPanel?
    lazy var input = DialInputCoordinator(currentMode: { [unowned self] in self.mode },
                                         currentProfile: { [unowned self] in self.profile },
                                         schedule: { _, _ in }) // Keep previews open for visual inspection.

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let style = argument("--style").flatMap(RadialMenuAppearance.init(rawValue:)) {
            menu.view.preferredAppearance = style
        }
        switch argument("--profile") {
        case "general": profile = nil; mode = .scrolling
        case "editwall": profile = .editwall; mode = .editwallSequence
        default: break
        }
        if let requested = argument("--mode").flatMap(Mode.init(rawValue:)),
           (profile?.availableModes ?? Mode.generalModes).contains(requested) {
            mode = requested
        }
        switch argument("--appearance") {
        case "light": menu.view.appearance = NSAppearance(named: .aqua)
        case "dark": menu.view.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        if let background = argument("--backdrop") {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating
            panel.ignoresMouseEvents = true
            panel.isReleasedWhenClosed = false
            panel.contentView = ContrastBackdrop(style: background)
            backdrop = panel
        }
        menu.view.updateDisplayOptions(
            reduceTransparency: CommandLine.arguments.contains("--reduce-transparency") || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            increasedContrast: CommandLine.arguments.contains("--increase-contrast") || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            reduceMotion: CommandLine.arguments.contains("--reduce-motion") || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        input.onPickerChanged = { [weak self] state in
            guard let self = self else { return }
            if let state = state {
                self.menu.show(state)
                if let window = self.menu.view.window, let backdrop = self.backdrop {
                    backdrop.setFrame(window.frame.insetBy(dx: -30, dy: -30), display: true)
                    backdrop.order(.below, relativeTo: window.windowNumber)
                }
            }
            else { self.menu.dismiss(); self.backdrop?.orderOut(nil) }
        }
        input.onCommit = { [weak self] mode in
            guard let self = self else { return false }
            self.mode = mode
            self.status.button?.title = "Preview: \(mode.title)"
            print("Selected \(mode.title)")
            return true
        }
        input.onConfirmation = { [weak self] in self?.menu.confirm($0) }
        menu.view.onHighlight = { [weak self] in self?.input.highlight($0) }
        menu.view.onPressHighlight = { [weak self] in self?.input.highlight($0, feedback: false) }
        menu.view.onSelect = { [weak self] mode in
            self?.input.confirmSelection(mode)
        }
        menu.view.onMove = { [weak self] in self?.input.moveSelection(by: $0) }
        menu.view.onConfirm = { [weak self] in self?.input.confirmSelection() }
        menu.view.onCancel = { [weak self] in self?.input.cancel() }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "Dial Preview"
        let actions = NSMenu()
        let appearance = NSMenuItem(title: "Radial Menu Appearance", action: nil, keyEquivalent: "")
        appearance.submenu = NSMenu()
        appearance.submenu?.autoenablesItems = false
        for style in RadialMenuAppearance.allCases {
            let item = NSMenuItem(title: style.title, action: #selector(changeAppearance(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style
            item.state = style == menu.view.preferredAppearance ? .on : .off
            item.isEnabled = style != .liquidGlass || RadialMenuAppearance.supportsLiquidGlass
            appearance.submenu?.addItem(item)
        }
        actions.addItem(appearance)
        actions.addItem(.separator())
        for profile: AppProfile? in [nil, .lightroom, .editwall] {
            for mode in profile?.availableModes ?? Mode.generalModes {
                let item = NSMenuItem(title: "\(profile?.title ?? "General"): \(mode.title)", action: #selector(openMode(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ModePickerState(selectedMode: mode, profile: profile)
                actions.addItem(item)
            }
            actions.addItem(.separator())
        }
        let quit = NSMenuItem(title: "Quit Preview", action: #selector(quitPreview), keyEquivalent: "q")
        quit.target = self
        actions.addItem(quit)
        status.menu = actions
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.open() }
    }

    func open() {
        input.cancel()
        input.handle(button: .pressed, rotation: nil, scrollDirection: -1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            self.input.handle(button: .released, rotation: nil, scrollDirection: -1)
        }
    }

    @objc func openMode(_ sender: NSMenuItem) {
        let state = sender.representedObject as! ModePickerState
        input.cancel()
        mode = state.selectedMode
        profile = state.profile
        // Allow the native status menu to finish tracking before taking keys.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.open() }
    }

    @objc func changeAppearance(_ sender: NSMenuItem) {
        input.cancel()
        menu.view.preferredAppearance = sender.representedObject as! RadialMenuAppearance
        for item in sender.menu?.items ?? [] { item.state = item === sender ? .on : .off }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.open() }
    }

    @objc func quitPreview() { NSApp.terminate(nil) }
}

// A same-window backdrop also makes compositor-based glass visible in window
// screenshots. Offscreen cacheDisplay cannot capture the native glass shader.
final class GalleryDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var wheels: [RadialMenuView] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 500),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Mac Dial — Liquid Glass preview"
        let background = ContrastBackdrop(style: argument("--backdrop") ?? "busy")
        window.contentView = background
        window.appearance = NSAppearance(named: argument("--appearance") == "dark" ? .darkAqua : .aqua)
        let contextual: AppProfile = argument("--profile") == "editwall" ? .editwall : .lightroom
        for (index, profile) in ([nil, contextual] as [AppProfile?]).enumerated() {
            let wheel = RadialMenuView()
            wheel.preferredAppearance = argument("--style").flatMap(RadialMenuAppearance.init(rawValue:)) ?? .automatic
            var state = ModePickerState(selectedMode: profile?.modes.first ?? .scrolling, profile: profile)
            if index == 1, let scenario = argument("--scenario") {
                let standardCount = scenario == "dense" ? 15 : 0
                let appCount = scenario == "empty" ? 0 : scenario == "single-app" ? 1 : scenario == "app-only" ? 18 : 3
                let app = ApplicationConfiguration(bundleIdentifier: contextual.bundleIdentifier, displayName: contextual.title,
                    slices: (0..<appCount).map { .custom(CustomSlice(name: "App action \($0 + 1)", symbolName: "star")) })
                let configuration = SliceConfiguration(standardSlices: (0..<standardCount).map {
                    $0 < Mode.generalModes.count ? .builtIn(Mode.generalModes[$0])
                        : .custom(CustomSlice(name: "Action \($0 + 1)", symbolName: "circle"))
                }, applications: [app])
                let dial = configuration.resolved(for: app.bundleIdentifier)
                state = ModePickerState(dial: dial, application: app, selectedSliceID: dial.clockwiseSlices.first?.id)
            }
            state.isArmed = true
            wheel.update(state)
            wheel.updateDisplayOptions(reduceTransparency: CommandLine.arguments.contains("--reduce-transparency"),
                                       increasedContrast: CommandLine.arguments.contains("--increase-contrast"),
                                       reduceMotion: CommandLine.arguments.contains("--reduce-motion"))
            let size = wheel.menuLayout.presentationSize
            let scaled = min(size.width, 460)
            wheel.fitPresentation(to: NSSize(width: scaled, height: scaled))
            wheel.frame.origin = NSPoint(x: CGFloat(index) * 460 + (460 - scaled) / 2,
                                         y: (500 - scaled) / 2)
            background.addSubview(wheel)
            wheel.onHighlightSlice = { [weak wheel] id in state.selectSlice(id); wheel?.update(state) }
            wheel.onMove = { [weak wheel] steps in state.move(by: steps); wheel?.update(state) }
            wheel.onSelectSlice = { [weak wheel] id in state.selectSlice(id); wheel?.showConfirmation(state) }
            wheel.onConfirm = { [weak wheel] in wheel?.showConfirmation(state) }
            wheels.append(wheel)
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(wheels[0])
        NSApp.activate(ignoringOtherApps: true)
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate: NSApplicationDelegate = CommandLine.arguments.contains("--gallery") ? GalleryDelegate() : PreviewDelegate()
application.delegate = delegate
application.run()
