import Foundation

/// On-disk locations the app uses.
enum Paths {
    /// The base we write under: the user's home on macOS, the app's sandbox
    /// container on iOS (where `homeDirectoryForCurrentUser` is unavailable). The
    /// container's `Documents/` is the same folder the Files app exposes.
    private static let home: URL = {
        #if os(iOS)
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            return docs.deletingLastPathComponent()
        #else
            return FileManager.default.homeDirectoryForCurrentUser
        #endif
    }()

    /// `~/.config/macfolio` — our side-channel for settings.
    static let support: URL = {
        let dir = home.appendingPathComponent(".config/macfolio")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func support(_ name: String) -> URL { support.appendingPathComponent(name) }

    /// Default home for projects: `~/Documents/Macfolio`.
    static let projectsHome: URL = {
        let dir = home.appendingPathComponent("Documents/Macfolio")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}
