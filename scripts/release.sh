#!/usr/bin/env bash
#
# Build, codesign, notarize, and zip a distributable Pointer.app.
#
# Prerequisites (one-time):
#   1. A "Developer ID Application" certificate in your Keychain.
#   2. A stored notarytool profile. Create with:
#      xcrun notarytool store-credentials "PointerNotary" \
#          --apple-id <your-apple-id> \
#          --team-id U25ZJ9KG26 \
#          --password <app-specific-password>
#      (App-specific passwords: https://appleid.apple.com → Sign-in and security → App-Specific Passwords)
#
# Usage:
#   scripts/release.sh <version>          # e.g. scripts/release.sh 0.1.0
#   scripts/release.sh <version> --skip-notarize   # for local testing

set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version> [--skip-notarize]" >&2
    exit 2
fi
SKIP_NOTARIZE=0
if [[ "${2:-}" == "--skip-notarize" ]]; then SKIP_NOTARIZE=1; fi

SIGN_IDENTITY="Developer ID Application: obaid ahmed (U25ZJ9KG26)"
NOTARY_PROFILE="PointerNotary"
BUNDLE_ID="com.magically.pointer"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/Pointer.app"
ZIP="$BUILD_DIR/Pointer-$VERSION.zip"

cd "$ROOT"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Building Release..."
swift build -c release

echo "==> Assembling Pointer.app bundle..."
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp ".build/release/Pointer" "$APP/Contents/MacOS/Pointer"
cp "$ROOT/assets/Pointer.icns" "$APP/Contents/Resources/Pointer.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Pointer</string>
    <key>CFBundleDisplayName</key>
    <string>Pointer</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>Pointer</string>
    <key>CFBundleIconFile</key>
    <string>Pointer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Pointer uses your microphone so you can dictate tasks instead of typing them.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Pointer transcribes your voice on-device so you can speak commands to the agent.</string>
</dict>
</plist>
EOF

echo "==> Codesigning with hardened runtime..."
codesign --force --options runtime --timestamp \
    --entitlements "$ROOT/scripts/Pointer.entitlements" \
    --sign "$SIGN_IDENTITY" \
    "$APP/Contents/MacOS/Pointer"
codesign --force --options runtime --timestamp \
    --entitlements "$ROOT/scripts/Pointer.entitlements" \
    --sign "$SIGN_IDENTITY" \
    "$APP"

echo "==> Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP"

if [[ $SKIP_NOTARIZE -eq 1 ]]; then
    echo "==> Skipping notarization (--skip-notarize)."
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Built (unsigned-by-Apple): $ZIP"
    exit 0
fi

echo "==> Submitting to Apple notary service (this can take 1-5 minutes)..."
NOTARY_ZIP="$BUILD_DIR/Pointer-notarize.zip"
ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Zipping final distributable..."
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "Done. Notarized release: $ZIP"
echo
echo "To create a GitHub release:"
echo "  gh release create v$VERSION '$ZIP' --title 'Pointer v$VERSION' --generate-notes"
