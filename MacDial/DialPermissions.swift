import AppKit
import ApplicationServices

// Permission is based on the running process, not the switch displayed by
// System Settings. Checks never prompt; requesting access is a user action.
final class DialPermissions {
    private let accessibility: () -> Bool
    private let eventPosting: () -> Bool
    private var lastResult: Bool?
    var onChange: ((Bool) -> Void)?
    var isGranted: Bool { lastResult == true }

    init(accessibility: @escaping () -> Bool = { AXIsProcessTrusted() },
         eventPosting: @escaping () -> Bool = { CGPreflightPostEventAccess() }) {
        self.accessibility = accessibility
        self.eventPosting = eventPosting
    }

    @discardableResult
    func refresh() -> Bool {
        let granted = accessibility() && eventPosting()
        if lastResult != granted {
            lastResult = granted
            onChange?(granted)
        }
        return granted
    }

    static func openSettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

final class DialPermissionWindow: NSWindowController {
    private let check: () -> Bool
    private let openSettings: () -> Void
    private let status = NSTextField(wrappingLabelWithString: "Dial actions are paused until macOS grants access.")

    init(check: @escaping () -> Bool, openSettings: @escaping () -> Void = DialPermissions.openSettings) {
        self.check = check
        self.openSettings = openSettings
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Mac Dial — Permission Required"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
        let content = window.contentView!
        func label(_ text: String, font: NSFont, y: CGFloat, height: CGFloat) {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = font
            label.frame = NSRect(x: 28, y: y, width: 494, height: height)
            content.addSubview(label)
        }
        label("Allow Mac Dial to control your Mac", font: .systemFont(ofSize: 22, weight: .semibold), y: 352, height: 36)
        status.font = .systemFont(ofSize: 13)
        status.frame = NSRect(x: 28, y: 300, width: 494, height: 44)
        content.addSubview(status)
        label("Open Privacy & Security and enable Mac Dial under Device Control and Data Access (called Accessibility on earlier macOS versions). You can still customize your dial while actions are paused.",
              font: .systemFont(ofSize: 13), y: 222, height: 68)
        label("Already enabled, but the dial still doesn’t work?", font: .systemFont(ofSize: 13, weight: .semibold), y: 186, height: 24)
        label("1. Remove Mac Dial from that permission list.\n2. Quit and reopen this copy of Mac Dial.\n3. Open Privacy Settings here and enable Mac Dial again.\n\nA rebuilt or replaced app can leave an old permission entry. Turning its switch off and on may not repair it.",
              font: .systemFont(ofSize: 13), y: 62, height: 118)
        let settings = NSButton(title: "Open Privacy Settings…", target: self, action: #selector(openPrivacySettings))
        settings.bezelStyle = .rounded
        settings.keyEquivalent = "\r"
        settings.frame = NSRect(x: 322, y: 18, width: 204, height: 32)
        content.addSubview(settings)
        let retry = NSButton(title: "Check Again", target: self, action: #selector(checkAgain))
        retry.bezelStyle = .rounded
        retry.frame = NSRect(x: 188, y: 18, width: 126, height: 32)
        content.addSubview(retry)
        let quit = NSButton(title: "Quit Mac Dial", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .rounded
        quit.frame = NSRect(x: 22, y: 18, width: 138, height: 32)
        content.addSubview(quit)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        status.stringValue = "Dial actions are paused until macOS grants access."
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openPrivacySettings() { openSettings() }
    @objc private func checkAgain() {
        if check() { close() }
        else { status.stringValue = "macOS still denies access to this copy of Mac Dial. Actions remain paused. If the switch is already on, follow the steps below." }
    }
}
