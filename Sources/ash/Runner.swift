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
