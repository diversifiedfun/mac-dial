import AppKit

enum Dial {
    enum ButtonState { case pressed, released }
    enum Rotation { case Clockwise(Int), CounterClockwise(Int) }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit Customization Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu
mainMenu.addItem(appMenuItem)
let editMenuItem = NSMenuItem()
editMenuItem.title = "Edit"
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
let redoItem = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
redoItem.keyEquivalentModifierMask = [.command, .shift]
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editMenuItem.submenu = editMenu
mainMenu.addItem(editMenuItem)
app.mainMenu = mainMenu
let suiteName = "local.macdial.customization-tests." + UUID().uuidString
let defaults = UserDefaults(suiteName: suiteName)!
let store = try SliceConfigurationStore(defaults: defaults)
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fatalError(message) }
}
let session = DialCustomizationSession(store: store)
session.undoManager.groupsByEvent = false
func edit(_ action: () -> Void) {
    session.undoManager.beginUndoGrouping()
    action()
    session.undoManager.endUndoGrouping()
}
let initial = store.configuration
edit { session.addSlice() }
let customID = session.selectedID!
check(session.slices.count == 6, "Add standard slice")
check(session.selected?.title == "New Slice", "New custom defaults")
check(store.configuration.selectedStandardSliceID == initial.selectedStandardSliceID, "Editor does not change runtime selection")
edit { session.updateCustom(customID, name: "Rename Slice") { $0.name = "Photo Review" } }
session.undoManager.undo()
check(session.selected?.title == "New Slice", "Undo rename")
session.undoManager.redo()
check(session.selected?.title == "Photo Review", "Redo rename")
edit { session.move(customID, to: 0) }
check(session.slices.first?.id == customID, "Move upward")
session.undoManager.undo()
check(session.slices.last?.id == customID, "Undo reorder")
edit { session.update(customID, name: "Disable") { $0.isEnabled = false } }
check(session.resolved.visibility[customID] == .disabled, "Off is explicit")
session.undoManager.undo()
check(session.resolved.contains(customID), "Undo enablement")
let activeSelection = SliceID.builtIn(.zoom)
try store.select(activeSelection)
session.undoManager.undo()
check(store.configuration.selectedStandardSliceID == activeSelection, "Content undo preserves live selection")
session.undoManager.redo()
let lightroom = AppProfile.lightroom.bundleIdentifier
session.selectContext(lightroom)
let selectionBeforePreview = store.configuration
session.selectSlice(.builtIn(.brightness))
check(store.configuration == selectionBeforePreview, "Preview selection cannot change config")
edit { session.addSlice() }
let appCustom = session.selectedID!
check(session.application?.slices.last?.id == appCustom, "App custom belongs to its group")
edit { session.updateCustom(appCustom, name: "Shortcut") { $0.gestures.rotateLeft = .keyboardShortcut(KeyboardShortcut(keyCode: 123, modifiers: [.command, .shift])) } }
check(try! SliceConfigurationStore(defaults: defaults).configuration == store.configuration, "Edits survive reload")
edit { session.deleteSelected() }
check(!session.slices.contains { $0.id == appCustom }, "Custom delete")
session.undoManager.undo()
check(session.slices.contains { $0.id == appCustom }, "Undo delete")
let beforeBuiltinDelete = store.configuration
session.selectSlice(.builtIn(.lightroomCrop))
session.deleteSelected()
check(store.configuration == beforeBuiltinDelete, "Built-ins cannot be deleted")
let added = ApplicationConfiguration(bundleIdentifier: "local.test.app", displayName: "Test App")
edit { session.addApplication(added) }
check(session.slices.isEmpty, "New apps have empty groups")
session.addApplication(added)
check(store.configuration.applications.filter { $0.id == added.id }.count == 1, "Duplicate app selects existing")
session.undoManager.undo()
check(session.context == nil, "Undo adding selected app returns to standard")
var errors = 0
session.onError = { _ in errors += 1 }
let beforeInvalid = store.configuration
edit { session.updateCustom(customID, name: "Invalid") { $0.name = "   " } }
check(errors == 1 && store.configuration == beforeInvalid, "Invalid names never persist")
let entries = DialSymbolCatalog.entries
check(!entries.isEmpty && Set(entries.map(\.name)).count == entries.count, "Unique available symbols")
for entry in entries { check(NSImage(systemSymbolName: entry.name, accessibilityDescription: nil) != nil, "Available symbol") }
for code in UInt16(0)...127 {
    let shortcut = KeyboardShortcut.recorded(keyCode: code, flags: [.command, .option, .control, .shift])
    if let shortcut = shortcut {
        check(shortcut.isValid && shortcut.modifiers == .supported, "Recorder stores allowed modifiers")
        check(!shortcut.displayName.isEmpty, "Shortcut has display name")
    }
}
check(KeyboardShortcut.recorded(keyCode: 53, flags: []) == nil, "Escape cancels")
check(KeyboardShortcut.recorded(keyCode: 72, flags: []) == nil, "Media keys excluded")
check(KeyboardShortcut.recorded(keyCode: 123, flags: [])?.displayName == "←", "Unmodified arrow")
let functionCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
for (index, code) in functionCodes.enumerated() {
    for flags: NSEvent.ModifierFlags in [[], [.function], [.function, .command, .option, .control, .shift]] {
        let shortcut = KeyboardShortcut.recorded(keyCode: code, flags: flags)
        let expected = KeyboardShortcut(keyCode: code, modifiers: flags.contains(.command) ? .supported : [])
        check(shortcut == expected, "F\(index + 1) records without storing Fn as a shortcut modifier")
        check(shortcut?.displayName == (expected.modifiers.isEmpty ? "" : "⌃⌥⇧⌘") + "F\(index + 1)", "Function key label matches its physical key")
        let data = try JSONEncoder().encode(expected)
        let restored = try JSONDecoder().decode(KeyboardShortcut.self, from: data)
        check(restored == expected, "Function key survives persistence")
    }
}
let discovered = DiscoveredDialApplication.merged([
    .init(id: "b", name: "Beta", url: URL(fileURLWithPath: "/old.app"), running: false),
    .init(id: "a", name: "Alpha", url: URL(fileURLWithPath: "/alpha.app"), running: false),
    .init(id: "b", name: "Beta", url: URL(fileURLWithPath: "/running.app"), running: true)])
