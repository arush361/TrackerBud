#!/usr/bin/env bash
set -euo pipefail

# Build script that wraps the SPM executable in a proper .app bundle.
# Usage: ./Scripts/build.sh [debug|release]   (default: debug)

CONFIG="${1:-debug}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="TrackerBud"
BUNDLE_ID="com.arushsharma.trackerbud"
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

# PkgInfo
printf "APPL????" > "$APP_DIR/Contents/PkgInfo"

echo "==> Ad-hoc signing with stable identity (preserves TCC grants across rebuilds)"
codesign --force --deep --sign - \
    --entitlements "$ROOT_DIR/Resources/TrackerBud.entitlements" \
    "$APP_DIR"

echo "==> Done."
echo "App bundle: $APP_DIR"
echo ""
echo "Launch with:  open '$APP_DIR'"
