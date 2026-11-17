#!/bin/bash
# Builds the sandboxed Mac App Store edition of LocalPrompt.
#
#   TEAM_ID=ABCDE12345 PROVISIONING_PROFILE=~/Downloads/LocalPrompt_MAS.provisionprofile \
#       SAFARI_PROVISIONING_PROFILE=~/Downloads/LocalPrompt_Safari_MAS.provisionprofile \
#       ./scripts/build-appstore.sh            # signed .pkg in dist/, ready for Transporter
#   ./scripts/build-appstore.sh --local-test   # ad-hoc signed, sandboxed copy to run on this Mac
#
# Optional: APP_SIGN_IDENTITY (default "Apple Distribution") and
# INSTALLER_SIGN_IDENTITY (default "3rd Party Mac Developer Installer").
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-store}"
if [[ $# -gt 1 || ( "$MODE" != "store" && "$MODE" != "--local-test" ) ]]; then
    echo "Usage: $0 [--local-test]" >&2
    exit 2
fi

if [[ "$MODE" == "store" ]]; then
    : "${TEAM_ID:?Set TEAM_ID to your 10-character Apple Developer Team ID}"
    : "${PROVISIONING_PROFILE:?Set PROVISIONING_PROFILE to the Mac App Store provisioning profile for com.biblejustin.localprompt}"
    [[ -f "$PROVISIONING_PROFILE" ]] || { echo "No provisioning profile at $PROVISIONING_PROFILE" >&2; exit 1; }
    : "${SAFARI_PROVISIONING_PROFILE:?Set SAFARI_PROVISIONING_PROFILE to the Mac App Store provisioning profile for com.biblejustin.localprompt.safari}"
    [[ -f "$SAFARI_PROVISIONING_PROFILE" ]] || { echo "No provisioning profile at $SAFARI_PROVISIONING_PROFILE" >&2; exit 1; }
    APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:-Apple Distribution}"
    INSTALLER_SIGN_IDENTITY="${INSTALLER_SIGN_IDENTITY:-3rd Party Mac Developer Installer}"
else
    # Any well-formed team prefix works for an ad-hoc local run.
    TEAM_ID="${TEAM_ID:-LOCALTEST0}"
    APP_SIGN_IDENTITY="-"
fi
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || { echo "TEAM_ID must be 10 letters or digits" >&2; exit 1; }

# One version source: the direct-download build script.
VERSION="$(sed -n 's:.*<key>CFBundleShortVersionString</key><string>\([^<]*\)</string>.*:\1:p' scripts/build-app.sh)"
BUILD_NUMBER="$(sed -n 's:.*<key>CFBundleVersion</key><string>\([^<]*\)</string>.*:\1:p' scripts/build-app.sh)"
[[ -n "$VERSION" && -n "$BUILD_NUMBER" ]] || { echo "Could not read the version from scripts/build-app.sh" >&2; exit 1; }

BUILD_ARGS=(-c release
    --scratch-path "$PWD/.build/appstore.noindex"
    --triple arm64-apple-macosx26.0
    -debug-info-format none
    -Xswiftc -gnone
    -Xswiftc -file-prefix-map -Xswiftc "$PWD=/LocalPrompt"
    -Xswiftc -file-prefix-map -Xswiftc "$HOME=/User")
swift build "${BUILD_ARGS[@]}"
BIN_PATH="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

OUT_ROOT="$PWD/.build/appstore-out.noindex"
rm -rf "$OUT_ROOT"
mkdir -p "$OUT_ROOT"
APP="$OUT_ROOT/LocalPrompt.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/BraveExtension"
cp "$BIN_PATH/LocalPrompt" "$BIN_PATH/LocalPromptSlidesHost" "$APP/Contents/MacOS/"
for file in manifest.json protocol.js native-port.js content.js service-worker.js popup.html popup.js popup.css; do
    cp "BrowserExtension/$file" "$APP/Contents/Resources/BraveExtension/$file"
done
cp AppStore/PrivacyInfo.xcprivacy "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
swift scripts/CreateIcon.swift .build/LocalPrompt.iconset
iconutil -c icns .build/LocalPrompt.iconset -o "$APP/Contents/Resources/LocalPrompt.icns"

# App Store Connect reads these to confirm the SDK and toolchain.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
SDK_BUILD="$(xcrun --sdk macosx --show-sdk-build-version)"
XCODE_VERSION="$(xcodebuild -version | awk '/^Xcode/ {print $2}')"
XCODE_BUILD="$(xcodebuild -version | awk '/^Build version/ {print $3}')"
DT_XCODE="$(echo "$XCODE_VERSION" | awk -F. '{printf "%d%d%d", $1, $2, ($3 == "" ? 0 : $3)}')"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>LocalPrompt</string>
<key>CFBundleDisplayName</key><string>LocalPrompt</string>
<key>CFBundleExecutable</key><string>LocalPrompt</string>
<key>CFBundleIconFile</key><string>LocalPrompt</string>
<key>CFBundleIdentifier</key><string>com.biblejustin.localprompt</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>ITSAppUsesNonExemptEncryption</key><false/>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>LocalPrompt uses your microphone to follow your place in the script. Speech is processed on this Mac.</string>
<key>NSAppleEventsUsageDescription</key><string>LocalPrompt can optionally advance your PowerPoint slideshow when you finish reading a slide cue.</string>
<key>DTPlatformName</key><string>macosx</string>
<key>DTPlatformVersion</key><string>$SDK_VERSION</string>
<key>DTPlatformBuild</key><string>$SDK_BUILD</string>
<key>DTSDKName</key><string>macosx$SDK_VERSION</string>
<key>DTSDKBuild</key><string>$SDK_BUILD</string>
<key>DTXcode</key><string>$DT_XCODE</string>
<key>DTXcodeBuild</key><string>$XCODE_BUILD</string>
<key>DTCompiler</key><string>com.apple.compilers.llvm.clang.1_0</string>
<key>BuildMachineOSBuild</key><string>$(sw_vers -buildVersion)</string>
</dict></plist>
PLIST
if [[ "$MODE" == "--local-test" ]]; then
    # A separate identity keeps the test's sandbox container and settings
    # apart from an installed LocalPrompt.
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.biblejustin.localprompt.sandboxtest" \
        -c "Set :CFBundleDisplayName LocalPrompt Sandbox Test" "$APP/Contents/Info.plist"
fi
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Safari extension: an app extension whose handler is compiled with the
# SlidesBridgeKit sources, plus the same web extension files Chrome uses.
APPEX="$APP/Contents/PlugIns/LocalPrompt Slides.appex"
mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"
swiftc -swift-version 5 -O -gnone -parse-as-library -application-extension \
    -module-name LocalPromptSafari -target arm64-apple-macosx26.0 \
    -file-prefix-map "$PWD=/LocalPrompt" -file-prefix-map "$HOME=/User" \
    AppStore/SafariExtension/SafariWebExtensionHandler.swift Sources/SlidesBridgeKit/*.swift \
    -framework SafariServices \
    -Xlinker -e -Xlinker _NSExtensionMain -Xlinker -application_extension \
    -o "$APPEX/Contents/MacOS/LocalPromptSafari"
for file in protocol.js native-port.js content.js service-worker.js popup.html popup.js popup.css; do
    cp "BrowserExtension/$file" "$APPEX/Contents/Resources/$file"
done
# The "key" only pins the unpacked Chrome extension's ID; Safari has no use for it.
python3 - BrowserExtension/manifest.json "$APPEX/Contents/Resources/manifest.json" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1]))
manifest.pop("key", None)
json.dump(manifest, open(sys.argv[2], "w"), indent=2)
PY
SAFARI_ID="com.biblejustin.localprompt.safari"
[[ "$MODE" == "--local-test" ]] && SAFARI_ID="com.biblejustin.localprompt.sandboxtest.safari"
cat > "$APPEX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleName</key><string>LocalPrompt Slides</string>
<key>CFBundleDisplayName</key><string>LocalPrompt Slides</string>
<key>CFBundleExecutable</key><string>LocalPromptSafari</string>
<key>CFBundleIdentifier</key><string>$SAFARI_ID</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundlePackageType</key><string>XPC!</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHumanReadableDescription</key><string>Connect one Google Slides slideshow to LocalPrompt on this Mac.</string>
<key>NSExtension</key><dict>
<key>NSExtensionPointIdentifier</key><string>com.apple.Safari.web-extension</string>
<key>NSExtensionPrincipalClass</key><string>LPSafariWebExtensionHandler</string>
</dict>
<key>DTPlatformName</key><string>macosx</string>
<key>DTPlatformVersion</key><string>$SDK_VERSION</string>
<key>DTPlatformBuild</key><string>$SDK_BUILD</string>
<key>DTSDKName</key><string>macosx$SDK_VERSION</string>
<key>DTSDKBuild</key><string>$SDK_BUILD</string>
<key>DTXcode</key><string>$DT_XCODE</string>
<key>DTXcodeBuild</key><string>$XCODE_BUILD</string>
<key>DTCompiler</key><string>com.apple.compilers.llvm.clang.1_0</string>
<key>BuildMachineOSBuild</key><string>$(sw_vers -buildVersion)</string>
</dict></plist>
PLIST
plutil -lint "$APPEX/Contents/Info.plist" >/dev/null

strip -S -x "$APP/Contents/MacOS/LocalPrompt" "$APP/Contents/MacOS/LocalPromptSlidesHost" "$APPEX/Contents/MacOS/LocalPromptSafari"

ENTITLEMENTS="$OUT_ROOT/entitlements"
mkdir -p "$ENTITLEMENTS"
sed "s/TEAM_ID/$TEAM_ID/g" AppStore/LocalPrompt.entitlements > "$ENTITLEMENTS/app.plist"
sed "s/TEAM_ID/$TEAM_ID/g" AppStore/LocalPromptSlidesHost.entitlements > "$ENTITLEMENTS/host.plist"
sed "s/TEAM_ID/$TEAM_ID/g" AppStore/LocalPromptSafari.entitlements > "$ENTITLEMENTS/safari.plist"
if [[ "$MODE" == "--local-test" ]]; then
    # These two need a provisioning profile; macOS refuses to launch an
    # ad-hoc build that claims them.
    for name in app safari; do
        grep -vE "com\.apple\.(application-identifier|developer\.team-identifier)" "$ENTITLEMENTS/$name.plist" > "$ENTITLEMENTS/$name-local.plist"
        mv "$ENTITLEMENTS/$name-local.plist" "$ENTITLEMENTS/$name.plist"
        plutil -lint "$ENTITLEMENTS/$name.plist" >/dev/null
    done
else
    cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
    cp "$SAFARI_PROVISIONING_PROFILE" "$APPEX/Contents/embedded.provisionprofile"
fi

codesign --force --sign "$APP_SIGN_IDENTITY" --entitlements "$ENTITLEMENTS/safari.plist" "$APPEX"
codesign --force --sign "$APP_SIGN_IDENTITY" --entitlements "$ENTITLEMENTS/host.plist" \
    --identifier com.biblejustin.localprompt.slideshost "$APP/Contents/MacOS/LocalPromptSlidesHost"
codesign --force --sign "$APP_SIGN_IDENTITY" --entitlements "$ENTITLEMENTS/app.plist" "$APP"
codesign --verify --deep --strict "$APP"
for binary in "$APP" "$APP/Contents/MacOS/LocalPromptSlidesHost" "$APPEX"; do
    codesign -d --entitlements - --xml "$binary" 2>/dev/null | grep -q "com.apple.security.app-sandbox" \
        || { echo "Not sandboxed: $binary" >&2; exit 1; }
done

if [[ "$MODE" == "--local-test" ]]; then
    TEST_APP="$PWD/.build/appstore-test.noindex/LocalPrompt.app"
    rm -rf "$TEST_APP"
    mkdir -p "$(dirname "$TEST_APP")"
    ditto "$APP" "$TEST_APP"
    echo "Sandboxed test build: $TEST_APP"
    exit 0
fi

mkdir -p dist
PKG="dist/LocalPrompt-$VERSION-AppStore.pkg"
productbuild --component "$APP" /Applications --sign "$INSTALLER_SIGN_IDENTITY" "$PKG"
echo "Built $PKG. Upload it with Apple's Transporter app."
