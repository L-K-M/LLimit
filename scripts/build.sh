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
exec "$BIN" "$@"
