import Foundation

/// One turn's token usage, reported by the CLI's final `result` message.
/// `inputTokens` is the *new* (uncached) input — it excludes the CLI's cached
/// system prompt + tool schemas (~25k, sent every turn), which would otherwise
/// dwarf the real usage.
struct AgentUsage: Equatable {
    var inputTokens: Int
    var outputTokens: Int
}

/// One update from a running turn, delivered in order over an `AsyncStream`.
enum TurnEvent {
    /// A short "what it's doing now" line (reading/writing a file, searching).
    case step(String)
    /// A new reply text block began — clear any previously streamed live text.
    case replyReset
    /// A chunk of the assistant's reply text, as it's generated.
    case replyDelta(String)
    /// The turn finished: the authoritative final reply and its token usage.
    case finished(reply: String?, usage: AgentUsage?)
}

/// Holds the running `Process` so a cancelled turn can terminate it, coping with
/// the race where cancellation arrives before the process has started.
private final class ProcessBox {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func set(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { process.terminate() } else { self.process = process }
    }

    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        process?.terminate()
    }
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

    /// Hard ceiling on a single turn. Agentic edits can take a while, but a hung
    /// process must eventually release the UI rather than block forever.
    private static let turnTimeout: TimeInterval = 300

    /// Run one agent turn inside the project folder, emitting ordered `TurnEvent`s:
    /// per-step progress (reading/writing files), the reply text as it streams, and
    /// a final `.finished` with the authoritative reply + token usage. The session
    /// id for the next turn is stored as it arrives.
    ///
    /// Consume with `for await`. Cancelling the consuming task (or letting the turn
    /// exceed `turnTimeout`) terminates the underlying CLI process.
    func run(_ instruction: String, in project: Project) -> AsyncStream<TurnEvent> {
        AsyncStream { continuation in
            guard let path = executablePath ?? locate() else {
                continuation.yield(.finished(reply: nil, usage: nil))
                continuation.finish()
                return
            }
            let args = arguments(for: instruction, in: project)
            let box = ProcessBox()

            let worker = Task.detached {
                var result: String?
                var usage: AgentUsage?
                // Accumulates the last streamed text block, used as the reply when
                // the process is cut short (timeout/cancel) before a `result`.
                var streamed = ""
                Shell.stream(
                    path, args, cwd: project.root, timeout: Self.turnTimeout,
                    onStart: { box.set($0) }
                ) { line in
                    self.handle(
                        line, project: project,
                        emit: { event in
                            switch event {
                            case .replyReset: streamed = ""
                            case .replyDelta(let text): streamed += text
                            default: break
                            }
                            continuation.yield(event)
                        },
                        setResult: { result = $0 }, setUsage: { usage = $0 })
                }
                let reply = result ?? (streamed.isEmpty ? nil : streamed)
                continuation.yield(.finished(reply: reply, usage: usage))
                continuation.finish()
            }

            continuation.onTermination = { _ in
                // Fires on normal finish and on cancellation; terminate the process
                // in both cases (a no-op once it has already exited).
                box.terminate()
                worker.cancel()
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
            // Stream the reply token-by-token so it appears as it's written,
            // instead of only after the whole turn finishes.
            "--include-partial-messages",
            "--model", SettingsStore.shared.model.rawValue,
        ]
        if let sessionID = SessionStore.shared.session(for: project) {
            args += ["--resume", sessionID]
        }
        return args
    }

    // MARK: - Parsing the stream

    /// Parse one stream-json line: capture the session id, stream the reply text
    /// as it arrives, turn tool uses into human-readable steps, and pick up the
    /// final `result` and its token usage.
    private func handle(
        _ line: String, project: Project,
        emit: (TurnEvent) -> Void, setResult: (String) -> Void, setUsage: (AgentUsage) -> Void
    ) {
        guard let data = line.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if let sessionID = obj["session_id"] as? String, !sessionID.isEmpty {
            SessionStore.shared.setSession(sessionID, for: project)
        }

        switch obj["type"] as? String {
        case "stream_event":
            // Partial-message events: reply text as it's generated. Thinking
            // (`thinking_delta`) and tool-input deltas are ignored here.
            guard let event = obj["event"] as? [String: Any] else { break }
            switch event["type"] as? String {
            case "content_block_start":
                // A fresh text block: drop any prior live text so only the last
                // block (the final reply) shows, not intermediate commentary.
                if (event["content_block"] as? [String: Any])?["type"] as? String == "text" {
                    emit(.replyReset)
                }
            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any],
                    delta["type"] as? String == "text_delta",
                    let text = delta["text"] as? String
                {
                    emit(.replyDelta(text))
                }
            default:
                break
            }
        case "assistant":
            let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for item in content where item["type"] as? String == "tool_use" {
                emit(.step(describe(item, project: project)))
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
