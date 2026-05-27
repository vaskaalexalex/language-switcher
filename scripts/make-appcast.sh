#!/usr/bin/env bash
#
# Generates appcast.xml for the latest LanguageSwitcher DMG in dist/.
#
# Usage:
#   ./scripts/make-appcast.sh
#   VERSION=1.1.5 ./scripts/make-appcast.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT/dist"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/Resources/Info.plist")}"
DMG_NAME="LanguageSwitcher-$VERSION.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
APPCAST_PATH="$DIST_DIR/appcast.xml"
STAGE_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

if [ ! -f "$DMG_PATH" ]; then
  echo "error: $DMG_PATH not found. Run ./build.sh dmg first." >&2
  exit 1
fi

echo "==> resolving Sparkle package"
swift package resolve >/dev/null

GENERATE_APPCAST="$(find "$ROOT/.build/artifacts/sparkle" -path '*/bin/generate_appcast' -type f 2>/dev/null | head -1)"
if [ -z "$GENERATE_APPCAST" ]; then
  GENERATE_APPCAST="$(find "$ROOT/.build/checkouts/Sparkle" -path '*/bin/generate_appcast' -type f 2>/dev/null | head -1)"
fi
if [ -z "$GENERATE_APPCAST" ]; then
  echo "error: Sparkle generate_appcast not found." >&2
  exit 1
fi

echo "==> staging $DMG_NAME for appcast generation"
cp "$DMG_PATH" "$STAGE_DIR/"

echo "==> generating appcast"
"$GENERATE_APPCAST" "$STAGE_DIR" --download-url-prefix "https://github.com/vaskaalexalex/language-switcher/releases/download/v$VERSION/"

if [ ! -f "$STAGE_DIR/appcast.xml" ]; then
  echo "error: appcast.xml was not generated" >&2
  exit 1
fi

cp "$STAGE_DIR/appcast.xml" "$APPCAST_PATH"
echo "==> done: $APPCAST_PATH"
