#!/bin/bash
# Create a stable self-signed code-signing identity ("CClimit Dev") in the login keychain.
# Signing with a stable identity keeps the macOS Keychain consent (for reading Claude Code's
# token) valid across rebuilds — ad-hoc signing re-prompts every build because its identity
# is the code hash, which changes each compile.
#
# Idempotent: does nothing if the identity already exists. Safe — a local dev cert only,
# never trusted for distribution.
set -euo pipefail

CERT_NAME="CClimit Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "Identity '$CERT_NAME' already exists — nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" <<'CONF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = CClimit Dev
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/cert.conf" >/dev/null 2>&1

# -legacy: OpenSSL 3's default PKCS12 MAC/encryption isn't readable by Apple's `security`
# tool ("MAC verification failed"); the legacy format is. A non-empty transfer password is
# also required — Apple's import rejects empty-password PKCS12. It's ephemeral (this file
# never leaves $TMP), so its value doesn't matter.
XFER_PASS="cclimit-dev-transfer"
openssl pkcs12 -export -legacy -out "$TMP/identity.p12" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout "pass:$XFER_PASS" >/dev/null 2>&1

# -T /usr/bin/codesign lets codesign use the private key without a per-sign prompt.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$XFER_PASS" -T /usr/bin/codesign

echo "Created code-signing identity '$CERT_NAME'."
echo "Two one-time prompts follow, then it's silent forever:"
echo "  1. 'codesign wants to sign using key CClimit Dev' → click Always Allow."
echo "  2. On first launch, the CClimit → Claude Code-credentials consent → click Allow."
