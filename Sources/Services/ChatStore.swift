import Combine
import Foundation

/// The co-authoring conversation, kept per project (in memory). Each user turn
/// runs one `ClaudeService.stream` on the project's persistent session, so the
/// agent keeps whole-project context.
@MainActor
final class ChatStore: ObservableObject {
    static let shared = ChatStore()

    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var working = false
    /// Live per-step progress for the in-flight turn (reading/writing files).
    @Published private(set) var activity: [String] = []

    private var byProject: [String: [ChatMessage]] = [:]
    private var activeProject: String?

    private init() {}

    /// Swap the visible thread when the open project changes.
    func activate(_ project: Project?) {
        if let activeProject { byProject[activeProject] = messages }
        activeProject = project?.id
        messages = project.flatMap { byProject[$0.id] } ?? []
    }

    /// Send one instruction; append the user turn, stream progress into
    /// `activity`, then append the agent's final reply.
    func send(_ instruction: String, in project: Project) async {
        messages.append(ChatMessage(role: .user, text: instruction))
        working = true
        activity = []

        let reply = await ClaudeService.shared.stream(prompt(instruction), in: project) { step in
            Task { @MainActor in self.activity.append(step) }
        }

        working = false
        activity = []
        messages.append(
            ChatMessage(role: .assistant, text: reply ?? "The agent returned nothing."))
    }

    /// Frame the instruction as a task over the project's Markdown files. Language
    /// is intentionally unspecified — the agent matches the user's and the files'.
    private func prompt(_ instruction: String) -> String {
        """
        You are working in a project folder of Markdown (.md) files. Create, edit, or
        organize `.md` files in this folder as needed. Write in the same language the user
        writes in and that existing files use; keep code and technical terms in English.

        \(instruction)
        """
    }
}
