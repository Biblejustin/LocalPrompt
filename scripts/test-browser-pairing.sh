#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PAIRING_BUILD="$PWD/.build/browser-pairing-checks.noindex"
mkdir -p "$PAIRING_BUILD"
swiftc -swift-version 5 -emit-library -emit-module -module-name SlidesBridgeKit \
    Sources/SlidesBridgeKit/*.swift \
    -emit-module-path "$PAIRING_BUILD/SlidesBridgeKit.swiftmodule" \
    -o "$PAIRING_BUILD/libSlidesBridgeKit.dylib"
swiftc -swift-version 5 -parse-as-library \
    Sources/LocalPrompt/BrowserPresentationController.swift \
    Tests/Support/SlideDiagnosticsStub.swift \
    Tests/BrowserPairingChecks/Checks.swift \
    -I "$PAIRING_BUILD" -L "$PAIRING_BUILD" -lSlidesBridgeKit \
    -Xlinker -rpath -Xlinker "$PAIRING_BUILD" \
    -o "$PAIRING_BUILD/checks"
"$PAIRING_BUILD/checks"
