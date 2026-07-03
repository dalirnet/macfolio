import AppKit
import SwiftUI

/// An image file discovered in the project, offered by the media picker.
struct MediaItem: Identifiable, Hashable {
    let url: URL
    /// Path relative to the current `.md` file — what goes in the Markdown.
    let src: String

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var alt: String { url.deletingPathExtension().lastPathComponent }
}

/// Bridges the WebView editor's dialog requests to SwiftUI sheets and carries the
/// results back. The EditorView coordinator sets `dialog` (from a WebView message)
/// and fills in the callbacks; MainView observes `dialog` to present the sheets.
final class EditorBridge: ObservableObject {
    enum Dialog: Identifiable {
        case table
        case link(String)
        case image([MediaItem])

        var id: String {
            switch self {
            case .table: return "table"
            case .link: return "link"
            case .image: return "image"
            }
        }
    }

    @Published var dialog: Dialog?

    var insertTable: ((Int, Int) -> Void)?
    var setLink: ((String) -> Void)?
    var insertImage: ((String, String) -> Void)?
}

/// A small caption above its control — the shared field style for the dialogs.
struct Field<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Rows/columns picker for inserting a table.
struct TableDialogView: View {
    @State private var rows = 3
    @State private var cols = 3
    var onInsert: (Int, Int) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Insert Table")
                .font(.system(size: 15, weight: .semibold))

            HStack(spacing: 16) {
                counter("Rows", $rows)
                counter("Columns", $cols)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Insert") { onInsert(rows, cols) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func counter(_ label: String, _ value: Binding<Int>) -> some View {
        Field(label: label) {
            HStack(spacing: 6) {
                TextField("", value: value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                Stepper("", value: value, in: 1...20)
                    .labelsHidden()
            }
        }
    }
}

/// URL entry for adding / editing / removing a link.
struct LinkDialogView: View {
    @State private var url: String
    private let editing: Bool
    var onSubmit: (String) -> Void
    var onRemove: () -> Void
    var onCancel: () -> Void

    init(
        initialURL: String,
        onSubmit: @escaping (String) -> Void,
        onRemove: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        _url = State(initialValue: initialURL)
        editing = !initialURL.isEmpty
        self.onSubmit = onSubmit
        self.onRemove = onRemove
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(editing ? "Edit Link" : "Add Link")
                .font(.system(size: 15, weight: .semibold))

            Field(label: "URL") {
                TextField("", text: $url)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                if editing {
                    Button("Remove", role: .destructive, action: onRemove)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(editing ? "Save" : "Add") { onSubmit(url) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// A select box listing the project's images; inserts the chosen one.
struct ImageDialogView: View {
    let items: [MediaItem]
    @State private var selection: MediaItem.ID?
    var onInsert: (MediaItem) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Insert Image")
                .font(.system(size: 15, weight: .semibold))

            Field(label: "Project media") {
                if items.isEmpty {
                    Text("No images found in this project.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200, alignment: .center)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6).stroke(.separator))
                } else {
                    List(items, selection: $selection) { item in
                        HStack(spacing: 8) {
                            thumbnail(item.url)
                            Text(item.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .tag(item.id)
                    }
                    .listStyle(.bordered)
                    .frame(height: 220)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Insert") { insert() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func insert() {
        guard let id = selection,
            let item = items.first(where: { $0.id == id })
        else { return }
        onInsert(item)
    }

    private func thumbnail(_ url: URL) -> some View {
        Group {
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 26, height: 26)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
