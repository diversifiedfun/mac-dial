import Foundation

// A second process verifies actual persisted state rather than sharing the
// first process's UserDefaults cache. Only a UUID test suite is ever opened.
if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--verify-persistence" {
    let suite = CommandLine.arguments[2]
    precondition(suite.hasPrefix("MacDial.ConfigurationTests."))
    let expected = try JSONDecoder().decode(SliceConfiguration.self,
        from: Data(base64Encoded: CommandLine.arguments[3])!)
    let reopened = try SliceConfigurationStore(defaults: UserDefaults(suiteName: suite)!)
    precondition(reopened.loadStatus == .loaded && reopened.configuration == expected,
                 "A fresh process must recover the exact saved configuration")
    exit(0)
}

var checks = 0
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) {
    do {
        let passed = try condition()
        precondition(passed, message)
    } catch { preconditionFailure("\(message): \(error)") }
    checks += 1
}

func rejects(_ operation: () throws -> Void, _ message: String) {
    do { try operation(); preconditionFailure(message) }
    catch { checks += 1 }
}

func withDefaults(_ test: (UserDefaults) throws -> Void) rethrows {
    let name = "MacDial.ConfigurationTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    try test(defaults)
}

let lightroomID = AppProfile.lightroom.bundleIdentifier
let editwallID = AppProfile.editwall.bundleIdentifier

// Migration uses the real legacy preference keys and built-in mode identifiers.
try withDefaults { defaults in
    defaults.set("zoom", forKey: "mode")
    defaults.set("lightroomBrush", forKey: "appMode.\(lightroomID)")
    defaults.set("undoRedo", forKey: "appMode.\(editwallID)")
    defaults.set("extreme", forKey: "sensitivity")
    defaults.set("classic", forKey: "radialMenuAppearance")
    let store = try SliceConfigurationStore(defaults: defaults)
    check(store.loadStatus == .migratedLegacy, "The first load migrates legacy preferences")
    var migrationNotifications = 0
    store.onChange = { _ in migrationNotifications += 1 }
    try store.replace(with: store.configuration)
    check(migrationNotifications == 0 && store.loadStatus == .migratedLegacy, "Unchanged migration does not publish a spurious edit")
    let configuration = store.configuration
    check(configuration.standardSlices.map(\.id) == Mode.generalModes.map(SliceID.builtIn), "Built-ins retain their original standard order")
    check(configuration.standardSlices.allSatisfy(\.isEnabled), "Existing standard actions start enabled")
    check(configuration.applications.map(\.bundleIdentifier) == [lightroomID, editwallID], "Existing app profiles are seeded")
    check(configuration.applications[0].slices.map(\.title) == ["Crop & Browse", "Fine Tune", "Remove"], "Built-in Lightroom names remain intact")
    check(configuration.selectedSlice(in: configuration.resolved()) == .builtIn(.zoom), "General selection migrates")
    check(configuration.selectedSlice(in: configuration.resolved(for: lightroomID)) == .builtIn(.lightroomBrush), "App action selection migrates")
    check(configuration.selectedSlice(in: configuration.resolved(for: editwallID)) == .builtIn(.undoRedo), "An app's remembered standard action migrates")
    check(defaults.string(forKey: "mode") == "zoom" && defaults.string(forKey: "appMode.\(lightroomID)") == "lightroomBrush", "Legacy keys remain untouched")
    check(defaults.string(forKey: "sensitivity") == "extreme" && defaults.string(forKey: "radialMenuAppearance") == "classic", "Unrelated settings remain untouched")
    let reloaded = try SliceConfigurationStore(defaults: defaults)
    check(reloaded.loadStatus == .loaded && reloaded.configuration == configuration, "Reload does not seed or migrate again")
    defaults.set("playback", forKey: "mode")
    check(try SliceConfigurationStore(defaults: defaults).configuration == configuration, "Legacy changes cannot overwrite a migrated document")
}

try withDefaults { defaults in
    defaults.set("lightroomCrop", forKey: "mode") // Wrong scope.
    defaults.set("editwallSequence", forKey: "appMode.\(lightroomID)")
    let configuration = try SliceConfigurationStore(defaults: defaults).configuration
    check(configuration.selectedStandardSliceID == .builtIn(.scrolling), "An invalid general selection falls back to Scroll")
    check(configuration.applications[0].selectedSliceID == nil, "An invalid app selection inherits the general selection")
    check(configuration.selectedSlice(in: configuration.resolved(for: lightroomID)) == .builtIn(.scrolling), "Invalid app selection resolves safely")
}

