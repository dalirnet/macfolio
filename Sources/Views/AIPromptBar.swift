import AppKit
import SwiftUI

extension View {
    /// Show the text (I-beam) cursor over the whole area, not just the glyphs —
    /// so the padding around the field reads as an input, not a button.
    func textCursorOnHover() -> some View {
        onContinuousHover { phase in
            switch phase {
            case .active: NSCursor.iBeam.set()
            case .ended: NSCursor.arrow.set()
            }
        }
    }
}

/// A floating AI prompt overlaid on the bottom-center of the editor.
///
/// The input is always docked at the bottom; while a turn runs the input row
/// itself shows the live status, and once it finishes the reply sits above the
/// input — never a scrolling chat thread. Returning to a new prompt is just
/// typing: submitting clears the reply.
///
/// State is driven by `ChatStore`; `disabled` is true when no project is open.
struct AIPromptBar: View {
    @ObservedObject private var chat = ChatStore.shared

    let disabled: Bool
    let onSubmit: (String) -> Void

    @State private var draft = ""
    @State private var inputHeight: CGFloat = AIPromptBar.rowHeight
    /// Measured height of the reply, so its box grows with content (up to a cap).
    @State private var responseHeight: CGFloat = 0
    /// Bumped to pull focus into the field (tapping its padding, not just glyphs).
    @State private var focusToken = 0

    /// Cap the reply box; beyond this it scrolls.
    private let maxResponseHeight: CGFloat = 200
    /// One-line height of the prompt (pinned line height + text-view insets),
    /// shared by the field's minimum and the status row so nothing jumps.
    static let rowHeight: CGFloat = Theme.lineHeight(12.5) + 4

    var body: some View {
        VStack(spacing: 0) {
            if let reply = chat.reply, !chat.working {
                response(reply)
                divider
            }
            // The prompt row itself: the live status while a turn runs, else the
            // editable input — status sits *on* the prompt, not stacked above it.
            if chat.working {
                status
            } else {
                input
            }
        }
        .frame(maxWidth: 600)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            // Adaptive hairline so the edge reads in both light and dark, not
            // just over a dark editor.
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 14, y: 5)
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        // Publish the bar's live height so the editor can inset its bottom by
        // exactly this much — the bar grows/shrinks with its state, so it's auto.
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: AIPromptBarHeightKey.self, value: geo.size.height)
            }
        )
        .animation(.easeInOut(duration: 0.2), value: chat.working)
        .animation(.easeInOut(duration: 0.2), value: chat.reply)
        .animation(.easeInOut(duration: 0.15), value: responseHeight)
    }

    private var divider: some View {
        Divider().opacity(0.5)
    }

    // MARK: - Input (always docked at the bottom)

    private var input: some View {
        // NSTextView-backed so Persian/Arabic type right-to-left naturally (see
        // PromptTextField). No send button — Return submits — so the layout stays
        // neutral for both directions.
        PromptTextField(
            text: $draft,
            height: $inputHeight,
            placeholder: "ask claude…",
            isEnabled: !(disabled || chat.working),
            font: Theme.nsUI(12.5),
            minHeight: AIPromptBar.rowHeight,
            maxHeight: 96,
            focusToken: focusToken,
            onSubmit: submit
        )
        .frame(maxWidth: .infinity)
        .frame(height: inputHeight)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .onTapGesture { focusToken += 1 }
        .textCursorOnHover()
    }

    // MARK: - Status (while a turn runs)

    private var status: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(Theme.primary)
            Text(chat.activity.last ?? "thinking…")
                .font(Theme.mono(11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(chat.activity.last)
                .transition(.opacity)
        }
        // Match the input's single-line height so swapping input↔status doesn't
        // change the row height (no vertical blink on submit/finish).
        .frame(minHeight: AIPromptBar.rowHeight)
        .animation(.easeInOut(duration: 0.15), value: chat.activity.last)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - Response

    private func response(_ text: String) -> some View {
        // A short, plain-text reply (the agent is asked not to use Markdown here).
        // The box sizes to the content, capped at `maxResponseHeight` then scrolls.
        // No header/close button: type a new prompt below to move on.
        let rtl = Bidi.isRTL(text)
        return ScrollView {
            Text(text)
                .font(Theme.ui(12.5))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineSpacing(3)
                .multilineTextAlignment(rtl ? .trailing : .leading)
                .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ResponseHeightKey.self, value: geo.size.height)
                    }
                )
        }
        .frame(height: min(responseHeight, maxResponseHeight))
        .onPreferenceChange(ResponseHeightKey.self) { responseHeight = $0 }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - Actions

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        let text = trimmed
        guard !text.isEmpty, !disabled, !chat.working else { return }
        draft = ""
        onSubmit(text)
    }
}

/// The floating bar's measured height, so the editor can inset its bottom to
/// clear it. Reduces to the max (a single value is published, but be safe).
struct AIPromptBarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The reply text's measured height, so its box can size to content.
private struct ResponseHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
