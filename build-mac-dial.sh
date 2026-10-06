#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$project_root"
# Source publication verifies Apple Silicon. No signing account is required.
bash build_hidapi.sh arm64
xcodebuild -project MacDial.xcodeproj -scheme MacDial \
    -configuration Release -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$project_root/build" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES MACOSX_DEPLOYMENT_TARGET=12.0 build
codesign --verify --deep --strict "$project_root/build/Build/Products/Release/MacDial.app"
