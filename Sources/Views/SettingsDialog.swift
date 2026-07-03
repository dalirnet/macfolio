import AppKit

/// The Settings prompt — a native alert (like the Table/Link dialogs) with native
/// popups for the model and permission mode. A SwiftUI `.alert` can't host a
/// Picker, so this is built with AppKit. The project folder isn't shown here — the
/// sidebar's "Reveal in Finder" opens it.
enum SettingsDialog {
    @MainActor
    static func present() {
        let settings = SettingsStore.shared
        let models = SettingsStore.Model.allCases
        let modes = SettingsStore.PermissionMode.allCases

        let modelPopup = DialogField.popup(models.map { $0.displayName })
        modelPopup.selectItem(at: models.firstIndex(of: settings.model) ?? 0)
        let modePopup = DialogField.popup(modes.map { $0.displayName })
        modePopup.selectItem(at: modes.firstIndex(of: settings.permissionMode) ?? 0)

        let alert = NSAlert()
        alert.messageText = "Settings"
        alert.accessoryView = DialogField.accessory([
            DialogField.labeled("Model", modelPopup),
            DialogField.labeled("Permissions", modePopup),
        ])
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Cancel")

        let apply: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            if models.indices.contains(modelPopup.indexOfSelectedItem) {
                settings.model = models[modelPopup.indexOfSelectedItem]
            }
            if modes.indices.contains(modePopup.indexOfSelectedItem) {
                settings.permissionMode = modes[modePopup.indexOfSelectedItem]
            }
        }

        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(alert.runModal())
        }
    }
}
