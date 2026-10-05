# Mac Dial

macOS support for the Surface Dial. The surface dial can be paired with macOS but any input results in invalid mouse inputs on macOS. This app reads the raw data from the dial and translates them to correct mouse and media inputs for macOS.

## Building

Make sure to clone the hidapi submodule and build the library using the build_hidapi.sh script. Note: This app depends on a hidapi fork, check the submodule to see what changed. App should then build with XCode.

You can find universal builds of the app under "releases". Note that these builds can be outdated.

## Usage

The app will continously try to open any Surface Dial connected to the computer and then process input controls. You will need to pair and connect the device as any other bluetooth device.

The app supports five general modes, plus contextual Lightroom Classic and Editwall modes:
* Scroll mode: Turn to scroll. Short-click to cycle Stepped / Freestyle / Precision; pressing immediately stops ongoing motion. Hold to open the mode picker. Scroll no longer sends mouse clicks.
* Playback mode: Turning the dial controls the system volume of your mac. Pressing the dial plays / pauses any current playback while a double click sends the "next" media action.
* Brightness mode: Clockwise brightens and counterclockwise dims, using the Mac's brightness keys with Shift+Option for fine steps. Click saves the brightness of the screen under the pointer and sets it to zero; click again on that screen to restore its level. Hold opens the picker. Scroll Direction does not reverse brightness. Works with displays that respond to macOS brightness keys; direct external-monitor DDC control is not included.
* Zoom mode: Clockwise zooms in and counterclockwise zooms out in the focused app. A short press resets zoom. Uses Command+=, Command+-, and Command+0; the focused app must support those shortcuts. Zoom direction is independent of Scroll Direction.
* Undo/Redo mode: Counterclockwise undoes and clockwise redoes one step per reported tick in the focused app. Single-click to undo once; double-click to redo once. Holding opens the mode picker. Uses Command+Z and Shift+Command+Z, so the focused app must support those shortcuts. Wheel Sensitivity controls the ticks per revolution; Scroll Direction does not reverse history actions. There is no acceleration or app-specific shortcut remapping.


Brightness clicks target the screen under the pointer, with a separate saved
level for each physical display. Move the pointer back onto a dimmed screen and
click to restore it. Saved levels survive mode changes, reconnects, sleep, and app
restarts, even if brightness was adjusted in between. Clicks never fall back to
a different screen. If a native write fails or its readback does not match, the
saved level is kept for a retry; an unavailable operation beeps. At zero without a saved level, clicking
leaves brightness unchanged. Rotation still uses macOS brightness keys. The
click toggle requires the optionally loaded macOS DisplayServices API; it does
not use a black overlay or turn the display off.

**Photography display preset:** On the built-in Liquid Retina XDR display,
the user observed that **Photography (P3-D65)** prevents direct brightness
changes, including the click-to-zero/restore toggle, while brightness-key
events still work. This explains why dial rotation can work when clicking does
not: rotation sends brightness-key events, while clicks use DisplayServices to
set an exact value. In this configuration the API reported success without
changing brightness, and its readback stayed at 100% even for requests to set
0%, 25%, or 50%. This is a display-preset limitation observed on this Mac, not
a general inability to control the laptop display. If you need the click
toggle, choose a display preset that permits brightness adjustment. Mac Dial
does not change the display preset automatically.

Single-click Undo waits for the macOS double-click interval. A second short
press begun within that interval sends only one Redo, with no preliminary Undo.
A second hold cancels the waiting click and opens the picker. Rotation remains
immediate and cancels any waiting click; changing modes or apps, disconnecting,
and other input cancellations also discard it. These click timings apply to Undo/Redo and Editwall Sequence modes. Picker confirmation still uses one immediate short click.

Undo/Redo sends complete key-down/key-up pairs to the foreground process. If
focus changes during a rotation batch, the started pair finishes in the original
app and the remaining steps stop. No history action is sent when opening,
cancelling, or confirming the picker.

