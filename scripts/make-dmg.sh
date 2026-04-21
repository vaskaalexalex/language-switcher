#!/usr/bin/env bash
#
# Packages build/LanguageSwitcher.app into a distributable .dmg with a
# custom Finder window layout: the app icon on the left and an Applications
# folder shortcut on the right, so users can drag-and-drop to install.
#
# Produces:
#   dist/LanguageSwitcher-<version>.dmg
#
# Requires `hdiutil` and `osascript` (both bundled with macOS).
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
RW_DMG="$(mktemp -u).dmg"
MOUNT_DIR="/Volumes/$VOLNAME"
cleanup() {
  hdiutil detach "$MOUNT_DIR" -quiet -force 2>/dev/null || true
  rm -rf "$STAGE"
  rm -f "$RW_DMG"
}
trap cleanup EXIT

# If a previous run left the volume mounted, detach it first.
if [ -d "$MOUNT_DIR" ]; then
  hdiutil detach "$MOUNT_DIR" -quiet -force 2>/dev/null || true
fi

echo "==> staging DMG contents"
cp -R "$APP_DIR" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

# Size the RW image with some headroom over the staged content.
STAGE_KB=$(du -sk "$STAGE" | awk '{print $1}')
SIZE_MB=$(( STAGE_KB / 1024 + 32 ))

echo "==> creating writable DMG (${SIZE_MB}M)"
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDRW \
  -size "${SIZE_MB}m" \
  -ov \
  "$RW_DMG" >/dev/null

echo "==> mounting writable DMG"
hdiutil attach "$RW_DMG" \
  -readwrite \
  -noverify \
  -noautoopen \
  -quiet >/dev/null

# Wait for the mount to appear.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -d "$MOUNT_DIR" ] && break
  sleep 0.5
done

if [ ! -d "$MOUNT_DIR" ]; then
  echo "error: volume $MOUNT_DIR did not mount" >&2
  exit 1
fi

# Prevent Spotlight / FSEvents / Trash metadata folders from being created on
# the volume, so the distributed DMG doesn't contain hidden junk.
touch "$MOUNT_DIR/.metadata_never_index"
rm -rf "$MOUNT_DIR/.fseventsd" \
       "$MOUNT_DIR/.Trashes" \
       "$MOUNT_DIR/.Spotlight-V100" \
       "$MOUNT_DIR/.DocumentRevisions-V100" \
       "$MOUNT_DIR/.TemporaryItems" 2>/dev/null || true

echo "==> laying out Finder window"
# Window geometry: a wide, short window similar to the reference screenshot.
# Coordinates are in Finder's icon-view space.
WIN_X=200
WIN_Y=140
WIN_W=640
WIN_H=400
ICON_SIZE=128
APP_X=160
APP_Y=190
APPS_X=480
APPS_Y=190

/usr/bin/osascript <<OSA
tell application "Finder"
    tell disk "$VOLNAME"
        open
        delay 2
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set sidebar width of container window to 0
        set the bounds of container window to {$WIN_X, $WIN_Y, $WIN_X + $WIN_W, $WIN_Y + $WIN_H}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to $ICON_SIZE
        set text size of viewOptions to 12
        set label position of viewOptions to bottom
        try
            set background color of viewOptions to {65535, 65535, 65535}
        end try
        set position of item "$APP_NAME.app" of container window to {$APP_X, $APP_Y}
        set position of item "Applications" of container window to {$APPS_X, $APPS_Y}
        update without registering applications
        delay 2
        -- Close and reopen so Finder refreshes and fetches the icon for the
        -- Applications symlink target, then flushes the layout to .DS_Store.
        close
        delay 1
        open
        delay 3
        update without registering applications
        delay 3
        close
    end tell
end tell
OSA

# Give Finder a moment to persist .DS_Store, then sync and scrub hidden
# metadata (Finder recreates .fseventsd after writing DS_Store). The final
# read-only DMG doesn't need .metadata_never_index either.
sleep 2
sync
rm -rf "$MOUNT_DIR/.fseventsd" \
       "$MOUNT_DIR/.Trashes" \
       "$MOUNT_DIR/.Spotlight-V100" \
       "$MOUNT_DIR/.DocumentRevisions-V100" \
       "$MOUNT_DIR/.TemporaryItems" 2>/dev/null || true
rm -f "$MOUNT_DIR/.metadata_never_index"
sync

echo "==> detaching writable DMG"
hdiutil detach "$MOUNT_DIR" -quiet -force

echo "==> converting to compressed DMG at $DMG_PATH"
hdiutil convert "$RW_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_PATH" >/dev/null

# Codesign the DMG itself with the same identity used for the app, if present.
SIGN_IDENTITY="${SIGN_IDENTITY:-LanguageSwitcher Local Dev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  echo "==> codesigning DMG with '$SIGN_IDENTITY'"
  codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$DMG_PATH" || true
fi

SIZE=$(du -h "$DMG_PATH" | awk '{print $1}')
echo "==> done: $DMG_PATH ($SIZE)"
