import AppKit
import SwiftUI

// SwiftUI's public Shape API gives the glass renderer the actual contour,
// including app-specific extensions, rather than clipping a rounded rectangle.
@available(macOS 26.0, *)
private struct RadialGlassShape: Shape {
    let layout: RadialMenuLayout

    func path(in rect: CGRect) -> Path {
        var transform = CGAffineTransform(a: rect.width / layout.diameter, b: 0,
                                         c: 0, d: -rect.height / layout.diameter,
                                         tx: rect.minX, ty: rect.maxY)
        return Path(layout.outline.compatibleCGPath.copy(using: &transform)!)
    }
}

@available(macOS 26.0, *)
private struct RadialGlassBackground: View {
    let layout: RadialMenuLayout

    var body: some View {
        Color.clear
            .frame(width: layout.diameter, height: layout.diameter)
            // Leave tint, appearance and optical intensity to macOS.
            .glassEffect(.regular, in: RadialGlassShape(layout: layout))
            // Padding must be outside the effect, not inside its shape: this
            // preserves the wheel radius while expanding the render surface.
            .padding(RadialMenuLayout.effectPadding)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

@available(macOS 26.0, *)
private final class RadialGlassHost: NSHostingView<RadialGlassBackground> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

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
    var onPressHighlight: ((Mode) -> Void)?
    var onSelect: ((Mode) -> Void)?
    var onMove: ((Int) -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    var onMaterialChanged: ((Bool) -> Void)?

    private let material = NSVisualEffectView()
    private var glass: NSView?
    private let surface = RadialSurfaceView()
    var preferredAppearance: RadialMenuAppearance = .automatic {
        didSet { updateDisplayOptions() }
    }
    private(set) var isUsingLiquidGlass = false
    private var reduceMotion = false
    private let titleLabel = NSTextField(labelWithString: "Scroll")
    private let turnLabel = NSTextField(labelWithString: "Turn to choose")
    private let clickLabel = NSTextField(labelWithString: "Click to select")
    private let contextLabel = NSTextField(labelWithString: "LIGHTROOM")
    private let gestureLabel = NSTextField(labelWithString: "Turn • Click to select")
    private let confirmationIcon = DecorationImageView()
    private let appGroup = ModeGroupView()
    private let appIcon = DecorationImageView()
    private var buttons: [Mode: NSButton] = [:]
    private var tracking: NSTrackingArea?
    private var displayObserver: NSObjectProtocol?
    private var mouseDownMode: Mode?
    private var isArmed = false
    private(set) var isConfirming = false
    private(set) var menuLayout = RadialMenuLayout(profile: nil)

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
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
        addSubview(appGroup)
        appIcon.imageScaling = .scaleProportionallyDown
        appIcon.setAccessibilityElement(false)
        appGroup.addSubview(appIcon)

        for label in [titleLabel, turnLabel, clickLabel, contextLabel, gestureLabel] {
            label.alignment = .center
            label.isSelectable = false
            label.font = .systemFont(ofSize: 11)
            label.textColor = .labelColor
            addSubview(label)
        }
        titleLabel.textColor = .labelColor
        confirmationIcon.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        confirmationIcon.contentTintColor = .labelColor
        confirmationIcon.setAccessibilityElement(false)
        confirmationIcon.isHidden = true
        addSubview(confirmationIcon)
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
        setFrameSize(menuLayout.presentationSize)
        // Keep wheel-space coordinates unchanged. The negative bounds origin
        // provides a transparent margin without shifting icons or hit targets.
        setBoundsOrigin(NSPoint(x: -RadialMenuLayout.effectPadding, y: -RadialMenuLayout.effectPadding))
        let wheelFrame = NSRect(x: 0, y: 0, width: menuLayout.diameter, height: menuLayout.diameter)
        material.frame = wheelFrame
        surface.frame = wheelFrame
        surface.menuLayout = menuLayout
        appGroup.frame = wheelFrame
        appGroup.isHidden = menuLayout.profile == nil
        appGroup.setAccessibilityLabel("\(menuLayout.profile?.title ?? "App") modes")
        appGroup.setAccessibilityHelp(menuLayout.profile.map { "\($0.modes.count) modes available while \($0.title) is active" })
        if let profile = menuLayout.profile, let group = menuLayout.appGroupSegment {
            appIcon.image = applicationIcon(for: profile)
            let p = menuLayout.point(angle: group.angle, radius: group.iconRadius)
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
            button.contentTintColor = .labelColor
            (button.cell as? NSButtonCell)?.imageDimsWhenDisabled = false
            button.target = self
            button.action = #selector(selectIcon(_:))
            button.tag = Mode.allCases.firstIndex(of: mode)!
            let p = menuLayout.point(angle: segment.angle, radius: segment.iconRadius)
            // The three Lightroom children share a narrower arc as general
            // modes are added. Keep their native hit targets from overlapping.
            let targetSize: CGFloat = segment.innerRadius == 150 ? 44 : 50
            button.frame = NSRect(x: p.x - targetSize / 2, y: p.y - targetSize / 2,
                                  width: targetSize, height: targetSize)
            button.setAccessibilityRole(.radioButton)
            button.setAccessibilityLabel("\(mode.title) mode")
            button.toolTip = mode.usageHelp
            button.setAccessibilityHelp((menuLayout.profile?.modes.contains(mode) == true
                ? "\(menuLayout.profile!.title). \(mode.turnHint). \(mode.clickHint). Turn to choose; click to select."
                : "Select \(mode.title) for the Surface Dial")
                    + (mode.usageHelp.map { " " + $0 } ?? ""))
            if menuLayout.profile?.modes.contains(mode) == true { appGroup.addSubview(button) }
            else { addSubview(button) }
            buttons[mode] = button
        }
        let mask = CAShapeLayer()
        mask.path = menuLayout.outline.compatibleCGPath
        material.layer?.mask = mask
        updateGlassLayout()
    }

    private func updateGlassLayout() {
        if #available(macOS 26.0, *), let host = glass as? RadialGlassHost {
            host.rootView = RadialGlassBackground(layout: menuLayout)
            host.frame = bounds
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateMaterialAppearance()
        surface.needsDisplay = true
    }

    private func updateMaterialAppearance() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        material.material = dark ? .hudWindow : .popover
        // Applying alpha resolves a semantic NSColor. Resolve under this view's
        // current appearance, and refresh when it changes, not at initialization.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for label in [turnLabel, clickLabel, contextLabel, gestureLabel] {
                label.textColor = NSColor.labelColor.withAlphaComponent(0.82)
            }
        }
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
        if profile == .editwall {
            candidates.append(URL(fileURLWithPath: "/Applications/Edit Wall.app"))
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
        if isConfirming { mouseDownMode = nil }
        isConfirming = false
        surface.isConfirming = false
        surface.decorationOpacity = 1
        confirmationIcon.isHidden = true
        appIcon.alphaValue = 1
        turnLabel.isHidden = false
        clickLabel.isHidden = false
        let profileChanged = menuLayout.profile != state.profile
        if profileChanged {
            menuLayout = RadialMenuLayout(profile: state.profile)
            rebuildControls()
        }
        let changed = surface.selectedMode != state.selectedMode
        surface.select(state.selectedMode, animated: !profileChanged && !reduceMotion
                       && isArmed && window?.isVisible == true)
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
            clickLabel.stringValue = state.isArmed ? "Press to select" : "Esc to cancel"
        }
        for (mode, button) in buttons {
            button.contentTintColor = .labelColor
            button.alphaValue = mode == state.selectedMode ? 1 : 0.78
            button.setAccessibilityValue(mode == state.selectedMode ? 1 : 0)
            button.isEnabled = state.isArmed
        }
        if changed { NSAccessibility.post(element: self, notification: .selectedChildrenChanged) }
    }

    func showConfirmation(_ state: ModePickerState) {
        update(state)
        finishSelectionAnimation()
        isConfirming = true
        mouseDownMode = nil
        isArmed = false
        surface.isConfirming = true
        buttons.values.forEach { $0.isEnabled = false }
        buttons[state.selectedMode]?.contentTintColor = .white
        let c = menuLayout.center
        titleLabel.frame.origin.y = c.y + 2
        contextLabel.isHidden = true
        gestureLabel.isHidden = true
        clickLabel.isHidden = true
        turnLabel.stringValue = "Selected"
        turnLabel.frame = NSRect(x: c.x - 18, y: c.y - 22, width: 58, height: 18)
        confirmationIcon.frame = NSRect(x: c.x - 36, y: c.y - 20, width: 14, height: 14)
        confirmationIcon.isHidden = false
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: "\(state.selectedMode.title) selected",
            .priority: NSAccessibilityPriorityLevel.high.rawValue
        ])
    }

    // The controller supplies progress so cancelled animations cannot alter a reopened menu.
    func setConfirmationProgress(_ progress: CGFloat) {
        guard isConfirming else { return }
        let opacity = 1 - max(0, min(1, progress))
        surface.decorationOpacity = opacity
        appIcon.alphaValue = opacity
        for (mode, button) in buttons {
            button.alphaValue = mode == surface.selectedMode ? 1 : 0.78 * opacity
        }
    }

    func finishSelectionAnimation() { surface.finishSelectionAnimation() }

    func updateDisplayOptions(reduceTransparency: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                              increasedContrast: Bool = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
                              reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        self.reduceMotion = reduceMotion
        if reduceMotion { finishSelectionAnimation() }
        let previouslyUsingGlass = isUsingLiquidGlass
        isUsingLiquidGlass = preferredAppearance.usesLiquidGlass() && !reduceTransparency
        if #available(macOS 26.0, *), isUsingLiquidGlass, glass == nil {
            let host = RadialGlassHost(rootView: RadialGlassBackground(layout: menuLayout))
            host.sizingOptions = []
            host.setAccessibilityElement(false)
            glass = host
            addSubview(host, positioned: .below, relativeTo: surface)
            updateGlassLayout()
        }
        glass?.isHidden = !isUsingLiquidGlass
        material.isHidden = reduceTransparency || isUsingLiquidGlass
        surface.usesGlass = isUsingLiquidGlass
        surface.reduceTransparency = reduceTransparency
        surface.increasedContrast = increasedContrast
        updateMaterialAppearance()
        if previouslyUsingGlass != isUsingLiquidGlass { onMaterialChanged?(isUsingLiquidGlass) }
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
        guard !isConfirming else { return }
        let point = convert(event.locationInWindow, from: nil)
        mouseDownMode = isArmed ? menuLayout.mode(at: point) : nil
        if let mode = mouseDownMode { onPressHighlight?(mode) }
        else if !menuLayout.outline.contains(point) { onCancel?() }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownMode = nil }
        if isArmed, let mode = mouseDownMode,
           menuLayout.mode(at: convert(event.locationInWindow, from: nil)) == mode { onSelect?(mode) }
    }

    override func keyDown(with event: NSEvent) {
        guard !isConfirming else { return }
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
    private(set) var selectedMode: Mode = .scrolling
    private var selectionWeights: [Mode: CGFloat] = [.scrolling: 1]
    private var selectionTimer: Timer?
    var usesGlass = false { didSet { needsDisplay = true } }

    deinit { selectionTimer?.invalidate() }

    func select(_ mode: Mode, animated: Bool) {
        guard mode != selectedMode else { return }
        let initialWeights = selectionWeights
        selectedMode = mode
        selectionTimer?.invalidate()
        guard animated else { finishSelectionAnimation(); return }
        let start = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let t = min(1, (ProcessInfo.processInfo.systemUptime - start) / 0.1)
            let progress = CGFloat(t * t * (3 - 2 * t))
            self.selectionWeights = initialWeights.mapValues { $0 * (1 - progress) }
            self.selectionWeights[mode, default: 0] += progress
            self.needsDisplay = true
            if t >= 1 { self.finishSelectionAnimation() }
        }
        selectionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func finishSelectionAnimation() {
        selectionTimer?.invalidate()
        selectionTimer = nil
        selectionWeights = [selectedMode: 1]
        needsDisplay = true
    }
    var increasedContrast = false { didSet { needsDisplay = true } }
    var reduceTransparency = false { didSet { needsDisplay = true } }
    var isConfirming = false { didSet { needsDisplay = true } }
    var decorationOpacity: CGFloat = 1 { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let layout = menuLayout
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        layout.outline.addClip()
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let foreground = NSColor.labelColor
        if reduceTransparency {
            NSColor.windowBackgroundColor.setFill()
            layout.outline.fill()
        } else if !usesGlass {
            (dark ? NSColor.black : NSColor.white).withAlphaComponent(0.24).setFill()
            layout.outline.fill()
        }
        for segment in layout.segments {
            if let mode = segment.mode, let weight = selectionWeights[mode], weight > 0 {
                (isConfirming ? NSColor.systemBlue.withAlphaComponent(weight)
                 : foreground.withAlphaComponent((increasedContrast ? 0.24 : 0.10) * weight)).setFill()
                layout.path(for: segment).fill()
            } else if segment.mode == nil && layout.profile?.modes.contains(selectedMode) == true {
                NSColor.systemBlue.withAlphaComponent((increasedContrast ? 0.24 : 0.12) * decorationOpacity).setFill()
                layout.path(for: segment).fill()
            }
        }

        foreground.withAlphaComponent(increasedContrast ? 0.55 : 0.10).setStroke()
        if layout.profile == nil {
            let border = NSBezierPath(ovalIn: layout.coreFrame.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
            foreground.withAlphaComponent((increasedContrast ? 0.55 : 0.10) * decorationOpacity).setStroke()
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
                foreground.withAlphaComponent((increasedContrast ? 0.55 : 0.10)
                    * (segment.mode == selectedMode ? 1 : decorationOpacity)).setStroke()
                let path = layout.path(for: segment)
                path.lineWidth = 0.5
                path.stroke()
            }
        }
        let middle = NSBezierPath(ovalIn: NSRect(x: layout.center.x - 72, y: layout.center.y - 72, width: 144, height: 144))
        foreground.withAlphaComponent(increasedContrast ? 0.55 : 0.10).setStroke()
        (usesGlass ? NSColor.windowBackgroundColor.withAlphaComponent(0.28)
         : (dark ? NSColor.black : NSColor.white).withAlphaComponent(0.20)).setFill()
        middle.fill()
        middle.lineWidth = 0.5
        middle.stroke()

        for (mode, weight) in selectionWeights where weight > 0 {
            guard let segment = layout.segment(for: mode) else { continue }
            let arc = NSBezierPath()
            arc.appendArc(withCenter: layout.center, radius: segment.outerRadius - 2.5,
                          startAngle: segment.angle + segment.sweep / 2 - 1.5,
                          endAngle: segment.angle - segment.sweep / 2 + 1.5, clockwise: true)
            arc.lineWidth = 4
            arc.lineCapStyle = .round
            NSColor.systemBlue.withAlphaComponent(weight).setStroke()
            arc.stroke()
        }
    }
}
