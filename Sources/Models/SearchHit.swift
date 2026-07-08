import Foundation

/// One search match: a document, its project, and a body excerpt around the
/// first match (empty when only the title matched).
struct SearchHit: Identifiable {
    let project: Project
    let file: ProjectFile
    let snippet: String
    var id: String { file.id }
}
