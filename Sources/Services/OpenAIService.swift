import Foundation

/// A co-authoring backend for the Claude API and OpenAI, both reached over the
/// same OpenAI-compatible `/chat/completions` shape at fixed endpoints.
///
/// Unlike Claude Code, these endpoints have no file tools of their own, so we host
/// the agentic loop: the model calls our file tools — `list_files`, `read_file`,
/// `write_file`, `edit_file` — against the project folder until it stops and gives
/// a final plain-text reply. Conversation history is kept per project in memory so
/// context carries across turns (the parallel of Claude's persistent session).
final class OpenAIService: AgentService {
    static let shared = OpenAIService()
    private init() {}

    /// Per-project chat history (raw message dicts, minus the system prompt).
    private var histories: [String: [[String: Any]]] = [:]
    private let lock = NSLock()

    /// Bound one turn's tool round-trips and the retained history length.
    private static let maxIterations = 16
    private static let maxHistory = 40
    private static let requestTimeout: TimeInterval = 120

    // Fixed OpenAI-compatible endpoints. Anthropic exposes one for the Claude API.
    private static let claudeBaseURL = "https://api.anthropic.com/v1"
    private static let openAIBaseURL = "https://api.openai.com/v1"

    /// The resolved endpoint, key, and model for the current API provider.
    private struct Config {
        let endpoint: URL
        let key: String
        let model: String
    }

    private func config(_ settings: SettingsStore) -> Config? {
        switch settings.provider {
        case .claudeAPI:
            guard let url = Self.endpoint(Self.claudeBaseURL) else { return nil }
            return Config(
                endpoint: url, key: settings.claudeAPIKey.trimmed, model: settings.model.rawValue)
        case .openAI:
            guard let url = Self.endpoint(Self.openAIBaseURL) else { return nil }
            return Config(
                endpoint: url, key: settings.openAIKey.trimmed, model: settings.openAIModel.rawValue
            )
        case .claudeCode:
            return nil
        }
    }

    // MARK: - Availability / session

    func isAvailable() -> Bool {
        guard let config = config(SettingsStore.shared) else { return false }
        return !config.key.isEmpty
    }

