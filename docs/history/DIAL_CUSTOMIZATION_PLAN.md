> Historical development record, retained for context. Paths, test counts, and
> verification statements describe earlier checkouts and are not current release
> evidence. See [the publication audit](../PUBLICATION_AUDIT.md) and
> [contributor instructions](../../CONTRIBUTING.md) for current status.

# Mac Dial customization — completed

## Status and tracking

**Status: Complete — 2026-10-06.** Closed at the user's request. The customization implementation, UI refinements, application removal, and permission recovery are committed in `84809a0`. Automated verification and the local Release build/signature checks pass. The user marked the remaining manual customization acceptance items complete before this closeout. No customization implementation or acceptance work remains in this plan; distribution preparation is separate.

- [x] Inspect the existing settings, mode selection, input routing, and test harness.
- [x] Create three customization mockups.
- [x] Select the application-sidebar direction.
- [x] Refine the selected mockup: preview follows sidebar selection; remove the preview dropdown and close the illustrated gap.
- [x] Establish the existing build and test baseline.
- [x] Implement configuration, persistence, and migration.
- [x] Implement capacity resolution and shared dial geometry.
- [x] Integrate dynamic slices and custom shortcut execution.
- [x] Implement the customization window and application chooser.
- [x] Complete integrated behavior, visual, and physical-device verification.
- [x] Produce and verify the release build.

Approved visual reference: app-sidebar-v2.png (historical local artifact; not distributed).
Layout revision (2026-10-06): keep the application sidebar; place the linked preview below Add Application in the wider first column, the full-height slice list in the middle, and slice details on the right. Hide scrollbars when content fits. Remove redundant “Built-in slice” subtitles and the built-in explanatory footer.
Geometry revision (2026-10-06): app subslices now use half the angular width of standard slices. This replaces the original equal-angle rule; ordering and the 18-action capacity are unchanged.
The mockup establishes layout and visual direction. The geometry rules below are authoritative; generated wedge angles are illustrative.

This is the completed implementation record. Historical progress entries retain the evidence available at each milestone; the completion status and release follow-ups describe the final handoff.

## First step: establish a baseline

- [x] Inspect the current working-tree diff and preserve existing uncommitted work.
- [x] Run `bash Tests/run.sh` from `mac-dial` and capture its result. If it stalls, identify the stalled stage before proceeding; do not assume a product regression.
- [x] Run the existing render checks with `bash Tests/render.sh` and record any environment limitations.
- [x] Run `bash build-mac-dial.sh` from the workspace root and record Release build and signature-verification results.

**Completion criteria:** Current changes are understood, the build/test state is documented, and existing failures or environment blockers are distinguished from this feature's work.

Baseline verified: **2,012 behavior checks**, **1,647 native view checks**, and the Apple Silicon Release build with strict signature verification passed. The sandboxed behavior executable stalled after successful compilation; the sandboxed renderer reported `screens=0`. Both suites passed with host access, establishing these as environment limitations. Existing heading simplification, pointer offset, rendering/test changes, and the dirty HID submodule were preserved.

## Phase 1: configuration model and migration

Replace fixed-mode assumptions with shared, persisted configuration while retaining the existing built-in action controllers.

- [x] Add stable `SliceID` values: fixed identifiers for built-ins and UUIDs for custom slices.
- [x] Add `SliceDefinition`: a built-in action reference or custom name, SF Symbol, and four gesture assignments.
- [x] Add `ApplicationConfiguration`: bundle identifier, display name, application location, and ordered slices.
- [x] Add a `ResolvedDial` interface for displayed actions, clockwise navigation order, application-group membership, and overflow reasons.
- [x] Store a versioned configuration in UserDefaults.
- [x] Seed the five standard slices and existing Lightroom/Editwall actions on first migration.
- [x] Preserve existing saved selections and unrelated preferences; leave legacy preferences intact.
- [x] Preserve unreadable stored configuration before using defaults; do not silently overwrite it.
- [x] Remember selections independently for Standard and each application.
- [x] If a remembered selection is disabled, deleted, or hidden, use the first available standard action, otherwise the highest-priority app action. Retain a remembered ID during temporary overflow so it can return when available.
- [x] Add persistence and migration tests before connecting the new model to live input.

