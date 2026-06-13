import Foundation
import Darwin

/// Wire format exchanged over the unix socket, one JSON object per line.
private struct WireRequest: Codable {
    let request: String
    let context: String
}
private struct WireResponse: Codable {
    var plan: Plan?
    var tokens: Int?
    var error: String?
}

/// A persistent background process holding a warm model session, plus the
/// client logic that talks to it (and spawns it on demand).
enum Daemon {

    static let socketPath = Config.socketPath
    static var pidPath: String { Config.dir.appendingPathComponent("ashd.pid").path }
    static var lockPath: String { Config.dir.appendingPathComponent("ashd.lock").path }

    // Held open for the daemon's whole lifetime; the OS releases the flock when
    // the process dies, so it doubles as a robust "is a daemon alive?" signal.
    nonisolated(unsafe) private static var lockFD: Int32 = -1

    // MARK: - Server

    /// Run the daemon: detach, warm the model, and serve requests until idle.
    /// Invoked as `ash __daemon`.
    static func serve() async -> Never {
        setsid()  // detach from the controlling terminal

        try? FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true)

        // Exactly one daemon may own the socket. Take the lock first; if another
        // daemon already holds it (a startup race), exit before touching anything.
        guard acquireLock() else { exit(0) }

        unlink(socketPath)  // clear any stale socket

        let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { exit(1) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: 104) { p in
                    strncpy(p, src, 103)
                }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, size) }
        }
        guard bindResult == 0 else { exit(1) }
        guard listen(listenFD, 8) == 0 else { exit(1) }

        // Record our pid so `ash daemon stop/status` can find us.
        try? "\(getpid())".write(toFile: pidPath, atomically: true, encoding: .utf8)

        // Pay the one-time model load now so the first client request is warm.
        Interpreter.warmUp()

        // Idle timeout in minutes from config; 0 means never exit on idle.
        let idleMinutes = Config.load().daemonTimeout

        while true {
            var readSet = fd_set()
            fdZero(&readSet)
            fdSet(listenFD, &readSet)
            let ready: Int32
            if idleMinutes > 0 {
                var tv = timeval(tv_sec: idleMinutes * 60, tv_usec: 0)
                ready = select(listenFD + 1, &readSet, nil, nil, &tv)
            } else {
                ready = select(listenFD + 1, &readSet, nil, nil, nil)  // block until a connection
            }
            if ready == 0 { break }            // idle timeout reached -> shut down
            if ready < 0 { continue }

            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 { continue }
            await handle(clientFD)
            close(clientFD)
        }

        unlink(socketPath)
        unlink(pidPath)
        exit(0)
    }

    /// Take the exclusive, non-blocking lock. Returns false if another process
    /// holds it. On success the fd is kept open for the process lifetime.
    private static func acquireLock() -> Bool {
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return false }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        lockFD = fd  // intentionally never closed; released by the OS on exit
        return true
    }

    /// Ensure a daemon is running, returning immediately. Safe to call from
    /// shell startup on every new terminal: it's a near-instant no-op when a
    /// daemon already exists, and the daemon-side lock prevents duplicates if
    /// several terminals open at once.
    static func launch() {
        try? FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true)
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        // If we can't take the lock, a daemon is already running or starting.
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { return }
        // Lock is free -> no daemon. Release it and spawn one (which re-takes it).
        flock(fd, LOCK_UN)
        try? spawn()
    }

    /// Stop a running daemon, if any.
    static func stop() {
        if let s = try? String(contentsOfFile: pidPath, encoding: .utf8),
           let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(pid, SIGTERM)
        }
        unlink(socketPath)
        unlink(pidPath)
    }

    private static func handle(_ fd: Int32) async {
        guard let line = readLine(fd),
              let data = line.data(using: .utf8),
              let req = try? JSONDecoder().decode(WireRequest.self, from: data) else {
            return
        }
        var resp = WireResponse()
        do {
            let interp = try await Interpreter.plan(for: req.request, context: req.context)
            resp.plan = interp.plan
            resp.tokens = interp.tokens
        } catch {
            resp.error = "\(error)"
        }
        if let out = try? JSONEncoder().encode(resp) {
            writeAll(fd, out)
            writeAll(fd, Data([0x0A]))  // newline terminator
        }
    }

    // MARK: - Client

    /// Ask the daemon for a Plan, spawning it if it isn't already running.
    static func requestPlan(request: String, context: String) async throws -> Interpretation {
        var fd = connect()
        if fd < 0 {
            try spawn()
            fd = try waitForConnect(timeout: 15)
        }
        defer { close(fd) }

        let wire = WireRequest(request: request, context: context)
        let payload = try JSONEncoder().encode(wire)
        writeAll(fd, payload)
        writeAll(fd, Data([0x0A]))

        guard let line = readLine(fd),
              let data = line.data(using: .utf8) else {
            throw DaemonError.noResponse
        }
        let resp = try JSONDecoder().decode(WireResponse.self, from: data)
        if let err = resp.error { throw DaemonError.remote(err) }
        guard let plan = resp.plan else { throw DaemonError.noResponse }
        return Interpretation(plan: plan, tokens: resp.tokens)
    }

    enum DaemonError: Error, CustomStringConvertible {
        case noResponse
        case remote(String)
        case spawnFailed
        var description: String {
            switch self {
            case .noResponse: return "no response from daemon"
            case .remote(let s): return s
            case .spawnFailed: return "could not start daemon"
            }
        }
    }

    /// Try to connect to the daemon socket. Returns a connected fd, or -1.
    private static func connect() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: 104) { p in
                    strncpy(p, src, 103)
                }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, size)
            }
        }
        if result != 0 { close(fd); return -1 }
        return fd
    }

    private static func waitForConnect(timeout: Double) throws -> Int32 {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            let fd = connect()
            if fd >= 0 { return fd }
            usleep(100_000)  // 100ms
        }
        throw DaemonError.spawnFailed
    }

    /// Launch `ash __daemon` as a detached background process.
    private static func spawn() throws {
        guard let exe = Bundle.main.executablePath else { throw DaemonError.spawnFailed }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = ["__daemon"]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        // Do not wait; it detaches via setsid() on its own.
    }

    // MARK: - Socket I/O helpers

    private static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var p = raw.bindMemory(to: UInt8.self).baseAddress!
            var remaining = data.count
            while remaining > 0 {
                let n = Darwin.write(fd, p, remaining)
                if n <= 0 { break }
                p += n
                remaining -= n
            }
        }
    }

    /// Read bytes up to and including the next newline; returns the line without it.
    private static func readLine(_ fd: Int32) -> String? {
        var buffer = [UInt8]()
        var byte: UInt8 = 0
        while true {
            let n = Darwin.read(fd, &byte, 1)
            if n <= 0 { break }
            if byte == 0x0A { break }
            buffer.append(byte)
        }
        if buffer.isEmpty { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }
}

// MARK: - fd_set helpers (Swift can't index the C fd_set tuple directly)

private func fdZero(_ set: inout fd_set) {
    set = fd_set()
}
private func fdSet(_ fd: Int32, _ set: inout fd_set) {
    let offset = Int(fd) / 32
    let mask = Int32(1 << (Int(fd) % 32))
    withUnsafeMutablePointer(to: &set.fds_bits) { ptr in
        ptr.withMemoryRebound(to: Int32.self, capacity: 32) { bits in
            bits[offset] |= mask
        }
    }
}
