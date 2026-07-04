import SwiftUI

/// Native, read-only Markdown preview — a Swift/AppKit alternative to the WebView
/// editor for reviewing content. Block structure is parsed here; inline styling
/// (bold/italic/links/code) comes from Foundation's `AttributedString(markdown:)`.
/// Direction is per-block (native TextKit bidi), so RTL renders correctly.
struct MarkdownView: View {
    let markdown: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) {
                    _, block in
                    view(for: block)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Block rendering

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            styled(inline(text), rtl: Bidi.isRTL(text))
                .font(Theme.ui(headingSize(level), .bold))
                .padding(.top, level <= 2 ? 8 : 4)

        case .paragraph(let text):
            styled(inline(text), rtl: Bidi.isRTL(text))
                .font(Theme.ui(16))
                .lineSpacing(5)

        case .bullet(let items):
            list(items, ordered: false)

        case .ordered(let items):
            list(items, ordered: true)

        case .quote(let text):
            HStack(spacing: 10) {
                Rectangle()
                    .fill(.secondary.opacity(0.4))
                    .frame(width: 3)
                styled(inline(text), rtl: Bidi.isRTL(text))
                    .font(Theme.ui(16))
                    .foregroundStyle(.secondary)
                    .lineSpacing(5)
            }
            .environment(\.layoutDirection, Bidi.isRTL(text) ? .rightToLeft : .leftToRight)

        case .code(let text):
            Text(text)
                .font(Theme.mono(13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    /// A bullet/ordered list — one row per item, marker flipped for RTL blocks.
    @ViewBuilder
    private func list(_ items: [String], ordered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let rtl = Bidi.isRTL(item)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ordered ? "\(index + 1)." : "•")
                        .font(Theme.ui(16))
                        .foregroundStyle(.secondary)
                    styled(inline(item), rtl: rtl)
                        .font(Theme.ui(16))
                        .lineSpacing(5)
                }
                .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
            }
        }
    }

    /// Common text styling: selectable, and aligned/flipped by detected direction.
    private func styled(_ text: AttributedString, rtl: Bool) -> some View {
        Text(text)
            .textSelection(.enabled)
            .multilineTextAlignment(rtl ? .trailing : .leading)
            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 30
        case 2: return 23
        case 3: return 19
        default: return 17
        }
    }

    /// Inline Markdown (bold/italic/links/code) → AttributedString, plain on failure.
    private func inline(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: source, options: options))
            ?? AttributedString(source)
    }
}

/// A parsed Markdown block. The parser covers the common CommonMark subset —
/// headings, paragraphs, lists, blockquotes, fenced code, and rules.
enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet([String])
    case ordered([String])
    case quote(String)
    case code(String)
    case rule

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = markdown.components(separatedBy: "\n")
        var i = 0

        func trimmed(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespaces)
        }

        while i < lines.count {
            let line = lines[i]
            let t = trimmed(line)

            // Blank line — block separator.
            if t.isEmpty {
                i += 1
                continue
            }

            // Fenced code block: ``` ... ```
            if t.hasPrefix("```") {
                var body: [String] = []
                i += 1
                while i < lines.count, !trimmed(lines[i]).hasPrefix("```") {
                    body.append(lines[i])
                    i += 1
                }
                i += 1  // closing fence
                blocks.append(.code(body.joined(separator: "\n")))
                continue
            }

            // Thematic break: ---, ***, ___
            if t == "---" || t == "***" || t == "___" {
                blocks.append(.rule)
                i += 1
                continue
            }

            // ATX heading: # ... ######
            if let heading = Self.heading(t) {
                blocks.append(heading)
                i += 1
                continue
            }

            // Blockquote: consecutive `>` lines.
            if t.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count, trimmed(lines[i]).hasPrefix(">") {
                    var q = trimmed(lines[i])
                    q.removeFirst()
                    quoteLines.append(trimmed(q))
                    i += 1
                }
                blocks.append(.quote(quoteLines.joined(separator: " ")))
                continue
            }

            // Unordered list: consecutive -, *, + items.
            if Self.isBullet(t) {
                var items: [String] = []
                while i < lines.count, Self.isBullet(trimmed(lines[i])) {
                    items.append(String(trimmed(lines[i]).dropFirst(2)))
                    i += 1
                }
                blocks.append(.bullet(items))
                continue
            }

            // Ordered list: consecutive `1.` items.
            if Self.orderedItem(t) != nil {
                var items: [String] = []
                while i < lines.count, let item = Self.orderedItem(trimmed(lines[i])) {
                    items.append(item)
                    i += 1
                }
                blocks.append(.ordered(items))
                continue
            }

            // Paragraph: consecutive plain lines until a blank/special line.
            var para: [String] = []
            while i < lines.count {
                let pt = trimmed(lines[i])
                if pt.isEmpty || pt.hasPrefix("```") || pt.hasPrefix(">")
                    || pt.hasPrefix("#") || Self.isBullet(pt)
                    || Self.orderedItem(pt) != nil
                {
                    break
                }
                para.append(pt)
                i += 1
            }
            blocks.append(.paragraph(para.joined(separator: " ")))
        }

        return blocks
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        var level = 0
        for char in line {
            if char == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6, line.dropFirst(level).first == " " else {
            return nil
        }
        let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
        return .heading(level: level, text: text)
    }

    private static func isBullet(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
    }

    /// The text after an ordered-list marker (`1.` / `2)`), or nil if not one.
    private static func orderedItem(_ line: String) -> String? {
        var digits = ""
        var rest = Substring(line)
        while let c = rest.first, c.isNumber {
            digits.append(c)
            rest = rest.dropFirst()
        }
        guard !digits.isEmpty, let sep = rest.first, sep == "." || sep == ")" else {
            return nil
        }
        rest = rest.dropFirst()
        guard rest.first == " " else { return nil }
        return String(rest.dropFirst())
    }
}
