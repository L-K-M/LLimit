#!/usr/bin/env bash
# Builds LLimit.app from the command line and reveals it in Finder on success.
# Incremental Release build by default; --clean resets wedged Xcode build daemons and
# wipes build/ first. Signed with the project's team (dev mode) so the embedded widget
# extension registers and can read the shared App Group container. Add --dmg/--zip to
# package distributables under dist/. Thin stub for the shared lkm-build engine.
#
# Usage: scripts/build.sh [--clean] [--debug] [--run] [--install] [--zip] [--dmg]
#                         [--app-version X.Y.Z]
# Shared engine: https://github.com/L-K-M/release-tool (this stub only sets config).
set -euo pipefail
export BUILD_APP_NAME="LLimit"
export BUILD_KIND="xcode"
export BUILD_XCODE_PROJECT="LLimit.xcodeproj"
export BUILD_XCODE_SCHEME="LLimitApp"
export BUILD_PRODUCT_NAME="LLimit"
export BUILD_SIGN_MODE="dev"
export BUILD_INVOKED_AS="scripts/build.sh"
BIN="${LKM_BUILD_BIN:-lkm-build}"
command -v "$BIN" >/dev/null 2>&1 || {
  echo "error: lkm-build not found — clone https://github.com/L-K-M/release-tool and run ./install.sh" >&2
  exit 1
}

INSTALL=false
for argument in "$@"; do
  if [[ "$argument" == "--install" ]]; then
    INSTALL=true
    break
  fi
done

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
PLUGINKIT="/usr/bin/pluginkit"
INSTALLED_APP="/Applications/$BUILD_APP_NAME.app"
INSTALLED_WIDGET="$INSTALLED_APP/Contents/PlugIns/LLimitWidgetExtension.appex"
WIDGET_BUNDLE_ID="ch.lkmc.llimit.app.widgetextension"
if [[ "$INSTALL" == true && -x "$LSREGISTER" ]]; then
  # Remove the old installed registration before replacement so PlugInKit never
  # observes a partially copied app, then remove stale intermediate products.
  if [[ -x "$PLUGINKIT" && -d "$INSTALLED_WIDGET" ]]; then
    "$PLUGINKIT" -r "$INSTALLED_WIDGET" >/dev/null 2>&1 || true
  fi
  "$LSREGISTER" -u -R "$INSTALLED_APP" >/dev/null 2>&1 || true
  "$LSREGISTER" -u -R "$PWD/build/Build/Products/Release/$BUILD_APP_NAME.app" >/dev/null 2>&1 || true
  "$LSREGISTER" -u -R "$PWD/build/Build/Products/Debug/$BUILD_APP_NAME.app" >/dev/null 2>&1 || true
fi

"$BIN" "$@"

if [[ "$INSTALL" == true && -x "$LSREGISTER" && -d "$INSTALLED_APP" ]]; then
  INTENT_METADATA="$INSTALLED_WIDGET/Contents/Resources/Metadata.appintents/extract.actionsdata"
  if [[ ! -f "$INTENT_METADATA" ]] \
    || ! /usr/bin/grep -q 'ProviderQuotaIntent' "$INTENT_METADATA"; then
    echo "error: installed widget is missing required App Intent metadata" >&2
    exit 1
  fi

  APP_BUILD=$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$INSTALLED_APP/Contents/Info.plist")
  WIDGET_BUILD=$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$INSTALLED_WIDGET/Contents/Info.plist")
  if [[ "$APP_BUILD" != "$WIDGET_BUILD" ]]; then
    echo "error: app build $APP_BUILD does not match widget build $WIDGET_BUILD" >&2
    exit 1
  fi

  /usr/bin/codesign --verify --deep --strict "$INSTALLED_APP"
  if ! /usr/bin/codesign -d --entitlements :- "$INSTALLED_WIDGET" 2>&1 \
    | /usr/bin/grep -q 'com.apple.security.app-sandbox'; then
    echo "error: installed widget is missing the App Sandbox entitlement" >&2
    exit 1
  fi

  "$LSREGISTER" -u -R "$PWD/build/Build/Products/Release/$BUILD_APP_NAME.app" >/dev/null 2>&1 || true
  "$LSREGISTER" -u -R "$PWD/build/Build/Products/Debug/$BUILD_APP_NAME.app" >/dev/null 2>&1 || true
  "$LSREGISTER" -u -R "$INSTALLED_APP" >/dev/null 2>&1 || true
  if [[ -x "$PLUGINKIT" ]]; then
    "$PLUGINKIT" -r "$INSTALLED_WIDGET" >/dev/null 2>&1 || true
  fi
  "$LSREGISTER" -f -R -trusted "$INSTALLED_APP"
  if [[ -x "$PLUGINKIT" ]]; then
    "$PLUGINKIT" -a "$INSTALLED_WIDGET"
    "$PLUGINKIT" -e use -i "$WIDGET_BUNDLE_ID"
  fi
  killall chronod >/dev/null 2>&1 || true

  echo "Registered $WIDGET_BUNDLE_ID build $WIDGET_BUILD from $INSTALLED_WIDGET"
  if [[ -x "$PLUGINKIT" ]]; then
    "$PLUGINKIT" -mAvvv -p com.apple.widgetkit-extension -i "$WIDGET_BUNDLE_ID"
  fi
fi
