#if os(iOS)
    import SwiftUI
    import UIKit
    import UniformTypeIdentifiers
    import WebKit

    /// The editor surface on iPad — the same Lexical (vanilla) WYSIWYG bundle the Mac
    /// app uses, in a `WKWebView`. It's a straight port of the macOS `EditorView`: the
    /// JS bridge (`macfolioLoad` / message handlers), the `mfmedia://` image handler,
    /// and the table/link/code/image prompts all match — only AppKit becomes UIKit
    /// (`NSViewRepresentable` → `UIViewRepresentable`, `NSAlert` → `UIAlertController`)
    /// and there's no macOS system-accent to follow (the bundle's CSS default is used).
    struct TouchEditorView: UIViewRepresentable {
        let docID: String
        let markdown: String
        let editable: Bool
        let fileURL: URL?
        let projectRoot: URL?
        let onSave: (String) -> Void

        // WKWebView can't create a sandbox extension for the read-only `.app` bundle,
        // so loading `editor/index.html` straight from `Bundle.main` fails. Stage the
        // web content (`editor/` + its sibling `Fonts/`, reached via the CSS's
        // `../Fonts`) into Caches — inside the app's data container, which WebKit *can*
        // extend — and load the copy from there. Returns the staged index.html.
        private static let stagedIndexURL: URL? = stageWebContent()

        private static func stageWebContent() -> URL? {
            let fm = FileManager.default
            guard let resources = Bundle.main.resourceURL else { return nil }
            let editorSrc = resources.appendingPathComponent("editor")
            guard fm.fileExists(atPath: editorSrc.appendingPathComponent("index.html").path) else {
                return nil
            }

            let root = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MacfolioWeb", isDirectory: true)
            let stagedEditor = root.appendingPathComponent("editor")
            let stagedIndex = stagedEditor.appendingPathComponent("index.html")

            // Re-copy only when the staged bundle is missing or differs from the app's
            // (compared by the main script's byte size) — avoids a ~2 MB copy per launch.
            let marker = "index.js"
            if fm.fileExists(atPath: stagedIndex.path),
                fileSize(editorSrc.appendingPathComponent(marker))
                    == fileSize(stagedEditor.appendingPathComponent(marker))
            {
                return stagedIndex
            }

            try? fm.removeItem(at: root)
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            try? fm.copyItem(at: editorSrc, to: stagedEditor)
            let fontsSrc = resources.appendingPathComponent("Fonts")
            if fm.fileExists(atPath: fontsSrc.path) {
                try? fm.copyItem(at: fontsSrc, to: root.appendingPathComponent("Fonts"))
            }
            return fm.fileExists(atPath: stagedIndex.path) ? stagedIndex : nil
        }

        private static func fileSize(_ url: URL) -> Int {
            ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? -1
        }

        func makeCoordinator() -> Coordinator { Coordinator(onSave: onSave) }

        // MARK: - Injected JavaScript

        // Message-handler channels the editor posts to (window.webkit.messageHandlers.<name>).
        private static let messageNames = [
            "save", "ready", "log", "table", "link", "code", "image", "selection",
        ]

        // Neutralise mobile-web behaviours the desktop WKWebView never has, so the editor
        // feels native: kill the double-tap zoom delay and accidental pinch/focus zoom, the
        // grey tap flash, and rotation text inflation.
        private static let touchTuningJS = """
            (function () {
                var m = document.querySelector('meta[name=viewport]');
                if (!m) { m = document.createElement('meta'); m.name = 'viewport'; document.head.appendChild(m); }
                m.setAttribute('content',
                    'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no');
                var s = document.createElement('style');
                s.textContent =
                    'html{-webkit-text-size-adjust:100%;}' +
                    'body{touch-action:manipulation;-webkit-tap-highlight-color:transparent;}';
                document.head.appendChild(s);
            })();
            """

        // On iOS a table's direction doesn't apply live for RTL text — the editor updates
        // it, but WebKit only reflows after a reload. Independently of Lexical, on each edit
        // inside a table set its `dir` attribute (the editor's CSS keys the column order,
        // right-push, cell alignment and rounded corners off `.mf-table[dir="rtl"]`) and
        // force a relayout so it takes effect. Caret is saved/restored so typing isn't cut.
        private static let rtlReflowJS = """
            (function () {
                var editor = document.getElementById('editor');
                if (!editor) return;
                var RTL = /[\\u0590-\\u08FF\\uFB1D-\\uFDFF\\uFE70-\\uFEFF]/;
                var LTR = /[A-Za-z\\u00C0-\\u02B8]/;
                function dirOf(text) {
                    for (var i = 0; i < text.length; i++) {
                        if (LTR.test(text[i])) return 'ltr';
                        if (RTL.test(text[i])) return 'rtl';
                    }
                    return 'ltr';
                }
                editor.addEventListener('input', function () {
                    var sel = window.getSelection();
                    if (!sel || !sel.rangeCount) return;
                    var node = sel.getRangeAt(0).startContainer;
                    var el = node.nodeType === 1 ? node : node.parentElement;
                    var table = el && el.closest ? el.closest('table') : null;
                    if (!table) return;
                    var dir = dirOf(table.textContent || '');
                    if (table.getAttribute('dir') === dir) return;
                    table.setAttribute('dir', dir);
                    var range = sel.getRangeAt(0).cloneRange();
                    var d = table.style.display;
                    table.style.display = 'none';
                    void table.offsetHeight;
                    table.style.display = d;
                    void table.offsetHeight;
                    sel.removeAllRanges();
                    sel.addRange(range);
                });
            })();
            """

        func makeUIView(context: Context) -> WKWebView {
            let coordinator = context.coordinator
            let config = WKWebViewConfiguration()
            config.dataDetectorTypes = []  // don't scan the text for phone numbers / links
            for script in [Self.touchTuningJS, Self.rtlReflowJS] {
                config.userContentController.addUserScript(
                    WKUserScript(
                        source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            }
            for name in Self.messageNames {
                config.userContentController.add(coordinator, name: name)
            }
            // Serves project images to the editor's <img> tags (see mediaUrl in JS).
            config.setURLSchemeHandler(coordinator, forURLScheme: "mfmedia")

            let webView = WKWebView(frame: .zero, configuration: config)
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            webView.scrollView.contentInsetAdjustmentBehavior = .never
            webView.scrollView.keyboardDismissMode = .interactive
            coordinator.webView = webView
            coordinator.observeKeyboard()

            // Allow Safari's Web Inspector to attach (Develop ▸ <device> ▸ index.html).
            if #available(iOS 16.4, *) {
                webView.isInspectable = true
            }

            if let url = Self.stagedIndexURL {
                // The staging root (…/MacfolioWeb) holds both editor/ and Fonts/, so
                // read access there lets the CSS reach the fonts via `../Fonts`.
                let root = url.deletingLastPathComponent().deletingLastPathComponent()
                webView.loadFileURL(url, allowingReadAccessTo: root)
            } else {
                // Visible fallback so a missing bundle isn't just a blank pane.
                webView.loadHTMLString(
                    "<html><body style=\"font:16px -apple-system;padding:24px;color:#888\">"
                        + "Editor bundle not embedded.<br>Run <b>make</b> on the Mac, then rebuild."
                        + "</body></html>", baseURL: nil)
            }
            return webView
        }

        func updateUIView(_ webView: WKWebView, context: Context) {
            let coordinator = context.coordinator
            coordinator.onSave = onSave
            coordinator.fileURL = fileURL
            coordinator.projectRoot = projectRoot

            if coordinator.loadedDoc != docID {
                coordinator.flushSave()  // persist the outgoing file before switching
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
            // Coalesce the editor's per-keystroke saves and write off the main thread —
            // a synchronous atomic write on every change janks typing on device.
            private var pendingWrite: (() -> Void)?
            private var saveWork: DispatchWorkItem?
            private var keyboardObservers: [NSObjectProtocol] = []

            init(onSave: @escaping (String) -> Void) { self.onSave = onSave }

            deinit {
                flushSave()
                keyboardObservers.forEach { NotificationCenter.default.removeObserver($0) }
            }

            // MARK: - JS → Swift

            func userContentController(
                _ controller: WKUserContentController, didReceive message: WKScriptMessage
            ) {
                switch message.name {
                case "ready":
                    ready = true
                    pushDocIfReady()
                case "save":
                    if let markdown = message.body as? String { scheduleSave(markdown) }
                case "log":
                    // JS errors / console output, forwarded so they're visible in
                    // Console.app (filter for "editor.js").
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
                    break  // caret context is only used to feed the AI, which iPad omits
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

            // MARK: - Debounced autosave

            // Capture the current file's `onSave` with the text, so a later doc switch
            // (which rebinds `onSave`) can't misroute a pending write to the new file.
            private func scheduleSave(_ markdown: String) {
                let save = onSave
                pendingWrite = { save(markdown) }
                saveWork?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.flushSave() }
                saveWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            }

            func flushSave() {
                saveWork?.cancel()
                saveWork = nil
                guard let write = pendingWrite else { return }
                pendingWrite = nil
                DispatchQueue.global(qos: .utility).async(execute: write)
            }

            // MARK: - Keyboard avoidance

            // Pad the scroll container by the keyboard's overlap so the caret can scroll
            // clear of it (the web content scrolls inside #app, so an outer scroll-view
            // inset wouldn't reach it). `scroll-padding-bottom` keeps scroll-into-view
            // from parking the caret under the keyboard.
            func observeKeyboard() {
                let center = NotificationCenter.default
                keyboardObservers = [
                    center.addObserver(
                        forName: UIResponder.keyboardWillChangeFrameNotification, object: nil,
                        queue: .main
                    ) { [weak self] note in self?.applyKeyboardInset(note) },
                    center.addObserver(
                        forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
                    ) { [weak self] _ in self?.setBottomInset(0) },
                ]
            }

            private func applyKeyboardInset(_ note: Notification) {
                guard let webView, let window = webView.window,
                    let frame =
                        (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?
                        .cgRectValue
                else { return }
                let keyboard = webView.convert(frame, from: window.screen.coordinateSpace)
                setBottomInset(max(0, webView.bounds.maxY - keyboard.minY))
            }

            private func setBottomInset(_ px: CGFloat) {
                let p = max(0, Int(px.rounded()))
                evaluate(
                    "(function(){var a=document.getElementById('app');"
                        + "if(a){a.style.paddingBottom=\(p)+'px';a.style.scrollPaddingBottom=\(p)+'px';}})();"
                )
            }

            // MARK: - Editor prompts (native alerts, labelled like the Mac dialogs)

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

            // Image picker (an action per project image) → alt-text prompt; prefilled
            // from the selected image when editing.
            private func presentImageDialog(currentSrc: String, currentAlt: String) {
                let images = projectImages()
                guard !images.isEmpty else {
                    let alert = UIAlertController(
                        title: "Insert Image", message: "No images found in this project.",
                        preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    present(alert)
                    return
                }

                let sheet = UIAlertController(
                    title: "Insert Image", message: "Choose an image", preferredStyle: .actionSheet)
                for image in images {
                    sheet.addAction(
                        UIAlertAction(title: image.name, style: .default) { [weak self] _ in
                            self?.promptImageAlt(src: image.src, currentAlt: currentAlt)
                        })
                }
                sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                present(sheet)
            }

            // Second step of the image flow: the alt text for the chosen image.
            private func promptImageAlt(src: String, currentAlt: String) {
                let alert = UIAlertController(
                    title: "Alt Text", message: nil, preferredStyle: .alert)
                alert.addTextField { field in
                    field.text = currentAlt
                    field.placeholder = "Description"
                }
                alert.addAction(
                    UIAlertAction(title: "Insert", style: .default) { [weak self] _ in
                        let alt = alert.textFields?.first?.text ?? ""
                        self?.evaluate(
                            "window.macfolioSetImage(\(jsEncoded(src)), \(jsEncoded(alt)));")
                    })
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                present(alert)
            }

            // Rows/columns prompt; prefilled from the caret's table (resize) or 3×3
            // for a new one.
            private func presentTableDialog(rows currentRows: Int?, cols currentCols: Int?) {
                let editing = currentRows != nil
                let alert = UIAlertController(
                    title: editing ? "Update Table" : "Insert Table", message: nil,
                    preferredStyle: .alert)
                alert.addTextField { field in
                    field.text = String(currentRows ?? 3)
                    field.placeholder = "Rows"
                    field.keyboardType = .numberPad
                }
                alert.addTextField { field in
                    field.text = String(currentCols ?? 3)
                    field.placeholder = "Columns"
                    field.keyboardType = .numberPad
                }
                alert.addAction(
                    UIAlertAction(title: editing ? "Update" : "Insert", style: .default) {
                        [weak self] _ in
                        let r = max(1, Int(alert.textFields?[0].text ?? "") ?? 1)
                        let c = max(1, Int(alert.textFields?[1].text ?? "") ?? 1)
                        self?.evaluate("window.macfolioInsertTable(\(r), \(c));")
                    })
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                present(alert)
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

            // Language picker; converts the caret's block into a code block, or
            // relanguages the code block it's already in.
            private func presentCodeDialog(currentLanguage: String) {
                let sheet = UIAlertController(
                    title: "Code Block", message: "Choose a language", preferredStyle: .actionSheet)
                for lang in Self.codeLanguages {
                    sheet.addAction(
                        UIAlertAction(title: lang.label, style: .default) { [weak self] _ in
                            self?.evaluate("window.macfolioInsertCodeBlock(\(jsEncoded(lang.id)));")
                        })
                }
                sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                present(sheet)
            }

            // URL prompt; an empty URL clears the link (Add / Edit an existing one).
            private func presentLinkDialog(currentURL: String) {
                let editing = !currentURL.isEmpty
                let alert = UIAlertController(
                    title: editing ? "Edit Link" : "Add Link", message: nil, preferredStyle: .alert)
                alert.addTextField { field in
                    field.text = currentURL
                    field.placeholder = editing ? "Clear to remove" : "https://"
                    field.keyboardType = .URL
                    field.autocapitalizationType = .none
                }
                alert.addAction(
                    UIAlertAction(title: editing ? "Save" : "Add", style: .default) {
                        [weak self] _ in
                        let url = alert.textFields?.first?.text ?? ""
                        self?.evaluate("window.macfolioSetLink(\(jsEncoded(url)));")
                    })
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                present(alert)
            }

            // Present from the web view's window, anchored to its centre so action
            // sheets don't crash on iPad (which requires a popover source).
            private func present(_ alert: UIAlertController) {
                guard let host = topViewController() else { return }
                if let popover = alert.popoverPresentationController, let view = webView {
                    popover.sourceView = view
                    popover.sourceRect = CGRect(
                        x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
                    popover.permittedArrowDirections = []
                }
                host.present(alert, animated: true)
            }

            // The frontmost view controller to present from.
            private func topViewController() -> UIViewController? {
                var top = webView?.window?.rootViewController
                while let presented = top?.presentedViewController { top = presented }
                return top
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
                return components.isEmpty
                    ? target.lastPathComponent : components.joined(separator: "/")
            }

            private static func mimeType(for ext: String) -> String {
                if let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType {
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
#endif
