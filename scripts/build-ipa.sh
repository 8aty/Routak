#!/bin/bash
# Builds Routak.ipa for sideloading with AltStore.
#
#   scripts/build-ipa.sh <version> <build-number> [output-dir]
#
# The app is built unsigned, then ad-hoc signed with the entitlements it needs (App Group only),
# so AltStore can see them and re-sign the app with the user's own Apple ID.
# iCloud is compiled out (SIDELOAD): personal Apple IDs can't use it.
set -euo pipefail

VERSION="${1:?version, e.g. 1.2.0}"
BUILD="${2:?build number, e.g. 7}"
OUT="${3:-dist}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/sideload"

cd "$ROOT"
rm -rf "$WORK"
mkdir -p "$WORK" "$OUT"

xcodebuild \
  -project Routak.xcodeproj \
  -target Routak \
  -configuration Release \
  -sdk iphoneos \
  SYMROOT="$WORK" \
  OBJROOT="$WORK/obj" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS="SIDELOAD" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build | tail -n 5

APP="$WORK/Release-iphoneos/Routak.app"
test -d "$APP/PlugIns/RoutakWidgets.appex"

# Sign the extension first, then the app around it.
codesign --force --sign - --entitlements Config/RoutakWidgets.entitlements "$APP/PlugIns/RoutakWidgets.appex"
codesign --force --sign - --entitlements Config/Routak-Sideload.entitlements "$APP"

mkdir -p "$WORK/ipa/Payload"
cp -R "$APP" "$WORK/ipa/Payload/"
(cd "$WORK/ipa" && zip -qry "$ROOT/$OUT/Routak.ipa" Payload)

PLIST="$APP/Info.plist"
echo "Built $OUT/Routak.ipa: version $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST") ($(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")), $(stat -f%z "$OUT/Routak.ipa") bytes"