check(discovered.count == 2 && discovered[0].id == "b" && discovered[0].url.path == "/running.app", "Running first and deduplicated")
check(customizationSymbol("local.macdial.missing.symbol") != nil, "Unknown symbols have a visible fallback")
var unavailable = store.configuration
let unavailableSlice = SliceDefinition.custom(CustomSlice(name: "Unavailable app action"))
unavailable.applications.append(ApplicationConfiguration(bundleIdentifier: "local.missing.app", displayName: "Missing App",
    applicationURL: URL(fileURLWithPath: "/nonexistent/Missing.app"), slices: [unavailableSlice]))
try store.replace(with: unavailable)
check(store.configuration.resolved(for: "local.missing.app").contains(unavailableSlice.id), "Missing application location does not discard its group")
check(try! SliceConfigurationStore(defaults: defaults).configuration == unavailable, "Unavailable applications survive relaunch")

// History navigation belongs to the edit, independent of subsequent browsing.
try store.replace(with: .builtInDefaults)
let history = DialCustomizationSession(store: store)
history.undoManager.groupsByEvent = false
func historyEdit(_ action: () -> Void) {
    history.undoManager.beginUndoGrouping()
    action()
    history.undoManager.endUndoGrouping()
}
history.selectContext(lightroom)
historyEdit { history.addSlice() }
let historySlice = history.selectedID!
history.selectContext(nil)
history.undoManager.undo()
check(history.context == lightroom && !history.slices.contains { $0.id == historySlice }, "Undo add returns to affected app")
history.selectContext(AppProfile.editwall.bundleIdentifier)
history.undoManager.redo()
check(history.context == lightroom && history.selectedID == historySlice, "Redo add selects restored slice after browsing elsewhere")
historyEdit { history.updateCustom(historySlice, name: "Rename") { $0.name = "History Target" } }
try store.select(.builtIn(.lightroomFineTune), for: lightroom)
history.selectContext(nil)
history.undoManager.undo()
check(history.context == lightroom && history.selectedID == historySlice && history.selected?.title == "New Slice", "Undo rename reveals correct editor")
history.selectContext(nil)
history.undoManager.redo()
check(history.context == lightroom && history.selectedID == historySlice && history.selected?.title == "History Target", "Redo rename retains edit location")
check(history.application?.selectedSliceID == .builtIn(.lightroomFineTune), "History navigation preserves live app selection")
history.selectSlice(.builtIn(.lightroomCrop))
historyEdit { history.update(historySlice, name: "Disable") { $0.isEnabled = false } }
history.selectContext(nil)
history.undoManager.undo()
check(history.context == lightroom && history.selectedID == historySlice && history.selected?.isEnabled == true, "Undo toggle reveals edited slice rather than prior selection")
history.selectContext(nil)
history.undoManager.redo()
check(history.context == lightroom && history.selectedID == historySlice && history.selected?.isEnabled == false, "Redo disabled slice stays selected in its editor")
historyEdit { history.move(historySlice, to: 0) }
history.selectContext(nil)
history.undoManager.undo()
check(history.context == lightroom && history.selectedID == historySlice && history.slices.last?.id == historySlice, "Undo reorder follows moved slice")
history.selectContext(nil)
history.undoManager.redo()
check(history.selectedID == historySlice && history.slices.first?.id == historySlice, "Redo reorder follows moved slice")
historyEdit { history.deleteSelected() }
history.selectContext(nil)
history.undoManager.undo()
check(history.context == lightroom && history.selectedID == historySlice, "Undo deletion selects restored slice")
history.selectContext(nil)
history.undoManager.redo()
check(history.context == lightroom && history.selectedID == history.slices.first?.id && history.selectedID != historySlice, "Redo deletion reveals neighboring row in affected group")
// Editing a Standard action through an app preview should reveal Standard.
history.selectContext(lightroom)
historyEdit { history.update(.builtIn(.zoom), name: "Disable Zoom") { $0.isEnabled = false } }
history.selectContext(AppProfile.editwall.bundleIdentifier)
history.undoManager.undo()
check(history.context == nil && history.selectedID == .builtIn(.zoom), "Undo reveals owning Standard group for preview edits")
history.selectContext(lightroom)
history.undoManager.redo()
check(history.context == nil && history.selectedID == .builtIn(.zoom), "Redo Standard edit ignores current app context")
historyEdit { history.addApplication(added) }
history.selectContext(lightroom)
history.undoManager.undo()
check(history.context == nil, "Undo removed application falls back to Standard")
history.selectContext(lightroom)
history.undoManager.redo()
check(history.context == added.id && history.selectedID == nil, "Redo application opens its empty group")
historyEdit { history.addSlice() }
let onlySlice = history.selectedID!
history.selectContext(nil)
history.undoManager.undo()
check(history.context == added.id && history.slices.isEmpty && history.selectedID == nil, "Undo sole slice reveals empty group")
history.selectContext(nil)
history.undoManager.redo()
check(history.context == added.id && history.selectedID == onlySlice, "Redo sole slice selects recreated item")

