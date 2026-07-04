import Foundation

/// Maps each project to its persistent Claude Code session id, so the co-author
/// keeps whole-project context across turns (one session **per project**).
/// Persisted to `~/.config/macfolio/sessions.json`.
final class SessionStore {
    static let shared = SessionStore()

    private var map: [String: String]  // project root path → session id
    private static let file = Paths.support("sessions.json")

    private init() {
        if let data = try? Data(contentsOf: Self.file),
            let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        {
            map = decoded
        } else {
            map = [:]
        }
    }

    func session(for project: Project) -> String? { map[project.id] }

    func setSession(_ id: String, for project: Project) {
        guard map[project.id] != id else { return }
        map[project.id] = id
        persist()
    }

    /// Forget the project's session so the next turn starts a fresh conversation.
    func clearSession(for project: Project) {
        guard map[project.id] != nil else { return }
        map[project.id] = nil
        persist()
    }

    func hasSession(for project: Project) -> Bool { map[project.id] != nil }

    private func persist() {
        if let data = try? JSONEncoder().encode(map) {
            try? data.write(to: Self.file)
        }
    }
}
