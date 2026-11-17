#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
RELAY_BUILD="$PWD/.build/safari-relay-checks.noindex"
mkdir -p "$RELAY_BUILD"
swiftc -swift-version 5 -emit-library -emit-module -module-name SlidesBridgeKit \
    Sources/SlidesBridgeKit/*.swift \
    -emit-module-path "$RELAY_BUILD/SlidesBridgeKit.swiftmodule" \
    -o "$RELAY_BUILD/libSlidesBridgeKit.dylib"
swiftc -swift-version 5 -parse-as-library \
    Sources/LocalPrompt/BrowserPresentationController.swift \
    Sources/LocalPrompt/SafariRelay.swift \
    Tests/Support/SlideDiagnosticsStub.swift \
    Tests/SafariRelayChecks/Checks.swift \
    -I "$RELAY_BUILD" -L "$RELAY_BUILD" -lSlidesBridgeKit \
    -Xlinker -rpath -Xlinker "$RELAY_BUILD" \
    -o "$RELAY_BUILD/checks"
"$RELAY_BUILD/checks"