// Removal is reversible; a fresh Add Application restores only shipped defaults.
try store.replace(with: .builtInDefaults)
let removal = DialCustomizationSession(store: store)
removal.undoManager.groupsByEvent = false
func removalEdit(_ action: () -> Void) {
    removal.undoManager.beginUndoGrouping()
    action()
    removal.undoManager.endUndoGrouping()
}
for profile in [AppProfile.lightroom, .editwall] {
    removal.selectContext(profile.bundleIdentifier)
    removalEdit { removal.addSlice() }
    let removedCustomID = removal.selectedID!
    removalEdit { removal.updateCustom(removedCustomID, name: "Customize") {
        $0.name = "Saved custom action"
        $0.gestures.click = .keyboardShortcut(KeyboardShortcut(keyCode: 35, modifiers: [.command]))
    } }
    removalEdit { removal.move(removedCustomID, to: 0) }
    removalEdit { removal.update(.builtIn(profile.modes[0]), name: "Disable Built-in") { $0.isEnabled = false } }
    try store.select(removedCustomID, for: profile.bundleIdentifier)
    let beforeRemoval = store.configuration
    removalEdit { removal.removeApplication(profile.bundleIdentifier) }
    check(removal.context == nil && removal.selectedID == removal.slices.first?.id, "Removal selects Standard")
    check(!store.configuration.applications.contains { $0.id == profile.bundleIdentifier }, "Application and its slices removed")
    check(store.configuration.resolved(for: profile.bundleIdentifier).applicationSlices.isEmpty, "Removed application falls back to Standard dial")
    check(try! SliceConfigurationStore(defaults: defaults).configuration == store.configuration, "Removed app stays removed after reload")
    removal.undoManager.undo()
    check(store.configuration == beforeRemoval, "Undo restores complete application, settings and sidebar order")
    check(removal.context == profile.bundleIdentifier && removal.selectedID == removedCustomID, "Undo selects restored app and slice")
    removal.selectContext(nil)
    removal.undoManager.redo()
    check(removal.context == nil && !store.configuration.applications.contains { $0.id == profile.bundleIdentifier }, "Redo removes app after browsing elsewhere")
    let discoveredApp = DiscoveredDialApplication(id: profile.bundleIdentifier, name: profile.title,
        url: URL(fileURLWithPath: "/Applications/\(profile.title).app"), running: false)
    removalEdit { removal.addApplication(discoveredApp.configuration) }
    check(removal.application?.slices == profile.modes.map(SliceDefinition.builtIn), "Fresh add restores enabled built-ins in default order")
    check(!removal.slices.contains { $0.id == removedCustomID }, "Fresh add does not resurrect custom actions")
    check(removal.application?.applicationURL == discoveredApp.url, "Fresh add preserves discovered application metadata")
    check(removal.selectedID == .builtIn(profile.modes[0]), "Fresh add selects first built-in")
    check(try! SliceConfigurationStore(defaults: defaults).configuration == store.configuration, "Fresh default configuration persists")
    removal.undoManager.undo()
    check(removal.context == nil, "Undo fresh add removes its new configuration")
    removal.undoManager.undo()
    check(store.configuration == beforeRemoval, "Undo original removal still restores custom configuration")
    removal.addApplication(discoveredApp.configuration)
    check(store.configuration == beforeRemoval, "Adding existing app preserves customized slices")
}
removalEdit { removal.addApplication(added) }
removalEdit { removal.addSlice() }
let genericCustomID = removal.selectedID!
removalEdit { removal.deleteSelected() }
check(removal.application?.id == added.id && removal.slices.isEmpty, "Deleting last slice keeps the application group")
removalEdit { removal.removeApplication(added.id) }
check(removal.context == nil, "Empty application can be removed")
removal.undoManager.undo()
check(removal.context == added.id && removal.slices.isEmpty, "Undo restores empty application")
removal.undoManager.undo()
check(removal.selectedID == genericCustomID, "Undo last-slice deletion restores its custom action")
removal.selectContext(lightroom)
removalEdit { removal.removeApplication(added.id) }
check(removal.context == nil, "Removing an unselected app also returns to Standard")
removalEdit { removal.addApplication(added) }
check(removal.context == added.id && removal.slices.isEmpty, "Other applications start empty when re-added")
let unchangedRemoval = store.configuration
removal.removeApplication("Standard")
removal.removeApplication("local.nonexistent.application")
check(store.configuration == unchangedRemoval, "Standard and absent applications cannot be removed")
// A future-version configuration remains protected even through direct calls.
let protectedSuite = suiteName + ".protected"
let protectedDefaults = UserDefaults(suiteName: protectedSuite)!
protectedDefaults.set(Data("{\"version\":999}".utf8), forKey: SliceConfigurationStore.storageKey)
let protectedStore = try SliceConfigurationStore(defaults: protectedDefaults)
let protectedSession = DialCustomizationSession(store: protectedStore)
let protectedConfiguration = protectedStore.configuration
protectedSession.removeApplication(lightroom)
check(protectedStore.configuration == protectedConfiguration && !protectedSession.undoManager.canUndo,
    "Removal cannot change read-only configurations")
