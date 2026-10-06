# Contributing

The maintained branch is `diversifiedfun`. Keep changes focused and include
reproduction steps and relevant verification with pull requests to this fork.
Do not include generated apps, build output, personal Xcode state, signing material,
application preferences, or logs containing private information.

## Development tooling

Development used OpenAI Codex with GPT-6 Astra at High and Extra High reasoning
effort. Codex assisted with implementation, debugging, automated verification,
and documentation under David's product direction and hands-on hardware testing.
These settings document the development workflow; they are not required to build
or contribute to the project.

## Build

Clone recursively and run `bash build-mac-dial.sh` from the repository root.
The documented build targets Apple Silicon, macOS 12, using Xcode 27. Build output
is local to `build/`. The pinned HIDAPI fork adds device monitoring; replacing it
with stock HIDAPI is not a compatible dependency update.

For Xcode editing, first run `bash build_hidapi.sh arm64`, then open the project.
The helper also accepts `x86_64` to compile that library for development, but no
Intel app or universal build is verified or published by this workflow.

## Automated verification

Run in a logged-in macOS desktop session with native window and preference-service
access. Restricted sandboxes may prevent these native checks from completing.
The controllers use recording-only event sinks, temporary preferences, or fake
hardware; the suites do not intentionally post shortcuts to your desktop or open HID.

```sh
bash Tests/run.sh            # includes configuration and controller/geometry checks
bash Tests/permissions.sh    # injected permission checks and native guidance
bash Tests/customization.sh  # settings, persistence, recorder, and Undo/Redo
bash Tests/render.sh         # native presentation checks and exported images
```

Render output is under `build/radial-render/images/`. These checks exercise state
transitions, not the physical Dial, actual privacy grants, or target applications.
See [the audit](docs/PUBLICATION_AUDIT.md) for the last recorded results.

## Isolated previews

```sh
bash Tests/preview.sh --build-only
bash Tests/customization.sh --build-only
```

The radial preview is `build/radial-preview/Mac Dial Preview.app`; open it manually
or omit `--build-only` to open it. For the customization preview, run:

```sh
"build/customization-preview/Mac Dial Customization Preview.app/Contents/MacOS/CustomizationPreview" --preview
```

Customization preview supports `--light`, `--dark`, `--dense`, and `--empty`.
It uses temporary preferences and removes them on normal exit. Previews do not
open the Dial or deliver system shortcuts.

## Manual acceptance checks

Use disposable documents or photo copies and one running Mac Dial copy. Verify:

- Pairing, rotation, clicks, holding, haptics, reconnects, and sleep/wake.
- Permission denial/revocation pauses actions; restoring permission resumes without stale input.
- App switching during clicks and rotations does not send remaining shortcuts to another app.
- Custom shortcuts, shortcut-recording cancellation, empty configurations, and all 18 visible slices.
- Brightness dim/restore on each display, unavailable APIs/presets, and relaunch with a saved restore value.
- Full-screen apps, Spaces, display edges, Reduce Motion, and Reduce Transparency.

Record the OS, architecture, app version, and actual outcome. Never convert an
untested case into a pass based only on the automated suite.

## Licensing and releases

Keep original notices. New contributions to the main project use MIT; changes to
the specifically attributed media-key helper retain CC BY-SA 4.0. Consult
[Third-party notices](THIRD_PARTY_NOTICES.md) before importing other code or assets.

This is a source-only publication. Signed/notarized binaries, application identity
changes and migrations, release versions, and automated update delivery are separate
work. Historical implementation and design notes are in `docs/history/` and do not
represent current verification evidence.
