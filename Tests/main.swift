import AppKit
import Carbon.HIToolbox

// The HID transport is stubbed. Production routing and controllers are used;
// injected event sinks never post input to the user's desktop.
enum Dial {
    enum ButtonState { case pressed, released }
    enum Rotation { case Clockwise(Int), CounterClockwise(Int) }
}

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    checks += 1
}

final class Clock {
    var time: TimeInterval = 0
    var pending: [(TimeInterval, DispatchWorkItem)] = []
    func schedule(_ delay: TimeInterval, _ work: DispatchWorkItem) {
        pending.append((time + delay, work))
    }
    func advance(_ interval: TimeInterval) {
        time += interval
        let ready = pending.filter { $0.0 <= time }
        pending.removeAll { $0.0 <= time }
        for (_, work) in ready { work.perform() }
    }
}

final class Harness {
    let clock = Clock()
    var mode: Mode = .scrolling
    var savedMode = "scroll"
    var clicks = 0
    var rotations: [Int] = []
    var commits: [Mode] = []
    var feedback = 0
    var presentations = 0
    var dismissals = 0
    lazy var button = DialButtonHandler(now: { [unowned self] in self.clock.time },
                                       schedule: { [unowned self] in self.clock.schedule($0, $1) })
    lazy var input = DialInputCoordinator(currentMode: { [unowned self] in self.mode }, button: button,
                                         schedule: { [unowned self] in self.clock.schedule($0, $1) })
    init() {
        input.onShortPress = { [unowned self] in self.clicks += 1 }
        input.onRotation = { [unowned self] _, direction in self.rotations.append(direction) }
        input.onCommit = { [unowned self] mode in
            self.commits.append(mode)
            self.mode = mode
            self.savedMode = mode.savedValue
        }
        input.onPickerChanged = { [unowned self] state in
            if state == nil { self.dismissals += 1 }
            else { self.presentations += 1 }
        }
        input.onFeedback = { [unowned self] in self.feedback += 1 }
    }
    func report(_ state: Dial.ButtonState, _ rotation: Dial.Rotation? = nil,
                sensitivity: Int = 36, direction: Int = -1) {
        input.handle(button: state, rotation: rotation, sensitivity: sensitivity, scrollDirection: direction)
    }
    func open() {
        report(.pressed)
        clock.advance(0.6)
        report(.released)
    }
    func click() {
        report(.pressed)
        clock.advance(0.1)
        report(.released)
    }
}

// Exact threshold, including release before an overdue timer is delivered.
for duration in [0.0, 0.599, 0.6, 0.601, 3.0] {
    let h = Harness()
    h.report(.pressed)
    h.report(.pressed)
    check(h.clicks == 0, "Pressing must not immediately click")
    h.clock.time = duration
    h.report(.released)
    h.report(.released)
    if duration < 0.6 {
        check(h.clicks == 1 && h.input.picker == nil, "Short press clicks exactly once")
    } else {
        check(h.clicks == 0 && h.input.picker?.isArmed == true, "Overdue long press opens and arms")
        check(h.mode == .scrolling && h.commits.isEmpty, "Opening never changes the active mode")
    }
}

// Reports timestamped on the HID thread retain the physical hold duration
// even when both edges wait behind a busy main queue.
for duration in [0.1, 0.599, 0.6, 1.0] {
    let h = Harness()
    h.clock.time = 10
    h.input.handle(button: .pressed, rotation: nil, sensitivity: 36, scrollDirection: -1, timestamp: 0)
    h.input.handle(button: .released, rotation: nil, sensitivity: 36, scrollDirection: -1, timestamp: duration)
    check(h.clicks == (duration < 0.6 ? 1 : 0), "Queued reports preserve real press duration")
    check((h.input.picker != nil) == (duration >= 0.6), "A main-queue stall cannot misclassify a hold")
}

