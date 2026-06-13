import Foundation

/// `ash update`: the ONLY networked feature in the tool, and only because the
/// user typed it. It checks GitHub for a newer signed release and, unless asked
/// to only `--check`, verifies the download's signature and Team ID before
/// atomically replacing the installed binary. There is deliberately no automatic
/// or background version check anywhere - that would betray the privacy promise.
enum Updater {

    private static let repo = "dboeke/ash-cli"
    private static let teamID = "3K58XWDQRF"
    private static let assetSuffix = "-macos-arm64.zip"

    enum UpdateError: Error {
        case network(String)   // could not reach / download
        case message(String)   // a clear, user-facing failure
        case permission(String) // target path not writable
    }

    struct Release {
        let version: String
        let assetURL: URL
    }

    // MARK: - GitHub API

    private struct GHRelease: Decodable {
        let tag_name: String
        let assets: [GHAsset]
    }
    private struct GHAsset: Decodable {
        let name: String
        let browser_download_url: String
    }

    /// Fetch the latest release: its version (tag minus a leading `v`) and the
    /// macOS arm64 asset URL.
    static func latest() async throws -> Release {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw UpdateError.message("internal error: bad API URL.")
        }
        var req = URLRequest(url: url)
        req.setValue("ash-cli", forHTTPHeaderField: "User-Agent")  // GitHub requires a UA
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw UpdateError.network("could not reach GitHub to check for updates.")
        }
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.network("could not reach GitHub to check for updates.")
        }
        guard let rel = try? JSONDecoder().decode(GHRelease.self, from: data) else {
            throw UpdateError.message("could not parse the GitHub release response.")
        }
        let version = rel.tag_name.hasPrefix("v") ? String(rel.tag_name.dropFirst()) : rel.tag_name
        guard let asset = rel.assets.first(where: { $0.name.hasSuffix(assetSuffix) }),
              let assetURL = URL(string: asset.browser_download_url) else {
            throw UpdateError.message("the latest release has no \(assetSuffix) asset.")
        }
        return Release(version: version, assetURL: assetURL)
    }

    /// True if `candidate` is a strictly higher version than `current`, comparing
    /// dot-separated components numerically (so 0.1.10 > 0.1.2).
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Download, verify, replace

    /// Download the asset zip into `workDir`, unzip it with `ditto`, and return
    /// the extracted `ash` binary's URL.
    private static func downloadAndExtract(_ url: URL, into workDir: URL) async throws -> URL {
        var req = URLRequest(url: url)
        req.setValue("ash-cli", forHTTPHeaderField: "User-Agent")

        let tmpFile: URL, resp: URLResponse
        do {
            (tmpFile, resp) = try await URLSession.shared.download(for: req)
        } catch {
            throw UpdateError.network("could not download the update.")
        }
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.network("could not download the update.")
        }

        let zipPath = workDir.appendingPathComponent("ash.zip")
        try? FileManager.default.removeItem(at: zipPath)
        try FileManager.default.moveItem(at: tmpFile, to: zipPath)

        let extractDir = workDir.appendingPathComponent("extract")
        // Foundation has no native unzip; `ditto` is what release.sh uses.
        let unzip = shell("/usr/bin/ditto", ["-x", "-k", zipPath.path, extractDir.path])
        guard unzip.status == 0 else {
            throw UpdateError.message("could not unzip the download.")
        }
        let binary = extractDir.appendingPathComponent("ash")
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw UpdateError.message("the download did not contain an ash binary.")
        }
        return binary
    }

    /// Verify the downloaded binary BEFORE it is allowed near the install path:
    /// the signature must be valid and the Team ID must match. A bad mirror, a
    /// MITM, or a compromised release cannot get past this.
    private static func verify(_ binary: URL) throws {
        _ = shell("/usr/bin/xattr", ["-dr", "com.apple.quarantine", binary.path])  // belt and braces

        let valid = shell("/usr/bin/codesign", ["--verify", "--strict", binary.path])
        guard valid.status == 0 else {
            throw UpdateError.message("the downloaded binary failed signature verification; not installing.")
        }
        let info = shell("/usr/bin/codesign", ["-dvvv", binary.path])
        guard info.out.contains("TeamIdentifier=\(teamID)") else {
            throw UpdateError.message("the downloaded binary is not signed by the expected developer; not installing.")
        }
    }

    /// Atomically replace the installed binary: stage the verified binary in the
    /// SAME directory (so `rename(2)` is atomic on one filesystem), then rename
    /// over the target. The running process keeps its old inode; the next run is
    /// the new version.
    private static func replace(target: String, with newBinary: URL) throws {
        let dir = (target as NSString).deletingLastPathComponent
        let staged = "\(dir)/.ash.update.\(UUID().uuidString)"
        do {
            try? FileManager.default.removeItem(atPath: staged)
            try FileManager.default.copyItem(atPath: newBinary.path, toPath: staged)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged)
        } catch {
            try? FileManager.default.removeItem(atPath: staged)
            throw UpdateError.permission(target)
        }
        if rename(staged, target) != 0 {
            let e = errno
            try? FileManager.default.removeItem(atPath: staged)
            if e == EACCES || e == EPERM { throw UpdateError.permission(target) }
            throw UpdateError.message("could not replace \(target): \(String(cString: strerror(e))).")
        }
    }

    // MARK: - Install path / Homebrew

    /// The real path of the running binary, with symlinks resolved, so we replace
    /// the actual file and not a symlink.
    private static func installedPath() -> String? {
        guard let exec = Bundle.main.executablePath else { return nil }
        var buf = [Int8](repeating: 0, count: Int(PATH_MAX))
        if let resolved = realpath(exec, &buf) { return String(cString: resolved) }
        return exec
    }

    /// Homebrew-managed binaries live under a `Cellar` directory. Self-replacing
    /// one would desync brew's records, so we refuse and defer to `brew upgrade`.
    private static func isHomebrewManaged(_ resolvedTarget: String) -> Bool {
        resolvedTarget.contains("/Cellar/")
    }

    // MARK: - Orchestration

    /// Run the update flow. Returns a process exit code.
    static func run(check: Bool, currentVersion: String) async -> Int32 {
        let release: Release
        do {
            release = try await latest()
        } catch let UpdateError.network(m) { err("ash: \(m)"); return 1 }
          catch let UpdateError.message(m) { err("ash: \(m)"); return 1 }
          catch { err("ash: could not reach GitHub to check for updates."); return 1 }

        print("current: \(currentVersion)")
        print("latest:  \(release.version)")

        guard isNewer(release.version, than: currentVersion) else {
            print(Style.green("already up to date (\(currentVersion))."))
            return 0
        }
        if check {
            print("run `ash update` to install \(release.version).")
            return 0
        }

        guard let target = installedPath() else {
            err("ash: could not locate the installed ash binary to update.")
            return 1
        }
        if isHomebrewManaged(target) {
            err("ash: ash was installed with Homebrew; run `brew upgrade ash` instead.")
            return 1
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ash-update-\(UUID().uuidString)")
        var keepWorkDir = false
        defer { if !keepWorkDir { try? FileManager.default.removeItem(at: workDir) } }

        let binary: URL
        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            print("downloading \(release.version)...")
            binary = try await downloadAndExtract(release.assetURL, into: workDir)
            try verify(binary)
        } catch let UpdateError.network(m) { err("ash: \(m)"); return 1 }
          catch let UpdateError.message(m) { err("ash: \(m)"); return 1 }
          catch { err("ash: update failed: \(error)"); return 1 }

        do {
            try replace(target: target, with: binary)
        } catch UpdateError.permission {
            // Keep the verified binary around so the manual install command works.
            keepWorkDir = true
            err("ash: cannot write to \(target) (no permission).")
            err("ash: the verified binary is at \(binary.path)")
            err("ash: install it yourself with:")
            err("  sudo install -m 0755 \(binary.path) \(target)")
            return 1
        } catch let UpdateError.message(m) { err("ash: \(m)"); return 1 }
          catch { err("ash: update failed: \(error)"); return 1 }

        print(Style.green("updated to \(release.version)."))
        return 0
    }

    // MARK: - Process helper

    /// Run a tool and capture combined stdout+stderr (codesign writes its detail
    /// to stderr) plus the exit status.
    @discardableResult
    private static func shell(_ launchPath: String, _ args: [String]) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