try withDefaults { defaults in
    defaults.set("scroll", forKey: "mode")
    let store = try SliceConfigurationStore(defaults: defaults)
    check(store.configuration.selectedStandardSliceID == .builtIn(.scrolling), "The legacy scroll alias migrates")
    var calls = 0
    store.onChange = { _ in calls += 1 }
    let custom = SliceDefinition.custom(CustomSlice(name: "Photo Review ✦", symbolName: "star", gestures: SliceGestures(
        rotateLeft: .keyboardShortcut(KeyboardShortcut(keyCode: 123)),
        rotateRight: .keyboardShortcut(KeyboardShortcut(keyCode: 124)),
        click: .keyboardShortcut(KeyboardShortcut(keyCode: 35, modifiers: [.command, .shift])),
        doubleClick: .noAction)))
    try store.edit { configuration in
        configuration.standardSlices.reverse()
        configuration.standardSlices[0].isEnabled = false
        configuration.applications.append(ApplicationConfiguration(bundleIdentifier: "test.editor", displayName: "Editor",
            applicationURL: URL(fileURLWithPath: "/Applications/Editor.app"), slices: [custom]))
    }
    check(calls == 1, "An edit notifies subscribers once")
    check(try store.select(custom.id, for: "test.editor"), "A custom app slice can be selected")
    let standardSelection = store.configuration.selectedStandardSliceID
    check(try store.select(.builtIn(.playback), for: lightroomID), "A standard slice can be remembered within an application")
    check(store.configuration.selectedStandardSliceID == standardSelection, "App selection never changes the general preference")
    check(store.configuration.applications.last?.selectedSliceID == custom.id, "Changing Lightroom does not change another app's selection")
    check(!(try store.select(custom.id)), "An app slice cannot be selected in the general context")
    let saved = store.configuration
    let reload = try SliceConfigurationStore(defaults: defaults)
    check(reload.configuration == saved, "Names, symbols, gestures, paths, enablement, order and selections round-trip")
    check(reload.configuration.resolved(for: "test.editor").applicationSlices == [custom], "A missing application on disk does not discard its actions")
    let beforeNoOp = calls
    try store.replace(with: saved)
    check(calls == beforeNoOp, "Unchanged replacements don't publish spurious edits")
    let originalData = defaults.data(forKey: SliceConfigurationStore.storageKey)
    rejects({ try store.edit { $0.standardSlices.append($0.standardSlices[0]) } }, "Duplicate identity must be rejected")
    check(store.configuration == saved && defaults.data(forKey: SliceConfigurationStore.storageKey) == originalData,
          "Rejected changes leave in-memory and persisted configuration untouched")
    check(calls == beforeNoOp, "Rejected edits do not notify observers")
}

try withDefaults { defaults in
    let store = try SliceConfigurationStore(defaults: defaults)
    let original = store.configuration
    var candidate = original
    candidate.version = 2
    rejects({ try store.replace(with: candidate) }, "Unknown schema cannot be saved")
    candidate = original
    candidate.applications.append(candidate.applications[0])
    rejects({ try candidate.validate() }, "Duplicate bundle identifiers must be rejected")
    candidate = original
    candidate.applications[0].applicationURL = URL(string: "https://example.com/app")
    rejects({ try candidate.validate() }, "Remote application locations must be rejected")
    candidate = original
    candidate.standardSlices.append(.builtIn(.lightroomCrop))
    rejects({ try candidate.validate() }, "An app-specific built-in cannot become global")
    candidate = original
    candidate.applications[1].slices.append(.builtIn(.lightroomCrop))
    rejects({ try candidate.validate() }, "A built-in cannot be assigned to an unrelated app")
    for name in ["", "  \n"] {
        candidate = original
        candidate.standardSlices.append(.custom(CustomSlice(name: name)))
        rejects({ try candidate.validate() }, "Blank names must be rejected")
    }
    candidate = original
    candidate.standardSlices.append(.custom(CustomSlice(symbolName: "  ")))
    rejects({ try candidate.validate() }, "Blank symbols must be rejected")
    candidate = original
    candidate.standardSlices.append(SliceDefinition(id: .builtIn(.scrolling), isEnabled: true, content: .custom(CustomSlice())))
    rejects({ try candidate.validate() }, "Custom content cannot impersonate a built-in identity")
    candidate = original
    candidate.standardSlices.append(.custom(CustomSlice(symbolName: "future.symbol")))
    try candidate.validate() // OS symbol availability is a UI concern, not data loss.
    checks += 1
    for keyCode: UInt16 in [54, 55, 57, 63, 72, 73, 74, 128, UInt16.max] {
        candidate = original
        candidate.standardSlices.append(.custom(CustomSlice(gestures: SliceGestures(click: .keyboardShortcut(KeyboardShortcut(keyCode: keyCode))))))
        rejects({ try candidate.validate() }, "Unsupported keys must be rejected")
    }
    candidate = original
    candidate.standardSlices.append(.custom(CustomSlice(gestures: SliceGestures(click: .keyboardShortcut(
        KeyboardShortcut(keyCode: 0, modifiers: ShortcutModifiers(rawValue: 128)))))))
    rejects({ try candidate.validate() }, "Unknown modifier bits must be rejected")
    for bits: UInt8 in 0...15 {
        check(KeyboardShortcut(keyCode: 0, modifiers: ShortcutModifiers(rawValue: bits)).isValid,
              "All supported modifier combinations, including an unmodified key, are valid")
    }
}

