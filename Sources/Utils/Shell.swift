import Foundation

/// Thin wrapper over `Process` — run a binary, optionally capture stdout.
enum Shell {
    /// The environment every child process gets: ours, plus the configured proxy.
    /// A launched `.app` inherits launchd's environment rather than the shell's, so
    /// without this the Claude Code CLI would connect directly — it reads proxy
    /// settings only from these variables.
    private static func environment(_ extra: [String: String] = [:]) -> [String: String] {
        ProcessInfo.processInfo.environment
            .merging(Proxy.environment) { _, new in new }
            .merging(extra) { _, new in new }
    }

    @discardableResult
    static func run(_ executable: String, _ args: [String], cwd: URL? = nil) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = environment()
        if let cwd { process.currentDirectoryURL = cwd }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    static func output(
        _ executable: String, _ args: [String], cwd: URL? = nil, env: [String: String]? = nil
    ) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        process.environment = environment(env ?? [:])
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Locate an executable: try known absolute paths first (a launched `.app`
    /// doesn't inherit the shell PATH), then fall back to the login shell's PATH
    /// (nvm, custom prefixes, …). Returns nil if it's nowhere runnable.
    static func locate(_ command: String, candidates: [String]) -> String? {
        let fileManager = FileManager.default
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return path
        }
        let resolved = output("/bin/zsh", ["-lic", "command -v \(command)"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !resolved.isEmpty && fileManager.isExecutableFile(atPath: resolved) ? resolved : nil
    }

    /// Run a process and deliver stdout **line by line** as it arrives (for
    /// `--output-format stream-json`). Blocks until the process exits, so call
    /// it off the main thread. `onLine` is invoked on this calling thread.
    ///
    /// `onStart` receives the running `Process` so the caller can `terminate()`
    /// it (e.g. to cancel). If `timeout` elapses before the process exits, it is
    /// terminated — a hung turn can't block the reader forever.
    static func stream(
        _ executable: String, _ args: [String], cwd: URL? = nil,
        timeout: TimeInterval? = nil,
        onStart: ((Process) -> Void)? = nil,
        onLine: (String) -> Void
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = environment()
        if let cwd { process.currentDirectoryURL = cwd }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let handle = pipe.fileHandleForReading
        do {
            try process.run()
        } catch {
            return
        }
        onStart?(process)

        // Watchdog: terminate the process if it outlives `timeout`. Terminating
        // closes the pipe, so the read loop below drains and exits.
        var watchdog: DispatchWorkItem?
        if let timeout {
            let item = DispatchWorkItem { process.terminate() }
            watchdog = item
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
        }

        var buffer = Data()
        while case let chunk = handle.availableData, !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                if let line = String(data: lineData, encoding: .utf8) { onLine(line) }
            }
        }
        watchdog?.cancel()
        process.waitUntilExit()
        if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) { onLine(line) }
    }
}
