import Foundation

/// A chapter's YAML frontmatter — the metadata block at the top of a `.md` file,
/// fenced by `---`. Modeled on **Jekyll**'s front matter so files drop straight
/// into a Jekyll site. Only the fields an author actually sets are surfaced —
/// `title`, `order`, `date`, `draft`, and `tags`. Any other keys a file carries
/// (`categories`, `published`, `layout`, custom params, …) are preserved verbatim
/// in `extra`, so editing metadata never drops a field we don't manage.
///
///     ---
///     title: The Opening
///     order: 1
///     date: 2026-07-09
///     draft: true
///     tags: [intro, backstory]
///     ---
///
/// The editor never shows this block; it's edited through the metadata form, and
/// the agent is asked to leave it intact.
struct Frontmatter: Equatable, Hashable {
    var title: String = ""
    /// Explicit sidebar position (a custom field; Jekyll has no native ordering).
    /// Chapters with an `order` sort ahead of the rest, ascending.
    var order: Int?
    var date: String = ""
    /// Whether the chapter is a work in progress (a custom flag; only written when
    /// `true`, so published files stay clean). Kept out of the sidebar's live view.
    var draft: Bool = false
    var tags: [String] = []
    /// Other frontmatter lines, preserved verbatim (Jekyll fields we don't surface,
    /// plus any custom keys), so a full Jekyll file round-trips losslessly.
    var extra: [String] = []

    /// Whether any field carries a value worth writing (an all-default block is
    /// omitted, keeping plain files plain).
    var isEmpty: Bool {
        title.isEmpty && order == nil && date.isEmpty && !draft && tags.isEmpty && extra.isEmpty
    }

    /// Today's date in the stored `yyyy-MM-dd` form, for seeding new files.
    static func today() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    // MARK: - Parsing

    private static let managedKeys: Set<String> = ["title", "order", "date", "draft", "tags"]

    /// Split a raw file into its frontmatter (if present) and the body that
    /// follows. A file with no leading `---` block yields `(Frontmatter(), raw)`.
    static func split(_ raw: String) -> (meta: Frontmatter, body: String) {
        let lines = raw.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return (Frontmatter(), raw)
        }
        guard
            let close = lines.dropFirst().firstIndex(where: {
                let t = $0.trimmingCharacters(in: .whitespaces)
                return t == "---" || t == "..."
            })
        else {
            return (Frontmatter(), raw)
        }

        let meta = parse(Array(lines[1..<close]))
        let body = lines[(close + 1)...].joined(separator: "\n")
        return (meta, body.hasPrefix("\n") ? String(body.dropFirst()) : body)
    }

    private static func parse(_ lines: [String]) -> Frontmatter {
        var meta = Frontmatter()
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
                continue
            }

            // Only top-level `key: value` lines are interpreted; anything else is
            // a child of the preceding key and handled where that key is consumed.
            guard indent(of: line) == 0, let colon = line.firstIndex(of: ":") else {
                meta.extra.append(line)
                i += 1
                continue
            }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = unquote(
                String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))

            guard managedKeys.contains(key) else {
                // Unknown key: preserve it and any deeper-indented child lines.
                meta.extra.append(line)
                i += 1
                while i < lines.count, indent(of: lines[i]) > 0,
                    !lines[i].trimmingCharacters(in: .whitespaces).isEmpty
                {
                    meta.extra.append(lines[i])
                    i += 1
                }
                continue
            }

            switch key {
            case "title": meta.title = value
            case "order": meta.order = Int(value)
            case "date": meta.date = value
            case "draft": meta.draft = (value.lowercased() == "true")
            case "tags":
                let (items, next) = array(after: i, inlineValue: value, in: lines)
                meta.tags = items
                i = next
                continue
            default: break
            }
            i += 1
        }
        return meta
    }

    /// Read an array field — a YAML flow sequence (`[a, b]`), the following block
    /// list (`- a`), or Jekyll's space/comma-separated string form (`a b`).
    /// Returns the items and the index of the next line to read.
    private static func array(after index: Int, inlineValue: String, in lines: [String]) -> (
        [String], Int
    ) {
        if !inlineValue.isEmpty {
            let separators: CharacterSet
            var inner = inlineValue
            if inner.hasPrefix("[") && inner.hasSuffix("]") {
                inner = String(inner.dropFirst().dropLast())
                separators = CharacterSet(charactersIn: ",")
            } else {
                separators = CharacterSet(charactersIn: ",").union(.whitespaces)
            }
            let items =
                inner.components(separatedBy: separators)
                .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }
            return (items, index + 1)
        }
        var items: [String] = []
        var i = index + 1
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            guard indent(of: lines[i]) > 0, trimmed.hasPrefix("-") else { break }
            let item = unquote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
            if !item.isEmpty { items.append(item) }
            i += 1
        }
        return (items, i)
    }

    private static func indent(of line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == "\"" || first == "'",
            value.last == first
        else { return value }
        return String(value.dropFirst().dropLast())
    }

    // MARK: - Serializing

    /// Re-join metadata and body into the raw file text. When the metadata is
    /// empty the fence is omitted entirely.
    static func join(_ meta: Frontmatter, body: String) -> String {
        let block = meta.serialized
        return block.isEmpty ? body : block + body
    }

    /// The `---`-fenced block (empty string when there's nothing to write). Managed
    /// fields come first in a stable order, then any preserved `extra` lines.
    var serialized: String {
        guard !isEmpty else { return "" }
        var lines: [String] = ["---"]
        if !title.isEmpty { lines.append("title: \(Self.quoteIfNeeded(title))") }
        if let order { lines.append("order: \(order)") }
        if !date.isEmpty { lines.append("date: \(date)") }
        if draft { lines.append("draft: true") }
        if !tags.isEmpty { lines.append("tags: [\(tags.joined(separator: ", "))]") }
        lines.append(contentsOf: extra)
        lines.append("---")
        return lines.joined(separator: "\n") + "\n\n"
    }

    private static func quoteIfNeeded(_ value: String) -> String {
        let special = CharacterSet(charactersIn: ":#[]{}&*!|>'\"%@`")
        let needsQuote =
            value.rangeOfCharacter(from: special) != nil || value.first == " " || value.last == " "
        guard needsQuote else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
