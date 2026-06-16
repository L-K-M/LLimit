#!/usr/bin/env bash
set -euo pipefail

# Build LLimit.app from the command line — no Xcode GUI required.
#
# Usage:
#   scripts/build.sh [--version X.Y.Z] [--build N] [--configuration Release]
#                    [--output DIR] [--no-dmg] [--adhoc]
#
# Signing modes (auto-selected):
#   dev (default)   Local development signing with the team in the committed project.
#                   Applies the App Group entitlement, so the WIDGET registers and can
#                   read data. Runs on this Mac only. This is what you want for widgets.
#   developer-id    Set DEVELOPMENT_TEAM + CODE_SIGN_IDENTITY ("Developer ID
#                   Application: …") for a hardened-runtime, distributable, notarizable
#                   build. Add NOTARY_APPLE_ID + NOTARY_PASSWORD (+ NOTARY_TEAM_ID) to
#                   also notarize and staple.
#   adhoc           --adhoc (or no team in the project): unsigned + ad-hoc signed. No
#                   entitlements, so the widget will NOT work — quick smoke test only.
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
FORCE_ADHOC=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --build) BUILD_NUMBER="$2"; shift 2 ;;
    --configuration) CONFIGURATION="$2"; shift 2 ;;
    --output) OUTPUT_DIR="$2"; shift 2 ;;
    --no-dmg) MAKE_DMG=0; shift ;;
    --adhoc) FORCE_ADHOC=1; shift ;;
    -h|--help) sed -n '3,34p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

command -v xcodebuild >/dev/null 2>&1 || { echo "error: xcodebuild not found (run on macOS)"; exit 1; }

# Build the COMMITTED LLimit.xcodeproj as-is — do NOT run `xcodegen generate` here.
# The committed project is the source of truth (it carries the signing team Xcode set
# up); regenerating it from project.yml, which leaves DEVELOPMENT_TEAM blank, would
# wipe that team and break signing. Run scripts/bootstrap.sh by hand only when you
# deliberately change the project's structure in project.yml.

# Default the version from the committed project (the authoritative source) if not given.
if [[ -z "$VERSION" ]]; then
  VERSION="$(awk -F'= ' '/MARKETING_VERSION =/{gsub(/[ ;]/,"",$2); print $2; exit}' "$PROJECT/project.pbxproj")"
fi
VERSION="${VERSION:-0.0.0}"

# The signing team baked into the committed project (used for local dev signing).
DEV_TEAM="${DEVELOPMENT_TEAM:-$(awk -F'= ' '/DEVELOPMENT_TEAM = /{gsub(/[ ;]/,"",$2); if ($2 != "") {print $2; exit}}' "$PROJECT/project.pbxproj")}"

# Pick a signing mode:
#   developer-id  Distribution build (Developer ID + hardened runtime, notarizable).
#                 Used when CODE_SIGN_IDENTITY + DEVELOPMENT_TEAM are both exported.
#   dev           Local development signing with the project's Apple Development team.
#                 IMPORTANT: this applies the app's entitlements (App Group), which is
#                 what creates the shared container the widget reads AND lets macOS
#                 register the widget extension. Default when a team is available.
#   adhoc         Unsigned build, ad-hoc signed afterwards. No entitlements, so the
#                 WIDGET WILL NOT appear/work — use only for a quick smoke test or on a
#                 machine without a signing certificate (--adhoc, or no team available).
MODE="dev"
SIGN_FLAGS=()
EXTRA_FLAGS=()
if [[ -n "${CODE_SIGN_IDENTITY:-}" && -n "${DEVELOPMENT_TEAM:-}" ]]; then
  MODE="developer-id"
elif [[ "$FORCE_ADHOC" -eq 1 || -z "$DEV_TEAM" ]]; then
  MODE="adhoc"
fi

case "$MODE" in
  developer-id)
    echo "==> Signing with Developer ID: ${CODE_SIGN_IDENTITY}"
    SIGN_FLAGS=(
      "CODE_SIGN_STYLE=Manual"
      "CODE_SIGN_IDENTITY=${CODE_SIGN_IDENTITY}"
      "DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}"
      "ENABLE_HARDENED_RUNTIME=YES"
    )
    ;;
  dev)
    echo "==> Local development signing (team ${DEV_TEAM}) — widget-capable"
    # Automatic signing with the project's team applies the entitlements (App Group),
    # so the widget registers and can read data. -allowProvisioningUpdates lets Xcode
    # create/refresh the App ID + App Group profiles on first run.
    SIGN_FLAGS=(
      "CODE_SIGN_STYLE=Automatic"
      "DEVELOPMENT_TEAM=${DEV_TEAM}"
    )
    EXTRA_FLAGS=(-allowProvisioningUpdates)
    ;;
  adhoc)
    echo "==> No team available — building unsigned, then ad-hoc signing (widget will NOT work)"
    SIGN_FLAGS=("CODE_SIGNING_ALLOWED=NO")
    ;;
esac

echo "==> Building LLimit ${VERSION} (${CONFIGURATION})"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED" \
  ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} \
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

# Ad-hoc sign the assembled bundle in adhoc mode (xcodebuild produced it unsigned).
# --deep signs the embedded widget extension and frameworks too; identity "-" is
# ad-hoc. The dev/developer-id modes are already signed (with entitlements) by xcodebuild.
if [[ "$MODE" == "adhoc" ]]; then
  echo "==> Ad-hoc signing $APP"
  codesign --force --deep --sign - "$APP"
fi

# Notarize + staple when requested and possible (Developer ID builds only).
if [[ "$MODE" == "developer-id" && -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
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
case "$MODE" in
  dev)
    echo ""
    echo "NOTE: locally signed (team ${DEV_TEAM}) with entitlements — widgets work on THIS Mac."
    echo "      Move it to /Applications and launch once so the widget appears in the gallery:"
    echo "        cp -R '$APP' /Applications/ && open /Applications/LLimit.app"
    echo "      Not notarized, so it won't run on other Macs (use a Developer ID build for that)."
    ;;
  adhoc)
    echo ""
    echo "NOTE: ad-hoc build — NO entitlements, so the widget will not register and the app"
    echo "      can't read its App Group container. Use a signing team (drop --adhoc) for widgets."
    echo "      Gatekeeper will block it when downloaded: xattr -dr com.apple.quarantine '$APP'"
    ;;
esac
