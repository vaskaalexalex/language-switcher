#!/usr/bin/env bash
#
# Generates Sparkle EdDSA keys if missing and prints the public key for Info.plist.
# Private key stays in the login keychain (Sparkle default).
#
# Usage:
#   ./scripts/setup-sparkle-keys.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEYS_DIR="$ROOT/.sparkle"
PUBLIC_KEY_FILE="$KEYS_DIR/eddsa-public-key.txt"

mkdir -p "$KEYS_DIR"

echo "==> resolving Sparkle package"
swift package resolve >/dev/null

SPARKLE_BIN="$(find "$ROOT/.build/artifacts/sparkle" -path '*/bin/generate_keys' -type f 2>/dev/null | head -1)"
if [ -z "$SPARKLE_BIN" ]; then
  SPARKLE_BIN="$(find "$ROOT/.build/checkouts/Sparkle" -path '*/bin/generate_keys' -type f 2>/dev/null | head -1)"
fi
if [ -z "$SPARKLE_BIN" ]; then
  echo "error: Sparkle generate_keys not found. Run 'swift package resolve' first." >&2
  exit 1
fi

if [ -f "$PUBLIC_KEY_FILE" ]; then
  echo "==> existing public key:"
  cat "$PUBLIC_KEY_FILE"
  exit 0
fi

echo "==> generating Sparkle EdDSA keys (private key stored in keychain)"
OUTPUT="$("$SPARKLE_BIN" 2>&1 || "$SPARKLE_BIN" -p 2>&1)"
PUBLIC_KEY="$(printf '%s\n' "$OUTPUT" | sed -n 's/.*<string>\([^<]*\)<\/string>.*/\1/p' | head -1)"
if [ -z "$PUBLIC_KEY" ]; then
  echo "error: failed to obtain Sparkle public key" >&2
  printf '%s\n' "$OUTPUT" >&2
  exit 1
fi
printf '%s\n' "$PUBLIC_KEY" > "$PUBLIC_KEY_FILE"
echo "==> public key saved to $PUBLIC_KEY_FILE"
echo "$PUBLIC_KEY"