### Scroll styles

**Stepped** is the default and preserves immediate, accelerated scroll jumps.
**Freestyle** keeps one- and two-tick adjustments precise, then builds speed
more quickly as you continue turning. It connects ticks up to 220 ms apart, so
moderate turns at Medium sensitivity accelerate instead of continually resetting
to the slow speed. Its ceiling remains 144 pixels per tick, with up to 1.2 seconds
of coast for long pages.
**Precision** moves a slow, isolated tick just **2 pixels**, spread uniformly over
approximately 80 ms in one-pixel increments. Repeated faster turns gradually
increase the distance per tick, up to 96 pixels, rather than accelerating abruptly
on the second tick. Tiny adjustments have no extra coast; inertia requires
sustained faster input and eases to rest over about 600 ms.

Press to stop or reverse to discard the glide. The pointer remains free to move
throughout either animated style’s glide; inertia never restores an old position.
After sustained turning, deceleration begins as soon as the final tick’s
movement finishes. The handoff to momentum events continues that same glide,
without waiting motionless for the gesture timeout or restarting at a higher speed.
The glide starts at the outgoing scroll speed, brakes gently at first, and tapers
to zero smoothly rather than using a steep exponential drop or a hard cutoff.

Wheel Sensitivity determines the physical turn needed for a report: Low = 20°,
Medium = 10°, High = 5°, and Extreme = 1°. Higher sensitivity detects smaller
turns and produces more ticks per revolution. The app cannot respond to movement
between hardware reports, but each report can produce small pixel increments.
Existing sensitivity preferences are preserved.

Rotation reports are decoded as signed 16-bit tick counts, including reports
that contain multiple ticks during fast turns. Acceleration and fine-adjustment
thresholds count actual ticks rather than assuming one tick per report. This
prevents dropped or reversed movement at high speed, especially at Extreme.

Short-click in Scroll to cycle **Stepped → Freestyle → Precision → Stepped**, or use **Scroll Style → Stepped / Freestyle / Precision**
in the menu bar. The choice is remembered globally across apps and restarts.
Existing Smooth and Freewheel selections become Precision and Freestyle;
Stepped is used when no valid selection has been saved.
The menu checkmark and tooltip show the selected style; toggling gives a pulse
only when Haptics is enabled, with no on-screen notification. Scroll remains a
single radial-menu choice, and confirming it does not toggle the style.

Pressing, changing style/direction/sensitivity, opening the picker, changing
apps or modes, disconnecting, sleeping, and ending the session cancel motion.
Delayed timer callbacks discard movement instead of producing a catch-up jump.
Precision and Freestyle send pixel scroll and momentum phases, but the exact feel depends on
the receiving app; Stepped remains available for compatibility. Wheel Sensitivity
and Haptics retain their existing hardware behavior.

### Radial mode picker

Hold the Dial for **600 ms** by default, release, turn to highlight a mode, then
click to select it. Choose **Menu Press Duration** in the menu bar, beside Wheel
Sensitivity, to use **200, 300, 400, 500, or 600 ms**. The choice is saved across
launches and controls the hold that opens the picker. Once the picker is armed,
the next press selects immediately, regardless of how long it is held.
A 300-point native macOS wheel opens at the pointer and stays within
that display's visible area. Five equal wedges place Scroll at the top, followed clockwise by Playback,
Zoom, Undo/Redo, and Brightness. The center names the
highlighted mode and shows picker navigation instructions.

Choose **Radial Menu Starts At**, immediately below Menu Press Duration in the
menu bar, to control the opening highlight:

- **Last Selected** (default) opens on the active mode for the current app.
- **First Item** always highlights the first selectable item, currently Scroll,
  so you can navigate by touch from a predictable starting point.

