import AppKit

// Shared by painting, icon placement, pointer targets and window bounds.
struct RadialMenuLayout {
    struct Segment {
        let mode: Mode? // nil is the nonselectable app group
        let angle: CGFloat
        let sweep: CGFloat
        let innerRadius: CGFloat
        let outerRadius: CGFloat
        var iconRadius: CGFloat { outerRadius == 150 ? 108 : (innerRadius + outerRadius) / 2 }
        var startAngle: CGFloat { angle + sweep / 2 }
        var endAngle: CGFloat { angle - sweep / 2 }
    }

    let profile: AppProfile?
    var diameter: CGFloat { profile == nil ? 300 : 432 }
    var center: NSPoint { NSPoint(x: diameter / 2, y: diameter / 2) }
    var coreFrame: NSRect { NSRect(x: center.x - 150, y: center.y - 150, width: 300, height: 300) }
    private var innerSweep: CGFloat { 360 / CGFloat(Mode.generalModes.count + (profile == nil ? 0 : 1)) }

    var appGroupSegment: Segment? {
        guard profile != nil else { return nil }
        let angle = (90 - CGFloat(Mode.generalModes.count) * innerSweep + 360).truncatingRemainder(dividingBy: 360)
        return Segment(mode: nil, angle: angle, sweep: innerSweep, innerRadius: 72, outerRadius: 150)
    }

    var segments: [Segment] {
        let sweep = innerSweep
        var result = Mode.generalModes.enumerated().map { index, mode in
            Segment(mode: mode, angle: 90 - CGFloat(index) * sweep, sweep: sweep,
                    innerRadius: 72, outerRadius: 150)
        }
        if let profile = profile, let group = appGroupSegment {
            result.append(group)
            let childSweep = group.sweep / CGFloat(max(1, profile.modes.count))
            result += profile.modes.enumerated().map { index, mode in
                Segment(mode: mode, angle: group.startAngle - childSweep * (CGFloat(index) + 0.5),
                        sweep: childSweep, innerRadius: 150, outerRadius: 216)
            }
        }
        return result
    }

    func point(angle: CGFloat, radius: CGFloat) -> NSPoint {
        let radians = angle * .pi / 180
        return NSPoint(x: center.x + cos(radians) * radius, y: center.y + sin(radians) * radius)
    }

    func segment(for mode: Mode) -> Segment? { segments.first { $0.mode == mode } }

    func mode(at point: NSPoint) -> Mode? {
        let radius = hypot(point.x - center.x, point.y - center.y)
        let angle = atan2(point.y - center.y, point.x - center.x) * 180 / .pi
        return segments.first { segment in
            let offset = (segment.angle + segment.sweep / 2 - angle + 720).truncatingRemainder(dividingBy: 360)
            return radius >= segment.innerRadius && radius <= segment.outerRadius && offset < segment.sweep
        }?.mode
    }

    func path(for segment: Segment) -> NSBezierPath {
        let path = NSBezierPath()
        let start = segment.startAngle
        let end = segment.endAngle
        path.move(to: point(angle: start, radius: segment.outerRadius))
        path.appendArc(withCenter: center, radius: segment.outerRadius, startAngle: start, endAngle: end, clockwise: true)
        path.line(to: point(angle: end, radius: segment.innerRadius))
        path.appendArc(withCenter: center, radius: segment.innerRadius, startAngle: end, endAngle: start, clockwise: false)
        path.close()
        return path
    }

    var outline: NSBezierPath {
        // One contour avoids winding-rule holes and seams in the material.
        guard let group = appGroupSegment else { return NSBezierPath(ovalIn: coreFrame) }
        let path = NSBezierPath()
        path.move(to: point(angle: group.endAngle, radius: 150))
        path.appendArc(withCenter: center, radius: 150, startAngle: group.endAngle, endAngle: group.startAngle, clockwise: true)
        path.line(to: point(angle: group.startAngle, radius: 216))
        path.appendArc(withCenter: center, radius: 216, startAngle: group.startAngle, endAngle: group.endAngle, clockwise: true)
        path.close()
        return path
    }

    func frame(around point: NSPoint, in screen: NSRect) -> NSRect {
        let available = screen.insetBy(dx: 10, dy: 10)
        return NSRect(x: max(available.minX, min(point.x - diameter / 2, available.maxX - diameter)),
                      y: max(available.minY, min(point.y - diameter / 2, available.maxY - diameter)),
                      width: diameter, height: diameter)
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
