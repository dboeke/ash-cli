#!/usr/bin/env bash
#
# Build, sign, notarize, and package ash for distribution as a GitHub release.
#
# Prerequisites (see RELEASING.md):
#   - An Apple Developer Program membership and a "Developer ID Application"
#     certificate installed in your login keychain.
#   - A notarytool keychain profile created once with:
#       xcrun notarytool store-credentials ash-notary \
#         --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PW
#
# Configure via environment:
#   ASH_SIGN_IDENTITY  "Developer ID Application: Your Name (TEAMID)"
#   ASH_NOTARY_PROFILE notarytool keychain profile name (default: ash-notary)
#
# Usage: scripts/release.sh <version>     e.g. scripts/release.sh 0.1.0

set -euo pipefail

VERSION="${1:?usage: release.sh <version>}"
SIGN_IDENTITY="${ASH_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${ASH_NOTARY_PROFILE:-ash-notary}"

DIST="dist"
BIN=".build/release/ash"
ZIP="$DIST/ash-$VERSION-macos-arm64.zip"

echo "==> Building release (arm64)"
swift build -c release --arch arm64
mkdir -p "$DIST"

if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "!! ASH_SIGN_IDENTITY is not set: producing an UNSIGNED build."
  echo "!! Unsigned binaries downloaded from the web are quarantined by Gatekeeper."
  echo "!! Set up a Developer ID certificate (see RELEASING.md) to sign + notarize."
  ditto -c -k --keepParent "$BIN" "$ZIP"
  shasum -a 256 "$ZIP"
  exit 0
fi

echo "==> Code signing with: $SIGN_IDENTITY"
# Hardened runtime + secure timestamp are required for notarization.
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$BIN"
codesign --verify --strict --verbose=2 "$BIN"

echo "==> Packaging $ZIP"
ditto -c -k --keepParent "$BIN" "$ZIP"

echo "==> Notarizing (this can take a few minutes)"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

# A bare CLI binary cannot be stapled (stapling targets .app/.pkg/.dmg). After
# notarization, Gatekeeper validates the binary online on first run, so it runs
# without the "unidentified developer" block. For fully offline trust, ship a
# notarized .pkg instead (a future enhancement; noted in RELEASING.md).

echo "==> Done"
shasum -a 256 "$ZIP"
echo "Artifact: $ZIP"