With First Item, **hold → release → turn → click**: no rotation highlights
Scroll, one clockwise tick highlights Playback, two highlight Zoom, and three
highlight Undo/Redo. Four ticks highlight Brightness. Click to confirm. Opening, browsing, and cancelling leave
the active mode unchanged. Each opening starts from the first item again, even
after confirming another mode. Enable Haptics to feel each selection step.

This preference is saved across launches and applies to the general,
Lightroom, and Editwall menus. It takes effect on the next opening, without moving an already
open menu's highlight. First Item follows the selectable menu order if that
order changes in a future version; it does not override saved app-specific modes.

The opening hold only opens the picker; releasing it arms selection. The current
mode continues to be the saved mode until the next press confirms immediately.
Holding that confirming press cannot cancel or reopen the picker; its repeated
reports and eventual release are consumed. Clockwise advances Scroll → Playback → Zoom → Undo/Redo → Brightness, wrapping in either
direction. Each rotation tick advances exactly one choice, with one automatic
haptic click when Haptics is enabled. Wheel Sensitivity controls menu spacing:

| Wheel Sensitivity | Menu degrees per choice | Normal ticks per revolution |
| --- | ---: | ---: |
| Low | 30° | 18 |
| Medium | 20° | 36 |
| High | 15° | 72 |
| Extreme | 10° | 360 |

Menu spacing does not depend on the number of choices. The Dial temporarily uses
12, 18, 24, or 36 ticks per revolution while the picker is open, then restores the
latest normal sensitivity on every exit. Saved preferences are not overwritten.
Scroll Direction does not reverse menu navigation.

You can also hover and click a segment, use the arrow keys, and press Return.
Confirming applies the mode immediately and shows a 300 ms visual acknowledgement:
the chosen segment turns blue, other icons and dividers fade over 100 ms, and the
center shows the mode name with a checkmark and **Selected**. The menu holds until
200 ms, then fades out over 100 ms. Reduce Motion shows the same confirmation
without animation before dismissing at 300 ms. Keyboard focus and pointer input
are released immediately, and the next Dial rotation operates the selected mode.
Reselecting the current mode gives the same confirmation. Assistive technology
receives a mode-selection announcement.
Haptic and sensitivity-restoration writes run on a separate serial queue, so the
visual countdown starts immediately and keeps drawing even if the device is slow.
The confirmation pulse is sent before the sensitivity reset. Queued ticks from
menu sensitivity are discarded until normal sensitivity has been restored.

Escape, an outside click, or 10 seconds without interaction
cancels without changing modes. Disconnecting, changing apps/Spaces/displays,
sleeping, selecting a mode from the menu bar, or quitting also cancels safely.
Opening, selection, and confirmation feedback follows the Haptics setting.
Rotating uses the hardware click without a duplicate software pulse; keyboard
and pointer browsing retain their feedback. A direct click confirms with one
pulse rather than adding a separate press-highlight pulse. Cancellation never
shows selection confirmation or emits a confirmation pulse. If menu configuration fails, the
picker cancels and attempts to restore normal sensitivity. Queued rotation from
an earlier configuration is ignored while valid button releases are preserved.

Scroll clicks now wait until a short press is released. This prevents a long
press from clicking or dragging anything underneath the wheel. Menu gestures
never send scroll, playback, zoom, history, or brightness actions; a confirmation report's rotation
is also consumed. You can still select modes from the menu bar, and the chosen
mode is remembered across launches using the existing preference values.

The wheel uses SF Symbols, native glass, and a blue selection arc. Choose
**Radial Menu Appearance** beside **Radial Menu Starts At** in the menu bar:

- **Automatic** (default): native Liquid Glass on macOS 26 or later; Classic on older macOS.
- **Liquid Glass**: explicitly use native glass. This option is disabled on older macOS;
  a saved Liquid Glass preference still falls back safely if used there.
- **Classic**: the traditional frosted material.

