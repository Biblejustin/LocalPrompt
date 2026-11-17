#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
AUDIO_LEVEL_BUILD="$PWD/.build/audio-level-checks.noindex"
mkdir -p "$AUDIO_LEVEL_BUILD"
swiftc -swift-version 5 -parse-as-library \
    Sources/LocalPrompt/AudioLevel.swift \
    Tests/AudioLevelChecks/Checks.swift \
    -o "$AUDIO_LEVEL_BUILD/checks"
"$AUDIO_LEVEL_BUILD/checks"
