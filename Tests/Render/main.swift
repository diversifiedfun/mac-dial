import AppKit

enum Dial {
    enum ButtonState { case pressed, released }
    enum Rotation { case Clockwise(Int), CounterClockwise(Int) }
}

// Offscreen rendering and view-level checks; no desktop input or HID access.
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
// Keep native symbol rasterization at the same 2x density as the exported
// bitmap, including while the desktop is locked or has no Retina screen.
final class RenderWindow: NSWindow {
    override var backingScaleFactor: CGFloat { 2 }
}
let window = RenderWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                      styleMask: .borderless, backing: .buffered, defer: false)
window.isOpaque = false
window.backgroundColor = .clear
let view = RadialMenuView()
window.contentView = view
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    checks += 1
}

func render(_ name: String) throws {
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2),
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = view.bounds.size
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name + ".png"))
}

func buttons(in parent: NSView) -> [NSButton] {
    parent.subviews.flatMap { child -> [NSButton] in
        if let button = child as? NSButton { return [button] }
        return buttons(in: child)
    }
}

func update(_ state: ModePickerState) {
    let diameter = RadialMenuLayout(profile: state.profile).diameter
    window.setContentSize(NSSize(width: diameter, height: diameter))
    view.update(state)
}

for profile: AppProfile? in [nil, .lightroom, .editwall] {
    let modes = profile?.availableModes ?? Mode.generalModes
    for mode in modes {
        var state = ModePickerState(selectedMode: mode, profile: profile)
        state.isArmed = true
        update(state)
        try render((profile.map { $0.title.lowercased() + "-" } ?? "") + mode.rawValue)
        let controls = buttons(in: view)
        check(controls.count == modes.count, "Only selectable modes expose native controls")
        for button in controls {
            let candidate = Mode.allCases[button.tag]
            check(button.accessibilityRole() == .radioButton, "Mode controls expose radio-button semantics")
            check(button.accessibilityLabel() == "\(candidate.title) mode", "Mode label is accessible")
            if candidate == .lightroomBrush {
                let guidance = "Activate Remove before turning. With Remove inactive, turning may change photo star ratings."
                check(button.toolTip == guidance, "Remove exposes the rating guidance to pointer users")
                check(button.accessibilityHelp()?.contains(guidance) == true,
                      "Remove exposes the rating guidance to accessibility users")
            }
            if candidate == .undoRedo {
                let guidance = "Turn left to undo; turn right to redo, one step per tick. Click to undo once; double-click to redo once. Single clicks wait for the macOS double-click interval. Requires Command+Z and Shift+Command+Z support in the focused app."
                check(button.toolTip == guidance, "Undo/Redo exposes its actions and shortcut requirements to pointer users")
                check(button.accessibilityHelp()?.contains(guidance) == true,
                      "Undo/Redo exposes its actions and shortcut requirements to accessibility users")
            }
            check((button.accessibilityValue() as? Int) == (candidate == mode ? 1 : 0), "Selected value is accessible")
            check(button.image != nil && button.isEnabled, "Icons are present and actionable after release")
            check(button.frame.width >= 44 && button.frame.height >= 44, "Icons have adequate pointer targets")
            let position = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: view)
            check(view.menuLayout.mode(at: position) == candidate, "Actual button frames match the shared geometry")
            check((view.hitTest(position) as? NSButton)?.tag == button.tag, "Native hit testing reaches each icon through its group")
        }
        let visibleLabels = view.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }
        check(visibleLabels.allSatisfy { $0.attributedStringValue.size().width <= $0.bounds.width },
              "All center text fits without truncation")
        check(controls.enumerated().allSatisfy { index, button in
            let frame = button.convert(button.bounds, to: view)
            return controls.dropFirst(index + 1).allSatisfy { !frame.intersects($0.convert($0.bounds, to: view)) }
        }, "Native pointer targets do not overlap in either ring")
        if mode == .undoRedo {
            check(visibleLabels.map(\.stringValue) == ["Undo/Redo", "Turn to choose", "Click to select"],
                  "Undo/Redo's center explains picker navigation rather than triggering history actions")
        }
        if let profile = profile {
            let group = view.subviews.first { $0.accessibilityRole() == .group && $0.accessibilityLabel() == "\(profile.title) modes" }
            check(group != nil && buttons(in: group!).count == profile.modes.count, "App-specific children have an accessible group")
        }
    }
}

