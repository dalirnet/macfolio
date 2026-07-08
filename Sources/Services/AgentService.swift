import Foundation

/// One turn's token usage. For the CLI, `inputTokens` is the *new* (uncached)
/// input — it excludes the cached system prompt + tool schemas (~25k every turn),
/// which would otherwise dwarf the real usage. For the API backends it's the
/// request's `prompt_tokens` / `completion_tokens`.
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

/// A co-authoring backend: something that can run one agentic turn over a
/// project's Markdown files and stream ordered `TurnEvent`s. `ClaudeService`
/// drives the Claude Code CLI (which brings its own file tools); `OpenAIService`
/// hosts a tool-calling loop against a fixed OpenAI-compatible endpoint (used for
/// both the Claude API and OpenAI).
protocol AgentService {
    /// Ready to run — the CLI is installed, or the endpoint/key/model are set.
    func isAvailable() -> Bool

    /// Stream one turn's progress + final reply. Cancelling the consuming task
    /// ends the turn (kills the process / cancels the request).
    func run(_ instruction: String, in project: Project) -> AsyncStream<TurnEvent>

    /// Whether this project has prior conversation state to reset.
    func hasSession(for project: Project) -> Bool

    /// Forget this project's conversation, so the next turn starts fresh.
    func clearSession(for project: Project)
}

/// Routes to the backend chosen in Settings. The Claude Code CLI is macOS-only
/// (it shells out), so on iOS everything runs through the API backend.
enum Agent {
    static var current: AgentService {
        switch SettingsStore.shared.provider {
        case .claudeAPI, .openAI:
            return OpenAIService.shared
        case .claudeCode:
            #if os(macOS)
                return ClaudeService.shared
            #else
                return OpenAIService.shared
            #endif
        }
    }
}
