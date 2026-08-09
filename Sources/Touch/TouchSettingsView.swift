#if os(iOS)
    import SwiftUI

    /// The iOS settings sheet — the SwiftUI form counterpart of the Mac
    /// `SettingsDialog`. Picks the AI provider (API backends only; the Claude Code
    /// CLI can't run on iOS) and its key + model. Bindings write straight through to
    /// `SettingsStore`, which persists on change.
    struct TouchSettingsView: View {
        @ObservedObject private var settings = SettingsStore.shared
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                Form {
                    Section("AI Provider") {
                        Picker("Provider", selection: $settings.provider) {
                            ForEach(SettingsStore.availableProviders) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                    }

                    switch settings.provider {
                    case .claudeAPI:
                        Section("Claude API") {
                            Picker("Model", selection: $settings.model) {
                                ForEach(SettingsStore.Model.allCases) { model in
                                    Text(model.displayName).tag(model)
                                }
                            }
                            SecureField("API Key", text: $settings.claudeAPIKey)
                                .textContentType(.password)
                        }
                    case .openAI:
                        Section("OpenAI") {
                            Picker("Model", selection: $settings.openAIModel) {
                                ForEach(SettingsStore.OpenAIModel.allCases) { model in
                                    Text(model.displayName).tag(model)
                                }
                            }
                            SecureField("API Key", text: $settings.openAIKey)
                                .textContentType(.password)
                        }
                    case .claudeCode:
                        EmptyView()
                    }

                    Section("Network") {
                        Picker("Proxy", selection: $settings.proxyMode) {
                            ForEach(SettingsStore.ProxyMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        if settings.proxyMode == .custom {
                            TextField("http://127.0.0.1:3128", text: $settings.proxyURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                        }
                    }
                }
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
    }
#endif
