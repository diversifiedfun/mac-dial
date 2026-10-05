import AppKit

// Independent of Mode: Scroll remains one choice in the radial menu.
enum ScrollStyle: String, CaseIterable {
    case stepped
    // Preserve preference values saved by earlier versions.
    case freestyle = "freewheel"
    case precision = "smooth"

    var title: String {
        switch self {
        case .stepped: return "Stepped"
        case .freestyle: return "Freestyle"
        case .precision: return "Precision"
        }
    }

    var next: ScrollStyle {
        switch self {
        case .stepped: return .freestyle
        case .freestyle: return .precision
        case .precision: return .stepped
        }
    }

    // Freestyle keeps slow-tick precision but accelerates faster turns more
    // strongly and dissipates their momentum over a longer, bounded coast.
    fileprivate var maximumPixelsPerTick: Double { self == .freestyle ? 144 : 96 }
    fileprivate var coastDuration: TimeInterval { self == .freestyle ? 1.2 : 0.60 }
    fileprivate var maximumCoastVelocity: Double { self == .freestyle ? 2400 : 1200 }
    // Medium reports one tick per 10 degrees. Freestyle must recognize a
    // comfortable sustained turn even when its ticks are over 100 ms apart.
    fileprivate var gestureTimeout: TimeInterval { self == .freestyle ? 0.22 : 0.10 }
    fileprivate var speedResponse: TimeInterval { self == .freestyle ? 0.08 : 0.12 }
    fileprivate var accelerationStart: Double { self == .freestyle ? 2 : 8 }
    fileprivate var accelerationRange: Double { self == .freestyle ? 16 : 40 }
    fileprivate var accelerationExponent: Double { self == .freestyle ? 1.5 : 2 }
    fileprivate var minimumCoastRate: Double { self == .freestyle ? 5 : 12 }

    static func load(from defaults: UserDefaults = .standard) -> ScrollStyle {
        ScrollStyle(rawValue: defaults.string(forKey: "scrollStyle") ?? "") ?? .stepped
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: "scrollStyle")
    }
}

final class ScrollController: Controller {
    private let source = CGEventSource(stateID: .hidSystemState)
    private let post: (CGEvent) -> Void
    private let makeScrollEvent: (CGEventSource?, Int32) -> CGEvent?
    private let now: () -> TimeInterval
    private let schedule: (TimeInterval, DispatchWorkItem) -> Void
    // The owner checks foreground context before asynchronous movement can post.
    var canScroll: () -> Bool = { true }
    var onStyleChanged: ((ScrollStyle) -> Void)?
    private(set) var style: ScrollStyle
    private var pendingClick = false
    private var lastRotate: TimeInterval?
    private var direction = 0
    private var timer: DispatchWorkItem?
    private var generation = 0
    private var lastFrame: TimeInterval = 0
    private var remainder = 0.0
    private var scrollActive = false
    private var momentumActive = false
    private var momentumStart: TimeInterval?
    private var coastStart: TimeInterval?
    private var coastVelocity = 0.0
    private var smoothedTickRate = 0.0
    private var consecutiveTicks = 0
    private struct Impulse {
        let start: TimeInterval
        let distance: Double
        var delivered: Double = 0
    }
    private var impulses: [Impulse] = []
    private static let frameInterval = 1.0 / 120
    private static let interpolation = 0.08
    private static let minimumPixelsPerTick = 2.0

