#!/usr/bin/env bash
#
# One-command release, run from this Mac. Does everything:
#   1. sets the version in the source (and commits) if needed
#   2. tags and pushes
#   3. builds, signs, and notarizes the binary (via release.sh)
#   4. creates/updates the GitHub release with the signed zip
#   5. updates the Homebrew tap formula (url + source checksum) and pushes it
#
# Prereqs: Developer ID cert in your keychain, an `ash-notary` notarytool
# profile (see RELEASING.md), the `gh` CLI authenticated, and a local clone of
# the tap (default: a sibling `homebrew-tap` dir; override with ASH_TAP_DIR).
#
# Usage: scripts/publish.sh <version>     e.g. scripts/publish.sh 0.2.0

set -euo pipefail

VERSION="${1:?usage: publish.sh <version>  e.g. publish.sh 0.2.0}"
REPO="dboeke/ash-cli"
TAG="v$VERSION"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAP_DIR="${ASH_TAP_DIR:-$(cd "$ROOT/.." && pwd)/homebrew-tap}"
export ASH_SIGN_IDENTITY="${ASH_SIGN_IDENTITY:-Developer ID Application: David Boeke (3K58XWDQRF)}"
export ASH_NOTARY_PROFILE="${ASH_NOTARY_PROFILE:-ash-notary}"

cd "$ROOT"

# Working tree must be clean so a release is a known commit.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree is not clean. Commit or stash first." >&2
  exit 1
fi

echo "==> [1/5] Setting version to $VERSION"
if ! grep -q "let version = \"$VERSION\"" Sources/ash/main.swift; then
  sed -i '' "s/let version = \"[^\"]*\"/let version = \"$VERSION\"/" Sources/ash/main.swift
  git add Sources/ash/main.swift
  git commit -q -m "Release $TAG"
  git push -q origin main
  echo "    bumped and committed"
else
  echo "    already at $VERSION"
fi

echo "==> [2/5] Tagging $TAG"
git rev-parse "$TAG" >/dev/null 2>&1 || git tag -a "$TAG" -m "ash $VERSION"
git push -q origin "$TAG"

echo "==> [3/5] Building, signing, notarizing"
"$ROOT/scripts/release.sh" "$VERSION"
ZIP="dist/ash-$VERSION-macos-arm64.zip"

echo "==> [4/5] Publishing GitHub release"
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$ZIP" --clobber -R "$REPO"
else
  gh release create "$TAG" "$ZIP" -R "$REPO" --title "ash $VERSION" --generate-notes
fi

echo "==> [5/5] Updating Homebrew tap"
SRC_URL="https://github.com/$REPO/archive/refs/tags/$TAG.tar.gz"
SRC_SHA="$(curl -sL "$SRC_URL" | shasum -a 256 | awk '{print $1}')"
if [[ -d "$TAP_DIR/.git" ]]; then
  sed -i '' -E "s|archive/refs/tags/v[0-9.]+\.tar\.gz|archive/refs/tags/$TAG.tar.gz|" "$TAP_DIR/Formula/ash.rb"
  sed -i '' -E "s|sha256 \"[a-f0-9]+\"|sha256 \"$SRC_SHA\"|" "$TAP_DIR/Formula/ash.rb"
  git -C "$TAP_DIR" add Formula/ash.rb
  git -C "$TAP_DIR" commit -q -m "ash $VERSION"
  git -C "$TAP_DIR" push -q
  echo "    tap updated and pushed ($TAP_DIR)"
else
  echo "    tap clone not found at $TAP_DIR (set ASH_TAP_DIR)."
  echo "    update Formula/ash.rb manually: url -> $TAG, sha256 -> $SRC_SHA"
fi

echo
echo "Released $TAG"
echo "  GitHub:   https://github.com/$REPO/releases/tag/$TAG"
echo "  Homebrew: brew install dboeke/tap/ash"
