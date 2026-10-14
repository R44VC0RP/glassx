#!/usr/bin/env bash
# Builds a Developer ID–signed, notarized and stapled GlassX release in dist/.
#
# Required environment:
#   SIGN_IDENTITY       e.g. "Developer ID Application: Your Name (TEAMID)"
#   NOTARY_KEY          contents of an App Store Connect API key (.p8)
#   NOTARY_KEY_ID       the key's ID
#   NOTARY_ISSUER       the key's issuer ID
# Optional:
#   VERSION             defaults to CFBundleShortVersionString in project.yml
set -euo pipefail
cd "$(dirname "$0")/.."

: "${SIGN_IDENTITY:?set SIGN_IDENTITY}"
: "${NOTARY_KEY:?set NOTARY_KEY}"
: "${NOTARY_KEY_ID:?set NOTARY_KEY_ID}"
: "${NOTARY_ISSUER:?set NOTARY_ISSUER}"

VERSION="${VERSION:-$(grep -E 'CFBundleShortVersionString' project.yml | sed -E 's/.*"(.*)".*/\1/')}"
DIST="dist"
DERIVED="build/release"
APP="$DERIVED/Build/Products/Release/GlassX.app"

KEY_FILE="$(mktemp -t glassx-notary).p8"
trap 'rm -f "$KEY_FILE"' EXIT
umask 077
printf '%s\n' "$NOTARY_KEY" > "$KEY_FILE"

notarize() {
  xcrun notarytool submit "$1" --key "$KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" \
    --wait --timeout 30m --output-format json | tee "$DIST/notary-$(basename "$1").json"
  python3 - "$DIST/notary-$(basename "$1").json" <<'PY'
import json, sys
status = json.load(open(sys.argv[1])).get("status")
print("notarization:", status)
sys.exit(0 if status == "Accepted" else 1)
PY
}

echo "==> Building GlassX $VERSION"
rm -rf "$DIST" "$DERIVED"
mkdir -p "$DIST"
xcodegen generate --quiet
xcodebuild -project GlassX.xcodeproj -scheme GlassX -configuration Release -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM= \
  OTHER_CODE_SIGN_FLAGS="--timestamp" ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  clean build -quiet 2>&1 | grep -E "error:" || true
[ -d "$APP" ] || { echo "error: build failed" >&2; exit 1; }

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Authority=Developer ID|Timestamp|flags=.*runtime"
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then
  echo "error: release build still has get-task-allow" >&2; exit 1
fi

echo "==> Packaging DMG"
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/GlassX.app"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/GlassX-$VERSION.dmg"
hdiutil create -volname "GlassX" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null 2>&1
rm -rf "$STAGE"
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"

echo "==> Notarizing (this can take a few minutes)"
notarize "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler staple "$APP"

echo "==> Packaging zip"
ZIP="$DIST/GlassX-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Gatekeeper check"
spctl --assess --type execute -vv "$APP"
spctl --assess --type open --context context:primary-signature -vv "$DMG"

(cd "$DIST" && shasum -a 256 "GlassX-$VERSION.dmg" "GlassX-$VERSION.zip" > SHA256SUMS.txt)
echo "==> Done"
ls -la "$DIST"