    init(style: ScrollStyle = .stepped,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: @escaping (TimeInterval, DispatchWorkItem) -> Void = {
             DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1)
         },
         makeScrollEvent: @escaping (CGEventSource?, Int32) -> CGEvent? = {
             CGEvent(scrollWheelEvent2Source: $0, units: .pixel,
                     wheelCount: 1, wheel1: $1, wheel2: 0, wheel3: 0)
         },
         post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.style = style
        self.now = now
        self.schedule = schedule
        self.post = post
        self.makeScrollEvent = makeScrollEvent
    }

    deinit { timer?.cancel() }

    func setStyle(_ value: ScrollStyle) {
        guard value != style else { return }
        onCancel()
        style = value
        onStyleChanged?(value)
    }

    func onPressBegan() { onCancel() }
    func onDown() { pendingClick = true }
    func onUp() {
        guard pendingClick else { return }
        pendingClick = false
        setStyle(style.next)
    }

    func onCancel() {
        pendingClick = false
        timer?.cancel()
        timer = nil
        generation += 1
        finishPhases(cancelled: true)
        impulses.removeAll()
        remainder = 0
        momentumStart = nil
        coastStart = nil
        coastVelocity = 0
        smoothedTickRate = 0
        consecutiveTicks = 0
        lastRotate = nil
        direction = 0
    }

    func onRotate(_ rotation: Dial.Rotation, _ scrollDirection: Int) {
        let ticks: Int
        switch rotation {
        case .Clockwise(let count): guard count > 0 else { return }; ticks = count
        case .CounterClockwise(let count): guard count > 0 else { return }; ticks = -count
        }
        guard scrollDirection == 1 || scrollDirection == -1, canScroll() else { onCancel(); return }
        let steps = Double(ticks) * Double(scrollDirection)
        let time = now()
        let newDirection = steps > 0 ? 1 : -1
        if style != .stepped,
           (momentumStart != nil || (direction != 0 && direction != newDirection)
            || (timer != nil && time - lastFrame > 0.05)) {
            onCancel()
        }
        let interval = lastRotate.map { max(0, time - $0) } ?? 0.15
        if style == .stepped {
            let multiplier = Int(1 + (150 - min(interval * 1000, 150)) / 40)
            let lines = steps * Double(multiplier)
            let pixels = Int32(clamping: Int64(min(Double(Int32.max), max(Double(Int32.min), lines * 24))))
            if let event = makeScrollEvent(source, pixels) {
                event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(lines))
                event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(pixels))
                event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                post(event)
            }
        } else {
            // A new tick within the gesture replaces the decaying tail without
            // discarding the turn's speed history or its fractional movement.
            coastStart = nil
            if lastRotate == nil || interval >= style.gestureTimeout {
                smoothedTickRate = 0
                consecutiveTicks = min(3, abs(ticks))
            } else {
                // Estimate speed gradually. One closely spaced pair of single-tick reports
                // must not turn a fine adjustment into a large accelerated jump.
                let rate = min(80, abs(steps) / max(interval, Self.frameInterval))
                let blend = 1 - exp(-interval / style.speedResponse)
                smoothedTickRate += (rate - smoothedTickRate) * blend
                consecutiveTicks = min(3, consecutiveTicks + min(3, abs(ticks)))
            }
            // Preserve a tiny one/two-tick adjustment while allowing Freestyle
            // to respond much earlier once the user continues turning.
            let speed = style == .freestyle && consecutiveTicks < 3 ? 0
                : max(0, min(1, (smoothedTickRate - style.accelerationStart) / style.accelerationRange))
            let pixelsPerTick = Self.minimumPixelsPerTick
                + (style.maximumPixelsPerTick - Self.minimumPixelsPerTick) * pow(speed, style.accelerationExponent)
            let distance = steps * pixelsPerTick
            impulses.append(Impulse(start: time, distance: distance))
            // Fine adjustments have no added coast. Inertia requires several
            // ticks and a sustained speed, independently of frame cadence.
            // Match the last impulse's outgoing velocity instead of scaling
            // it down based on report timing at the direct-to-glide boundary.
            coastVelocity = consecutiveTicks >= 3 && smoothedTickRate >= style.minimumCoastRate
                && interval < style.gestureTimeout
                ? Double(newDirection) * min(style.maximumCoastVelocity, abs(distance) / Self.interpolation)
                : 0
            if timer == nil {
                lastFrame = time
                enqueueFrame()
            }
        }
        lastRotate = time
        direction = newDirection
    }

    private func enqueueFrame() {
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.generation == token else { return }
            self.timer = nil
            guard self.canScroll(), self.generation == token else { self.onCancel(); return }
            self.frame()
        }
        timer = work
        schedule(Self.frameInterval, work)
    }

    private func frame() {
        let time = now()
        let dt = time - lastFrame
        // A busy queue must not dump delayed movement into the foreground app.
        guard dt >= 0, dt <= 0.05 else { onCancel(); return }
        let previous = lastFrame
        lastFrame = time
        if coastStart != nil {
            if advanceCoast(from: previous, to: time) { enqueueFrame() }
            return
        }

        var distance = 0.0
        for index in impulses.indices {
            let progress = max(0, min(1, (time - impulses[index].start) / Self.interpolation))
            // Uniformly distribute each impulse instead of front-loading
            // most of a tick into its first few animation frames.
            let cumulative = impulses[index].distance * progress
            distance += cumulative - impulses[index].delivered
            impulses[index].delivered = cumulative
        }
        impulses.removeAll { time - $0.start >= Self.interpolation }
        emit(distance, momentum: false)
        if impulses.isEmpty, let last = lastRotate {
            if coastVelocity != 0 {
                // Physical motion starts decaying as soon as interpolation
                // finishes. The gesture timeout only changes event phases;
                // it must never introduce a pause or restart the velocity.
                coastStart = last + Self.interpolation
                if !advanceCoast(from: previous, to: time) { return }
            } else if time - last >= style.gestureTimeout {
                finishMotion()
                return
            }
        }
        enqueueFrame()
    }

    private func advanceCoast(from previous: TimeInterval, to time: TimeInterval) -> Bool {
        guard let start = coastStart, let last = lastRotate else { return false }
        let transition = last + style.gestureTimeout
        func displacement(from lower: TimeInterval, to upper: TimeInterval) -> Double {
            let a = max(0, min(style.coastDuration, lower - start))
            let b = max(0, min(style.coastDuration, upper - start))
            guard b > a else { return 0 }
            // Velocity follows 1 - smoothstep(t / duration): it starts at
            // the outgoing speed with no sudden braking, and reaches zero
            // with zero slope. Integrate it exactly across frame/phase bounds
            // so neither scheduling jitter nor phase changes restart the glide.
            func integral(_ elapsed: TimeInterval) -> Double {
                let u = elapsed / style.coastDuration
                return u - u * u * u + 0.5 * u * u * u * u
            }
            return coastVelocity * style.coastDuration * (integral(b) - integral(a))
        }
        if momentumStart == nil {
            emit(displacement(from: previous, to: min(time, transition)), momentum: false)
            if time >= transition {
                finishPhases(cancelled: false)
                momentumStart = transition
            }
        }
        if momentumStart != nil {
            emit(displacement(from: max(previous, transition), to: time), momentum: true)
        }
        if time - start >= style.coastDuration {
            finishMotion()
            return false
        }
        return true
    }

    private func finishMotion() {
        finishPhases(cancelled: false)
        remainder = 0
        momentumStart = nil
        coastStart = nil
        coastVelocity = 0
        smoothedTickRate = 0
        consecutiveTicks = 0
        lastRotate = nil
        direction = 0
    }

    private func emit(_ distance: Double, momentum: Bool) {
        remainder += distance
        // Rounded accumulation preserves isolated tick distance in either direction.
        let pixels = Int32(max(Double(Int32.min), min(Double(Int32.max), remainder.rounded())))
        guard pixels != 0 else { return }
        remainder -= Double(pixels)
        if momentum {
            send(pixels, scrollPhase: 0,
                 momentumPhase: momentumActive ? CGMomentumScrollPhase.continuous.rawValue : CGMomentumScrollPhase.begin.rawValue)
            momentumActive = true
        } else {
            send(pixels, scrollPhase: scrollActive ? CGScrollPhase.changed.rawValue : CGScrollPhase.began.rawValue,
                 momentumPhase: 0)
            scrollActive = true
        }
    }

    private func finishPhases(cancelled: Bool) {
        if scrollActive {
            send(0, scrollPhase: cancelled ? CGScrollPhase.cancelled.rawValue : CGScrollPhase.ended.rawValue,
                 momentumPhase: 0)
        }
        if momentumActive {
            send(0, scrollPhase: 0, momentumPhase: CGMomentumScrollPhase.end.rawValue)
        }
        scrollActive = false
        momentumActive = false
    }

    private func send(_ pixels: Int32, scrollPhase: UInt32, momentumPhase: UInt32) {
        guard let event = makeScrollEvent(source, pixels) else { return }
        // Use the pixel initializer's coherent line/fixed-point fields instead
        // of overwriting them with the old, unrelated whole-tick line delta.
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(scrollPhase))
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentumPhase))
        // Keep Quartz's fresh pointer location on every event, including the
        // zero-delta momentum ending. Replaying a cached gesture location here
        // pulls the cursor back while the user moves it during the glide.
        post(event)
    }
}