do {
    let h = Harness()
    h.report(.pressed)
    h.clock.advance(0.6)
    check(h.input.picker?.isArmed == false, "Wheel opens while the original hold is still down")
    h.input.moveSelection(by: 1)
    h.input.highlight(.zoom)
    h.input.confirmSelection()
    h.report(.pressed, .Clockwise(30))
    check(h.input.picker?.selectedMode == .scrolling, "Opening hold cannot browse or confirm")
    h.clock.advance(1)
    check(h.presentations == 1, "A continuing hold must not reopen the menu")
    h.report(.released, .Clockwise(30))
    check(h.input.picker?.isArmed == true && h.input.picker?.selectedMode == .scrolling,
          "Opening release only arms; its rotation is consumed")
    h.report(.released, .Clockwise(2))
    check(h.input.picker?.selectedMode == .scrolling, "Subthreshold rotation accumulates")
    h.report(.released, .Clockwise(1))
    check(h.input.picker?.selectedMode == .playback && h.mode == .scrolling,
          "Thirty degrees highlights Playback without committing")
    h.report(.pressed, .Clockwise(3))
    h.clock.advance(0.1)
    h.report(.released, .Clockwise(3))
    check(h.mode == .playback && h.savedMode == "playback" && h.input.picker == nil,
          "Short confirmation commits and persists the highlight")
    check(h.clicks == 0 && h.rotations.isEmpty, "Confirmation and its rotation cannot leak")
    check(h.commits == [.playback] && h.dismissals == 1, "Commit and dismissal occur once")
    h.report(.released, .Clockwise(1))
    check(h.rotations == [-1], "Normal rotation resumes after dismissal")
    h.click()
    check(h.clicks == 1, "Short mode actions resume after dismissal")
}

do {
    let h = Harness()
    h.mode = .zoom
    h.savedMode = "zoom"
    h.open()
    check(h.input.picker?.selectedMode == .zoom, "Open with the saved current mode selected")
    h.click()
    check(h.commits == [.zoom] && h.clicks == 0, "Selecting the current mode closes without a mode action")
    h.open()
    h.input.moveSelection(by: 1)
    check(h.input.picker?.selectedMode == .scrolling, "Clockwise selection wraps")
    h.input.moveSelection(by: -1)
    check(h.input.picker?.selectedMode == .zoom, "Counterclockwise selection wraps")
    h.input.highlight(.playback)
    h.input.confirmSelection()
    check(h.mode == .playback && h.savedMode == "playback", "Pointer/keyboard confirmation commits")
}

// Escape, outside click, lifecycle changes and manual mode selection share cancel.
for cancelWhilePressed in [false, true] {
    let h = Harness()
    h.open()
    h.input.highlight(.zoom)
    if cancelWhilePressed { h.report(.pressed) }
    h.input.cancel()
    h.input.cancel()
    h.report(.released, cancelWhilePressed ? .Clockwise(3) : nil)
    h.clock.advance(1)
    check(h.mode == .scrolling && h.commits.isEmpty && h.input.picker == nil,
          "Cancellation preserves the saved mode")
    check(h.clicks == 0 && h.rotations.isEmpty && h.dismissals == 1,
          "Cancellation consumes outstanding input and dismisses once")
    h.click()
    check(h.clicks == 1, "Cancellation permits the next new press")
}

do {
    let h = Harness()
    h.open()
    h.input.highlight(.zoom)
    h.report(.pressed)
    h.clock.advance(0.6)
    check(h.input.picker == nil && h.mode == .scrolling, "Second hold cancels")
    h.report(.pressed, .Clockwise(3))
    h.report(.released, .Clockwise(3))
    check(h.clicks == 0 && h.rotations.isEmpty, "Cancel hold suppresses all input until release")
    h.open()
    h.report(.pressed)
    h.clock.time += 0.7 // cancellation detected by release, not by the timer
    h.report(.released, .Clockwise(3))
    check(h.input.picker == nil && h.clicks == 0 && h.rotations.isEmpty,
          "Overdue cancellation release must not click or rotate")
}

do {
    let h = Harness()
    h.report(.pressed)
    let stale = h.clock.pending[0].1
    h.input.cancel()
    h.mode = .zoom // manual menu change while the physical button is held
    h.report(.released, .Clockwise(3))
    h.report(.pressed)
    stale.perform()
    check(h.input.picker == nil, "A stale timer cannot open a new gesture early")
    h.clock.advance(0.1)
    h.report(.released)
    check(h.clicks == 1 && h.rotations.isEmpty, "Manual changes consume the old release, including rotation")
}

