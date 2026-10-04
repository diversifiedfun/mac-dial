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
    var profile: AppProfile?
    var savedMode = "scroll"
    var clicks = 0
    var rotations: [Int] = []
    var commits: [Mode] = []
    var feedback = 0
    var presentations = 0
    var dismissals = 0
    var configurations: [DialHardwareConfiguration] = []
    var failNextConfiguration = false
    lazy var configuration = DialConfigurationController { [unowned self] value in
        self.configurations.append(value)
        if self.failNextConfiguration {
            self.failNextConfiguration = false
            return false
        }
        return true
    }
    lazy var button = DialButtonHandler(now: { [unowned self] in self.clock.time },
                                       schedule: { [unowned self] in self.clock.schedule($0, $1) })
    lazy var input = DialInputCoordinator(currentMode: { [unowned self] in self.mode },
                                         currentProfile: { [unowned self] in self.profile }, button: button,
                                         schedule: { [unowned self] in self.clock.schedule($0, $1) })
    init() {
        configuration.update(haptics: true)
        configuration.didConnect()
        input.onMenuNavigationChanged = { [unowned self] in self.configuration.setMenuNavigationActive($0) }
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
        input.onFeedback = { [unowned self] in
            self.configuration.performFeedback { self.feedback += 1 }
        }
    }
    func report(_ state: Dial.ButtonState, _ rotation: Dial.Rotation? = nil,
                direction: Int = -1, generation: UInt64? = nil) {
        input.handle(button: state, rotation: rotation,
                     rotationIsCurrent: generation.map(configuration.acceptsRotation) ?? true,
                     scrollDirection: direction)
    }
    func open() {
        report(.pressed)
        clock.advance(input.menuPressDuration.seconds)
        report(.released)
    }
    func click() {
        report(.pressed)
        clock.advance(0.1)
        report(.released)
    }
}

// Recording transport: real configuration policy and gesture routing, no HID.
for (sensitivity, normal, menu) in [(WheelSensitivity.low, 18, 12), (.medium, 36, 18),
                                  (.high, 72, 24), (.extreme, 360, 36)] {
    let h = Harness()
    h.configuration.update(sensitivity: sensitivity)
    check(h.configurations.last == DialHardwareConfiguration(ticksPerRevolution: normal, haptics: true),
          "Normal sensitivity keeps its existing mapping")
    let before = h.configuration.withInputContext { 0 }.generation
    h.open()
    check(h.configurations.last == DialHardwareConfiguration(ticksPerRevolution: menu, haptics: true),
          "Menu uses the agreed sensitivity mapping")
    check(!h.configuration.acceptsRotation(before), "Opening invalidates queued normal rotation")
    let writes = h.configurations.count
    let openingFeedback = h.feedback
    for _ in 0..<7 { h.report(.released, .Clockwise(1)) }
    check(h.input.picker?.selectedMode == .playback, "Seven clicks advance seven choices")
    check(h.configurations.count == writes, "Selection does not repeatedly reprogram hardware")
    check(h.feedback == openingFeedback, "Dial rotation never adds a software haptic")
    h.input.moveSelection(by: 1)
    check(h.feedback == openingFeedback + 1, "Keyboard selection retains its software haptic")
    h.input.highlight(.scrolling)
    check(h.feedback == openingFeedback + 2, "Pointer selection retains its software haptic")
    h.click()
    check(h.feedback == openingFeedback + 3, "Confirmation retains its software haptic")
    check(h.configurations.last?.ticksPerRevolution == normal, "Confirmation restores normal sensitivity")
    for profile: AppProfile? in [nil, .lightroom] {
        h.profile = profile
        h.open()
        check(h.configurations.last?.ticksPerRevolution == menu, "Choice count does not change menu spacing")
        h.input.cancel()
    }
}

do {
    let h = Harness()
    h.open()
    h.configuration.update(sensitivity: .extreme)
    check(h.configurations.last?.ticksPerRevolution == 36, "Preference changes use the menu mapping while open")
    h.input.cancel()
    check(h.configurations.last?.ticksPerRevolution == 360, "Closing restores the latest preference")
    h.configuration.update(haptics: false)
    let feedback = h.feedback
    h.open()
    h.report(.released, .Clockwise(1))
    check(h.input.picker?.selectedMode == .playback, "Haptics disabled still advances one choice per tick")
    h.input.moveSelection(by: 1)
    h.input.highlight(.scrolling)
    h.click()
    check(h.feedback == feedback && h.configurations.last?.haptics == false,
          "Disabled haptics suppresses both hardware and software feedback")
    h.open()
    h.configuration.update(haptics: true)
    check(h.configurations.last?.ticksPerRevolution == 36 && h.configurations.last?.haptics == true,
          "Enabling haptics while open preserves menu sensitivity")
    let token = h.configuration.withInputContext { 0 }.generation
    let writes = h.configurations.count
    h.configuration.update(haptics: true)
    check(h.configurations.count == writes && h.configuration.acceptsRotation(token),
          "Unchanged preferences do not write hardware or discard input")
}

