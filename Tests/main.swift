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
    var confirmations: [ModePickerState] = []
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
            return true
        }
        input.onConfirmation = { [unowned self] in self.confirmations.append($0) }
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
    for _ in 0..<(Mode.generalModes.count * 2 + 1) { h.report(.released, .Clockwise(1)) }
    check(h.input.picker?.selectedMode == .playback, "Multiple revolutions advance exactly one choice per tick")
    check(h.configurations.count == writes, "Selection does not repeatedly reprogram hardware")
    check(h.feedback == openingFeedback, "Dial rotation never adds a software haptic")
    h.input.moveSelection(by: 1)
    check(h.feedback == openingFeedback + 1, "Keyboard selection retains its software haptic")
    h.input.highlight(.scrolling)
    check(h.feedback == openingFeedback + 2, "Pointer selection retains its software haptic")
    h.click()
    check(h.feedback == openingFeedback + 3, "Confirmation retains its software haptic")
    check(h.configurations.last?.ticksPerRevolution == normal, "Confirmation restores normal sensitivity")
    for profile: AppProfile? in [nil, .lightroom, .editwall] {
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
               "sleep", "menu-bar mode", "timeout", "shutdown", "presentation failure"] {
    let h = Harness()
    h.configuration.update(sensitivity: .low)
    if reason == "presentation failure" {
        h.input.onPickerChanged = { state in if state != nil { h.input.cancel() } }
    }
    h.open()
    if reason == "timeout" { h.clock.advance(10) }
    else { h.input.cancel() }
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

check(Harness().input.radialMenuStartPosition == .lastSelected,
      "Existing users retain the last-selected opening behavior")

do {
    let suite = "MacDial.RadialMenuStartPositionTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    check(RadialMenuStartPosition.load(from: defaults) == .lastSelected,
          "Missing starting-position preference defaults to Last Selected")
    defaults.set("zoom", forKey: "mode")
    defaults.set("lightroomFineTune", forKey: "appMode." + AppProfile.lightroom.bundleIdentifier)
    for option in RadialMenuStartPosition.allCases {
        option.save(to: defaults)
        check(RadialMenuStartPosition.load(from: UserDefaults(suiteName: suite)!) == option,
              "Each starting-position preference survives a fresh defaults instance")
    }
    check(defaults.string(forKey: "mode") == "zoom"
          && defaults.string(forKey: "appMode." + AppProfile.lightroom.bundleIdentifier) == "lightroomFineTune",
          "Saving the starting position preserves general and app-specific mode preferences")
    for invalid: Any in ["", "unknown", 42, true, ["firstItem"]] {
        defaults.set(invalid, forKey: "radialMenuStartPosition")
        check(RadialMenuStartPosition.load(from: defaults) == .lastSelected,
              "Invalid starting-position preferences fall back to Last Selected")
    }
}

// Both policies open independently of the active mode, including app modes.
for profile: AppProfile? in [nil, .lightroom, .editwall] {
    let modes = profile?.availableModes ?? Mode.generalModes
    for mode in modes {
        for option in RadialMenuStartPosition.allCases {
            let h = Harness()
            h.profile = profile
            h.mode = mode
            h.savedMode = mode.savedValue
            h.input.radialMenuStartPosition = option
            h.report(.pressed)
            h.clock.advance(h.input.menuPressDuration.seconds)
            let expected = option == .firstItem ? modes[0] : mode
            check(h.input.picker?.selectedMode == expected && h.input.picker?.isArmed == false,
                  "Opening highlights the configured choice before release")
            h.report(.pressed, .Clockwise(1))
            h.input.confirmSelection()
            check(h.input.picker?.selectedMode == expected && h.commits.isEmpty,
                  "The opening hold cannot navigate or confirm either starting policy")
            h.report(.released, .Clockwise(1))
            check(h.input.picker?.selectedMode == expected && h.input.picker?.isArmed == true,
                  "Release arms the configured choice without advancing it")
            h.report(.released, .Clockwise(1))
            check(h.input.picker?.selectedMode == expected.advanced(by: 1, in: modes),
                  "The first navigation tick advances from the configured starting choice")
            h.input.cancel()
            check(h.mode == mode && h.savedMode == mode.savedValue && h.commits.isEmpty,
                  "Opening, browsing and cancelling preserve the active and saved modes")
            check(h.clicks == 0 && h.rotations.isEmpty,
                  "Starting-position selection never leaks a mode action")
        }

        for ticks in 0...3 {
            let h = Harness()
            h.profile = profile
            h.mode = mode
            h.savedMode = mode.savedValue
            h.input.radialMenuStartPosition = .firstItem
            h.open()
            for _ in 0..<ticks { h.report(.released, .Clockwise(1)) }
            check(h.input.picker?.selectedMode == Mode.generalModes[ticks] && h.mode == mode,
                  "Zero through three clockwise ticks predictably highlight the general choices")
            h.click()
            check(h.commits == [Mode.generalModes[ticks]] && h.savedMode == Mode.generalModes[ticks].savedValue,
                  "A short click confirms and saves the counted choice")
            h.open()
            check(h.input.picker?.selectedMode == .scrolling,
                  "First Item resets the next opening after confirming any counted choice")
            h.input.cancel()
        }
    }

    for sensitivity in [WheelSensitivity.low, .medium, .high, .extreme] {
        for direction in [-1, 1] {
            let h = Harness()
            h.profile = profile
            h.mode = modes.last!
            h.configuration.update(sensitivity: sensitivity)
            h.input.radialMenuStartPosition = .firstItem
            h.open()
            let openingFeedback = h.feedback
            h.report(.released, .CounterClockwise(1), direction: direction)
            check(h.input.picker?.selectedMode == modes.last,
                  "Reverse navigation from First Item wraps at every sensitivity and scroll direction")
            for expected in modes {
                h.report(.released, .Clockwise(1), direction: direction)
                check(h.input.picker?.selectedMode == expected,
                      "Each tick follows the selectable order, including Lightroom children")
            }
            check(h.feedback == openingFeedback && h.configurations.last?.haptics == true,
                  "First Item preserves hardware haptics without adding software rotation feedback")
            h.input.cancel()
        }
    }
}

