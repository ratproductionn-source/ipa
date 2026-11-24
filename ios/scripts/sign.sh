#!/usr/bin/env bash
# Re-signs a fakesigned IPA with a real Apple development certificate so it can
# be installed with AltStore / Sideloadly / a paid developer account.
#
# Required environment:
#   SIGN_P12           base64 of the .p12 certificate + private key
#   SIGN_P12_PASSWORD  password for the .p12
#   SIGN_PROFILE       base64 of the .mobileprovision
set -euo pipefail

IPA="${1:?usage: sign.sh <input.ipa> <output.ipa>}"
OUT="${2:?usage: sign.sh <input.ipa> <output.ipa>}"

: "${SIGN_P12:?SIGN_P12 is not set}"
: "${SIGN_P12_PASSWORD:?SIGN_P12_PASSWORD is not set}"
: "${SIGN_PROFILE:?SIGN_PROFILE is not set}"

OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> importing certificate"
printf '%s' "$SIGN_P12" | base64 --decode > "$WORK/cert.p12"
printf '%s' "$SIGN_PROFILE" | base64 --decode > "$WORK/profile.mobileprovision"

security cms -D -i "$WORK/profile.mobileprovision" > "$WORK/profile.plist"
/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$WORK/profile.plist" > "$WORK/entitlements.plist"

KC="$WORK/sign.keychain-db"
KCPASS="$(openssl rand -hex 16)"
security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p "$KCPASS" "$KC"
security import "$WORK/cert.p12" -k "$KC" -P "$SIGN_P12_PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null

IDENTITY="$(security find-identity -v -p codesigning "$KC" | awk 'NR==1 {print $2}')"
if [ -z "$IDENTITY" ]; then
    echo "::error::the p12 contains no usable codesigning identity"
    exit 1
fi
echo "    identity: $IDENTITY"

echo "==> unpacking"
mkdir -p "$WORK/app"
unzip -q "$IPA" -d "$WORK/app"
APP="$(find "$WORK/app/Payload" -maxdepth 1 -name '*.app' -print -quit)"
[ -n "$APP" ] || { echo "::error::no .app inside the IPA"; exit 1; }

cp -f "$WORK/profile.mobileprovision" "$APP/embedded.mobileprovision"

echo "==> signing nested code"
if [ -d "$APP/Frameworks" ]; then
    while IFS= read -r fw; do
        codesign -f -s "$IDENTITY" --timestamp=none "$fw"
    done < <(find "$APP/Frameworks" -maxdepth 1 -name '*.framework' -o -maxdepth 1 -name '*.dylib')
fi

if [ -d "$APP/PlugIns" ]; then
    while IFS= read -r ext; do
        codesign -f -s "$IDENTITY" --entitlements "$WORK/entitlements.plist" --timestamp=none "$ext"
    done < <(find "$APP/PlugIns" -maxdepth 1 -name '*.appex')
fi

echo "==> signing app"
codesign -f -s "$IDENTITY" --entitlements "$WORK/entitlements.plist" --timestamp=none "$APP"

if ! codesign --verify --deep --strict "$APP"; then
    echo "::warning::codesign verification reported problems; the IPA was still produced"
fi

echo "==> packaging"
rm -f "$OUT"
( cd "$WORK/app" && zip -qry "$OUT" Payload )
echo "signed: $OUT"
