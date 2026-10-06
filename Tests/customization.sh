#!/bin/bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
custom_build="build/customization-preview"
custom_app="$custom_build/Mac Dial Customization Preview.app"
mkdir -p "$custom_app/Contents/MacOS" "$custom_build/module-cache"
xcrun swiftc -target arm64-apple-macos12.0 -module-cache-path "$custom_build/module-cache" \
    MacDial/Mode.swift MacDial/SliceConfiguration.swift MacDial/SliceConfigurationStore.swift \
    MacDial/DialButtonHandler.swift MacDial/ModePickerState.swift MacDial/RadialMenuLayout.swift MacDial/RadialMenuView.swift \
    MacDial/DialCustomizationSession.swift MacDial/CustomizationControls.swift MacDial/DialCustomizationWindow.swift \
    Tests/Customization/main.swift -o "$custom_app/Contents/MacOS/CustomizationPreview"
cat > "$custom_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.macdial.customization-preview</string>
<key>CFBundleName</key><string>Mac Dial Customization Preview</string>
<key>CFBundleExecutable</key><string>CustomizationPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$custom_app"
if [[ "${1:-}" != "--build-only" ]]; then
    "$custom_app/Contents/MacOS/CustomizationPreview" "$@"
fi
