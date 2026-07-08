import AppKit
import SwiftUI

/// The studio: a native sidebar of **projects › files**, and a main area with the
/// editable Markdown file above a docked **chat** footer. Both you and the agent
/// act on the project's `.md` files.
struct MainView: View {
    @ObservedObject private var projects = ProjectStore.shared
    @ObservedObject private var chat = ChatStore.shared
    @ObservedObject private var settings = SettingsStore.shared

    @State private var promptOpen = true
    /// Live height of the floating AI bar, used to inset the editor's bottom.
    @State private var promptBarHeight: CGFloat = 0
    /// Bumped after the agent edits files, to reload the editor from disk.
    @State private var editorReload = 0
    /// The editor's current caret selection/line, passed to the agent as context.
    @State private var selection = EditorSelectionContext()
    /// Projects whose file list is expanded in the sidebar (seeded with the
    /// restored open project so its file is visible on launch).
    @State private var expandedProjects: Set<String> =
        ProjectStore.shared.project.map { [$0.id] } ?? []

    // Text prompts (New Project / New Document / Rename).
    @State private var showNewProject = false
    @State private var newProjectTitle = ""
    @State private var showAddFile = false
    @State private var addFileTitle = ""
    @State private var addFileProject: Project?
    @State private var renameTarget: ProjectFile?
    @State private var renameTitle = ""
    @State private var renameProjectTarget: Project?
    @State private var renameProjectTitle = ""
    /// The ⌘F search palette.
    @State private var showSearch = false
    /// The pending "jump to match" for the editor, set when opening a search
    /// result. Each request bumps the token so repeats (same file + query) fire.
    @State private var findRequest: EditorFindRequest?
    /// Whether the Claude Code CLI is installed and runnable. Gates the AI bar;
    /// checked once on appear (nil = not yet determined).
    @State private var aiAvailable: Bool?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: AppWindow.sidebar, max: 320)
        } detail: {
            detail
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(projects.windowTitle)
        .toolbar { toolbar }
        .alert("New Project", isPresented: $showNewProject) { newProjectPrompt }
        .alert("New Document", isPresented: $showAddFile) { newFilePrompt }
        .alert("Rename Document", isPresented: renameBinding) { renamePrompt }
        .alert("Rename Project", isPresented: renameProjectBinding) { renameProjectPrompt }
        .overlay {
            if showSearch {
                SearchOverlay(
                    onOpen: openSearchResult,
                    onClose: { showSearch = false }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: showSearch)
        .onAppear {
            chat.activate(projects.project)
            expandOpenProject()
            checkAI()
        }
        .onChange(of: projects.project) { project in
            chat.activate(project)
            expandOpenProject()
        }
        .onChange(of: projects.selected) { _ in
            // Drop the previous file's selection; the editor re-reports on load.
            selection = EditorSelectionContext()
        }
        .onChange(of: settings.aiSignature) { _ in
            // Switching provider or editing its config may flip availability.
            checkAI()
        }
        .onReceive(NotificationCenter.default.publisher(for: .newProject)) { _ in
            startNewProject()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSearch)) { _ in
            showSearch = true
        }
    }

    // MARK: - Toolbar

    /// Primary-action toolbar: the AI-bar toggle (disabled when no AI backend is
    /// configured) and Settings.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                promptOpen.toggle()
            } label: {
                Image(systemName: "sparkle")
                    .foregroundStyle(promptOpen ? Color.accentColor : Color.primary)
            }
            .disabled(aiAvailable == false)
            .help(aiAvailable == false ? "AI backend not configured" : "")
            Button {
                SettingsDialog.present()
            } label: {
                Image(systemName: "gearshape")
            }
        }
    }

    /// Open a search result: switch to its project (if needed), select the file
    /// and expand it in the sidebar, then ask the editor to jump to the match.
    private func openSearchResult(_ project: Project, _ file: ProjectFile, _ query: String) {
        if projects.project?.id != project.id { projects.select(project) }
        projects.selected = file
        expandedProjects.insert(project.id)
        findRequest = EditorFindRequest(token: (findRequest?.token ?? 0) + 1, text: query)
    }

    // MARK: - Text prompts (New / Rename)

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

    @ViewBuilder
    private var renameProjectPrompt: some View {
        TextField("Name", text: $renameProjectTitle)
        Button("Rename") {
            if let project = renameProjectTarget {
                let title = renameProjectTitle.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { projects.renameProject(project, to: title) }
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
                    if let media = projects.mediaByProject[project.project.id],
                        !media.isEmpty
                    {
                        Divider()
                        ForEach(media, id: \.self) { url in
                            mediaRow(url)
                        }
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
            Button("New Project") { startNewProject() }
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

    /// Probe for the Claude Code CLI; if it's missing, close the AI bar so the
    /// disabled toggle doesn't leave a dead bar on screen.
    private func checkAI() {
        Task.detached {
            let available = Agent.current.isAvailable()
            await MainActor.run {
                aiAvailable = available
                if !available { promptOpen = false }
            }
        }
    }

    private func selectNode(_ node: SidebarNode?) {
        guard let node else { return }
        if projects.project?.id != node.project.id { projects.select(node.project) }
        if let file = node.file, projects.selected?.id != file.id {
            projects.selected = file
        }
    }

    // Project image — Open (preview) / Delete via the context menu. Insertion is
    // done from the editor's Image toolbar button.
    private func mediaRow(_ url: URL) -> some View {
        Label(url.lastPathComponent, systemImage: "photo")
            .lineLimit(1)
            .truncationMode(.middle)
            .contextMenu {
                Button("Open") { NSWorkspace.shared.open(url) }
                Button("Delete", role: .destructive) { projects.deleteMedia(url) }
            }
    }

    @ViewBuilder
    private func nodeMenu(_ node: SidebarNode) -> some View {
        if let file = node.file {
            Button("Rename") {
                renameTitle = file.title
                renameTarget = file
            }
            Divider()
            Button("Delete", role: .destructive) { projects.delete(file) }
                .disabled((projects.filesByProject[node.project.id]?.count ?? 0) <= 1)
        } else {
            Button("New Document") { startAddFile(node.project) }
            Button("Rename") {
                renameProjectTitle = node.project.title
                renameProjectTarget = node.project
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([node.project.root])
            }
            Divider()
            Button("Delete Project", role: .destructive) { projects.deleteProject(node.project) }
        }
    }

    // MARK: - Detail (editor + floating AI prompt)

    @ViewBuilder
    private var detail: some View {
        if projects.project == nil {
            EmptyState("Create or select a project to begin", icon: "folder")
        } else {
            ZStack(alignment: .bottom) {
                // The editor fills the whole area (behind the bar); its content
                // gets a bottom inset instead, so the bar's frosted material sits
                // over the editor rather than the window background.
                editorPane
                if promptOpen {
                    AIPromptBar(
                        disabled: projects.selected == nil,
                        onSubmit: send,
                        onCancel: cancelTurn,
                        onNewSession: startNewSession,
                        canStartNewSession: chat.canStartNewSession(in: projects.project)
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onPreferenceChange(AIPromptBarHeightKey.self) { promptBarHeight = $0 }
            .animation(.easeInOut(duration: 0.2), value: promptOpen)
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
                bottomInset: promptOpen ? promptBarHeight : 0,
                findRequest: findRequest,
                onSelection: { selection = $0 },
                onSave: { text in projects.save(text, to: file) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyState("Select or add a document", icon: "doc.text")
        }
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

    private var renameProjectBinding: Binding<Bool> {
        Binding(
            get: { renameProjectTarget != nil },
            set: { if !$0 { renameProjectTarget = nil } })
    }

    private func startNewSession() {
        guard let project = projects.project else { return }
        chat.newSession(in: project)
    }

    private func send(_ prompt: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let project = projects.project, !chat.working else { return }
        // Pass the open file + caret context so the agent can act on "the
        // selection" or "this line". The editor is locked while chat.working.
        // `onFinish` runs when the turn ends (or is cancelled) to reload edited
        // files from disk — otherwise the editor shows the pre-edit content.
        chat.send(text, in: project, focus: projects.selected, selection: selection) {
            projects.refresh()
            editorReload += 1
        }
    }

    /// Stop the open project's in-flight agent turn.
    private func cancelTurn() {
        guard let project = projects.project else { return }
        chat.cancel(in: project)
    }
}
