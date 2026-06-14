#!/usr/bin/env bash
set -euo pipefail

# Build LLimit.app from the command line — no Xcode GUI required.
#
# Usage:
#   scripts/build.sh [--version X.Y.Z] [--build N] [--configuration Release]
#                    [--output DIR] [--no-dmg]
#
# Signing (all optional, via environment variables):
#   DEVELOPMENT_TEAM        Apple Developer team id (e.g. ABCDE12345)
#   CODE_SIGN_IDENTITY      e.g. "Developer ID Application: Your Name (ABCDE12345)"
#       -> when both are set, a Developer ID-signed, hardened-runtime build is made.
#       -> otherwise an ad-hoc signed build is produced (runs locally only).
#
# Notarization (optional — requires a Developer ID-signed build + these vars):
#   NOTARY_APPLE_ID         Apple ID email
#   NOTARY_PASSWORD         app-specific password (https://appleid.apple.com)
#   NOTARY_TEAM_ID          team id for notarization (defaults to DEVELOPMENT_TEAM)
#
# Output: dist/LLimit.app, dist/LLimit-<version>.zip, dist/LLimit-<version>.dmg

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$ROOT"

CONFIGURATION="Release"
SCHEME="LLimitApp"
PROJECT="LLimit.xcodeproj"
OUTPUT_DIR="$ROOT/dist"
DERIVED="$ROOT/build"
VERSION=""
BUILD_NUMBER=""
MAKE_DMG=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --build) BUILD_NUMBER="$2"; shift 2 ;;
    --configuration) CONFIGURATION="$2"; shift 2 ;;
    --output) OUTPUT_DIR="$2"; shift 2 ;;
    --no-dmg) MAKE_DMG=0; shift ;;
    -h|--help) sed -n '3,30p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

command -v xcodebuild >/dev/null 2>&1 || { echo "error: xcodebuild not found (run on macOS)"; exit 1; }
command -v xcodegen   >/dev/null 2>&1 || { echo "error: xcodegen required: brew install xcodegen"; exit 1; }

# Default the version from project.yml if not supplied.
if [[ -z "$VERSION" ]]; then
  VERSION="$(awk -F': ' '/MARKETING_VERSION:/{gsub(/[" ]/,"",$2); print $2; exit}' project.yml)"
fi
VERSION="${VERSION:-0.0.0}"

echo "==> Generating Xcode project"
xcodegen generate

# Assemble code-signing settings.
SIGN_FLAGS=("CODE_SIGN_STYLE=Manual")
SIGNED=0
if [[ -n "${CODE_SIGN_IDENTITY:-}" && -n "${DEVELOPMENT_TEAM:-}" ]]; then
  echo "==> Signing with Developer ID: ${CODE_SIGN_IDENTITY}"
  SIGN_FLAGS+=(
    "CODE_SIGN_IDENTITY=${CODE_SIGN_IDENTITY}"
    "DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}"
    "ENABLE_HARDENED_RUNTIME=YES"
  )
  SIGNED=1
else
  echo "==> No Developer ID provided — building ad-hoc signed (local use only)"
  SIGN_FLAGS+=(
    "CODE_SIGN_IDENTITY=-"
    "DEVELOPMENT_TEAM="
    "CODE_SIGNING_REQUIRED=NO"
    "CODE_SIGNING_ALLOWED=YES"
    "AD_HOC_CODE_SIGNING_ALLOWED=YES"
  )
fi

echo "==> Building LLimit ${VERSION} (${CONFIGURATION})"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$VERSION" \
  ${BUILD_NUMBER:+CURRENT_PROJECT_VERSION="$BUILD_NUMBER"} \
  "${SIGN_FLAGS[@]}" \
  clean build

APP_SRC="$DERIVED/Build/Products/$CONFIGURATION/LLimit.app"
if [[ ! -d "$APP_SRC" ]]; then
  echo "error: built app not found at $APP_SRC" >&2
  exit 1
fi

echo "==> Collecting artifacts in $OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR/LLimit.app"
cp -R "$APP_SRC" "$OUTPUT_DIR/LLimit.app"
APP="$OUTPUT_DIR/LLimit.app"

# Notarize + staple when requested and possible.
if [[ "$SIGNED" -eq 1 && -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
  TEAM_ID="${NOTARY_TEAM_ID:-${DEVELOPMENT_TEAM}}"
  echo "==> Notarizing with notarytool (team ${TEAM_ID})"
  NOTARY_ZIP="$OUTPUT_DIR/notarize.zip"
  ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
  xcrun notarytool submit "$NOTARY_ZIP" \
    --apple-id "$NOTARY_APPLE_ID" \
    --password "$NOTARY_PASSWORD" \
    --team-id "$TEAM_ID" \
    --wait
  xcrun stapler staple "$APP"
  rm -f "$NOTARY_ZIP"
else
  echo "==> Skipping notarization (need Developer ID + NOTARY_* env vars)"
fi

ZIP="$OUTPUT_DIR/LLimit-${VERSION}.zip"
echo "==> Packaging zip: $ZIP"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

if [[ "$MAKE_DMG" -eq 1 ]]; then
  DMG="$OUTPUT_DIR/LLimit-${VERSION}.dmg"
  echo "==> Packaging dmg: $DMG"
  rm -f "$DMG"
  hdiutil create -volname "LLimit" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null
fi

echo ""
echo "Done. Artifacts in $OUTPUT_DIR:"
ls -1 "$OUTPUT_DIR"
if [[ "$SIGNED" -eq 0 ]]; then
  echo ""
  echo "NOTE: ad-hoc build. macOS Gatekeeper will block it when downloaded."
  echo "      Run locally with:  xattr -dr com.apple.quarantine '$APP'"
  echo "      For distribution, set DEVELOPMENT_TEAM + CODE_SIGN_IDENTITY (+ NOTARY_*)."
fi
