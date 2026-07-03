import Foundation

/// Thin wrapper over `Process` — run a binary, optionally capture stdout.
enum Shell {
    @discardableResult
    static func run(_ executable: String, _ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
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

    static func output(_ executable: String, _ args: [String], cwd: URL? = nil) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
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

    /// Run a process and deliver stdout **line by line** as it arrives (for
    /// `--output-format stream-json`). Blocks until the process exits, so call
    /// it off the main thread. `onLine` is invoked on this calling thread.
    static func stream(
        _ executable: String, _ args: [String], cwd: URL? = nil,
        onLine: (String) -> Void
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
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

        var buffer = Data()
        while case let chunk = handle.availableData, !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                if let line = String(data: lineData, encoding: .utf8) { onLine(line) }
            }
        }
        process.waitUntilExit()
        if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) { onLine(line) }
    }
}