for (original, updated) in [(RadialMenuStartPosition.lastSelected, RadialMenuStartPosition.firstItem),
                            (.firstItem, .lastSelected)] {
    let h = Harness()
    h.mode = .zoom
    h.input.radialMenuStartPosition = original
    h.open()
    h.input.highlight(.playback)
    let presentations = h.presentations
    let feedback = h.feedback
    h.input.radialMenuStartPosition = updated
    check(h.input.picker?.selectedMode == .playback && h.presentations == presentations && h.feedback == feedback,
          "Changing the preference leaves an open picker's highlight and feedback untouched")
    h.input.cancel()
    h.open()
    check(h.input.picker?.selectedMode == (updated == .firstItem ? .scrolling : .zoom),
          "The next opening applies the updated preference in either direction")
    h.input.cancel()
}

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
    check(h.commits == [.scrolling] && h.confirmations.count == 1,
          "Armed selection confirms on the press edge without waiting for a timer or release")
    h.clock.advance(threshold + 0.001)
    h.report(.pressed, .Clockwise(3))
    check(h.input.picker == nil && h.commits == [.scrolling], "Selection confirms on press at every opening-hold duration")
    h.report(.released)
    h.click()
    check(h.clicks == 1, "Short clicks resume after the confirming hold is released")
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
    check(h.commits == [.playback] && h.confirmations.count == 1 && h.dismissals == 0,
          "Commit and confirmation occur once without a cancellation dismissal")
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
    check(h.input.picker?.selectedMode == .undoRedo, "Undo/Redo follows Zoom")
    h.input.moveSelection(by: 1)
    check(h.input.picker?.selectedMode == .scrolling, "Clockwise selection wraps")
    h.input.moveSelection(by: -1)
    check(h.input.picker?.selectedMode == .undoRedo, "Counterclockwise selection wraps")
    h.input.highlight(.playback)
    h.input.confirmSelection()
    check(h.mode == .playback && h.savedMode == "playback", "Pointer/keyboard confirmation commits")
}

// Escape, outside click, lifecycle changes and manual mode selection share cancel.
for cancelWhilePressed in [false, true] {
    let h = Harness()
    if cancelWhilePressed {
        h.report(.pressed)
        h.clock.advance(h.input.menuPressDuration.seconds)
    } else { h.open() }
    h.input.highlight(.zoom)
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
    check(h.input.picker == nil && h.mode == .zoom && h.commits == [.zoom], "A held selection confirms immediately")
    h.report(.pressed, .Clockwise(3))
    h.report(.released, .Clockwise(3))
    check(h.clicks == 0 && h.rotations.isEmpty, "Confirming hold suppresses all input until release")
    h.open()
    h.report(.pressed)
    h.clock.time += 0.7 // A held confirmation cannot reopen the menu.
    h.report(.released, .Clockwise(3))
    check(h.input.picker == nil && h.clicks == 0 && h.rotations.isEmpty,
          "A delayed confirmation release must not click or rotate")
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
    picker.select(.undoRedo)
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

// Scroll clicks toggle styles and never synthesize mouse button events.
var mouse: [CGEvent] = []
let scroll = ScrollController(post: { mouse.append($0) })
scroll.onDown()
scroll.onDown()
scroll.onCancel()
scroll.onUp()
check(scroll.style == .smooth && mouse.isEmpty, "Cancelled Scroll clicks do not toggle or emit mouse input")
scroll.onDown()
scroll.onUp()
scroll.onUp()
check(scroll.style == .stepped && mouse.isEmpty, "Scroll toggles exactly once on short release")
scroll.onRotate(.Clockwise(1), -1)
check(mouse.last!.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -24,
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

var historyKeys: [CGEvent] = []
var historyPIDs: [pid_t] = []
var historyForeground: pid_t? = 42
let historyClock = Clock()
let undoRedo = UndoRedoController(now: { historyClock.time }, doubleClickInterval: { 0.5 },
                                 schedule: { historyClock.schedule($0, $1) },
                                 targetProcess: { historyForeground }, post: { event, pid in
    historyKeys.append(event)
    historyPIDs.append(pid)
})
undoRedo.onDown()
undoRedo.onCancel()
check(historyKeys.isEmpty, "Initial press and cancellation never undo")
for direction in [1, -1] {
    historyKeys.removeAll()
    undoRedo.onRotate(.Clockwise(2), direction)
    undoRedo.onRotate(.CounterClockwise(3), direction)
    check(historyKeys.count == 10, "Each history tick emits one pair, including multi-step reversal")
    check(historyKeys.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_Z) },
          "Both history actions use Z")
    check(historyKeys.prefix(4).allSatisfy { $0.flags == [.maskCommand, .maskShift] }
          && historyKeys.suffix(6).allSatisfy { $0.flags == .maskCommand },
          "Right redoes and left undoes with exact modifiers, independent of Scroll Direction")
    check(historyKeys.enumerated().allSatisfy { $0.element.type == ($0.offset % 2 == 0 ? .keyDown : .keyUp) },
          "Every history key down has a matching key up")
}
historyKeys.removeAll()
undoRedo.onUp()
check(historyKeys.isEmpty, "Single-click undo waits for the double-click window")
historyClock.advance(0.5)
check(historyKeys.map(\.type) == [.keyDown, .keyUp] && historyKeys.allSatisfy { $0.flags == .maskCommand },
      "Single-click timeout performs exactly one undo")
check(historyPIDs.allSatisfy { $0 == 42 }, "History shortcuts target the foreground process")
for count in [0, -1] {
    undoRedo.onRotate(.Clockwise(count), 1)
    undoRedo.onRotate(.CounterClockwise(count), -1)
}
historyForeground = nil
undoRedo.onUp()
undoRedo.onRotate(.CounterClockwise(3), 1)
undoRedo.onRotate(.Clockwise(3), -1)
check(historyKeys.count == 2, "Invalid counts and missing foreground application emit nothing")
historyForeground = 42

for rotation: Dial.Rotation in [.Clockwise(5), .CounterClockwise(5)] {
    for changedOn: CGEventType in [.keyDown, .keyUp] {
        for newPID: pid_t? in [84, nil] {
            var foreground: pid_t? = 42
            var events: [CGEvent] = []
            var destinations: [pid_t] = []
            let controller = UndoRedoController(targetProcess: { foreground }, post: { event, pid in
                events.append(event)
                destinations.append(pid)
                if event.type == changedOn { foreground = newPID }
            })
            controller.onRotate(rotation, 1)
            check(events.map(\.type) == [.keyDown, .keyUp] && destinations == [42, 42],
                  "Focus loss or switching completes the original pair and stops remaining history steps")
        }
    }
}
do {
    var lookups = 0
    var events: [CGEvent] = []
    let clock = Clock()
    let controller = UndoRedoController(now: { clock.time }, doubleClickInterval: { 0.5 },
                                       schedule: { clock.schedule($0, $1) }, targetProcess: {
        lookups += 1
        return lookups == 1 ? 42 : 84
    }, post: { event, _ in events.append(event) })
    controller.onRotate(.CounterClockwise(5), 1)
    check(events.isEmpty, "A focus change before the first pair prevents the entire batch")
    controller.onUp()
    clock.advance(0.5)
    check(events.count == 2, "A new input can target the newly focused application")
}

