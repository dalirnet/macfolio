#if os(iOS)
    import SwiftUI

    /// The iPad studio: a native sidebar of **projects › files** beside the editable
    /// Markdown file. The same `.md`-files-in-a-folder model as the Mac app, driven by
    /// the shared `ProjectStore`; only there's no docked chat footer, since the Claude
    /// co-author can't run on iPadOS (no `claude` subprocess).
    struct TouchMainView: View {
        @ObservedObject private var projects = ProjectStore.shared
        @ObservedObject private var chat = ChatStore.shared
        @ObservedObject private var settings = SettingsStore.shared

        /// Keep the sidebar visible alongside the editor on iPad (it otherwise starts
        /// collapsed, hiding the New Project button on a fresh launch).
        @State private var columnVisibility = NavigationSplitViewVisibility.all

        /// Whether the docked AI bar is shown, and whether a backend is configured.
        @State private var promptOpen = true
        @State private var aiAvailable: Bool?
        @State private var showSettings = false
        @State private var metadataTarget: ProjectFile?
        /// Pending deletions, awaiting confirmation.
        @State private var deleteFileTarget: ProjectFile?
        @State private var deleteProjectTarget: Project?
        /// Bumped after the agent edits files, to reload the editor from disk.
        @State private var editorReload = 0

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

        var body: some View {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar
                    .navigationTitle("Macfolio")
            } detail: {
                detail
                    .navigationTitle(projects.windowTitle)
                    .navigationBarTitleDisplayMode(.inline)
                    // `.editor` role left-aligns the title as plain text (like the
                    // Mac window title), instead of iOS's centered, tinted title.
                    .toolbarRole(.editor)
                    .toolbar {
                        // Match the Mac toolbar: just the AI toggle and Settings.
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                promptOpen.toggle()
                            } label: {
                                Image(systemName: "sparkle")
                            }
                            .tint(promptOpen ? .accentColor : nil)
                            .disabled(aiAvailable == false)
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                showSettings = true
                            } label: {
                                Image(systemName: "gearshape")
                            }
                        }
                    }
            }
            .navigationSplitViewStyle(.balanced)
            .alert("New Project", isPresented: $showNewProject) { newProjectPrompt }
            .alert("New Document", isPresented: $showAddFile) { newFilePrompt }
            .alert("Rename Document", isPresented: $renameTarget.isPresent()) { renamePrompt }
            .alert("Rename Project", isPresented: $renameProjectTarget.isPresent()) { renameProjectPrompt }
            .sheet(isPresented: $showSettings) { TouchSettingsView() }
            .sheet(item: $metadataTarget) { TouchMetadataView(file: $0) }
            .confirmationDialog(
                "Delete this document?",
                isPresented: $deleteFileTarget.isPresent(), presenting: deleteFileTarget
            ) { file in
                Button("Delete", role: .destructive) { projects.delete(file) }
                Button("Cancel", role: .cancel) {}
            } message: { file in
                Text("“\(file.displayTitle)” will be deleted.")
            }
            .confirmationDialog(
                "Delete this project?",
                isPresented: $deleteProjectTarget.isPresent(), presenting: deleteProjectTarget
            ) { project in
                Button("Delete", role: .destructive) { projects.deleteProject(project) }
                Button("Cancel", role: .cancel) {}
            } message: { project in
                Text("“\(project.title)” and all its documents will be deleted.")
            }
            .onAppear {
                chat.activate(projects.project)
                expandOpenProject()
                checkAI()
            }
            .onChange(of: projects.project) { project in
                chat.activate(project)
                expandOpenProject()
            }
            .onChange(of: settings.aiSignature) { _ in checkAI() }
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
            List {
                ForEach(nodes) { project in
                    DisclosureGroup(isExpanded: expansion(project.id)) {
                        ForEach(project.children ?? []) { child in
                            fileRow(child)
                        }
                        if let media = projects.mediaByProject[project.project.id], !media.isEmpty {
                            Divider()
                            ForEach(media, id: \.self) { url in
                                mediaRow(url)
                            }
                        }
                    } label: {
                        Label(project.title, systemImage: "folder")
                            .contextMenu { nodeMenu(project) }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if projects.projects.isEmpty {
                    EmptyState("No projects yet —\ntap to create one", icon: "folder")
                        .contentShape(Rectangle())
                        .onTapGesture { startNewProject() }
                }
            }
            // Long-press the sidebar background to add a project (like the Mac
            // sidebar's right-click menu). New Document lives on each project's menu.
            .contextMenu {
                Button("New Project") { startNewProject() }
            }
        }

        /// The tree: each project a node, its files the children.
        private var nodes: [SidebarNode] {
            projects.projects.map { project in
                let kids = (projects.filesByProject[project.id] ?? []).map {
                    SidebarNode(
                        id: $0.id, title: $0.displayTitle, project: project, file: $0,
                        children: nil)
                }
                return SidebarNode(
                    id: project.id, title: project.title, project: project, file: nil,
                    children: kids.isEmpty ? nil : kids)
            }
        }

        // A file row; tapping it opens the file (and its project, if not already open).
        private func fileRow(_ node: SidebarNode) -> some View {
            Button {
                selectNode(node)
            } label: {
                Label(node.title, systemImage: "doc.text")
                    .foregroundStyle(
                        projects.selected?.id == node.file?.id ? Color.accentColor : Color.primary)
            }
            .contextMenu { nodeMenu(node) }
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

        private func selectNode(_ node: SidebarNode) {
            if projects.project?.id != node.project.id { projects.select(node.project) }
            if let file = node.file, projects.selected?.id != file.id {
                projects.selected = file
            }
        }

        // Project image — Delete via the context menu. Insertion is done by dropping
        // files into the book folder (visible in the Files app).
        private func mediaRow(_ url: URL) -> some View {
            Label(url.lastPathComponent, systemImage: "photo")
                .lineLimit(1)
                .truncationMode(.middle)
                .contextMenu {
                    Button("Delete", role: .destructive) { projects.deleteMedia(url) }
                }
        }

        @ViewBuilder
        private func nodeMenu(_ node: SidebarNode) -> some View {
            if let file = node.file {
                Button("Metadata") { metadataTarget = file }
                Button("Rename") {
                    renameTitle = file.displayTitle
                    renameTarget = file
                }
                Divider()
                Button("Delete", role: .destructive) { deleteFileTarget = file }
            } else {
                Button("New Document") { startAddFile(node.project) }
                Button("Rename") {
                    renameProjectTitle = node.project.title
                    renameProjectTarget = node.project
                }
                Divider()
                Button("Delete Project", role: .destructive) {
                    deleteProjectTarget = node.project
                }
            }
        }

        // MARK: - Detail (editor)

        @ViewBuilder
        private var detail: some View {
            Group {
                if projects.project == nil {
                    EmptyState("Create or select a project to begin", icon: "folder")
                } else if let file = projects.selected {
                    TouchEditorView(
                        // `editorReload` bumps after an agent turn so the editor
                        // re-reads files the agent may have changed.
                        docID: "\(file.id)#\(editorReload)",
                        markdown: projects.body(of: file),
                        editable: !chat.working,
                        fileURL: file.url,
                        projectRoot: projects.project?.root,
                        onSave: { text in projects.save(text, to: file) }
                    )
                    // Keep full height when the keyboard shows — the editor handles the
                    // caret inset itself (see setBottomInset), so avoid double-compensating.
                    .ignoresSafeArea(.container, edges: .bottom)
                    .ignoresSafeArea(.keyboard, edges: .bottom)
                } else {
                    EmptyState("Select or add a document", icon: "doc.text")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if promptOpen, projects.project != nil, aiAvailable != false {
                    TouchAIBar(
                        disabled: projects.selected == nil,
                        onSubmit: send,
                        onCancel: cancelTurn,
                        onNewSession: startNewSession,
                        canStartNewSession: chat.canStartNewSession(in: projects.project)
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: promptOpen)
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

        // MARK: - AI

        /// Probe the configured backend; if unavailable, close the AI bar so its
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

        /// Send one instruction over the open project. iOS has no caret context, so
        /// the agent gets the open file as focus with an empty selection.
        private func send(_ prompt: String) {
            let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let project = projects.project, !chat.working else { return }
            chat.send(
                text, in: project, focus: projects.selected, selection: EditorSelectionContext()
            ) {
                projects.refresh()
                editorReload += 1
            }
        }

        private func cancelTurn() {
            guard let project = projects.project else { return }
            chat.cancel(in: project)
        }

        private func startNewSession() {
            guard let project = projects.project else { return }
            chat.newSession(in: project)
        }
    }
#endif
