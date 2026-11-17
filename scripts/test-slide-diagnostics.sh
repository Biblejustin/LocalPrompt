#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
DIAGNOSTICS_BUILD="$PWD/.build/slide-diagnostics-checks.noindex"
mkdir -p "$DIAGNOSTICS_BUILD"
swiftc -swift-version 5 -parse-as-library \
    Sources/LocalPrompt/SlideDiagnostics.swift \
    Tests/SlideDiagnosticsChecks/Checks.swift \
    -o "$DIAGNOSTICS_BUILD/checks"
"$DIAGNOSTICS_BUILD/checks"
