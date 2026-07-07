#if os(iOS)
    import SwiftUI

    /// The iPad studio: a native sidebar of **projects › files** beside the editable
    /// Markdown file. The same `.md`-files-in-a-folder model as the Mac app, driven by
    /// the shared `ProjectStore`; only there's no docked chat footer, since the Claude
    /// co-author can't run on iPadOS (no `claude` subprocess).
    struct TouchMainView: View {
        @ObservedObject private var projects = ProjectStore.shared

        /// Keep the sidebar visible alongside the editor on iPad (it otherwise starts
        /// collapsed, hiding the New Project button on a fresh launch).
        @State private var columnVisibility = NavigationSplitViewVisibility.all

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
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                startNewProject()
                            } label: {
                                Image(systemName: "folder.badge.plus")
                            }
                        }
                    }
            } detail: {
                detail
                    .navigationTitle(projects.selected?.title ?? "Macfolio")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        // Always present, so the actions are reachable even before a
                        // project or file exists (the sidebar may be collapsed).
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                startAddFile(projects.project)
                            } label: {
                                Image(systemName: "doc.badge.plus")
                            }
                            .disabled(projects.project == nil)
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                startNewProject()
                            } label: {
                                Image(systemName: "folder.badge.plus")
                            }
                        }
                    }
            }
            .navigationSplitViewStyle(.balanced)
            .alert("New Project", isPresented: $showNewProject) { newProjectPrompt }
            .alert("New Document", isPresented: $showAddFile) { newFilePrompt }
            .alert("Rename Document", isPresented: renameBinding) { renamePrompt }
            .alert("Rename Project", isPresented: renameProjectBinding) { renameProjectPrompt }
            .onAppear(perform: expandOpenProject)
            .onChange(of: projects.project) { _ in expandOpenProject() }
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
                    EmptyState("No projects yet —\ntap + to create one", icon: "folder")
                        .allowsHitTesting(false)
                }
            }
        }

        /// The tree: each project a node, its files the children.
        private var nodes: [SidebarNode] {
            projects.projects.map { project in
                let kids = (projects.filesByProject[project.id] ?? []).map {
                    SidebarNode(
                        id: $0.id, title: $0.title, project: project, file: $0, children: nil)
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
                Divider()
                Button("Delete Project", role: .destructive) {
                    projects.deleteProject(node.project)
                }
            }
        }

        // MARK: - Detail (editor)

        @ViewBuilder
        private var detail: some View {
            if projects.project == nil {
                EmptyState("Create or select a project to begin", icon: "folder")
            } else if let file = projects.selected {
                TouchEditorView(
                    docID: file.id,
                    markdown: projects.text(of: file),
                    editable: true,
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
    }
#endif
