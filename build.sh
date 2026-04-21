#!/usr/bin/env bash
#
# Build LanguageSwitcher.app from the Swift package.
#
# Usage:
#   ./build.sh                 # release build -> ./build/LanguageSwitcher.app
#   ./build.sh debug           # debug build
#   ./build.sh run             # build + launch
#   ./build.sh install         # build + copy to /Applications
#   ./build.sh dmg             # release build + package DMG into ./dist/
#
set -euo pipefail

CONFIG="${1:-release}"
ACTION=""
case "$CONFIG" in
  run|install|dmg)
    ACTION="$CONFIG"
    CONFIG="release"
    ;;
  debug|release)
    ;;
  *)
    echo "Unknown argument: $CONFIG" >&2
    exit 1
    ;;
esac

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
APP_NAME="LanguageSwitcher"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"

ICON_ICNS="$ROOT/Resources/AppIcon.icns"
if [ ! -f "$ICON_ICNS" ] || [ "$ROOT/scripts/make-icon.swift" -nt "$ICON_ICNS" ]; then
  echo "==> generating AppIcon.icns"
  swift "$ROOT/scripts/make-icon.swift" "$ROOT/Resources"
fi

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG" --product "$APP_NAME"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"

echo "==> packaging $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ICON_ICNS" "$RES_DIR/AppIcon.icns"

# Create PkgInfo
printf 'APPL????' > "$CONTENTS/PkgInfo"

SIGN_IDENTITY="${SIGN_IDENTITY:-LanguageSwitcher Local Dev}"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  echo "==> '$SIGN_IDENTITY' not found; running scripts/setup-signing.sh"
  "$ROOT/scripts/setup-signing.sh"
fi

echo "==> codesigning with '$SIGN_IDENTITY'"
codesign --force --deep --sign "$SIGN_IDENTITY" \
  --entitlements "$ROOT/Resources/LanguageSwitcher.entitlements" \
  --options runtime \
  --timestamp=none \
  "$APP_DIR"

# Signing with a stable self-signed identity keeps the designated requirement
# constant across rebuilds, so the Accessibility grant (TCC) survives rebuilds.
# If you ever change the identity or the grant misbehaves, run:
#   tccutil reset Accessibility com.languageswitcher.mac

echo "==> built: $APP_DIR"

case "$ACTION" in
  run)
    echo "==> launching"
    open "$APP_DIR"
    ;;
  install)
    echo "==> installing to /Applications"
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP_DIR" "/Applications/"
    echo "Installed: /Applications/$APP_NAME.app"
    ;;
  dmg)
    "$ROOT/scripts/make-dmg.sh"
    ;;
esac
