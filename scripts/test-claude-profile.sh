#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
  echo "Claude terminal integration tests require macOS and Xcode." >&2
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
build_dir="${1:-${TMPDIR:-/tmp}/LLimit-ClaudeProfileTests}"
mkdir -p "$build_dir"
build_dir="$(cd "$build_dir" && pwd)"

# Build the production app first, reusing these exact package modules and objects.
# A standalone harness avoids adding a host-app test target solely for PTY tests.
if [[ "$build_mode" == build ]]; then
  if ! xcodebuild -project "$repo_root/LLimit.xcodeproj" -scheme LLimitApp \
    -configuration Debug -destination 'platform=macOS' -derivedDataPath "$build_dir" \
    CODE_SIGNING_ALLOWED=NO build > "$build_dir/claude-profile-build.log" 2>&1; then
    tail -80 "$build_dir/claude-profile-build.log" >&2
    exit 1
  fi
fi

products="$build_dir/Build/Products/Debug"
if [[ ! -f "$products/SwiftTerm.o" || ! -f "$products/QuotaCore.o" ]]; then
  echo "Missing Debug package objects. Build the app before using --skip-build." >&2
  exit 1
fi
xcrun swiftc -parse-as-library -swift-version 5 \
  -target "$(uname -m)-apple-macos14.0" -I "$products" \
  "$repo_root/LLimitApp/Services/ClaudeTerminalSession.swift" \
  "$repo_root/scripts/tests/ClaudeTerminalTests.swift" \
  "$products/SwiftTerm.o" "$products/QuotaCore.o" \
  -o "$build_dir/claude-terminal-tests"
"$build_dir/claude-terminal-tests"
