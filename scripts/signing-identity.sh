#!/bin/zsh
# Creates a stable self-signed code-signing identity for Frontier, once.
#
# Why: an ad-hoc signature (`codesign -s -`) is different for every build, so macOS treats each
# install as a brand-new app and revokes the Accessibility grant that the gramophone's play/skip
# controls need. Signing every build with the same certificate keeps that grant.
#
# This touches only your login keychain, and only adds. To undo it:
#   security delete-certificate -c "Frontier Local Signing" ~/Library/Keychains/login.keychain-db
#
# macOS may ask for your login password, and the first build afterwards may ask permission for
# codesign to use the key — choose "Always Allow" to avoid being asked again.
set -euo pipefail
NAME="Frontier Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "already set up: $NAME"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/req.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = $NAME
[ v3 ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -config "$tmp/req.cnf" 2>/dev/null
# OpenSSL 3 defaults to AES-256/SHA-256 for PKCS#12, which Apple's `security` cannot read
# ("MAC verification failed"). These flags ask for the older algorithms it does understand.
openssl pkcs12 -export -out "$tmp/id.p12" -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
  -passout pass:frontier -name "$NAME" \
  -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES 2>/dev/null \
  || openssl pkcs12 -export -out "$tmp/id.p12" -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
       -passout pass:frontier -name "$NAME" 2>/dev/null

# -A lets any tool use the key, which avoids a prompt on every single build.
security import "$tmp/id.p12" -k "$KEYCHAIN" -P frontier -A >/dev/null
# Trust it for code signing only, in the user domain (no admin rights needed).
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$tmp/cert.pem"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "created: $NAME"
  echo "Run 'make install' again, then grant Accessibility once more. It will stick from now on."
else
  echo "the certificate was imported but codesign does not list it as valid yet." >&2
  echo "Open Keychain Access, find \"$NAME\", and set 'Code Signing' to 'Always Trust'." >&2
  exit 1
fi
