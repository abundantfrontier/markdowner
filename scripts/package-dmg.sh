#!/usr/bin/env bash
# Build a Release Markdowner.app and wrap it in a drag-to-Applications DMG.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Markdowner"
SCHEME="Markdowner"
CONFIGURATION="Release"
DERIVED_DATA="${ROOT}/build"
DIST="${ROOT}/dist"
STAGE="${DIST}/dmg-stage"
VERSION="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "${ROOT}/Markdowner/Info.plist" 2>/dev/null || echo "1.0"
)"
DMG_NAME="${APP_NAME}-${VERSION}"
DMG_PATH="${DIST}/${DMG_NAME}.dmg"
APP_PATH="${DERIVED_DATA}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"

echo "==> Building ${APP_NAME} (${CONFIGURATION})…"
xcodebuild \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -derivedDataPath "${DERIVED_DATA}" \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=NO \
  build

if [[ ! -d "${APP_PATH}" ]]; then
  echo "error: app not found at ${APP_PATH}" >&2
  exit 1
fi

echo "==> Ad-hoc signing ${APP_NAME}.app…"
codesign --force --deep --sign - "${APP_PATH}"

echo "==> Staging DMG contents…"
rm -rf "${STAGE}"
mkdir -p "${STAGE}"
ditto "${APP_PATH}" "${STAGE}/${APP_NAME}.app"
ln -sf /Applications "${STAGE}/Applications"

echo "==> Creating ${DMG_PATH}…"
mkdir -p "${DIST}"
rm -f "${DMG_PATH}"
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${STAGE}" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "${DMG_PATH}"

rm -rf "${STAGE}"
cp -f "${DMG_PATH}" "${DIST}/${APP_NAME}.dmg"

SIZE="$(du -h "${DMG_PATH}" | awk '{print $1}')"
echo ""
echo "Done."
echo "  App:  ${APP_PATH}"
echo "  DMG:  ${DMG_PATH}  (${SIZE})"
echo "  Also: ${DIST}/${APP_NAME}.dmg"
echo ""
echo "Note: This DMG is ad-hoc signed (not notarized)."
echo "On another Mac, Gatekeeper may require right-click → Open the first time."
echo "For public distribution, sign with a Developer ID and notarize with notarytool."
