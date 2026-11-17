#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
MANUAL_SYNC_BUILD="$PWD/.build/manual-slide-sync-checks.noindex"
mkdir -p "$MANUAL_SYNC_BUILD"
swiftc -swift-version 5 -emit-library -emit-module -module-name PromptCore \
    Sources/PromptCore/*.swift \
    -emit-module-path "$MANUAL_SYNC_BUILD/PromptCore.swiftmodule" \
    -o "$MANUAL_SYNC_BUILD/libPromptCore.dylib"
swiftc -swift-version 5 -parse-as-library \
    Sources/LocalPrompt/AppModel.swift \
    Tests/Support/SlideDiagnosticsStub.swift \
    Tests/ManualSlideSyncChecks/Stubs.swift \
    Tests/ManualSlideSyncChecks/Checks.swift \
    -I "$MANUAL_SYNC_BUILD" -L "$MANUAL_SYNC_BUILD" -lPromptCore \
    -Xlinker -rpath -Xlinker "$MANUAL_SYNC_BUILD" \
    -o "$MANUAL_SYNC_BUILD/checks"
"$MANUAL_SYNC_BUILD/checks"
