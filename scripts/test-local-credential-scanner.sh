#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
  echo "Local credential scanner tests require macOS and Xcode." >&2
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
build_dir="${1:-${TMPDIR:-/tmp}/LLimit-LocalCredentialScannerTests}"
mkdir -p "$build_dir"
build_dir="$(cd "$build_dir" && pwd)"
if [[ "$build_mode" == build ]]; then
  if ! xcodebuild -project "$repo_root/LLimit.xcodeproj" -scheme LLimitApp \
    -destination 'platform=macOS' -derivedDataPath "$build_dir" \
    CODE_SIGNING_ALLOWED=NO build > "$build_dir/local-credential-scanner-build.log" 2>&1; then
    tail -60 "$build_dir/local-credential-scanner-build.log" >&2
    exit 1
  fi
fi
products="$build_dir/Build/Products/Debug"
if [[ ! -f "$products/QuotaCore.o" ]]; then
  echo "Missing $products/QuotaCore.o; run once without --skip-build." >&2
  exit 1
fi
xcrun swiftc -parse-as-library -swift-version 5 \
  -target "$(uname -m)-apple-macos14.0" -I "$products" \
  "$repo_root/LLimitApp/Services/LocalCredentialScanner.swift" \
  "$repo_root/scripts/tests/LocalCredentialScannerTests.swift" "$products/QuotaCore.o" \
  -framework Security -o "$build_dir/local-credential-scanner-tests"
"$build_dir/local-credential-scanner-tests"
