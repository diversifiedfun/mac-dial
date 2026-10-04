import AppKit

// A hardware-free preview of the production UI/router. Never opens a HID
// device, changes saved modes, requests permissions, or posts system input.
enum Dial {
    enum ButtonState { case pressed, released }
    enum Rotation { case Clockwise(Int), CounterClockwise(Int) }
}

final class PreviewDelegate: NSObject, NSApplicationDelegate {
    let menu = RadialMenuController()
    var mode = Mode.scrolling
    var status: NSStatusItem!
    lazy var input = DialInputCoordinator(currentMode: { [unowned self] in self.mode },
                                         schedule: { _, _ in }) // Keep previews open for visual inspection.

    func applicationDidFinishLaunching(_ notification: Notification) {
        input.onPickerChanged = { [weak self] state in
            guard let self = self else { return }
            if let state = state { self.menu.show(state) }
            else { self.menu.dismiss() }
        }
        input.onCommit = { [weak self] mode in
            self?.mode = mode
            self?.status.button?.title = "Preview: \(mode.title)"
            print("Selected \(mode.title)")
        }
        menu.view.onHighlight = { [weak self] in self?.input.highlight($0) }
        menu.view.onSelect = { [weak self] mode in
            self?.input.highlight(mode)
            self?.input.confirmSelection()
        }
        menu.view.onMove = { [weak self] in self?.input.moveSelection(by: $0) }
        menu.view.onConfirm = { [weak self] in self?.input.confirmSelection() }
        menu.view.onCancel = { [weak self] in self?.input.cancel() }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "Dial Preview"
        let actions = NSMenu()
        for mode in Mode.allCases {
            let item = NSMenuItem(title: "Preview \(mode.title)", action: #selector(openMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            actions.addItem(item)
        }
        actions.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Preview", action: #selector(quitPreview), keyEquivalent: "q")
        quit.target = self
        actions.addItem(quit)
        status.menu = actions
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.open() }
    }

    func open() {
        input.cancel()
        input.handle(button: .pressed, rotation: nil, sensitivity: 36, scrollDirection: -1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            self.input.handle(button: .released, rotation: nil, sensitivity: 36, scrollDirection: -1)
        }
    }

    @objc func openMode(_ sender: NSMenuItem) {
        mode = sender.representedObject as! Mode
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
