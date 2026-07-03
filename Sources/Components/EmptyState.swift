import SwiftUI

/// Centered placeholder for empty panes (no book, no chapters, loading).
struct EmptyState: View {
    let message: String
    let icon: String

    init(_ message: String, icon: String) {
        self.message = message
        self.icon = icon
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}
