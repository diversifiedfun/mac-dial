import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fatalError(message) }
}
var accessibility = false
var eventPosting = false
let permissions = DialPermissions(accessibility: { accessibility }, eventPosting: { eventPosting })
var changes: [Bool] = []
permissions.onChange = { changes.append($0) }
check(!permissions.isGranted, "Unknown permissions fail closed")
check(!permissions.refresh() && changes == [false], "Denied launch triggers recovery once")
for _ in 0..<20 { _ = permissions.refresh() }
check(changes == [false], "Polling does not repeatedly alert while blocked")
accessibility = true
check(!permissions.refresh(), "An Accessibility grant alone cannot enable denied event posting")
eventPosting = true
check(permissions.refresh() && changes == [false, true], "Both permissions resume control")
accessibility = false
check(!permissions.refresh() && changes == [false, true, false], "Revocation pauses an already running app")
accessibility = true
check(permissions.refresh(), "Recovery re-enables access without relaunching when macOS permits")
eventPosting = false
check(!permissions.refresh(), "Event-posting revocation also pauses actions")
let priorChanges = changes
for _ in 0..<20 { _ = permissions.refresh() }
check(changes == priorChanges, "One notification per blocked episode")

var settingsRequests = 0
let window = DialPermissionWindow(check: { permissions.refresh() }, openSettings: { settingsRequests += 1 })
func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
window.present()
RunLoop.current.run(until: Date().addingTimeInterval(0.1))
let views = allViews(window.window!.contentView!)
let buttons = views.compactMap { $0 as? NSButton }
let labels = views.compactMap { $0 as? NSTextField }
check(window.window!.isVisible, "Recovery is a visible native window")
check(settingsRequests == 0, "Opening recovery does not itself request system access")
buttons.first { $0.title == "Open Privacy Settings…" }!.performClick(nil)
check(settingsRequests == 1, "Settings button explicitly requests access")
buttons.first { $0.title == "Check Again" }!.performClick(nil)
check(window.window!.isVisible && labels.contains { $0.stringValue.contains("macOS still denies") },
      "Failed recheck keeps recovery open and explains that actions stay paused")
check(labels.contains { $0.stringValue.contains("Remove Mac Dial") && $0.stringValue.contains("Turning its switch off and on") },
      "Recovery explains stale grants rather than only recommending a toggle")
window.close()
check(!permissions.isGranted, "Dismissing help never bypasses the permission gate")
window.present()
eventPosting = true
buttons.first { $0.title == "Check Again" }!.performClick(nil)
check(!window.window!.isVisible && permissions.isGranted, "Successful recheck closes recovery")
for label in labels {
    let needed = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.frame.width, height: 10000)).height
    check(needed <= label.frame.height, "Recovery instructions fit without clipping")
}
print("Passed \(checks) permission checks: denial, revocation, recovery, notification frequency and native guidance.")
if CommandLine.arguments.contains("--preview") {
    eventPosting = false
    _ = permissions.refresh()
    window.window?.appearance = NSAppearance(named: .darkAqua)
    window.present()
    app.run()
}
