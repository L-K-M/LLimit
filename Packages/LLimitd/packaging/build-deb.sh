#!/usr/bin/env bash
# Builds llimit_<version>_amd64.deb from a prebuilt llimit binary.
#
# Usage:
#   packaging/build-deb.sh <version> [path-to-llimit]
#
# The binary is expected to be the fully static musl build:
#
#   swift sdk install <static-linux SDK>   # once
#   swift build -c release --swift-sdk x86_64-swift-linux-musl --package-path Packages/LLimitd
#
# which runs with no Swift runtime and no library dependencies at all, so the
# .deb needs nothing beyond a kernel and (for TLS) ca-certificates.
#
# Writing the license notices needs python3 plus the Swift toolchain and static
# Linux SDK that built the binary (set SWIFT_SDK_SBOM to the SDK's
# sbom.spdx.json if the lookup below cannot find it).
#
# Layout produced:
#   /usr/bin/llimit                      the binary (stripped when `strip` is available)
#   /usr/lib/systemd/user/llimit*.service|.timer   user units, ExecStart=/usr/bin/llimit
#   /usr/share/llimit/examples/          waybar/polybar/eww module examples
#   /usr/share/doc/llimit/               README, copyright, Third-Party-Notices.txt
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
BINARY="${2:-$ROOT/.build/x86_64-swift-linux-musl/release/llimit}"
OUT_DIR="${3:-$ROOT/.build}"

if [[ ! -x "$BINARY" ]]; then
  echo "llimit binary not found or not executable: $BINARY" >&2
  echo "Build it first:" >&2
  echo "  swift build -c release --swift-sdk x86_64-swift-linux-musl --package-path Packages/LLimitd" >&2
  exit 1
fi

# A tag or package label must match the binary users actually run.
if ! REPORTED_VERSION="$("$BINARY" --version)"; then
  echo "cannot read llimit binary version" >&2
  exit 1
fi
if [[ ! "$REPORTED_VERSION" =~ ^llimit[[:space:]]([^[:space:]]+) ]]; then
  echo "unrecognized llimit binary version" >&2
  exit 1
fi
BINARY_VERSION="${BASH_REMATCH[1]}"
VERSION="${VERSION:-$BINARY_VERSION}"
if [[ "$VERSION" != "$BINARY_VERSION" ]]; then
  echo "package version $VERSION does not match llimit $BINARY_VERSION; stamp and rebuild first" >&2
  exit 1
fi

# Debian versions must start with a digit.
if [[ ! "$VERSION" =~ ^[0-9] ]]; then
  echo "version must start with a digit (got: $VERSION)" >&2
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Binary (stripped when possible — the static build carries ~100 MB of symbols).
install -D -m 0755 "$BINARY" "$STAGE/usr/bin/llimit"
if command -v strip >/dev/null 2>&1; then
  strip "$STAGE/usr/bin/llimit" || true
fi

# systemd user units. The repo's units target ~/.local/bin (manual installs);
# the packaged ones run the packaged binary.
for unit in llimit.service llimit-refresh.service llimit-refresh.timer llimit-tray.service; do
  install -D -m 0644 /dev/null "$STAGE/usr/lib/systemd/user/$unit"
  sed 's|%h/.local/bin/llimit|/usr/bin/llimit|' "$ROOT/systemd/$unit" \
    > "$STAGE/usr/lib/systemd/user/$unit"
done

