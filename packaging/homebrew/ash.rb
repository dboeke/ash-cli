# Homebrew formula for ash, building from source.
#
# Building locally means the binary is never quarantined by Gatekeeper, so it
# runs immediately with no "downloaded from the internet" prompt and no signing
# required.
#
# Distribute this via a tap repo named `dboeke/homebrew-tap`: place this file at
# `Formula/ash.rb` in that repo, then users install with:
#   brew install dboeke/tap/ash
#
# For each release, update `url` to the new tag tarball and set `sha256` to its
# checksum (`shasum -a 256 <tarball>`).

class Ash < Formula
  desc "Agentic shell: natural-language commands via on-device Apple Intelligence"
  homepage "https://github.com/dboeke/ash-cli"
  url "https://github.com/dboeke/ash-cli/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "REPLACE_WITH_TARBALL_SHA256"
  license "MIT"
  head "https://github.com/dboeke/ash-cli.git", branch: "main"

  depends_on xcode: :build
  depends_on arch: :arm64
  # Requires macOS 26+ with Apple Intelligence at runtime. ash prints a clear
  # message and exits if the on-device model is unavailable, so the OS minimum
  # is enforced at runtime rather than risking a stale Homebrew version symbol.

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release", "--arch", "arm64"
    bin.install ".build/release/ash"
  end

  test do
    assert_match "ash", shell_output("#{bin}/ash --version")
  end
end