// Route real controllers into recording sinks: holds and picker confirmation
// must not produce any mode action, regardless of the current mode.
var media: [Int32] = []
let playback = PlaybackController(post: { key, _, count in media += Array(repeating: key, count: count) })
for (mode, controller) in [(Mode.scrolling, scroll as Controller), (.playback, playback), (.zoom, zoom), (.undoRedo, undoRedo)] {
    mouse.removeAll(); keys.removeAll(); media.removeAll(); historyKeys.removeAll()
    let h = Harness()
    h.mode = mode
    h.input.onPressBegan = { controller.onPressBegan() }
    h.input.onShortPress = { controller.onDown(); controller.onUp() }
    h.input.onCancelAction = { controller.onCancel() }
    h.input.onRotation = { controller.onRotate($0, $1) }
    let originalScrollStyle = scroll.style
    h.report(.pressed)
    check(mouse.isEmpty && keys.isEmpty && media.isEmpty && historyKeys.isEmpty, "No controller output on initial press")
    h.clock.advance(0.6)
    h.report(.released)
    h.report(.released, .Clockwise(3))
    h.report(.pressed)
    h.clock.advance(0.1)
    h.report(.released, .Clockwise(3))
    check(mouse.isEmpty && keys.isEmpty && media.isEmpty && historyKeys.isEmpty, "Opening, browsing, and confirmation never emit mode actions")
    if mode == .scrolling { check(scroll.style == originalScrollStyle, "Holds and picker confirmation never toggle Scroll") }
    h.click()
    switch mode {
    case .scrolling: check(mouse.isEmpty && scroll.style != originalScrollStyle, "Scroll toggles without emitting a mouse click")
    case .playback: check(media == [NX_KEYTYPE_PLAY], "Playback still plays/pauses on a short click")
    case .zoom: check(keys.count == 2, "Zoom still resets on a short click")
    case .undoRedo:
        check(historyKeys.isEmpty, "Undo/Redo defers the short click while checking for a double-click")
        historyClock.advance(0.5)
        check(historyKeys.count == 2 && historyKeys.allSatisfy { $0.flags == .maskCommand },
              "Undo/Redo undoes once after its click window")
    default: preconditionFailure("General controllers only")
    }
}
for profile: AppProfile? in [nil, .lightroom, .editwall] {
    for duration in MenuPressDuration.allCases {
        historyKeys.removeAll()
        let h = Harness()
        h.mode = .undoRedo
        h.profile = profile
        h.input.menuPressDuration = duration
        let controller = UndoRedoController(now: { h.clock.time }, doubleClickInterval: { 0.5 },
                                           schedule: { h.clock.schedule($0, $1) },
                                           targetProcess: { 42 }, post: { event, _ in historyKeys.append(event) })
        h.input.onPressBegan = { controller.onPressBegan() }
        h.input.onShortPress = { controller.onDown(); controller.onUp() }
        h.input.onCancelAction = { controller.onCancel() }
        h.input.onRotation = { controller.onRotate($0, $1) }
        h.open()
        h.input.highlight(.undoRedo)
        h.report(.pressed)
        h.clock.advance(0.1)
        h.report(.released, .CounterClockwise(5))
        check(h.commits == [.undoRedo] && historyKeys.isEmpty,
              "Confirming Undo/Redo consumes click and rotation at every hold duration and in Lightroom")
        h.open()
        h.report(.pressed)
        h.clock.advance(duration.seconds)
        h.report(.released, .Clockwise(5))
        check(h.input.picker == nil && historyKeys.isEmpty, "Held selection confirms without touching history")
        h.report(.pressed)
        h.input.cancel()
        h.report(.released, .CounterClockwise(5))
        check(historyKeys.isEmpty, "Cancelling an in-progress short press consumes its release and rotation")
        h.click()
        h.clock.advance(0.5)
        check(historyKeys.count == 2, "A fresh short click undoes once after cancellation")
    }
}
// Use the actual physical-press router and a deterministic clock for exclusive
// single/double clicks; no event is posted to the desktop.
final class HistoryClickHarness {
    let routing = Harness()
    var foreground: pid_t? = 42
    var interval: TimeInterval = 0.5
    var events: [CGEvent] = []
    lazy var controller = UndoRedoController(
        now: { [unowned self] in self.routing.clock.time },
        doubleClickInterval: { [unowned self] in self.interval },
        schedule: { [unowned self] in self.routing.clock.schedule($0, $1) },
        targetProcess: { [unowned self] in self.foreground },
        post: { [unowned self] event, _ in self.events.append(event) })

    init() {
        routing.mode = .undoRedo
        routing.input.onPressBegan = { [unowned self] in self.controller.onPressBegan() }
        routing.input.onShortPress = { [unowned self] in self.controller.onDown(); self.controller.onUp() }
        routing.input.onCancelAction = { [unowned self] in self.controller.onCancel() }
        routing.input.onRotation = { [unowned self] in self.controller.onRotate($0, $1) }
    }

    func checkActions(_ flags: [CGEventFlags], _ message: String) {
        check(events.count == flags.count * 2 && events.enumerated().allSatisfy { index, event in
            event.flags == flags[index / 2] && event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_Z)
                && event.type == (index % 2 == 0 ? .keyDown : .keyUp)
        }, message)
    }
}

for interval: TimeInterval in [0.25, 0.5, 0.8] {
    let c = HistoryClickHarness()
    c.interval = interval
    c.routing.click()
    c.checkActions([], "First click sends no undo while a double-click is possible")
    c.routing.clock.advance(interval / 2)
    c.routing.click()
    c.checkActions([[.maskCommand, .maskShift]], "Double-click sends exactly one redo and no preliminary undo")
    c.routing.clock.advance(interval + 1)
    c.checkActions([[.maskCommand, .maskShift]], "Double-click leaves no delayed undo behind")
    c.routing.click()
    c.checkActions([[.maskCommand, .maskShift]], "Third click starts a new single-click window")
    c.routing.clock.advance(interval)
    c.checkActions([[.maskCommand, .maskShift], .maskCommand], "Third click becomes one undo after the configured interval")
}