// All non-confirming exits share the same restoration callback.
for reason in ["escape", "outside click", "lost focus", "app change", "space change", "display change",
               "sleep", "menu-bar mode", "timeout", "second hold", "shutdown", "presentation failure"] {
    let h = Harness()
    h.configuration.update(sensitivity: .low)
    if reason == "presentation failure" {
        h.input.onPickerChanged = { state in if state != nil { h.input.cancel() } }
    }
    h.open()
    if reason == "timeout" { h.clock.advance(10) }
    else if reason == "second hold" {
        h.report(.pressed)
        h.clock.advance(h.input.menuPressDuration.seconds)
        h.report(.released, .Clockwise(1))
    } else { h.input.cancel() }
    check(h.input.picker == nil && h.configurations.last?.ticksPerRevolution == 18,
          "\(reason) restores normal sensitivity")
    check(h.commits.isEmpty && h.rotations.isEmpty && h.clicks == 0,
          "\(reason) cannot commit or leak an action")
    if reason == "shutdown" {
        h.configuration.shutdown()
        check(h.configurations.last == DialHardwareConfiguration(ticksPerRevolution: 18, haptics: false),
              "Shutdown restores normal spacing and silences the device")
        h.configuration.didConnect()
        check(h.configurations.last?.haptics == true, "Shutdown does not overwrite the haptics preference")
    }
}

do {
    let h = Harness()
    h.configuration.update(sensitivity: .high)
    h.open()
    let queued = h.configuration.withInputContext { 0 }.generation
    h.configuration.didDisconnect()
    h.input.cancel()
    check(!h.configuration.acceptsRotation(queued), "Disconnect invalidates pending menu input")
    let writes = h.configurations.count
    h.configuration.update(sensitivity: .low, haptics: false)
    check(h.configurations.count == writes, "Disconnected preference changes do not write the transport")
    check(!h.configuration.setMenuNavigationActive(true), "A disconnected device cannot enter menu configuration")
    h.configuration.didConnect()
    check(h.configurations.last == DialHardwareConfiguration(ticksPerRevolution: 18, haptics: false),
          "Reconnect restores the latest normal preferences")
}

do {
    let h = Harness()
    let normalGeneration = h.configuration.withInputContext { 0 }.generation
    h.report(.pressed)
    h.clock.advance(h.input.menuPressDuration.seconds)
    h.report(.released, .Clockwise(1), generation: normalGeneration)
    check(h.input.picker?.isArmed == true && h.input.picker?.selectedMode == .scrolling,
          "An old generation release arms the menu without rotating or cancelling it")
    let menuGeneration = h.configuration.withInputContext { 0 }.generation
    h.report(.released, .Clockwise(1), generation: normalGeneration)
    check(h.input.picker?.selectedMode == .scrolling, "Old normal ticks cannot advance the open menu")
    h.report(.released, .Clockwise(1), generation: menuGeneration)
    check(h.input.picker?.selectedMode == .playback, "The first current tick advances immediately")
    h.report(.pressed, generation: menuGeneration)
    h.configuration.update(sensitivity: .high)
    h.clock.advance(0.1)
    h.report(.released, .Clockwise(3), generation: menuGeneration)
    check(h.commits == [.playback] && h.rotations.isEmpty && h.clicks == 0,
          "A stale rotation still delivers its confirmation release without leaking actions")
    h.report(.released, .Clockwise(1), generation: menuGeneration)
    check(h.rotations.isEmpty, "Queued menu ticks cannot escape into the selected controller")
    let current = h.configuration.withInputContext { 0 }.generation
    h.report(.released, .Clockwise(1), generation: current)
    check(h.rotations == [-1], "The first fresh normal tick resumes the selected controller")
}

