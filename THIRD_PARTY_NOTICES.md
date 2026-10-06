# Third-party notices

## Mac Dial and inherited assets — MIT

Original project: [andreasjhkarlsson/mac-dial](https://github.com/andreasjhkarlsson/mac-dial).
Copyright (c) 2021 Andreas Karlsson. The original [MIT license](LICENSE) is retained.
Upstream contributors remain credited in Git history. The bundled app, playback,
and scroll PNG assets are unchanged from that upstream repository and are covered
by its repository license; no new third-party bitmap assets were added here.

Fork maintained and extended by David — Diversified Fun. Main-project changes
are provided under the same MIT terms, except for the explicitly identified helper below.

## HIDAPI — BSD 3-Clause option

Pinned source: [Andreas Karlsson's HIDAPI fork](https://github.com/andreasjhkarlsson/hidapi/tree/04386ec07fb4cbab8e879950adca18a5e53af87d),
commit `04386ec07fb4cbab8e879950adca18a5e53af87d`.
Copyright (c) 2010 Alan Ott, Signal 11 Software.

HIDAPI offers GPLv3, BSD-style, or its original license at the user's option.
This fork selects the [BSD 3-Clause option](docs/licenses/HIDAPI-BSD-3-Clause.txt).
Original notices remain in the pinned submodule. Its monitoring extensions are
required by Mac Dial. Retain these notices in any later binary distribution.

## Media-key event helper — CC BY-SA 4.0 exception

`HIDPostAuxKey` in `MacDial/PlaybackController.swift` is adapted from the
[Stack Overflow answer by “the quantity”, April 25, 2019](https://stackoverflow.com/a/55854051)
([author profile](https://stackoverflow.com/users/4108950/the-quantity)).
The answer identifies its license as **Creative Commons Attribution-ShareAlike 4.0 International**.

The helper was inherited from upstream. Adaptations include explicit modifiers,
Int32 key constants, and repeated down/up event pairs. This function and its
adaptations are distributed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/),
not solely under the repository's MIT license. Preserve attribution, indicate
changes, and apply the license's ShareAlike terms to adaptations. The
[full license text](docs/licenses/CC-BY-SA-4.0.txt) is included. No endorsement is implied.
The attribution also identifies the helper present in the retained upstream history.

## DisplayServices API reference — BSD 2-Clause

`MacDial/SystemDisplayBrightness.swift` references function signatures documented
by [Nicholas Riley's brightness project](https://github.com/nriley/brightness/blob/master/brightness.c).
Copyright (c) 2014–2019 Nicholas Riley. Its [BSD 2-Clause notice](docs/licenses/brightness-BSD-2-Clause.txt)
is included. The command-line brightness program is not bundled; the Swift wrapper
loads macOS's optional DisplayServices framework at runtime.

## Surface Dial protocol reference

[Daniel Prilik's surface-dial-linux](https://github.com/daniel5151/surface-dial-linux/blob/main/src/dial_device/haptics.rs)
is acknowledged as an interoperability reference for report IDs, field positions,
and haptic values. Its Rust implementation is not bundled or linked. No license
file or package license declaration was found in that reference repository during
the audit, so it must not be treated as a reusable code dependency. The reviewed
Swift implementation uses the required device protocol values; its locking,
configuration lifecycle, and event handling are maintained in this repository.

## System-provided symbols, icons, and frameworks

SF Symbols are requested by name through AppKit/SwiftUI, not redistributed as font
or image files. Application icons are read from installed application bundles for
local contextual UI. Apple frameworks and installed application artwork are not
included in this source distribution. Their respective owners retain their rights.
Microsoft Surface Dial, macOS, Lightroom, and other product names identify
compatibility; this fork does not imply endorsement by their owners.
