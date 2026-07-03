import AppKit

/// Shared builders for the native alert accessories — a caption above each
/// control — so the Settings / Table / Link dialogs share one labelled-input look.
enum DialogField {
    static let width: CGFloat = 240

    /// A caption stacked above its control, with an optional right-aligned hint on
    /// the caption line.
    static func labeled(_ label: String, _ control: NSView, hint: String? = nil) -> NSView {
        let caption = NSTextField(labelWithString: label)
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = .secondaryLabelColor

        let header: NSView
        if let hint {
            caption.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            let note = NSTextField(labelWithString: hint)
            note.font = .systemFont(ofSize: 11)
            note.textColor = .tertiaryLabelColor
            note.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            let spacer = NSView()  // low hugging → stretches, pushing the hint right
            let row = NSStackView(views: [caption, spacer, note])
            row.orientation = .horizontal
            row.spacing = 8
            row.widthAnchor.constraint(equalToConstant: width).isActive = true
            header = row
        } else {
            header = caption
        }

        let stack = NSStackView(views: [header, control])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    /// Stack labelled fields into a sized accessory view for an `NSAlert`.
    static func accessory(_ fields: [NSView]) -> NSView {
        let stack = NSStackView(views: fields)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = true
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        return stack
    }

    static func textField(_ value: String) -> NSTextField {
        let field = NSTextField(string: value)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    static func popup(_ titles: [String]) -> NSPopUpButton {
        let popup = NSPopUpButton()
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.addItems(withTitles: titles)
        popup.widthAnchor.constraint(equalToConstant: width).isActive = true
        return popup
    }
}