do {
    let h = Harness()
    h.failNextConfiguration = true
    h.open()
    check(h.input.picker == nil && h.configurations.suffix(2).map(\.ticksPerRevolution) == [18, 36],
          "A failed menu write cancels opening and restores normal configuration")
    check(h.feedback == 0 && h.clicks == 0 && h.rotations.isEmpty,
          "Failed opening neither announces success nor leaks an action")
    h.click()
    check(h.clicks == 1, "Input recovers after a failed opening")
    h.open()
    h.failNextConfiguration = true
    if !h.configuration.update(sensitivity: .high) { h.input.cancel() }
    check(h.input.picker == nil && h.configurations.last?.ticksPerRevolution == 72,
          "A failed preference change closes the menu and restores the new normal preference")
}

do {
    var fail = false
    var writes: [DialHardwareConfiguration] = []
    let configuration = DialConfigurationController { value in
        writes.append(value)
        return !fail
    }
    configuration.didConnect()
    fail = true
    check(!configuration.setMenuNavigationActive(true), "Both failed menu and restore writes report failure")
    let token = configuration.withInputContext { 0 }.generation
    check(!configuration.acceptsRotation(token), "Unconfigured hardware cannot route rotation")
    fail = false
    check(configuration.setMenuNavigationActive(false), "Normal configuration can be retried after failure")
    let recovered = configuration.withInputContext { 0 }.generation
    check(configuration.acceptsRotation(recovered) && !configuration.acceptsRotation(token),
          "Only input read after configuration recovers is accepted")
    let report = DialHardwareConfiguration(ticksPerRevolution: 360, haptics: true).featureReport
    check(report == [1, 0x68, 0x01, 0, 3, 0, 0, 0], "HID configuration preserves both sensitivity bytes")
}

check(Harness().input.menuPressDuration == .ms600, "Existing users retain the 600 ms default")

do {
    let suite = "MacDial.MenuPressDurationTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    check(MenuPressDuration.load(from: defaults) == .ms600, "Missing preference defaults to 600 ms")
    for option in MenuPressDuration.allCases {
        option.save(to: defaults)
        check(MenuPressDuration.load(from: UserDefaults(suiteName: suite)!) == option,
              "Every duration is restored from saved preferences")
    }
    for invalid in [-1, 0, 250, 1000] {
        defaults.set(invalid, forKey: "menuPressDuration")
        check(MenuPressDuration.load(from: defaults) == .ms600, "Unsupported preference defaults to 600 ms")
    }
}

// Every choice uses the same boundary for its timer and HID timestamps,
// including release before an overdue timer is delivered.
for option in MenuPressDuration.allCases {
    let threshold = option.seconds
    for duration in [0.0, threshold - 0.001, threshold, threshold + 0.001, 3.0] {
        let h = Harness()
        h.input.menuPressDuration = option
        h.report(.pressed)
        h.report(.pressed)
        check(h.clicks == 0, "Pressing must not immediately click")
        h.clock.time = duration
        h.report(.released)
        h.report(.released)
        if duration < threshold {
            check(h.clicks == 1 && h.input.picker == nil, "Short press clicks exactly once")
        } else {
            check(h.clicks == 0 && h.input.picker?.isArmed == true, "Overdue long press opens and arms")
            check(h.mode == .scrolling && h.commits.isEmpty, "Opening never changes the active mode")
        }
    }

    // Reports timestamped on the HID thread retain the physical hold duration
    // even when both edges wait behind a busy main queue.
    for duration in [0.1, threshold - 0.001, threshold, 1.0] {
        let h = Harness()
        h.input.menuPressDuration = option
        h.clock.time = 10
        h.input.handle(button: .pressed, rotation: nil, scrollDirection: -1, timestamp: 0)
        h.input.handle(button: .released, rotation: nil, scrollDirection: -1, timestamp: duration)
        check(h.clicks == (duration < threshold ? 1 : 0), "Queued reports preserve real press duration")
        check((h.input.picker != nil) == (duration >= threshold), "A main-queue stall cannot misclassify a hold")
        let presentations = h.presentations
        h.clock.advance(1)
        check(h.presentations == presentations, "Late timers cannot open or duplicate a released gesture")
    }

    let h = Harness()
    h.input.menuPressDuration = option
    h.report(.pressed)
    h.clock.advance(threshold - 0.001)
    check(h.input.picker == nil, "Timer cannot open the menu before the selected duration")
    h.clock.time = threshold
    h.clock.advance(0)
    check(h.input.picker?.isArmed == false && h.clicks == 0, "Timer opens at the selected duration without clicking")
    h.report(.released)
    check(h.input.picker?.isArmed == true, "Release arms the menu at every duration")
    h.report(.pressed)
    h.clock.advance(threshold + 0.001)
    check(h.input.picker == nil && h.commits.isEmpty, "Second hold uses the selected duration to cancel")
    h.report(.released)
    h.click()
    check(h.clicks == 1, "Short clicks resume after cancellation at every duration")
}

