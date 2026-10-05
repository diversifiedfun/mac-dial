import AppKit

private final class ModeIconButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }
}

private final class DecorationImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class ModeGroupView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

final class RadialMenuView: NSView {
    var onHighlight: ((Mode) -> Void)?
    var onSelect: ((Mode) -> Void)?
    var onMove: ((Int) -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    private let material = NSVisualEffectView()
    private let surface = RadialSurfaceView()
    private let titleLabel = NSTextField(labelWithString: "Scroll")
    private let turnLabel = NSTextField(labelWithString: "Turn to choose")
    private let clickLabel = NSTextField(labelWithString: "Click to select")
    private let contextLabel = NSTextField(labelWithString: "LIGHTROOM")
    private let gestureLabel = NSTextField(labelWithString: "Turn • Click to select")
    private let appGroup = ModeGroupView()
    private let appIcon = DecorationImageView()
    private var buttons: [Mode: NSButton] = [:]
    private var tracking: NSTrackingArea?
    private var displayObserver: NSObjectProtocol?
    private var mouseDownMode: Mode?
    private var isArmed = false
    private(set) var menuLayout = RadialMenuLayout(profile: nil)

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        appearance = NSAppearance(named: .vibrantDark)
        setAccessibilityElement(false)
        setAccessibilityLabel("Mac Dial modes")

        material.wantsLayer = true
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        addSubview(material)
        addSubview(surface)

        appGroup.setAccessibilityElement(true)
        appGroup.setAccessibilityRole(.group)
        appGroup.setAccessibilityLabel("Lightroom modes")
        appGroup.setAccessibilityHelp("Three modes available while Lightroom Classic is active")
        addSubview(appGroup)
        appIcon.imageScaling = .scaleProportionallyDown
        appIcon.setAccessibilityElement(false)
        appGroup.addSubview(appIcon)

        for label in [titleLabel, turnLabel, clickLabel, contextLabel, gestureLabel] {
            label.alignment = .center
            label.isSelectable = false
            label.font = .systemFont(ofSize: 11)
            label.textColor = NSColor.white.withAlphaComponent(0.72)
            addSubview(label)
        }
        titleLabel.textColor = .white
        contextLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        gestureLabel.font = .systemFont(ofSize: 10)
        rebuildControls()
        update(ModePickerState(selectedMode: .scrolling))
        displayObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.updateDisplayOptions() }
        updateDisplayOptions()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let observer = displayObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    private func rebuildControls() {
        mouseDownMode = nil
        buttons.values.forEach { $0.removeFromSuperview() }
        buttons.removeAll()
        setFrameSize(NSSize(width: menuLayout.diameter, height: menuLayout.diameter))
        material.frame = bounds
        surface.frame = bounds
        surface.menuLayout = menuLayout
        appGroup.frame = bounds
        appGroup.isHidden = menuLayout.profile == nil
        appGroup.setAccessibilityLabel("\(menuLayout.profile?.title ?? "App") modes")
        if let profile = menuLayout.profile {
            appIcon.image = applicationIcon(for: profile)
            let p = menuLayout.point(angle: 180, radius: 111)
            appIcon.frame = NSRect(x: p.x - 21, y: p.y - 21, width: 42, height: 42)
        }
        for segment in menuLayout.segments {
            guard let mode = segment.mode else { continue }
            let button = ModeIconButton()
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.image = NSImage(systemSymbolName: mode.symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 28, weight: .regular))
            button.contentTintColor = .white
            button.target = self
            button.action = #selector(selectIcon(_:))
            button.tag = Mode.allCases.firstIndex(of: mode)!
            let p = menuLayout.point(angle: segment.angle, radius: segment.iconRadius)
            button.frame = NSRect(x: p.x - 25, y: p.y - 25, width: 50, height: 50)
            button.setAccessibilityRole(.radioButton)
            button.setAccessibilityLabel("\(mode.title) mode")
            button.toolTip = mode.usageHelp
            button.setAccessibilityHelp(mode.isLightroom
                ? "Lightroom. \(mode.turnHint). \(mode.clickHint). Turn to choose; click to select."
                    + (mode.usageHelp.map { " " + $0 } ?? "")
                : "Select \(mode.title) for the Surface Dial")
            if menuLayout.profile?.modes.contains(mode) == true { appGroup.addSubview(button) }
            else { addSubview(button) }
            buttons[mode] = button
        }
        let mask = CAShapeLayer()
        mask.path = menuLayout.outline.compatibleCGPath
        material.layer?.mask = mask
    }

    private func applicationIcon(for profile: AppProfile) -> NSImage? {
        var candidates = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == profile.bundleIdentifier }.compactMap(\.bundleURL)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: profile.bundleIdentifier) {
            candidates.append(url)
        }
        // Launch Services lookup can be unavailable in offscreen inspection.
        if profile == .lightroom {
            candidates.append(URL(fileURLWithPath: "/Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app"))
        }
        for url in candidates {
            guard let bundle = Bundle(url: url), bundle.bundleIdentifier == profile.bundleIdentifier,
                  let name = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
                  let resources = bundle.resourceURL else { continue }
            let filename = (name as NSString).pathExtension.isEmpty ? name + ".icns" : name
            if let icon = NSImage(contentsOf: resources.appendingPathComponent(filename)) { return icon }
        }
        return NSImage(systemSymbolName: "app", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 32, weight: .regular))
    }

    func update(_ state: ModePickerState) {
        if menuLayout.profile != state.profile {
            menuLayout = RadialMenuLayout(profile: state.profile)
            rebuildControls()
        }
        let changed = surface.selectedMode != state.selectedMode
        surface.selectedMode = state.selectedMode
        isArmed = state.isArmed
        titleLabel.stringValue = state.selectedMode.title
        let c = menuLayout.center
        let appMode = state.profile?.modes.contains(state.selectedMode) == true
        contextLabel.isHidden = !appMode
        gestureLabel.isHidden = !appMode
        if appMode {
            contextLabel.stringValue = state.profile!.title.uppercased()
            contextLabel.frame = NSRect(x: c.x - 60, y: c.y + 34, width: 120, height: 14)
            titleLabel.font = .systemFont(ofSize: 16, weight: .medium)
            titleLabel.frame = NSRect(x: c.x - 68, y: c.y + 10, width: 136, height: 24)
            turnLabel.frame = NSRect(x: c.x - 68, y: c.y - 12, width: 136, height: 18)
            clickLabel.frame = NSRect(x: c.x - 68, y: c.y - 29, width: 136, height: 18)
            gestureLabel.frame = NSRect(x: c.x - 62, y: c.y - 49, width: 124, height: 16)
            turnLabel.stringValue = state.selectedMode.turnHint
            clickLabel.stringValue = state.selectedMode.clickHint
            gestureLabel.stringValue = state.isArmed ? "Turn • Click to select" : "Release to choose"
        } else {
            titleLabel.font = .systemFont(ofSize: 21, weight: .medium)
            titleLabel.frame = NSRect(x: c.x - 80, y: c.y - 2, width: 160, height: 28)
            turnLabel.frame = NSRect(x: c.x - 74, y: c.y - 22, width: 148, height: 18)
            clickLabel.frame = NSRect(x: c.x - 74, y: c.y - 39, width: 148, height: 18)
            turnLabel.stringValue = state.isArmed ? "Turn to choose" : "Release to choose"
            clickLabel.stringValue = state.isArmed ? "Click to select" : "Hold again to cancel"
        }
        for (mode, button) in buttons {
            button.alphaValue = mode == state.selectedMode ? 1 : 0.78
            button.setAccessibilityValue(mode == state.selectedMode ? 1 : 0)
            button.isEnabled = state.isArmed
        }
        if changed { NSAccessibility.post(element: self, notification: .selectedChildrenChanged) }
    }

    func updateDisplayOptions(reduceTransparency: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                              increasedContrast: Bool = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast) {
        material.isHidden = reduceTransparency
        surface.reduceTransparency = reduceTransparency
        surface.increasedContrast = increasedContrast
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking = tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard isArmed else { return }
        if let mode = menuLayout.mode(at: convert(event.locationInWindow, from: nil)) { onHighlight?(mode) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseDownMode = isArmed ? menuLayout.mode(at: point) : nil
        if let mode = mouseDownMode { onHighlight?(mode) }
        else if !menuLayout.outline.contains(point) { onCancel?() }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownMode = nil }
        if isArmed, let mode = mouseDownMode,
           menuLayout.mode(at: convert(event.locationInWindow, from: nil)) == mode { onSelect?(mode) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }
        guard isArmed else { return }
        switch event.keyCode {
        case 123, 126: onMove?(-1)
        case 124, 125: onMove?(1)
        case 36, 76: onConfirm?()
        default: break
        }
    }

    @objc private func selectIcon(_ sender: NSButton) {
        guard isArmed, sender.isEnabled else { return }
        onSelect?(Mode.allCases[sender.tag])
    }
}