do {
    let c = HistoryClickHarness()
    c.routing.click()
    c.routing.clock.advance(0.51)
    c.routing.click()
    c.routing.clock.advance(0.51)
    c.checkActions([.maskCommand, .maskCommand], "Clicks outside the double-click window each undo once")
}
do {
    let c = HistoryClickHarness()
    c.routing.click()
    c.routing.clock.time += 0.51 // The first timer is overdue on a busy main queue.
    c.routing.click()
    c.checkActions([.maskCommand], "An overdue single click is resolved before a late second click")
    c.routing.clock.advance(0.51)
    c.checkActions([.maskCommand, .maskCommand], "Late second click cannot become redo because its timer was delayed")
}
do {
    let c = HistoryClickHarness()
    c.routing.click()
    c.routing.clock.advance(0.4)
    c.routing.report(.pressed)
    c.routing.clock.advance(0.15)
    c.checkActions([], "A second press suspends undo while waiting to distinguish a click from a hold")
    c.routing.report(.released)
    c.checkActions([[.maskCommand, .maskShift]], "A second short press begun within the window redoes even when released after it")
}
for duration in MenuPressDuration.allCases {
    let c = HistoryClickHarness()
    c.routing.input.menuPressDuration = duration
    c.routing.click()
    c.routing.clock.advance(0.1)
    c.routing.report(.pressed)
    c.routing.clock.advance(duration.seconds)
    c.routing.report(.released)
    c.routing.clock.advance(1)
    check(c.routing.input.picker != nil, "A hold following a single click still opens the picker")
    c.checkActions([], "Click followed by hold cancels pending undo at every menu press duration")
    c.routing.input.cancel()
    c.routing.click()
    c.routing.clock.advance(0.51)
    c.checkActions([.maskCommand], "Clicking works normally after a cancelled click-and-hold")
}
do {
    let c = HistoryClickHarness()
    c.routing.click()
    let stale = c.routing.clock.pending.last!.1
    c.routing.input.cancel() // Shared by mode changes, disconnect, sleep and app changes.
    c.routing.clock.advance(1)
    c.checkActions([], "Lifecycle cancellation drops a pending undo")
    c.routing.click()
    stale.perform()
    c.checkActions([], "A stale callback cannot resolve a new single click")
    c.routing.clock.advance(0.51)
    c.checkActions([.maskCommand], "A fresh click survives a stale cancelled callback")
}
for foreground: pid_t? in [84, nil] {
    let c = HistoryClickHarness()
    c.routing.click()
    c.foreground = foreground
    c.routing.clock.advance(0.51)
    c.checkActions([], "Delayed undo cannot be redirected when foreground focus changes or disappears")
}
for rotation: Dial.Rotation in [.Clockwise(2), .CounterClockwise(2)] {
    let c = HistoryClickHarness()
    c.routing.click()
    c.routing.report(.released, rotation)
    let flags: CGEventFlags
    switch rotation {
    case .Clockwise: flags = [.maskCommand, .maskShift]
    case .CounterClockwise: flags = .maskCommand
    }
    c.checkActions([flags, flags], "Rotation is immediate and takes over from a pending click")
    c.routing.clock.advance(1)
    c.checkActions([flags, flags], "Rotation cannot be followed by a leftover delayed undo")
}
do {
    let c = HistoryClickHarness()
    c.routing.click()
    c.routing.report(.released, .Clockwise(0))
    c.routing.report(.released, .CounterClockwise(-1))
    c.routing.clock.advance(0.51)
    c.checkActions([.maskCommand], "Empty rotations do not discard a real pending click")
}

playback.onCancel()
media.removeAll()
playback.onUp()
playback.onUp()
check(media == [NX_KEYTYPE_PLAY, NX_KEYTYPE_PLAY, NX_KEYTYPE_NEXT], "Playback double-click still advances the track")
// Lightroom is a flat sequence; the parent group is not an extra stop.
let lightroomModes = AppProfile.lightroom.availableModes
check(Mode.generalModes == [.scrolling, .playback, .zoom, .undoRedo], "Four standard modes have the requested order")
check(lightroomModes == [.scrolling, .playback, .zoom, .undoRedo, .lightroomCrop, .lightroomFineTune, .lightroomBrush],
      "Seven choices have the requested clockwise order")
