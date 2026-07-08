#if os(iOS)
    import SwiftUI

    /// The chapter metadata sheet — the iOS counterpart of `MetadataDialog`. Edits
    /// the core fields (title, order, date, tags) and writes them back through
    /// `ProjectStore` on Save. Fields it doesn't surface are preserved. Opened from
    /// the sidebar's menu.
    struct TouchMetadataView: View {
        let file: ProjectFile

        @Environment(\.dismiss) private var dismiss

        /// The loaded metadata, kept so preserved `extra` keys survive a save.
        @State private var meta: Frontmatter
        @State private var orderText: String
        @State private var tagsText: String

        init(file: ProjectFile) {
            self.file = file
            let loaded = ProjectStore.shared.metadata(of: file)
            _meta = State(initialValue: loaded)
            _orderText = State(initialValue: loaded.order.map(String.init) ?? "")
            _tagsText = State(initialValue: loaded.tags.joined(separator: ", "))
        }

        var body: some View {
            NavigationStack {
                Form {
                    Section {
                        TextField("Title", text: $meta.title)
                    }
                    Section {
                        TextField("Order", text: $orderText)
                            .keyboardType(.numberPad)
                        TextField("Date (YYYY-MM-DD)", text: $meta.date)
                    }
                    Section("Tags") {
                        TextField("comma-separated", text: $tagsText)
                    }
                }
                .navigationTitle("Metadata")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save() }
                    }
                }
            }
        }

        private func save() {
            meta.title = meta.title.trimmingCharacters(in: .whitespaces)
            meta.order = Int(orderText.trimmingCharacters(in: .whitespaces))
            meta.date = meta.date.trimmingCharacters(in: .whitespaces)
            meta.tags = Self.commaList(tagsText)
            ProjectStore.shared.updateMetadata(meta, for: file)
            dismiss()
        }

        private static func commaList(_ value: String) -> [String] {
            value.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }
#endif
