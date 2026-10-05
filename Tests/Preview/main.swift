import AppKit

// A hardware-free preview of the production UI/router. Never opens a HID
// device, changes saved modes, requests permissions, or posts system input.
enum Dial {
    enum ButtonState { case pressed, released }
    enum Rotation { case Clockwise(Int), CounterClockwise(Int) }
}

final class PreviewDelegate: NSObject, NSApplicationDelegate {
    let menu = RadialMenuController()
    var mode = Mode.lightroomCrop
    var profile: AppProfile? = .lightroom
    var status: NSStatusItem!
    lazy var input = DialInputCoordinator(currentMode: { [unowned self] in self.mode },
                                         currentProfile: { [unowned self] in self.profile },
                                         schedule: { _, _ in }) // Keep previews open for visual inspection.

    func applicationDidFinishLaunching(_ notification: Notification) {
        input.onPickerChanged = { [weak self] state in
            guard let self = self else { return }
            if let state = state { self.menu.show(state) }
            else { self.menu.dismiss() }
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

    @objc func quitPreview() { NSApp.terminate(nil) }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = PreviewDelegate()
application.delegate = delegate
application.run()
