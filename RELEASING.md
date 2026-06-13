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

## 3. Automated releases (GitHub Actions)

`.github/workflows/release.yml` builds, signs, notarizes, and publishes a
release whenever a `v*` tag is pushed (or via manual `workflow_dispatch`).

### Why it needs a self-hosted runner

GitHub-hosted macOS runners are macOS 14/15 and do not have the macOS 26 SDK
that FoundationModels requires, so they cannot compile ash. You must register an
Apple Silicon Mac running macOS 26 as a self-hosted runner:

1. Repo Settings > Actions > Runners > New self-hosted runner, choose macOS /
   arm64, and follow the configure/run steps on that Mac.
2. The runner machine needs the Swift 6 toolchain (Xcode or Command Line Tools)
   and the `gh` CLI on PATH.

### Required repository secrets

Set these under Settings > Secrets and variables > Actions (or with
`gh secret set NAME`):

| Secret | What it is |
| --- | --- |
| `SIGN_IDENTITY` | `Developer ID Application: David Boeke (3K58XWDQRF)` |
| `DEVELOPER_ID_CERT_P12_BASE64` | Your Developer ID Application cert + private key, exported as `.p12` and base64-encoded |
| `DEVELOPER_ID_CERT_PASSWORD` | The password you set when exporting the `.p12` |
| `KEYCHAIN_PASSWORD` | Any random string; used for the temporary build keychain |
| `NOTARY_API_KEY_BASE64` | App Store Connect API key `.p8`, base64-encoded |
| `NOTARY_API_KEY_ID` | The API key's Key ID |
| `NOTARY_API_ISSUER_ID` | The API key's Issuer ID |

### Generating the secret values

Export the signing certificate (Keychain Access > login > My Certificates >
your Developer ID Application cert > right-click > Export as `.p12`):

```sh
base64 -i DeveloperID.p12 | pbcopy   # paste into DEVELOPER_ID_CERT_P12_BASE64
```

Create an App Store Connect API key (appstoreconnect.apple.com > Users and
Access > Integrations > App Store Connect API). Give it a role that can notarize
(Developer is sufficient), download the `.p8` once, and note its Key ID and
Issuer ID:

```sh
base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy   # paste into NOTARY_API_KEY_BASE64
```

### Cutting a release

```sh
git tag v0.2.0 && git push origin v0.2.0
```

The workflow imports the cert into a throwaway keychain, runs
`scripts/release.sh` (which signs with the hardened runtime and notarizes via
the API key), publishes the release with the signed zip attached, and deletes
the keychain and key afterward. Then update the Homebrew tap formula's `url` and
`sha256` as in section 1.

## Note on pre-release macOS

Homebrew does not support pre-release (beta) macOS versions and labels them a
Tier 2 configuration. On a beta macOS, `brew install` source builds can fail in
Homebrew's build environment even when a plain `swift build` of the same source
succeeds, because Homebrew's explicit-modules build path trips on the beta SDK.
This affects only people running a macOS beta. On stable macOS the source build
through Homebrew works normally. As a fallback on a beta machine, build and
install directly:

```sh
swift build -c release --arch arm64
install -m 0755 .build/release/ash /opt/homebrew/bin/ash
```

## Requirements recap

- Apple Silicon Mac, macOS 26+, Apple Intelligence enabled (runtime).
- Swift 6 toolchain (build).
- Apple Developer Program membership (only for the signed direct-download path).
