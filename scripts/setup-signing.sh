#!/bin/bash
# Puts the Developer ID signing identity where local builds use it: a dedicated keychain
# (~/Library/Keychains/developer-id.keychain-db) whose generated password is kept in
# ~/Library/Application Support/DeveloperID/, so codesign never prompts. The certificate
# belongs to the team, not to Fred: the maintainer's other Mac apps carry a copy of this
# script with the same paths, so whichever runs first sets up the Mac for all of them.
#   scripts/setup-signing.sh            import it from AWS Secrets Manager
#                                       github/keys/apple-developer (SSO profile `prod`,
#                                       or AWS_PROFILE)
#   scripts/setup-signing.sh <id.p12>   import it from an exported .p12 (asks for its password)
#   scripts/setup-signing.sh --check    exit 1 with instructions if anything is missing
#
# Why the Developer ID and not a local identity: macOS privacy grants are keyed on the
# app's designated requirement, and every Developer ID signature has the same one (bundle
# id + team ID). So brew-installed releases and `make install` builds are the same app to
# TCC, and grants survive certificate renewals. Any other identity would need every
# permission granted again whenever a Mac switched between a release and a local build.
#
# Also installs Apple's Developer ID G2 intermediate into the login keychain when it's
# missing (pinned by hash): codesign builds the embedded chain from the keychain search
# list. Every run (re)imports the identity, replacing the old one: run it again after
# renewing the certificate.
set -euo pipefail

# Keep these paths in sync with the other apps' copies of this script (and bundle.sh).
DEV_DIR="$HOME/Library/Application Support/DeveloperID"
KC="$HOME/Library/Keychains/developer-id.keychain-db"
PASS_FILE="$DEV_DIR/keychain-password"
LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"
G2_URL=https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer
G2_SHA256=f16cd3c54c7f83cea4bf1a3e6a0819c8aaa8e4a1528fd144715f350643d2df3a

have_g2() {   # the G2 "Developer ID Certification Authority" in the login or System keychain
  local pems
  pems="$(security find-certificate -a -c "Developer ID Certification Authority" -p \
    "$LOGIN_KC" /Library/Keychains/System.keychain 2>/dev/null || true)"
  [[ -n "$pems" ]] && openssl crl2pkcs7 -nocrl -certfile <(printf '%s\n' "$pems") \
    | openssl pkcs7 -print_certs -noout | grep -q "OU=G2"
}
identity() {   # SHA-1 of the valid Developer ID identity in the signing keychain, if any
  [[ -f "$KC" ]] && security find-identity -v -p codesigning "$KC" 2>/dev/null \
    | awk '/"Developer ID Application: / { print $2; exit }'
}

if [[ "${1:-}" == --check ]]; then
  [[ -f "$PASS_FILE" ]] && have_g2 && [[ -n "$(identity)" ]] && exit 0
  echo "local signing isn't set up: run scripts/setup-signing.sh (imports the Developer ID)" >&2
  exit 1
fi

TMP="$(mktemp -d)"
chmod 700 "$TMP"
CHECK_KC="$TMP/check.keychain-db"
trap 'security delete-keychain "$CHECK_KC" 2>/dev/null || true; rm -rf "$TMP"' EXIT

if ! have_g2; then
  curl -fsSL "$G2_URL" -o "$TMP/g2.cer"
  [[ "$(shasum -a 256 "$TMP/g2.cer" | cut -d' ' -f1)" == "$G2_SHA256" ]] \
    || { echo "$G2_URL doesn't have the expected hash" >&2; exit 1; }
  security import "$TMP/g2.cer" -k "$LOGIN_KC" >/dev/null
  echo "installed Apple's Developer ID G2 intermediate in the login keychain"
fi

if [[ -f "$KC" && ! -f "$PASS_FILE" ]]; then
  echo "$KC exists but its password file is gone; delete the keychain and run this again" >&2
  exit 1
fi
if [[ ! -f "$KC" ]]; then
  mkdir -p "$DEV_DIR"
  chmod 700 "$DEV_DIR"
  openssl rand -hex 24 | tr -d '\n' > "$PASS_FILE"
  chmod 600 "$PASS_FILE"
  security create-keychain -p "$(cat "$PASS_FILE")" "$KC"
  security set-keychain-settings "$KC"   # no auto-lock timeout
fi
PASS="$(cat "$PASS_FILE")"
security unlock-keychain -p "$PASS" "$KC"

# Always (re)import, so a renewed certificate replaces one that is still valid.
if [[ $# -gt 0 ]]; then
  cp "$1" "$TMP/id.p12"
  read -rsp "password of $(basename "$1"): " P12PW
  echo
else
  PROFILE="${AWS_PROFILE:-prod}"
  aws sts get-caller-identity --profile "$PROFILE" >/dev/null 2>&1 || aws sso login --profile "$PROFILE"
  aws secretsmanager get-secret-value --profile "$PROFILE" --region us-west-2 \
    --secret-id github/keys/apple-developer --query SecretString --output text > "$TMP/secret.json"
  jq -er .APPLE_CERT_P12_BASE64 "$TMP/secret.json" | base64 --decode > "$TMP/id.p12"
  P12PW="$(jq -er .APPLE_CERT_PASSWORD "$TMP/secret.json")"
fi
# Import into a scratch keychain first: a wrong password or a bad secret must not leave the
# shared keychain without an identity.
security create-keychain -p "$(openssl rand -hex 16)" "$CHECK_KC"
security import "$TMP/id.p12" -k "$CHECK_KC" -P "$P12PW" >/dev/null \
  || { echo "can't import the .p12 (wrong password, or a bad secret)" >&2; exit 1; }
security delete-keychain "$CHECK_KC"
# Replace any older Developer ID identity, so exactly one is there to sign with.
while security delete-identity -c "Developer ID Application" "$KC" >/dev/null 2>&1; do :; done
security import "$TMP/id.p12" -k "$KC" -P "$P12PW" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KC" >/dev/null

id="$(identity)"
[[ -n "$id" ]] || { echo "no valid Developer ID Application identity in $KC" >&2; exit 1; }
# Prove codesign can use it without a prompt and build the chain.
cp /usr/bin/true "$TMP/probe"
codesign --force --timestamp=none --sign "$id" --keychain "$KC" "$TMP/probe"
codesign -dvv "$TMP/probe" 2>&1 | sed -n 's/^Authority=/  /p'
echo "local builds sign with $(security find-identity -v -p codesigning "$KC" | awk -v h="$id" '$2 == h { sub(/^[^"]*"/, ""); sub(/".*$/, ""); print }')"
