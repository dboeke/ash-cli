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

# Package the signed binary into a zip that contains just `ash` at the top level
# (no wrapper directory), so users unzip straight to the executable.
package_zip() {
  local stage
  stage="$(mktemp -d)"
  cp "$BIN" "$stage/ash"
  xattr -c "$stage/ash"   # drop quarantine/provenance xattrs so no ._ash in the zip
  rm -f "$ZIP"
  ditto -c -k --norsrc --noextattr "$stage/ash" "$ZIP"
  rm -rf "$stage"
}

echo "==> Building release (arm64)"
swift build -c release --arch arm64
mkdir -p "$DIST"

if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "!! ASH_SIGN_IDENTITY is not set: producing an UNSIGNED build."
  echo "!! Unsigned binaries downloaded from the web are quarantined by Gatekeeper."
  echo "!! Set up a Developer ID certificate (see RELEASING.md) to sign + notarize."
  package_zip
  shasum -a 256 "$ZIP"
  exit 0
fi

echo "==> Code signing with: $SIGN_IDENTITY"
# Hardened runtime + secure timestamp are required for notarization. In CI,
# ASH_SIGN_KEYCHAIN points codesign at a temporary keychain holding the cert,
# so the login keychain search list is left untouched.
keychain_arg=()
[[ -n "${ASH_SIGN_KEYCHAIN:-}" ]] && keychain_arg=(--keychain "$ASH_SIGN_KEYCHAIN")
codesign --force --options runtime --timestamp "${keychain_arg[@]}" --sign "$SIGN_IDENTITY" "$BIN"
codesign --verify --strict --verbose=2 "$BIN"

echo "==> Packaging $ZIP"
package_zip

echo "==> Notarizing (this can take a few minutes)"
# CI uses an App Store Connect API key (ASH_NOTARY_KEY/_KEY_ID/_ISSUER); local
# runs use a stored keychain profile (ASH_NOTARY_PROFILE).
if [[ -n "${ASH_NOTARY_KEY:-}" ]]; then
  xcrun notarytool submit "$ZIP" \
    --key "$ASH_NOTARY_KEY" --key-id "$ASH_NOTARY_KEY_ID" --issuer "$ASH_NOTARY_ISSUER" --wait
else
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
fi

# A bare CLI binary cannot be stapled (stapling targets .app/.pkg/.dmg). After
# notarization, Gatekeeper validates the binary online on first run, so it runs
# without the "unidentified developer" block. We accept the online check and do
# not ship a .pkg.

echo "==> Done"
shasum -a 256 "$ZIP"
echo "Artifact: $ZIP"