do {
    let h = Harness()
    h.open()
    h.clock.advance(9)
    let staleIdle = h.clock.pending.first { $0.0 > h.clock.time }!.1
    h.report(.released, .Clockwise(1)) // activity even below a selection threshold
    h.clock.advance(1.1)
    staleIdle.perform()
    check(h.input.picker != nil, "Any real browsing activity resets the idle timer")
    h.clock.advance(8.9)
    check(h.input.picker == nil && h.mode == .scrolling, "Ten idle seconds cancel without committing")
    h.open()
    h.clock.advance(9)
    h.report(.released) // duplicate raw HID state is not interaction
    h.clock.advance(1)
    check(h.input.picker == nil, "Duplicate HID states must not keep the wheel alive forever")
    h.report(.pressed)
    h.clock.advance(0.6)
    h.clock.advance(10)
    h.report(.released, .Clockwise(1))
    check(h.input.picker == nil && h.rotations.isEmpty && h.clicks == 0,
          "Timeout during the opening hold consumes its eventual release")
}

for sensitivity in [18, 36, 72, 360] {
    var picker = ModePickerState(selectedMode: .scrolling)
    for _ in 0..<(sensitivity / 3) { picker.rotate(.Clockwise(1), sensitivity: sensitivity) }
    check(picker.selectedMode == .playback, "120 physical degrees advances four selections at every sensitivity")
    for _ in 0..<(sensitivity / 3) { picker.rotate(.CounterClockwise(1), sensitivity: sensitivity) }
    check(picker.selectedMode == .scrolling, "Reverse rotation has the same normalized sensitivity")
    let h = Harness()
    h.open()
    h.report(.released, .Clockwise(sensitivity / 3), sensitivity: sensitivity, direction: -1)
    check(h.input.picker?.selectedMode == .playback && h.rotations.isEmpty,
          "Natural scrolling does not reverse picker navigation")
}

do {
    let h = Harness()
    h.input.onPickerChanged = { state in
        // For example, no display available or presentation lost focus.
        if state != nil { h.input.cancel() }
    }
    h.report(.pressed)
    h.clock.time = 1
    h.report(.released, .Clockwise(3))
    check(h.input.picker == nil && h.clicks == 0 && h.rotations.isEmpty,
          "A presentation cancelled synchronously cannot leak its opening report")
}

do {
    var picker = ModePickerState(selectedMode: .scrolling)
    picker.rotate(.Clockwise(2), sensitivity: 36)
    picker.rotate(.CounterClockwise(2), sensitivity: 36)
    check(picker.selectedMode == .scrolling, "Opposing partial movement cancels")
    picker.rotate(.Clockwise(2), sensitivity: 36)
    picker.select(.zoom)
    picker.rotate(.Clockwise(1), sensitivity: 36)
    check(picker.selectedMode == .zoom, "Pointer selection clears fractional rotation")
    picker.rotate(.Clockwise(0), sensitivity: 36)
    picker.rotate(.CounterClockwise(-1), sensitivity: 36)
    picker.rotate(.Clockwise(1), sensitivity: 0)
    check(picker.selectedMode == .zoom, "Invalid rotation and sensitivity are ignored")
}

for mode in Mode.allCases {
    check(Mode(savedValue: mode.savedValue) == mode, "All stored modes round-trip")
    check(NSImage(systemSymbolName: mode.symbolName, accessibilityDescription: nil) != nil,
          "Every mode has a real available SF Symbol")
}
check(Mode(savedValue: nil) == .scrolling && Mode(savedValue: "unknown") == .scrolling,
      "Missing or unrecognized preferences fall back to Scroll")
check(Mode.scrolling.savedValue == "scroll", "Preserve the legacy Scroll preference key")

// Hit testing and placement use the same geometry as drawing.
for mode in Mode.allCases {
    let point = RadialMenuGeometry.point(angle: RadialMenuGeometry.angle(for: mode), radius: 110)
    check(RadialMenuGeometry.mode(at: point) == mode, "Each icon lies in its own segment")
}
check(RadialMenuGeometry.mode(at: NSPoint(x: 150, y: 150)) == nil, "Center is a nonselecting dead zone")
check(RadialMenuGeometry.mode(at: .zero) == nil, "Transparent corner is outside the wheel")
for screen in [NSRect(x: 0, y: 25, width: 1440, height: 875),
               NSRect(x: -1920, y: -200, width: 1920, height: 1080),
               NSRect(x: 100, y: 900, width: 1280, height: 720)] {
    for point in [screen.origin, NSPoint(x: screen.maxX, y: screen.maxY),
                  NSPoint(x: screen.midX, y: screen.midY)] {
        let frame = RadialMenuGeometry.frame(around: point, in: screen)
        check(screen.insetBy(dx: 10, dy: 10).contains(frame), "Wheel stays inside the pointer display, including negative coordinates")
    }
}

