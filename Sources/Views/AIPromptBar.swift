import AppKit
import SwiftUI

extension View {
    /// The prompt row's inset field look: a solid rounded field with inner
    /// padding, sitting inside the bar. No border.
    func promptFieldStyle() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
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
    /// Start a fresh agent session (clear its memory of this project).
    let onNewSession: () -> Void
    /// Whether there's a conversation to reset (drives the new-session button).
    let canStartNewSession: Bool

    @State private var draft = ""
    @State private var inputHeight: CGFloat = AIPromptBar.rowHeight
    /// Measured height of the reply, so its box grows with content (up to a cap).
    @State private var responseHeight: CGFloat = 0
    /// Bumped to pull focus into the field (e.g. tapping the row's padding).
    @State private var focusToken = 0

    /// Cap the reply box; beyond this it scrolls.
    private let maxResponseHeight: CGFloat = 200
    /// One-line height of the prompt (pinned line height + text-view insets), used
    /// as the row's minimum so the input and the working status are the same size.
    static let rowHeight: CGFloat = Theme.lineHeight(12.5) + 4

    /// What to show in the reply area: the streaming text while a turn runs, then
    /// the authoritative final reply. Nil when there's nothing to show yet.
    private var displayedReply: String? {
        if chat.working { return chat.liveReply.isEmpty ? nil : chat.liveReply }
        return chat.reply
    }

    var body: some View {
        VStack(spacing: 0) {
            if let text = displayedReply {
                response(text)
            }
            promptRow
        }
        // Responsive: span the editor's width (with the side margins below)
        // rather than a fixed cap, so the bar follows the window as it resizes.
        .frame(maxWidth: .infinity)
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

    // MARK: - Prompt row (leading icon + input / status)

    private var promptRow: some View {
        HStack(spacing: 8) {
            leadingIcon
            if chat.working {
                // Live status — no spinner prefix; the leading icon carries it.
                Text(chat.activity.last ?? "thinking")
                    .font(Theme.mono(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(chat.activity.last)
                    .transition(.opacity)
            } else {
                // NSTextView-backed so Persian/Arabic type right-to-left naturally.
                PromptTextField(
                    text: $draft,
                    height: $inputHeight,
                    placeholder: "Ask AI",
                    isEnabled: !disabled,
                    font: Theme.nsUI(12.5),
                    minHeight: AIPromptBar.rowHeight,
                    maxHeight: 96,
                    focusToken: focusToken,
                    onSubmit: submit
                )
                .frame(height: inputHeight)
                if canStartNewSession {
                    newSessionButton
                }
            }
        }
        .frame(minHeight: AIPromptBar.rowHeight)
        .promptFieldStyle()
        .contentShape(Rectangle())
        .onTapGesture { if !chat.working { focusToken += 1 } }
        .animation(.easeInOut(duration: 0.15), value: chat.activity.last)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Leading indicator: a sparkle "send" button when idle (submits; dimmed when
    /// empty), a spinner while a turn runs. Fixed slot so the row doesn't shift.
    private var leadingIcon: some View {
        Group {
            if chat.working {
                ProgressView().controlSize(.small).tint(.accentColor)
            } else {
                Button(action: submit) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 14))
                        .foregroundStyle(canSubmit ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .help("Ask AI")
            }
        }
        .frame(width: 18, height: 18)
    }

    /// Trailing button to start a fresh session — clears the agent's memory of the
    /// project, so the next prompt has no prior context.
    private var newSessionButton: some View {
        Button(action: onNewSession) {
            Image(systemName: "plus.bubble")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help("New session — clear the agent's memory of this project")
    }

    private var canSubmit: Bool {
        !disabled && !trimmed.isEmpty
    }

    // MARK: - Response

    private func response(_ text: String) -> some View {
        // A short, plain-text reply (the agent is asked not to use Markdown here).
        // The box sizes to the content, capped at `maxResponseHeight` then scrolls.
        // No header/close button: type a new prompt below to move on.
        let rtl = Bidi.isRTL(text)
        return VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                Text(text)
                    .font(Theme.ui(12.5))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .multilineTextAlignment(rtl ? .trailing : .leading)
                    .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: ResponseHeightKey.self, value: geo.size.height)
                        }
                    )
            }
            .frame(height: min(responseHeight, maxResponseHeight))
            .onPreferenceChange(ResponseHeightKey.self) { responseHeight = $0 }

            if let usage = chat.usage {
                tokenUsage(usage)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    /// The turn's token usage: ↑ input (what you send to the agent), ↓ output
    /// (what it sends back). Shown under the reply.
    private func tokenUsage(_ usage: AgentUsage) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.up").font(.system(size: 8, weight: .bold))
            Text(AIPromptBar.short(usage.inputTokens))
            Image(systemName: "arrow.down").font(.system(size: 8, weight: .bold))
                .padding(.leading, 8)
            Text(AIPromptBar.short(usage.outputTokens))
        }
        .font(Theme.mono(10.5))
        .foregroundStyle(.primary)
    }

    /// Compact token count: 1234 → "1.2k".
    private static func short(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
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