// Bad bytes and wrong preference types remain recoverable, including reopening
// before editing. Future schemas are read-only even if their payload is unknown.
for corrupt: Any in [Data("not JSON".utf8), "wrong preference type", Data("{\"version\":1}".utf8)] {
    try withDefaults { defaults in
        defaults.set(corrupt, forKey: SliceConfigurationStore.storageKey)
        let store = try SliceConfigurationStore(defaults: defaults)
        guard case .recovered(let key) = store.loadStatus else { fatalError("Expected recoverable invalid data") }
        check((defaults.object(forKey: key) as! NSObject).isEqual(corrupt), "Recovery preserves the exact original value")
        check((defaults.object(forKey: SliceConfigurationStore.storageKey) as! NSObject).isEqual(corrupt), "Loading corruption doesn't replace the original key")
        let reopened = try SliceConfigurationStore(defaults: defaults)
        check(reopened.loadStatus == store.loadStatus, "Reopening reuses the original recovery backup")
        try store.edit { $0.standardSlices[0].isEnabled = false }
        check((defaults.object(forKey: key) as! NSObject).isEqual(corrupt), "A later edit retains the recovery backup")
        check(try SliceConfigurationStore(defaults: defaults).configuration == store.configuration, "Explicit edits after recovery persist")
    }
}

try withDefaults { defaults in
    let future = Data("{\"version\":99,\"futurePayload\":true}".utf8)
    defaults.set(future, forKey: SliceConfigurationStore.storageKey)
    let store = try SliceConfigurationStore(defaults: defaults)
    guard case .unsupportedVersion(99, let key) = store.loadStatus else { fatalError("Expected future schema detection") }
    check(defaults.data(forKey: key) == future, "Future schemas are backed up before falling back")
    rejects({ try store.edit { $0.standardSlices.removeAll() } }, "An older build cannot overwrite a future schema")
    check(defaults.data(forKey: SliceConfigurationStore.storageKey) == future, "Future original remains intact after rejected edit")
}

try withDefaults { defaults in
    var invalid = SliceConfiguration.migrating(defaults)
    invalid.standardSlices.append(invalid.standardSlices[0])
    let bytes = try JSONEncoder().encode(invalid)
    defaults.set(bytes, forKey: SliceConfigurationStore.storageKey)
    let store = try SliceConfigurationStore(defaults: defaults)
    guard case .recovered = store.loadStatus else { fatalError("Expected semantic validation during load") }
    check(store.configuration.standardSlices.count == 5, "Invalid decoded data falls back before it can reach the resolver")
}

