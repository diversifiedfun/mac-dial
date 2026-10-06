import AppKit
import Carbon

// Small native controls shared by the settings window and its sheets.
final class CustomizationButton: NSButton {
    var invoke: (() -> Void)?
    convenience init(_ title: String, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        self.action = #selector(run)
        invoke = action
    }
    @objc private func run() { invoke?() }
}

final class CustomizationSwitch: NSSwitch {
    var invoke: ((Bool) -> Void)?
    init(enabled: Bool, label: String, action: @escaping (Bool) -> Void) {
        super.init(frame: .zero)
        state = enabled ? .on : .off
        setAccessibilityLabel(label)
        target = self
        self.action = #selector(run)
        invoke = action
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func run() { invoke?(state == .on) }
}

func customizationLabel(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                        secondary: Bool = false) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = secondary ? .secondaryLabelColor : .labelColor
    return label
}

func customizationSymbol(_ name: String) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)
        ?? NSImage(systemSymbolName: "star", accessibilityDescription: nil)
}

struct DiscoveredDialApplication {
    let id: String
    let name: String
    let url: URL
    var running: Bool

    static func read(_ url: URL, running: Bool = false) -> Self? {
        guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url),
              let id = bundle.bundleIdentifier, !id.isEmpty else { return nil }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        return Self(id: id, name: name, url: url, running: running)
    }

    var configuration: ApplicationConfiguration {
        ApplicationConfiguration(bundleIdentifier: id, displayName: name, applicationURL: url)
    }

    static func merged(_ values: [Self]) -> [Self] {
        var apps: [String: Self] = [:]
        for app in values {
            if apps[app.id] == nil || app.running { apps[app.id] = app }
        }
        return apps.values.sorted {
            if $0.running != $1.running { return $0.running }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    static func discover(completion: @escaping ([Self]) -> Void) {
        let running = NSWorkspace.shared.runningApplications.compactMap { app in
            app.bundleURL.flatMap { read($0, running: true) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var results = running
            let roots = [URL(fileURLWithPath: "/Applications"),
                         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
                         URL(fileURLWithPath: "/System/Applications"),
                         URL(fileURLWithPath: "/System/Library/CoreServices/Applications")]
            for root in roots {
                guard let paths = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let url as URL in paths where url.pathExtension.lowercased() == "app" {
                    if let app = read(url) { results.append(app) }
                }
            }
            let merged = merged(results)
            DispatchQueue.main.async { completion(merged) }
        }
    }
}

// Curated bundled SF Symbols catalog. Availability is checked on the running OS.
struct DialSymbolCatalog {
    static let categories: [(String, String)] = [
        ("Favorites", "star star.fill heart heart.fill bookmark flag pin tag checkmark seal"),
        ("Navigation", "arrow.left arrow.right arrow.up arrow.down arrow.up.arrow.down arrow.left.arrow.right arrow.uturn.backward arrow.uturn.forward arrow.clockwise arrow.counterclockwise chevron.left chevron.right location map compass"),
        ("Editing", "pencil pencil.tip paintbrush paintbrush.pointed crop slider.horizontal.3 wand.and.stars scissors eyedropper eraser lasso selection.pin.in.out plus.magnifyingglass minus.magnifyingglass magnifyingglass textformat bold italic underline"),
        ("Media", "play pause stop backward forward backward.end forward.end speaker speaker.wave.2 speaker.slash mic music.note headphones camera photo film video record.circle"),
        ("Workspace", "folder doc doc.text doc.on.doc clipboard tray archivebox trash square.and.arrow.up square.and.arrow.down printer terminal keyboard command option control shift return escape space"),
        ("Controls", "gearshape sun.max moon circle square triangle diamond hexagon bolt lightbulb lock lock.open eye eye.slash bell clock timer calendar person person.2 globe link wifi display desktopcomputer laptopcomputer rectangle.stack rectangle.split.2x2")
    ]
    static var entries: [(name: String, category: String)] {
        categories.flatMap { category, names in
            names.split(separator: " ").map(String.init).filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
                .map { (name: $0, category: category) }
        }
    }
}

extension KeyboardShortcut {
    var displayName: String {
        var prefix = ""
        if modifiers.contains(.control) { prefix += "⌃" }
        if modifiers.contains(.option) { prefix += "⌥" }
        if modifiers.contains(.shift) { prefix += "⇧" }
        if modifiers.contains(.command) { prefix += "⌘" }
        let special: [UInt16: String] = [36:"Return", 48:"Tab", 49:"Space", 51:"Delete", 53:"Escape", 76:"Enter",
            114:"Help", 115:"Home", 116:"Page Up", 117:"Forward Delete", 119:"End", 121:"Page Down",
            123:"←", 124:"→", 125:"↓", 126:"↑",
            122:"F1", 120:"F2", 99:"F3", 118:"F4", 96:"F5", 97:"F6", 98:"F7", 100:"F8", 101:"F9", 109:"F10", 103:"F11", 111:"F12", 105:"F13", 107:"F14", 113:"F15", 106:"F16", 64:"F17", 79:"F18", 80:"F19", 90:"F20"]
        if let name = special[keyCode] { return prefix + name }
        if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
            let layout = UnsafeRawPointer(CFDataGetBytePtr(data)).assumingMemoryBound(to: UCKeyboardLayout.self)
            var dead: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 8)
            if UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, chars.count, &length, &chars) == noErr, length > 0 {
                return prefix + String(utf16CodeUnits: chars, count: length).uppercased()
            }
        }
        return prefix + "Key \(keyCode)"
    }

    static func recorded(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> KeyboardShortcut? {
        guard keyCode != 53 else { return nil } // Escape belongs to the recorder.
        var modifiers: ShortcutModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        let shortcut = KeyboardShortcut(keyCode: keyCode, modifiers: modifiers)
        return shortcut.isValid ? shortcut : nil
    }
}

