import Foundation

/// A project: a folder of Markdown files.
struct Project: Identifiable, Hashable {
    let root: URL
    var title: String
    var id: String { root.path }

    /// A path relative to the project root — for compact display and for pointing
    /// the agent at a file. Falls back to the last component for anything outside
    /// the project.
    func relativePath(of url: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count).drop { $0 == "/" })
    }
}

/// A single Markdown file inside a project.
struct ProjectFile: Identifiable, Hashable {
    let url: URL
    /// The file's parsed frontmatter (empty when it has none). Loaded with the file.
    var metadata = Frontmatter()

    var id: String { url.path }

    /// The filename without its `.md` extension — the file's identity for rename.
    var title: String { url.deletingPathExtension().lastPathComponent }

    /// What the sidebar shows: the frontmatter title if set, else the filename.
    var displayTitle: String { metadata.title.isEmpty ? title : metadata.title }
}
