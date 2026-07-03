import Foundation

/// On-disk locations the app uses.
enum Paths {
    /// `~/.config/macfolio` — our side-channel for settings.
    static let support: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/macfolio")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func support(_ name: String) -> URL { support.appendingPathComponent(name) }

    /// Default home for projects: `~/Documents/Macfolio`.
    static let projectsHome: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Macfolio")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}
