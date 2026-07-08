import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The caret's context in the editor, forwarded so an AI prompt can act on "the
/// selection" or "this line". `blockText` is the paragraph/line the caret sits in.
struct EditorSelectionContext: Equatable {
    var selectedText = ""
    var blockText = ""
}

/// A request to jump to text in the loaded document — the ⌘F search opens a
/// result on its match. The `token` makes repeat requests for the same text fire.
struct EditorFindRequest: Equatable {
    let token: Int
    let text: String
}

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
    /// Extra scroll space at the bottom of the content so the last lines clear the
    /// floating AI bar overlaid on top of the editor.
    let bottomInset: CGFloat
    /// When set (and changed), scroll to + highlight this text once the document
    /// is loaded. Driven by the ⌘F search opening a result on its match.
    let findRequest: EditorFindRequest?
    /// The caret's selection/line, reported as it changes (for AI prompt context).
    let onSelection: (EditorSelectionContext) -> Void
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
        config.userContentController.add(coordinator, name: "code")
        config.userContentController.add(coordinator, name: "image")
        config.userContentController.add(coordinator, name: "selection")
        // Serves project images to the editor's <img> tags (see mediaUrl in JS).
        config.setURLSchemeHandler(coordinator, forURLScheme: "mfmedia")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.autoresizingMask = [.width, .height]  // fill the container (fullscreen, resize)
        coordinator.webView = webView
        coordinator.observeAccent()  // keep the editor's --mf-accent on the macOS accent

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
        coordinator.onSelection = onSelection
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
        if coordinator.bottomInset != bottomInset {
            coordinator.bottomInset = bottomInset
            coordinator.applyBottomInset()
        }
        if let request = findRequest, coordinator.findToken != request.token {
            coordinator.findToken = request.token
            coordinator.pendingFind = request.text
            coordinator.flushFind()
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKURLSchemeHandler {
        weak var webView: WKWebView?
        var onSave: (String) -> Void
        var onSelection: (EditorSelectionContext) -> Void = { _ in }
        var ready = false
        var editable = true
        var loadedDoc = ""
        var pending: String?
        var fileURL: URL?
        var projectRoot: URL?
        var bottomInset: CGFloat = 0
        var findToken = 0
        /// A find awaiting the document load; flushed once the doc is pushed.
        var pendingFind: String?
        private var accentObserver: NSObjectProtocol?
        private var appearanceObservation: NSKeyValueObservation?

        init(onSave: @escaping (String) -> Void) { self.onSave = onSave }

        deinit {
            if let accentObserver { NotificationCenter.default.removeObserver(accentObserver) }
        }

        // MARK: - JS → Swift

        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            switch message.name {
            case "ready":
                ready = true
                pushDocIfReady()
                applyBottomInset()
                applyAccent()
            case "save":
                if let markdown = message.body as? String { onSave(markdown) }
            case "log":
                // JS errors / console output, forwarded so they're visible in
                // Console.app (filter for "editor.js") or the launching terminal.
                NSLog("[editor.js] %@", message.body as? String ?? "\(message.body)")
            case "table":
                let dims = message.body as? [String: Any]
                presentTableDialog(
                    rows: (dims?["rows"] as? NSNumber)?.intValue,
                    cols: (dims?["cols"] as? NSNumber)?.intValue)
            case "link":
                presentLinkDialog(currentURL: message.body as? String ?? "")
            case "code":
                presentCodeDialog(currentLanguage: message.body as? String ?? "")
            case "image":
                let data = message.body as? [String: Any]
                presentImageDialog(
                    currentSrc: data?["src"] as? String ?? "",
                    currentAlt: data?["alt"] as? String ?? "")
            case "selection":
                let data = message.body as? [String: Any]
                onSelection(
                    EditorSelectionContext(
                        selectedText: data?["selectedText"] as? String ?? "",
                        blockText: data?["blockText"] as? String ?? ""))
            default:
                break
            }
        }

        func pushDocIfReady() {
            guard ready, let doc = pending else { return }
            pending = nil
            evaluate("window.macfolioLoad(\(jsEncoded(doc)));")
            flushFind()
        }

        // Run a queued find once the editor is ready and its document is loaded
        // (so the match text exists to scroll to).
        func flushFind() {
            guard ready, pending == nil, let text = pendingFind else { return }
            pendingFind = nil
            evaluate("window.macfolioFind(\(jsEncoded(text)));")
        }

        // Pad the scroll container (#editor-shell keeps its 15px base) so content
        // can scroll above the floating AI bar. Injected rather than baked into
        // the editor CSS so it tracks the bar's live height.
        func applyBottomInset() {
            guard ready else { return }
            let px = max(0, Int(bottomInset.rounded()))
            evaluate(
                "(function(){var s=document.getElementById('editor-shell');"
                    + "if(s){s.style.paddingBottom=(15+\(px))+'px';}})();")
        }

        func evaluate(_ script: String) {
            webView?.evaluateJavaScript(script)
        }

        // MARK: - Accent color (follow the macOS system accent)

        // Re-push the accent when the user changes it (systemColorsDidChange) or the
        // editor's light/dark appearance flips (controlAccentColor resolves per
        // appearance). KVO on effectiveAppearance auto-invalidates when released.
        func observeAccent() {
            accentObserver = NotificationCenter.default.addObserver(
                forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.applyAccent()
            }
            appearanceObservation = webView?.observe(\.effectiveAppearance) { [weak self] _, _ in
                self?.applyAccent()
            }
        }

        // Override the editor's --mf-accent with the resolved macOS accent color, so
        // links / the block bar / selection UI match the rest of the app.
        func applyAccent() {
            guard ready, let webView else { return }
            var rgb = (r: 0, g: 0, b: 0)
            webView.effectiveAppearance.performAsCurrentDrawingAppearance {
                if let color = NSColor.controlAccentColor.usingColorSpace(.sRGB) {
                    rgb.r = Int((color.redComponent * 255).rounded())
                    rgb.g = Int((color.greenComponent * 255).rounded())
                    rgb.b = Int((color.blueComponent * 255).rounded())
                }
            }
            evaluate(
                "document.documentElement.style"
                    + ".setProperty('--mf-accent','rgb(\(rgb.r),\(rgb.g),\(rgb.b))');")
        }

        // MARK: - Editor prompts (native alerts, labelled like Settings)

        private static let imageExtensions: Set<String> = [
            "png", "jpg", "jpeg", "gif", "svg",
        ]

        // The project's images as (src relative to the open .md file, filename).
        private func projectImages() -> [(src: String, name: String)] {
            guard let root = projectRoot else { return [] }
            let base = fileURL?.deletingLastPathComponent()
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            var items: [(src: String, name: String)] = []
            while let url = enumerator?.nextObject() as? URL {
                guard Self.imageExtensions.contains(url.pathExtension.lowercased())
                else { continue }
                items.append((relativePath(from: base, to: url), url.lastPathComponent))
            }
            return items.sorted { $0.name.lowercased() < $1.name.lowercased() }
        }

        // Image picker + alt field; prefilled from the selected image when editing.
        private func presentImageDialog(currentSrc: String, currentAlt: String) {
            let images = projectImages()
            let alert = NSAlert()

            guard !images.isEmpty else {
                alert.messageText = "Insert Image"
                alert.informativeText = "No images found in this project."
                alert.addButton(withTitle: "OK")
                present(alert) { _ in }
                return
            }

            let editing = !currentSrc.isEmpty
            let popup = DialogField.popup(images.map { $0.name })
            if let index = images.firstIndex(where: { $0.src == currentSrc }) {
                popup.selectItem(at: index)
            }
            let altField = DialogField.textField(currentAlt)
            alert.messageText = editing ? "Edit Image" : "Insert Image"
            alert.accessoryView = DialogField.accessory([
                DialogField.labeled("Image", popup),
                DialogField.labeled("Alt text", altField),
            ])
            alert.addButton(withTitle: editing ? "Save" : "Insert")
            alert.addButton(withTitle: "Cancel")
            present(alert) { [weak self] response in
                guard response == .alertFirstButtonReturn,
                    images.indices.contains(popup.indexOfSelectedItem)
                else { return }
                let src = images[popup.indexOfSelectedItem].src
                self?.evaluate(
                    "window.macfolioSetImage(\(jsEncoded(src)), \(jsEncoded(altField.stringValue)));"
                )
            }
        }

        // Rows/columns prompt; prefilled from the caret's table (resize) or 3×3
        // for a new one.
        private func presentTableDialog(rows currentRows: Int?, cols currentCols: Int?) {
            let editing = currentRows != nil
            let rows = DialogField.textField(String(currentRows ?? 3))
            let cols = DialogField.textField(String(currentCols ?? 3))
            let alert = NSAlert()
            alert.messageText = editing ? "Update Table" : "Insert Table"
            alert.accessoryView = DialogField.accessory([
                DialogField.labeled("Rows", rows),
                DialogField.labeled("Columns", cols),
            ])
            alert.addButton(withTitle: editing ? "Update" : "Insert")
            alert.addButton(withTitle: "Cancel")
            present(alert) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                let r = max(1, Int(rows.stringValue) ?? 1)
                let c = max(1, Int(cols.stringValue) ?? 1)
                self?.evaluate("window.macfolioInsertTable(\(r), \(c));")
            }
        }

        // Languages offered by the code-block picker (label, Prism id). Plain has
        // no id so the block serialises to a bare ``` fence.
        private static let codeLanguages: [(label: String, id: String)] = [
            ("Plain Text", ""),
            ("Bash", "bash"),
            ("C", "c"),
            ("C++", "cpp"),
            ("CSS", "css"),
            ("Go", "go"),
            ("HTML", "html"),
            ("Java", "java"),
            ("JavaScript", "javascript"),
            ("JSON", "json"),
            ("Markdown", "markdown"),
            ("Python", "python"),
            ("Rust", "rust"),
            ("SQL", "sql"),
            ("Swift", "swift"),
            ("TypeScript", "typescript"),
            ("YAML", "yaml"),
        ]

        // Language prompt; converts the caret's block into a code block, or
        // relanguages the code block it's already in (preselected).
        private func presentCodeDialog(currentLanguage: String) {
            let langs = Self.codeLanguages
            let popup = DialogField.popup(langs.map { $0.label })
            if let index = langs.firstIndex(where: { $0.id == currentLanguage }) {
                popup.selectItem(at: index)
            }
            let alert = NSAlert()
            alert.messageText = "Code Block"
            alert.accessoryView = DialogField.accessory([
                DialogField.labeled("Language", popup)
            ])
            alert.addButton(withTitle: "Insert")
            alert.addButton(withTitle: "Cancel")
            present(alert) { [weak self] response in
                guard response == .alertFirstButtonReturn,
                    langs.indices.contains(popup.indexOfSelectedItem)
                else { return }
                let id = langs[popup.indexOfSelectedItem].id
                self?.evaluate("window.macfolioInsertCodeBlock(\(jsEncoded(id)));")
            }
        }

        // URL prompt; an empty URL clears the link (Add / Edit an existing one).
        private func presentLinkDialog(currentURL: String) {
            let editing = !currentURL.isEmpty
            let url = DialogField.textField(currentURL)
            let alert = NSAlert()
            alert.messageText = editing ? "Edit Link" : "Add Link"
            alert.accessoryView = DialogField.accessory([
                DialogField.labeled("URL", url, hint: editing ? "Clear to remove" : nil)
            ])
            alert.addButton(withTitle: editing ? "Save" : "Add")
            alert.addButton(withTitle: "Cancel")
            present(alert) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.evaluate("window.macfolioSetLink(\(jsEncoded(url.stringValue)));")
            }
        }

        // Show as a window sheet when we can, else a standalone modal.
        private func present(
            _ alert: NSAlert, _ handler: @escaping (NSApplication.ModalResponse) -> Void
        ) {
            if let window = webView?.window {
                alert.beginSheetModal(for: window, completionHandler: handler)
            } else {
                handler(alert.runModal())
            }
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