    func hasSession(for project: Project) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !(histories[project.id]?.isEmpty ?? true)
    }

    func clearSession(for project: Project) {
        lock.lock()
        defer { lock.unlock() }
        histories[project.id] = nil
    }

    // MARK: - Running a turn

    func run(_ instruction: String, in project: Project) -> AsyncStream<TurnEvent> {
        AsyncStream { continuation in
            guard let config = config(SettingsStore.shared) else {
                continuation.yield(.finished(reply: "This backend isn't configured.", usage: nil))
                continuation.finish()
                return
            }

            let task = Task {
                do {
                    let (reply, usage) = try await self.loop(
                        endpoint: config.endpoint, key: config.key, model: config.model,
                        instruction: instruction, project: project,
                        emit: { continuation.yield($0) })
                    continuation.yield(.finished(reply: reply, usage: usage))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    let message =
                        (error as? AgentError)?.errorDescription ?? error.localizedDescription
                    continuation.yield(.finished(reply: "Request failed: \(message)", usage: nil))
                    continuation.finish()
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Drive the tool loop: call the endpoint, run any tools it asks for, and loop
    /// until it replies without tools (or we hit the iteration cap). Streams a
    /// `.step` per tool call and the final text as `.replyReset` + `.replyDelta`.
    private func loop(
        endpoint: URL, key: String, model: String, instruction: String, project: Project,
        emit: (TurnEvent) -> Void
    ) async throws -> (String?, AgentUsage?) {
        var messages = beginMessages(instruction: instruction, project: project)
        var usage: AgentUsage?

        for _ in 0..<Self.maxIterations {
            try Task.checkCancellation()
            let completion = try await complete(
                endpoint: endpoint, key: key, model: model, messages: messages)
            usage = completion.usage ?? usage
            messages.append(completion.assistantMessage)

            if completion.toolCalls.isEmpty {
                let text = completion.content?.trimmingCharacters(in: .whitespacesAndNewlines)
                emit(.replyReset)
                if let text, !text.isEmpty { emit(.replyDelta(text)) }
                save(history: messages, for: project)
                return (text, usage)
            }

            for call in completion.toolCalls {
                emit(.step(describe(call)))
                let result = execute(call, project: project)
                messages.append(["role": "tool", "tool_call_id": call.id, "content": result])
            }
        }

        save(history: messages, for: project)
        return ("Stopped after \(Self.maxIterations) tool steps.", usage)
    }

    // MARK: - History

    private func beginMessages(instruction: String, project: Project) -> [[String: Any]] {
        lock.lock()
        let prior = histories[project.id] ?? []
        lock.unlock()

        var messages: [[String: Any]] = [["role": "system", "content": Self.systemPrompt]]
        messages.append(contentsOf: prior)
        messages.append(["role": "user", "content": instruction])
        return messages
    }

    /// Keep a bounded tail (dropping the system prompt), trimmed to start on a
    /// user turn so a dangling `tool` message never leads the next request.
    private func save(history messages: [[String: Any]], for project: Project) {
        var history = messages
        if history.first?["role"] as? String == "system" { history.removeFirst() }
        if history.count > Self.maxHistory {
            history = Array(history.suffix(Self.maxHistory))
            while let first = history.first, first["role"] as? String != "user" {
                history.removeFirst()
            }
        }
        lock.lock()
        histories[project.id] = history
        lock.unlock()
    }

    // MARK: - Networking

    private struct Completion {
        var assistantMessage: [String: Any]
        var content: String?
        var toolCalls: [ToolCall]
        var usage: AgentUsage?
    }

    private struct ToolCall {
        var id: String
        var name: String
        var arguments: [String: Any]
    }

    private func complete(
        endpoint: URL, key: String, model: String, messages: [[String: Any]]
    ) async throws -> Completion {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "tools": Self.tools,
            "tool_choice": "auto",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await Proxy.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentError.message("No response from the endpoint.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AgentError.message(Self.errorText(data, status: http.statusCode))
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = obj["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any]
        else {
            throw AgentError.message("Unexpected response shape.")
        }

        let content = message["content"] as? String
        let rawCalls = message["tool_calls"] as? [[String: Any]] ?? []
        let calls: [ToolCall] = rawCalls.compactMap { call in
            guard let fn = call["function"] as? [String: Any], let name = fn["name"] as? String
            else { return nil }
            let id = call["id"] as? String ?? ""
            let argString = fn["arguments"] as? String ?? "{}"
            let args =
                (try? JSONSerialization.jsonObject(with: Data(argString.utf8)) as? [String: Any])
                ?? [:]
            return ToolCall(id: id, name: name, arguments: args)
        }

        // Echo the assistant message back verbatim next turn (content may be null
        // when it only calls tools; tool_calls must round-trip exactly).
        var assistant: [String: Any] = ["role": "assistant", "content": content ?? NSNull()]
        if !rawCalls.isEmpty { assistant["tool_calls"] = rawCalls }

        var usage: AgentUsage?
        if let u = obj["usage"] as? [String: Any] {
            func count(_ key: String) -> Int { (u[key] as? NSNumber)?.intValue ?? 0 }
            usage = AgentUsage(
                inputTokens: count("prompt_tokens"), outputTokens: count("completion_tokens"))
        }

        return Completion(
            assistantMessage: assistant, content: content, toolCalls: calls, usage: usage)
    }

    /// Normalize the base URL (e.g. `https://api.openai.com/v1`) to the full
    /// completions endpoint, tolerating a trailing slash or a URL that already
    /// points at `/chat/completions`.
    private static func endpoint(_ base: String) -> URL? {
        var value = base.trimmed
        guard !value.isEmpty else { return nil }
        if value.hasSuffix("/") { value.removeLast() }
        if !value.hasSuffix("/chat/completions") { value += "/chat/completions" }
        return URL(string: value)
    }

    private static func errorText(_ data: Data, status: Int) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = obj["error"] as? [String: Any],
            let message = error["message"] as? String
        {
            return "HTTP \(status): \(message)"
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        return raw.isEmpty ? "HTTP \(status)." : "HTTP \(status): \(raw.prefix(200))"
    }

    // MARK: - File tools

    private func execute(_ call: ToolCall, project: Project) -> String {
        switch call.name {
        case "list_files":
            return listFiles(project)
        case "read_file":
            return readFile(call.arguments["path"] as? String, project)
        case "write_file":
            return writeFile(
                call.arguments["path"] as? String, call.arguments["content"] as? String, project)
        case "edit_file":
            return editFile(
                call.arguments["path"] as? String, call.arguments["old_string"] as? String,
                call.arguments["new_string"] as? String, project)
        default:
            return "Error: unknown tool \(call.name)."
        }
    }

    private func listFiles(_ project: Project) -> String {
        guard
            let enumerator = FileManager.default.enumerator(
                at: project.root, includingPropertiesForKeys: nil)
        else { return "(no files)" }
        var paths: [String] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            paths.append(project.relativePath(of: url))
        }
        paths.sort()
        return paths.isEmpty ? "(no Markdown files yet)" : paths.joined(separator: "\n")
    }

    private func readFile(_ path: String?, _ project: Project) -> String {
        guard let url = resolve(path, project: project) else { return "Error: invalid path." }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Error: could not read \(path ?? "file")."
        }
        return text
    }

    private func writeFile(_ path: String?, _ content: String?, _ project: Project) -> String {
        guard let url = resolve(path, project: project), let content else {
            return "Error: invalid path or content."
        }
        guard url.pathExtension.lowercased() == "md" else {
            return "Error: only .md files can be written."
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return "Wrote \(project.relativePath(of: url)) (\(content.count) chars)."
        } catch {
            return "Error writing: \(error.localizedDescription)"
        }
    }

    private func editFile(
        _ path: String?, _ old: String?, _ new: String?, _ project: Project
    ) -> String {
        guard let url = resolve(path, project: project), let old, let new else {
            return "Error: invalid arguments."
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Error: could not read \(path ?? "file")."
        }
        let occurrences = text.components(separatedBy: old).count - 1
        guard occurrences > 0 else {
            return "Error: old_string not found in \(project.relativePath(of: url))."
        }
        guard occurrences == 1 else {
            return "Error: old_string matches \(occurrences) times; make it unique."
        }
        do {
            try text.replacingOccurrences(of: old, with: new)
                .write(to: url, atomically: true, encoding: .utf8)
            return "Edited \(project.relativePath(of: url))."
        } catch {
            return "Error writing: \(error.localizedDescription)"
        }
    }

    /// Resolve a tool-supplied path inside the project, rejecting escapes (`..`).
    private func resolve(_ path: String?, project: Project) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let root = project.root.standardizedFileURL
        let url = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL
        guard url.path == root.path || url.path.hasPrefix(root.path + "/") else { return nil }
        return url
    }

    /// A short "what it's doing now" line from a tool call. Paths are already
    /// project-relative (per the tool schema), so they're shown as given.
    private func describe(_ call: ToolCall) -> String {
        let path = call.arguments["path"] as? String ?? "file"
        switch call.name {
        case "list_files": return "listing files"
        case "read_file": return "reading \(path)"
        case "write_file": return "writing \(path)"
        case "edit_file": return "editing \(path)"
        default: return call.name
        }
    }

    // MARK: - System prompt & tool schemas

    private static let systemPrompt = """
        You are a co-author working inside a project folder of Markdown (.md) files. Use the \
        provided tools to list, read, create, and edit .md files in that folder to carry out the \
        user's request. Read files for context before changing them. Only ever touch .md files. \
        Write in the same language the user writes in and that existing files use; keep code and \
        technical terms in English.

        When you have finished making changes, stop calling tools and reply to the user with a \
        short, plain-text confirmation — one or two sentences at most. Do NOT use Markdown in this \
        reply: no headings, lists, code fences, bold, or links. The Markdown you author belongs in \
        the files, not in this reply.
        """

    private static func tool(
        _ name: String, _ description: String, properties: [String: [String: String]],
        required: [String]
    ) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": required,
                ],
            ],
        ]
    }

    private static func string(_ description: String) -> [String: String] {
        ["type": "string", "description": description]
    }

    private static let tools: [[String: Any]] = [
        tool(
            "list_files",
            "List all Markdown (.md) files in the project, as paths relative to the project root.",
            properties: [:], required: []),
        tool(
            "read_file", "Read a Markdown file's full contents.",
            properties: ["path": string("Path relative to the project root, e.g. \"notes.md\".")],
            required: ["path"]),
        tool(
            "write_file", "Create or overwrite a Markdown file with the given contents.",
            properties: [
                "path": string("Path relative to the project root (must end in .md)."),
                "content": string("The full new file contents."),
            ], required: ["path", "content"]),
        tool(
            "edit_file",
            "Replace an exact snippet in a Markdown file. old_string must occur exactly once.",
            properties: [
                "path": string("Path relative to the project root."),
                "old_string": string("Exact text to replace (must be unique in the file)."),
                "new_string": string("Replacement text."),
            ], required: ["path", "old_string", "new_string"]),
    ]
}

/// A user-facing failure from the OpenAI-compatible backend (bad URL, HTTP error).
enum AgentError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