**Completion criteria:** Configuration survives relaunch; legacy state migrates without losing preferences; custom slices and application groups can be represented without extending the built-in mode enumeration.

**Evidence:** `MacDial/SliceConfiguration.swift` and `MacDial/SliceConfigurationStore.swift` are included in the Xcode target. `Tests/configuration.sh` passes **7,689 checks**, including a separate-process persistence check, and now runs as part of `Tests/run.sh`. Writes validate and encode before updating state. Malformed saved values are backed up and retained until an explicit edit; unsupported schema versions remain read-only. Runtime integration now initializes the store at launch and preserves legacy preference keys. The installed application has not been replaced or launched with these changes.

## Phase 2: resolution, ordering, and geometry

The same resolver must supply the settings preview, runtime picker, menu-bar choices, and selection validation.

- [x] Implement and test pure capacity, visibility, ordering, and fallback selection independently of UI/input. Exhaustively checked standard/app counts from 0 through 22.
- [x] Connect the resolver to the runtime picker, menu-bar choices, shared drawing geometry, and hardware-free inspection preview.
- [x] Connect the settings window's preview in Phase 4.

For each application context:

1. Take its first 18 enabled app actions.
2. Fill remaining slots from the enabled standard list.
3. Arrange standards clockwise, followed by app actions in reverse list order.

This makes the top app action the first counterclockwise step from the first standard slice.

- [x] Use a 2:1 standard/app angular ratio: standard angle = `360° / (standard count + app count / 2)`; app angle = half the standard angle. App-only and standard-only configurations still fill the circle. (Revised 2026-10-06.)
- [x] Make the nonselectable inner application group span all its outer children without consuming another slot.
- [x] Center the first standard action at twelve o'clock.
- [x] With only app actions, place the highest-priority action at twelve o'clock and arrange the rest counterclockwise.
- [x] Omit the application group when it has no enabled actions.
- [x] Handle zero actions explicitly: show “No enabled slices” and perform no dial actions.
- [x] Keep customization accessible with zero actions when the window entry point is added in Phase 4.
- [x] Model **Off** separately from **Hidden by the 18-action limit**. Overflow never changes saved enablement or order.
- [x] Display the distinct disabled/overflow labels in the settings window.
- [x] Preserve existing wheel dimensions where they fit; expand the radius at higher counts to separate icons and click targets. Constrain the complete wheel to the available screen.
- [x] Share geometry across drawing, icons, hit testing, accessibility, and inspection preview. Handle full-circle paths explicitly to prevent gaps.
- [x] Retain First Item/Last Selected behavior, wrapping, confirmation, haptics, and existing material rendering.

**Completion criteria:** Preview and runtime resolve identical actions and geometry; all count combinations, including zero, app-only, and overflow, have tested behavior and no missing wedges.

**Evidence:** `Tests/DynamicSlices.swift` exercises standard/app counts from 0 through 19, including the 2:1 standard/app angle ratio, continuous material/hit coverage, nonoverlapping native targets, full-circle paths, display fitting, custom selection, and empty states. Native view tests cover scaled controls and rendered custom states. A live Liquid Glass gallery with 18 actions was inspected for gaps, overlap, and clipping. The settings preview now uses the same resolver and renderer; native tests compare the resolved snapshots, including overflow and zero actions.

## Phase 3: runtime integration and custom shortcuts

- [x] Replace fixed mode lists in the picker and menu-bar choices with the resolved configuration.
- [x] Keep the existing built-in controllers and their behavior.
- [x] Add a custom controller through the existing controller interface.
- [x] Send one balanced key-down/key-up pair per rotation tick. Physical left/right mappings ignore Scroll Direction.
- [x] Recognize single and double clicks exclusively using the system double-click interval.
- [x] A double-click assigned No Action consumes the pair without firing the single-click action.
- [x] Keep hold reserved for opening the picker.
- [x] Verify the foreground process before sending; app-specific shortcuts also require the matching bundle identifier.
- [x] Cancel pending input on context changes, configuration edits, picker opening, disconnect, sleep, and session changes.
- [x] Wire input suppression to the customization window lifecycle. Opening, closing, and app activation changes cancel pending input. Preview selection never calls runtime selection or event delivery; recording consumes keystrokes locally. Physical device acceptance was marked complete by the user at closeout.
- [x] Test emitted events through recording-only sinks before live shortcut verification.

