import Combine
import Foundation

/// The co-authoring turn, kept per project (in memory). Unlike a chat thread, the
/// UI shows only a *single slot* — the live progress, then the agent's final reply
/// — so this store keeps just the current turn, not a history. Each `send` runs one
/// `ClaudeService.stream` on the project's persistent session, so the agent still
/// keeps whole-project context across turns.
@MainActor
final class ChatStore: ObservableObject {
    static let shared = ChatStore()

    /// The agent's final reply for the current turn (nil while empty or working).
    @Published private(set) var reply: String?
    @Published private(set) var working = false
    /// Live per-step progress for the in-flight turn (reading/writing files).
    @Published private(set) var activity: [String] = []

    /// Each project's most recent reply, so switching projects restores its slot.
    private var replyByProject: [String: String] = [:]
    private var activeProject: String?

    private init() {}

    /// Swap the visible slot when the open project changes.
    func activate(_ project: Project?) {
        if let activeProject { replyByProject[activeProject] = reply }
        activeProject = project?.id
        reply = project.flatMap { replyByProject[$0.id] }
    }

    /// Send one instruction: stream progress into `activity`, then surface the
    /// agent's final reply in the same slot. `focus` is the file the user currently
    /// has open, passed to the agent as the request's context.
    func send(_ instruction: String, in project: Project, focus file: ProjectFile?) async {
        reply = nil
        working = true
        activity = []

        let framed = framed(instruction, focus: file, in: project)
        let result = await ClaudeService.shared.stream(framed, in: project) { step in
            Task { @MainActor in self.activity.append(step) }
        }

        working = false
        activity = []
        reply = result ?? "The agent returned nothing."
    }

    /// Frame the instruction as a task over the project's Markdown files. Language
    /// is intentionally unspecified — the agent matches the user's and the files'.
    private func framed(_ instruction: String, focus file: ProjectFile?, in project: Project)
        -> String
    {
        var context = ""
        if let file {
            let path = relativePath(of: file.url, in: project)
            context = """
                The user currently has this file open in the editor: `\(path)`. Treat it as
                the focus of the request unless they clearly mean another file, and read it
                for context before making changes.


                """
        }
        return """
            You are working in a project folder of Markdown (.md) files. Create, edit, or
            organize `.md` files in this folder as needed. Write in the same language the user
            writes in and that existing files use; keep code and technical terms in English.

            When you finish, reply to the user with a short, plain-text confirmation — one or
            two sentences at most. Do NOT use Markdown in this reply: no headings, lists, code
            fences, bold, or links. The Markdown you author belongs in the files, not here.

            \(context)\(instruction)
            """
    }

    /// A path relative to the project root, for pointing the agent at the open file.
    private func relativePath(of url: URL, in project: Project) -> String {
        let root = project.root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root) else { return url.lastPathComponent }
        return String(path.dropFirst(root.count).drop { $0 == "/" })
    }
}
