# Radial picker design QA

**final result: passed** — native component visual comparison and view checks.
Live desktop integration and remaining physical Dial validation are listed below.

## Evidence and comparison target

- Source visual: `/var/folders/kp/2_0qdpjj3n52bfmd32ssshmh0000gn/T/codex-clipboard-ea182b6b-f309-4326-a47f-3b7e374e410f.png`.
- Retained source: `../build/radial-render/reference-windows.png`.
- Implementation: `../build/radial-render/images/scrolling.png`, `playback.png`,
  `zoom.png`, `opening.png`, and `reduced-transparency-contrast.png`.
- Viewport: native AppKit component, 300×300 points; exports are 600×600 pixels
  at 2× density. There is no browser/CSS viewport.
- Source: 422×384 pixels, with an approximately 382-pixel wheel. The approved
  adaptation deliberately changes the Windows layout to three equal sectors,
  native SF Symbols, macOS typography/material, and selection instructions.
  Comparison uses proportions within the circular component rather than an
  exact pixel match to Windows. Export density is interpreted at 2×; no
  resampled screenshot or desktop screenshot is claimed.
- The source and all three selected implementation states were opened together
  in one comparison input. The opening state was also inspected. The entire
  component and its small text are readable in these exports, so separate
  focused crops were unnecessary.

## Findings

No actionable P0/P1/P2 visual differences against the approved adaptation.

- **Typography:** native system font; selected mode has a clear size hierarchy.
  Playback and both instruction lines fit inside the center without truncation
  or collisions. The opening state explains that release arms selection.
- **Layout:** equal sectors retain fixed positions (Scroll top, Playback lower
  right, Zoom lower left). Icons are centered within their sectors. Center,
  ring, and blue selection arc remain aligned in all three states.
- **Colors:** dark surface, brighter highlighted wedge, white symbols, and blue
  arc preserve the reference's visual selection language. The opaque fallback
  and stronger boundaries were rendered and inspected. Desktop-dependent blur
  and the external window shadow cannot be verified by offscreen exports.
- **Assets:** actual native SF Symbols render sharply at 2×. The system's valid
  Zoom symbol is `plus.magnifyingglass`; the proposed inverse spelling was
  corrected when the symbol-availability test caught it. No raster or drawn
  icon substitutes are used.
- **Copy:** labels match the existing three modes. Instructions match the
  hold → release → turn → click interaction. Cancellation preserves the
  saved mode; no Windows-only mode is carried into the wheel.

## Comparison history

The first rendered comparison passed without a visual repair iteration. The
invalid Zoom symbol was caught and fixed by automated checks before rendering.

## Verification

- Apple Silicon Release build and strict code-signature verification pass.
- 108 recording-only checks pass: gesture boundaries, delayed timers and queued
  HID timestamps, duplicate edges, confirmation-report suppression, every
  shared cancellation path, stale callbacks, idle timeout, mode persistence
  mapping, sensitivity normalization, screen-edge placement (including displays
  with negative coordinates), symbol availability, and real controller events.
- 44 native view checks pass: accessible radio-button roles, names and selected
  values; enabled/disabled opening states; opaque fallback; arrow/Return/Escape
  handlers; and pointer selection for every wedge.
- No test posts mouse, keyboard, or media input to another application.
- The user confirmed physical long-press opening, mode selection/menu-bar
  updates, and haptics. Scrolling, volume, and zoom were blocked by a stale
  Accessibility grant. The permission entry was replaced with the exact new
  build and that build was restarted; system actions have not yet been
  confirmed after the refresh.

## Remaining manual checks

The native computer-use inspector returned `timeoutReached` both for the preview
app path and its bundle ID. A hardware-free preview app opened successfully,
but live screenshot and interaction verification through that inspector was
unavailable. Offscreen exports are not a substitute for the following checks:

1. Quit the installed Mac Dial before launching the new local build; verify
   hold, release, both turn directions, confirmation, cancellation, and haptics
   using the physical Surface Dial at each sensitivity.
2. Check keyboard focus returns to the original app after selection/Escape,
   an outside click reaches its intended app, and switching apps dismisses.
3. Check real placement near all screen edges, on multiple displays, and over
   full-screen apps; verify Space/display changes dismiss the picker.
4. Check actual translucent blur/shadow, Reduce Motion, and VoiceOver navigation.
5. Check disconnect/reconnect and sleep/wake while a gesture or picker is active.

The installed app was not replaced. The preview never connects to HID or saves
mode preferences; its idle timeout is disabled only for inspection.
