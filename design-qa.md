# Grouped Lightroom radial picker — design QA

## Extra window-shadow follow-up — October 5, 2026

**Implementation and native checks passed; exact desktop-outline verification pending.**

- Disabled the floating panel's additional window shadow while native Liquid Glass
  is active. The material still renders its own rim and soft elevation. Classic
  and the opaque accessibility fallback retain the normal window shadow.
- Material changes notify the controller, so switching appearance or Reduce
  Transparency while open updates shadow ownership immediately. The previous
  clipping fix, wheel geometry, selection arc and controls remain intact.
- Captured the production floating Lightroom Fine Tune preview in dark appearance:
  `../design/liquid-glass/qa/outline-after.png` (992×992). Compared with
  `clipping-after-fine-tune.png`; the glass edge and uncut left extension remain
  intact. Window-only captures do not reproduce the displaced black desktop
  outline from the user's reference, so they cannot conclusively establish its
  cause or removal. The redundant panel shadow is now demonstrably disabled.
- 1,295 native checks passed, including all appearance choices, live opaque
  fallback transitions and returning to glass, with normal and reduced motion.
  Release build and strict signature verification passed. Preview reconnection
  initially timed out; reopening the isolated preview restored capture access.
- Built app is ready locally; the installed application has not been replaced.

## Floating-window clipping follow-up — October 5, 2026

**final result: passed**

- [P2, resolved] The contextual shape reached x=0 in both the glass host and the
  floating window. Native effects extending beyond that contour were cut off at
  the left edge. Added 32 points of transparent space outside the glass effect,
  enlarged the host/window, and included that margin in screen-edge clamping.
- Kept the existing window shadow enabled. The black-outline/shadow styling is
  intentionally a separate follow-up; this change fixes the render boundary.
- Wheel geometry is unchanged: 300-point core, 144-point center, 432-point
  contextual coordinate area. Window sizes are now 364/496 points. A negative
  content bounds origin preserves wheel-space geometry; events and hit tests
  convert correctly between window, superview and wheel coordinates.
- User reference: `/var/folders/kp/2_0qdpjj3n52bfmd32ssshmh0000gn/T/codex-clipboard-9f973eb2-d753-4c1f-b5c9-cb0770b0d11c.png`.
- Native before/after: `../design/liquid-glass/qa/clipping-before.png` (864×864),
  `clipping-after.png` (992×992), and `clipping-after-fine-tune.png` (992×992).
  These use the production floating panel, not the earlier gallery window.
- Viewed the user reference and final Fine Tune capture together. Compare their
  600-pixel cores at identical 2× density; screenshot padding/background differs.
  The left outer curve and shadow now have 64 pixels of render space before the
  window edge. Inspected the leftmost arc and its top/bottom joins at full image
  resolution. No straight truncation at the window boundary remains.
- Fonts, labels, icon positions, selection arc, native material and center spacing
  match the prior implementation. Only the transparent render area grows.
- 1,433 behavior/geometry checks and 1,281 native view/presentation checks passed.
  Added all-corner placement checks on normal and negative-origin displays, native
  effect-envelope containment, unchanged center alignment, and margin cancellation.
  Synthetic pointer events and hit-test calls now explicitly convert coordinates.
- Release build and strict code-signature verification passed. A CUA keyboard
  attempt timed out; the preview was
  reopened directly in Fine Tune for verification. Automated keyboard/pointer and
  presentation checks passed. Native preview remains open in Fine Tune.



## Liquid Glass — October 5, 2026

**final result: passed**

Implemented the selected Quiet Glass concept using Apple's regular Liquid Glass
material, hosted in AppKit through a SwiftUI shape. The shape uses the production
outline, so native refraction follows the general circle and the Lightroom/Editwall
extensions. No custom glass tint or material-opacity override is applied. A
system-colored center backing improves instruction readability. Classic remains
available, and both renderers follow the effective light/dark appearance.

### Evidence and comparison

- Source visual truth: `../design/liquid-glass/selected-concept.png` (1487 × 1058).
- Final native screenshot: `../design/liquid-glass/qa/native-preview.png` (1840 × 1064).
- Implementation viewport: native 920 × 500 point content, 2× density; the screenshot
  additionally includes the 32-point title bar. No CSS/browser viewport applies.
- State: General → Scroll and Lightroom → Crop & Browse, armed, dark appearance.
- Source and implementation were opened together in the same comparison input.
  The mock's two examples have different illustrative scales; comparison used the
  existing 300-point core and 144-point center as the geometry truth. Native cores
  are each 600 pixels across. The contextual view keeps its 432-point bounds.
  Mock-page titles, wallpaper, and relative example sizes are presentation chrome,
  not app UI, and were excluded from fidelity judgments.
- Focused center-label, icon, selection-arc, and extension-boundary inspection was
  possible directly in the full-resolution images; no extra crops were necessary.
- Live captures also cover `light-busy.png`, `dark-busy-final.png`,
  `light-dark-final.png`, `dark-bright.png`, and `editwall-accessible.png` in that
  same QA directory. The patterned fixture deliberately stresses contrast.

### Findings and resolved iterations