**Completion criteria:** Custom actions work through the existing input lifecycle, built-in actions remain intact, and stale or delayed events cannot execute in a new context.

**Evidence:** Configuration plus **146,733 behavior/geometry checks** and **1,848 native view checks** pass. Custom checks cover modifiers, repeated ticks, exclusive clicks, No Action, cancellation during a batch, and focus changes. The Apple Silicon Release build and strict signature verification pass. Live custom-shortcut delivery and physical Dial acceptance were marked complete by the user at closeout.

## Phase 4: customization window

Build a native, resizable **Customize Dial…** window opened from the menu bar.

- [x] Left pane: Standard, configured applications, Add Application, selected-row trash control, and right-click Remove Application.
- [x] Middle pane: full-height compact ordered slices, enable switches, drag handles, and Add Slice. Linked dial preview sits under Add Application in the first column.
- [x] Right pane: selected slice details and editing controls. Preview follows the sidebar selection with no independent context dropdown.
- [x] Use AppKit controls and the existing dial renderer, preserving macOS 12 compatibility and appearance/accessibility options.
- [x] Selecting a preview slice selects its editor without executing an action or changing the active runtime mode.
- [x] Built-ins show their existing actions in the same name, icon, and gesture controls as custom slices, with editing and deletion disabled. The panel explains that users can create a new slice for custom actions. Built-ins still allow enabling/reordering in the list. Custom slices allow name, icon, gesture editing, and deletion.
- [x] Provide keyboard-accessible Move Up/Down actions alongside dragging.
- [x] Save and apply changes immediately with window-scoped Undo/Redo.
- [x] Commit text edits on Return or leaving the field; prevent blank names from committing.
- [x] New custom slices start as “New Slice,” with a default symbol and four No Action assignments.
- [x] Show capacity, disabled/overflow states, empty states, and readable fallback-selection behavior.

### Application chooser

- [x] Search installed applications, put running applications first, and provide Browse for `.app` bundles.
- [x] Discover asynchronously and deduplicate by bundle identifier.
- [x] Select the existing configuration when an application is added again.
- [x] Remove applications with complete Undo/Redo restoration; keep Standard protected and empty groups until explicitly removed.
- [x] Fresh adds of removed Lightroom/Editwall groups restore enabled built-in defaults only; other applications start empty.
- [x] Load native application icons with a generic fallback.
- [x] Retain configurations when applications move or become unavailable; reconnect by bundle identifier.
- [x] Start newly added applications with an empty action list, while retaining the existing Lightroom/Editwall presets.

### Icon and shortcut editors

- [x] Search a bundled, categorized SF Symbols catalog and filter symbols unavailable on the current OS.
- [x] Each gesture supports No Action or one recorded keyboard shortcut.
- [x] Record key code and Command/Option/Control/Shift modifiers, including unmodified keys. Escape cancels recording.
- [x] Consume captured keystrokes locally so recording cannot trigger menu commands.
- [x] Support individual key combinations in version one; exclude macros, text insertion, scripts, and media-key recording.

**Completion criteria:** Users can complete the approved customization workflow with mouse or keyboard; edits persist and are undoable; previewing and recording have no action side effects.

**Evidence:** `Tests/customization.sh` uses an isolated UserDefaults suite and no HID/event-posting code. It checks editing, Undo/Redo without reverting live selections, persistence, invalid names, app deduplication, available symbols, recorder validation, preview agreement, overflow/empty states, and resized control bounds. Native interaction checks confirmed name commit on Return, searchable icon selection, TextEdit discovery/addition, custom app slices, Command-Q recording without quitting, and Command-Z undo. Light and dark windows and the 18-action app-only layout were inspected. Compilation targets macOS 12; execution was checked on the host OS.

Application discovery scans `/Applications`, `~/Applications`, `/System/Applications`, and system application utilities asynchronously, adds running apps from any location, and deduplicates by bundle identifier. Browse handles other locations. Missing applications keep their saved configuration; lookup reconnects by bundle identifier.

## Phase 5: acceptance and release verification

### Automated behavior and geometry