Appearance is saved independently of the selected Dial mode. Both renderers follow
system light/dark appearance. Liquid Glass uses Apple's regular material without a
custom tint or opacity override, allowing macOS to control its optical appearance.
A subtle system-colored center backing protects instruction readability. Native
SwiftUI glass is hosted behind the existing AppKit controls, using the same outline
as the wheel and its app extensions. Shapes, targets, and navigation are unchanged.
A 32-point transparent render margin surrounds the wheel inside both the glass
host and floating window. This prevents the left app arc's native rim/shadow from
being clipped. Screen-edge placement includes the margin; the visible wheel stays
the same size and centered on the pointer when space allows.
When native glass is active, the floating panel's additional window shadow is
disabled so only the material supplies elevation. Classic and Reduce Transparency
retain the normal panel shadow, including when settings change while open.
Build with the macOS 26 SDK or later; the packaged app retains macOS 12 compatibility.

Its native controls expose mode labels and selected state to accessibility.
Reduce Transparency uses an opaque surface; Increase Contrast strengthens
boundaries; Reduce Motion disables the opening fade and the 100 ms selection
crossfade. Selection updates immediately, and confirmation cancels any crossfade.
Accessibility setting changes are applied while the wheel is open.

For repeatable native material checks, build `Tests/preview.sh --build-only`, then
launch the preview executable with `--gallery --appearance light --backdrop busy`.
The gallery shows the production general and contextual views on a shared background.
Use `--appearance dark`, `--backdrop bright|dark|busy`, `--profile editwall`,
`--style automatic|liquidGlass|classic`, `--reduce-transparency`, `--increase-contrast`,
or `--reduce-motion` to inspect variations without changing system or app preferences.
Use `--backdrop-image /path/to/image` to inspect glass over a local wallpaper.
Without `--gallery`, the preview exercises the production picker/controller and its
status menu. Use `--mode lightroomFineTune` with `--profile lightroom` to reproduce
the left-arc clipping regression state. Offscreen rendering checks layout and controls; use the live preview
to inspect the compositor-rendered glass. Display/presentation tests need a macOS
session with access to a screen (a restricted sandbox can report zero displays).

### Editwall modes

When **Edit Wall is the foreground app** (`com.editwall.desktop`), choose
**Editwall → Sequence** in the menu bar or select Sequence on the radial picker's
Editwall outer arc. Open the Sequence view in Editwall before using this mapping.

| Sequence gesture | Shortcut | Action |
| --- | --- | --- |
| Rotate left (counterclockwise) | Up arrow | Previous candidate |
| Rotate right (clockwise) | Down arrow | Next candidate |
| Single click | Right arrow | Next sequence slot |
| Double click | Left arrow | Previous sequence slot |

Each rotation tick sends one unmodified arrow key. Scroll Direction does not
reverse these actions. Single clicks wait for the macOS double-click interval;
a double click sends only Left, with no preliminary Right. Holding opens the
picker. A second hold, rotation, focus change, disconnect, or mode change cancels
any waiting click. Picker confirmation does not navigate the sequence.

Editwall remembers its last selected mode under `appMode.com.editwall.desktop`,
independently of the general and Lightroom choices. On first use, select Sequence
explicitly. This mapping sends shortcuts; it does not switch Editwall's view or
inspect its active text field. Physical Dial behavior in Editwall still needs a
live check.

### Lightroom Classic modes

When **Lightroom Classic is the foreground app**, the wheel shows six equal
inner wedges: Scroll (top), then Playback, Zoom, Undo/Redo, Brightness, and Lightroom clockwise.
Three selectable icons equally divide the Lightroom wedge's outer arc, which is
66 points thick. The inner wheel remains 300 points; the contextual shape uses a 432×432 coordinate
area. Including its transparent effect margin, the floating window is 496×496
points (364×364 for the general wheel).
Lightroom’s installed app icon identifies its parent wedge, which is a visual
group rather than another selection target.

