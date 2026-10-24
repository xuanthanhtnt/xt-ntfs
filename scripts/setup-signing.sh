#!/bin/bash
# Imports a code signing certificate (.p12) into a temporary keychain on a
# CI machine and trusts it for code signing, so `codesign --sign <name>`
# works with a self-signed certificate.
#
#   scripts/setup-signing.sh <file.p12> <password> <keychain-path>
# Prints the certificate's common name (the identity to pass to codesign).
set -euo pipefail

P12="${1:?p12}"
PASSWORD="${2?password}"
KC="${3:?keychain path}"

OPENSSL=openssl
if command -v brew >/dev/null 2>&1 && [ -x "$(brew --prefix openssl@3 2>/dev/null)/bin/openssl" ]; then
  OPENSSL="$(brew --prefix openssl@3)/bin/openssl"
fi

security create-keychain -p xt "$KC" >/dev/null
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p xt "$KC"
security import "$P12" -k "$KC" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k xt "$KC" >/dev/null
# Put the keychain first in the search list, keeping the existing ones.
existing="$(security list-keychains -d user | tr -d '"' | tr '\n' ' ')"
# shellcheck disable=SC2086
security list-keychains -d user -s "$KC" $existing

CERT="$(mktemp)"
"$OPENSSL" pkcs12 -in "$P12" -passin pass:"$PASSWORD" -nokeys -clcerts -legacy 2>/dev/null \
  | "$OPENSSL" x509 -out "$CERT" 2>/dev/null \
  || "$OPENSSL" pkcs12 -in "$P12" -passin pass:"$PASSWORD" -nokeys -clcerts \
  | "$OPENSSL" x509 -out "$CERT"
sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain "$CERT" >&2
NAME="$("$OPENSSL" x509 -in "$CERT" -noout -subject -nameopt multiline | sed -n 's/^ *commonName *= *//p')"
rm -f "$CERT"
security find-identity -v -p codesigning "$KC" >&2
echo "$NAME"
