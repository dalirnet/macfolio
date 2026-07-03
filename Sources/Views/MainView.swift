import SwiftUI

/// The studio: a native sidebar of **projects › files**, and a main area with the
/// editable Markdown file above a docked **chat** footer. Both you and the agent
/// act on the project's `.md` files.
struct MainView: View {
    @ObservedObject private var projects = ProjectStore.shared
    @ObservedObject private var chat = ChatStore.shared

    @State private var draft = ""
    @State private var chatOpen = true
    @State private var showSettings = false
    /// Bumped after the agent edits files, to reload the editor from disk.
    @State private var editorReload = 0
    /// Editor dialogs (table / link / image) requested by the WebView editor.
    @StateObject private var editorBridge = EditorBridge()

    /// Projects whose file list is expanded in the sidebar (seeded with the
    /// restored open project so its file is visible on launch).
    @State private var expandedProjects: Set<String> =
        ProjectStore.shared.project.map { [$0.id] } ?? []

    // Text prompts (New Project / New File / Rename).
    @State private var showNewProject = false
    @State private var newProjectTitle = ""
    @State private var showAddFile = false
    @State private var addFileTitle = ""
    @State private var addFileProject: Project?
    @State private var renameTarget: ProjectFile?
    @State private var renameTitle = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: AppWindow.sidebar, max: 320)
        } detail: {
            detail
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    chatOpen.toggle()
                } label: {
                    Image(
                        systemName: chatOpen
                            ? "bubble.left.and.bubble.right.fill"
                            : "bubble.left.and.bubble.right")
                }
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView { showSettings = false } }
        .sheet(item: $editorBridge.dialog) { editorDialog($0) }
        .alert("New Project", isPresented: $showNewProject) { newProjectPrompt }
        .alert("New File", isPresented: $showAddFile) { newFilePrompt }
        .alert("Rename File", isPresented: renameBinding) { renamePrompt }
        .onAppear {
            chat.activate(projects.project)
            expandOpenProject()
        }
        .onChange(of: projects.project) { project in
            chat.activate(project)
            expandOpenProject()
        }
        .onReceive(NotificationCenter.default.publisher(for: .newProject)) { _ in
            startNewProject()
        }
    }

    // MARK: - Modals (editor dialogs + text prompts)

    @ViewBuilder
    private func editorDialog(_ dialog: EditorBridge.Dialog) -> some View {
        switch dialog {
        case .table:
            TableDialogView { rows, cols in
                editorBridge.insertTable?(rows, cols)
                editorBridge.dialog = nil
            } onCancel: {
                editorBridge.dialog = nil
            }
        case .link(let url):
            LinkDialogView(initialURL: url) { newURL in
                editorBridge.setLink?(newURL)
                editorBridge.dialog = nil
            } onRemove: {
                editorBridge.setLink?("")
                editorBridge.dialog = nil
            } onCancel: {
                editorBridge.dialog = nil
            }
        case .image(let items):
            ImageDialogView(items: items) { item in
                editorBridge.insertImage?(item.src, item.alt)
                editorBridge.dialog = nil
            } onCancel: {
                editorBridge.dialog = nil
            }
        }
    }

    @ViewBuilder
    private var newProjectPrompt: some View {
        TextField("Name", text: $newProjectTitle)
        Button("Create") {
            let title = newProjectTitle.trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { projects.create(title: title) }
        }
        Button("Cancel", role: .cancel) {}
    }

    @ViewBuilder
    private var newFilePrompt: some View {
        TextField("Name", text: $addFileTitle)
        Button("Add") {
            let title = addFileTitle.trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { projects.addFile(title: title, to: addFileProject) }
        }
        Button("Cancel", role: .cancel) {}
    }

    @ViewBuilder
    private var renamePrompt: some View {
        TextField("Name", text: $renameTitle)
        Button("Rename") {
            if let file = renameTarget {
                let title = renameTitle.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { projects.rename(file, to: title) }
            }
        }
        Button("Cancel", role: .cancel) {}
    }

    // MARK: - Sidebar tree (projects › files)

    private var sidebar: some View {
        List(selection: fileSelection) {
            ForEach(nodes) { project in
                DisclosureGroup(isExpanded: expansion(project.id)) {
                    ForEach(project.children ?? []) { child in
                        Label(child.title, systemImage: "doc.text")
                            .tag(child)
                            .contextMenu { nodeMenu(child) }
                    }
                } label: {
                    Label(project.title, systemImage: "folder")
                        .tag(project)
                        .contextMenu { nodeMenu(project) }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .overlay {
            if projects.projects.isEmpty {
                EmptyState("No projects yet —\nright-click to create one", icon: "folder")
                    .allowsHitTesting(false)
            }
        }
        // Background context menu (empty sidebar area) → new project.
        .contextMenu {
            Button("New Project…") { startNewProject() }
        }
    }

    /// The tree: each project a node, its files the children.
    private var nodes: [SidebarNode] {
        projects.projects.map { project in
            let kids = (projects.filesByProject[project.id] ?? []).map {
                SidebarNode(id: $0.id, title: $0.title, project: project, file: $0, children: nil)
            }
            return SidebarNode(
                id: project.id, title: project.title, project: project, file: nil,
                children: kids.isEmpty ? nil : kids)
        }
    }

    /// Sidebar selection mirrors the open file, so the restored file highlights
    /// on launch and clicks flow back through `selectNode`.
    private var fileSelection: Binding<SidebarNode?> {
        Binding(
            get: {
                guard let file = projects.selected else { return nil }
                return
                    nodes
                    .flatMap { [$0] + ($0.children ?? []) }
                    .first { $0.file?.id == file.id }
            },
            set: { selectNode($0) }
        )
    }

    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expandedProjects.contains(id) },
            set: { isOpen in
                if isOpen {
                    expandedProjects.insert(id)
                } else {
                    expandedProjects.remove(id)
                }
            }
        )
    }

    private func expandOpenProject() {
        if let id = projects.project?.id { expandedProjects.insert(id) }
    }

    private func selectNode(_ node: SidebarNode?) {
        guard let node else { return }
        if projects.project?.id != node.project.id { projects.select(node.project) }
        if let file = node.file, projects.selected?.id != file.id {
            projects.selected = file
        }
    }

    @ViewBuilder
    private func nodeMenu(_ node: SidebarNode) -> some View {
        if let file = node.file {
            Button("Copy Markdown") { projects.copyMarkdown(file) }
            Button("Rename…") {
                renameTitle = file.title
                renameTarget = file
            }
            Divider()
            Button("Delete", role: .destructive) { projects.delete(file) }
                .disabled((projects.filesByProject[node.project.id]?.count ?? 0) <= 1)
        } else {
            Button("New File") { startAddFile(node.project) }
            Divider()
            Button("Delete Project", role: .destructive) { projects.deleteProject(node.project) }
        }
    }

    // MARK: - Detail (editor + chat footer)

    @ViewBuilder
    private var detail: some View {
        if projects.project == nil {
            EmptyState("Create or select a project to begin", icon: "folder")
        } else if chatOpen {
            VSplitView {
                editorPane
                    .frame(minHeight: 220, maxHeight: .infinity)
                chatPanel
                    .frame(minHeight: 150, idealHeight: 200)
            }
        } else {
            editorPane
        }
    }

    @ViewBuilder
    private var editorPane: some View {
        if let file = projects.selected {
            EditorView(
                docID: "\(file.id)#\(editorReload)",
                markdown: projects.text(of: file),
                editable: !chat.working,
                fileURL: file.url,
                projectRoot: projects.project?.root,
                bridge: editorBridge,
                onSave: { text in projects.save(text, to: file) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyState("Select or add a file", icon: "doc.text")
        }
    }

    // MARK: - Chat footer

    private var chatPanel: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(chat.messages) { message in
                            messageRow(message).id(message.id)
                        }
                        if chat.working {
                            activityLog.id("activity")
                        }
                    }
                    .padding(12)
                }
                .onChange(of: chat.messages.count) { _ in
                    if let last = chat.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: chat.activity.count) { _ in
                    withAnimation { proxy.scrollTo("activity", anchor: .bottom) }
                }
            }
            Divider()
            inputBar
        }
        .background(.background)
    }

    /// A chat bubble: user on the right, agent on the left; text direction auto.
    private func messageRow(_ message: ChatMessage) -> some View {
        let rtl = Bidi.isRTL(message.text)
        let isUser = message.role == .user
        return HStack {
            if isUser { Spacer(minLength: 36) }
            Text(message.text)
                .font(Theme.ui(12))
                .textSelection(.enabled)
                .multilineTextAlignment(rtl ? .trailing : .leading)
                .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    isUser
                        ? AnyShapeStyle(Theme.primary.opacity(0.15))
                        : AnyShapeStyle(.quaternary),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            if !isUser { Spacer(minLength: 36) }
        }
    }

    /// Live "what the agent is doing" log during a streaming turn.
    private var activityLog: some View {
        VStack(alignment: .leading, spacing: 4) {
            if chat.activity.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("thinking…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                ForEach(Array(chat.activity.enumerated()), id: \.offset) { index, step in
                    HStack(spacing: 6) {
                        if index == chat.activity.count - 1 {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.tertiary)
                                .frame(width: 12)
                        }
                        Text(step)
                            .font(Theme.mono(10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("ask claude…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .disabled(chat.working || projects.project == nil)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
            }
            .buttonStyle(.plain)
            .foregroundColor(Theme.primary)
            .disabled(
                chat.working || projects.project == nil
                    || draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
    }

    // MARK: - Actions

    private func startNewProject() {
        newProjectTitle = ""
        showNewProject = true
    }

    private func startAddFile(_ project: Project?) {
        addFileProject = project ?? projects.project
        addFileTitle = ""
        showAddFile = true
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let project = projects.project, !chat.working else { return }
        draft = ""
        // @MainActor so the post-turn refresh + editor reload run on the main
        // thread — otherwise the SwiftUI state changes don't propagate and the
        // editor keeps showing the pre-edit content until you reopen the file.
        Task { @MainActor in
            await chat.send(text, in: project)  // editor is locked via chat.working
            projects.refresh()
            editorReload += 1  // reload the file from disk after the agent's edits
        }
    }
}