- [x] Migration, persistence, Undo/Redo, invalid data, and independent remembered selections.
- [x] Every standard/app count combination through 18, overflow beyond 18, disabled items, and empty configurations.
- [x] Exact clockwise/counterclockwise order, 2:1 standard/app angles, continuous outlines, and correct hit targets.
- [x] Shortcut modifiers, repeated ticks, exclusive double clicks, No Action, cancellation, and focus changes using recording-only event sinks.
- [x] Application deduplication, unavailable applications, symbol fallback, and preview/runtime agreement.
- [x] Existing behavior and render suites pass, or any external limitations are explicitly documented.

### Native visual and manual checks

- [x] Compare the native window against the approved mockup: three panes, linked preview, native controls, 2:1 standard/app angles, and no independent context dropdown.
- [x] Inspect light/dark appearance and dense 18-action configurations in the native window.
- [x] Complete a manual settings-window pass with Classic and accessibility overrides (the shared renderer already has automated coverage).
- [x] Verify app-only/empty previews and minimum-window bounds with native tests; inspect the app-only 18-action window.
- [x] Verify the completed feature on physical multi-display setups and at display edges (geometry placement is covered automatically).
- [x] Exercise real shortcut delivery in a disposable document.
- [x] Verify physical Dial rotation, click/double-click, hold, context switching, and disconnect/reconnect separately.

The manual Classic/accessibility, physical-display, live-shortcut, and physical-Dial items above were marked complete by the user before this document was closed. They are user-reported acceptance, distinct from the automated and native-preview checks performed by the coding agent.

### Release

- [x] Complete the Apple Silicon Release build and strict signature verification.
- [x] Record completed checks and remaining limitations in project documentation.
- [x] Produce the verified local build. Installation over the user's application is a separate step.

### Release follow-ups outside the completed implementation

Distribution preparation remains separate: actual permission revocation/recovery and permission continuity across consistently signed updates have no recorded test result here. Recovery has been tested with simulated grants; local builds remain ad-hoc signed.

Latest recorded results: **491 customization**, **21 permission**, **7,689 configuration**, **146,733 behavior/geometry**, and **1,848 native rendering checks** passed across the relevant suites. The latest Release build and strict signature verification passed. Installation and distribution signing are separate release tasks.

## Defaults and boundaries

- Approved direction, revised 2026-10-06: a 320-point application sidebar with the fixed 372-point preview panel under Add Application, a full-height slice list in the middle, and slice details on the right. The main preview dial keeps a consistent size across contexts, reserving space for application subslices in Standard.
- Default editing behavior: immediate save/apply with Undo/Redo; no Apply/Cancel workflow.
- Maximum 18 displayed selectable actions; saved configurations can contain more.
- Only the foreground application's group affects the live dial. Selecting an application in customization changes the preview, not the runtime target.
- Built-in action mappings remain unchanged. Custom mappings are single keyboard combinations or No Action.
- Preserve existing uncommitted changes throughout implementation.

## Progress log

| Milestone | Status | Evidence / notes |
| --- | --- | --- |
| Design selection | Complete | Application-sidebar mockup approved; preview dropdown removed in v2. |
| Repository exploration | Complete | Fixed built-in modes, existing controller interface, context guards, geometry, and native test harness inspected. |
| Baseline verification | Complete | 2,012 behavior checks, 1,647 native view checks, Release build and signature verification passed. Native tests require host access. |
| Configuration and migration | Complete | 7,689 configuration checks passed, including cross-process persistence; 2,012 existing behavior checks still pass. Foundation Release build and signature verification passed. |
| Resolver and geometry | Complete | Runtime and settings preview share resolution and geometry; 2:1 standard/app angles, app ordering, adaptive radius, full circles, and empty/overflow states verified. |
| Runtime and shortcuts | Complete | Dynamic routing, custom shortcuts, and window input suppression connected. 146,733 behavior/geometry checks and 1,848 native checks pass; physical/live acceptance marked complete by the user. |
| Customization UI | Complete | Native sidebar, lists, editor, preview, app chooser, icon search, shortcut recorder, persistence and Undo/Redo implemented. Isolated native tests and interaction checks pass. |
| Layout refinement (2026-10-06) | Complete | Sidebar scrollbar appears only when needed; compact slice rows omit type subtitles while keeping Off/overflow labels. Preview and details swapped; built-in explanatory footer removed. |
| Acceptance and local build | Complete | Automated suites and Release build/signature pass. Native light/dark, dense preview and editing interactions checked. Remaining manual customization acceptance marked complete by the user. |
| Final handoff (2026-10-06) | Complete | User requested closure after implementation commit `84809a0`; this document records the completed scope and remaining release validation. |

