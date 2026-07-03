import Foundation

/// A project: a folder of Markdown files.
struct Project: Identifiable, Hashable {
    let root: URL
    var title: String
    var id: String { root.path }
}

/// A single Markdown file inside a project.
struct ProjectFile: Identifiable, Hashable {
    let url: URL
    var id: String { url.path }

    /// Display name: the filename without its `.md` extension.
    var title: String { url.deletingPathExtension().lastPathComponent }
}
