#!/bin/bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
bash Tests/configuration.sh
test_build="build/controller-tests"
mkdir -p "$test_build/module-cache"
xcrun swiftc -module-cache-path "$test_build/module-cache" \
    MacDial/Controller.swift MacDial/DialButtonHandler.swift MacDial/Mode.swift MacDial/SliceConfiguration.swift MacDial/SliceConfigurationStore.swift MacDial/CustomSliceController.swift MacDial/DialReportDecoder.swift \
    MacDial/DialConfiguration.swift MacDial/ModePickerState.swift MacDial/DialInputCoordinator.swift \
    MacDial/RadialMenuLayout.swift MacDial/RadialMenuView.swift MacDial/PlaybackController.swift MacDial/BrightnessController.swift MacDial/SystemDisplayBrightness.swift \
    MacDial/ScrollController.swift MacDial/ZoomController.swift MacDial/UndoRedoController.swift MacDial/EditwallSequenceController.swift MacDial/LightroomController.swift MacDial/AppModeContext.swift Tests/DynamicSlices.swift Tests/main.swift \
    -o "$test_build/controller-tests"
"$test_build/controller-tests"