### Verification logs

- Baseline behavior: `customization-baseline-tests-host.log` (historical local artifact; not distributed).
- Baseline native rendering: `customization-baseline-render-host.log` (historical local artifact; not distributed).
- Baseline build/signature: `customization-baseline-build.log` (historical local artifact; not distributed).
- Foundation configuration and behavior suites: `customization-foundation-tests-host.log` (historical local artifact; not distributed).
- Foundation build/signature: `customization-foundation-build.log` (historical local artifact; not distributed).
- Runtime configuration and behavior: `customization-runtime-tests.log` (historical local artifact; not distributed).
- Runtime native views: `customization-runtime-render.log` (historical local artifact; not distributed).
- Runtime build/signature: `customization-runtime-build.log` (historical local artifact; not distributed).
- Hardware-free preview build: `customization-runtime-preview.log` (historical local artifact; not distributed).
- Custom-state Classic render exports: `radial-render/images` (historical local artifact; not distributed). Live glass was inspected separately because offscreen capture cannot reproduce its compositor effects reliably.

- Customization editing/native checks: `customization-window-tests-host.log` (historical local artifact; not distributed).
- Full configuration and behavior suites: `customization-window-behavior.log` (historical local artifact; not distributed).
- Full native renderer checks: `customization-window-render.log` (historical local artifact; not distributed).
- Completed UI build/signature: `customization-window-build.log` (historical local artifact; not distributed).

Logs and build outputs are local artifacts. The cross-process preference test also needs host preference-service access; its temporary UUID-named suite is removed after verification. The customization preview also uses temporary UUID-named preferences, removed on normal exit. Physical-device checks and live custom-shortcut delivery were marked complete by the user at closeout. The coding agent did not replace the installed application.

Layout revision verification: `customization-layout-tests.log` (379 native customization checks) and `customization-layout-build.log` (Release build/signature). Native Standard and custom-slice layouts inspected in the isolated preview.

Half-width subslice verification (2026-10-06): `customization-half-width-tests.log`, `customization-half-width-render.log`, `customization-half-width-editor.log`, and `customization-half-width-build.log`. Geometry checks cover every standard/app count from 0 through 19, continuous boundaries, the half-width ratio, full-circle totals, nonoverlapping targets, and app logos contained in their parent wedges.

Native visual check: recreated the Editwall example with five standard actions and two app actions in the isolated customization preview. Standard slices span 60° and app subslices 30°, with the same ordering and intact selection arcs. All suites passed: 7,689 configuration, 146,733 behavior/geometry, 1,848 native rendering, and 379 customization checks; Release build and strict signature verification passed.

Default-slice details revision (2026-10-06): default slices now share the custom-slice form, with name, icon, gesture and delete controls disabled. Added “Default slices can’t be edited. Create a new slice to add custom actions.” Existing controller behavior is unchanged. Native inspection confirmed disabled default controls and enabled custom controls; 379 customization checks and Release/signature verification passed (`customization-default-controls-tests.log`, `customization-default-controls-build.log`).

Preview and helper-text refinement (2026-10-06): moved the slice helper directly below Slice Details in the standard 13-point helper style; removed disabled-row “Off” labels and preview order captions. The preview occupies the bottom half of the middle column, scales on resize, and keeps its main rim radius and center fixed across Standard/application contexts. Standard reserves space for the outer app ring; a fixed scrollable status area preserves overflow/empty-state explanations without changing dial size. Native Standard/Lightroom and disabled-row inspection passed, along with 385 customization checks (including context-size/center and resize checks) and Release build/signature verification. Logs: `customization-preview-layout-tests.log`, `customization-preview-layout-build.log`.

Larger preview refinement (2026-10-06): removed the bottom hidden-actions paragraph and reclaimed its reserved space for the dial. Halved preview effect padding and the top/bottom layout gaps; the main dial is approximately 31% larger at the default window size while remaining centered and equally sized across contexts. Guidance and exceptional/empty-state messages share the compact area below Preview. Native Standard and dense 18-action layouts inspected without clipping; 384 customization checks, 1,848 native view checks, and Release build/signature verification passed. Removed the obsolete assertion requiring the deleted paragraph. Logs: `customization-larger-preview-tests.log`, `customization-larger-preview-render.log`, `customization-larger-preview-build.log`.

