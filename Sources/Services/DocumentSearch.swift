import Foundation

/// Full-text search across every project's documents — matches a file's title
/// and body, ranked title-matches first. Reads document contents on demand
/// through the shared `ProjectStore`, so it always reflects what's on disk.
enum DocumentSearch {
    /// Cap the result list so a broad query can't return hundreds of rows.
    static let maxResults = 50

    /// Documents matching `query` (case-insensitive) by title or body, with a
    /// body excerpt for each. Title matches sort ahead of body-only matches.
    static func matches(for query: String, in store: ProjectStore = .shared) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        var titleHits: [SearchHit] = []
        var bodyHits: [SearchHit] = []
        for project in store.projects {
            for file in store.filesByProject[project.id] ?? [] {
                let titleMatch = file.title.range(of: q, options: .caseInsensitive) != nil
                let excerpt = excerpt(from: store.text(of: file), query: q)
                guard titleMatch || !excerpt.isEmpty else { continue }
                let hit = SearchHit(project: project, file: file, snippet: excerpt)
                if titleMatch { titleHits.append(hit) } else { bodyHits.append(hit) }
            }
        }
        return Array((titleHits + bodyHits).prefix(maxResults))
    }

    /// A one-line excerpt of `body` around the first match, whitespace collapsed
    /// and ellipsed at the trimmed ends. Empty when there's no body match.
    private static func excerpt(from body: String, query: String) -> String {
        guard let match = body.range(of: query, options: .caseInsensitive) else {
            return ""
        }
        let start =
            body.index(match.lowerBound, offsetBy: -30, limitedBy: body.startIndex)
            ?? body.startIndex
        let end =
            body.index(match.upperBound, offsetBy: 90, limitedBy: body.endIndex)
            ?? body.endIndex
        var text = String(body[start..<end])
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if start != body.startIndex { text = "…" + text }
        if end != body.endIndex { text += "…" }
        return text
    }
}
