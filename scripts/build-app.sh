#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-install}"
if [[ $# -gt 1 || ( "$MODE" != "install" && "$MODE" != "--package" ) ]]; then
    echo "Usage: $0 [--package]" >&2
    exit 2
fi
BUILD_ARGS=(-c release)
if [[ "$MODE" == "--package" ]]; then
    # Keep distributable output independent of local development builds, omit
    # debug info, and remap source paths before they can enter the executable.
    BUILD_ARGS+=(--scratch-path "$PWD/.build/release-package.noindex"
        --triple arm64-apple-macosx26.0 --product LocalPrompt
        -debug-info-format none
        -Xswiftc -gnone
        -Xswiftc -file-prefix-map -Xswiftc "$PWD=/LocalPrompt"
        -Xswiftc -file-prefix-map -Xswiftc "$HOME=/User")
fi
swift build "${BUILD_ARGS[@]}"
BIN_PATH="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
BUILD_ROOT="$PWD/.build/app-bundles.noindex"
mkdir -p "$BUILD_ROOT"
STAGING_ROOT="$(mktemp -d "$BUILD_ROOT/stage.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT
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
if [[ "$MODE" == "--package" ]]; then
    strip -S -x "$APP/Contents/MacOS/LocalPrompt"
fi
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
if [[ "$MODE" == "--package" ]]; then
    # Verify the exact public payload before creating an archive. No user
    # preferences, development artifacts, or filesystem metadata are included.
    python3 - "$APP" "$PWD" <<'PY'
from pathlib import Path
import hashlib
import os
import plistlib
import re
import subprocess
import sys
import zipfile

app = Path(sys.argv[1])
project = Path(sys.argv[2])
binary = app / 'Contents/MacOS/LocalPrompt'
allowed = {
    'Contents/Info.plist',
    'Contents/MacOS/LocalPrompt',
    'Contents/Resources/LocalPrompt.icns',
    'Contents/_CodeSignature/CodeResources',
}
actual = {str(p.relative_to(app)) for p in app.rglob('*') if p.is_file()}
if actual != allowed or any(p.is_symlink() for p in app.rglob('*')):
    raise SystemExit('Unexpected files or links in release bundle')
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
if info['CFBundleIdentifier'] != 'com.biblejustin.localprompt' or info['LSMinimumSystemVersion'] != '26.0':
    raise SystemExit('Unexpected bundle identity or minimum macOS version')
arch = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).strip()
build = subprocess.check_output(['xcrun', 'vtool', '-show-build', str(binary)], text=True)
if arch != 'arm64' or not re.search(r'platform\s+MACOS\b', build) or not re.search(r'minos\s+26\.0\b', build):
    raise SystemExit('Release must be arm64 with a macOS 26.0 deployment target')
private_paths = [str(project).encode(), str(Path.home()).encode(), b'/Users/', b'/private/var/folders/', b'/var/folders/']
for relative in allowed:
    data = (app / relative).read_bytes()
    if any(path in data for path in private_paths):
        raise SystemExit(f'Private machine path found in {relative}')

version = info['CFBundleShortVersionString']
output = project / 'dist'
output.mkdir(exist_ok=True)
archive_name = f'LocalPrompt-{version}-macOS-arm64.zip'
staged_zip = app.parent / archive_name
subprocess.run([
    '/usr/bin/ditto', '-c', '-k', '--keepParent', '--norsrc',
    '--noextattr', '--noacl', str(app), str(staged_zip),
], check=True)
with zipfile.ZipFile(staged_zip) as archive:
    expected = {f'LocalPrompt.app/{name}' for name in allowed}
    files = {item.filename for item in archive.infolist() if not item.is_dir()}
    if files != expected or archive.testzip() is not None:
        raise SystemExit('Archive contents or integrity check failed')
    for name in expected:
        if archive.read(name) != (app.parent / name).read_bytes():
            raise SystemExit(f'Archive bytes differ for {name}')

extracted = app.parent / 'verify.noindex'
subprocess.run(['/usr/bin/ditto', '-x', '-k', str(staged_zip), str(extracted)], check=True)
restored = extracted / 'LocalPrompt.app'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(restored)], check=True)
if not os.access(restored / 'Contents/MacOS/LocalPrompt', os.X_OK):
    raise SystemExit('Archive lost executable permissions')
digest = hashlib.sha256(staged_zip.read_bytes()).hexdigest()
checksum = app.parent / 'SHA256SUMS.txt'
checksum.write_text(f'{digest}  {archive_name}\n')
staged_zip.replace(output / archive_name)
checksum.replace(output / 'SHA256SUMS.txt')
print(f'Release archive: {output / archive_name}')
print(f'SHA256: {digest}')
print('Verified: arm64, macOS 26.0+, ad-hoc signature, exact four-file payload, no private machine paths.')
print('Not Developer ID signed or notarized; macOS Gatekeeper may require user approval.')
PY
    exit 0
fi
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
