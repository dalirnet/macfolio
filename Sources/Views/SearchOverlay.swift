import SwiftUI

#if os(macOS)

    /// A tiny search palette — opened with ⌘F, styled like the app's dialogs
    /// (frosted, rounded, floating). Runs `DocumentSearch` over every project's
    /// documents; each result shows the file, its project, and a snippet with the
    /// matched keyword highlighted. Enter opens the top result, Escape closes.
    struct SearchOverlay: View {
        /// Open a matched document — its project, file, and the query to jump to.
        let onOpen: (Project, ProjectFile, String) -> Void
        let onClose: () -> Void

        @State private var query = ""
        @State private var hits: [SearchHit] = []
        @FocusState private var focused: Bool

        private var trimmed: String {
            query.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var body: some View {
            ZStack(alignment: .top) {
                // Dimmed backdrop — click anywhere outside the panel to dismiss.
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onClose)

                panel
                    .padding(.top, 96)
            }
            .onExitCommand(perform: onClose)  // Escape
            .onChange(of: query) { hits = DocumentSearch.matches(for: $0) }
        }

        // MARK: - Panel

        private var panel: some View {
            VStack(spacing: 0) {
                field
                if !trimmed.isEmpty {
                    Divider()
                    resultsList
                }
            }
            .frame(width: 460)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            // The floating-surface shadow from AIPromptBar, lifted a touch for a
            // centered modal that sits above the editor.
            .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
        }

        private var field: some View {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                TextField("Search documents", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(14))
                    .focused($focused)
                    .onSubmit { if let first = hits.first { open(first) } }
                if !trimmed.isEmpty {
                    Text("\(hits.count)")
                        .font(Theme.mono(11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .onAppear { focused = true }
        }

        @ViewBuilder
        private var resultsList: some View {
            if hits.isEmpty {
                Text("No matches")
                    .font(Theme.ui(12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(hits) { hit in
                            row(hit)
                            if hit.id != hits.last?.id {
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }

        private func row(_ hit: SearchHit) -> some View {
            Button {
                open(hit)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(highlighted(hit.file.displayTitle))
                            .font(Theme.ui(13, .medium))
                            .lineLimit(1)
                        Text(hit.project.title)
                            .font(Theme.ui(11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if !hit.snippet.isEmpty {
                        Text(highlighted(hit.snippet))
                            .font(Theme.ui(11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        // MARK: - Actions

        private func open(_ hit: SearchHit) {
            onOpen(hit.project, hit.file, trimmed)
            onClose()
        }

        /// `source` with every case-insensitive occurrence of the query given an
        /// accent-tinted, bold highlight (size preserved from the base font).
        private func highlighted(_ source: String) -> AttributedString {
            var attr = AttributedString(source)
            let q = trimmed
            guard !q.isEmpty else { return attr }
            var cursor = source.startIndex
            while let range = source.range(
                of: q, options: .caseInsensitive, range: cursor..<source.endIndex),
                !range.isEmpty
            {
                if let lo = AttributedString.Index(range.lowerBound, within: attr),
                    let hi = AttributedString.Index(range.upperBound, within: attr)
                {
                    attr[lo..<hi].backgroundColor = Color.accentColor.opacity(0.25)
                    attr[lo..<hi].foregroundColor = .primary
                    attr[lo..<hi].inlinePresentationIntent = .stronglyEmphasized
                }
                cursor = range.upperBound
            }
            return attr
        }
    }

#endif
