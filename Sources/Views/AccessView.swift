import AppKit
import SwiftUI

/// First screen: confirms the Claude Code CLI is available, with a recheck.
/// Macfolio has no login of its own — it inherits the CLI's existing auth.
struct AccessView: View {
    var onComplete: () -> Void

    @State private var state: AccessState = .checking
    @State private var pulse: CGFloat = 1.0

    enum AccessState {
        case checking
        case available
        case unavailable
    }

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: 96, height: 96)
                    .scaleEffect(pulse)
                Circle()
                    .fill(Color.accentColor.opacity(0.06))
                    .frame(width: 72, height: 72)
                    .scaleEffect(pulse * 0.97)
                iconView
            }

            VStack(spacing: 4) {
                Text(statusTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)

                if let subtitle = statusSubtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 32)

            actionButtons
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.3), value: state)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulse = 1.08
            }
            Task { await check() }
        }
    }

    @ViewBuilder
    private var iconView: some View {
        switch state {
        case .checking:
            ProgressView().controlSize(.small)
        case .available:
            Image(systemName: "checkmark")
                .font(.system(size: 30, weight: .semibold))
                .foregroundColor(.accentColor)
        case .unavailable:
            Image(systemName: "terminal")
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(.accentColor)
        }
    }

    private var statusTitle: String {
        switch state {
        case .checking: return "Checking Claude Code"
        case .available: return "Claude Code ready"
        case .unavailable: return "Claude Code not found"
        }
    }

    private var statusSubtitle: String? {
        switch state {
        case .checking, .available:
            return nil
        case .unavailable:
            return "Macfolio needs the Claude Code CLI to write and revise your "
                + "manuscript. Install it, then recheck."
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch state {
        case .checking:
            EmptyView()
        case .available:
            Button("Continue") { onComplete() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .unavailable:
            VStack(spacing: 10) {
                Button("Recheck") { Task { await check() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                Button("Install Claude Code") {
                    if let url = URL(string: "https://docs.claude.com/en/docs/claude-code/setup") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            }
        }
    }

    private func check() async {
        state = .checking
        let available = await Task.detached { ClaudeService.shared.isAvailable() }.value
        state = available ? .available : .unavailable
    }
}
