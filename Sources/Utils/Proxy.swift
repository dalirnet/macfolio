import Foundation

/// How outbound traffic reaches the internet.
///
/// A launched `.app` inherits launchd's environment, not the shell's — so a
/// `HTTPS_PROXY` exported in `~/.zshrc` never reaches us, and the Claude Code CLI
/// we spawn (which only ever reads proxy *environment variables*, never the system
/// settings) connects directly and fails. This resolves one proxy from Settings and
/// hands it to both sides: as env vars for the CLI child process, and as a
/// `URLSession` for the API backends.
enum Proxy {
    /// The proxy in effect, or nil for a direct connection.
    static func url() -> URL? {
        switch SettingsStore.shared.proxyMode {
        case .system: return systemProxy()
        case .custom: return normalized(SettingsStore.shared.proxyURL)
        }
    }

    /// Proxy environment for a child process. Empty when there's no proxy, so
    /// merging it never clobbers vars the process already inherited.
    static var environment: [String: String] {
        guard let value = url()?.absoluteString else { return [:] }
        let bypass = "localhost,127.0.0.1,::1"
        return [
            "HTTP_PROXY": value, "http_proxy": value,
            "HTTPS_PROXY": value, "https_proxy": value,
            "ALL_PROXY": value, "all_proxy": value,
            "NO_PROXY": bypass, "no_proxy": bypass,
        ]
    }

    /// A session honouring the configured proxy. In `.system` mode the shared
    /// session already follows the system settings, so it's used as-is; a custom
    /// proxy needs its own configured session (cached, since building one per
    /// request would leak connections).
    static var session: URLSession {
        guard SettingsStore.shared.proxyMode == .custom,
            let proxy = normalized(SettingsStore.shared.proxyURL),
            let host = proxy.host, let scheme = proxy.scheme,
            scheme == "http" || scheme == "https"
        else { return .shared }

        let port = proxy.port ?? (scheme == "https" ? 443 : 80)
        let key = "\(scheme)://\(host):\(port)"

        lock.lock()
        defer { lock.unlock() }
        if let cached, cached.key == key { return cached.session }
        cached?.session.finishTasksAndInvalidate()

        let config = URLSessionConfiguration.default
        // String keys, not the `kCFNetworkProxies…` constants: the HTTPS ones are
        // macOS-only symbols, and these are the values they carry on both platforms.
        config.connectionProxyDictionary = [
            "HTTPEnable": true, "HTTPProxy": host, "HTTPPort": port,
            "HTTPSEnable": true, "HTTPSProxy": host, "HTTPSPort": port,
        ]
        let session = URLSession(configuration: config)
        cached = (key, session)
        return session
    }

    private static let lock = NSLock()
    private static var cached: (key: String, session: URLSession)?

    /// Accept a bare `host:port` as well as a full URL, so a pasted proxy works
    /// without remembering the scheme.
    private static func normalized(_ value: String) -> URL? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard let url = URL(string: text), url.host != nil else { return nil }
        return url
    }

    /// The proxy macOS is configured to use for our API host. Entries that need a
    /// PAC script fetched are skipped — only a plain host/port is usable here.
    private static func systemProxy() -> URL? {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue(),
            let target = URL(string: "https://api.anthropic.com")
        else { return nil }

        let proxies =
            CFNetworkCopyProxiesForURL(target as CFURL, settings).takeRetainedValue()
            as? [[String: Any]] ?? []

        // Bound as plain strings: the `kCFProxyType…` constants are `CFString`s, so
        // they can't be matched against a bridged `String` directly.
        let httpTypes = [kCFProxyTypeHTTP as String, kCFProxyTypeHTTPS as String]
        let socksType = kCFProxyTypeSOCKS as String

        for proxy in proxies {
            guard let type = proxy[kCFProxyTypeKey as String] as? String else { continue }
            let scheme: String
            // An HTTPS system proxy is still reached over plain HTTP (CONNECT).
            if httpTypes.contains(type) {
                scheme = "http"
            } else if type == socksType {
                scheme = "socks5"
            } else {
                continue
            }
            guard let host = proxy[kCFProxyHostNameKey as String] as? String else { continue }
            let port = (proxy[kCFProxyPortNumberKey as String] as? NSNumber)?.intValue
            return URL(string: port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)")
        }
        return nil
    }
}
