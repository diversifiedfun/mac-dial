import AppKit

// One geometry source for the live picker, customization preview and hit tests.
struct RadialMenuLayout {
    struct Segment {
        let slice: SliceDefinition? // nil is the nonselectable application group
        let angle: CGFloat
        let sweep: CGFloat
        let innerRadius: CGFloat
        let outerRadius: CGFloat
        let iconRadius: CGFloat
        let isApplication: Bool
        var mode: Mode? { slice?.builtInMode }
        var startAngle: CGFloat { angle + sweep / 2 }
        var endAngle: CGFloat { angle - sweep / 2 }
    }

    let dial: ResolvedDial
    let application: ApplicationConfiguration?
    var profile: AppProfile? { AppProfile.matching(application?.bundleIdentifier) }
    static let effectPadding: CGFloat = 32
    static let applicationRingWidth: CGFloat = 66
    static let pointerVerticalOffset: CGFloat = 48
    static let innerRadius: CGFloat = 72

    init(dial: ResolvedDial, application: ApplicationConfiguration? = nil) {
        self.dial = dial
        self.application = application
    }

    init(profile: AppProfile?) {
        let defaults = SliceConfiguration.builtInDefaults
        self.init(dial: defaults.resolved(for: profile?.bundleIdentifier),
                  application: defaults.applications.first { $0.bundleIdentifier == profile?.bundleIdentifier })
    }

    var hasApplicationGroup: Bool { !dial.applicationSlices.isEmpty }
    private var standardSweep: CGFloat { CGFloat(dial.standardSliceAngle) }
    private var applicationSweep: CGFloat { CGFloat(dial.applicationSliceAngle) }
    private var applicationGroupSweep: CGFloat {
        dial.standardSlices.isEmpty ? 360 : CGFloat(dial.applicationSlices.count) * applicationSweep
    }
    // A 50-point square target needs at least its diagonal between centers.
    // Existing sparse wheels retain their 108-point icon / 150-point rim radii.
    var standardIconRadius: CGFloat {
        var radius: CGFloat = 108
        if dial.actionCount > 2 {
            radius = max(radius, 72 / (2 * sin(.pi / CGFloat(dial.actionCount))))
        }
        if dial.applicationSlices.count > 1 {
            // Child targets sit 75 points farther out than standard icons.
            radius = max(radius, 72 / (2 * sin(applicationSweep * .pi / 360)) - 75)
        }
        if hasApplicationGroup && applicationGroupSweep < 180 {
            // Keep the 42-point app logo inside even a narrow parent wedge.
            radius = max(radius, 60 / (2 * sin(applicationGroupSweep * .pi / 360)))
        }
        return radius
    }
    var coreRadius: CGFloat { standardIconRadius + 42 }
    var outerRadius: CGFloat { coreRadius + (hasApplicationGroup ? Self.applicationRingWidth : 0) }
    var diameter: CGFloat { outerRadius * 2 }
    var presentationSize: NSSize {
        NSSize(width: diameter + Self.effectPadding * 2, height: diameter + Self.effectPadding * 2)
    }
    var center: NSPoint { NSPoint(x: outerRadius, y: outerRadius) }
    var coreFrame: NSRect {
        NSRect(x: center.x - coreRadius, y: center.y - coreRadius, width: coreRadius * 2, height: coreRadius * 2)
    }

    var appGroupSegment: Segment? {
        guard hasApplicationGroup else { return nil }
        let groupSweep = applicationGroupSweep
        let start = 90 + standardSweep / 2 - CGFloat(dial.standardSlices.count) * standardSweep
        return Segment(slice: nil, angle: groupSweep >= 360 ? 180 : start - groupSweep / 2,
                       sweep: groupSweep, innerRadius: Self.innerRadius, outerRadius: coreRadius,
                       iconRadius: standardIconRadius, isApplication: true)
    }

    var segments: [Segment] {
        let appIDs = Set(dial.applicationSlices.map(\.id))
        let firstSweep = dial.standardSlices.isEmpty ? applicationSweep : standardSweep
        var start = 90 + firstSweep / 2
        var result = dial.clockwiseSlices.map { slice -> Segment in
            let isApp = appIDs.contains(slice.id)
            let sweep = isApp ? applicationSweep : standardSweep
            let angle = start - sweep / 2
            start -= sweep
            return Segment(slice: slice, angle: angle, sweep: sweep,
                           innerRadius: isApp ? coreRadius : Self.innerRadius,
                           outerRadius: isApp ? outerRadius : coreRadius,
                           iconRadius: isApp ? coreRadius + 33 : standardIconRadius,
                           isApplication: isApp)
        }
        if let group = appGroupSegment { result.append(group) }
        return result
    }

