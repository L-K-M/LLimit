#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
  echo "StepFun browser isolation tests require macOS and Xcode." >&2
  exit 1
fi

build_mode=build
if [[ "${1:-}" == --skip-build ]]; then
  build_mode=reuse
  shift
fi
if (( $# > 1 )); then
  echo "Usage: $0 [--skip-build] [DerivedData directory]" >&2
  exit 1
fi
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${1:-${TMPDIR:-/tmp}/LLimit-StepFunLoginTests}"
mkdir -p "$build_dir"
build_dir="$(cd "$build_dir" && pwd)"
if [[ "$build_mode" == build ]]; then
  if ! xcodebuild -project "$repo_root/LLimit.xcodeproj" -scheme LLimitApp \
    -destination 'platform=macOS' -derivedDataPath "$build_dir" \
    CODE_SIGNING_ALLOWED=NO build > "$build_dir/stepfun-build.log" 2>&1; then
    tail -60 "$build_dir/stepfun-build.log" >&2
    exit 1
  fi
fi
products="$build_dir/Build/Products/Debug"
xcrun swiftc -parse-as-library -swift-version 5 \
  -target "$(uname -m)-apple-macos14.0" -I "$products" \
  "$repo_root/LLimitApp/Services/StepFunLoginSession.swift" \
  "$repo_root/scripts/tests/StepFunLoginTests.swift" "$products/QuotaCore.o" \
  -framework AppKit -framework WebKit -o "$build_dir/stepfun-login-tests"
"$build_dir/stepfun-login-tests"
