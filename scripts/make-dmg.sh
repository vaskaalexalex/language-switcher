#!/usr/bin/env bash
#
# Packages build/LanguageSwitcher.app into a distributable .dmg.
#
# Produces:
#   dist/LanguageSwitcher-<version>.dmg
#
# Requires `hdiutil` (bundled with macOS). No extra tools needed.
#
# Usage:
#   ./scripts/make-dmg.sh                # uses version from Info.plist
#   VERSION=1.2.3 ./scripts/make-dmg.sh  # override version
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="LanguageSwitcher"
APP_DIR="$ROOT/build/$APP_NAME.app"
DIST_DIR="$ROOT/dist"

if [ ! -d "$APP_DIR" ]; then
  echo "error: $APP_DIR not found. Run ./build.sh first." >&2
  exit 1
fi

VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_DIR/Contents/Info.plist" 2>/dev/null || echo 1.0.0)}"
DMG_NAME="$APP_NAME-$VERSION"
DMG_PATH="$DIST_DIR/$DMG_NAME.dmg"
VOLNAME="$APP_NAME $VERSION"

mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> staging DMG contents"
cp -R "$APP_DIR" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

# Short install instructions inside the DMG window.
cat > "$STAGE/README.txt" <<EOF
$APP_NAME

Install:
  1. Drag $APP_NAME.app into the Applications folder.
  2. Launch it from /Applications (or Spotlight).
  3. macOS will ask for Accessibility permission — grant it in
     System Settings -> Privacy & Security -> Accessibility.

Because the app is self-signed (not notarized), the first launch will show
a Gatekeeper warning. Right-click the app in Finder and choose "Open",
then "Open" again in the dialog, or run once:

  xattr -dr com.apple.quarantine /Applications/$APP_NAME.app

Source code and updates: https://github.com/
EOF

echo "==> building DMG at $DMG_PATH"
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGE" \
  -ov \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG_PATH" >/dev/null

# Codesign the DMG itself with the same identity used for the app, if present.
SIGN_IDENTITY="${SIGN_IDENTITY:-LanguageSwitcher Local Dev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  echo "==> codesigning DMG with '$SIGN_IDENTITY'"
  codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$DMG_PATH" || true
fi

SIZE=$(du -h "$DMG_PATH" | awk '{print $1}')
echo "==> done: $DMG_PATH ($SIZE)"
