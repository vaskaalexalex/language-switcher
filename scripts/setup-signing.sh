#!/usr/bin/env bash
#
# Creates a stable self-signed code-signing identity used by build.sh so that
# every rebuild produces a binary with the same designated requirement.
#
# Why this matters: macOS stores Accessibility grants by (bundleId, designated
# requirement). Ad-hoc (`codesign -s -`) signatures derive the DR from the
# binary's code hash — it changes every build, silently revoking the grant.
# A stable self-signed cert means the DR is "identifier ... and certificate
# leaf = H:<cert-hash>", which stays the same for all builds.
#
# Run once per machine. Idempotent.
#
set -euo pipefail

IDENTITY_NAME="${IDENTITY_NAME:-LanguageSwitcher Local Dev}"
LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"

# Allow re-running just the partition-list step on an existing identity.
MODE="${1:-auto}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY_NAME"; then
    if [ "$MODE" = "fix-acl" ]; then
        echo "==> Updating key partition list for '$IDENTITY_NAME'"
        echo -n "Enter your login (keychain) password: "
        read -rs LOGIN_PW
        echo
        security set-key-partition-list \
            -S "apple-tool:,apple:,codesign:" \
            -s \
            -k "$LOGIN_PW" \
            "$LOGIN_KC" \
            >/dev/null
        echo "==> Done. codesign should no longer prompt."
        exit 0
    fi
    echo "Identity '$IDENTITY_NAME' already exists."
    echo "If codesign keeps asking for your password, run:"
    echo "  $0 fix-acl"
    exit 0
fi

echo "==> Creating self-signed code-signing identity '$IDENTITY_NAME'"
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

cat > "$tmpdir/config" <<EOF
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = v3
[ dn ]
CN = $IDENTITY_NAME
[ v3 ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

# Generate 2048-bit RSA key + self-signed cert valid 10 years.
openssl req -newkey rsa:2048 -nodes -x509 -days 3650 \
    -keyout "$tmpdir/key.pem" \
    -out "$tmpdir/cert.pem" \
    -config "$tmpdir/config" \
    >/dev/null 2>&1

# Bundle into PKCS#12 for keychain import.
# Use a simple password (PKCS#12 requires non-empty on modern openssl).
P12_PASS="languageswitcher"
openssl pkcs12 -export -legacy \
    -out "$tmpdir/cert.p12" \
    -inkey "$tmpdir/key.pem" \
    -in "$tmpdir/cert.pem" \
    -name "$IDENTITY_NAME" \
    -passout "pass:$P12_PASS" \
    >/dev/null 2>&1

echo "==> Importing into login keychain"
# -T /usr/bin/codesign allows codesign to use the key without UI prompts.
security import "$tmpdir/cert.p12" \
    -k "$LOGIN_KC" \
    -P "$P12_PASS" \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    >/dev/null 2>&1

# Mark the cert as trusted for code signing (user domain — no sudo needed).
# This avoids codesign warnings about untrusted roots.
security add-trusted-cert \
    -p codeSign \
    -k "$LOGIN_KC" \
    "$tmpdir/cert.pem" \
    >/dev/null 2>&1 || \
    echo "   (skipping cert trust — may require password prompt later)"

# Update the key's partition list so codesign can use it non-interactively.
# Requires the user's login (keychain) password.
echo "==> Setting key partition list (needed so codesign doesn't prompt every build)"
echo -n "Enter your login (keychain) password: "
read -rs LOGIN_PW
echo
if ! security set-key-partition-list \
        -S "apple-tool:,apple:,codesign:" \
        -s \
        -k "$LOGIN_PW" \
        "$LOGIN_KC" \
        >/dev/null 2>&1; then
    echo "   WARNING: partition list update failed. You can retry later with:"
    echo "     $0 fix-acl"
fi
unset LOGIN_PW

echo "==> Done."
echo "Identity: $IDENTITY_NAME"
security find-identity -v -p codesigning | grep "$IDENTITY_NAME" || true