// Exhaust the capacity matrix, including configurations larger than the limit.
for standardCount in 0...22 {
    for appCount in 0...22 {
        let standards = (0..<standardCount).map { SliceDefinition.custom(CustomSlice(name: "Standard \($0)")) }
        let children = (0..<appCount).map { SliceDefinition.custom(CustomSlice(name: "App \($0)")) }
        let configuration = SliceConfiguration(standardSlices: standards, applications: [
            ApplicationConfiguration(bundleIdentifier: "test.app", displayName: "Test", slices: children)
        ])
        try configuration.validate()
        let dial = configuration.resolved(for: "test.app")
        let appSlots = min(appCount, 18)
        let standardSlots = min(standardCount, 18 - appSlots)
        check(dial.applicationSlices == Array(children.prefix(appSlots)), "App actions take the first capacity slots")
        check(dial.standardSlices == Array(standards.prefix(standardSlots)), "Remaining slots use the top standard actions")
        check(dial.actionCount == appSlots + standardSlots && dial.actionCount <= 18, "Capacity never exceeds 18")
        check(dial.clockwiseSlices.count == dial.actionCount && Set(dial.clockwiseSlices.map(\.id)).count == dial.actionCount,
              "Clockwise navigation contains each displayed action exactly once")
        if standardSlots > 0 && appSlots > 0 {
            check(dial.clockwiseSlices.last?.id == children.first?.id, "First counterclockwise step from the first standard reaches the top app action")
        } else if appSlots > 0 {
            check(dial.clockwiseSlices.first?.id == children.first?.id, "App-only wheel starts on highest priority")
            if appSlots > 1 { check(dial.clockwiseSlices.last?.id == children[1].id, "App-only counterclockwise movement follows priority order") }
        }
        check(dial.actionCount == 0 ? dial.standardSliceAngle == 0 : abs(dial.standardSliceAngle * Double(standardSlots) + dial.applicationSliceAngle * Double(appSlots) - 360) < 0.000001,
              "Weighted action angles fill the circle, with a safe empty state")
        check(configuration.standardSlices == standards && configuration.applications[0].slices == children,
              "Resolution never changes saved order or enablement")
        for slice in standards.dropFirst(standardSlots) + children.dropFirst(appSlots) {
            check(dial.visibility[slice.id] == .overflow, "Every undisplayed enabled action reports overflow")
        }
        let general = configuration.resolved(for: "unconfigured.app")
        check(general.applicationSlices.isEmpty && general.standardSlices.count == min(18, standardCount), "Unconfigured apps resolve to the general dial")
    }
}

try withDefaults { defaults in
    let store = try SliceConfigurationStore(defaults: defaults)
    _ = try store.select(.builtIn(.brightness))
    try store.edit { configuration in
        configuration.applications[0].slices = (0..<18).map { SliceDefinition.custom(CustomSlice(name: "App \($0)")) }
        configuration.applications[0].selectedSliceID = .builtIn(.brightness)
    }
    let full = store.configuration.resolved(for: lightroomID)
    check(full.visibility[.builtIn(.brightness)] == .overflow, "Enabled standard action can be temporarily hidden")
    check(store.configuration.selectedSlice(in: full) == full.applicationSlices.first?.id, "An app-only overflow falls back to the highest-priority app action")
    check(store.configuration.applications[0].selectedSliceID == .builtIn(.brightness), "Resolving overflow retains remembered selection")
    try store.edit { $0.applications[0].slices.removeLast(5) }
    check(store.configuration.selectedSlice(in: store.configuration.resolved(for: lightroomID)) == .builtIn(.brightness),
          "Remembered selection returns when capacity becomes available")
    try store.edit { $0.standardSlices[4].isEnabled = false }
    let disabled = store.configuration.resolved(for: lightroomID)
    check(disabled.visibility[.builtIn(.brightness)] == .disabled, "Disabled actions remain distinct from overflow")
    check(store.configuration.selectedSlice(in: disabled) == .builtIn(.scrolling), "Disabled selection falls back to first standard action")
    try store.edit { configuration in
        configuration.standardSlices.removeAll()
        configuration.applications[0].slices.removeAll()
    }
    let empty = store.configuration.resolved(for: lightroomID)
    check(empty.actionCount == 0 && empty.clockwiseSlices.isEmpty && store.configuration.selectedSlice(in: empty) == nil,
          "All-disabled/deleted configuration has no implicit action")
}

do {
    let name = "MacDial.ConfigurationTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name); defaults.synchronize() }
    let store = try SliceConfigurationStore(defaults: defaults)
    let slice = SliceDefinition.custom(CustomSlice(name: "Persisted custom slice"))
    try store.edit { configuration in
        configuration.standardSlices.insert(slice, at: 0)
        configuration.standardSlices[1].isEnabled = false
        configuration.selectedStandardSliceID = slice.id
    }
    check(defaults.synchronize(), "Test preferences flush before the independent process starts")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    process.arguments = ["--verify-persistence", name, try JSONEncoder().encode(store.configuration).base64EncodedString()]
    try process.run()
    process.waitUntilExit()
    check(process.terminationStatus == 0, "Configuration survives reopening in an independent process")
}

print("Passed \(checks) configuration checks: migration, storage, recovery, selection and capacity resolution.")
