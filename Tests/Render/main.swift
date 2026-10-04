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
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
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
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 600,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = view.bounds.size
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name + ".png"))
}

for mode in Mode.allCases {
    var state = ModePickerState(selectedMode: mode)
    state.isArmed = true
    view.update(state)
    try render(mode.rawValue)
    let buttons = view.subviews.compactMap { $0 as? NSButton }
    check(buttons.count == 3, "Three native accessible controls")
    for button in buttons {
        let candidate = Mode.allCases[button.tag]
        check(button.accessibilityRole() == .radioButton, "Mode controls expose radio-button semantics")
        check(button.accessibilityLabel() == "\(candidate.title) mode", "Mode label is accessible")
        check((button.accessibilityValue() as? Int) == (candidate == mode ? 1 : 0), "Selected value is accessible")
        check(button.image != nil && button.isEnabled, "Icons are present and actionable after release")
    }
}

view.update(ModePickerState(selectedMode: .scrolling))
check(view.subviews.compactMap { $0 as? NSButton }.allSatisfy { !$0.isEnabled }, "Opening hold disables selection")
try render("opening")
var state = ModePickerState(selectedMode: .scrolling)
state.isArmed = true
view.update(state)
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
for mode in Mode.allCases {
    let location = RadialMenuGeometry.point(angle: RadialMenuGeometry.angle(for: mode) + 20, radius: 125)
    func mouse(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                          clickCount: 1, pressure: 1)!
    }
    view.mouseDown(with: mouse(.leftMouseDown))
    view.mouseUp(with: mouse(.leftMouseUp))
}
check(selected == Mode.allCases, "Each wedge supports pointer selection")
print("Passed \(checks) native view checks; rendered five states to \(destination.path)")
