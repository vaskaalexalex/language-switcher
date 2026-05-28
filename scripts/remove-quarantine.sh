#!/usr/bin/env bash
#
# Remove Gatekeeper quarantine from a downloaded LanguageSwitcher artifact
# so it can launch without Privacy & Security → Open Anyway.
#
# Usage:
#   ./scripts/remove-quarantine.sh dist/LanguageSwitcher-1.1.5.dmg
#   ./scripts/remove-quarantine.sh /Applications/LanguageSwitcher.app
#
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <path-to-.dmg-or-.app>" >&2
  exit 1
fi

TARGET="$1"
if [ ! -e "$TARGET" ]; then
  echo "error: not found: $TARGET" >&2
  exit 1
fi

echo "==> removing com.apple.quarantine from $TARGET"
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

if [[ "$TARGET" == *.dmg ]]; then
  echo "==> done. Mount the DMG and drag LanguageSwitcher.app to /Applications."
else
  echo "==> done. You can launch $TARGET normally."
fi
