#if os(iOS)
    import SwiftUI
    import UIKit

    extension View {
        /// The prompt row's inset field look: a solid rounded field with inner
        /// padding, sitting inside the bar (mirrors the Mac `promptFieldStyle`).
        fileprivate func touchPromptFieldStyle() -> some View {
            frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// The iOS AI prompt bar — the SwiftUI-only sibling of the Mac `AIPromptBar`,
    /// matching its layout: the input row (an inset field inside a frosted bar)
    /// while idle, a live status with a stop button while a turn runs, and the
    /// agent's reply above the input once it finishes. State is driven by
    /// `ChatStore`; `disabled` is true when no document is open.
    struct TouchAIBar: View {
        @ObservedObject private var chat = ChatStore.shared

        let disabled: Bool
        let onSubmit: (String) -> Void
        let onCancel: () -> Void
        let onNewSession: () -> Void
        let canStartNewSession: Bool

        @State private var draft = ""
        @State private var responseHeight: CGFloat = 0
        @FocusState private var focused: Bool

        /// Cap the reply box; beyond this it scrolls (matches the Mac bar).
        private let maxResponseHeight: CGFloat = 200

        /// The streaming text while a turn runs, then the authoritative final reply.
        private var displayedReply: String? {
            if chat.working { return chat.liveReply.isEmpty ? nil : chat.liveReply }
            return chat.reply
        }

        private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
        private var canSubmit: Bool { !disabled && !trimmed.isEmpty && !chat.working }

        var body: some View {
            VStack(spacing: 0) {
                if let text = displayedReply { response(text) }
                promptRow
            }
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.16), radius: 14, y: 5)
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
            .animation(.easeInOut(duration: 0.2), value: chat.working)
            .animation(.easeInOut(duration: 0.2), value: chat.reply)
            .animation(.easeInOut(duration: 0.15), value: responseHeight)
        }

        // MARK: - Prompt row (leading icon + input / status)

        private var promptRow: some View {
            HStack(spacing: 8) {
                leadingIcon
                if chat.working {
                    Text(chat.activity.last ?? "thinking")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    stopButton
                } else {
                    TextField("Ask AI", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .font(.system(size: 12.5))
                        .focused($focused)
                        .disabled(disabled)
                        .submitLabel(.send)
                        .onSubmit(submit)
                        .multilineTextAlignment(Bidi.isRTL(draft) ? .trailing : .leading)
                    if canStartNewSession { newSessionButton }
                }
            }
            .frame(minHeight: 22)
            .touchPromptFieldStyle()
            .contentShape(Rectangle())
            .onTapGesture { if !chat.working { focused = true } }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }

        /// Leading indicator: a sparkle "send" button when idle (dimmed when empty),
        /// a spinner while a turn runs. Fixed slot so the row doesn't shift.
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
                    .disabled(!canSubmit)
                }
            }
            .frame(width: 18, height: 18)
        }

        /// Trailing stop button while a turn runs — cancels it.
        private var stopButton: some View {
            Button(action: onCancel) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }

        /// Trailing button to start a fresh session — clears the agent's memory of
        /// the project, so the next prompt has no prior context.
        private var newSessionButton: some View {
            Button(action: onNewSession) {
                Image(systemName: "plus.bubble")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .disabled(disabled)
        }

        // MARK: - Response

        private func response(_ text: String) -> some View {
            let rtl = Bidi.isRTL(text)
            return VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    Text(text)
                        .font(.system(size: 12.5))
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

                if let usage = chat.usage { tokenUsage(usage) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }

        /// The turn's token usage: ↑ input, ↓ output. Shown under the reply.
        private func tokenUsage(_ usage: AgentUsage) -> some View {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up").font(.system(size: 8, weight: .bold))
                Text(Self.short(usage.inputTokens))
                Image(systemName: "arrow.down").font(.system(size: 8, weight: .bold))
                    .padding(.leading, 8)
                Text(Self.short(usage.outputTokens))
            }
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.primary)
        }

        private static func short(_ n: Int) -> String {
            n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
        }

        private func submit() {
            let text = trimmed
            guard !text.isEmpty, !disabled, !chat.working else { return }
            draft = ""
            onSubmit(text)
        }
    }

    /// The reply text's measured height, so its box can size to content.
    private struct ResponseHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }
#endif
