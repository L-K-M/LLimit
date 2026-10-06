#!/usr/bin/env bash
# Checks the menu bar panel resize geometry. The geometry is plain Foundation,
# so this compiles it standalone without building the app.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/LLimit-PanelGeometryTests.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT

swiftc=(swiftc)
if [[ "$(uname -s)" == Darwin ]]; then
  swiftc=(xcrun swiftc -target "$(uname -m)-apple-macos14.0")
fi

"${swiftc[@]}" -parse-as-library -swift-version 5 \
  -module-cache-path "$build_dir/ModuleCache" \
  "$repo_root/LLimitApp/MenuBarPanelGeometry.swift" \
  "$repo_root/scripts/tests/MenuBarPanelGeometryTests.swift" \
  -o "$build_dir/panel-geometry-tests"
"$build_dir/panel-geometry-tests"
