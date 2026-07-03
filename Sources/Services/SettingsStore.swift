import Combine
import Foundation

/// App settings: the model and Claude Code permission mode the agent runs with.
/// Persisted to `~/.config/macfolio/settings.json`.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var model: Model { didSet { save() } }
    @Published var permissionMode: PermissionMode { didSet { save() } }

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

    private var loading = true
    private static let file = Paths.support("settings.json")

    private struct Snapshot: Codable {
        var model: Model
        var permissionMode: PermissionMode

        init(model: Model, permissionMode: PermissionMode) {
            self.model = model
            self.permissionMode = permissionMode
        }

        // Lenient: missing keys (older settings files) fall back to defaults.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            model = (try? c.decode(Model.self, forKey: .model)) ?? .opus
            permissionMode =
                (try? c.decode(PermissionMode.self, forKey: .permissionMode)) ?? .bypassPermissions
        }
    }

    private init() {
        let snapshot = Self.read()
        model = snapshot?.model ?? .opus
        permissionMode = snapshot?.permissionMode ?? .bypassPermissions
        loading = false
    }

    private func save() {
        guard !loading,
            let data = try? JSONEncoder().encode(
                Snapshot(model: model, permissionMode: permissionMode))
        else { return }
        try? data.write(to: Self.file)
    }

    private static func read() -> Snapshot? {
        guard let data = try? Data(contentsOf: Self.file) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
}