# Tray icon (Python/PyGObject — see README "Tray icon"). Kept out of the binary
# because the tray protocol is D-Bus and Swift has no binding for it.
install -D -m 0644 "$ROOT/tray/llimit_tray.py" "$STAGE/usr/share/llimit/tray/llimit_tray.py"
for icon in "$ROOT"/tray/icons/*.svg; do
  install -D -m 0644 "$icon" "$STAGE/usr/share/llimit/tray/icons/$(basename "$icon")"
done
# Wrapper so the unit and the user both just run `llimit-tray`. The script
# defaults its icon directory to <script dir>/icons, which is correct here.
install -D -m 0755 /dev/null "$STAGE/usr/bin/llimit-tray"
cat > "$STAGE/usr/bin/llimit-tray" <<'WRAPPER'
#!/bin/sh
# LLimit tray icon launcher.
#
# /usr/bin/python3 explicitly, not `python3` off PATH: the GTK bindings come
# from the distro (python3-gi), so they are only importable by the distro
# interpreter. A pyenv/conda python3 earlier on PATH would fail to load the
# compiled _gi module built for a different minor version.
exec /usr/bin/python3 /usr/share/llimit/tray/llimit_tray.py "$@"
WRAPPER
chmod 0755 "$STAGE/usr/bin/llimit-tray"

# Bar examples and docs.
mkdir -p "$STAGE/usr/share/llimit" "$STAGE/usr/share/doc/llimit"
cp -r "$ROOT/examples" "$STAGE/usr/share/llimit/examples"
install -m 0644 "$ROOT/README.md" "$STAGE/usr/share/doc/llimit/README.md"

# License notices for what the static SDK links into the binary: curl,
# BoringSSL, ICU, musl, zlib and the Swift runtime. The generators fail on a
# missing license text; packaging/licenses/README.md lists the sources.
REPO_ROOT="$(cd "$ROOT/../.." && pwd)"
DOC="$STAGE/usr/share/doc/llimit"
# runtimeResourcePath is <prefix>/usr/lib/swift, so the runtime's license is
# <prefix>/usr/share/swift/LICENSE.txt. "Swift version 6.2.3
# (swift-6.2.3-RELEASE)" names the sources and the matching static SDK.
SWIFT_INFO="$(swift -print-target-info)"
SWIFT_RESOURCES="$(python3 -c 'import json, sys; print(json.load(sys.stdin)["paths"]["runtimeResourcePath"])' <<<"$SWIFT_INFO")"
SWIFT_TAG="$(python3 -c 'import json, re, sys; print(re.search(r"\((swift-[^)]+)\)", json.load(sys.stdin)["compilerVersion"]).group(1))' <<<"$SWIFT_INFO")"
SWIFT_VERSION="${SWIFT_TAG#swift-}"
SWIFT_VERSION="${SWIFT_VERSION%-RELEASE}"
if [[ -z "${SWIFT_SDK_SBOM:-}" ]]; then
  mapfile -t sboms < <(find "$HOME/.swiftpm/swift-sdks" "$HOME/.config/swiftpm/swift-sdks" \
    -path "*/${SWIFT_TAG}_static-linux-*.artifactbundle/sbom.spdx.json" 2>/dev/null)
  if [[ ${#sboms[@]} -ne 1 ]]; then
    echo "expected one $SWIFT_TAG static Linux SDK SBOM, found ${#sboms[@]}; set SWIFT_SDK_SBOM" >&2
    exit 1
  fi
  SWIFT_SDK_SBOM="${sboms[0]}"
fi
export SWIFT_LICENSE="$SWIFT_RESOURCES/../../share/swift/LICENSE.txt" SWIFT_TAG SWIFT_VERSION SWIFT_SDK_SBOM
# Third-Party-Notices.txt also fails when the SDK's SBOM lists a library or
# version that packaging/licenses/notices.json does not cover.
python3 -I "$REPO_ROOT/scripts/swiftpm-notices.py" --title llimit \
  --overrides "$ROOT/packaging/licenses/notices.json" --output "$DOC/Third-Party-Notices.txt"
python3 -I "$REPO_ROOT/scripts/deb-copyright.py" generate "$ROOT/packaging/licenses/components.json" \
  --copyright-out "$DOC/copyright"
python3 -I "$REPO_ROOT/scripts/deb-copyright.py" check "$DOC/copyright" --no-common-licenses
# Compare both files with what the stripped binary links, so an SDK change that
# adds a library or bumps curl, zlib or ICU fails here instead of shipping stale
# notices. LLVM's exception waives attribution for libunwind in binaries.
for notices in Third-Party-Notices.txt copyright; do
  python3 -I "$REPO_ROOT/scripts/static-runtime-notices.py" check "$STAGE/usr/bin" --notices "$DOC/$notices" \
    --allow 'libunwind=Apache-2.0 WITH LLVM-exception, no attribution required'
done
chmod 0644 "$DOC/copyright" "$DOC/Third-Party-Notices.txt"

mkdir -p "$STAGE/DEBIAN"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: llimit
Version: $VERSION
Section: utils
Priority: optional
Architecture: amd64
Maintainer: L-K-M <https://github.com/L-K-M/LLimit>
Recommends: ca-certificates
Suggests: python3-gi, gir1.2-ayatanaappindicator3-0.1
Description: LLM subscription quota tracking for Linux status bars
 llimit tracks remaining LLM subscription quota (Claude, ChatGPT, Copilot,
 Zhipu, Z.ai, Kimi, Antigravity) and exposes it to status bars. Ships a refresh
 daemon with systemd user units, an account-management CLI, ready-made
 waybar/polybar/eww modules driven by 'llimit status --json', and an optional
 tray icon with a per-limit popup.
 .
 Enable the daemon after installing:
   systemctl --user enable --now llimit.service
 Then see /usr/share/llimit/examples for your bar.
 .
 The tray icon is optional and needs GTK, so its dependencies are only
 suggested — the daemon and bar modules have none:
   sudo apt install python3-gi gir1.2-ayatanaappindicator3-0.1
   systemctl --user enable --now llimit-tray.service
EOF

DEB="$OUT_DIR/llimit_${VERSION}_amd64.deb"
mkdir -p "$OUT_DIR"
dpkg-deb --build --root-owner-group "$STAGE" "$DEB"
echo "Built $DEB"
