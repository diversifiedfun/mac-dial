# Source publication audit — 2026-10-06

Scope: the Diversified Fun fork based on `fed2b0a`, its reachable history, production
Swift code, build scripts, inherited assets, and the pinned macOS HIDAPI dependency.
This is a practical source and publication review, not an independent security
certification or a certification of all third-party rights.

## Findings and disposition

| Severity | Finding | Disposition |
| --- | --- | --- |
| High | HID string reads could decode uninitialized memory after a failed call; string/read buffers were not freed. | Zero-initialized bounded storage, checked return status, safe Unicode decoding, read-buffer cleanup; regression tests cover failed, unterminated, and invalid input. |
| Medium | Zoom posted globally, allowing an app switch to split a key pair or redirect a rotation batch. | Deliver both edges to the original PID; cancel subsequent steps after focus change or cancellation; regression tests added. |
| Medium | The HID thread's run flag was shared without synchronization and shutdown busy-spun. | Lock-protected flag and bounded sleeps while the read thread finishes. |
| Medium | Device serial numbers appeared in ordinary connection output. | Removed from logging; retained in memory and local connection status. HIDAPI's serial-printing sample is inside `#if 0`, not the compiled path. |
| Medium | The inherited Stack Overflow media helper lacked full attribution and its distinct license notice. | Identify author, source, modifications, CC BY-SA 4.0 scope and full license text; the repository no longer describes all code as MIT-only. |
| Medium | The documented build depended on a script outside the repository and generated files inside a dependency. | Self-contained scripts, pinned submodule and repository-local ignored build output. |
| Low | Personal upstream Xcode workspace state was tracked. | Removed from the current tree and ignored; already-public upstream history is preserved. |
| Low | README mixed local artifacts, old counts, and pending checks with installation instructions. | Separate user/contributor/privacy documentation and explicitly marked historical notes. |

No credentials were detected by Gitleaks 8.30.1 in the selected app history
(47 commits scanned by the tool) or the pinned HIDAPI history (452 commits scanned).
A separate inspection covered 51 reachable app commits and 275 unique historical
blobs before cleanup. Absolute home paths were found only in inherited Xcode
workspace state. David's existing business email and upstream contributor identities
remain in history intentionally. A scanner result is not proof that no secret exists.

## Runtime review

- Permission checks gate action routing; denial/revocation cancels pending input.
  HID discovery itself is not represented as a permission-closed device boundary.
- Custom, Lightroom, Undo/Redo, Editwall and now Zoom keyboard actions target the
  intended process and pair releases with presses. Queued work is cancelled on
  context changes; automated tests exercise these boundaries using recorded events.
- Shortcut recording is local to its focused sheet and removes monitors on finish
  or cancellation. App discovery reads bundle metadata; it does not inspect documents.
- Settings and recovery copies are local UserDefaults data. Brightness restore values
  are saved before dimming and retained after failed writes. See [Privacy](../PRIVACY.md).
- No production network client, telemetry, automatic updater or crash uploader was
  found in the reviewed Swift code or compiled macOS HIDAPI path. User-selected links
  open the system browser. This review did not instrument OS-level network traffic.
- DisplayServices is a private, optional API. Missing functions fail without stopping
  launch; support can change with macOS versions and display presets.

## Licensing and asset review

Original MIT notices and upstream history are retained. HIDAPI's BSD option is
selected and copied with notices. The inherited media helper retains its CC BY-SA
exception. The brightness reference's BSD notice is included. Surface Dial Linux
was checked as a protocol reference, not an imported Rust dependency; it has no
published license declaration. Bundled PNGs match upstream; SF Symbols and installed
app icons are obtained through system APIs. See [Third-party notices](../THIRD_PARTY_NOTICES.md).

## Verification

Environment: Apple Silicon, macOS 27.0.1, Xcode 27.0 (27A266a). Deployment target:
macOS 12. These are distinct: older runtimes and Intel are not verified here.

| Check | Result |
| --- | --- |
| Release build and strict ad-hoc signature verification | Passed |
| Configuration and independent-process persistence | 7,689 checks passed |
| Controller, geometry, routing and HID/Zoom regressions | 146,741 checks passed |
| Permission logic and native recovery guidance | 21 checks passed |
| Native customization | 491 checks passed |
| Native presentation and render export | 1,848 checks passed |
| Fresh recursive clone and build | Pending final publication check |
| Documentation links and current-tree secret scan | Pending final publication check |

Initial sandboxed native test attempts could not access preference/window services;
the suites passed when rerun with host service access. The build reports existing
HIDAPI `kIOMasterPortDefault` deprecation warnings. No signing identity or notarized
binary is provided by this source publication.

## Remaining manual verification

Physical Dial rotation/clicks/haptics, actual permission revocation/recovery,
Bluetooth disconnect/reconnect, sleep/wake, real app shortcuts, multi-display
brightness dim/restore, full-screen/Spaces interaction and older macOS runtimes
remain unverified for this publication. Use the [manual checklist](../CONTRIBUTING.md).
These limitations are disclosed for source publication; they must not be represented
as passed tests or a stable end-user release. The original bundle identifier and
settings format are unchanged, so upstream and this fork share a preferences domain.
