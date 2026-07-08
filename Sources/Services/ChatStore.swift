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

    // These five publish the *visible* slot — a live mirror of the open project's
    // turn (`byProject[activeProject]`). Turns run per project, so a turn in a
    // background project doesn't make the open one look busy.

    /// The agent's final reply for the current turn (nil while empty or working).
    @Published private(set) var reply: String?
    /// The token usage of the current reply's turn (nil until it completes).
    @Published private(set) var usage: AgentUsage?
    @Published private(set) var working = false
    /// Live per-step progress for the in-flight turn (reading/writing files).
    @Published private(set) var activity: [String] = []
    /// The reply text streaming in for the in-flight turn (empty until it starts).
    @Published private(set) var liveReply = ""

    /// A project's whole turn state, so switching projects restores its live
    /// progress (or final reply) exactly — and each project runs independently.
    private struct Turn {
        var reply: String?
        var usage: AgentUsage?
        var working = false
        var activity: [String] = []
        var liveReply = ""

        /// Start a fresh in-flight turn, clearing any prior reply/usage.
        mutating func begin() {
            self = Turn()
            working = true
        }

        /// The turn ended (finished or cancelled): stop working and drop the
        /// transient live state, keeping whatever final reply/usage arrived.
        mutating func end() {
            working = false
            activity = []
            liveReply = ""
        }
    }
    /// The source of truth, keyed by project id; the published slot mirrors the
    /// active project's entry.
    private var byProject: [String: Turn] = [:]
    private var activeProject: String?
    /// The in-flight turn per project, so it can be cancelled (stop button).
    private var turnTasks: [String: Task<Void, Never>] = [:]

    private init() {}

    /// Swap the visible slot when the open project changes.
    func activate(_ project: Project?) {
        activeProject = project?.id
        publish(project.flatMap { byProject[$0.id] } ?? Turn())
    }

    /// Mutate a project's turn (the source of truth), mirroring it to the visible
    /// slot when that project is the one on screen.
    private func update(_ id: String, _ change: (inout Turn) -> Void) {
        var turn = byProject[id] ?? Turn()
        change(&turn)
        byProject[id] = turn
        if id == activeProject { publish(turn) }
    }

    private func publish(_ turn: Turn) {
        reply = turn.reply
        usage = turn.usage
        working = turn.working
        activity = turn.activity
        liveReply = turn.liveReply
    }

    /// Whether there's a conversation to reset (a session or a shown reply).
    func canStartNewSession(in project: Project?) -> Bool {
        guard let project else { return false }
        return byProject[project.id]?.reply != nil || SessionStore.shared.hasSession(for: project)
    }

    /// Start a fresh conversation: forget the project's session and clear its slot
    /// (reply + token usage), so the next prompt has no prior context.
    func newSession(in project: Project) {
        SessionStore.shared.clearSession(for: project)
        update(project.id) { $0 = Turn() }
    }

    /// Send one instruction: stream progress into `activity`, then surface the
    /// agent's final reply (and its token usage) in the same slot. `focus` is the
    /// file the user currently has open, and `selection` is the caret's
    /// selection/line, both passed to the agent as the request's context. Runs the
    /// turn on a tracked task so `cancel(in:)` can stop it; `onFinish` fires when
    /// the turn ends (completed or cancelled) so the caller can reload edited files.
    func send(
        _ instruction: String, in project: Project, focus file: ProjectFile?,
        selection: EditorSelectionContext, onFinish: @escaping () -> Void
    ) {
        let id = project.id
        turnTasks[id]?.cancel()
        update(id) { $0.begin() }

        let framed = framed(instruction, focus: file, selection: selection, in: project)
        turnTasks[id] = Task { [weak self] in
            // `for await` on the main actor keeps the ordered stream in order — the
            // reply's text deltas can't scramble. Cancelling this task ends the
            // stream, which terminates the CLI process (see ClaudeService.run).
            for await event in ClaudeService.shared.run(framed, in: project) {
                switch event {
                case .step(let step):
                    self?.update(id) { $0.activity.append(step) }
                case .replyReset:
                    self?.update(id) { $0.liveReply = "" }
                case .replyDelta(let text):
                    self?.update(id) { $0.liveReply += text }
                case .finished(let finalReply, let finalUsage):
                    self?.update(id) {
                        $0.reply = finalReply ?? "The agent returned nothing."
                        $0.usage = finalUsage
                    }
                }
            }
            self?.update(id) { $0.end() }
            self?.turnTasks[id] = nil
            onFinish()
        }
    }

    /// Stop the project's in-flight turn: terminates the CLI process and clears the
    /// working state (the turn's task runs its completion, keeping any partial reply
    /// out and firing `onFinish`).
    func cancel(in project: Project) {
        turnTasks[project.id]?.cancel()
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
