#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)"
BUILD_ROOT="$PWD/.build/app-bundles.noindex"
mkdir -p "$BUILD_ROOT"
STAGING_ROOT="$(mktemp -d "$BUILD_ROOT/stage.XXXXXX")"
APP="$STAGING_ROOT/LocalPrompt.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/LocalPrompt" "$APP/Contents/MacOS/LocalPrompt"
swift scripts/CreateIcon.swift .build/LocalPrompt.iconset
iconutil -c icns .build/LocalPrompt.iconset -o "$APP/Contents/Resources/LocalPrompt.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>LocalPrompt</string>
<key>CFBundleDisplayName</key><string>LocalPrompt</string>
<key>CFBundleExecutable</key><string>LocalPrompt</string>
<key>CFBundleIconFile</key><string>LocalPrompt</string>
<key>CFBundleIdentifier</key><string>com.biblejustin.localprompt</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>LocalPrompt uses your microphone to follow your place in the script. Speech is processed on this Mac.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
# Publish one user-facing app. Stage complete bundles so updates never overwrite
# a running executable. Recovery copies stay outside Spotlight indexing.
python3 - "$APP" "$PWD" <<'PY'
from pathlib import Path
import plistlib
import subprocess
import sys
import uuid

staged = Path(sys.argv[1])
project = Path(sys.argv[2])
target = Path.home() / 'Applications' / 'LocalPrompt.app'
target.parent.mkdir(exist_ok=True)
archive = project / '.build' / 'previous-apps.noindex'
archive.mkdir(exist_ok=True)
previous = None
if target.exists():
    version = plistlib.loads((target / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
    previous = archive / f'LocalPrompt-{version}-{uuid.uuid4().hex[:8]}.app'
    target.rename(previous)
try:
    staged.rename(target)
except Exception:
    if previous is not None:
        previous.rename(target)
    raise
if previous is not None:
    # Finder can track a moved bundle by file identity; retire its registration.
    registration = subprocess.run([
        '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister',
        '-u', str(previous),
    ], capture_output=True, text=True)
    diagnostic = registration.stdout + registration.stderr
    # -10814 means the archived app is already absent from the registry.
    if registration.returncode and '-10814' not in diagnostic:
        print(f'Could not retire archived app registration: {diagnostic}', file=sys.stderr)
print(target)
PY
rmdir "$STAGING_ROOT"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -f "$HOME/Applications/LocalPrompt.app"
