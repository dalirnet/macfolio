import SwiftUI

/// A project's snapshot history — the git log, newest first. The current snapshot
/// is marked; older ones can be restored (non-destructive) or removed. Presented as
/// a sheet from the sidebar's project menu.
struct HistoryView: View {
    let project: Project
    /// Called after files may have changed (restore/remove) so the caller can
    /// refresh the editor/sidebar.
    let onRestore: () -> Void
    let onClose: () -> Void

    @State private var commits: [GitCommit] = []
    @State private var head: String?
    @State private var loading = true
    @State private var pendingDelete: GitCommit?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 460, height: 440)
        .task { await load() }
        .confirmationDialog(
            "Delete this snapshot?",
            isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { commit in
            Button("Delete", role: .destructive) { remove(commit) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the snapshot from history and can't be undone.")
        }
    }

    private var header: some View {
        HStack {
            Text("History — \(project.title)")
                .font(Theme.ui(13, .semibold))
            Spacer()
            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            Spacer()
            ProgressView().controlSize(.small)
            Spacer()
        } else if commits.isEmpty {
            EmptyState("No snapshots yet", icon: "clock.arrow.circlepath")
        } else {
            List(commits) { commit in
                row(commit, isCurrent: commit.hash == head, isRoot: commit.id == commits.last?.id)
            }
            .listStyle(.inset)
        }
    }

    private func row(_ commit: GitCommit, isCurrent: Bool, isRoot: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(commit.subject)
                        .font(Theme.ui(12.5))
                        .lineLimit(1)
                    if isCurrent { currentBadge }
                }
                HStack(spacing: 6) {
                    Text(commit.relativeDate)
                    Text(commit.shortHash).font(Theme.mono(10.5))
                }
                .font(Theme.ui(11))
                .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                if !isCurrent {
                    Button("Restore") { restore(commit) }
                }
                // The first snapshot has no parent, so it can't be removed.
                Button("Delete", role: .destructive) { pendingDelete = commit }
                    .disabled(isRoot)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 3)
    }

    private var currentBadge: some View {
        Text("Current")
            .font(Theme.ui(10, .medium))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.14), in: Capsule())
    }

    // MARK: - Actions

    private func load() async {
        let project = project
        let (log, headHash) = await Task.detached {
            (GitService.shared.history(project), GitService.shared.headHash(project))
        }.value
        commits = log
        head = headHash
        loading = false
    }

    private func restore(_ commit: GitCommit) {
        let project = project
        Task {
            _ = await Task.detached { GitService.shared.restore(project, to: commit) }.value
            onRestore()
            onClose()
        }
    }

    private func remove(_ commit: GitCommit) {
        let project = project
        Task {
            _ = await Task.detached { GitService.shared.removeSnapshot(project, commit) }.value
            onRestore()  // the working tree may have shifted
            await load()  // refresh the list, stay open
        }
    }
}