for start in lightroomModes {
    var picker = ModePickerState(selectedMode: start, profile: .lightroom)
    for next in 1...lightroomModes.count {
        picker.move(by: 1)
        check(picker.selectedMode == lightroomModes[(lightroomModes.firstIndex(of: start)! + next) % lightroomModes.count],
              "Forward navigation crosses groups and wraps without a parent stop")
    }
    picker.move(by: -lightroomModes.count)
    check(picker.selectedMode == start, "Reverse navigation wraps all contextual choices")
}
for count in [1, 2, 4, 7, 15] {
    var picker = ModePickerState(selectedMode: .zoom, profile: .lightroom)
    picker.rotate(.Clockwise(count))
    check(picker.selectedMode == lightroomModes[(2 + count) % lightroomModes.count], "Each tick advances one Lightroom choice")
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
check(defaults.string(forKey: "appMode." + AppProfile.lightroom.bundleIdentifier) == "lightroomBrush",
      "Remove keeps the existing saved preference value")
defaults.set("lightroomBrush", forKey: "appMode." + AppProfile.lightroom.bundleIdentifier)
let reopened = AppModeContext(defaults: defaults)
reopened.activate(bundleIdentifier: AppProfile.lightroom.bundleIdentifier)
check(reopened.currentMode == .lightroomBrush && reopened.currentMode.title == "Remove",
      "An existing lightroomBrush preference reopens as Remove")
relaunched.activate(bundleIdentifier: "com.adobe.Lightroom")
check(relaunched.profile == nil && relaunched.currentMode == .playback, "Cloud Lightroom does not match the Classic profile")
check(relaunched.select(.undoRedo) && defaults.string(forKey: "mode") == "undoRedo",
      "Undo/Redo saves as a standard mode")
let historyRelaunched = AppModeContext(defaults: defaults)
check(historyRelaunched.currentMode == .undoRedo, "Standard Undo/Redo survives relaunch")
historyRelaunched.activate(bundleIdentifier: AppProfile.lightroom.bundleIdentifier)
check(historyRelaunched.currentMode == .lightroomBrush, "Global history mode preserves Lightroom's existing selection")
check(historyRelaunched.select(.undoRedo), "Undo/Redo can also be selected in Lightroom")
historyRelaunched.activate(bundleIdentifier: nil)
historyRelaunched.select(.zoom)
let contextRelaunched = AppModeContext(defaults: defaults)
contextRelaunched.activate(bundleIdentifier: AppProfile.lightroom.bundleIdentifier)
check(contextRelaunched.currentMode == .undoRedo, "Lightroom's Undo/Redo survives a general mode change and relaunch")
contextRelaunched.activate(bundleIdentifier: nil)
check(contextRelaunched.currentMode == .zoom, "Leaving Lightroom restores the independently saved general mode")
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
let generalLayout = RadialMenuLayout(profile: nil)
check(generalLayout.segments.map(\.angle) == [90, 0, -90, -180]
      && generalLayout.segments.allSatisfy { $0.sweep == 90 }, "Standard modes occupy four equal cardinal wedges")
check(groupedLayout.segments.filter { $0.outerRadius == 150 }.count == 5
      && groupedLayout.segments.filter { $0.outerRadius == 150 }.allSatisfy { $0.sweep == 72 },
      "Four standard modes and Lightroom occupy five equal inner wedges")
check(groupedLayout.segments.filter { $0.innerRadius == 150 }.map(\.sweep) == [24, 24, 24],
      "Lightroom children equally divide the parent's outer arc")
check((0..<360).allSatisfy { degrees in
    let point = groupedLayout.point(angle: CGFloat(degrees) + 0.5, radius: 183)
    return groupedLayout.outline.contains(point) == (groupedLayout.mode(at: point) != nil)
        && groupedLayout.outline.compatibleCGPath.contains(point) == (groupedLayout.mode(at: point) != nil)
}, "The entire outer arc's material mask agrees with selectable wedges")
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
    (.lightroomBrush, kVK_ANSI_RightBracket, kVK_ANSI_LeftBracket, kVK_ANSI_Q)
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

// Sequence uses real routing with recorded key events, never desktop input.
final class SequenceHarness {
    let routing = Harness()
    var foreground: pid_t? = 42
    var events: [CGEvent] = []
    lazy var controller = EditwallSequenceController(
        now: { [unowned self] in self.routing.clock.time }, doubleClickInterval: { 0.5 },
        schedule: { [unowned self] in self.routing.clock.schedule($0, $1) },
        targetProcess: { [unowned self] in self.foreground },
        post: { [unowned self] event, _ in self.events.append(event) })
    init() {
        routing.profile = .editwall
        routing.mode = .editwallSequence
        routing.input.onPressBegan = { [unowned self] in self.controller.onPressBegan() }
        routing.input.onShortPress = { [unowned self] in self.controller.onDown(); self.controller.onUp() }
        routing.input.onCancelAction = { [unowned self] in self.controller.onCancel() }
        routing.input.onRotation = { [unowned self] in self.controller.onRotate($0, $1) }
    }
    func expect(_ keys: [Int], _ message: String) {
        check(events.count == keys.count * 2 && events.enumerated().allSatisfy { index, event in
            event.getIntegerValueField(.keyboardEventKeycode) == Int64(keys[index / 2])
                && event.flags.isEmpty && event.type == (index % 2 == 0 ? .keyDown : .keyUp)
        }, message)
    }
}
for direction in [-1, 1] {
    let c = SequenceHarness()
    c.routing.report(.released, .CounterClockwise(2), direction: direction)
    c.routing.report(.released, .Clockwise(3), direction: direction)
    c.expect([kVK_UpArrow, kVK_UpArrow, kVK_DownArrow, kVK_DownArrow, kVK_DownArrow],
             "Sequence left/right sends one unmodified Up/Down pair per tick, independent of scroll preference")
    c.events.removeAll()
    c.routing.report(.released, .Clockwise(0))
    c.routing.report(.released, .CounterClockwise(-1))
    c.expect([], "Invalid Sequence tick counts do nothing")
}
do {
    let c = SequenceHarness()
    c.routing.click()
    c.expect([], "Next slot waits for the double-click window")
    c.routing.clock.advance(0.5)
    c.expect([kVK_RightArrow], "Single click advances exactly one sequence slot")
}
do {
    let c = SequenceHarness()
    c.routing.click()
    c.routing.clock.advance(0.1)
    c.routing.click()
    c.routing.clock.advance(1)
    c.expect([kVK_LeftArrow], "Double click goes back one slot without first advancing")
    c.routing.click()
    c.routing.clock.advance(0.5)
    c.expect([kVK_LeftArrow, kVK_RightArrow], "A fresh single click works after a double click")
}
for duration in MenuPressDuration.allCases {
    let c = SequenceHarness()
    c.routing.input.menuPressDuration = duration
    c.routing.click()
    c.routing.report(.pressed)
    c.routing.clock.advance(duration.seconds)
    c.routing.report(.released)
    c.routing.clock.advance(1)
    c.expect([], "Click then hold cancels navigation at every menu press duration")
    check(c.routing.input.picker != nil, "Holding Sequence opens its picker")
    c.routing.input.highlight(.editwallSequence)
    c.routing.click()
    c.routing.clock.advance(1)
    c.expect([], "Picker confirmation never navigates a sequence")
}
do {
    let c = SequenceHarness()
    c.routing.click()
    c.routing.report(.released, .Clockwise(1))
    c.routing.clock.advance(1)
    c.expect([kVK_DownArrow], "Rotation cancels a delayed slot change")
}
for newPID: pid_t? in [84, nil] {
    let c = SequenceHarness()
    c.routing.click()
    c.foreground = newPID
    c.routing.clock.advance(1)
    c.expect([], "Focus change discards the delayed Sequence click")
}
do {
    let c = SequenceHarness()
    c.routing.click()
    c.routing.input.cancel()
    c.routing.clock.advance(1)
    c.expect([], "Disconnect, mode changes and other cancellation discard Sequence clicks")
    c.foreground = nil
    c.routing.click()
    c.routing.report(.released, .Clockwise(3))
    c.routing.clock.advance(1)
    c.expect([], "No Sequence shortcuts are emitted without an eligible target")
}
for rotation: Dial.Rotation in [.Clockwise(5), .CounterClockwise(5)] {
    var foreground: pid_t? = 42
    var events: [CGEvent] = []
    var destinations: [pid_t] = []
    let controller = EditwallSequenceController(targetProcess: { foreground }, post: { event, pid in
        events.append(event)
        destinations.append(pid)
        foreground = 84
    })
    controller.onRotate(rotation, 1)
    check(events.map(\.type) == [.keyDown, .keyUp] && destinations == [42, 42],
          "Sequence finishes the original key pair and stops its batch on a focus change")
}
do {
    let suite = "MacDial.SequenceTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let context = AppModeContext(defaults: defaults)
    context.select(.zoom)
    context.activate(bundleIdentifier: "com.editwall.desktop")
    check(context.profile == .editwall && context.currentMode == .zoom, "Editwall initially inherits the general choice")
    check(context.select(.editwallSequence), "Sequence is selectable in Editwall")
    let relaunched = AppModeContext(defaults: defaults)
    relaunched.activate(bundleIdentifier: "com.editwall.desktop")
    check(relaunched.currentMode == .editwallSequence, "Sequence survives relaunch")
    context.activate(bundleIdentifier: AppProfile.lightroom.bundleIdentifier)
    check(context.currentMode == .zoom && !context.select(.editwallSequence), "Sequence is unavailable in Lightroom")
    context.select(.lightroomCrop)
    context.activate(bundleIdentifier: nil)
    check(context.currentMode == .zoom && !context.select(.editwallSequence), "Leaving Editwall preserves the general choice")
    context.activate(bundleIdentifier: "com.editwall.desktop")
    check(context.currentMode == .editwallSequence, "Returning restores Sequence independently of Lightroom")
    check(!context.select(.lightroomCrop), "Editwall cannot select Lightroom modes")
}
let sequenceLayout = RadialMenuLayout(profile: .editwall)
let sequenceSegment = sequenceLayout.segment(for: .editwallSequence)!
check(sequenceLayout.mode(at: sequenceLayout.point(angle: sequenceSegment.angle, radius: sequenceSegment.iconRadius)) == .editwallSequence,
      "Sequence outer icon hits the Sequence mode")
check(AppProfile.editwall.availableModes == Mode.generalModes + [.editwallSequence], "Editwall has four general modes and one Sequence submode")
// Confirmation is a presentation of an already accepted mode, never a delayed commit.
for profile: AppProfile? in [nil, .lightroom, .editwall] {
    for enabled in [false, true] {
        let h = Harness()
        h.profile = profile
        h.configuration.update(haptics: enabled)
        h.open()
        let chosen = profile?.modes.last ?? .zoom
        let before = h.feedback
        h.input.highlight(chosen, feedback: false) // Wedge mouse-down is silent.
        check(h.feedback == before, "Press highlighting never adds a selection pulse")
        h.input.confirmSelection(chosen) // Also used by native accessibility buttons.
        check(h.mode == chosen && h.input.picker == nil, "Mode applies synchronously before confirmation")
        check(h.confirmations.count == 1 && h.confirmations[0].selectedMode == chosen
              && h.confirmations[0].profile == profile && h.dismissals == 0,
              "Confirmation retains the chosen mode and layout without cancellation")
        check(h.feedback == before + (enabled ? 1 : 0), "Exactly one confirmation pulse respects preferences")
        h.input.confirmSelection(chosen)
        check(h.commits.count == 1 && h.confirmations.count == 1, "Repeated confirmation is ignored")
        h.report(.released, .Clockwise(1))
        check(h.rotations.count == 1, "Rotation operates the new mode during its visual confirmation")
        h.open()
        h.input.confirmSelection()
        check(h.confirmations.count == 2, "Reselecting the current mode also confirms")
        h.open()
        let cancellationFeedback = h.feedback
        h.input.cancel()
        h.clock.advance(20)
        check(h.confirmations.count == 2 && h.feedback == cancellationFeedback && h.dismissals == 1,
              "Cancellation and stale idle timers never confirm or pulse")
    }
}
do {
    let h = Harness()
    h.open()
    let before = h.feedback
    h.input.onCommit = { _ in false }
    h.input.confirmSelection(.zoom)
    check(h.mode == .scrolling && h.confirmations.isEmpty && h.feedback == before && h.dismissals == 1,
          "Rejected commits dismiss without claiming success")
}
do {
    let h = Harness()
    h.open()
    let before = h.feedback
    h.input.onCommit = { _ in h.input.cancel(); return true }
    h.input.confirmSelection()
    check(h.confirmations.isEmpty && h.feedback == before, "Context invalidation during commit prevents success feedback")
}
do {
    let h = Harness()
    h.open()
    let before = h.feedback
    h.input.onConfirmation = { _ in h.input.cancel() }
    h.input.confirmSelection(.zoom)
    check(h.mode == .zoom && h.feedback == before,
          "Invalidation during presentation does not enqueue a stale pulse")
}
// Hardware jobs can wait without blocking UI queries or applying stale state.
do {
    var work: [() -> Void] = []
    var events: [String] = []
    let configuration = DialConfigurationController { value in
        events.append("configure \(value.ticksPerRevolution)")
        return true
    }
    configuration.update(haptics: true)
    configuration.didConnect()
    let commands = DialHardwareCommands(configuration: configuration, schedule: { work.append($0) },
                                        impact: { events.append("pulse") })
    func drain() { let jobs = work; work.removeAll(); jobs.forEach { $0() } }
    commands.setMenuNavigationActive(true)
    let menuGeneration = configuration.withInputContext { 0 }.generation
    events.removeAll()
    commands.feedback()
    commands.setMenuNavigationActive(false)
    check(events.isEmpty, "Confirmation pulse and sensitivity restoration never do inline hardware I/O")
    check(!commands.acceptsRotation(menuGeneration), "Queued menu ticks are rejected as soon as restoration is requested")
    drain()
    check(events == ["pulse", "configure 36"], "Confirmation pulse precedes the potentially slow sensitivity reset")
    let normalGeneration = configuration.withInputContext { 0 }.generation
    check(commands.acceptsRotation(normalGeneration) && !commands.acceptsRotation(menuGeneration),
          "Only fresh normal ticks resume after asynchronous restoration")

    commands.setMenuNavigationActive(true)
    commands.setMenuNavigationActive(false)
    commands.setMenuNavigationActive(true)
    events.removeAll()
    drain()
    check(events.isEmpty, "An old queued restore cannot overwrite a reopened menu's sensitivity")
    let reopenedGeneration = configuration.withInputContext { 0 }.generation
    check(commands.acceptsRotation(reopenedGeneration), "Reopened menus accept their current tick generation")
    commands.feedback()
    commands.feedback()
    drain()
    check(events == ["pulse"], "A newer pulse replaces stale queued browsing feedback")
    events.removeAll()
    commands.feedback()
    commands.cancelFeedback()
    drain()
    check(events.isEmpty, "Lifecycle cancellation drops queued haptics")
    commands.feedback()
    configuration.didDisconnect()
    configuration.didConnect()
    events.removeAll()
    drain()
    check(events.isEmpty, "A pulse queued for an old connection is never played after reconnect")
    commands.feedback()
    configuration.update(haptics: false)
    events.removeAll()
    commands.feedback()
    drain()
    check(events.isEmpty, "Disabling haptics silences pending and new pulses")
}
do {
    let configuration = DialConfigurationController { _ in true }
    configuration.update(haptics: true)
    configuration.didConnect()
    let generation = configuration.withInputContext { 0 }.generation
    let began = DispatchSemaphore(value: 0)
    let finish = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        configuration.performFeedback {
            began.signal()
            _ = finish.wait(timeout: .now() + 5)
        }
        finished.signal()
    }
    check(began.wait(timeout: .now() + 2) == .success, "Test hardware write begins")
    let queried = DispatchSemaphore(value: 0)
    var accepted = false
    DispatchQueue.global().async {
        accepted = configuration.acceptsRotation(generation) && configuration.feedbackToken != nil
        queried.signal()
    }
    let responsive = queried.wait(timeout: .now() + 0.5) == .success
    finish.signal()
    _ = finished.wait(timeout: .now() + 2)
    if !responsive { _ = queried.wait(timeout: .now() + 2) }
    check(responsive && accepted, "UI generation and feedback queries do not wait for an in-flight HID write")
}
// Appearance persistence and fallback must not alter other dial preferences.
do {
    let suite = "MacDial.AppearanceTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("zoom", forKey: "mode")
    check(RadialMenuAppearance.load(from: defaults) == .automatic, "New installs use Automatic appearance")
    for appearance in RadialMenuAppearance.allCases {
        appearance.save(to: defaults)
        check(RadialMenuAppearance.load(from: UserDefaults(suiteName: suite)!) == appearance,
              "Appearance survives defaults reload")
        check(!appearance.usesLiquidGlass(isSupported: false), "All preferences fall back on older systems")
        check(appearance.usesLiquidGlass(isSupported: true) == (appearance != .classic),
              "Only Automatic and Liquid Glass use the supported native material")
    }
    defaults.set("unknown", forKey: "radialMenuAppearance")
    check(RadialMenuAppearance.load(from: defaults) == .automatic, "Unknown appearance safely defaults to Automatic")
    check(defaults.string(forKey: "mode") == "zoom", "Appearance does not change saved dial mode")
}
// Screen placement includes the glass/shadow render margin on every edge.
for profile: AppProfile? in [nil, .lightroom, .editwall] {
    let layout = RadialMenuLayout(profile: profile)
    for screen in [NSRect(x: 0, y: 25, width: 1440, height: 875),
                   NSRect(x: -1920, y: -200, width: 1920, height: 1080)] {
        for point in [screen.origin, NSPoint(x: screen.minX, y: screen.maxY),
                      NSPoint(x: screen.maxX, y: screen.minY), NSPoint(x: screen.maxX, y: screen.maxY),
                      NSPoint(x: screen.midX, y: screen.midY)] {
            let frame = layout.frame(around: point, in: screen, padding: RadialMenuLayout.effectPadding)
            check(screen.insetBy(dx: 10, dy: 10).contains(frame), "The complete padded window stays on the pointer display")
            check(frame.size == layout.presentationSize, "Clamping never scales or trims the wheel")
        }
        let center = NSPoint(x: screen.midX, y: screen.midY)
        let frame = layout.frame(around: center, in: screen, padding: RadialMenuLayout.effectPadding)
        check(frame.midX == center.x && frame.midY == center.y, "An unconstrained wheel remains centered on the pointer")
    }
}
// A chronological clock exercises frame cadence independently of real timers.
final class ScrollHarness {
    let clock = Clock()
    var events: [CGEvent] = []
    var eventTimes: [Double] = []
    var pointerLocation = CGPoint(x: 100, y: 200)
    var permitted = true
    lazy var controller: ScrollController = {
        let result = ScrollController(now: { [unowned self] in self.clock.time },
                                      schedule: { [unowned self] in self.clock.schedule($0, $1) },
                                      makeScrollEvent: { [unowned self] source, pixels in
                                          let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                                              wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0)
                                          // Simulate the fresh pointer location supplied by Quartz,
                                          // without moving or posting events to the real desktop.
                                          event?.location = self.pointerLocation
                                          return event
                                      },
                                      post: { [unowned self] in self.events.append($0); self.eventTimes.append(self.clock.time) })
        result.canScroll = { [unowned self] in self.permitted }
        return result
    }()
    func advance(_ seconds: Double) {
        let end = clock.time + seconds
        var frames = 0
        while let next = clock.pending.map({ $0.0 }).min(), next <= end {
            precondition(frames < 10000, "Scroll frame scheduler must make progress")
            frames += 1
            clock.time = max(clock.time, next)
            clock.advance(0)
        }
        clock.time = max(clock.time, end)
        clock.advance(0)
    }
    var pixels: [Int64] { events.map { $0.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) } }
    var momentum: [CGEvent] { events.filter { $0.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0 } }
    func fastTurn() {
        controller.onRotate(.Clockwise(1), 1)
        advance(0.03)
        controller.onRotate(.Clockwise(1), 1)
    }
}

