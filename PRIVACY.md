# Privacy

This describes the production source reviewed for the Diversified Fun source
publication. It is a source review, not a guarantee about every future version or
operating-system service.

## Device and application access

Mac Dial reads Surface Dial HID reports and sends scroll, media, brightness, or
keyboard events. Accessibility/event-posting permission is necessary for these
actions. The app is not sandboxed; granting access permits control of other apps.

Foreground application identifiers select contextual actions. The application picker
reads bundle names, identifiers, paths and icons from running apps and standard
application folders (plus an app you explicitly choose). It does not inspect
application documents or browser content.

Shortcut recording uses a local key-down monitor while the recorder is focused.
It consumes the selected shortcut and stops on completion, cancellation, or app
deactivation. It is not a global keyboard recorder. While the radial picker is open, local and
global mouse-down monitors dismiss it on outside clicks; they are removed when
the picker closes.

## Local storage and logs

Preferences use the existing `com.andreasjhkarlsson.MacDial` UserDefaults domain:
mode and appearance settings, named slices, key codes and modifiers, application
bundle identifiers/names/paths, and per-display identifiers with saved brightness
restore values. Invalid configuration data may be retained under recovery keys.
The Dial serial number is kept in memory for connection status and shown in the
local menu; it is no longer printed in normal connection logs.

Ordinary connection/failure messages can appear in local process output. The
reviewed production Swift code and compiled macOS HIDAPI path contain no network
client, analytics, crash uploader, or automatic updater. About links open GitHub
in your browser when selected; the browser and macOS have their own behavior.

## Removing data

Removing an application group in Customize Dial removes that group's saved settings
but can be undone in the current editing session. To erase all preferences, first
restore any displays dimmed by Mac Dial, quit every copy, and then run:

```sh
defaults delete com.andreasjhkarlsson.MacDial
```

This also removes recovery copies and brightness restore values and affects upstream
Mac Dial because the bundle identifier is shared. Remove the app from Login Items
and revoke its privacy permission in System Settings separately if desired.
Do not include preference exports, serial numbers, private paths, or unrelated
application content in public issues.
