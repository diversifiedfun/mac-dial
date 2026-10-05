# Grouped Lightroom radial picker — design QA

**final result: passed** — native component rendering and view-level behavior.
Remove's live Lightroom keyboard shortcuts also pass; physical-device and
full picker desktop checks remain unverified, as detailed below.

## Comparison target and evidence

- Source visual: `../build/radial-render/reference-general-before-lightroom.png`,
  retained from the existing approved three-mode implementation before this change.
- Design specification: the approved Lightroom plan in this chat: four equal
  inner wedges, a nonselectable Lightroom parent on the left, and three 30°
  selectable outer segments. The children form a single navigation sequence
  with Scroll, Playback, and Zoom.
- Implementation: `../build/radial-render/images/scrolling.png`, `playback.png`,
  `zoom.png`, and `lightroom-{scrolling,playback,zoom,lightroomCrop,lightroomFineTune,lightroomBrush}.png`.
- Additional states: `opening.png`, `reduced-transparency-contrast.png`,
  `lightroom-opening.png`, and `lightroom-reduced-transparency-contrast.png`.
- Viewport/density: native AppKit, no CSS/browser viewport. The source and general
  states are 300×300 points exported at 600×600 pixels. Contextual states are
  432×432 points exported at 864×864 pixels, with the same 300-point inner wheel.
  All exports use 2× backing, including native SF Symbol rasterization.
- The retained source, final general state and all three Lightroom children were
  opened together in one comparison input. General geometry, typography, spacing
  and color were compared at identical point and pixel sizes. The new outer arc
  was assessed against the approved specification rather than claiming a pixel
  match to a nonexistent Lightroom reference mockup.
- Full-size exports make icons and all center text legible; separate crops were
  unnecessary. Opening and opaque/high-contrast states were also inspected.

## Final findings

No remaining actionable P0/P1/P2 visual differences against the approved design.

- **Typography:** native system font; the general wheel retains its original
  type hierarchy. Lightroom adds a small context label, 16-point mode name,
  action hints and a selection instruction within the same center circle.
  All visible text fits its bounds without truncation in automated checks.
- **Spacing/layout:** original 108-point general icon radius and three-sector
  positions are retained outside Lightroom. Contextual general wedges are at
  top/right/bottom; Lightroom is left, with Crop below-left, Fine Tune left,
  and Remove above-left. Icons sit inside their shared drawing/hit-test segments.
  The outer extension is 66 points, and unused outer space is transparent.
- **Colors:** dark material, brighter selected wedge, white icons and blue
  selection arc retain the established language. Selecting a Lightroom child
  adds a subdued blue tint to its parent. Opaque/high-contrast rendering
  strengthens boundaries without obscuring text or the app icon.
- **Assets:** real SF Symbols and the installed Lightroom Classic `App.icns`.
  Bundle identity is checked before using the app icon. Symbols render sharply
  at 2×; the preview does not recreate them as custom vector artwork.
- **Copy:** names and hints match the requested mappings. The Lightroom parent
  has no misleading selection or entry action. The bottom center instruction
  describes choosing a mode; action hints describe the selected mode's use.
- **Accessibility/input:** selectable icons are native radio-button controls;
  Lightroom children have an accessible group. Pointer targets are 50×50
  points. Native hit testing reaches all six controls, the parent does nothing,
  the opening hold disables both rings, and outside space cancels. Keyboard
  navigation, selection values, and opaque/high-contrast behavior are checked.

## Comparison history

1. Initial render: [P2] Lightroom appeared as a small generic app placeholder.
   Fixed by loading the verified installed bundle's icon resource directly,
   with running-app and Launch Services discovery plus the standard installed
   location as a fallback. Subsequent captures show the correct LrC icon.
2. General-wheel comparison: [P2] shared geometry moved icons outward by three
   points and introduced a brighter outer edge. Restored the 108-point icon
   radius and original general boundary drawing; clipped the contextual surface
   to its silhouette. Final general rendering matches the source layout.
3. Export comparison: SF Symbols initially rasterized at 1× while the bitmap
   exported at 2×, softening icons. This was a capture-density mismatch; the
   offscreen test window now explicitly reports 2× backing. Final captures show
   sharp symbols. This does not override production display scaling.
4. Final comparison: source and final general/Lightroom states opened together;
   no unresolved P0/P1/P2 visual findings. The intentional extra ring, app icon,
   contextual labels and four-sector layout follow the approved specification.
5. Remove rename: compared `../build/radial-render/reference-remove-before-rename.png`
   with the updated `lightroom-lightroomBrush.png` at the same 864×864 size.
   The title and hints now read Remove, Turn: Remove size, and Click: Remove (Q).
   Text fits cleanly; geometry, icon, colors and typography are unchanged.
   Pointer tooltips and accessibility help include the inactive-tool rating guidance.

## Verification

- Apple Silicon Release build and strict code-signature verification pass.
- **504 recording-only behavior checks pass:** existing press thresholds,
  cancellation and controllers; six-mode navigation and wrapping; identical
  selection sensitivity; app-mode persistence and relaunch; inactive-app
  rejection; stale reports and app-switch cancellation; exact key codes,
  balanced edges, explicit modifiers and verified target PIDs; the Q click mapping
  and legacy `lightroomBrush` preferences reopening as Remove.
- **364 native-view checks pass:** shared geometry, actual native hit targets,
  group exclusion, accessible labels/roles/values, text fit, native symbols,
  both layouts, opening states, pointer/keyboard handlers and display fallbacks;
  Remove's pointer tooltip and accessibility rating guidance.
- Tests use injected sinks and never post keyboard, mouse or media input to
  another app. CoreGraphics event creation stalled inside the shell sandbox;
  the same recording-only suite passed with host event access.
- Hardware-free preview builds and was launched through Launch Services.
  It simulates either profile, does not open HID, does not save preferences,
  does not request permissions and does not send desktop events.
- The earlier picker inspection was blocked by a locked desktop. The Remove
  update's live Lightroom keyboard check succeeded on a temporary virtual copy:
  Q opened Remove, ] changed Size from 14 to 15, [ restored 14, and Q closed it.
  Undo Create Virtual Copy then removed the test copy and restored the original
  photo selection. No removal strokes or rating changes were made. This checks
  Lightroom's shortcuts, not physical Dial input or the new app's live picker.

## Remaining manual checks

1. Quit the currently running Mac Dial before opening the new local build. With
   Lightroom Classic 15.6 focused, verify the six-item wheel and menu-bar submenu;
   keep general behavior on first use, choose a child, switch away and return,
   then relaunch to confirm saved choices.
2. On disposable photos/virtual copies, check Command+Left/Right with Crop open,
   R toggling Crop, unshifted +/= and minus changing the selected adjustment in
   small increments, backslash Before view, bracket sizing with Remove active,
   and repeated Q clicks toggling Remove. Check physical rotation feel at each sensitivity.
3. Verify native blur/shadow and keyboard-focus restoration after confirmation,
   Escape and outside click; test over full-screen Lightroom, across Spaces and
   near display edges. Actual multi-display presentation is still manual.
4. Check VoiceOver grouping, Reduce Motion, Haptics, disconnect/reconnect and
   sleep/wake, including app changes while the Dial is held.

The updated app is `../build/Build/Products/Release/MacDial.app`.
The earlier `../downloads/MacDial-lightroom-modes-arm64.app.zip` archive predates
this rename. Installation is separate; the installed copy was not replaced.
