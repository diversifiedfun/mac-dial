# Mac Dial

macOS support for the Surface Dial. The surface dial can be paired with macOS but any input results in invalid mouse inputs on macOS. This app reads the raw data from the dial and translates them to correct mouse and media inputs for macOS.

## Building

Make sure to clone the hidapi submodule and build the library using the build_hidapi.sh script. Note: This app depends on a hidapi fork, check the submodule to see what changed. App should then build with XCode.

You can find universal builds of the app under "releases". Note that these builds can be outdated.

## Usage

The app will continously try to open any Surface Dial connected to the computer and then process input controls. You will need to pair and connect the device as any other bluetooth device.

The app supports three general modes, plus contextual Lightroom Classic modes:
* Scroll mode: Turning the dial will result in scrolling. A short press clicks at the current cursor position when released. Press-and-hold dragging is not supported.
* Playback mode: Turning the dial controls the system volume of your mac. Pressing the dial plays / pauses any current playback while a double click sends the "next" media action.
* Zoom mode: Clockwise zooms in and counterclockwise zooms out in the focused app. A short press resets zoom. Uses Command+=, Command+-, and Command+0; the focused app must support those shortcuts. Zoom direction is independent of Scroll Direction.

### Radial mode picker

Hold the Dial for **600 ms** by default, release, turn to highlight a mode, then
click to select it. Choose **Menu Press Duration** in the menu bar, beside Wheel
Sensitivity, to use **200, 300, 400, 500, or 600 ms**. The choice is saved across
launches and applies to the next press, including a second hold to cancel the
picker. A 300-point native macOS wheel opens at the pointer and stays within
that display's visible area. Scroll is at the top, Playback at the lower right,
and Zoom at the lower left. The center names the highlighted mode.

The opening hold only opens the picker; releasing it arms selection. The current
mode continues to be the saved mode until a subsequent short press confirms on
release. Clockwise advances Scroll → Playback → Zoom, wrapping in either
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
Escape, another long hold, an outside click, or 10 seconds without interaction
cancels without changing modes. Disconnecting, changing apps/Spaces/displays,
sleeping, selecting a mode from the menu bar, or quitting also cancels safely.
Opening, selection, and confirmation feedback follows the Haptics setting.
Rotating uses the hardware click without a duplicate software pulse; keyboard
and pointer selection retain their feedback. If menu configuration fails, the
picker cancels and attempts to restore normal sensitivity. Queued rotation from
an earlier configuration is ignored while valid button releases are preserved.

Scroll clicks now wait until a short press is released. This prevents a long
press from clicking or dragging anything underneath the wheel. Menu gestures
never send scroll, playback, or zoom actions; a confirmation report's rotation
is also consumed. You can still select modes from the menu bar, and the chosen
mode is remembered across launches using the existing preference values.

The wheel uses SF Symbols, a dark translucent material, and a blue selection
arc. Its native controls expose mode labels and selected state to accessibility.
Reduce Transparency uses an opaque surface; Increase Contrast strengthens
boundaries; Reduce Motion disables the opening fade.

### Lightroom Classic modes

When **Lightroom Classic is the foreground app**, the wheel shows four equal
inner wedges: Scroll (top), Playback (right), Zoom (bottom), and Lightroom (left).
Three selectable icons extend outward from the Lightroom quarter in a 66-point
outer arc. The inner wheel remains 300 points; contextual bounds are 432×432.
Lightroom’s installed app icon identifies its parent wedge, which is a visual
group rather than another selection target.

Turning still follows one continuous sequence, with no extra click to enter a
submenu: **Scroll → Playback → Zoom → Crop & Browse → Fine Tune → Remove**.
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
`mode` values (`scroll`, `playback`, `zoom`) remain compatible; the Lightroom
choice is stored under `appMode.com.adobe.LightroomClassicCC7`. Remove retains
the existing `lightroomBrush` preference value, so saved selections remain compatible.

The menu bar also exposes a contextual Lightroom submenu and reflects the
current effective mode in its icon and tooltip. Switching foreground apps
cancels any active picker/press and discards queued input from the old context.
Each Lightroom shortcut rechecks the foreground app, then sends both key edges
to that Lightroom process so its release cannot spill into another application.

Initial support targets **Lightroom Classic** (`com.adobe.LightroomClassicCC7`)
and the U.S. keyboard layout. Cloud Lightroom and other app profiles are not
included. Merely keeping Lightroom open in the background does not enable its
modes. Outside Lightroom the original three-mode wheel returns.

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
  (including queued HID timestamps and changes during a hold), short clicks, menu routing, cancellation, selection
  normalization, preference compatibility, multi-display placement, and actual
  controller events recorded without posting input to the desktop.
- `bash Tests/render.sh` checks the native view's accessibility and input handlers
  and exports all general and Lightroom selections, opening states, and
  opaque/high-contrast fallbacks under `../build/radial-render/images/`.
  General exports are 600×600 pixels and Lightroom exports are 864×864 at 2×.
  The renderer explicitly uses 2× backing so SF Symbols remain sharp even when
  the desktop is locked or a Retina screen is unavailable.
- `bash Tests/preview.sh` builds and opens **Mac Dial Preview**, a separate
  hardware-free app using the production picker and gesture router. Its menu-bar
  item previews either the general or Lightroom layout and every selection.
  It opens initially on Crop & Browse. It never opens the HID device, posts system input,
  requests permissions, or changes saved modes. Only this inspection preview
  disables the idle timeout; the real app retains the 10-second timeout.
  Add `--build-only` to compile the preview without opening it.

The Remove-mode Release build, strict code-signature verification,
504 recording-only behavior checks, and 364 native-view checks pass.
The controller checks require access to native macOS services;
in a restricted execution sandbox they can stall, so run them with that access.
Automated checks cover the four menu sensitivity mappings, configuration failure
recovery, restoration after dismissal, haptic suppression, queued rotation, all six
modes, app-specific persistence, stale-report rejection, app-switch cancellation,
exact keyboard events and modifiers, group hit testing, accessible controls,
text fit, and placement on displays with negative coordinates.

Live Lightroom shortcut checks on a temporary virtual copy confirmed Q opens
and closes Remove, ] increases its size from 14 to 15, and [ restores it to 14.
The temporary copy was removed with Undo Create Virtual Copy afterward.
These checks used keyboard input; physical Dial input remains unverified.

Physical Dial validation and live focus/Space behavior remain unverified for
this build. At each Wheel Sensitivity, verify one felt click per menu selection
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
