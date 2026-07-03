import SwiftUI

/// Settings sheet: model and permission mode for the agent, plus where
/// projects live.
struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings")
                .font(.system(size: 15, weight: .semibold))

            Field(label: "Model") {
                Picker("", selection: $settings.model) {
                    ForEach(SettingsStore.Model.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Field(label: "Permissions") {
                Picker("", selection: $settings.permissionMode) {
                    ForEach(SettingsStore.PermissionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Field(label: "Projects at") {
                Text(Paths.projectsHome.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
