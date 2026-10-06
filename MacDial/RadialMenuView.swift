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
    var onHighlightSlice: ((SliceID) -> Void)?
    var onPressHighlightSlice: ((SliceID) -> Void)?
    var onSelectSlice: ((SliceID) -> Void)?
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
    private let confirmationLabel = NSTextField(labelWithString: "Selected")
    private let confirmationIcon = DecorationImageView()
    private let appGroup = ModeGroupView()
    private let appIcon = DecorationImageView()
    private var buttons: [SliceID: NSButton] = [:]
    private var tracking: NSTrackingArea?
    private var displayObserver: NSObjectProtocol?
    private var mouseDownMode: SliceID?
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

        for label in [titleLabel, confirmationLabel] {
            label.alignment = .center
            label.isSelectable = false
            label.font = .systemFont(ofSize: 11)
            label.textColor = .labelColor
            addSubview(label)
        }
        titleLabel.font = .systemFont(ofSize: 24, weight: .medium)
        titleLabel.maximumNumberOfLines = 2
        titleLabel.usesSingleLineMode = false
        titleLabel.textColor = .labelColor
        confirmationIcon.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        confirmationIcon.contentTintColor = .labelColor
        confirmationIcon.setAccessibilityElement(false)
        confirmationIcon.isHidden = true
        addSubview(confirmationIcon)
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
        setBoundsSize(menuLayout.presentationSize)
        // Keep wheel-space coordinates unchanged. The negative bounds origin
        // provides a transparent margin without shifting icons or hit targets.
        setBoundsOrigin(NSPoint(x: -RadialMenuLayout.effectPadding, y: -RadialMenuLayout.effectPadding))
        let wheelFrame = NSRect(x: 0, y: 0, width: menuLayout.diameter, height: menuLayout.diameter)
        material.frame = wheelFrame
        surface.frame = wheelFrame
        surface.menuLayout = menuLayout
        appGroup.frame = wheelFrame
        appGroup.isHidden = !menuLayout.hasApplicationGroup
        appGroup.setAccessibilityLabel("\(menuLayout.application?.displayName ?? "App") modes")
        appGroup.setAccessibilityHelp(menuLayout.application.map { "\(menuLayout.dial.applicationSlices.count) modes available while \($0.displayName) is active" })
        if let profile = menuLayout.application, let group = menuLayout.appGroupSegment {
            appIcon.image = applicationIcon(for: profile)
            let p = menuLayout.point(angle: group.angle, radius: group.iconRadius)
            appIcon.frame = NSRect(x: p.x - 21, y: p.y - 21, width: 42, height: 42)
        }
        for segment in menuLayout.segments {
            guard let mode = segment.slice else { continue }
            let button = ModeIconButton()
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.image = NSImage(systemSymbolName: mode.symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 28, weight: .regular))
            if button.image == nil { button.image = NSImage(systemSymbolName: "star", accessibilityDescription: nil) }
            button.contentTintColor = .labelColor
            (button.cell as? NSButtonCell)?.imageDimsWhenDisabled = false
            button.target = self
            button.action = #selector(selectIcon(_:))
            button.tag = mode.builtInMode.flatMap { Mode.allCases.firstIndex(of: $0) } ?? -1
            button.identifier = NSUserInterfaceItemIdentifier(mode.id.rawValue)
            let p = menuLayout.point(angle: segment.angle, radius: segment.iconRadius)
            // Geometry reserves enough distance for nonoverlapping native targets.
            let targetSize: CGFloat = 50
            button.frame = NSRect(x: p.x - targetSize / 2, y: p.y - targetSize / 2,
                                  width: targetSize, height: targetSize)
            button.setAccessibilityRole(.radioButton)
            button.setAccessibilityLabel("\(mode.title) mode")
            button.toolTip = mode.usageHelp
            let hints = mode.builtInMode.map { "\($0.turnHint). \($0.clickHint)." } ?? "Custom actions."
            button.setAccessibilityHelp([mode.usageHelp, hints, "Turn to choose; click to select."].compactMap { $0 }.joined(separator: " "))
            if segment.isApplication { appGroup.addSubview(button) }
            else { addSubview(button) }
            buttons[mode.id] = button
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

    // Scale a complete logical wheel into a preview or a small display. Reset
    // both frame and bounds so reopening after a scaled presentation is stable.
    func fitPresentation(to size: NSSize, padding: CGFloat = RadialMenuLayout.effectPadding) {
        setFrameSize(size)
        let diameter = menuLayout.diameter + padding * 2
        setBoundsSize(NSSize(width: diameter, height: diameter))
        setBoundsOrigin(NSPoint(x: -padding, y: -padding))
        updateGlassLayout()
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
            confirmationLabel.textColor = NSColor.labelColor.withAlphaComponent(0.82)
        }
    }

    private func applicationIcon(for profile: ApplicationConfiguration) -> NSImage? {
        var candidates = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == profile.bundleIdentifier }.compactMap(\.bundleURL)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: profile.bundleIdentifier) {
            candidates.append(url)
        }
        if let savedURL = profile.applicationURL { candidates.append(savedURL) }
        // Launch Services lookup can be unavailable in offscreen inspection.
        if profile.bundleIdentifier == AppProfile.lightroom.bundleIdentifier {
            candidates.append(URL(fileURLWithPath: "/Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app"))
        }
        if profile.bundleIdentifier == AppProfile.editwall.bundleIdentifier {
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
        confirmationLabel.isHidden = true
        let profileChanged = menuLayout.dial != state.dial || menuLayout.application != state.application
        if profileChanged {
            menuLayout = RadialMenuLayout(dial: state.dial, application: state.application)
            rebuildControls()
        }
        let changed = surface.selectedSliceID != state.selectedSliceID
        surface.select(state.selectedSliceID, animated: !profileChanged && !reduceMotion
                       && isArmed && window?.isVisible == true)
        isArmed = state.isArmed
        // Keep long names inside the center disk at the same larger type size.
        let multilineTitle = state.selectedSlice?.builtInMode == .lightroomCrop || state.selectedSlice == nil
        titleLabel.stringValue = state.selectedSlice == nil ? "No enabled\nslices"
            : state.selectedSlice?.builtInMode == .lightroomCrop ? "Crop &\nBrowse" : state.selectedSlice!.title
        titleLabel.setAccessibilityLabel(state.selectedSlice?.title ?? "No enabled slices")
        let c = menuLayout.center
        titleLabel.font = .systemFont(ofSize: 24, weight: .medium)
        let isCustom = state.selectedSlice?.builtInMode == nil && state.selectedSlice != nil
        let longCustomName = isCustom && titleLabel.attributedStringValue.size().width > 136
        if longCustomName {
            let name = titleLabel.stringValue
            var split = name.startIndex
            while split < name.endIndex {
                let next = name.index(after: split)
                let width = (String(name[..<next]) as NSString).size(withAttributes: [.font: titleLabel.font!]).width
                if width > 136 { break }
                split = next
            }
            if let space = name[..<split].lastIndex(where: { $0.isWhitespace }) {
                split = space
            }
            if split > name.startIndex {
                titleLabel.stringValue = String(name[..<split]) + "\n"
                    + name[split...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        titleLabel.lineBreakMode = .byTruncatingTail
        let titleHeight: CGFloat = multilineTitle || longCustomName ? 60 : 32
        titleLabel.frame = NSRect(x: c.x - 68, y: c.y - titleHeight / 2,
                                  width: 136, height: titleHeight)
        for (mode, button) in buttons {
            button.contentTintColor = .labelColor
            button.alphaValue = mode == state.selectedSliceID ? 1 : 0.78
            button.setAccessibilityValue(mode == state.selectedSliceID ? 1 : 0)
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
        if let id = state.selectedSliceID { buttons[id]?.contentTintColor = .white }
        let c = menuLayout.center
        titleLabel.frame.origin.y += 14
        confirmationLabel.isHidden = false
        let statusY = titleLabel.frame.minY - 22
        confirmationLabel.frame = NSRect(x: c.x - 18, y: statusY, width: 58, height: 18)
        confirmationIcon.frame = NSRect(x: c.x - 36, y: statusY + 2, width: 14, height: 14)
        confirmationIcon.isHidden = false
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: "\(state.selectedSlice?.title ?? "Slice") selected",
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
            button.alphaValue = mode == surface.selectedSliceID ? 1 : 0.78 * opacity
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
        if let slice = menuLayout.slice(at: convert(event.locationInWindow, from: nil)) {
            onHighlightSlice?(slice.id)
            if let mode = slice.builtInMode { onHighlight?(mode) }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !isConfirming else { return }
        let point = convert(event.locationInWindow, from: nil)
        mouseDownMode = isArmed ? menuLayout.slice(at: point)?.id : nil
        if let id = mouseDownMode {
            onPressHighlightSlice?(id)
            if let mode = menuLayout.segment(for: id)?.mode { onPressHighlight?(mode) }
        }
        else if !menuLayout.outline.contains(point) { onCancel?() }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownMode = nil }
        if isArmed, let mode = mouseDownMode,
           menuLayout.slice(at: convert(event.locationInWindow, from: nil))?.id == mode { selectSlice(mode) }
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
        guard let rawValue = sender.identifier?.rawValue else { return }
        selectSlice(SliceID(rawValue: rawValue))
    }

    private func selectSlice(_ id: SliceID) {
        onSelectSlice?(id)
        if let mode = menuLayout.segment(for: id)?.mode { onSelect?(mode) }
    }
}

private final class RadialSurfaceView: NSView {
    var menuLayout = RadialMenuLayout(profile: nil) { didSet { needsDisplay = true } }
    private(set) var selectedSliceID: SliceID? = .builtIn(.scrolling)
    private var selectionWeights: [SliceID: CGFloat] = [.builtIn(.scrolling): 1]
    private var selectionTimer: Timer?
    var usesGlass = false { didSet { needsDisplay = true } }

    deinit { selectionTimer?.invalidate() }

    func select(_ mode: SliceID?, animated: Bool) {
        guard mode != selectedSliceID else { return }
        let initialWeights = selectionWeights
        selectedSliceID = mode
        selectionTimer?.invalidate()
        guard animated else { finishSelectionAnimation(); return }
        let start = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let t = min(1, (ProcessInfo.processInfo.systemUptime - start) / 0.1)
            let progress = CGFloat(t * t * (3 - 2 * t))
            self.selectionWeights = initialWeights.mapValues { $0 * (1 - progress) }
            if let mode = mode { self.selectionWeights[mode, default: 0] += progress }
            self.needsDisplay = true
            if t >= 1 { self.finishSelectionAnimation() }
        }
        selectionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func finishSelectionAnimation() {
        selectionTimer?.invalidate()
        selectionTimer = nil
        selectionWeights = selectedSliceID.map { [$0: CGFloat(1)] } ?? [:]
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
            if let mode = segment.slice?.id, let weight = selectionWeights[mode], weight > 0 {
                (isConfirming ? NSColor.systemBlue.withAlphaComponent(weight)
                 : foreground.withAlphaComponent((increasedContrast ? 0.24 : 0.10) * weight)).setFill()
                layout.path(for: segment).fill()
            } else if segment.slice == nil && layout.dial.applicationSlices.contains(where: { $0.id == selectedSliceID }) {
                NSColor.systemBlue.withAlphaComponent((increasedContrast ? 0.24 : 0.12) * decorationOpacity).setFill()
                layout.path(for: segment).fill()
            }
        }

        foreground.withAlphaComponent(increasedContrast ? 0.55 : 0.10).setStroke()
        if !layout.hasApplicationGroup {
            let border = NSBezierPath(ovalIn: layout.coreFrame.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
            foreground.withAlphaComponent((increasedContrast ? 0.55 : 0.10) * decorationOpacity).setStroke()
            for segment in layout.segments where segment.sweep < 360 {
                let angle = segment.angle + segment.sweep / 2
                let line = NSBezierPath()
                line.move(to: layout.point(angle: angle, radius: 72))
                line.line(to: layout.point(angle: angle, radius: layout.coreRadius - 4))
                line.lineWidth = 0.5
                line.stroke()
            }
        } else {
            let outline = layout.outline
            outline.lineWidth = 1
            outline.stroke()
            for segment in layout.segments {
                foreground.withAlphaComponent((increasedContrast ? 0.55 : 0.10)
                    * (segment.slice?.id == selectedSliceID ? 1 : decorationOpacity)).setStroke()
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
            if segment.sweep >= 360 {
                let radius = segment.outerRadius - 2.5
                arc.appendOval(in: NSRect(x: layout.center.x - radius, y: layout.center.y - radius,
                                         width: radius * 2, height: radius * 2))
            } else {
                arc.appendArc(withCenter: layout.center, radius: segment.outerRadius - 2.5,
                          startAngle: segment.angle + segment.sweep / 2 - 1.5,
                          endAngle: segment.angle - segment.sweep / 2 + 1.5, clockwise: true)
            }
            arc.lineWidth = 4
            arc.lineCapStyle = .round
            NSColor.systemBlue.withAlphaComponent(weight).setStroke()
            arc.stroke()
        }
    }
}