for style in [ScrollStyle.smooth, .freewheel] {
    for direction in [-1, 1] {
        let h = ScrollHarness()
        h.controller.setStyle(style)
        h.controller.onRotate(.Clockwise(1), direction)
        h.advance(0.025)
        check(h.pixels.count >= 2 && h.pixels.allSatisfy { abs($0) < 24 }, "Animated scrolling splits a tick into small frames")
        h.advance(0.2)
        check(h.pixels.reduce(0, +) == 24 * direction && h.momentum.isEmpty, "An isolated tick preserves 24 pixels without coast")
        check(h.events.first?.getIntegerValueField(.scrollWheelEventScrollPhase) == 1
              && h.events.last?.getIntegerValueField(.scrollWheelEventScrollPhase) == 4, "Direct scroll phases balance")
        check(h.clock.pending.isEmpty, "Idle scrolling schedules no more work")
        check(h.events.allSatisfy { $0.getIntegerValueField(.scrollWheelEventIsContinuous) == 1 }, "Animated events use precise scrolling")
        check(h.events.allSatisfy { event in
            guard let native = NSEvent(cgEvent: event) else { return false }
            return native.hasPreciseScrollingDeltas
                && native.scrollingDeltaY == Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        }, "AppKit receives consistent precise pixel deltas")
    }

    do {
        let h = ScrollHarness()
        h.controller.setStyle(style)
        h.fastTurn()
        h.advance(1.3)
        let direct = h.events.filter { $0.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0 }
        let distance = direct.reduce(Int64(0)) { $0 + $1.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) }
        check(abs(Double(distance) - (24 + 24 * (style == .freewheel ? 5.0 : 3.4))) <= 1, "Overlapping impulses preserve their accelerated distance")
        check(h.momentum.first?.getIntegerValueField(.scrollWheelEventMomentumPhase) == 1
              && h.momentum.last?.getIntegerValueField(.scrollWheelEventMomentumPhase) == 3, "Momentum begins and ends with Quartz phases")
        check(h.momentum.contains { $0.getIntegerValueField(.scrollWheelEventMomentumPhase) == 2 }, "Momentum has continuation frames")
        check(h.events.allSatisfy { !($0.getIntegerValueField(.scrollWheelEventScrollPhase) != 0
                                   && $0.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0) }, "Direct and momentum phases never overlap")
        let coast = h.momentum.map { $0.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) }
        check(coast.reduce(0, +) > 0 && coast.reduce(0, +) < (style == .freewheel ? 601 : 100) && h.clock.pending.isEmpty, "Coast is bounded and shuts down")
        check(coast.first! > coast.dropLast().last!, "Coast decelerates")
        let ended = h.events.firstIndex { $0.getIntegerValueField(.scrollWheelEventScrollPhase) == 4 }!
        check(h.eventTimes.last! - h.eventTimes[ended] <= (style == .freewheel ? 1.0 : 0.30) + 1.0 / 120 + 0.00001,
              "Momentum terminates within its style limit plus one scheduling frame")
    }

    // Moving the pointer during inertia must never replay the gesture's old
    // location, even in a zero-delta end/cancel event or across display origins.
    for cancel in [false, true] {
        let h = ScrollHarness()
        h.controller.setStyle(style)
        h.fastTurn()
        h.advance(0.15)
        check(!h.momentum.isEmpty, "Pointer regression test starts during active inertia")
        for position in [CGPoint(x: 420, y: 350), CGPoint(x: -800, y: 120)] {
            h.pointerLocation = position
            let count = h.events.count
            h.advance(0.025)
            let frames = h.events.dropFirst(count)
            check(!frames.isEmpty && frames.allSatisfy { $0.location == position },
                  "Moving the pointer during \(style.title) inertia preserves its current position")
        }
        h.pointerLocation = CGPoint(x: 600, y: -200)
        let count = h.events.count
        if cancel { h.controller.onPressBegan() }
        else { h.advance(1.3) }
        let ending = h.events.dropFirst(count)
        check(!ending.isEmpty && ending.allSatisfy { $0.location == h.pointerLocation },
              "Finishing or cancelling inertia never restores an old pointer position")
        check(ending.last?.getIntegerValueField(.scrollWheelEventMomentumPhase) == 3,
              "Pointer movement preserves the balanced momentum ending")
    }

    for duringCoast in [false, true] {
        let h = ScrollHarness()
        h.controller.setStyle(style)
        h.fastTurn()
        h.advance(duringCoast ? 0.15 : 0.02)
        h.controller.onRotate(.CounterClockwise(1), 1)
        let count = h.events.count
        h.advance(1.3)
        check(h.pixels.dropFirst(count).allSatisfy { $0 <= 0 }, "Reversal never continues old-direction motion")
    }

    for reason in ["press", "cancel", "style", "context", "stall"] {
        for duringCoast in [false, true] {
            let h = ScrollHarness()
            h.controller.setStyle(style)
            h.fastTurn()
            h.advance(duringCoast ? 0.15 : 0.02)
            let count = h.events.count
            switch reason {
            case "press": h.controller.onPressBegan()
            case "cancel": h.controller.onCancel()
            case "style": h.controller.setStyle(.stepped)
            case "context": h.permitted = false
            default: h.clock.advance(1) // Deliver an overdue frame with no intermediate callbacks.
            }
            h.advance(1)
            check(h.pixels.dropFirst(count).allSatisfy { $0 == 0 } && h.clock.pending.isEmpty,
                  "\(reason) cancels direct motion and coast without catch-up or stale callbacks")
        }
    }
}