1. [P2, resolved] Small instructions were too faint over the dark patterned fixture
   (`dark-busy.png`). Increased instruction foreground opacity and added a subtle
   28% system-background center backing. `dark-busy-final.png` verifies the fix.
2. [P2, resolved] Applying alpha to a semantic text color at initialization could
   retain dark-mode white instructions after moving to light appearance
   (`light-dark.png`). Resolve instruction colors under the view's effective
   appearance and refresh on changes. `light-dark-final.png` and a new automated
   light/dark color regression check verify the fix.
3. Expected native-material difference: rim brightness, translucency, tint from the
   backdrop, and refraction vary with macOS and its settings. The generated white
   rim and blue-gray tone are not hardcoded. This preserves the user's requirement
   that macOS control the material. No actionable P0/P1/P2 differences remain.

### Required fidelity surfaces

- Typography: retained native system fonts, weights and sizes; all mode labels and
  instruction text fit, with no wrapping/truncation. Light/dark foregrounds verified.
- Spacing/layout: original geometry, center, icons, hit areas, wedges and app arcs
  are unchanged. Native glass contours align with the outer outline without seams
  or rectangular clipping artifacts.
- Colors/tokens: semantic foreground/background colors, system-blue selection arc,
  regular untinted glass; opaque and strengthened-boundary accessibility variants.
- Assets: original SF Symbols and installed application icons remain crisp. No
  generated image is used as an interactive wheel or a fake glass texture.
- Copy/content: original mode labels, contextual actions and confirmation copy
  preserved. Appearance submenu uses Automatic, Liquid Glass, Classic.

### Validation

- 1,367 behavior checks passed: preferences, fallback resolution, gestures,
  contextual routing, geometry, recorded input, and hardware-command scheduling.
- 1,272 native view/presentation checks passed: three appearance choices, all
  profiles, light/dark, reduced transparency, increased contrast, color changes,
  hit testing, labels, keyboard/pointer routing, and confirmation timing.
- Live keyboard selection, rapid Right/Right/Return confirmation, and pointer
  selection of Lightroom Fine Tune verified through the accessibility tree.
- Release build and strict code-signature verification passed with macOS 12 target.
  Existing HID deprecation warnings remain. Native presentation checks require
  display access; the initial sandbox-only failure reported zero screens and
  passed outside that sandbox without changing the presentation implementation.
- Physical Surface Dial interaction and execution on pre-26 macOS were not tested
  during this change. Fallback resolution is covered with simulated unsupported
  availability, and the old-runtime deployment target still builds.
- The user's system Glass slider and accessibility preferences were not changed.
  Display fixtures inject appearance/accessibility states locally. Live global
  slider adjustment remains a manual check; native material ownership is retained.

### Implementation checklist

- [x] Persisted appearance submenu, default Automatic, gated Liquid Glass item.
- [x] Native custom-contour glass and Classic fallback with system appearance.
- [x] Immediate semantic selection with cancellable 100 ms visual crossfade.
- [x] Existing confirmation behavior, reduced motion and opaque contrast fallback.
- [x] Native visual comparison, regression checks, release build, preview left open.



## Selection confirmation — October 5, 2026

- Implemented the approved 300 ms confirmation: system-blue selected segment,
  white icon, mode name, checkmark and “Selected”; other choices fade over 100 ms.
  The panel fades during the final 100 ms, while mode input resumes immediately.
- Confirmation renderings for every mode in the general, Lightroom and Editwall
  layouts are under `../build/radial-render/images/*-confirmed.png`, with
  `*-confirmed-accessible.png` covering opaque and increased-contrast settings.
  General Zoom and Lightroom Crop & Browse confirmations were visually inspected.
- 1,355 behavior checks and 972 view/presentation checks pass. Presentation checks
  use the production controller with a deterministic scheduler and cover 100/200/
  250/300 ms states, Reduce Motion, duplicate selection, focus/pointer release,
  interrupted opening, reopening during fade, and lifecycle dismissal.
- Selection now commits on the next press after the opening hold is released.
  Keeping that press held cannot cancel, reopen, or trigger an action in the new
  mode. Escape, outside click and timeout remain cancellation paths.
- Follow-up latency fix: the previous ordering waited for the HID pulse before
  displaying confirmation, which preserved the animation but delayed its start.
  Haptic and sensitivity-exit writes now use a separate serial queue; the pulse
  is queued before the sensitivity reset. Input-generation and connection-status
  queries use lightweight snapshots instead of waiting for hardware locks.
- Integrated tests hold hardware jobs pending while the production picker commits
  on press and runs its complete animation; both normal and reduced motion pass.
  Worker tests verify pulse ordering, stale restores after reopening, suppression
  of queued pulses on cancellation/reconnect/haptics disable, and nonblocking UI
  queries during an in-flight write. Physical timing still needs device validation.
- The hardware-free desktop preview opened correctly; Return selected the mode
  and dismissed its window. The transient 300 ms sequence was too short for the
  desktop capture to retain; timing is verified by the presentation checks and
  appearance by native renders. Physical Dial pulse/feel and VoiceOver announcement
  playback remain unverified. The Release build and strict signature check pass.

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
