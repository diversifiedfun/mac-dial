# Mac Dial

macOS support for the Surface Dial. The surface dial can be paired with macOS but any input results in invalid mouse inputs on macOS. This app reads the raw data from the dial and translates them to correct mouse and media inputs for macOS.

## Building

Make sure to clone the hidapi submodule and build the library using the build_hidapi.sh script. Note: This app depends on a hidapi fork, check the submodule to see what changed. App should then build with XCode.

You can find universal builds of the app under "releases". Note that these builds can be outdated.

## Usage

The app will continously try to open any Surface Dial connected to the computer and then process input controls. You will need to pair and connect the device as any other bluetooth device.

The app currently supports three modes:
* Scroll mode: Turning the dial will result in scrolling. Pressing the dial is interpreteded as a mouse click at the current cursor position.
* Playback mode: Turning the dial controls the system volume of your mac. Pressing the dial plays / pauses any current playback while a double click sends the "next" media action.
* Zoom mode: Clockwise zooms in and counterclockwise zooms out in the focused app. A short press resets zoom. Uses Command+=, Command+-, and Command+0; the focused app must support those shortcuts. Zoom direction is independent of Scroll Direction.

To change mode, hold the Dial for 600 ms until a haptic blip, then release.
Each hold switches once: Scroll → Playback → Zoom → Scroll. Releasing after a
long press does not invoke the new mode's click action. Scroll mode releases its
pending mouse button before switching. You can also select a mode from the
Mac Dial menu-bar icon; Zoom uses a magnifying-glass icon. The selected mode is
remembered across launches.

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

The installed copy is `/Applications/MacDial.app`. A packaged copy is retained at
`../downloads/MacDial-longpress-zoom-arm64.app.zip`; the original upstream archive
and the previously working `MacDial-1.4-macOS27-arm64.app.zip` are retained beside
it. The local build is ad-hoc signed.

The long-press behavior and `Controller.onCancel()` follow
[PR #37](https://github.com/andreasjhkarlsson/mac-dial/pull/37), with cancellation
also applied on disconnect, manual mode selection, and quit. Other features from
that PR are not included. Run `bash Tests/run.sh` for hardware-independent checks
of press timing, cancellation, balanced mouse events, and zoom shortcuts. Tests
record generated events without posting them to the desktop.

After replacing the executable, macOS may require removing and re-adding Mac Dial
under Privacy & Security > Accessibility (labelled Device Control and Data Access
on this Mac), even if its existing switch is on. Select the installed copy in
Applications and restart it.

In this setup, Scroll Direction > Natural gives clockwise-down scrolling.
Launch at login is not configured. Volume and scrolling were verified on macOS
27.0.1 in the previous build after refreshing permission. Long-press cycling and
Zoom require a hardware check after installing this build; play/pause with active
audio and automatic sleep/wake remain untested.
