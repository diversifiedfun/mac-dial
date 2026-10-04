import AppKit
import Carbon.HIToolbox

// Only the HID transport is stubbed; gesture and event code is compiled from
// the app sources. Recorded events are never posted to the user's desktop.
enum Dial {
    enum Rotation { case Clockwise(Int), CounterClockwise(Int) }
}

final class Recorder: Controller {
    var events: [String] = []
    func onDown() { events.append("down") }
    func onUp() { events.append("up") }
    func onCancel() { events.append("cancel") }
    func onRotate(_ rotation: Dial.Rotation, _ scrollDirection: Int) {}
}

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    checks += 1
}

var time: TimeInterval = 0
var pending: [DispatchWorkItem] = []
let button = DialButtonHandler(now: { time }, schedule: { delay, work in
    check(delay == 0.6, "Hold threshold must be 600 ms")
    pending.append(work)
})
let first = Recorder()
let second = Recorder()
var cycles = 0
button.onLongPress = {
    check(first.events.last == "cancel", "Release the old controller before changing mode")
    cycles += 1
}

// Short click and duplicate HID edges.
button.pressed(controller: first)
button.pressed(controller: second)
time = 0.599
button.released()
button.released()
check(first.events == ["down", "up"], "Short press must click exactly once")
check(second.events.isEmpty && cycles == 0, "Duplicate down must not change controller")

// Long hold switches while still down and suppresses its eventual release.
time = 1
button.pressed(controller: first)
time = 1.6
pending.last!.perform()
check(button.longPressActive && cycles == 1, "Long press must switch while held")
check(first.events == ["down", "up", "down", "cancel"], "Long press must cancel, not click")
time = 10
button.released()
check(cycles == 1 && first.events.count == 4, "Holding longer must not switch repeatedly or click")
check(!button.longPressActive, "Rotation must resume after release")

// If the main queue was busy, an overdue release still counts as a long press.
time = 11
button.pressed(controller: first)
time = 12
button.released()
check(cycles == 2 && first.events.suffix(2) == ["down", "cancel"], "Delayed timer must not cause a short click")

// Manual mode changes/disconnection/quit cancel safely; stale timers cannot
// switch a new gesture and stray releases cannot click the new mode.
time = 13
button.pressed(controller: first)
let stale = pending.last!
button.cancel()
button.cancel()
button.released()
check(first.events.suffix(2) == ["down", "cancel"], "Cancellation must release once")
time = 14
button.pressed(controller: second)
stale.perform()
check(cycles == 2 && !button.longPressActive, "Cancelled timer must not affect the next press")
time = 14.1
button.released()
check(second.events == ["down", "up"], "Clicks must recover after cancellation")

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
print("Passed \(checks) checks: press timing, cancellation, mouse release, scroll direction, and zoom shortcuts.")
