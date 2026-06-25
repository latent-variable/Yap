#!/usr/bin/env bash
# One-time: create a STABLE self-signed code-signing identity so every Yap
# build shares one code identity. macOS then ties your Accessibility grant to
# the certificate, not the binary hash — so it survives every rebuild. Grant
# once, never again.
#
# Uses a DEDICATED keychain with its own password (not your login keychain), so
# it needs no input from you and touches none of your other keys.
#
#   bash scripts/setup_signing.sh            # set up
#   bash scripts/setup_signing.sh --remove   # undo
set -euo pipefail

NAME="Yap Local Signing"
SIGN_KC="$HOME/Library/Keychains/yap-signing.keychain-db"
KCPW="yap-local"   # password for THIS keychain only

current_keychains() { security list-keychains -d user | sed 's/^[[:space:]]*//; s/"//g'; }

if [ "${1:-}" = "--remove" ]; then
  # drop from search list, then delete
  REMAIN=(); while IFS= read -r k; do [ "$k" = "$SIGN_KC" ] || REMAIN+=("$k"); done < <(current_keychains)
  [ ${#REMAIN[@]} -gt 0 ] && security list-keychains -d user -s "${REMAIN[@]}" >/dev/null 2>&1 || true
  security delete-keychain "$SIGN_KC" 2>/dev/null || true
  echo "removed signing keychain"; exit 0
fi

if [ -f "$SIGN_KC" ] && security find-certificate -c "$NAME" "$SIGN_KC" >/dev/null 2>&1; then
  echo "✓ '$NAME' already set up. Rebuild with: bash scripts/build_app.sh"
  exit 0
fi

echo "[sign] creating dedicated signing keychain"
security delete-keychain "$SIGN_KC" 2>/dev/null || true
security create-keychain -p "$KCPW" "$SIGN_KC"
security set-keychain-settings "$SIGN_KC"                 # no auto-lock timeout
security unlock-keychain -p "$KCPW" "$SIGN_KC"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg" <<CNF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $NAME
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CNF

echo "[sign] generating self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -config "$TMP/cfg" >/dev/null 2>&1
# The -legacy/PBE flags are OpenSSL 3.x-only; macOS's stock LibreSSL rejects
# them. Apply them only when the active openssl is OpenSSL 3.x.
if openssl version | grep -q "OpenSSL 3"; then
  LEGACY_ARGS=(-legacy -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1)
else
  LEGACY_ARGS=()
fi
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" \
  -passout pass:yap -name "$NAME" "${LEGACY_ARGS[@]}" >/dev/null 2>&1

echo "[sign] importing + authorizing codesign (non-interactive)"
security import "$TMP/id.p12" -k "$SIGN_KC" -P yap -T /usr/bin/codesign -A >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPW" "$SIGN_KC" >/dev/null 2>&1

# add the signing keychain to the search list (keep existing ones)
KCS=(); while IFS= read -r k; do [ -n "$k" ] && KCS+=("$k"); done < <(current_keychains)
INSEARCH=0; for k in "${KCS[@]}"; do [ "$k" = "$SIGN_KC" ] && INSEARCH=1; done
[ "$INSEARCH" = 0 ] && security list-keychains -d user -s "${KCS[@]}" "$SIGN_KC" >/dev/null

# Verify by test-signing a real binary (find-identity hides untrusted
# self-signed certs, so it's not a usable check). Re-unlock first — the
# partition-list/search-list steps above can leave codesign unable to reach the
# private key, which made this self-check fail even though signing works.
security unlock-keychain -p "$KCPW" "$SIGN_KC" >/dev/null 2>&1
VTMP="$(mktemp -d)"; cp /bin/echo "$VTMP/echo"
echo
if codesign --force --sign "$NAME" --keychain "$SIGN_KC" "$VTMP/echo" 2>/dev/null \
   && codesign -dvv "$VTMP/echo" 2>&1 | grep -q "Authority=$NAME"; then
  rm -rf "$VTMP"
  echo "✓ '$NAME' ready (dedicated keychain, no prompts)."
  echo "  Rebuild + reinstall once, grant Accessibility once, and it sticks"
  echo "  across every future build:"
  echo "    bash scripts/build_app.sh && cp -R dist/Yap.app /Applications/"
else
  rm -rf "$VTMP"
  echo "✗ setup failed — codesign could not use the identity."
  exit 1
fi