// Captures locally before menu key equivalents are dispatched. No CGEvent posting.
final class DialShortcutRecorder: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private var monitor: Any?
    private var completion: ((KeyboardShortcut?) -> Void)?
    private var resignObserver: NSObjectProtocol?

    init(parent: NSWindow, gesture: String, completion: @escaping (KeyboardShortcut?) -> Void) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 450, height: 190), styleMask: [.titled], backing: .buffered, defer: false)
        self.completion = completion
        super.init()
        panel.title = "Record Shortcut"
        let label = customizationLabel("Press a shortcut for \(gesture.lowercased()).", size: 17, weight: .semibold)
        label.frame = NSRect(x: 24, y: 115, width: 402, height: 45)
        let detail = customizationLabel("Use one key with optional ⌘ ⌥ ⌃ ⇧ modifiers.\nEscape cancels. Media keys are not supported.", secondary: true)
        detail.frame = NSRect(x: 24, y: 58, width: 402, height: 48)
        let cancel = CustomizationButton("Cancel") { [weak self] in self?.finish(nil) }
        cancel.frame = NSRect(x: 330, y: 16, width: 96, height: 28)
        panel.contentView?.addSubview(label)
        panel.contentView?.addSubview(detail)
        panel.contentView?.addSubview(cancel)
        parent.beginSheet(panel)
        panel.makeKey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self, self.panel.isKeyWindow else { return event }
            if event.keyCode == 53 { self.finish(nil) }
            else if !event.isARepeat, let shortcut = KeyboardShortcut.recorded(keyCode: event.keyCode, flags: event.modifierFlags) {
                self.finish(shortcut)
            }
            return nil
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in self?.finish(nil) }
    }

    func finish(_ shortcut: KeyboardShortcut?) {
        guard let completion = completion else { return }
        self.completion = nil
        if let monitor = monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let observer = resignObserver { NotificationCenter.default.removeObserver(observer); resignObserver = nil }
        panel.sheetParent?.endSheet(panel)
        panel.orderOut(nil)
        completion(shortcut)
    }
    deinit {
        if let monitor = monitor { NSEvent.removeMonitor(monitor) }
        if let observer = resignObserver { NotificationCenter.default.removeObserver(observer) }
    }
}

final class DialChoiceSheet: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    struct Choice { let id: String; let title: String; let detail: String; let image: NSImage? }
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 530), styleMask: [.titled], backing: .buffered, defer: false)
    let search = NSSearchField()
    let table = NSTableView()
    var choices: [Choice] = [] { didSet { filter() } }
    private var filtered: [Choice] = []
    private var choose: ((String) -> Void)?
    private var add: CustomizationButton!
    private let status = customizationLabel("", secondary: true)
    var browse: (() -> Void)?
    func showLoading() { status.stringValue = "Searching applications…" }
    init(parent: NSWindow, title: String, placeholder: String, browse: (() -> Void)? = nil, choose: @escaping (String) -> Void) {
        self.choose = choose
        self.browse = browse
        super.init()
        panel.title = title
        search.frame = NSRect(x: 20, y: 474, width: 440, height: 30)
        search.placeholderString = placeholder
        search.delegate = self
        table.addTableColumn(NSTableColumn(identifier: .init("choice")))
        table.headerView = nil
        table.rowHeight = 52
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(accept)
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 90, width: 440, height: 370))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        status.frame = NSRect(x: 20, y: 56, width: 440, height: 28)
        let cancel = CustomizationButton("Cancel") { [weak self] in self?.close() }
        cancel.frame = NSRect(x: 265, y: 16, width: 90, height: 28)
        cancel.keyEquivalent = "\u{1b}"
        add = CustomizationButton("Choose") { [weak self] in self?.accept() }
        add.frame = NSRect(x: 360, y: 16, width: 100, height: 28)
        add.keyEquivalent = "\r"
        for view in [search, scroll, status, cancel, add!] { panel.contentView?.addSubview(view) }
        if browse != nil {
            let button = CustomizationButton("Browse…") { [weak self] in self?.browse?() }
            button.frame = NSRect(x: 20, y: 16, width: 100, height: 28)
            panel.contentView?.addSubview(button)
        }
        filter()
        parent.beginSheet(panel)
        panel.makeFirstResponder(search)
    }
    func close() { panel.sheetParent?.endSheet(panel); panel.orderOut(nil) }
    private func filter() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = choices.filter { query.isEmpty || ($0.title + " " + $0.detail + " " + $0.id).localizedCaseInsensitiveContains(query) }
        table.reloadData()
        if !filtered.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        status.stringValue = filtered.isEmpty ? "No matches. Try another search." : "\(filtered.count) available"
        add?.isEnabled = !filtered.isEmpty
    }
    func controlTextDidChange(_ obj: Notification) { filter() }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableViewSelectionDidChange(_ notification: Notification) { add.isEnabled = table.selectedRow >= 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let choice = filtered[row]
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 52))
        let icon = NSImageView(frame: NSRect(x: 10, y: 10, width: 30, height: 30))
        icon.image = choice.image
        let title = customizationLabel(choice.title, weight: .medium)
        title.frame = NSRect(x: 52, y: 26, width: 355, height: 20)
        let detail = customizationLabel(choice.detail, size: 11, secondary: true)
        detail.frame = NSRect(x: 52, y: 6, width: 355, height: 18)
        view.addSubview(icon); view.addSubview(title); view.addSubview(detail)
        return view
    }
    @objc private func accept() {
        guard filtered.indices.contains(table.selectedRow) else { return }
        let id = filtered[table.selectedRow].id
        close()
        choose?(id)
    }
}
