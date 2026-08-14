#!/bin/bash
# Cuts a release: ./scripts/release.sh 1.2.0
#
# There's no version file to bump — build.sh reads the tag — so this is the
# preflight checks, a smoke build, and the tag push that triggers CI.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
  echo "usage: ./scripts/release.sh <version>   (e.g. 1.2.0)" >&2
  exit 1
fi
TAG="v$VERSION"

BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" != main ]; then
  echo "must be on main (currently on $BRANCH)" >&2
  exit 1
fi

STATUS=$(git status --porcelain)
if [ -n "$STATUS" ]; then
  echo "working tree not clean:" >&2
  echo "$STATUS" >&2
  exit 1
fi

git pull --ff-only
# Explicitly, because a plain pull only brings tags reachable from what it
# fetched — a tag already on origin could otherwise slip through the check
# below and only fail at push time, leaving a stray local tag behind.
git fetch --tags

if [ -n "$(git tag --list "$TAG")" ]; then
  echo "tag $TAG already exists" >&2
  exit 1
fi

# Releasing a version that doesn't compile wastes a tag, and tags are awkward to
# take back once pushed.
echo "==> smoke build"
VERSION="$VERSION" ./build.sh >/dev/null
echo "    ok"

git tag -a "$TAG" -m "$TAG"
git push origin main "$TAG"

echo
echo "released $TAG. watch the build:"
echo "  gh run watch"
