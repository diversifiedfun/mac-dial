#!/bin/bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
architecture="${1:-arm64}"
case "$architecture" in arm64|x86_64) ;; *) echo "Usage: bash build_hidapi.sh [arm64|x86_64]" >&2; exit 2 ;; esac
if [[ ! -f lib/hidapi/mac/hid.c ]]; then
    echo "Missing HIDAPI. Run: git submodule update --init --recursive" >&2
    exit 1
fi
output="build/hidapi/$architecture"
mkdir -p "$output"
xcrun clang -arch "$architecture" -mmacosx-version-min=12.0 -O2 \
    -I lib/hidapi/hidapi -c lib/hidapi/mac/hid.c -o "$output/hid.o"
xcrun libtool -static -o "$output/libhidapi.a" "$output/hid.o"
