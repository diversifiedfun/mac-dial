#!/bin/bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
permission_build="build/permission-preview"
permission_app="$permission_build/Mac Dial Permission Preview.app"
mkdir -p "$permission_app/Contents/MacOS" "$permission_build/module-cache"
xcrun swiftc -target arm64-apple-macos12.0 -module-cache-path "$permission_build/module-cache" \
    MacDial/DialPermissions.swift Tests/Permissions/main.swift \
    -o "$permission_app/Contents/MacOS/PermissionPreview"
cat > "$permission_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.macdial.permission-preview</string>
<key>CFBundleName</key><string>Mac Dial Permission Preview</string>
<key>CFBundleExecutable</key><string>PermissionPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$permission_app"
"$permission_app/Contents/MacOS/PermissionPreview" "$@"
