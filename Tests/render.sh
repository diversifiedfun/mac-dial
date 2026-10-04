#!/bin/bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
render_build="../build/radial-render"
mkdir -p "$render_build/module-cache"
xcrun swiftc -target arm64-apple-macos12.0 -module-cache-path "$render_build/module-cache" \
    MacDial/Mode.swift MacDial/ModePickerState.swift MacDial/RadialMenuLayout.swift MacDial/RadialMenuView.swift \
    Tests/Render/main.swift -o "$render_build/render"
"$render_build/render" "$render_build/images"