// Real mouse-event cancellation must never leave a drag held across modes.
var mouse: [CGEvent] = []
let scroll = ScrollController(post: { mouse.append($0) })
scroll.onDown()
scroll.onDown()
scroll.onCancel()
scroll.onUp()
scroll.onCancel()
check(mouse.map(\.type) == [.leftMouseDown, .leftMouseUp], "Scroll cancellation must balance mouse down exactly once")
scroll.onDown()
scroll.onUp()
check(mouse.count == 4, "Scroll clicks must work again after cancellation")
scroll.onRotate(.Clockwise(1), -1)
check(mouse.last!.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) < 0,
      "Saved Natural direction must retain clockwise-down scrolling")

// Check actual keyboard events, including both edges and no inherited modifiers.
var keys: [CGEvent] = []
let zoom = ZoomController(post: { keys.append($0) })
zoom.onDown()
zoom.onCancel()
check(keys.isEmpty, "Long press in Zoom must not reset zoom")
zoom.onRotate(.Clockwise(2), -1)
zoom.onRotate(.CounterClockwise(1), 1)
zoom.onUp()
let expected = [kVK_ANSI_Equal, kVK_ANSI_Equal, kVK_ANSI_Equal, kVK_ANSI_Equal,
                kVK_ANSI_Minus, kVK_ANSI_Minus, kVK_ANSI_0, kVK_ANSI_0]
check(keys.map { Int($0.getIntegerValueField(.keyboardEventKeycode)) } == expected,
      "Zoom must map clockwise to +, counterclockwise to -, and press to 0")
check(keys.allSatisfy { $0.flags == .maskCommand }, "Zoom shortcuts must use only Command")
check(keys.enumerated().allSatisfy { $0.element.type == ($0.offset % 2 == 0 ? .keyDown : .keyUp) },
      "Every key down must have a matching key up")
zoom.onRotate(.Clockwise(0), 1)
zoom.onRotate(.CounterClockwise(-1), -1)
check(keys.count == 8, "Empty rotations must not generate keys")

// Route real controllers into recording sinks: holds and picker confirmation
// must not produce any mode action, regardless of the current mode.
var media: [Int32] = []
let playback = PlaybackController(post: { key, _, count in media += Array(repeating: key, count: count) })
for (mode, controller) in [(Mode.scrolling, scroll as Controller), (.playback, playback), (.zoom, zoom)] {
    mouse.removeAll(); keys.removeAll(); media.removeAll()
    let h = Harness()
    h.mode = mode
    h.input.onShortPress = { controller.onDown(); controller.onUp() }
    h.input.onCancelAction = { controller.onCancel() }
    h.input.onRotation = { controller.onRotate($0, $1) }
    h.report(.pressed)
    check(mouse.isEmpty && keys.isEmpty && media.isEmpty, "No controller output on initial press")
    h.clock.advance(0.6)
    h.report(.released)
    h.report(.released, .Clockwise(3))
    h.report(.pressed)
    h.clock.advance(0.1)
    h.report(.released, .Clockwise(3))
    check(mouse.isEmpty && keys.isEmpty && media.isEmpty, "Opening, browsing, and confirmation never emit mode actions")
    h.click()
    switch mode {
    case .scrolling: check(mouse.map(\.type) == [.leftMouseDown, .leftMouseUp], "Scroll emits one balanced click at short release")
    case .playback: check(media == [NX_KEYTYPE_PLAY], "Playback still plays/pauses on a short click")
    case .zoom: check(keys.count == 2, "Zoom still resets on a short click")
    }
}
playback.onCancel()
media.removeAll()
playback.onUp()
playback.onUp()
check(media == [NX_KEYTYPE_PLAY, NX_KEYTYPE_PLAY, NX_KEYTYPE_NEXT], "Playback double-click still advances the track")
print("Passed \(checks) checks: gestures, picker routing, cancellation, persistence, geometry, symbols, and recorded controller events.")
