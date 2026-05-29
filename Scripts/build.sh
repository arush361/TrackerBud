#!/usr/bin/env bash
set -euo pipefail

# Build script that wraps the SPM executable in a proper .app bundle.
# Usage: ./Scripts/build.sh [debug|release]   (default: debug)

CONFIG="${1:-debug}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="TrackerBud"
BUILD_DIR="$ROOT_DIR/.build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

cd "$ROOT_DIR"

echo "==> Building $APP_NAME ($CONFIG)"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
if [ ! -f "$BIN_PATH" ]; then
    echo "Build did not produce expected binary at $BIN_PATH"
    exit 1
fi

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
printf "APPL????" > "$APP_DIR/Contents/PkgInfo"

# Pick the most stable signing identity available. TCC associates Screen
# Recording / Accessibility / Input Monitoring / etc. grants with the
# signing identity (Team ID + bundle ID for properly signed apps). If the
# identity changes between rebuilds, all grants are invalidated and the OS
# re-prompts. Order of preference:
#   1. A persistent self-signed cert called "TrackerBud Self-Signed" if the
#      user has trusted it for Code Signing (see Scripts/create-signing-cert.sh).
#   2. The user's Apple Development cert if one exists (stable Team ID).
#   3. Ad-hoc — only stable if zero source changes, which is rarely the case.
SIGNING_IDENTITY="-"
SIGN_LABEL="ad-hoc (TCC grants will reset on every source change)"

# 1) Self-signed if trusted (find-identity -p codesigning -v only lists trusted)
TS_HASH="$(security find-identity -p codesigning -v 2>/dev/null \
    | grep '"TrackerBud Self-Signed"' \
    | awk '{print $2}' \
    | head -1 || true)"
if [ -n "$TS_HASH" ]; then
    SIGNING_IDENTITY="$TS_HASH"
    SIGN_LABEL="TrackerBud Self-Signed ($TS_HASH)"
fi

# 2) Fall back to Apple Development cert
if [ "$SIGNING_IDENTITY" = "-" ]; then
    APPLE_DEV_HASH="$(security find-identity -p codesigning -v 2>/dev/null \
        | grep '"Apple Development:' \
        | awk '{print $2}' \
        | head -1 || true)"
    if [ -n "$APPLE_DEV_HASH" ]; then
        SIGNING_IDENTITY="$APPLE_DEV_HASH"
        SIGN_LABEL="Apple Development cert ($APPLE_DEV_HASH)"
    fi
fi

echo "==> Signing with: $SIGN_LABEL"
codesign --force --deep --sign "$SIGNING_IDENTITY" \
    --entitlements "$ROOT_DIR/Resources/TrackerBud.entitlements" \
    --options runtime \
    "$APP_DIR"

echo "==> Verifying signature"
codesign -dvvv "$APP_DIR" 2>&1 | grep -E "Identifier|Signature|Authority|TeamIdentifier|CDHash" | head

echo
echo "==> Done."
echo "App bundle: $APP_DIR"
echo
echo "Launch with:  open '$APP_DIR'"
