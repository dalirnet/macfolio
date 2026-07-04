import Foundation

/// One turn's token usage, reported by the CLI's final `result` message.
/// `inputTokens` is the *new* (uncached) input — it excludes the CLI's cached
/// system prompt + tool schemas (~25k, sent every turn), which would otherwise
/// dwarf the real usage.
struct AgentUsage: Equatable {
    var inputTokens: Int
    var outputTokens: Int
}

/// Macfolio's single dependency: the Claude Code CLI.
///
/// Macfolio *drives* Claude Code to write: it runs with tools enabled inside the
/// project folder so the agent can create and revise the project's `.md` files.
/// Auth is inherited from the user's already-logged-in `claude` binary — no
/// sign-in of our own. Each project keeps one persistent session (see
/// `SessionStore`) so the agent retains whole-project context across turns.
final class ClaudeService {
    static let shared = ClaudeService()

    private(set) var executablePath: String?

    private init() {}

    // MARK: - Locating the CLI

    /// A launched .app doesn't inherit the shell PATH, so probe these first.
    private static let candidatePaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".claude/local/claude").path,
            home.appendingPathComponent(".local/bin/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude",
        ]
    }()

    /// Locate the `claude` binary, caching it in `executablePath`.
    @discardableResult
    func locate() -> String? {
        let fileManager = FileManager.default

        for path in Self.candidatePaths where fileManager.isExecutableFile(atPath: path) {
            executablePath = path
            return path
        }

        // Fall back to the login shell's PATH (nvm, custom prefixes, etc.).
        let resolved = Shell.output("/bin/zsh", ["-lic", "command -v claude"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !resolved.isEmpty, fileManager.isExecutableFile(atPath: resolved) {
            executablePath = resolved
            return resolved
        }

        executablePath = nil
        return nil
    }

    /// True when the CLI is installed and runnable (`claude --version`).
    func isAvailable() -> Bool {
        guard let path = locate() else { return false }
        return Shell.run(path, ["--version"])
    }

    // MARK: - Running a turn

    /// Run one agent turn inside the project folder, streaming per-step progress
    /// (reading/writing files) via `onStep`. Returns the final reply and the token
    /// usage, and stores the session id for the next turn. `onStep` is called off
    /// the main thread — hop before touching UI.
    func stream(
        _ instruction: String, in project: Project, onStep: @escaping (String) -> Void
    ) async -> (reply: String?, usage: AgentUsage?) {
        guard let path = executablePath ?? locate() else { return (nil, nil) }
        let args = arguments(for: instruction, in: project)

        return await withCheckedContinuation { continuation in
            Task.detached {
                var result: String?
                var usage: AgentUsage?
                Shell.stream(path, args, cwd: project.root) { line in
                    self.handle(
                        line, project: project, onStep: onStep,
                        setResult: { result = $0 }, setUsage: { usage = $0 })
                }
                continuation.resume(returning: (result, usage))
            }
        }
    }

    /// The `claude` CLI arguments for one streaming turn.
    private func arguments(for instruction: String, in project: Project) -> [String] {
        var args = [
            "-p", instruction,
            // Headless `-p` can't answer permission prompts; the default
            // (bypassPermissions) avoids denials on reads/edits in the project.
            "--permission-mode", SettingsStore.shared.permissionMode.rawValue,
            "--output-format", "stream-json",
            "--verbose",  // required with stream-json in print mode
            "--model", SettingsStore.shared.model.rawValue,
        ]
        if let sessionID = SessionStore.shared.session(for: project) {
            args += ["--resume", sessionID]
        }
        return args
    }

    // MARK: - Parsing the stream

    /// Parse one stream-json line: capture the session id, turn tool uses into
    /// human-readable steps, and pick up the final `result` and its token usage.
    private func handle(
        _ line: String, project: Project,
        onStep: (String) -> Void, setResult: (String) -> Void, setUsage: (AgentUsage) -> Void
    ) {
        guard let data = line.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if let sessionID = obj["session_id"] as? String, !sessionID.isEmpty {
            SessionStore.shared.setSession(sessionID, for: project)
        }

        switch obj["type"] as? String {
        case "assistant":
            let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for item in content where item["type"] as? String == "tool_use" {
                onStep(describe(item, project: project))
            }
        case "result":
            if let result = (obj["result"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty
            {
                setResult(result)
            }
            if let usage = obj["usage"] as? [String: Any] {
                setUsage(Self.usage(from: usage))
            }
        default:
            break
        }
    }

    /// Token usage from a result `usage` object. Uses the new (uncached) input —
    /// not the cached system prompt + tools + prior turns — so the shown "in"
    /// reflects the turn's real input, not the fixed ~25k CLI overhead.
    private static func usage(from dict: [String: Any]) -> AgentUsage {
        func count(_ key: String) -> Int { (dict[key] as? NSNumber)?.intValue ?? 0 }
        return AgentUsage(
            inputTokens: count("input_tokens"), outputTokens: count("output_tokens"))
    }

    /// A short "what it's doing now" line from a tool_use block.
    private func describe(_ toolUse: [String: Any], project: Project) -> String {
        let name = toolUse["name"] as? String ?? "tool"
        let input = toolUse["input"] as? [String: Any] ?? [:]
        let path = (input["file_path"] as? String).map { relative($0, to: project) }

        switch name {
        case "Read": return "reading \(path ?? "file")"
        case "Write": return "writing \(path ?? "file")"
        case "Edit", "MultiEdit": return "editing \(path ?? "file")"
        case "Bash": return "run: \((input["command"] as? String ?? "").prefix(48))"
        case "Glob", "Grep": return "searching"
        case "TodoWrite": return "planning"
        default: return name.lowercased()
        }
    }

    /// A path relative to the project root, for compact display.
    private func relative(_ path: String, to project: Project) -> String {
        let root = project.root.path
        guard path.hasPrefix(root) else { return (path as NSString).lastPathComponent }
        return String(path.dropFirst(root.count).drop { $0 == "/" })
    }
}