private final class RadialSurfaceView: NSView {
    var menuLayout = RadialMenuLayout(profile: nil) { didSet { needsDisplay = true } }
    var selectedMode: Mode = .scrolling { didSet { needsDisplay = true } }
    var increasedContrast = false { didSet { needsDisplay = true } }
    var reduceTransparency = false { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let layout = menuLayout
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        layout.outline.addClip()
        (reduceTransparency ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor.black.withAlphaComponent(0.24)).setFill()
        layout.outline.fill()
        for segment in layout.segments {
            if segment.mode == selectedMode {
                NSColor.white.withAlphaComponent(increasedContrast ? 0.24 : 0.10).setFill()
                layout.path(for: segment).fill()
            } else if segment.mode == nil && layout.profile?.modes.contains(selectedMode) == true {
                NSColor.systemBlue.withAlphaComponent(increasedContrast ? 0.24 : 0.12).setFill()
                layout.path(for: segment).fill()
            }
        }

        NSColor.white.withAlphaComponent(increasedContrast ? 0.45 : 0.10).setStroke()
        if layout.profile == nil {
            let border = NSBezierPath(ovalIn: layout.coreFrame.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
            for segment in layout.segments {
                let angle = segment.angle + segment.sweep / 2
                let line = NSBezierPath()
                line.move(to: layout.point(angle: angle, radius: 72))
                line.line(to: layout.point(angle: angle, radius: 146))
                line.lineWidth = 0.5
                line.stroke()
            }
        } else {
            let outline = layout.outline
            outline.lineWidth = 1
            outline.stroke()
            for segment in layout.segments {
                let path = layout.path(for: segment)
                path.lineWidth = 0.5
                path.stroke()
            }
        }
        let middle = NSBezierPath(ovalIn: NSRect(x: layout.center.x - 72, y: layout.center.y - 72, width: 144, height: 144))
        NSColor.black.withAlphaComponent(0.20).setFill()
        middle.fill()
        middle.lineWidth = 0.5
        middle.stroke()

        if let segment = layout.segment(for: selectedMode) {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: layout.center, radius: segment.outerRadius - 2.5,
                          startAngle: segment.angle + segment.sweep / 2 - 1.5,
                          endAngle: segment.angle - segment.sweep / 2 + 1.5, clockwise: true)
            arc.lineWidth = 4
            arc.lineCapStyle = .round
            NSColor.systemBlue.setStroke()
            arc.stroke()
        }
    }
}
