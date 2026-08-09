import Foundation

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
final class ClaudeService: AgentService {
    static let shared = ClaudeService()

    private(set) var executablePath: String?

    private init() {}

    // MARK: - Session (delegated to the persistent per-project session)

    func hasSession(for project: Project) -> Bool {
        SessionStore.shared.hasSession(for: project)
    }

    func clearSession(for project: Project) {
        SessionStore.shared.clearSession(for: project)
    }

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
        if let executablePath { return executablePath }
        executablePath = Shell.locate("claude", candidates: Self.candidatePaths)
        return executablePath
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
                continuation.yield(
                    .finished(reply: "The Claude Code CLI wasn't found.", usage: nil))
                continuation.finish()
                return
            }
            let box = ProcessBox()

            let worker = Task.detached {
                let resumed = SessionStore.shared.session(for: project)
                var turn = self.attempt(
                    path, instruction: instruction, project: project, resume: resumed, box: box,
                    emit: { continuation.yield($0) })

                // `--resume` fails outright when the stored session's transcript is
                // gone (a cleared `~/.claude` cache, another machine), and it fails
                // before any output — so the project's AI would stay stuck on every
                // future turn. Forget the session and take one fresh run instead.
                if turn.reply == nil, resumed != nil, !Task.isCancelled {
                    SessionStore.shared.clearSession(for: project)
                    turn = self.attempt(
                        path, instruction: instruction, project: project, resume: nil, box: box,
                        emit: { continuation.yield($0) })
                }

                continuation.yield(
                    .finished(reply: turn.reply ?? Self.failure(turn.error), usage: turn.usage))
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

    /// Run the CLI once and collect the turn: the final reply (nil when it produced
    /// none), its token usage, and anything it wrote to stderr.
    private func attempt(
        _ path: String, instruction: String, project: Project, resume: String?, box: ProcessBox,
        emit: @escaping (TurnEvent) -> Void
    ) -> (reply: String?, usage: AgentUsage?, error: String) {
        var result: String?
        var usage: AgentUsage?
        var error = ""
        // Accumulates the last streamed text block, used as the reply when the
        // process is cut short (timeout/cancel) before a `result`.
        var streamed = ""

        Shell.stream(
            path, arguments(for: instruction, in: project, resume: resume), cwd: project.root,
            timeout: Self.turnTimeout,
            onStart: { box.set($0) },
            onError: { error = $0 }
        ) { line in
            self.handle(
                line, project: project,
                emit: { event in
                    switch event {
                    case .replyReset: streamed = ""
                    case .replyDelta(let text): streamed += text
                    default: break
                    }
                    emit(event)
                },
                setResult: { result = $0 }, setUsage: { usage = $0 })
        }

        return (result ?? (streamed.isEmpty ? nil : streamed), usage, error)
    }

    /// The CLI's own complaint, as the reply for a turn that produced nothing —
    /// its last non-empty stderr line, which carries the actual cause.
    private static func failure(_ error: String) -> String? {
        error.split(separator: "\n")
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init)
    }

    /// The `claude` CLI arguments for one streaming turn.
    private func arguments(for instruction: String, in project: Project, resume: String?)
        -> [String]
    {
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
        if let resume { args += ["--resume", resume] }
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
        let path = (input["file_path"] as? String).map {
            project.relativePath(of: URL(fileURLWithPath: $0))
        }

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
}
