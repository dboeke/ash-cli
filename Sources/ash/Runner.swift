import Foundation

/// Side-effecting helpers: running a shell command and copying to the clipboard.
enum Runner {

    /// Runs a command via `/bin/zsh -c` in the current working directory,
    /// streaming stdout/stderr straight through to the terminal. Returns the
    /// process exit code.
    @discardableResult
    static func execute(_ command: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        // Inherit the parent's stdio so output appears live and colors survive.
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            FileHandle.standardError.write(Data("ash: failed to run command: \(error)\n".utf8))
            return 127
        }
    }

    /// Read a single keypress from the terminal (no Enter needed), with echo
    /// off. Returns nil if stdin is not a terminal or the read fails.
    static func readKey() -> Character? {
        guard isatty(STDIN_FILENO) == 1 else { return nil }
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }
        var raw = original
        raw.c_lflag &= ~(tcflag_t(ICANON) | tcflag_t(ECHO))
        withUnsafeMutablePointer(to: &raw.c_cc) { p in
            p.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
                cc[Int(VMIN)] = 1
                cc[Int(VTIME)] = 0
            }
        }
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        defer { tcsetattr(STDIN_FILENO, TCSANOW, &original) }
        var byte: UInt8 = 0
        guard read(STDIN_FILENO, &byte, 1) == 1 else { return nil }
        return Character(UnicodeScalar(byte))
    }

    /// Copies text to the macOS clipboard via pbcopy.
    static func copyToClipboard(_ text: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        let pipe = Pipe()
        process.standardInput = pipe
        do {
            try process.run()
            pipe.fileHandleForWriting.write(Data(text.utf8))
            pipe.fileHandleForWriting.closeFile()
            process.waitUntilExit()
        } catch {
            // Clipboard is best-effort; ignore failures.
        }
    }
}
