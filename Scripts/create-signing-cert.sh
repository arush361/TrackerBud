#!/usr/bin/env bash
# Creates a self-signed code-signing certificate dedicated to TrackerBud and
# imports it into the user's login keychain. Run once. Future rebuilds re-use
# the same cert, which keeps the (cert hash, bundle ID) pair stable so TCC
# grants survive across rebuilds.

set -euo pipefail

CERT_NAME="TrackerBud Self-Signed"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Skip if already installed
if security find-identity -p codesigning -v | grep -q "$CERT_NAME"; then
    echo "Certificate '$CERT_NAME' is already installed in your login keychain."
    security find-identity -p codesigning -v | grep "$CERT_NAME"
    exit 0
fi

echo "==> Creating self-signed code-signing certificate '$CERT_NAME'"

cat > "$WORK_DIR/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
default_md         = sha256

[ dn ]
CN = $CERT_NAME

[ v3 ]
basicConstraints     = critical, CA:FALSE
keyUsage             = critical, digitalSignature
extendedKeyUsage     = critical, codeSigning
subjectKeyIdentifier = hash
EOF

# 100-year cert so it doesn't expire on us
openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$WORK_DIR/key.pem" \
    -out "$WORK_DIR/cert.pem" \
    -days 36500 \
    -config "$WORK_DIR/cert.cnf" \
    -extensions v3 2>/dev/null

openssl pkcs12 -export \
    -out "$WORK_DIR/cert.p12" \
    -inkey "$WORK_DIR/key.pem" \
    -in "$WORK_DIR/cert.pem" \
    -name "$CERT_NAME" \
    -passout pass: \
    -legacy 2>/dev/null

KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

echo "==> Importing into login keychain (you may be prompted for your login password)"
security import "$WORK_DIR/cert.p12" -k "$KEYCHAIN" -P "" -T /usr/bin/codesign -A 2>/dev/null

# Mark trusted for code signing
echo "==> Trusting cert for code signing"
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK_DIR/cert.pem" 2>/dev/null || \
    echo "(Note: add-trusted-cert needs admin sometimes; you can also trust manually in Keychain Access)"

echo
echo "==> Done. Verifying:"
security find-identity -p codesigning -v | grep -E "$CERT_NAME|valid identities"
