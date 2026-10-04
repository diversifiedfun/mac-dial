import AppKit

enum RadialMenuGeometry {
    static let diameter: CGFloat = 300
    static let innerRadius: CGFloat = 72

    static func frame(around point: NSPoint, in screen: NSRect) -> NSRect {
        let margin: CGFloat = 10
        let available = screen.insetBy(dx: margin, dy: margin)
        return NSRect(x: max(available.minX, min(point.x - diameter / 2, available.maxX - diameter)),
                      y: max(available.minY, min(point.y - diameter / 2, available.maxY - diameter)),
                      width: diameter, height: diameter)
    }

    static func angle(for mode: Mode) -> CGFloat {
        90 - CGFloat(Mode.allCases.firstIndex(of: mode)!) * 120
    }

    static func point(angle: CGFloat, radius: CGFloat) -> NSPoint {
        let radians = angle * .pi / 180
        return NSPoint(x: diameter / 2 + cos(radians) * radius,
                       y: diameter / 2 + sin(radians) * radius)
    }

    static func mode(at point: NSPoint) -> Mode? {
        let dx = point.x - diameter / 2
        let dy = point.y - diameter / 2
        let radius = hypot(dx, dy)
        guard radius >= innerRadius, radius <= diameter / 2 else { return nil }
        let degrees = atan2(dy, dx) * 180 / .pi
        let clockwise = (150 - degrees + 360).truncatingRemainder(dividingBy: 360)
        return Mode.allCases[Int(clockwise / 120) % Mode.allCases.count]
    }
}

private final class ModeIconButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Keyboard navigation belongs to the wheel rather than the icon buttons.
    override var acceptsFirstResponder: Bool { false }
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
    private var buttons: [Mode: NSButton] = [:]
    private var tracking: NSTrackingArea?
    private var displayObserver: NSObjectProtocol?
    private var mouseDownMode: Mode?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        appearance = NSAppearance(named: .vibrantDark)
        wantsLayer = true
        layer?.cornerRadius = 150
        layer?.masksToBounds = true
        setAccessibilityElement(false)
        setAccessibilityLabel("Mac Dial modes")

        material.frame = bounds
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.autoresizingMask = [.width, .height]
        addSubview(material)
        surface.frame = bounds
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)

        for mode in Mode.allCases {
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
            let center = RadialMenuGeometry.point(angle: RadialMenuGeometry.angle(for: mode), radius: 108)
            button.frame = NSRect(x: center.x - 25, y: center.y - 25, width: 50, height: 50)
            button.setAccessibilityRole(.radioButton)
            button.setAccessibilityLabel("\(mode.title) mode")
            button.setAccessibilityHelp("Select \(mode.title) for the Surface Dial")
            addSubview(button)
            buttons[mode] = button
        }

        titleLabel.font = .systemFont(ofSize: 21, weight: .medium)
        titleLabel.textColor = .white
        titleLabel.frame = NSRect(x: 70, y: 148, width: 160, height: 28)
        turnLabel.frame = NSRect(x: 76, y: 128, width: 148, height: 18)
        clickLabel.frame = NSRect(x: 76, y: 111, width: 148, height: 18)
        for label in [titleLabel, turnLabel, clickLabel] {
            label.alignment = .center
            label.isSelectable = false
            if label !== titleLabel {
                label.font = .systemFont(ofSize: 11, weight: .regular)
                label.textColor = NSColor.white.withAlphaComponent(0.72)
            }
            addSubview(label)
        }
        displayObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.updateDisplayOptions() }
        updateDisplayOptions()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let observer = displayObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func update(_ state: ModePickerState) {
        let changed = surface.selectedMode != state.selectedMode
        surface.selectedMode = state.selectedMode
        titleLabel.stringValue = state.selectedMode.title
        turnLabel.stringValue = state.isArmed ? "Turn to choose" : "Release to choose"
        clickLabel.stringValue = state.isArmed ? "Click to select" : "Hold again to cancel"
        for (mode, button) in buttons {
            button.alphaValue = mode == state.selectedMode ? 1 : 0.78
            button.setAccessibilityValue(mode == state.selectedMode ? 1 : 0)
            button.isEnabled = state.isArmed
        }
        if changed {
            NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
        }
    }

    func updateDisplayOptions(reduceTransparency: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                              increasedContrast: Bool = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast) {
        material.isHidden = reduceTransparency
        layer?.backgroundColor = reduceTransparency
            ? NSColor(calibratedWhite: 0.12, alpha: 1).cgColor : NSColor.clear.cgColor
        surface.increasedContrast = increasedContrast
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking = tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        if let mode = RadialMenuGeometry.mode(at: convert(event.locationInWindow, from: nil)) {
            onHighlight?(mode)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseDownMode = RadialMenuGeometry.mode(at: point)
        if let mode = mouseDownMode { onHighlight?(mode) }
        else if hypot(point.x - 150, point.y - 150) > 150 { onCancel?() }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownMode = nil }
        if let mode = mouseDownMode,
           RadialMenuGeometry.mode(at: convert(event.locationInWindow, from: nil)) == mode {
            onSelect?(mode)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()
        case 123, 126: onMove?(-1)
        case 124, 125: onMove?(1)
        case 36, 76: onConfirm?()
        default: break
        }
    }

    @objc private func selectIcon(_ sender: NSButton) {
        onSelect?(Mode.allCases[sender.tag])
    }
}

private final class RadialSurfaceView: NSView {
    var selectedMode: Mode = .scrolling { didSet { needsDisplay = true } }
    var increasedContrast = false { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: 150, y: 150)
        NSColor.black.withAlphaComponent(0.24).setFill()
        NSBezierPath(ovalIn: bounds).fill()

        let angle = RadialMenuGeometry.angle(for: selectedMode)
        let wedge = NSBezierPath()
        wedge.move(to: RadialMenuGeometry.point(angle: angle + 60, radius: 150))
        wedge.appendArc(withCenter: center, radius: 150, startAngle: angle + 60, endAngle: angle - 60, clockwise: true)
        wedge.line(to: RadialMenuGeometry.point(angle: angle - 60, radius: RadialMenuGeometry.innerRadius))
        wedge.appendArc(withCenter: center, radius: RadialMenuGeometry.innerRadius,
                        startAngle: angle - 60, endAngle: angle + 60, clockwise: false)
        wedge.close()
        NSColor.white.withAlphaComponent(increasedContrast ? 0.24 : 0.10).setFill()
        wedge.fill()

        NSColor.white.withAlphaComponent(increasedContrast ? 0.45 : 0.10).setStroke()
        let border = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
        for mode in Mode.allCases {
            let separatorAngle = RadialMenuGeometry.angle(for: mode) + 60
            let line = NSBezierPath()
            line.move(to: RadialMenuGeometry.point(angle: separatorAngle, radius: RadialMenuGeometry.innerRadius))
            line.line(to: RadialMenuGeometry.point(angle: separatorAngle, radius: 146))
            line.lineWidth = 0.5
            line.stroke()
        }

        let middle = NSBezierPath(ovalIn: NSRect(x: 78, y: 78, width: 144, height: 144))
        NSColor.black.withAlphaComponent(0.20).setFill()
        middle.fill()
        middle.lineWidth = 0.5
        middle.stroke()

        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: 147.5, startAngle: angle + 58.5,
                      endAngle: angle - 58.5, clockwise: true)
        arc.lineWidth = 4
        arc.lineCapStyle = .round
        NSColor.systemBlue.setStroke()
        arc.stroke()
    }
}
