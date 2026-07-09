import Foundation

/// One commit in a project's history.
struct GitCommit: Identifiable, Hashable {
    let hash: String
    let shortHash: String
    let subject: String
    let relativeDate: String
    var id: String { hash }
}

/// Local git version control for a project folder (macOS only — shells out to
/// `git`, which iPad has no access to). Each project is its own repo: the user
/// takes **manual snapshots** that become commits to browse and restore, so a
/// round of edits (yours or the agent's) can always be undone.
///
/// Repos are initialized lazily on the first snapshot, so there's no setup. A local
/// committer identity is set only when the user has none configured globally, so we
/// never touch their global git config.
final class GitService {
    static let shared = GitService()
    private init() {}

    private(set) var executablePath: String?

    private static let candidatePaths = [
        "/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git",
    ]

    // MARK: - Locating git

    @discardableResult
    func locate() -> String? {
        if let executablePath { return executablePath }
        executablePath = Shell.locate("git", candidates: Self.candidatePaths)
        return executablePath
    }

    func isAvailable() -> Bool { locate() != nil }

    /// Whether the folder already holds a git repo.
    func isRepo(_ project: Project) -> Bool {
        FileManager.default.fileExists(atPath: project.root.appendingPathComponent(".git").path)
    }

    // MARK: - Snapshots

    /// Record the folder's current state as a commit. Initializes the repo on first
    /// use. Returns false when git is unavailable or there was nothing to commit.
    @discardableResult
    func snapshot(_ project: Project, message: String) -> Bool {
        guard let git = locate() else { return false }
        if !isRepo(project) {
            guard run(git, ["init"], project) else { return false }
        }
        ensureIdentity(git, project)
        guard isDirty(git, project) else { return false }
        run(git, ["add", "-A"], project)
        return run(git, ["commit", "-m", message], project)
    }

    /// The project's commit log, newest first.
    func history(_ project: Project, limit: Int = 100) -> [GitCommit] {
        guard let git = locate(), isRepo(project) else { return [] }
        let format = "%H\u{1f}%h\u{1f}%s\u{1f}%cr"
        let output = Shell.output(
            git, ["log", "-n", "\(limit)", "--pretty=format:\(format)"], cwd: project.root)
        return output.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\u{1f}")
            guard parts.count == 4 else { return nil }
            return GitCommit(
                hash: parts[0], shortHash: parts[1], subject: parts[2], relativeDate: parts[3])
        }
    }

    /// Drop a snapshot from history, replaying the ones after it onto its parent.
    /// Each snapshot is a full-tree state, so `-X theirs` resolves any overlap by
    /// keeping the later snapshot's content — the end state is preserved. The very
    /// first commit has no parent and can't be removed this way.
    @discardableResult
    func removeSnapshot(_ project: Project, _ commit: GitCommit) -> Bool {
        guard let git = locate(), isRepo(project) else { return false }
        ensureIdentity(git, project)
        guard run(git, ["rev-parse", "--verify", "--quiet", "\(commit.hash)^"], project) else {
            return false
        }
        let ok = run(
            git, ["rebase", "--autostash", "-X", "theirs", "--onto", "\(commit.hash)^", commit.hash],
            project)
        if !ok { run(git, ["rebase", "--abort"], project) }
        return ok
    }

    /// The current commit's hash (HEAD), or nil when there are no commits.
    func headHash(_ project: Project) -> String? {
        guard let git = locate(), isRepo(project) else { return nil }
        let hash = Shell.output(git, ["rev-parse", "HEAD"], cwd: project.root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return hash.isEmpty ? nil : hash
    }

    /// Restore the working tree to a past commit's contents, recording the result
    /// as a new commit — non-destructive, so the history is never rewritten.
    @discardableResult
    func restore(_ project: Project, to commit: GitCommit) -> Bool {
        guard let git = locate(), isRepo(project) else { return false }
        ensureIdentity(git, project)
        run(git, ["checkout", commit.hash, "--", "."], project)
        guard isDirty(git, project) else { return true }  // already at that state
        run(git, ["add", "-A"], project)
        return run(git, ["commit", "-m", "Restore to \(commit.shortHash)"], project)
    }

    // MARK: - Helpers

    private func isDirty(_ git: String, _ project: Project) -> Bool {
        !Shell.output(git, ["status", "--porcelain"], cwd: project.root)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Set a repo-local identity only if the user has no global one, so `git commit`
    /// never fails for lack of a committer — without overriding their config.
    private func ensureIdentity(_ git: String, _ project: Project) {
        let email = Shell.output(git, ["config", "user.email"], cwd: project.root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.isEmpty else { return }
        run(git, ["config", "user.email", "macfolio@localhost"], project)
        run(git, ["config", "user.name", "Macfolio"], project)
    }

    @discardableResult
    private func run(_ git: String, _ args: [String], _ project: Project) -> Bool {
        Shell.run(git, args, cwd: project.root)
    }
}