do {
    let h = ScrollHarness()
    h.controller.setStyle(.stepped)
    h.controller.onRotate(.Clockwise(1), 1)
    h.advance(0.01)
    h.controller.onRotate(.Clockwise(1), 1)
    check(h.pixels == [24, 96], "Stepped keeps original tick acceleration")
    h.controller.onCancel()
    h.controller.onRotate(.Clockwise(1), 1)
    check(h.pixels.last == 24 && h.clock.pending.isEmpty, "Cancellation resets Stepped acceleration without scheduling frames")
}

// Freewheel must materially out-travel Smooth for the same fast input.
do {
    let smooth = ScrollHarness()
    let freewheel = ScrollHarness()
    freewheel.controller.setStyle(.freewheel)
    smooth.fastTurn()
    freewheel.fastTurn()
    smooth.advance(0.5)
    freewheel.advance(0.5)
    check(smooth.clock.pending.isEmpty && !freewheel.clock.pending.isEmpty,
          "Freewheel continues gliding after Smooth has stopped")
    freewheel.advance(0.8)
    check(freewheel.pixels.reduce(0, +) > smooth.pixels.reduce(0, +) * 3,
          "Freewheel covers substantially more of a long page for the same fast turn")
    check(freewheel.clock.pending.isEmpty, "Freewheel stops scheduling when its longer glide ends")
}

