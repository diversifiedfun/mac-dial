import AppKit

// Independent of Mode: Scroll remains one choice in the radial menu.
enum ScrollStyle: String, CaseIterable {
    case smooth, stepped, freewheel

    var title: String {
        switch self {
        case .smooth: return "Smooth"
        case .stepped: return "Stepped"
        case .freewheel: return "Freewheel"
        }
    }

    var next: ScrollStyle {
        switch self {
        case .smooth: return .stepped
        case .stepped: return .freewheel
        case .freewheel: return .smooth
        }
    }

    // Freewheel keeps slow-tick precision but accelerates faster turns more
    // strongly and dissipates their momentum over a longer, bounded coast.
    fileprivate var maximumGain: Double { self == .freewheel ? 6 : 4 }
    fileprivate var coastDuration: TimeInterval { self == .freewheel ? 1.0 : 0.30 }
    fileprivate var decay: TimeInterval { self == .freewheel ? 0.25 : 0.075 }
    fileprivate var coastVelocityScale: Double { self == .freewheel ? 0.5 : 0.25 }
    fileprivate var maximumCoastVelocity: Double { self == .freewheel ? 2400 : 1200 }

    static func load(from defaults: UserDefaults = .standard) -> ScrollStyle {
        ScrollStyle(rawValue: defaults.string(forKey: "scrollStyle") ?? "") ?? .smooth
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
    private var coastVelocity = 0.0
    private struct Impulse {
        let start: TimeInterval
        let distance: Double
        var delivered: Double = 0
    }
    private var impulses: [Impulse] = []
    private static let frameInterval = 1.0 / 120
    private static let interpolation = 0.08
    private static let gestureTimeout = 0.10

    init(style: ScrollStyle = .smooth,
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
        coastVelocity = 0
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
            let gain = 1 + (style.maximumGain - 1) * max(0, min(1, 1 - interval / 0.15))
            let distance = steps * 24 * gain
            impulses.append(Impulse(start: time, distance: distance))
            // Only repeated fast reports qualify for a coast; a single tick
            // always finishes at exactly 24 pixels, including fractional frames.
            coastVelocity = lastRotate != nil && interval < Self.gestureTimeout
                ? Double(newDirection) * min(style.maximumCoastVelocity, abs(distance) / max(interval, Self.frameInterval) * style.coastVelocityScale)
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
        lastFrame = time
        if let start = momentumStart {
            let elapsed = min(style.coastDuration, time - start)
            let previous = max(0, time - dt - start)
            let distance = coastVelocity * style.decay
                * (exp(-previous / style.decay) - exp(-elapsed / style.decay))
            emit(distance, momentum: true)
            if time - start >= style.coastDuration {
                finishPhases(cancelled: false)
                remainder = 0
                momentumStart = nil
                coastVelocity = 0
                lastRotate = nil
                direction = 0
                return
            }
        } else {
            var distance = 0.0
            for index in impulses.indices {
                let progress = max(0, min(1, (time - impulses[index].start) / Self.interpolation))
                let cumulative = impulses[index].distance * (1 - pow(1 - progress, 3))
                distance += cumulative - impulses[index].delivered
                impulses[index].delivered = cumulative
            }
            impulses.removeAll { time - $0.start >= Self.interpolation }
            emit(distance, momentum: false)
            if impulses.isEmpty, let last = lastRotate, time - last >= Self.gestureTimeout {
                finishPhases(cancelled: false)
                if coastVelocity != 0 {
                    momentumStart = time
                } else {
                    remainder = 0
                    lastRotate = nil
                    direction = 0
                    return
                }
            }
        }
        enqueueFrame()
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
