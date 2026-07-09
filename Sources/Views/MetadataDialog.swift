import AppKit

/// The chapter metadata prompt — a native alert (like Settings) for editing a
/// file's frontmatter: title, order, draft flag, date, and tags. Opened from the
/// sidebar's context menu; on save it writes the block back via `ProjectStore`.
enum MetadataDialog {
    @MainActor
    static func present(_ file: ProjectFile) {
        var meta = ProjectStore.shared.metadata(of: file)

        let titleField = DialogField.textField(meta.title)
        let orderField = DialogField.numberField(meta.order)
        let dateField = DialogField.textField(meta.date)
        let statusPopup = DialogField.popup(["Published", "Draft"])
        statusPopup.selectItem(at: meta.draft ? 1 : 0)
        let tagsField = DialogField.textField(meta.tags.joined(separator: ", "))

        let alert = NSAlert()
        alert.messageText = "Metadata"
        alert.informativeText = file.title
        alert.accessoryView = DialogField.accessory([
            DialogField.labeled("Title", titleField),
            DialogField.labeled("Order", orderField, hint: "sidebar position"),
            DialogField.labeled("Date", dateField, hint: "YYYY-MM-DD"),
            DialogField.labeled("Status", statusPopup),
            DialogField.labeled("Tags", tagsField, hint: "comma-separated"),
        ])
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let apply: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            // Start from the current metadata so preserved `extra` keys survive.
            meta.title = titleField.stringValue.trimmingCharacters(in: .whitespaces)
            meta.order = Int(orderField.stringValue.trimmingCharacters(in: .whitespaces))
            meta.date = dateField.stringValue.trimmingCharacters(in: .whitespaces)
            meta.draft = statusPopup.indexOfSelectedItem == 1
            meta.tags = commaList(tagsField.stringValue)
            ProjectStore.shared.updateMetadata(meta, for: file)
        }

        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(alert.runModal())
        }
    }

    private static func commaList(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
