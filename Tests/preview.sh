#!/bin/bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
preview_build="build/radial-preview"
preview_app="$preview_build/Mac Dial Preview.app"
mkdir -p "$preview_app/Contents/MacOS" "$preview_build/module-cache"
xcrun swiftc -target arm64-apple-macos12.0 -module-cache-path "$preview_build/module-cache" \
    MacDial/Mode.swift MacDial/SliceConfiguration.swift MacDial/DialButtonHandler.swift MacDial/ModePickerState.swift \
    MacDial/DialInputCoordinator.swift MacDial/RadialMenuLayout.swift MacDial/RadialMenuView.swift \
    MacDial/RadialMenuController.swift Tests/Preview/main.swift \
    -o "$preview_app/Contents/MacOS/MacDialPreview"
cat > "$preview_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.macdial.radial-preview</string>
<key>CFBundleName</key><string>Mac Dial Preview</string>
<key>CFBundleExecutable</key><string>MacDialPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>12.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$preview_app"
if [[ "${1:-}" != "--build-only" ]]; then
    open -g "$preview_app"
fi