Numbered slice rows (2026-10-06): removed per-row “Hidden by the 18-action limit” subtitles. Every row is now 36 points tall, with its saved list position before the drag handle. Rows 1–18 show numbers and switches; later rows show X and hide their switches. Moving a slice across position 18 updates the marker and switch without changing saved enablement or dial resolution. Native inspection confirmed numbered rows and accessibility state for X rows. All 388 customization checks passed, including moving across the row-18 boundary in both directions; Release build/signature verification passed. Logs: `customization-row-numbers-tests.log`, `customization-row-numbers-build.log`.

Separate number gutter (2026-10-06): moved position numbers/X markers out of draggable rows and their selection highlights into a sibling gutter inside the same scroll document. Numbers remain attached to list positions while slice rows reorder; both scroll together. Adjusted table-column sizing and resizing of row controls for the narrower table. Native inspection verified selected-row separation, drag reordering, aligned scrolling through X rows, and unclipped switches. All 390 customization checks and Release build/signature verification passed. Logs: `customization-number-gutter-tests.log`, `customization-number-gutter-build.log`.

Fixed preview panel and blank overflow markers (2026-10-06): replaced X markers after position 18 with blank gutter placeholders; switches remain hidden for those rows. Halved preview top/bottom gaps and effect padding again. The preview panel now stays 410 points tall and anchored to the bottom; the slice list receives all remaining vertical space as the window resizes. Main dial size remains consistent across contexts. Dense native preview inspected; 391 customization checks (including fixed preview size, bottom anchoring, and list growth across window sizes) and Release build/signature verification passed. Logs: `customization-fixed-preview-tests.log`, `customization-fixed-preview-build.log`.

Compact preview caption revision (2026-10-06): removed the app-priority helper paragraph and reclaimed its 38-point area, reducing the fixed preview panel from 410 to 372 points while preserving the normal dial size and position. Standard uses the same compact panel; click-to-edit guidance is available as a tooltip. Exceptional/empty-state messages remain available when needed. Native dense preview inspected; 391 customization checks and Release build/signature verification passed. Logs: `customization-compact-preview-tests.log`, `customization-compact-preview-build.log`.

Undo/Redo navigation (2026-10-06): history entries now retain the owning Standard/application group, affected slice ID, and row fallback. Undo/Redo return to that group, select the affected slice, and scroll the sidebar/list and details into view. Deleted targets reveal a neighboring row or the empty group; undoing application creation falls back to Standard, while redo opens the restored application. Navigation made after an edit does not change its undo/redo destination, and live dial selections remain untouched. All 413 customization checks passed, covering cross-context edits, rename/toggle/reorder, add/delete, Standard edits through app previews, empty groups, persistent redo location, live-selection preservation, and offscreen-row reveal. Native button Undo and keyboard Redo verified from Standard back to Lightroom. Release build/signature verification passed. Logs: `customization-undo-navigation-tests.log`, `customization-undo-navigation-build.log`.

Sidebar preview relocation (2026-10-06): moved Preview below Add Application in the first column and widened that column from 204 to 320 points. The middle column now uses the full available height for slices, with its toolbar at the bottom. The preview retains its fixed-height panel and consistent main dial size across contexts. Adjusted middle/details widths to fit the existing minimum window size. Native dense Lightroom and Standard layouts inspected; 419 customization checks (including sidebar placement, resizing and offscreen Undo/Redo reveal) and Release build/signature verification passed. Logs: `customization-sidebar-preview-tests.log`, `customization-sidebar-preview-build.log`.

Application removal and fresh defaults (2026-10-06): added a trash icon on the selected application row and a right-click Remove Application command. Removal selects Standard without a confirmation dialog. Undo restores the original group, sidebar position, custom actions, switches, slice order and selection; Redo removes it again. Standard is protected and deleting a final slice retains the empty group. Fresh Add Application restores only enabled built-in defaults for Lightroom/Editwall, discards old custom actions, and starts other applications empty. Existing groups are never reset by Add Application. Read-only configurations reject removal. All 463 customization checks passed, including persistence/reload, both built-in profiles, empty/nonselected group removal, complete undo restoration, fresh-add behavior, protected configuration handling, and native trash controls. Native right-click removal, Undo, trash removal, and Lightroom fresh-add flow verified. Release build/signature verification passed. Logs: `customization-remove-application-tests.log`, `customization-remove-application-build.log`.