protectedDefaults.removePersistentDomain(forName: protectedSuite)

// A standalone window with temporary preferences: no HID access or event posting.
try store.replace(with: .builtInDefaults)
let window = DialCustomizationWindow(store: store)
window.session.selectContext(lightroom)
window.session.addSlice()
window.session.updateCustom(window.session.selectedID!, name: "Example") {
    $0.name = "Photo Review"
    $0.gestures.rotateLeft = .keyboardShortcut(KeyboardShortcut(keyCode: 123))
    $0.gestures.rotateRight = .keyboardShortcut(KeyboardShortcut(keyCode: 124))
    $0.gestures.click = .keyboardShortcut(KeyboardShortcut(keyCode: 35))
}
window.session.move(window.session.selectedID!, to: 0)
var visibility: [Bool] = []
window.onVisibilityChanged = { visibility.append($0) }
window.present()
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
check(visibility.last == true, "Opening suppresses live input")
check(window.preview.menuLayout.dial == window.session.resolved, "Preview follows selected app resolver")
let saved = store.configuration
window.preview.onSelectSlice?(.builtIn(.zoom))
check(window.session.selectedID == .builtIn(.zoom), "Preview opens selected editor")
check(store.configuration == saved, "Native preview does not mutate runtime")
window.session.selectSlice(window.session.slices.first!.id)
var previousPreviewLayout: (frame: NSRect, windowHeight: CGFloat, listHeight: CGFloat)?
for size in [NSSize(width: 1080, height: 740), NSSize(width: 1440, height: 1024)] {
    window.window!.setContentSize(size)
    window.window!.contentView!.layoutSubtreeIfNeeded()
    let listHeight = window.sliceTable.enclosingScrollView!.frame.height
    if let previous = previousPreviewLayout {
        let growth = size.height - previous.windowHeight
        check(window.preview.frame.size == previous.frame.size, "Resizing keeps preview size fixed")
        check(abs(window.preview.frame.minY - previous.frame.minY - growth) < 0.01, "Preview stays anchored to the bottom")
        check(abs(listHeight - previous.listHeight - growth) < 0.01, "Slice list takes all additional window height")
    }
    previousPreviewLayout = (window.preview.frame, size.height, listHeight)
    let appRadius = window.preview.menuLayout.coreRadius * window.preview.frame.width / window.preview.bounds.width
    let appCenter = NSPoint(x: window.preview.frame.midX, y: window.preview.frame.midY)
    window.session.selectContext(nil)
    let standardRadius = window.preview.menuLayout.coreRadius * window.preview.frame.width / window.preview.bounds.width
    check(abs(appRadius - standardRadius) < 0.01, "Main dial radius is stable across contexts")
    check(abs(window.preview.frame.midX - appCenter.x) < 0.01 && abs(window.preview.frame.midY - appCenter.y) < 0.01,
        "Main dial center is stable across contexts")
    window.session.selectContext(lightroom)
    check(window.preview.frame.maxX <= size.width && window.preview.frame.maxY <= size.height, "Preview fits resized window")
    let sidebarFrame = window.sidebar.enclosingScrollView!.frame
    let listFrame = window.sliceTable.enclosingScrollView!.frame
    check(window.preview.frame.maxX < listFrame.minX, "Preview stays in the sidebar beside the slice list")
    check(window.preview.frame.minY > sidebarFrame.maxY, "Preview sits below the application list")
    check(listFrame.maxY > window.preview.frame.midY, "Slice list uses the space beside the preview")
    if let cell = window.sliceTable.view(atColumn: 0, row: 0, makeIfNecessary: true) {
        for toggle in cell.subviews.compactMap({ $0 as? NSSwitch }) {
            check(toggle.frame.minX >= 0 && toggle.frame.maxX <= cell.bounds.width, "Enable switch fits its table cell")
            let toggleRect = toggle.convert(toggle.bounds, to: window.sliceTable)
            check(toggleRect.maxX <= window.sliceTable.bounds.width, "Enable switch fits table beside gutter")
        }
    }
}
func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
// Exercise the actual sheet controls. No shortcuts are posted to other apps.
for (index, code) in (functionCodes + [53, 53]).enumerated() {
    var result: KeyboardShortcut?
    var completions = 0
    let recorder = DialShortcutRecorder(parent: window.window!, gesture: "Click") {
        result = $0
        completions += 1
    }
    let sheet = window.window!.attachedSheet!
    let views = allViews(sheet.contentView!)
    let mode = views.compactMap { $0 as? NSSegmentedControl }.first!
    let picker = views.compactMap { $0 as? NSPopUpButton }.first!
    let use = views.compactMap { $0 as? NSButton }.first { $0.title == "Use Shortcut" }!
    check(mode.label(forSegment: 1) == "Choose Special Key" && picker.itemTitles.last == "Esc", "Special key picker includes Escape")
    check(!picker.isEnabled && !use.isEnabled, "Picker is inactive during physical key recording")
    mode.selectedSegment = 1
    _ = mode.sendAction(mode.action, to: mode.target)
    check(picker.isEnabled && use.isEnabled, "Choosing a function key enables explicit assignment")
    picker.selectItem(at: min(index, 12))
    let withModifiers = index % 2 == 1
    for name in ["Command", "Option", "Control", "Shift"] {
        let modifier = views.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == name }!
        modifier.state = withModifiers ? .on : .off
    }
    use.performClick(nil)
    check(result == KeyboardShortcut(keyCode: code, modifiers: withModifiers ? .supported : []),
        "Native selector assigns the special key with the selected modifiers")
    recorder.finish(nil)
    check(completions == 1, "Recorder completes only once")
    RunLoop.current.run(until: Date().addingTimeInterval(0.03))
}
do {
    var completions = 0
    let recorder = DialShortcutRecorder(parent: window.window!, gesture: "Click") {
        check($0 == nil, "Cancel does not save the default function key")
        completions += 1
    }
    let views = allViews(window.window!.attachedSheet!.contentView!)
    let mode = views.compactMap { $0 as? NSSegmentedControl }.first!
    mode.selectedSegment = 1
    _ = mode.sendAction(mode.action, to: mode.target)
    views.compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }!.performClick(nil)
    recorder.finish(nil)
    check(completions == 1, "Function key selection can be cancelled")
    RunLoop.current.run(until: Date().addingTimeInterval(0.03))
}
let nameTestID = window.session.selectedID!
do {
    let before = store.configuration
    window.session.undoManager.beginUndoGrouping()
    for (label, title) in [("Rotate left", "Brightness Down"), ("Rotate right", "Brightness Up")] {
        let popup = allViews(window.window!.contentView!).compactMap { $0 as? NSPopUpButton }
            .first { $0.accessibilityLabel() == label + " action" }!
        check(popup.itemTitles == ["No Action", "Keyboard Shortcut", "macOS Action"], "Action groups are exactly the three requested choices")
        popup.selectItem(withTitle: "macOS Action")
        _ = popup.sendAction(popup.action, to: popup.target)
        let systemPopup = allViews(window.window!.contentView!).compactMap { $0 as? NSPopUpButton }
            .first { $0.accessibilityLabel() == label + " macOS action" }!
        check(systemPopup.itemTitles == MacOSAction.allCases.map(\.title), "All system actions appear in the second menu")
        systemPopup.selectItem(withTitle: title)
        _ = systemPopup.sendAction(systemPopup.action, to: systemPopup.target)
        check(window.window!.attachedSheet == nil, "macOS actions do not open the shortcut recorder")
    }
    window.session.undoManager.endUndoGrouping()
    guard case .custom(let custom) = window.session.selected!.content else { fatalError("Expected custom slice") }
    check(custom.gestures.rotateLeft == .macOSAction(.brightnessDown) && custom.gestures.rotateRight == .macOSAction(.brightnessUp),
        "Native action menus save both brightness directions")
    check(try! SliceConfigurationStore(defaults: defaults).configuration == store.configuration, "Native brightness selections persist")
    let brightnessConfiguration = store.configuration
    window.session.undoManager.undo()
    check(store.configuration == before, "Undo restores previous keyboard shortcuts")
    window.session.undoManager.redo()
    check(store.configuration == brightnessConfiguration, "Redo restores brightness actions")
    window.session.undoManager.undo()
}
window.session.undoManager.groupsByEvent = false
for input in ["Exposure Adjustment", "123456789012345678901234", String(repeating: "👩🏽‍💻", count: 21),
              String(repeating: "e\u{301}", count: 21)] {
    let oldName = window.session.selected!.title
    let field = allViews(window.window!.contentView!).compactMap { $0 as? NSTextField }
        .first { $0.accessibilityLabel() == "Slice name" }!
    field.stringValue = input
    window.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    let expected = String(input.prefix(20))
    check(field.stringValue == expected, "Name field limits pasted text by complete Unicode characters")
    window.session.undoManager.beginUndoGrouping()
    window.commitName()
    window.session.undoManager.endUndoGrouping()
    check(window.session.selected?.title == expected, "Name limit persists on commit")
    let centerLabel = window.preview.subviews.compactMap { $0 as? NSTextField }
        .first { !$0.isHidden }!
    check(centerLabel.maximumNumberOfLines == 2 && centerLabel.lineBreakMode == .byTruncatingTail,
        "Dial name allows two lines and truncates overflow")
    check(centerLabel.font?.pointSize == 24 && centerLabel.frame.height == 60,
        "Long names have two full lines without shrinking the type")
    check(centerLabel.stringValue.contains("\n"), "Long center names actually break onto a second line")
    window.session.undoManager.undo()
    check(window.session.selected?.title == oldName && window.session.selectedID == nameTestID,
        "Undo restores name and selection")
    window.session.undoManager.redo()
    check(window.session.selected?.title == expected, "Redo restores limited name")
    window.session.undoManager.undo()
}
window.session.undoManager.groupsByEvent = true
let example = store.configuration
var dense = example
dense.applications[0].slices += (0..<18).map { .custom(CustomSlice(name: "App Action \($0 + 1)")) }
try store.replace(with: dense)
window.refresh()
check(window.session.resolved.actionCount == 18, "Settings preview capacity")
check(window.preview.menuLayout.dial == window.session.resolved, "Dense preview/runtime agree")
// Reordering across the numbered-row boundary restores access to the switch
// without changing the slice's saved enabled state.
let boundarySlice = window.session.slices[18]
func boundarySwitch(at row: Int) -> NSSwitch? {
    window.sliceTable.view(atColumn: 0, row: row, makeIfNecessary: true)?
        .subviews.compactMap { $0 as? NSSwitch }.first
}
check(boundarySwitch(at: 18)?.isHidden == true, "Row beyond 18 hides its switch")
window.session.move(boundarySlice.id, to: 17)
check(boundarySwitch(at: 17)?.isHidden == false, "Moving into row 18 restores the switch")
check(window.session.slices[17].isEnabled == boundarySlice.isEnabled, "Reordering preserves enabled state")
window.session.move(boundarySlice.id, to: 18)
check(boundarySwitch(at: 18)?.isHidden == true, "Moving past row 18 hides the switch again")
// Keep the history target below the viewport even with the full-height list.
window.window!.setContentSize(NSSize(width: 1080, height: 740))
window.window!.contentView!.layoutSubtreeIfNeeded()
RunLoop.current.run(until: Date().addingTimeInterval(0.05))
window.session.undoManager.removeAllActions()
window.session.undoManager.groupsByEvent = false
func sidebarRemovalButton(at row: Int) -> CustomizationButton? {
    window.sidebar.view(atColumn: 0, row: row, makeIfNecessary: true)?
        .subviews.compactMap { $0 as? CustomizationButton }.first
}
check(sidebarRemovalButton(at: 0) == nil, "Standard has no trash button")
check(sidebarRemovalButton(at: 2) == nil, "Unselected applications have no trash button")
let nativeRemove = sidebarRemovalButton(at: 1)
check(nativeRemove?.toolTip == "Remove Lightroom from Mac Dial", "Selected application exposes labeled removal control")
let nativeBeforeRemoval = store.configuration
window.session.undoManager.beginUndoGrouping()
nativeRemove?.performClick(nil)
window.session.undoManager.endUndoGrouping()
check(window.sidebar.selectedRow == 0 && window.session.context == nil, "Trash button selects Standard after removal")
check(!store.configuration.applications.contains { $0.id == lightroom }, "Trash button removes its application")
window.session.undoManager.undo()
check(store.configuration == nativeBeforeRemoval && window.sidebar.selectedRow == 1, "Native Undo restores and selects the complete group")
window.session.undoManager.removeAllActions()
let distantSlice = window.session.slices.last!.id
window.session.undoManager.beginUndoGrouping()
window.session.updateCustom(distantSlice, name: "Rename Distant Slice") { $0.name = "Distant change" }
window.session.undoManager.endUndoGrouping()
window.session.selectContext(nil)
window.session.undoManager.undo()
check(window.session.context == lightroom && window.session.selectedID == distantSlice, "Native undo returns to affected app and slice")
check(window.sidebar.selectedRow == 1 && window.sliceTable.selectedRow == window.session.slices.count - 1, "Native undo updates both selected rows")
let revealedRow = window.sliceTable.rect(ofRow: window.sliceTable.selectedRow)
check(window.sliceTable.visibleRect.contains(revealedRow), "Native undo scrolls affected row into view")
window.session.selectContext(nil)
window.session.undoManager.redo()
check(window.session.context == lightroom && window.session.selected?.title == "Distant change", "Native redo returns to edited details")
check(window.sliceTable.visibleRect.contains(window.sliceTable.rect(ofRow: window.sliceTable.selectedRow)), "Native redo scrolls affected row into view")
window.session.undoManager.groupsByEvent = true
for index in dense.standardSlices.indices { dense.standardSlices[index].isEnabled = false }
for index in dense.applications[0].slices.indices { dense.applications[0].slices[index].isEnabled = false }
try store.replace(with: dense)
window.refresh()
check(window.session.resolved.actionCount == 0, "Empty settings preview")
check(allViews(window.window!.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }
    .contains { $0.contains("No enabled slices") }, "Empty state explains recovery")
