import Foundation

/// A node in the sidebar tree: a project (top level) or a file (child).
struct SidebarNode: Identifiable, Hashable {
    let id: String
    let title: String
    let project: Project
    /// nil for a project node; set for a file node.
    let file: ProjectFile?
    var children: [SidebarNode]?

    var isProject: Bool { file == nil }

    static func == (lhs: SidebarNode, rhs: SidebarNode) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