// Changing a preference mid-hold must not make the timer and release disagree.
for (original, updated) in [(MenuPressDuration.ms600, MenuPressDuration.ms200), (.ms200, .ms600)] {
    for timerFires in [false, true] {
        let h = Harness()
        h.input.menuPressDuration = original
        h.report(.pressed)
        h.input.menuPressDuration = updated
        h.clock.time = original.seconds - 0.001
        h.report(.pressed)
        check(h.input.picker == nil, "Preference changes do not shorten a hold already in progress")
        h.clock.time = original.seconds
        if timerFires { h.clock.advance(0) }
        h.report(.released)
        check(h.input.picker?.isArmed == true && h.clicks == 0,
              "Timer and release retain the original duration for an active hold")
        h.input.cancel()
        h.clock.time = 10
        h.report(.pressed)
        h.clock.advance(updated.seconds - 0.001)
        check(h.input.picker == nil, "Next hold waits for the updated duration")
        h.clock.advance(0.002)
        check(h.input.picker?.isArmed == false, "Next hold uses the updated duration immediately")
    }
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
    h.report(.released, .Clockwise(1))
    check(h.input.picker?.selectedMode == .playback && h.mode == .scrolling,
          "One tick highlights Playback without committing")
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
    h.report(.released, .Clockwise(1)) // any real browsing activity
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

for sensitivity in WheelSensitivity.allCases {
    let h = Harness()
    h.configuration.update(sensitivity: sensitivity)
    h.open()
    h.report(.released, .Clockwise(1), direction: -1)
    check(h.input.picker?.selectedMode == .playback && h.rotations.isEmpty,
          "Every sensitivity advances one choice; natural scrolling does not reverse navigation")
    h.report(.released, .CounterClockwise(1))
    check(h.input.picker?.selectedMode == .scrolling, "Reversal takes exactly one tick")
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
    picker.rotate(.Clockwise(2))
    picker.rotate(.CounterClockwise(2))
    check(picker.selectedMode == .scrolling, "Opposing multi-tick movement returns to the starting choice")
    picker.rotate(.Clockwise(2))
    picker.select(.zoom)
    picker.rotate(.Clockwise(1))
    check(picker.selectedMode == .scrolling, "One tick after pointer selection immediately advances")
    picker.rotate(.Clockwise(0))
    picker.rotate(.CounterClockwise(-1))
    check(picker.selectedMode == .scrolling, "Invalid rotation counts are ignored")
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
for mode in Mode.generalModes {
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
    default: preconditionFailure("General controllers only")
    }
}
playback.onCancel()
media.removeAll()
playback.onUp()
playback.onUp()
check(media == [NX_KEYTYPE_PLAY, NX_KEYTYPE_PLAY, NX_KEYTYPE_NEXT], "Playback double-click still advances the track")
// Lightroom is a flat sequence; the parent group is not an extra stop.
let lightroomModes = AppProfile.lightroom.availableModes
check(lightroomModes == [.scrolling, .playback, .zoom, .lightroomCrop, .lightroomFineTune, .lightroomBrush],
      "Six choices have the requested clockwise order")
for start in lightroomModes {
    var picker = ModePickerState(selectedMode: start, profile: .lightroom)
    for next in 1...6 {
        picker.move(by: 1)
        check(picker.selectedMode == lightroomModes[(lightroomModes.firstIndex(of: start)! + next) % 6],
              "Forward navigation crosses groups and wraps without a parent stop")
    }
    picker.move(by: -6)
    check(picker.selectedMode == start, "Reverse navigation wraps all six choices")
}
for count in [1, 2, 4, 6, 13] {
    var picker = ModePickerState(selectedMode: .zoom, profile: .lightroom)
    picker.rotate(.Clockwise(count))
    check(picker.selectedMode == lightroomModes[(2 + count) % 6], "Each tick advances one Lightroom choice")
    picker.rotate(.CounterClockwise(count))
    check(picker.selectedMode == .zoom, "Multi-tick reversal crosses groups and wraps correctly")
}
var unavailable = ModePickerState(selectedMode: .lightroomCrop)
check(unavailable.selectedMode == .scrolling && !unavailable.select(.lightroomBrush),
      "Unavailable app modes cannot be selected outside their profile")

// Preferences are isolated from the user's actual defaults.
let suite = "MacDial.Tests." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defaults.set("zoom", forKey: "mode")
let context = AppModeContext(defaults: defaults)
context.activate(bundleIdentifier: AppProfile.lightroom.bundleIdentifier)
check(context.currentMode == .zoom, "First Lightroom visit inherits the general mode")
check(defaults.string(forKey: "appMode." + AppProfile.lightroom.bundleIdentifier) == nil,
      "Merely visiting Lightroom does not create an explicit preference")
context.select(.lightroomFineTune)
check(context.currentMode == .lightroomFineTune && defaults.string(forKey: "mode") == "zoom",
      "Selecting a Lightroom child preserves the general preference")
context.activate(bundleIdentifier: "com.apple.finder")
check(context.currentMode == .zoom && context.profile == nil, "Leaving Lightroom restores general Zoom")
check(!context.select(.lightroomBrush), "A stale contextual menu action cannot select an unavailable mode")
context.select(.playback)
context.activate(bundleIdentifier: AppProfile.lightroom.bundleIdentifier)
check(context.currentMode == .lightroomFineTune, "Returning restores the last Lightroom child")
context.select(.scrolling)
context.activate(bundleIdentifier: nil)
check(context.currentMode == .playback, "A general selection inside Lightroom is also kept separate")
let relaunched = AppModeContext(defaults: defaults)
relaunched.activate(bundleIdentifier: AppProfile.lightroom.bundleIdentifier)
check(relaunched.currentMode == .scrolling, "A general choice in Lightroom survives relaunch")
defaults.set("unknown-future-mode", forKey: "appMode." + AppProfile.lightroom.bundleIdentifier)
check(relaunched.currentMode == .playback, "An unknown app preference falls back to the saved general mode")
relaunched.select(.lightroomBrush)
let reopened = AppModeContext(defaults: defaults)
reopened.activate(bundleIdentifier: AppProfile.lightroom.bundleIdentifier)
check(reopened.currentMode == .lightroomBrush, "A Lightroom child survives relaunch")
relaunched.activate(bundleIdentifier: "com.adobe.Lightroom")
check(relaunched.profile == nil && relaunched.currentMode == .playback, "Cloud Lightroom does not match the Classic profile")
defaults.removePersistentDomain(forName: suite)

let gate = InputContextGate()
let oldToken = gate.token
gate.invalidate(at: 10)
check(!gate.accepts(oldToken, timestamp: 11), "Queued reports are rejected after a context change")
check(!gate.accepts(gate.token, timestamp: 9), "An old timestamp is rejected even if stamped after invalidation")
check(gate.accepts(gate.token, timestamp: 10), "New context reports are accepted")
for staleState: Dial.ButtonState in [.pressed, .released] {
    let h = Harness()
    h.profile = .lightroom
    h.mode = .lightroomCrop
    h.report(.pressed)
    h.input.cancel() // foreground switch cancels before applying the new context
    h.profile = nil
    h.mode = .zoom
    h.input.discard(button: staleState)
    h.clock.advance(1)
    h.report(.released, .Clockwise(5))
    check(h.clicks == 0 && h.input.picker == nil, "A stale press cannot become a click or long hold in the new app")
    if staleState == .pressed { check(h.rotations.isEmpty, "Release of a stale held press consumes its rotation") }
    h.click()
    check(h.clicks == 1, "A fresh press works after the context transition")
}
do {
    let h = Harness()
    h.profile = .lightroom
    h.mode = .lightroomBrush
    h.open()
    h.input.highlight(.lightroomFineTune)
    h.input.cancel()
    h.profile = nil
    h.mode = .playback
    h.input.confirmSelection()
    h.clock.advance(11)
    check(h.commits.isEmpty && h.mode == .playback, "App switching cancels pending selection and stale timers")
}

let groupedLayout = RadialMenuLayout(profile: .lightroom)
check(groupedLayout.diameter == 432, "Contextual bounds are 432 points")
for segment in groupedLayout.segments {
    let point = groupedLayout.point(angle: segment.angle, radius: segment.iconRadius)
    check(groupedLayout.mode(at: point) == segment.mode, "Shared geometry identifies every child and excludes the parent")
    check(groupedLayout.outline.contains(point), "Each icon lies inside the material mask")
    check(groupedLayout.outline.compatibleCGPath.contains(point), "Native layer mask matches drawing geometry")
    if let mode = segment.mode {
        for angle in [segment.angle - segment.sweep / 2 + 0.1, segment.angle + segment.sweep / 2 - 0.1] {
            check(groupedLayout.mode(at: groupedLayout.point(angle: angle, radius: segment.iconRadius)) == mode,
                  "Pointer selection reaches both edges of each wedge")
        }
    }
}
check(groupedLayout.mode(at: groupedLayout.center) == nil, "Contextual center is not a selection target")
check(!groupedLayout.outline.contains(groupedLayout.point(angle: 0, radius: 180)),
      "Unused outer-ring space stays transparent")
for screen in [NSRect(x: 0, y: 25, width: 1440, height: 875), NSRect(x: -1920, y: -200, width: 1920, height: 1080)] {
    for point in [screen.origin, NSPoint(x: screen.maxX, y: screen.maxY)] {
        check(screen.insetBy(dx: 10, dy: 10).contains(groupedLayout.frame(around: point, in: screen)),
              "Larger grouped wheel stays inside each display")
    }
}

for (mode, clockwise, counterclockwise, click) in [
    (Mode.lightroomCrop, kVK_RightArrow, kVK_LeftArrow, kVK_ANSI_R),
    (.lightroomFineTune, kVK_ANSI_Equal, kVK_ANSI_Minus, kVK_ANSI_Backslash),
    (.lightroomBrush, kVK_ANSI_RightBracket, kVK_ANSI_LeftBracket, kVK_ANSI_A)
] {
    var events: [CGEvent] = []
    var pids: [pid_t] = []
    var foreground: pid_t? = 42
    let controller = LightroomController(mode: mode, targetProcess: { foreground }, post: { event, pid in
        events.append(event)
        pids.append(pid)
    })
    controller.onDown()
    controller.onCancel()
    check(events.isEmpty, "Opening a menu or cancelling never sends a Lightroom key")
    controller.onRotate(.Clockwise(2), -1)
    controller.onRotate(.CounterClockwise(1), 1)
    controller.onUp()
    check(events.map { Int($0.getIntegerValueField(.keyboardEventKeycode)) } ==
          [clockwise, clockwise, clockwise, clockwise, counterclockwise, counterclockwise, click, click],
          "Lightroom mappings emit one key pair per step and the specified click")
    check(events.enumerated().allSatisfy { $0.element.type == ($0.offset % 2 == 0 ? .keyDown : .keyUp) },
          "Lightroom always balances key down and up")
    check(events.prefix(6).allSatisfy { $0.flags == (mode == .lightroomCrop ? .maskCommand : []) }
          && events.suffix(2).allSatisfy { $0.flags.isEmpty }, "Only photo navigation uses Command; no coarse Shift modifier")
    check(pids.allSatisfy { $0 == 42 }, "Events target the verified Lightroom process")
    controller.onRotate(.Clockwise(0), 1)
    controller.onRotate(.CounterClockwise(-1), 1)
    foreground = nil
    controller.onUp()
    controller.onRotate(.Clockwise(8), 1)
    check(events.count == 8, "Inactive Lightroom and invalid counts emit no events")
    foreground = 42
    events.removeAll()
    let h = Harness()
    h.profile = .lightroom
    h.mode = mode
    h.input.onShortPress = { controller.onDown(); controller.onUp() }
    h.input.onRotation = { controller.onRotate($0, $1) }
    h.input.onCancelAction = { controller.onCancel() }
    h.open()
    h.input.highlight(mode)
    h.report(.pressed)
    h.clock.advance(0.1)
    h.report(.released, .Clockwise(8))
    check(events.isEmpty && h.commits == [mode], "Confirming a Lightroom mode does not execute its click or rotation")
    h.click()
    check(events.count == 2, "First new click after confirmation executes the Lightroom shortcut")
}
do {
    var active = true
    var events: [CGEvent] = []
    let controller = LightroomController(mode: .lightroomCrop, targetProcess: { active ? 42 : nil }, post: { event, _ in
        events.append(event)
        active = false
    })
    controller.onRotate(.Clockwise(5), 1)
    check(events.map(\.type) == [.keyDown, .keyUp], "Focus change during a batch completes its pair and stops subsequent shortcuts")
}
print("Passed \(checks) checks: gestures, contextual routing, preferences, geometry and recorded events.")