Turning still follows one continuous sequence, with no extra click to enter a
submenu: **Scroll → Playback → Zoom → Undo/Redo → Brightness → Crop & Browse → Fine Tune → Remove**.
The sensitivity-dependent selection step, hold/release gesture, cancellation,
keyboard navigation, and Haptics setting are the same in both layouts.
The center shows the highlighted Lightroom mode’s turn and click actions.

| Lightroom mode | Clockwise | Counterclockwise | Short click |
| --- | --- | --- | --- |
| Crop & Browse | Next image: Command+Right | Previous image: Command+Left | R — Crop |
| Fine Tune | Increase selected adjustment: +/= | Decrease selected adjustment: − | Backslash — Before view |
| Remove | Larger Remove size: ] | Smaller Remove size: [ | Q — Toggle Remove |

Each reported rotation step sends one balanced key pair. Wheel Sensitivity
controls the number of steps per revolution; Scroll Direction does not reverse
Lightroom actions. Fine Tune sends the unshifted U.S. +/= key and minus key for
small increments, without adding Shift for coarse increments.

Selecting a mode only changes the Dial mapping. A subsequent short click in
Remove mode sends Q to toggle Lightroom's Remove tool. Fine Tune acts on the
selected adjustment. These modes do not detect the active tool or inspect text
fields; selecting a mode does not change Lightroom modules.

**Activate Remove before turning. With Remove inactive, turning may change photo star ratings.**
This guidance also appears in Remove's pointer tooltips and accessibility help.

On first use in Lightroom, the current general mode stays active until you
explicitly select a mode. Later visits restore the last choice made in Lightroom,
including a general mode if you selected one there. Leaving Lightroom restores
your separately saved general mode. Both choices survive relaunches. Existing
`mode` values (`scroll`, `playback`, `zoom`) remain compatible; Brightness uses `brightness`; Undo/Redo uses
`undoRedo`. The Lightroom choice is stored under
`appMode.com.adobe.LightroomClassicCC7`. Remove retains
the existing `lightroomBrush` preference value, so saved selections remain compatible.

The menu bar also exposes a contextual Lightroom submenu and reflects the
current effective mode in its icon and tooltip. Switching foreground apps
cancels any active picker/press and discards queued input from the old context.
Each Lightroom shortcut rechecks the foreground app, then sends both key edges
to that Lightroom process so its release cannot spill into another application.

Initial support targets **Lightroom Classic** (`com.adobe.LightroomClassicCC7`)
and the U.S. keyboard layout. Cloud Lightroom is not included. Merely keeping Lightroom open in the background does not enable its
modes. Outside supported apps the five-mode general wheel returns.

If you want to app to run at startup you will need to add it yourself to the "login items" for your user.

## Improvements

* More input modes
* ~~Change input mode using the dial itself~~
* ~~Smarter device discovery (currently tries to open the dial every 50 ms)~~

## Local macOS compatibility build

This checkout is based on `releases/1.4`. The local changes use the system menu bar,
restore the saved scroll direction at launch, dispatch controller callbacks to the
main thread, and generate pixel-based scroll events. The menu also reports missing
Accessibility permission and uses a template icon with a Mac Dial tooltip.

Run `bash ../build-mac-dial.sh` from this checkout to build an Apple Silicon app
using the installed Xcode tools. The script builds the pinned HID fork directly;
CMake is not required. The local deployment target is macOS 12 or later.
The resulting app is in `../build/Build/Products/Release/MacDial.app`.

The installed copy is `/Applications/MacDial.app`; building does not replace it.
The build with configurable press duration is packaged at
`../downloads/MacDial-press-duration-arm64.app.zip`. Earlier archives are retained.
The local build is ad-hoc signed.

Before a physical Dial check, quit the installed Mac Dial copy, then open
`../build/Build/Products/Release/MacDial.app`. Avoid running both copies at once,
because both try to read the same Dial. After replacing an executable, macOS may
require removing and re-adding it under Privacy & Security > Accessibility
(labelled Device Control and Data Access on this Mac).

### Verification and preview

- `bash Tests/run.sh` runs hardware-independent checks of all five press durations
  (including queued HID timestamps and changes during a hold), both radial menu
  starting positions, short clicks, menu routing, cancellation, selection
  normalization, preference compatibility, multi-display placement, and actual
  controller events recorded without posting input to the desktop.
- `bash Tests/render.sh` checks the native view's accessibility and input handlers,
  confirmation timing, input release, Reduce Motion, and interrupted/reopened menus,
  and exports all general, Lightroom, and Editwall selections, opening states, and
  opaque/high-contrast fallbacks under `../build/radial-render/images/`.
  General exports are 600×600 pixels and contextual exports are 864×864 at 2×.
  The renderer explicitly uses 2× backing so SF Symbols remain sharp even when
  the desktop is locked or a Retina screen is unavailable.
- `bash Tests/preview.sh` builds and opens **Mac Dial Preview**, a separate
  hardware-free app using the production picker and gesture router. Its menu-bar
  item previews the general, Lightroom, or Editwall layout and every selection.
  It opens initially on Crop & Browse. It never opens the HID device, posts system input,
  requests permissions, or changes saved modes. Only this inspection preview
  disables the idle timeout; the real app retains the 10-second timeout.
  Add `--build-only` to compile the preview without opening it.

The selection-confirmation Release build, strict code-signature verification,
1,355 recording-only behavior checks, and 972 native-view/presentation checks pass.
The controller checks require access to native macOS services;
in a restricted execution sandbox they can stall, so run them with that access.
Automated checks cover the four menu sensitivity mappings, configuration failure
recovery, restoration after dismissal, haptic suppression, queued rotation, all eight
modes, app-specific persistence, stale-report rejection, app-switch cancellation,
exact keyboard events and modifiers, group hit testing, accessible controls,
text fit, nonoverlapping pointer targets, and placement on displays with negative
coordinates. Starting-position checks cover both policies from every available
mode, zero through three counted ticks, reopening after confirmation, cancellation,
preference persistence and invalid-value fallback, changes while open, and both
rotation directions at every sensitivity in the general and Lightroom menus.
Undo/Redo checks also cover exact per-tick shortcuts, delayed single-click
undo, exclusive double-click redo, click-and-hold cancellation, focus changes during
a batch or click delay, menu gesture suppression, and both general
and Lightroom persistence. Physical Dial input and live Undo/Redo shortcuts remain
unverified; test rotation and clicking on a disposable document.

Live Lightroom shortcut checks on a temporary virtual copy confirmed Q opens
and closes Remove, ] increases its size from 14 to 15, and [ restores it to 14.
The temporary copy was removed with Undo Create Virtual Copy afterward.
These checks used keyboard input; physical Dial input remains unverified.

Physical Dial validation and live focus/Space behavior remain unverified for
this build. With First Item selected, confirm the picker starts on Scroll after
choosing other general or Lightroom modes, and that one and two clockwise clicks
highlight Playback and Zoom without looking. At each Wheel Sensitivity, verify one felt click per menu selection
in both directions, wraparound, Lightroom group transitions, and normal sensitivity
after dismissal. On Lightroom Classic 15.6, check next/previous navigation with Crop
open, fine adjustment step size, Before view, Remove size and Q toggling Remove,
then leave and return to Lightroom to check mode restoration. Use disposable
photos or virtual copies for that check. Also check the wheel over full-screen
Lightroom, near display edges, and after disconnect/reconnect or sleep/wake.
See `design-qa.md` for the visual evidence and remaining checks. Installation is
a separate step; building and packaging do not replace `/Applications/MacDial.app`.

In this setup, Scroll Direction > Natural gives clockwise-down scrolling.
Launch at login is not configured.