Application identifiers (2026-10-06): application sidebar rows now show their bundle identifier beneath the friendly name, including `com.adobe.LightroomClassicCC7` for Lightroom. Long identifiers truncate with the full value available in a tooltip; Standard retains its single-line label. Native layout inspected; all 463 customization checks and Release build/signature verification passed. Logs: `customization-app-identifiers-tests.log`, `customization-app-identifiers-build.log`.

Slice name limit (2026-10-06): new and edited custom names are limited to 20 Unicode characters, including spaces, during typing/paste and commit. Composing input is allowed to finish first. Existing saved names remain intact until renamed. The dial center uses up to two lines at the normal text size, with an ellipsis for overflow; Slice Details retains the full name. Native paste and two-line display verified. All 491 customization checks passed, including Unicode boundaries, persistence, Undo/Redo and multiline label behavior. Release build and signature verification passed. Logs: `customization-name-limit-tests.log`, `customization-name-limit-build.log`.

Shared application identifiers (2026-10-06): verified that the installed Photoshop 2026 (27.11.0) and Photoshop Beta (27.12.0) both declare `com.adobe.Photoshop`. Discovery merges installations by bundle ID, runtime matching shares their dial configuration, and icon lookup can select either installation. The user chose to retain this behavior and document the limitation. README now explains the single search entry, shared configuration, and potentially different icon. No application code changed; distinguishing installations by path is deferred.

Bundle ID placement (2026-10-06): moved the identifier out of application sidebar rows and beneath the selected application heading in the second column. The identifier is selectable and wraps with an adaptive height. Sidebar names are vertically centered on one line; Standard omits the identifier and its spacing. Native Lightroom and Standard layouts inspected; all 491 customization checks and Release build/signature verification passed. Logs: `customization-identifier-location-tests.log`, `customization-identifier-location-build.log`.

Menu ordering (2026-10-06): moved Customize Dial to the last position in the menu bar actions section, after standard/application slices and before the settings separator. Dynamic action refreshes insert before Customize Dial so it stays last. Source ordering check and Release build/signature verification passed (`customization-menu-order-build.log`).

Permission recovery (2026-10-06): replaced the one-time launch alert with process-level Accessibility and event-posting checks, a persistent menu warning and native recovery window. Denied access pauses input/actions, cancels pending gestures and scrolling, dismisses the live dial and disables action choices; customization/settings remain usable. Rechecks run every second, on application activation and before input routing. Recovery restores controls, discards stale input and wakes connection retry. Help appears once per denied episode and includes remove-entry/reopen/re-enable instructions for stale grants. The build script remains ad-hoc signed; consistent Developer ID signing and privacy-grant continuity remain release requirements. All 21 isolated permission checks, 7,689 configuration checks, 146,733 input/behavior checks, and Release build/signature verification passed. Recovery and denied recheck inspected in a native preview using simulated grants. Actual system permission revocation/recovery, physical Dial behavior, and signed-update continuity still require manual verification; no system grants or installed app were changed. Logs: `permissions-tests.log`, `permissions-behavior-tests.log`, `permissions-build.log`.

Applications panel heading (2026-10-06): added an Applications header above the sidebar list and removed the application ordering helper beneath the bundle ID, reclaiming that space for slices. Standard retains its existing context helper. Native layout inspected; 491 customization checks and Release build/signature verification passed. The rebuilt app includes permission recovery for user testing. Logs: `customization-applications-heading-tests.log`, `customization-applications-heading-build.log`.

Consistent headers (2026-10-06): aligned the selected context heading with Applications and Slice Details, using the same 20-point semibold type and 32-point frame at y=28. Preview already uses the same font. All 491 customization checks and Release build/signature verification passed. Logs: `customization-consistent-headers-tests.log`, `customization-consistent-headers-build.log`.

Default slice subheading (2026-10-06): added Default slice beneath built-in slice names in Slice Details, matching the Custom slice label styling and position. Standard scope remains appended when selecting a standard slice through an application preview. All 491 customization checks and Release build/signature verification passed. Logs: `customization-default-subheading-tests.log`, `customization-default-subheading-build.log`.
