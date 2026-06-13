# Releasing ash

Two distribution paths. The Homebrew path needs no signing and is the
recommended way for users to install. The signed-binary path is for people who
download a release artifact directly.

## 1. Homebrew (recommended, no signing needed)

A binary compiled on the user's own machine is never quarantined by Gatekeeper,
so building from source through Homebrew sidesteps the "downloaded from the
internet" problem entirely.

### One-time tap setup

1. Create a public GitHub repo named `dboeke/homebrew-tap`.
2. Copy `packaging/homebrew/ash.rb` into it at `Formula/ash.rb`.

Users then install with:

```sh
brew install dboeke/tap/ash
```

### Per release

1. Tag and push a version, e.g. `v0.1.0`:
   ```sh
   git tag v0.1.0 && git push origin v0.1.0
   ```
2. Get the tarball checksum:
   ```sh
   curl -sL https://github.com/dboeke/ash-cli/archive/refs/tags/v0.1.0.tar.gz | shasum -a 256
   ```
3. In the tap's `Formula/ash.rb`, update `url` to the new tag and set `sha256`
   to that checksum. Commit and push the tap.

### Later: homebrew-core

Once ash has meaningful adoption (homebrew-core expects a notable, stable
project), it can be submitted to `homebrew/core` so `brew install ash` works
with no tap. The formula is essentially the one in `packaging/homebrew`.

## 2. Signed and notarized direct download

For users who grab a binary from the GitHub Releases page rather than Homebrew,
the artifact must be signed and notarized or macOS will block it.

### One-time setup

1. Join the Apple Developer Program ($99/year). This is required to obtain a
   **Developer ID Application** certificate; there is no way to produce a
   Gatekeeper-trusted binary without it.
2. In Xcode or the Developer portal, create and install a "Developer ID
   Application" certificate. Confirm it is present:
   ```sh
   security find-identity -v -p codesigning
   ```
3. Store notarization credentials once as a keychain profile:
   ```sh
   xcrun notarytool store-credentials ash-notary \
     --apple-id you@example.com --team-id TEAMID \
     --password <app-specific-password>
   ```
   Create the app-specific password at appleid.apple.com.

### Each release

```sh
export ASH_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export ASH_NOTARY_PROFILE="ash-notary"
make release-signed VERSION=0.1.0
```

This builds, signs with the hardened runtime, notarizes, and writes
`dist/ash-0.1.0-macos-arm64.zip` plus its SHA-256. Upload the zip to the GitHub
release.

Without `ASH_SIGN_IDENTITY` set, the script still builds and zips, but the
result is unsigned and will be quarantined when downloaded. Use that only for
local testing.

### Note on stapling

A bare CLI binary cannot have a notarization ticket stapled to it (stapling
targets `.app`, `.pkg`, and `.dmg`). After notarization, Gatekeeper verifies the
binary online the first time it runs, so it is not blocked. For fully offline
trust, wrap the binary in a notarized `.pkg`. That is a future enhancement.

## Requirements recap

- Apple Silicon Mac, macOS 26+, Apple Intelligence enabled (runtime).
- Swift 6 toolchain (build).
- Apple Developer Program membership (only for the signed direct-download path).