try store.replace(with: example)
window.refresh()
if CommandLine.arguments.contains("--preview") {
    window.window!.setContentSize(NSSize(width: 1240, height: 820))
    if CommandLine.arguments.contains("--dark") { window.window?.appearance = NSAppearance(named: .darkAqua) }
    if CommandLine.arguments.contains("--light") { window.window?.appearance = NSAppearance(named: .aqua) }
    if CommandLine.arguments.contains("--empty") { try store.replace(with: dense); window.refresh() }
    if CommandLine.arguments.contains("--dense") {
        for index in dense.standardSlices.indices { dense.standardSlices[index].isEnabled = true }
        for index in dense.applications[0].slices.indices { dense.applications[0].slices[index].isEnabled = true }
        try store.replace(with: dense); window.refresh()
    }
    print("Customization preview uses temporary preferences; no HID or shortcut delivery.")
    let cleanup = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
        object: nil, queue: .main) { _ in defaults.removePersistentDomain(forName: suiteName) }
    let close = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
        object: window.window, queue: .main) { _ in app.terminate(nil) }
    app.run()
    NotificationCenter.default.removeObserver(cleanup)
    NotificationCenter.default.removeObserver(close)
} else {
    window.window!.performClose(nil)
    check(visibility.last == false, "Closing restores input")
    defaults.removePersistentDomain(forName: suiteName)
    print("Passed \(checks) customization checks: editing, undo, persistence, symbols, recorder validation, application deduplication and native preview.")
}
