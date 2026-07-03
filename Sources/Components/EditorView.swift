import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The editor surface: Lexical (vanilla) WYSIWYG in a WebView. Loads the file's
/// Markdown and posts edits back so we autosave. `docID` identifies the loaded
/// file; `editable` is dropped to false while the agent writes. `fileURL` /
/// `projectRoot` scope the native image picker and the `mfmedia://` image
/// handler that renders project images the WebView can't reach over file://.
struct EditorView: NSViewRepresentable {
    let docID: String
    let markdown: String
    let editable: Bool
    let fileURL: URL?
    let projectRoot: URL?
    let bridge: EditorBridge
    let onSave: (String) -> Void

    private static let bundleURL: URL? = {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let index = resources.appendingPathComponent("editor/index.html")
        return FileManager.default.fileExists(atPath: index.path) ? index : nil
    }()

    func makeCoordinator() -> Coordinator { Coordinator(onSave: onSave) }

    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let config = WKWebViewConfiguration()
        config.userContentController.add(coordinator, name: "save")
        config.userContentController.add(coordinator, name: "ready")
        config.userContentController.add(coordinator, name: "log")
        config.userContentController.add(coordinator, name: "table")
        config.userContentController.add(coordinator, name: "link")
        config.userContentController.add(coordinator, name: "image")
        // Serves project images to the editor's <img> tags (see mediaUrl in JS).
        config.setURLSchemeHandler(coordinator, forURLScheme: "mfmedia")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.autoresizingMask = [.width, .height]  // fill the container (fullscreen, resize)
        coordinator.webView = webView

        // Route the SwiftUI dialog results back into the editor.
        coordinator.bridge = bridge
        bridge.insertTable = { [weak coordinator] rows, cols in
            coordinator?.evaluate("window.macfolioInsertTable(\(rows), \(cols));")
        }
        bridge.setLink = { [weak coordinator] url in
            coordinator?.evaluate("window.macfolioSetLink(\(jsEncoded(url)));")
        }
        bridge.insertImage = { [weak coordinator] src, alt in
            coordinator?.evaluate(
                "window.macfolioInsertImage(\(jsEncoded(src)), \(jsEncoded(alt)));")
        }

        // Allow Safari's Web Inspector to attach (Develop ▸ <app> ▸ index.html).
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }

        if let url = Self.bundleURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSave = onSave
        coordinator.fileURL = fileURL
        coordinator.projectRoot = projectRoot

        if coordinator.loadedDoc != docID {
            coordinator.loadedDoc = docID
            coordinator.pending = markdown
            coordinator.pushDocIfReady()
        }
        if coordinator.editable != editable {
            coordinator.editable = editable
            coordinator.evaluate("window.macfolioSetEditable(\(editable));")
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKURLSchemeHandler {
        weak var webView: WKWebView?
        var onSave: (String) -> Void
        var ready = false
        var editable = true
        var loadedDoc = ""
        var pending: String?
        var fileURL: URL?
        var projectRoot: URL?
        weak var bridge: EditorBridge?

        init(onSave: @escaping (String) -> Void) { self.onSave = onSave }

        // MARK: - JS → Swift

        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            switch message.name {
            case "ready":
                ready = true
                pushDocIfReady()
            case "save":
                if let markdown = message.body as? String { onSave(markdown) }
            case "log":
                // JS errors / console output, forwarded so they're visible in
                // Console.app (filter for "editor.js") or the launching terminal.
                NSLog("[editor.js] %@", message.body as? String ?? "\(message.body)")
            case "table":
                bridge?.dialog = .table
            case "link":
                bridge?.dialog = .link(message.body as? String ?? "")
            case "image":
                bridge?.dialog = .image(collectMedia())
            default:
                break
            }
        }

        func pushDocIfReady() {
            guard ready, let doc = pending else { return }
            pending = nil
            evaluate("window.macfolioLoad(\(jsEncoded(doc)));")
        }

        func evaluate(_ script: String) {
            webView?.evaluateJavaScript(script)
        }

        // MARK: - Project media

        private static let imageExtensions: Set<String> = [
            "png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "bmp", "tiff",
        ]

        // Every image file under the project, with paths relative to the .md file.
        private func collectMedia() -> [MediaItem] {
            guard let root = projectRoot else { return [] }
            let base = fileURL?.deletingLastPathComponent()

            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )

            var items: [MediaItem] = []
            while let url = enumerator?.nextObject() as? URL {
                guard Self.imageExtensions.contains(url.pathExtension.lowercased())
                else { continue }
                items.append(MediaItem(url: url, src: relativePath(from: base, to: url)))
            }
            return items.sorted { $0.name.lowercased() < $1.name.lowercased() }
        }

        // MARK: - Media scheme handler (mfmedia://) for <img> display

        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            guard let url = task.request.url,
                let base = fileURL?.deletingLastPathComponent()
            else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }

            let relative = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
            let target = base.appendingPathComponent(relative).standardizedFileURL

            // Keep reads inside the project.
            if let root = projectRoot?.standardizedFileURL,
                !target.path.hasPrefix(root.path)
            {
                task.didFailWithError(URLError(.noPermissionsToReadFile))
                return
            }

            guard let data = try? Data(contentsOf: target) else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }

            let response = URLResponse(
                url: url,
                mimeType: Self.mimeType(for: target.pathExtension),
                expectedContentLength: data.count,
                textEncodingName: nil
            )
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

        // MARK: - Helpers

        // Path of `target` relative to `base`'s directory (for the Markdown src).
        private func relativePath(from base: URL?, to target: URL) -> String {
            guard let base = base?.standardizedFileURL else { return target.path }
            let baseComponents = base.pathComponents
            let targetComponents = target.standardizedFileURL.pathComponents

            var shared = 0
            while shared < baseComponents.count, shared < targetComponents.count,
                baseComponents[shared] == targetComponents[shared]
            {
                shared += 1
            }

            let up = Array(repeating: "..", count: baseComponents.count - shared)
            let down = targetComponents[shared...]
            let components = up + down
            return components.isEmpty ? target.lastPathComponent : components.joined(separator: "/")
        }

        private static func mimeType(for ext: String) -> String {
            if #available(macOS 11.0, *),
                let type = UTType(filenameExtension: ext),
                let mime = type.preferredMIMEType
            {
                return mime
            }
            switch ext.lowercased() {
            case "png": return "image/png"
            case "jpg", "jpeg": return "image/jpeg"
            case "gif": return "image/gif"
            case "webp": return "image/webp"
            case "svg": return "image/svg+xml"
            default: return "application/octet-stream"
            }
        }
    }
}

/// JSON-encode a string for safe interpolation into an evaluated JS call.
private func jsEncoded(_ value: String) -> String {
    guard let data = try? JSONEncoder().encode(value),
        let json = String(data: data, encoding: .utf8)
    else { return "\"\"" }
    return json
}
