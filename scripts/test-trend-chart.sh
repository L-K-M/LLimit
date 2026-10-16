#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
  echo "Trend chart rendering tests require macOS and Xcode." >&2
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
build_dir="${1:-${TMPDIR:-/tmp}/LLimit-TrendChartTests}"
mkdir -p "$build_dir"
build_dir="$(cd "$build_dir" && pwd)"

if [[ "$build_mode" == build ]]; then
  if ! xcodebuild -project "$repo_root/LLimit.xcodeproj" -scheme LLimitApp \
    -configuration Debug -destination 'platform=macOS' -derivedDataPath "$build_dir" \
    CODE_SIGNING_ALLOWED=NO build > "$build_dir/trend-chart-build.log" 2>&1; then
    tail -80 "$build_dir/trend-chart-build.log" >&2
    exit 1
  fi
fi

products="$build_dir/Build/Products/Debug"
if [[ ! -f "$products/QuotaCore.o" ]]; then
  echo "Missing Debug package objects. Build the app before using --skip-build." >&2
  exit 1
fi
# Compile the fixture in the view's file scope without widening private UI APIs.
cat "$repo_root/LLimitWidgetExtension/LLimitQuotaWidget.swift" \
  "$repo_root/scripts/tests/TrendChartRenderTests.swift" > "$build_dir/TrendChartRenderTests.swift"
xcrun swiftc -parse-as-library -swift-version 5 \
  -target "$(uname -m)-apple-macos14.0" -I "$products" \
  -module-cache-path "$build_dir/TrendChartModuleCache" \
  "$repo_root/Shared/SharedConstants.swift" \
  "$repo_root/Shared/LimitKindColorScheme.swift" \
  "$repo_root/LLimitWidgetExtension/QuotaTimelineProvider.swift" \
  "$build_dir/TrendChartRenderTests.swift" \
  "$products/QuotaCore.o" -o "$build_dir/trend-chart-tests"
"$build_dir/trend-chart-tests" "$build_dir"
