import Combine
import Foundation

/// All projects under `~/Documents/Macfolio`, the selected project + file, and
/// each project's files (for the sidebar tree). A project's folder name is its
/// title; its files are the `.md` files directly inside. Persists the last-open
/// project and file, restored on launch.
final class ProjectStore: ObservableObject {
    static let shared = ProjectStore()

    @Published private(set) var projects: [Project] = []
    /// Files for every project, keyed by project id — drives the sidebar tree.
    @Published private(set) var filesByProject: [String: [ProjectFile]] = [:]
    /// Image files under every project, keyed by project id — shown in the sidebar.
    @Published private(set) var mediaByProject: [String: [URL]] = [:]
    @Published private(set) var project: Project?
    @Published private(set) var files: [ProjectFile] = []
    @Published var selected: ProjectFile? {
        didSet { persistSelection() }
    }

    private static let key = "currentProjectPath"
    private static let fileKey = "currentFilePath"

    private init() {
        refreshProjects()
        if let path = UserDefaults.standard.string(forKey: Self.key),
            FileManager.default.fileExists(atPath: path)
        {
            let url = URL(fileURLWithPath: path)
            openProject(Project(root: url, title: url.lastPathComponent))
        }
    }

    // MARK: - Projects

    func refreshProjects() {
        let fm = FileManager.default
        let dirs =
            (try? fm.contentsOfDirectory(
                at: Paths.projectsHome, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
        projects =
            dirs
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { Project(root: $0, title: $0.lastPathComponent) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        var map: [String: [ProjectFile]] = [:]
        var media: [String: [URL]] = [:]
        for project in projects {
            map[project.id] = loadFiles(project)
            media[project.id] = loadMedia(project)
        }
        filesByProject = map
        mediaByProject = media
    }

    /// Create a new project (folder name = title) and open it. Deduplicates names.
    func create(title: String) {
        let safe =
            title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        let base = safe.isEmpty ? "Untitled" : safe

        var root = Paths.projectsHome.appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: root.path) {
            root = Paths.projectsHome.appendingPathComponent("\(base) \(n)")
            n += 1
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        refreshProjects()
        // A project always has at least one file — seed the first and open it.
        addFile(title: "Untitled", to: Project(root: root, title: root.lastPathComponent))
    }

    func select(_ project: Project) { openProject(project) }

    /// Delete a whole project folder.
    func deleteProject(_ project: Project) {
        try? FileManager.default.removeItem(at: project.root)
        if self.project?.id == project.id {
            self.project = nil
            files = []
            selected = nil
            UserDefaults.standard.removeObject(forKey: Self.key)
        }
        refreshProjects()
    }

    private func openProject(_ project: Project) {
        self.project = project
        UserDefaults.standard.set(project.root.path, forKey: Self.key)
        refresh()
    }

    // MARK: - Files

    /// Re-scan the open project's `.md` files (the agent may have changed them).
    func refresh() {
        guard let project else {
            files = []
            selected = nil
            return
        }
        files = loadFiles(project)
        filesByProject[project.id] = files
        mediaByProject[project.id] = loadMedia(project)
        if selected == nil || !files.contains(where: { $0.id == selected?.id }) {
            selected = restoredFile() ?? files.first
        }
    }

    // The last-opened file, if it belongs to the currently open project.
    private func restoredFile() -> ProjectFile? {
        guard let path = UserDefaults.standard.string(forKey: Self.fileKey) else {
            return nil
        }
        return files.first { $0.url.path == path }
    }

    private func persistSelection() {
        if let path = selected?.url.path {
            UserDefaults.standard.set(path, forKey: Self.fileKey)
        }
    }

    private func loadFiles(_ project: Project) -> [ProjectFile] {
        let fm = FileManager.default
        let items =
            (try? fm.contentsOfDirectory(
                at: project.root, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])) ?? []
        return
            items
            .filter { $0.pathExtension == "md" }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
            .map { ProjectFile(url: $0) }
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "svg",
    ]

    // Every image file anywhere under the project (e.g. an `images/` subfolder).
    private func loadMedia(_ project: Project) -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: project.root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var urls: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if Self.imageExtensions.contains(url.pathExtension.lowercased()) {
                urls.append(url)
            }
        }
        return urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                == .orderedAscending
        }
    }

    func text(of file: ProjectFile) -> String {
        (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
    }

    func save(_ text: String, to file: ProjectFile) {
        try? text.write(to: file.url, atomically: true, encoding: .utf8)
    }

    // MARK: - File operations

    /// Add a file to a project (or the open project), seeded with a title heading.
    func addFile(title: String, to targetProject: Project? = nil) {
        guard let target = targetProject ?? project else { return }
        var url = target.root.appendingPathComponent("\(slugify(title)).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = target.root.appendingPathComponent("\(slugify(title))-\(n).md")
            n += 1
        }
        try? "# \(title)\n\n".write(to: url, atomically: true, encoding: .utf8)
        openProject(target)
        selected = files.first { $0.url == url }
        refreshProjects()
    }

    /// Rename a project (its folder). Deduplicates; re-opens if it was open.
    func renameProject(_ project: Project, to title: String) {
        let safe =
            title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        guard !safe.isEmpty else { return }
        let newRoot = project.root.deletingLastPathComponent().appendingPathComponent(safe)
        guard newRoot != project.root, !FileManager.default.fileExists(atPath: newRoot.path)
        else { return }
        try? FileManager.default.moveItem(at: project.root, to: newRoot)
        let wasOpen = self.project?.id == project.id
        refreshProjects()
        if wasOpen {
            openProject(Project(root: newRoot, title: newRoot.lastPathComponent))
        }
    }

    /// Rename a file.
    func rename(_ file: ProjectFile, to title: String) {
        let newURL = file.url.deletingLastPathComponent()
            .appendingPathComponent("\(slugify(title)).md")
        guard newURL != file.url, !FileManager.default.fileExists(atPath: newURL.path) else {
            return
        }
        try? FileManager.default.moveItem(at: file.url, to: newURL)
        reload(after: file, select: newURL)
    }

    /// Delete a file, but keep at least one file in the project.
    func delete(_ file: ProjectFile) {
        let dir = file.url.deletingLastPathComponent()
        let mdCount =
            ((try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }.count
        guard mdCount > 1 else { return }  // a project always keeps ≥ 1 file
        try? FileManager.default.removeItem(at: file.url)
        reload(after: file, select: nil)
    }

    /// Move a project image to the Trash and refresh the sidebar media list.
    func deleteMedia(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        refreshProjects()
    }

    // MARK: - Helpers

    /// Refresh state after a file change; if it's in the open project, reselect.
    private func reload(after file: ProjectFile, select url: URL?) {
        let dir = file.url.deletingLastPathComponent()
        let isOpen = project?.root == dir
        refreshProjects()
        if isOpen, let project {
            files = loadFiles(project)
            filesByProject[project.id] = files
            if let url {
                selected = files.first { $0.url == url }
            } else if selected == nil || !files.contains(where: { $0.id == selected?.id }) {
                selected = files.first
            }
        }
    }

    private func slugify(_ title: String) -> String {
        let trimmed =
            title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        return trimmed.isEmpty ? "untitled" : trimmed
    }
}
