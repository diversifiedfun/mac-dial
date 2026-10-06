import AppKit

func runDynamicSliceChecks(_ check: (Bool, String) -> Void) {
    // Every possible visible composition, plus overflow, uses one layout source.
    for standardCount in 0...19 {
        for appCount in 0...19 {
            let configuration = SliceConfiguration(
                standardSlices: (0..<standardCount).map { .custom(CustomSlice(name: "Standard \($0)")) },
                applications: [ApplicationConfiguration(bundleIdentifier: "test.geometry", displayName: "Geometry",
                    slices: (0..<appCount).map { .custom(CustomSlice(name: "App \($0)")) })])
            let dial = configuration.resolved(for: "test.geometry")
            let layout = RadialMenuLayout(dial: dial, application: configuration.applications[0])
            let actions = layout.segments.filter { $0.slice != nil }
            check(actions.count == dial.actionCount, "Geometry contains exactly the resolved selectable actions")
            check(actions.allSatisfy { abs($0.sweep - CGFloat($0.isApplication ? dial.applicationSliceAngle : dial.standardSliceAngle)) < 0.000001 }, "Each action uses its standard or half-width child angle")
            check(abs(dial.standardSliceAngle - 2 * dial.applicationSliceAngle) < 0.000001, "Child angles are half standard angles")
            check(actions.isEmpty || abs(actions.reduce(0) { $0 + $1.sweep } - 360) < 0.000001, "Selectable angles fill the circle")
            check(actions.first == nil || abs(actions[0].angle - 90) < 0.000001, "First action stays centered at twelve o'clock")
            for index in actions.indices where index > 0 {
                check(abs(actions[index - 1].endAngle - actions[index].startAngle) < 0.000001,
                      "Adjacent weighted wedges meet without gaps or overlap")
            }
            check(abs((layout.appGroupSegment?.sweep ?? 0) - CGFloat(dial.applicationSlices.count) * CGFloat(dial.applicationSliceAngle)) < 0.000001,
                  "Parent span is the sum of its children's angles")
            if let group = layout.appGroupSegment {
                let point = layout.point(angle: group.angle, radius: group.iconRadius)
                for x: CGFloat in [-21, 21] {
                    for y: CGFloat in [-21, 21] {
                        check(layout.path(for: group).contains(NSPoint(x: point.x + x, y: point.y + y)),
                              "App logo fits inside the parent wedge")
                    }
                }
            }
            for (index, segment) in actions.enumerated() {
                let point = layout.point(angle: segment.angle, radius: segment.iconRadius)
                check(layout.slice(at: point)?.id == segment.slice?.id, "Every custom action icon hits its own segment")
                check(layout.path(for: segment).contains(point), "Each wedge's fill includes its icon")
                check(!layout.path(for: segment).contains(layout.center), "Even a full-circle action excludes the center")
                for offset: CGFloat in [-0.49, 0.49] {
                    let edge = layout.point(angle: segment.angle + segment.sweep * offset, radius: segment.iconRadius)
                    check(layout.slice(at: edge)?.id == segment.slice?.id, "Both sides inside each wedge select the correct action")
                }
                let target = NSRect(x: point.x - 25, y: point.y - 25, width: 50, height: 50)
                for next in actions.dropFirst(index + 1) {
                    let other = layout.point(angle: next.angle, radius: next.iconRadius)
                    check(!target.intersects(NSRect(x: other.x - 25, y: other.y - 25, width: 50, height: 50)),
                          "Fifty-point targets do not overlap at any supported composition")
                }
            }
            for degree in stride(from: 0, to: 360, by: 5) {
                let point = layout.point(angle: CGFloat(degree) + 0.317, radius: layout.coreRadius - 1)
                check(layout.outline.contains(point) && layout.outline.compatibleCGPath.contains(point),
                      "The base wheel has no missing wedge or contour hole")
                if layout.hasApplicationGroup {
                    let outer = layout.point(angle: CGFloat(degree) + 0.317, radius: layout.coreRadius + 33)
                    check(layout.outline.contains(outer) == (layout.slice(at: outer) != nil),
                          "Outer material exactly covers the child arc")
                }
            }
            check(layout.slice(at: layout.center) == nil, "The wheel center never performs an action")
            let screen = NSRect(x: -800, y: 100, width: 640, height: 480)
            let frame = layout.frame(around: NSPoint(x: -790, y: 570), in: screen, padding: 32)
            check(screen.insetBy(dx: 10, dy: 10).contains(frame), "Dense wheels fit entirely inside small offset displays")
            var state = ModePickerState(dial: dial, application: configuration.applications[0], selectedSliceID: .custom(), startPosition: .firstItem)
            check(state.selectedSliceID == dial.clockwiseSlices.first?.id, "First Item uses actual configured order")
            if let first = state.selectedSliceID {
                _ = state.move(by: dial.actionCount)
                check(state.selectedSliceID == first, "One revolution preserves selection with custom actions")
                _ = state.move(by: -1)
                check(state.selectedSliceID == dial.clockwiseSlices.last?.id, "Counterclockwise reaches the last rendered action")
            } else {
                check(!state.move(by: 1) && state.selectedSlice == nil, "Empty picker remains empty on rotation")
            }
        }
    }

    // Route a custom selection through the actual press/hold coordinator.
    do {
        let custom = SliceDefinition.custom()
        let configuration = SliceConfiguration(standardSlices: [.builtIn(.scrolling), custom], applications: [])
        let h = Harness()
        h.input.currentPicker = { ModePickerState(dial: configuration.resolved(), selectedSliceID: custom.id) }
        var committed: SliceID?
        h.input.onCommitSlice = { committed = $0; return true }
        h.report(.pressed)
        h.clock.advance(0.6)
        h.report(.released)
        check(h.input.picker?.selectedSliceID == custom.id, "Opening preserves a custom last-selected identity")
        h.input.confirmSlice(custom.id)
        check(committed == custom.id && h.commits.isEmpty, "Custom confirmation never falls through to a built-in callback")
        let empty = SliceConfiguration(standardSlices: [], applications: [])
        h.input.currentPicker = { ModePickerState(dial: empty.resolved(), selectedSliceID: nil) }
        committed = nil
        h.report(.pressed)
        h.clock.advance(0.6)
        h.report(.released)
        h.input.confirmSelection()
        check(committed == nil && h.input.picker?.selectedSliceID == nil, "Confirming an empty picker cannot dispatch Scroll")
        h.input.cancel()
    }

    do {
        let clock = Clock()
        var pid: pid_t? = 42
        var events: [(Int32, [NSEvent.ModifierFlags], Int)] = []
        var keyboardEvents = 0
        let controller = CustomSliceController(gestures: SliceGestures(rotateLeft: .brightnessDown,
            rotateRight: .brightnessUp, click: .brightnessDown, doubleClick: .brightnessUp),
            now: { clock.time }, doubleClickInterval: { 0.3 }, schedule: clock.schedule,
            targetProcess: { pid }, post: { _, _ in keyboardEvents += 1 },
            postSystemKey: { events.append(($0, $1, $2)) })
        controller.onRotate(.CounterClockwise(2), -1)
        controller.onRotate(.Clockwise(3), -1)
        check(events.map { $0.0 } == [NX_KEYTYPE_BRIGHTNESS_DOWN, NX_KEYTYPE_BRIGHTNESS_DOWN,
            NX_KEYTYPE_BRIGHTNESS_UP, NX_KEYTYPE_BRIGHTNESS_UP, NX_KEYTYPE_BRIGHTNESS_UP],
            "Custom brightness uses system brightness controls once per tick, independent of Scroll Direction")
        check(events.allSatisfy { $0.1 == [.shift, .option] && $0.2 == 1 } && keyboardEvents == 0,
            "Brightness sends fine system steps without F1/F2 keyboard events")
        events.removeAll()
        controller.onRotate(.Clockwise(0), 1)
        controller.onRotate(.CounterClockwise(-1), 1)
        controller.onUp()
        check(events.isEmpty, "Brightness ignores nonpositive ticks and waits to classify clicks")
        clock.advance(0.3)
        check(events.map { $0.0 } == [NX_KEYTYPE_BRIGHTNESS_DOWN], "A single click runs its brightness action once")
        events.removeAll()
        controller.onUp()
        controller.onPressBegan()
        controller.onUp()
        clock.advance(1)
        check(events.map { $0.0 } == [NX_KEYTYPE_BRIGHTNESS_UP], "A double click runs only its assigned brightness action")
        events.removeAll()
        controller.onUp()
        controller.onCancel()
        clock.advance(1)
        check(events.isEmpty, "Hold cancellation prevents delayed brightness actions")
        controller.onUp()
        pid = 84
        clock.advance(1)
        check(events.isEmpty, "Focus changes prevent stale brightness clicks")
        pid = nil
        controller.onRotate(.Clockwise(2), 1)
        check(events.isEmpty, "Permission or context rejection prevents brightness output")
    }
    for cancelDuringPost in [false, true] {
        var pid: pid_t? = 42
        var count = 0
        var controller: CustomSliceController!
        controller = CustomSliceController(gestures: SliceGestures(rotateRight: .brightnessUp),
            targetProcess: { pid }, postSystemKey: { _, _, _ in
                count += 1
                if cancelDuringPost { controller.onCancel() } else { pid = 84 }
            })
        controller.onRotate(.Clockwise(4), 1)
        check(count == 1, "Context changes or cancellation stop remaining brightness ticks")
    }

    let systemKeys: [(MacOSAction, Int32, [NSEvent.ModifierFlags])] = [
        (.brightnessDown, NX_KEYTYPE_BRIGHTNESS_DOWN, [.shift, .option]),
        (.brightnessUp, NX_KEYTYPE_BRIGHTNESS_UP, [.shift, .option]),
        (.volumeDown, NX_KEYTYPE_SOUND_DOWN, [.shift, .option]),
        (.volumeUp, NX_KEYTYPE_SOUND_UP, [.shift, .option]),
        (.mute, NX_KEYTYPE_MUTE, []), (.playPause, NX_KEYTYPE_PLAY, []),
        (.previousTrack, NX_KEYTYPE_PREVIOUS, []), (.nextTrack, NX_KEYTYPE_NEXT, []),
        (.keyboardBacklightDown, NX_KEYTYPE_ILLUMINATION_DOWN, []),
        (.keyboardBacklightUp, NX_KEYTYPE_ILLUMINATION_UP, []),
        (.keyboardBacklightToggle, NX_KEYTYPE_ILLUMINATION_TOGGLE, [])]
    for (action, key, flags) in systemKeys {
        var events: [(Int32, [NSEvent.ModifierFlags], Int)] = []
        var unexpected = 0
        let controller = CustomSliceController(gestures: SliceGestures(rotateRight: .macOSAction(action)),
            targetProcess: { 42 }, post: { _, _ in unexpected += 1 },
            postSystemKey: { events.append(($0, $1, $2)) }, postGlobalKey: { _ in unexpected += 1 })
        controller.onRotate(.Clockwise(2), 1)
        check(events.count == 2 && events.allSatisfy { $0.0 == key && $0.1 == flags && $0.2 == 1 } && unexpected == 0,
            "\(action.title) routes to its system media control with the expected modifiers")
    }
    for (action, key, flags): (MacOSAction, Int64, CGEventFlags) in [
        (.missionControl, 126, .maskControl), (.showDesktop, 103, .maskSecondaryFn), (.spotlight, 49, .maskCommand)] {
        var events: [CGEvent] = []
        var unexpected = 0
        var pid: pid_t? = 42
        let controller = CustomSliceController(gestures: SliceGestures(rotateRight: .macOSAction(action)),
            targetProcess: { pid }, post: { _, _ in unexpected += 1 },
            postSystemKey: { _, _, _ in unexpected += 1 }, postGlobalKey: { events.append($0); pid = 84 })
        controller.onRotate(.Clockwise(3), 1)
        check(events.map(\.type) == [.keyDown, .keyUp] && events.allSatisfy {
            $0.getIntegerValueField(.keyboardEventKeycode) == key && $0.flags == flags
        } && unexpected == 0, "\(action.title) sends a balanced global shortcut and stops after a focus change")
    }
    for modifiers: ShortcutModifiers in [[], [.command]] {
        var events: [CGEvent] = []
        let controller = CustomSliceController(gestures: SliceGestures(rotateRight:
            .keyboardShortcut(KeyboardShortcut(keyCode: 53, modifiers: modifiers))), targetProcess: { 42 },
            post: { event, _ in events.append(event) })
        controller.onRotate(.Clockwise(1), 1)
        check(events.map(\.type) == [.keyDown, .keyUp] && events.allSatisfy {
            $0.getIntegerValueField(.keyboardEventKeycode) == 53 && $0.flags == (modifiers.isEmpty ? [] : .maskCommand)
        }, "Escape and modified Escape dispatch as balanced keyboard shortcuts")
    }

    let left = KeyboardShortcut(keyCode: 123, modifiers: [.command, .option])
    let right = KeyboardShortcut(keyCode: 124, modifiers: [.control, .shift])
    let click = KeyboardShortcut(keyCode: 35)
    let doubleClick = KeyboardShortcut(keyCode: 7)
    let gestures = SliceGestures(rotateLeft: .keyboardShortcut(left), rotateRight: .keyboardShortcut(right),
                                click: .keyboardShortcut(click), doubleClick: .keyboardShortcut(doubleClick))
    do {
        let clock = Clock()
        var pid: pid_t? = 42
        var events: [(CGEventType, Int64, CGEventFlags, pid_t)] = []
        let controller = CustomSliceController(gestures: gestures, now: { clock.time }, doubleClickInterval: { 0.3 },
            schedule: clock.schedule, targetProcess: { pid }, post: {
                events.append(($0.type, $0.getIntegerValueField(.keyboardEventKeycode), $0.flags, $1))
            })
        controller.onRotate(.CounterClockwise(2), -1)
        controller.onRotate(.Clockwise(1), -1)
        check(events.map { $0.1 } == [123, 123, 123, 123, 124, 124], "Every tick emits one balanced pair independent of Scroll Direction")
        check(events.map { $0.0 } == [.keyDown, .keyUp, .keyDown, .keyUp, .keyDown, .keyUp], "Shortcut edges remain balanced")
        check(events.prefix(4).allSatisfy { $0.2 == [.maskCommand, .maskAlternate] }
              && events.suffix(2).allSatisfy { $0.2 == [.maskControl, .maskShift] }, "All four supported modifiers map to explicit event flags")
        events.removeAll()
        controller.onUp()
        check(events.isEmpty, "Single click waits for double-click classification")
        clock.advance(0.3)
        check(events.map { $0.1 } == [35, 35], "A lone click executes once")
        events.removeAll()
        controller.onUp()
        clock.advance(0.1)
        controller.onPressBegan()
        controller.onUp()
        clock.advance(0.4)
        check(events.map { $0.1 } == [7, 7], "A double click emits only its own action")
        events.removeAll()
        controller.onUp()
        controller.onPressBegan()
        controller.onCancel() // hold, configuration edit, sleep or disconnect
        clock.advance(1)
        check(events.isEmpty, "Cancelling a second press drops both delayed click actions")
        controller.onUp()
        pid = 84
        clock.advance(1)
        check(events.isEmpty, "Delayed shortcuts cannot spill into a new foreground process")
        pid = 42
        controller.onUp()
        controller.onRotate(.Clockwise(1), 1)
        clock.advance(1)
        check(events.map { $0.1 } == [124, 124], "Rotation cancels a pending click before sending its own shortcut")
    }
    do {
        let clock = Clock()
        var keys: [Int64] = []
        let controller = CustomSliceController(gestures: SliceGestures(click: .keyboardShortcut(click)), now: { clock.time },
            doubleClickInterval: { 0.3 }, schedule: clock.schedule, targetProcess: { 42 },
            post: { event, _ in keys.append(event.getIntegerValueField(.keyboardEventKeycode)) })
        controller.onUp()
        controller.onPressBegan()
        controller.onUp()
        clock.advance(1)
        controller.onRotate(.Clockwise(10), 1)
        check(keys.isEmpty, "No Action on double-click consumes the pair; No Action rotation emits nothing")
    }
    for invalidateDuringDown in [false, true] {
        var events: [(CGEventType, pid_t)] = []
        var pid: pid_t? = 42
        var controller: CustomSliceController!
        controller = CustomSliceController(gestures: gestures, targetProcess: { pid }, post: { event, destination in
            events.append((event.type, destination))
            if event.type == .keyDown {
                if invalidateDuringDown { controller.onCancel() }
                else { pid = 84 }
            }
        })
        controller.onRotate(.Clockwise(4), 1)
        check(events.count == 2 && events.map { $0.0 } == [.keyDown, .keyUp] && events.allSatisfy { $0.1 == 42 },
              "Focus or generation changes finish the original key pair and cancel remaining ticks")
    }
}
