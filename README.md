# Mac Dial

macOS support for the Surface Dial. The surface dial can be paired with macOS but any input results in invalid mouse inputs on macOS. This app reads the raw data from the dial and translates them to correct mouse and media inputs for macOS.

## Building

Make sure to clone the hidapi submodule and build the library using the build_hidapi.sh script. Note: This app depends on a hidapi fork, check the submodule to see what changed. App should then build with XCode.

You can find universal builds of the app under "releases". Note that these builds can be outdated.

## Usage

The app will continously try to open any Surface Dial connected to the computer and then process input controls. You will need to pair and connect the device as any other bluetooth device.

The app currently supports three modes:
* Scroll mode: Turning the dial will result in scrolling. A short press clicks at the current cursor position when released. Press-and-hold dragging is not supported.
* Playback mode: Turning the dial controls the system volume of your mac. Pressing the dial plays / pauses any current playback while a double click sends the "next" media action.
* Zoom mode: Clockwise zooms in and counterclockwise zooms out in the focused app. A short press resets zoom. Uses Command+=, Command+-, and Command+0; the focused app must support those shortcuts. Zoom direction is independent of Scroll Direction.

### Radial mode picker

Hold the Dial for **600 ms**, release, turn to highlight a mode, then click to
select it. A 300-point native macOS wheel opens at the pointer and stays within
that display's visible area. Scroll is at the top, Playback at the lower right,
and Zoom at the lower left. The center names the highlighted mode.

The opening hold only opens the picker; releasing it arms selection. The current
mode continues to be the saved mode until a subsequent short press confirms on
release. Clockwise advances Scroll → Playback → Zoom, wrapping in either
direction. Approximately 30° advances one choice at any Wheel Sensitivity;
Scroll Direction does not reverse menu navigation.

You can also hover and click a segment, use the arrow keys, and press Return.
Escape, another long hold, an outside click, or 10 seconds without interaction
cancels without changing modes. Disconnecting, changing apps/Spaces/displays,
sleeping, selecting a mode from the menu bar, or quitting also cancels safely.
Opening, selection, and confirmation feedback follows the Haptics setting.

Scroll clicks now wait until a short press is released. This prevents a long
press from clicking or dragging anything underneath the wheel. Menu gestures
never send scroll, playback, or zoom actions; a confirmation report's rotation
is also consumed. You can still select modes from the menu bar, and the chosen
mode is remembered across launches using the existing preference values.

The wheel uses SF Symbols, a dark translucent material, and a blue selection
arc. Its native controls expose mode labels and selected state to accessibility.
Reduce Transparency uses an opaque surface; Increase Contrast strengthens
boundaries; Reduce Motion disables the opening fade.

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
The radial-picker build is packaged at
`../downloads/MacDial-radial-menu-arm64.app.zip`. Earlier archives are retained.
The local build is ad-hoc signed.

Before a physical Dial check, quit the installed Mac Dial copy, then open
`../build/Build/Products/Release/MacDial.app`. Avoid running both copies at once,
because both try to read the same Dial. After replacing an executable, macOS may
require removing and re-adding it under Privacy & Security > Accessibility
(labelled Device Control and Data Access on this Mac).

### Verification and preview

- `bash Tests/run.sh` runs hardware-independent checks of press timing (including
  queued HID timestamps), short clicks, menu routing, cancellation, selection
  normalization, preference compatibility, multi-display placement, and actual
  controller events recorded without posting input to the desktop.
- `bash Tests/render.sh` checks the native view's accessibility and input handlers
  and exports 600×600 images of all three selections, the opening state, and
  the opaque/high-contrast fallback under `../build/radial-render/images/`.
- `bash Tests/preview.sh` builds and opens **Mac Dial Preview**, a separate
  hardware-free app using the production picker and gesture router. Its menu-bar
  item reopens any mode. It never opens the HID device, posts system input,
  requests permissions, or changes saved modes. Only this inspection preview
  disables the idle timeout; the real app retains the 10-second timeout.

The local build, recorded-event tests, and offscreen native-view checks pass.
On the physical Dial, long-press opening, mode selection/menu-bar updates, and
haptics were confirmed. System actions were blocked by a stale Accessibility
grant; the exact new build was re-added and restarted. Scrolling, volume, and
zoom still need a follow-up check after that permission refresh.
The native UI inspection service timed out, so live keyboard-focus restoration,
full-screen/Space transitions, and actual multi-display presentation remain
manual checks. Physical rotation feel, haptics, and disconnect/sleep recovery
also need broader validation with the Surface Dial. See `design-qa.md` for visual evidence
and the remaining runtime checks. Installation is a separate step.

In this setup, Scroll Direction > Natural gives clockwise-down scrolling.
Launch at login is not configured.