for profile: AppProfile? in [nil, .lightroom, .editwall] {
    var state = ModePickerState(selectedMode: .undoRedo, profile: profile)
    state.isArmed = true
    update(state)
    view.updateDisplayOptions(reduceTransparency: true, increasedContrast: true)
    try render((profile.map { $0.title.lowercased() + "-" } ?? "") + "undoRedo-reduced-transparency-contrast")
}
view.updateDisplayOptions(reduceTransparency: false, increasedContrast: false)
update(ModePickerState(selectedMode: .scrolling))
check(buttons(in: view).allSatisfy { !$0.isEnabled }, "Opening hold disables selection")
try render("opening")
var state = ModePickerState(selectedMode: .scrolling)
state.isArmed = true
update(state)
view.updateDisplayOptions(reduceTransparency: true, increasedContrast: true)
try render("reduced-transparency-contrast")
check(view.subviews.compactMap { $0 as? NSVisualEffectView }.allSatisfy(\.isHidden), "Opaque fallback hides the material")

var navigation: [Int] = []
var confirmations = 0
var cancellations = 0
view.onMove = { navigation.append($0) }
view.onConfirm = { confirmations += 1 }
view.onCancel = { cancellations += 1 }
for code: UInt16 in [123, 124, 125, 126, 36, 76, 53] {
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                windowNumber: window.windowNumber, context: nil, characters: "",
                                charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    view.keyDown(with: event)
}
check(navigation == [-1, 1, 1, -1], "Arrow keys navigate both directions")
check(confirmations == 2 && cancellations == 1, "Return and Escape route correctly")

var selected: [Mode] = []
view.onSelect = { selected.append($0) }
for mode in Mode.generalModes {
    let location = RadialMenuGeometry.point(angle: RadialMenuGeometry.angle(for: mode) + 20, radius: 125)
    func mouse(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                          clickCount: 1, pressure: 1)!
    }
    view.mouseDown(with: mouse(.leftMouseDown))
    view.mouseUp(with: mouse(.leftMouseUp))
}
check(selected == Mode.generalModes, "Each wedge supports pointer selection")
// Exercise actual contextual pointer targets, including the nonselectable parent.
state = ModePickerState(selectedMode: .lightroomCrop, profile: .lightroom)
state.isArmed = true
update(state)
view.updateDisplayOptions(reduceTransparency: false, increasedContrast: false)
selected.removeAll()
var highlights: [Mode] = []
view.onHighlight = { highlights.append($0) }
func mouse(_ type: NSEvent.EventType, at location: NSPoint) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                      windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                      clickCount: 1, pressure: 1)!
}
for segment in view.menuLayout.segments {
    let location = view.menuLayout.point(angle: segment.angle, radius: segment.iconRadius)
    view.mouseMoved(with: mouse(.mouseMoved, at: location))
    view.mouseDown(with: mouse(.leftMouseDown, at: location))
    view.mouseUp(with: mouse(.leftMouseUp, at: location))
}
check(selected == AppProfile.lightroom.availableModes, "Pointer selection skips the app parent and selects all seven leaves")
check(highlights.count == AppProfile.lightroom.availableModes.count * 2, "The parent cannot be highlighted")
let parent = view.menuLayout.appGroupSegment!
let parentPoint = view.menuLayout.point(angle: parent.angle, radius: parent.iconRadius)
check(!(view.hitTest(parentPoint) is NSButton), "The app icon is not an actionable control")
let selectedBefore = selected.count
state.isArmed = false
update(state)
check(buttons(in: view).allSatisfy { !$0.isEnabled }, "Opening hold disables both rings")
let child = view.menuLayout.segment(for: .lightroomFineTune)!
let childPoint = view.menuLayout.point(angle: child.angle, radius: child.iconRadius)
view.mouseDown(with: mouse(.leftMouseDown, at: childPoint))
view.mouseUp(with: mouse(.leftMouseUp, at: childPoint))
check(selected.count == selectedBefore, "Opening hold cannot activate an outer child")
try render("lightroom-opening")
state.isArmed = true
update(state)
view.updateDisplayOptions(reduceTransparency: true, increasedContrast: true)
try render("lightroom-reduced-transparency-contrast")
check(view.subviews.compactMap { $0 as? NSVisualEffectView }.allSatisfy(\.isHidden), "Contextual opaque fallback hides material")
var didCancel = false
view.onCancel = { didCancel = true }
view.mouseDown(with: mouse(.leftMouseDown, at: view.menuLayout.point(angle: 0, radius: 180)))
check(didCancel, "Empty space outside the partial outer ring cancels")
update(ModePickerState(selectedMode: .zoom))
check(view.bounds.width == 300 && buttons(in: view).count == Mode.generalModes.count,
      "Leaving app context restores the standard size and choices")
print("Passed \(checks) native view checks; rendered general, Lightroom and Editwall states to \(destination.path)")
