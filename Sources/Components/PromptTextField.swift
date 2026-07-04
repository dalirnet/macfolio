import AppKit
import SwiftUI

/// A borderless, auto-growing prompt input backed by `NSTextView`.
///
/// SwiftUI's `TextField` won't do right-to-left on macOS (the plain style ignores
/// `multilineTextAlignment`, and the field ignores `layoutDirection` for its
/// content), so Persian/Arabic always render left-aligned. `NSTextView` with a
/// *natural* base writing direction handles bidi the way the web's `dir="auto"`
/// does: Persian types RTL, Latin LTR, decided per line from the text itself.
///
/// Grows with content between `minHeight` and `maxHeight` (then scrolls). Return
/// submits; Shift+Return inserts a newline.
struct PromptTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let placeholder: String
    let isEnabled: Bool
    let font: NSFont
    let minHeight: CGFloat
    let maxHeight: CGFloat
    /// Bumped by the parent to pull focus back into the field.
    let focusToken: Int
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PromptTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.font = font
        textView.textColor = .labelColor
        textView.insertionPointColor = NSColor(Theme.primary)
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.allowsUndo = true
        textView.placeholder = placeholder
        textView.placeholderFont = font
        textView.string = text
        context.coordinator.textView = textView
        context.coordinator.applyDirection()

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? PromptTextView else { return }
        context.coordinator.parent = self
        if textView.string != text { textView.string = text }
        textView.isEditable = isEnabled
        textView.placeholder = placeholder
        context.coordinator.applyDirection()
        textView.needsDisplay = true

        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
        DispatchQueue.main.async { context.coordinator.recomputeHeight() }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptTextField
        weak var textView: PromptTextView?
        var lastFocusToken: Int

        init(_ parent: PromptTextField) {
            self.parent = parent
            self.lastFocusToken = parent.focusToken
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            applyDirection()
            recomputeHeight()
        }

        /// Direction from the text itself (first strong character), like the web's
        /// `dir="auto"`. `NSTextAlignment.natural` can't do this — it follows the
        /// app's localization (LTR), which is why Persian stayed left-aligned.
        /// Also pins the line height so LTR (Sofia) and RTL (Dana) rows match.
        func applyDirection() {
            guard let textView else { return }
            let rtl = Bidi.isRTL(textView.string)
            textView.baseWritingDirection = rtl ? .rightToLeft : .leftToRight

            let style = NSMutableParagraphStyle()
            style.alignment = rtl ? .right : .left
            style.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
            let lineHeight = Theme.lineHeight(parent.font.pointSize)
            style.minimumLineHeight = lineHeight
            style.maximumLineHeight = lineHeight

            textView.defaultParagraphStyle = style
            textView.typingAttributes[.paragraphStyle] = style
            textView.typingAttributes[.font] = parent.font
            if let storage = textView.textStorage, storage.length > 0 {
                storage.addAttribute(
                    .paragraphStyle, value: style,
                    range: NSRange(location: 0, length: storage.length))
            }
        }

        // Return submits; Shift+Return inserts a newline.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.onSubmit()
            }
            return true
        }

        /// Size to the text between the min/max, then let it scroll.
        func recomputeHeight() {
            guard let textView, let manager = textView.layoutManager,
                let container = textView.textContainer
            else { return }
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container).height
            let content = used + textView.textContainerInset.height * 2
            let clamped = min(max(content, parent.minHeight), parent.maxHeight)
            if abs(parent.height - clamped) > 0.5 { parent.height = clamped }
            textView.enclosingScrollView?.hasVerticalScroller = content > parent.maxHeight
        }
    }
}

/// `NSTextView` that paints a placeholder while empty.
final class PromptTextView: NSTextView {
    var placeholder = ""
    var placeholderFont: NSFont?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.placeholderTextColor,
            .font: placeholderFont ?? font ?? NSFont.systemFont(ofSize: 12),
        ]
        let origin = NSPoint(
            x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
            y: textContainerInset.height)
        placeholder.draw(at: origin, withAttributes: attributes)
    }
}
