#!/usr/bin/env bash
set -euo pipefail

# Cut a release: bump the version, commit, tag and push.
# Pushing the tag triggers .github/workflows/release.yml, which builds the app
# and publishes a GitHub Release with the .zip and .dmg attached.
#
# Usage:
#   scripts/release.sh <version>          e.g. scripts/release.sh 0.2.1
#   scripts/release.sh <version> --local  also build locally first (no publish)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
LOCAL_BUILD=0
[[ "${2:-}" == "--local" ]] && LOCAL_BUILD=1

if [[ -z "$VERSION" ]]; then
  echo "usage: scripts/release.sh <version> [--local]   e.g. scripts/release.sh 0.2.1" >&2
  exit 2
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must be semver X.Y.Z (got '$VERSION')" >&2
  exit 2
fi

TAG="v${VERSION}"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree is not clean — commit or stash first" >&2
  exit 1
fi
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "error: tag $TAG already exists" >&2
  exit 1
fi

# Bump MARKETING_VERSION and increment CURRENT_PROJECT_VERSION (build number) in project.yml.
CURRENT_BUILD="$(awk -F': ' '/CURRENT_PROJECT_VERSION:/{gsub(/[" ]/,"",$2); print $2; exit}' project.yml)"
NEXT_BUILD=$(( ${CURRENT_BUILD:-0} + 1 ))

# BSD sed (macOS) in-place edit.
sed -i '' -E "s/(MARKETING_VERSION: ).*/\1${VERSION}/" project.yml
sed -i '' -E "s/(CURRENT_PROJECT_VERSION: ).*/\1${NEXT_BUILD}/" project.yml

echo "==> Version ${VERSION} (build ${NEXT_BUILD})"

if [[ "$LOCAL_BUILD" -eq 1 ]]; then
  echo "==> Local build"
  "${SCRIPT_DIR}/build.sh" --version "$VERSION" --build "$NEXT_BUILD"
fi

git add project.yml
git commit -m "Release ${TAG}"
git tag -a "$TAG" -m "LLimit ${TAG}"

echo "==> Pushing branch and tag"
git push origin HEAD
git push origin "$TAG"

echo ""
echo "Pushed ${TAG}. The release workflow will build and publish it at:"
echo "  https://github.com/L-K-M/LLimit/releases/tag/${TAG}"
