#!/bin/bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
configuration_build="build/configuration-tests"
mkdir -p "$configuration_build/module-cache"
configuration_build="$(cd "$configuration_build" && pwd -P)"
xcrun swiftc -target arm64-apple-macos12.0 -module-cache-path "$configuration_build/module-cache" \
    MacDial/Mode.swift MacDial/SliceConfiguration.swift MacDial/SliceConfigurationStore.swift \
    Tests/Configuration/main.swift -o "$configuration_build/configuration-tests"
"$configuration_build/configuration-tests"
