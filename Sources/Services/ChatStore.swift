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
    /// The token usage of the current reply's turn (nil until it completes).
    @Published private(set) var usage: AgentUsage?
    @Published private(set) var working = false
    /// Live per-step progress for the in-flight turn (reading/writing files).
    @Published private(set) var activity: [String] = []
    /// The reply text streaming in for the in-flight turn (empty until it starts).
    @Published private(set) var liveReply = ""

    /// Each project's most recent reply + usage, so switching projects restores it.
    private struct Turn {
        var reply: String?
        var usage: AgentUsage?
    }
    private var byProject: [String: Turn] = [:]
    private var activeProject: String?

    private init() {}

    /// Swap the visible slot when the open project changes.
    func activate(_ project: Project?) {
        if let activeProject { byProject[activeProject] = Turn(reply: reply, usage: usage) }
        activeProject = project?.id
        let turn = project.flatMap { byProject[$0.id] }
        reply = turn?.reply
        usage = turn?.usage
    }

    /// Whether there's a conversation to reset (a session or a shown reply).
    func canStartNewSession(in project: Project?) -> Bool {
        guard let project else { return false }
        return reply != nil || SessionStore.shared.hasSession(for: project)
    }

    /// Start a fresh conversation: forget the project's session and clear its slot
    /// (reply + token usage), so the next prompt has no prior context.
    func newSession(in project: Project) {
        SessionStore.shared.clearSession(for: project)
        byProject[project.id] = nil
        reply = nil
        usage = nil
        activity = []
        liveReply = ""
    }

    /// Send one instruction: stream progress into `activity`, then surface the
    /// agent's final reply (and its token usage) in the same slot. `focus` is the
    /// file the user currently has open, and `selection` is the caret's
    /// selection/line, both passed to the agent as the request's context.
    func send(
        _ instruction: String, in project: Project, focus file: ProjectFile?,
        selection: EditorSelectionContext
    ) async {
        reply = nil
        usage = nil
        working = true
        activity = []
        liveReply = ""

        let framed = framed(instruction, focus: file, selection: selection, in: project)
        // `for await` on the main actor keeps the ordered stream in order — the
        // reply's text deltas can't scramble.
        for await event in ClaudeService.shared.run(framed, in: project) {
            switch event {
            case .step(let step):
                activity.append(step)
            case .replyReset:
                liveReply = ""
            case .replyDelta(let text):
                liveReply += text
            case .finished(let finalReply, let finalUsage):
                reply = finalReply ?? "The agent returned nothing."
                usage = finalUsage
            }
        }

        working = false
        activity = []
        liveReply = ""
    }

    /// Frame the instruction as a task over the project's Markdown files. Language
    /// is intentionally unspecified — the agent matches the user's and the files'.
    private func framed(
        _ instruction: String, focus file: ProjectFile?, selection: EditorSelectionContext,
        in project: Project
    ) -> String {
        var context = ""
        if let file {
            let path = relativePath(of: file.url, in: project)
            context = """
                The user currently has this file open in the editor: `\(path)`. Treat it as
                the focus of the request unless they clearly mean another file, and read it
                for context before making changes.


                """
        }
        // The caret's context, so "expand the selection" / "remove this line" resolve.
        if !selection.selectedText.isEmpty {
            context += """
                The user has selected this text in the editor; apply the request to it:
                \"\"\"
                \(selection.selectedText)
                \"\"\"


                """
        } else if !selection.blockText.isEmpty {
            context += """
                The user's cursor is on this line/paragraph:
                \"\"\"
                \(selection.blockText)
                \"\"\"


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