    func point(angle: CGFloat, radius: CGFloat) -> NSPoint {
        let radians = angle * .pi / 180
        return NSPoint(x: center.x + cos(radians) * radius, y: center.y + sin(radians) * radius)
    }

    func segment(for mode: Mode) -> Segment? { segment(for: SliceID.builtIn(mode)) }
    func segment(for id: SliceID) -> Segment? { segments.first { $0.slice?.id == id } }

    func slice(at point: NSPoint) -> SliceDefinition? {
        let radius = hypot(point.x - center.x, point.y - center.y)
        let angle = atan2(point.y - center.y, point.x - center.x) * 180 / .pi
        return segments.first { segment in
            let offset = (segment.startAngle - angle + 1080).truncatingRemainder(dividingBy: 360)
            return segment.slice != nil && radius >= segment.innerRadius && radius <= segment.outerRadius
                && (segment.sweep >= 360 || offset < segment.sweep)
        }?.slice
    }

    func mode(at point: NSPoint) -> Mode? { slice(at: point)?.builtInMode }

    func path(for segment: Segment) -> NSBezierPath {
        let path = NSBezierPath()
        if segment.sweep >= 360 {
            path.appendOval(in: NSRect(x: center.x - segment.outerRadius, y: center.y - segment.outerRadius,
                                      width: segment.outerRadius * 2, height: segment.outerRadius * 2))
            path.appendOval(in: NSRect(x: center.x - segment.innerRadius, y: center.y - segment.innerRadius,
                                      width: segment.innerRadius * 2, height: segment.innerRadius * 2))
            path.windingRule = .evenOdd
            return path
        }
        path.move(to: point(angle: segment.startAngle, radius: segment.outerRadius))
        path.appendArc(withCenter: center, radius: segment.outerRadius,
                       startAngle: segment.startAngle, endAngle: segment.endAngle, clockwise: true)
        path.line(to: point(angle: segment.endAngle, radius: segment.innerRadius))
        path.appendArc(withCenter: center, radius: segment.innerRadius,
                       startAngle: segment.endAngle, endAngle: segment.startAngle, clockwise: false)
        path.close()
        return path
    }

    var outline: NSBezierPath {
        guard let group = appGroupSegment else { return NSBezierPath(ovalIn: coreFrame) }
        if group.sweep >= 360 {
            return NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        }
        let path = NSBezierPath()
        path.move(to: point(angle: group.endAngle, radius: coreRadius))
        path.appendArc(withCenter: center, radius: coreRadius,
                       startAngle: group.endAngle, endAngle: group.startAngle, clockwise: true)
        path.line(to: point(angle: group.startAngle, radius: outerRadius))
        path.appendArc(withCenter: center, radius: outerRadius,
                       startAngle: group.startAngle, endAngle: group.endAngle, clockwise: true)
        path.close()
        return path
    }

    func frame(around point: NSPoint, in screen: NSRect, padding: CGFloat = 0) -> NSRect {
        let available = screen.insetBy(dx: 10, dy: 10)
        let naturalSize = diameter + padding * 2
        let size = max(1, min(naturalSize, available.width, available.height))
        let offset = Self.pointerVerticalOffset * size / naturalSize
        return NSRect(x: max(available.minX, min(point.x - size / 2, available.maxX - size)),
                      y: max(available.minY, min(point.y + offset - size / 2, available.maxY - size)),
                      width: size, height: size)
    }
}

// NSBezierPath.cgPath requires macOS 14; this app supports macOS 12.
extension NSBezierPath {
    var compatibleCGPath: CGPath {
        let path = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)
        for index in 0..<elementCount {
            // Raw values preserve macOS 12 compatibility across the curveTo
            // rename in macOS 14 (cubic = 2, quadratic = 4).
            switch element(at: index, associatedPoints: &points).rawValue {
            case 0: path.move(to: points[0])
            case 1: path.addLine(to: points[0])
            case 2: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case 3: path.closeSubpath()
            case 4: path.addQuadCurve(to: points[1], control: points[0])
            default: break
            }
        }
        return path
    }
}

// Compatibility helpers for the existing general-wheel checks.
enum RadialMenuGeometry {
    static let diameter: CGFloat = 300
    static let innerRadius: CGFloat = 72
    private static let layout = RadialMenuLayout(profile: nil)
    static func frame(around point: NSPoint, in screen: NSRect) -> NSRect { layout.frame(around: point, in: screen) }
    static func angle(for mode: Mode) -> CGFloat { layout.segment(for: mode)?.angle ?? 90 }
    static func point(angle: CGFloat, radius: CGFloat) -> NSPoint { layout.point(angle: angle, radius: radius) }
    static func mode(at point: NSPoint) -> Mode? { layout.mode(at: point) }
}