// The same button recognizer is used at every hold threshold and app profile.
for profile: AppProfile? in [nil, .lightroom, .editwall] {
    for duration in MenuPressDuration.allCases {
        let routing = Harness()
        routing.profile = profile
        routing.input.menuPressDuration = duration
        let motion = ScrollHarness()
        var changes: [ScrollStyle] = []
        motion.controller.onStyleChanged = { changes.append($0) }
        routing.input.onPressBegan = { motion.controller.onPressBegan() }
        routing.input.onShortPress = { motion.controller.onDown(); motion.controller.onUp() }
        routing.input.onCancelAction = { motion.controller.onCancel() }
        routing.open()
        routing.input.highlight(.scrolling)
        routing.report(.pressed)
        routing.clock.advance(0.05)
        routing.report(.released, .Clockwise(3))
        check(changes.isEmpty && motion.events.isEmpty, "Every hold threshold and profile consumes Scroll confirmation")
        routing.click()
        check(changes == [.stepped] && motion.events.isEmpty, "Short click changes style once with no mouse events")
        routing.click()
        check(changes == [.stepped, .freewheel], "Second click selects Freewheel")
        routing.open()
        routing.input.highlight(.scrolling)
        routing.report(.pressed)
        routing.clock.advance(0.05)
        routing.report(.released)
        check(changes == [.stepped, .freewheel], "Holding and confirming Scroll preserves Freewheel")
        routing.click()
        check(changes == [.stepped, .freewheel, .smooth] && motion.events.isEmpty,
              "Third click wraps to Smooth without mouse events")
    }
}

for sensitivity in WheelSensitivity.allCases {
    let h = ScrollHarness()
    h.controller.onRotate(.Clockwise(sensitivity.normalTicksPerRevolution), -1)
    h.advance(0.2)
    check(h.pixels.reduce(0, +) == Int64(-24 * sensitivity.normalTicksPerRevolution), "Every sensitivity preserves batched tick distance")
}

do {
    let suite = "MacDial.ScrollTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    check(ScrollStyle.load(from: defaults) == .smooth, "Smooth is the default")
    defaults.set("invalid", forKey: "scrollStyle")
    check(ScrollStyle.load(from: defaults) == .smooth, "Unknown styles fall back to Smooth")
    for style in ScrollStyle.allCases {
        style.save(to: defaults)
        check(ScrollStyle.load(from: UserDefaults(suiteName: suite)!) == style, "Scroll style survives preference reload")
    }
    defaults.removeObject(forKey: "scrollStyle")
}

print("Passed \(checks) checks: gestures, contextual routing, preferences, geometry and recorded events.")
