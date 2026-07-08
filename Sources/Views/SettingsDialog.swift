import AppKit

/// The Settings prompt — a native alert (like the Table/Link dialogs). A top popup
/// picks the AI provider; the fields below switch to match:
///   • Claude Code — model + permission mode (the CLI's file-tool permissions).
///   • Claude API  — API key + model.
///   • OpenAI      — API key + model.
/// A SwiftUI `.alert` can't host these, so it's built with AppKit.
enum SettingsDialog {
    @MainActor
    static func present() {
        let settings = SettingsStore.shared
        let providers = SettingsStore.availableProviders
        let models = SettingsStore.Model.allCases
        let openAIModels = SettingsStore.OpenAIModel.allCases
        let modes = SettingsStore.PermissionMode.allCases

        let providerPopup = DialogField.callbackPopup(providers.map { $0.displayName })
        providerPopup.selectItem(at: providers.firstIndex(of: settings.provider) ?? 0)

        // Claude model — its own popup per section (a control lives in one place).
        func claudeModelPopup() -> NSPopUpButton {
            let popup = DialogField.popup(models.map { $0.displayName })
            popup.selectItem(at: models.firstIndex(of: settings.model) ?? 0)
            return popup
        }

        // Claude Code section.
        let codeModelPopup = claudeModelPopup()
        let modePopup = DialogField.popup(modes.map { $0.displayName })
        modePopup.selectItem(at: modes.firstIndex(of: settings.permissionMode) ?? 0)
        let claudeCodeSection = DialogField.section([
            DialogField.labeled("Model", codeModelPopup),
            DialogField.labeled("Permissions", modePopup),
        ])

        // Claude API section.
        let claudeKeyField = DialogField.secureField(settings.claudeAPIKey)
        let apiModelPopup = claudeModelPopup()
        let claudeAPISection = DialogField.section([
            DialogField.labeled("Model", apiModelPopup),
            DialogField.labeled("API Key", claudeKeyField),
        ])

        // OpenAI section.
        let openAIKeyField = DialogField.secureField(settings.openAIKey)
        let openAIModelPopup = DialogField.popup(openAIModels.map { $0.displayName })
        openAIModelPopup.selectItem(at: openAIModels.firstIndex(of: settings.openAIModel) ?? 0)
        let openAISection = DialogField.section([
            DialogField.labeled("Model", openAIModelPopup),
            DialogField.labeled("API Key", openAIKeyField),
        ])

        let accessory = DialogField.accessory([
            DialogField.labeled("AI Provider", providerPopup),
            claudeCodeSection,
            claudeAPISection,
            openAISection,
        ])

        let alert = NSAlert()
        alert.messageText = "Settings"
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Cancel")

        // Show only the selected provider's section, then resize the accessory to
        // fit and re-lay out the alert — so the dialog grows/shrinks to the visible
        // fields instead of leaving a gap under a shorter section.
        let sync = {
            let index = providerPopup.indexOfSelectedItem
            let provider = providers.indices.contains(index) ? providers[index] : .claudeCode
            claudeCodeSection.isHidden = provider != .claudeCode
            claudeAPISection.isHidden = provider != .claudeAPI
            openAISection.isHidden = provider != .openAI
            accessory.layoutSubtreeIfNeeded()
            accessory.frame.size = accessory.fittingSize
            alert.layout()
        }
        providerPopup.onChange = sync
        sync()

        let apply: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let index = providerPopup.indexOfSelectedItem
            let provider = providers.indices.contains(index) ? providers[index] : settings.provider
            settings.provider = provider

            // Persist only the selected provider's fields (the others' controls
            // still hold their loaded values, so nothing is lost either way).
            switch provider {
            case .claudeCode:
                if models.indices.contains(codeModelPopup.indexOfSelectedItem) {
                    settings.model = models[codeModelPopup.indexOfSelectedItem]
                }
                if modes.indices.contains(modePopup.indexOfSelectedItem) {
                    settings.permissionMode = modes[modePopup.indexOfSelectedItem]
                }
            case .claudeAPI:
                settings.claudeAPIKey = claudeKeyField.stringValue
                if models.indices.contains(apiModelPopup.indexOfSelectedItem) {
                    settings.model = models[apiModelPopup.indexOfSelectedItem]
                }
            case .openAI:
                settings.openAIKey = openAIKeyField.stringValue
                if openAIModels.indices.contains(openAIModelPopup.indexOfSelectedItem) {
                    settings.openAIModel = openAIModels[openAIModelPopup.indexOfSelectedItem]
                }
            }
        }

        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(alert.runModal())
        }
    }
}
