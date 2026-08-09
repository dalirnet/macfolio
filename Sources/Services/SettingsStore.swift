import Combine
import Foundation

/// App settings: which AI backend co-authors the project, and its configuration.
/// Three backends: the Claude Code CLI (agentic, with its own file tools), the
/// Claude API, and OpenAI — the latter two hosted through one OpenAI-compatible
/// chat loop against fixed endpoints. Persisted to `~/.config/macfolio/settings.json`.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var provider: Provider { didSet { save() } }

    // Claude model, shared by the Claude Code CLI and the Claude API.
    @Published var model: Model { didSet { save() } }
    // Claude Code only — the CLI's file-tool permission mode.
    @Published var permissionMode: PermissionMode { didSet { save() } }

    // API backends: a key each, and OpenAI's model.
    @Published var claudeAPIKey: String { didSet { save() } }
    @Published var openAIKey: String { didSet { save() } }
    @Published var openAIModel: OpenAIModel { didSet { save() } }

    // Network: how every backend reaches the internet (see `Proxy`).
    @Published var proxyMode: ProxyMode { didSet { save() } }
    @Published var proxyURL: String { didSet { save() } }

    /// The co-authoring backend.
    enum Provider: String, CaseIterable, Identifiable, Codable {
        case claudeCode
        case claudeAPI
        case openAI

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .claudeCode: return "Claude Code"
            case .claudeAPI: return "Claude API"
            case .openAI: return "OpenAI"
            }
        }
    }

    /// Providers offered on this platform. The Claude Code CLI is macOS-only, so
    /// iOS shows the two API backends.
    static var availableProviders: [Provider] {
        #if os(macOS)
            return Provider.allCases
        #else
            return [.claudeAPI, .openAI]
        #endif
    }

    /// The default backend when there's no saved setting.
    static var defaultProvider: Provider {
        #if os(macOS)
            return .claudeCode
        #else
            return .claudeAPI
        #endif
    }

    enum Model: String, CaseIterable, Identifiable, Codable {
        case opus = "claude-opus-4-8"
        case sonnet = "claude-sonnet-5"
        case haiku = "claude-haiku-4-5-20251001"

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .opus: return "Claude Opus 4.8"
            case .sonnet: return "Claude Sonnet 5"
            case .haiku: return "Claude Haiku 4.5"
            }
        }
    }

    enum OpenAIModel: String, CaseIterable, Identifiable, Codable {
        case gpt4o = "gpt-4o"
        case gpt4oMini = "gpt-4o-mini"
        case gpt41 = "gpt-4.1"
        case gpt41Mini = "gpt-4.1-mini"

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .gpt4o: return "GPT-4o"
            case .gpt4oMini: return "GPT-4o mini"
            case .gpt41: return "GPT-4.1"
            case .gpt41Mini: return "GPT-4.1 mini"
            }
        }
    }

    /// Where the proxy comes from. "System" follows the proxy macOS is configured
    /// with; "Custom" uses the address typed in Settings. Either way it applies to
    /// the API backends *and* the Claude Code CLI — a launched `.app` never
    /// inherits the shell's `HTTPS_PROXY`, so it has to be resolved here.
    enum ProxyMode: String, CaseIterable, Identifiable, Codable {
        case system
        case custom

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .system: return "System Proxy"
            case .custom: return "Custom Proxy"
            }
        }
    }

    /// Claude Code `--permission-mode` values. Headless `-p` can't answer prompts,
    /// so `bypassPermissions` (the default) avoids denials.
    enum PermissionMode: String, CaseIterable, Identifiable, Codable {
        case bypassPermissions
        case acceptEdits
        case `default`
        case plan

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .bypassPermissions: return "Bypass (no prompts)"
            case .acceptEdits: return "Accept Edits"
            case .default: return "Default"
            case .plan: return "Plan"
            }
        }
    }

    /// A value that changes whenever the *availability* of the chosen backend
    /// might change, so the UI can re-check (show/hide the AI bar) on any edit.
    var aiSignature: String {
        "\(provider.rawValue)|\(claudeAPIKey.isEmpty ? "0" : "1")|\(openAIKey.isEmpty ? "0" : "1")"
    }

    private var loading = true
    private static let file = Paths.support("settings.json")

    private struct Snapshot: Codable {
        var provider: Provider
        var model: Model
        var permissionMode: PermissionMode
        var claudeAPIKey: String
        var openAIKey: String
        var openAIModel: OpenAIModel
        var proxyMode: ProxyMode
        var proxyURL: String

        init(_ store: SettingsStore) {
            provider = store.provider
            model = store.model
            permissionMode = store.permissionMode
            claudeAPIKey = store.claudeAPIKey
            openAIKey = store.openAIKey
            openAIModel = store.openAIModel
            proxyMode = store.proxyMode
            proxyURL = store.proxyURL
        }

        // Lenient: missing keys (older settings files) fall back to defaults.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            provider =
                (try? c.decode(Provider.self, forKey: .provider)) ?? SettingsStore.defaultProvider
            model = (try? c.decode(Model.self, forKey: .model)) ?? .opus
            permissionMode =
                (try? c.decode(PermissionMode.self, forKey: .permissionMode)) ?? .bypassPermissions
            claudeAPIKey = (try? c.decode(String.self, forKey: .claudeAPIKey)) ?? ""
            openAIKey = (try? c.decode(String.self, forKey: .openAIKey)) ?? ""
            openAIModel = (try? c.decode(OpenAIModel.self, forKey: .openAIModel)) ?? .gpt4o
            proxyMode = (try? c.decode(ProxyMode.self, forKey: .proxyMode)) ?? .system
            proxyURL = (try? c.decode(String.self, forKey: .proxyURL)) ?? ""
        }
    }

    private init() {
        let snapshot = Self.read()
        let saved = snapshot?.provider ?? Self.defaultProvider
        // A settings file synced from macOS may name Claude Code, which iOS can't
        // run — fall back to the platform default so the picker stays valid.
        provider = Self.availableProviders.contains(saved) ? saved : Self.defaultProvider
        model = snapshot?.model ?? .opus
        permissionMode = snapshot?.permissionMode ?? .bypassPermissions
        claudeAPIKey = snapshot?.claudeAPIKey ?? ""
        openAIKey = snapshot?.openAIKey ?? ""
        openAIModel = snapshot?.openAIModel ?? .gpt4o
        proxyMode = snapshot?.proxyMode ?? .system
        proxyURL = snapshot?.proxyURL ?? ""
        loading = false
    }

    private func save() {
        guard !loading, let data = try? JSONEncoder().encode(Snapshot(self)) else { return }
        try? data.write(to: Self.file)
    }

    private static func read() -> Snapshot? {
        guard let data = try? Data(contentsOf: Self.file) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
}
