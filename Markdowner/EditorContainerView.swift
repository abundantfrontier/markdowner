import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct EditorContainerView: View {
    @Environment(\.controlActiveState) private var controlActiveState

    @State private var workspace = WorkspaceModel()
    /// Per-window browser so each workspace can be in a different folder.
    @State private var browser = FolderBrowserModel()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var viewMode: ViewMode = .wysiwyg
    @State private var showFind = false
    @State private var showReplace = false

    /// Menu commands are broadcast; only the key window should act on them.
    private var isKeyWindow: Bool {
        controlActiveState == .key
    }

    enum ViewMode: String, CaseIterable, Identifiable {
        case wysiwyg
        case source
        case split

        var id: String { rawValue }

        var title: String {
            switch self {
            case .wysiwyg: return "Write"
            case .source: return "Source"
            case .split: return "Split"
            }
        }

        /// Short help for the toolbar.
        var help: String {
            switch self {
            case .wysiwyg: return "Formatted document (read like a word processor)"
            case .source: return "Edit raw Markdown"
            case .split: return "Source + live preview side by side"
            }
        }

        var systemImage: String {
            switch self {
            case .wysiwyg: return "doc.richtext"
            case .source: return "chevron.left.forwardslash.chevron.right"
            case .split: return "rectangle.split.2x1"
            }
        }
    }

    var body: some View {
        let documentText = workspace.text
        workspaceSplit(documentText: documentText)
            .modifier(WorkspaceCommandHandlers(
                isKeyWindow: isKeyWindow,
                workspace: workspace,
                browser: browser,
                columnVisibility: $columnVisibility,
                viewMode: $viewMode,
                showFind: $showFind,
                showReplace: $showReplace,
                onExportHTML: exportHTML,
                onExportPDF: exportPDF,
                onInsertImage: insertImageMarkdown
            ))
    }

    private func workspaceSplit(documentText: String) -> some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            FileSidebarView(browser: browser, activeDocumentURL: workspace.fileURL)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 420)
                .navigationTitle("Files")
        } detail: {
            editorDetail(documentText: documentText)
                .navigationTitle(workspace.windowTitle)
                .navigationSubtitle(subtitle)
                // Keep first lines of the document out from under the toolbar glass.
                .padding(.top, 8)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 960, minHeight: 560)
        .toolbar { toolbarContent }
        .environment(\.openURL, LinkHandling.openURLAction)
        .onAppear {
            browser.restoreLastFolderIfNeeded()
            browser.onOpenMarkdown = { [workspace] url in
                workspace.openFile(at: url)
            }
            browser.onPackageSessionChanged = { [workspace] session in
                workspace.bindPackageSession(session)
            }
            if isKeyWindow {
                updateLinkResolutionBases()
            }
        }
        .onChange(of: workspace.fileURL) { _, newURL in
            browser.revealDocument(at: newURL)
            if isKeyWindow {
                updateLinkResolutionBases()
            }
        }
        .onChange(of: controlActiveState) { _, state in
            if state == .key {
                updateLinkResolutionBases()
            }
        }
        .onChange(of: browser.currentDirectory) { _, _ in
            if isKeyWindow {
                updateLinkResolutionBases()
            }
        }
        .onOpenURL { url in
            // new-window is handled only in AppDelegate to avoid a second openWindow.
            if url.scheme?.lowercased() == "markdowner" { return }
            workspace.openFile(at: url)
        }
    }

    private var subtitle: String {
        if let pkg = browser.activePackage ?? workspace.packageSession {
            return "\(pkg.sidebarRootLabel) · Read-only"
        }
        if let folder = workspace.fileURL?.deletingLastPathComponent().lastPathComponent {
            return folder
        }
        if let current = browser.currentDirectory?.lastPathComponent {
            return current
        }
        return "Open a folder or package to browse Markdown"
    }

    /// Keep link resolution rooted on the open document + sidebar folders.
    private func updateLinkResolutionBases() {
        LinkHandling.documentDirectory = workspace.fileURL?.deletingLastPathComponent()
            ?? browser.currentDirectory
        LinkHandling.currentDocumentURL = workspace.fileURL
        var roots: [URL] = []
        if let root = browser.rootDirectory { roots.append(root) }
        if let current = browser.currentDirectory { roots.append(current) }
        LinkHandling.searchRoots = roots
    }

    // MARK: - Detail

    private func editorDetail(documentText: String) -> some View {
        VStack(spacing: 0) {
            if workspace.isReadOnly {
                packageReadOnlyBanner
            }

            if showFind {
                FindReplaceBar(
                    isPresented: $showFind,
                    showReplace: $showReplace,
                    onFind: { query, caseSensitive in
                        findQuery = query
                        findCaseSensitive = caseSensitive
                        findDirection = 1
                        findNonce += 1
                    },
                    onNext: {
                        findDirection = 1
                        findNonce += 1
                    },
                    onPrevious: {
                        findDirection = -1
                        findNonce += 1
                    },
                    onReplace: { replacement in
                        replaceCurrent(replacement)
                        findDirection = 1
                        findNonce += 1
                    },
                    onReplaceAll: { replacement in
                        replaceAll(replacement)
                    },
                    onClose: {
                        findQuery = ""
                    }
                )
            }

            ZStack {
                NativeEditorView(
                    text: Binding(
                        get: { workspace.text },
                        set: { workspace.updateText($0) }
                    ),
                    viewMode: $viewMode,
                    findQuery: findQuery,
                    findCaseSensitive: findCaseSensitive,
                    findNonce: findNonce,
                    findDirection: findDirection,
                    isReadOnly: workspace.isReadOnly
                )

                if workspace.fileURL == nil
                    && documentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    emptyWorkspaceHint
                        .allowsHitTesting(false)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        // Keep document clear of the titlebar/toolbar chrome.
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: 0)
        }
        .padding(.top, 4)
    }

    // MARK: - Find / replace (drives editors via findNonce)

    @State private var findQuery: String = ""
    @State private var findCaseSensitive = false
    @State private var findNonce: Int = 0
    @State private var findDirection: Int = 1

    private var packageReadOnlyBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.doc.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Read-only package")
                    .font(.subheadline.weight(.semibold))
                Text({
                    let name = workspace.packageSession?.sidebarRootLabel
                        ?? browser.activePackage?.sidebarRootLabel
                        ?? "package.zip"
                    return "“\(name)” — browsing only. Extract to a folder to edit and save."
                }())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Extract…") {
                browser.extractActivePackage()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(browser.activePackage == nil)
            .help("Copy package contents to a folder you can edit")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func replaceCurrent(_ replacement: String) {
        guard !workspace.isReadOnly else { return }
        guard !findQuery.isEmpty else { return }
        let options: String.CompareOptions = findCaseSensitive ? [] : [.caseInsensitive]
        guard let range = workspace.text.range(of: findQuery, options: options) else { return }
        workspace.updateText(workspace.text.replacingCharacters(in: range, with: replacement))
    }

    private func replaceAll(_ replacement: String) {
        guard !findQuery.isEmpty else { return }
        let options: String.CompareOptions = findCaseSensitive ? [] : [.caseInsensitive]
        let updated = workspace.text.replacingOccurrences(
            of: findQuery,
            with: replacement,
            options: options
        )
        workspace.updateText(updated)
    }

    private var emptyWorkspaceHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)
            Text("Start writing, or pick a file in the sidebar")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("⌥⌘O opens a folder · Open Package for a .zip · click any .md to load it here")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            // Browser-style document history (when following .md links)
            Button {
                workspace.goBack()
            } label: {
                Image(systemName: "chevron.backward")
            }
            .help("Back")
            .disabled(!workspace.canGoBack)
            .keyboardShortcut("[", modifiers: .command)

            Button {
                workspace.goForward()
            } label: {
                Image(systemName: "chevron.forward")
            }
            .help("Forward")
            .disabled(!workspace.canGoForward)
            .keyboardShortcut("]", modifiers: .command)

            // Sidebar toggle is provided automatically by NavigationSplitView.
            Button {
                browser.pickFolder()
            } label: {
                Image(systemName: "folder")
            }
            .help("Open Folder… (⌥⌘O)")

            Button {
                browser.pickPackage()
            } label: {
                Image(systemName: "doc.zipper")
            }
            .help("Open Package… (.zip of Markdown files)")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Picker("View", selection: $viewMode) {
                ForEach(ViewMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                        .help(mode.help)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .help("Write = formatted · Source = edit Markdown · Split = both (⌘\\ / ⌥⌘\\)")

            Button {
                wrapSelection("**", "**")
            } label: {
                Image(systemName: "bold")
            }
            .help("Bold (⌘B)")
            .disabled(workspace.isReadOnly)

            Button {
                wrapSelection("*", "*")
            } label: {
                Image(systemName: "italic")
            }
            .help("Italic (⌘I)")
            .disabled(workspace.isReadOnly)

            Button {
                wrapSelection("[", "](url)")
            } label: {
                Image(systemName: "link")
            }
            .help("Link")
            .disabled(workspace.isReadOnly)

            Button {
                insertImageMarkdown()
            } label: {
                Image(systemName: "photo")
            }
            .help("Insert image")
            .disabled(workspace.isReadOnly)

            Button {
                showFind = true
                showReplace = false
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .help("Find (⌘F)")

            Button {
                openCurrentInNewWindow()
            } label: {
                Image(systemName: "rectangle.on.rectangle")
            }
            .help("Open this document in a new window (side‑by‑side compare)")
            .disabled(workspace.fileURL == nil)

            Button {
                workspace.save()
            } label: {
                if workspace.isDirty {
                    Label("Save", systemImage: "square.and.arrow.down.fill")
                } else {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
            }
            .help(workspace.isReadOnly
                  ? "Read-only package — extract to edit and save"
                  : (workspace.isDirty ? "Save changes (⌘S)" : "Save (⌘S)"))
            .disabled(workspace.isReadOnly || (!workspace.isDirty && workspace.fileURL != nil))
            .opacity(workspace.isReadOnly ? 0.4 : (workspace.isDirty || workspace.fileURL == nil ? 1 : 0.55))

            Menu {
                Button("Save") { workspace.save() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Save As…") { workspace.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Export HTML…") { exportHTML() }
                Button("Export PDF…") { exportPDF() }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .help("Save / Export")
        }
    }

    private func wrapSelection(_ before: String, _ after: String) {
        // Forward to the focused text view via the shared format channel.
        if before == "**" {
            NotificationCenter.default.post(name: .markdownerFormat, object: "bold")
        } else if before == "*" {
            NotificationCenter.default.post(name: .markdownerFormat, object: "italic")
        } else if before == "[" {
            NotificationCenter.default.post(name: .markdownerFormat, object: "link")
        }
    }

    private func insertImageMarkdown() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.png, .jpeg, .gif, .tiff, .bmp]
        if let webp = UTType(filenameExtension: "webp") { types.append(webp) }
        if let heic = UTType(filenameExtension: "heic") { types.append(heic) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
            let ext = url.pathExtension.lowercased()
            let mime: String
            switch ext {
            case "jpg", "jpeg": mime = "image/jpeg"
            case "gif": mime = "image/gif"
            case "webp": mime = "image/webp"
            default: mime = "image/png"
            }
            let b64 = data.base64EncodedString()
            let alt = url.deletingPathExtension().lastPathComponent
            let snippet = "\n\n![\(alt)](data:\(mime);base64,\(b64))\n\n"
            DispatchQueue.main.async {
                workspace.updateText(workspace.text + snippet)
            }
        }
    }

    // MARK: - Actions

    private func exportHTML() {
        let name = workspace.fileURL?.deletingPathExtension().lastPathComponent ?? "Document"
        ExportService.exportHTML(markdown: workspace.text, suggestedName: name)
    }

    private func exportPDF() {
        let name = workspace.fileURL?.deletingPathExtension().lastPathComponent ?? "Document"
        ExportService.exportPDF(markdown: workspace.text, suggestedName: name)
    }

    /// Open the same file in another workspace window for compare / dual panes.
    private func openCurrentInNewWindow() {
        guard let url = workspace.fileURL else { return }
        NotificationCenter.default.post(name: .markdownerOpenFileURLInNewWindow, object: url)
    }

}

/// Holds a URL that a brand-new window should open on appear.
enum PendingWindowOpen {
    nonisolated(unsafe) static var fileURL: URL?
}

// MARK: - Key-window menu command routing (keeps multi-window menus sane)

private struct WorkspaceCommandHandlers: ViewModifier {
    let isKeyWindow: Bool
    let workspace: WorkspaceModel
    let browser: FolderBrowserModel
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Binding var viewMode: EditorContainerView.ViewMode
    @Binding var showFind: Bool
    @Binding var showReplace: Bool
    let onExportHTML: () -> Void
    let onExportPDF: () -> Void
    let onInsertImage: () -> Void
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        registerWindowBridge(
            windowCommands(
                fileAndNavCommands(
                    editCommands(content)
                )
            )
        )
    }

    private func registerWindowBridge<V: View>(_ content: V) -> some View {
        content
            .onAppear {
                WorkspaceWindowBridge.openWindowAction = openWindow
                if let pending = PendingWindowOpen.fileURL {
                    PendingWindowOpen.fileURL = nil
                    columnVisibility = .all
                    workspace.openFile(at: pending)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .markdownerOpenNewWindow)) { note in
                let token = note.userInfo?["token"] as? UInt64
                let activate = note.userInfo?["activate"] as? Bool ?? false
                WorkspaceWindowBridge.fulfillFromEnvironment(openWindow, token: token, activate: activate)
            }
            .onReceive(NotificationCenter.default.publisher(for: .markdownerOpenFileURLInNewWindow)) { note in
                guard let url = note.object as? URL else { return }
                PendingWindowOpen.fileURL = url
                WorkspaceWindowBridge.openWindowAction = openWindow
                openWindow(id: WorkspaceWindowBridge.workspaceWindowID)
            }
            .onReceive(NotificationCenter.default.publisher(for: .markdownerDuplicateDocumentWindow)) { _ in
                guard isKeyWindow, let url = workspace.fileURL else { return }
                PendingWindowOpen.fileURL = url
                WorkspaceWindowBridge.openWindowAction = openWindow
                openWindow(id: WorkspaceWindowBridge.workspaceWindowID)
            }
    }

    private func windowCommands<V: View>(_ content: V) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .markdownerOpenFolder)) { _ in
                guard isKeyWindow else { return }
                columnVisibility = .all
                browser.pickFolder()
            }
            .onReceive(NotificationCenter.default.publisher(for: .markdownerOpenPackage)) { _ in
                guard isKeyWindow else { return }
                columnVisibility = .all
                browser.pickPackage()
            }
            .onReceive(NotificationCenter.default.publisher(for: .markdownerExtractPackage)) { _ in
                guard isKeyWindow else { return }
                browser.extractActivePackage()
            }
            .onReceive(NotificationCenter.default.publisher(for: .markdownerToggleSidebar)) { _ in
                guard isKeyWindow else { return }
                withAnimation(.snappy) {
                    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                }
            }
    }

    private func fileAndNavCommands<V: View>(_ content: V) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .markdownerNewDocument)) { _ in
                guard isKeyWindow else { return }
                workspace.newDocument()
            }
            .onReceive(NotificationCenter.default.publisher(for: .markdownerOpenDocument)) { _ in
                guard isKeyWindow else { return }
                workspace.openPanel()
            }
            .onReceive(NotificationCenter.default.publisher(for: .markdownerSaveDocument)) { _ in
                guard isKeyWindow else { return }
                workspace.save()
            }
            .onReceive(NotificationCenter.default.publisher(for: .markdownerSaveDocumentAs)) { _ in
                guard isKeyWindow else { return }
                workspace.saveAs()
            }
            .onReceive(NotificationCenter.default.publisher(for: .markdownerOpenFileURL)) { note in
                guard isKeyWindow else { return }
                if let url = note.object as? URL {
                    columnVisibility = .all
                    workspace.openFile(at: url)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .markdownerNavigateDirectory)) { note in
                guard isKeyWindow else { return }
                if let url = note.object as? URL {
                    columnVisibility = .all
                    browser.navigateToDirectory(url)
                }
            }
    }

    private func editCommands<V: View>(_ content: V) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .markdownerShowFind)) { note in
                guard isKeyWindow else { return }
                showFind = true
                if let replace = note.userInfo?["replace"] as? Bool {
                    showReplace = replace
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .markdownerExport)) { note in
                guard isKeyWindow else { return }
                guard let kind = note.object as? String else { return }
                if kind == "html" { onExportHTML() }
                else if kind == "pdf" { onExportPDF() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .markdownerInsertImage)) { _ in
                guard isKeyWindow else { return }
                onInsertImage()
            }
            .onReceive(NotificationCenter.default.publisher(for: .markdownerFormat)) { note in
                guard isKeyWindow else { return }
                guard let action = note.object as? String else { return }
                switch action {
                case "mode-wysiwyg", "wysiwyg": viewMode = .wysiwyg
                case "mode-source", "source": viewMode = .source
                case "mode-split", "split": viewMode = .split
                case "image": onInsertImage()
                default: break
                }
            }
    }
}

struct SettingsView: View {
    var body: some View {
        Form {
            Section {
                Text("Markdowner opens to a blank workspace with a folder sidebar — no open dialog.")
                    .foregroundStyle(.secondary)
                Text("Browse a folder of notes, click a file to edit, and save with ⌘S.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("About")
            }

            Section {
                LabeledContent("New Window", value: "⇧⌘N")
                LabeledContent("Back / Forward", value: "⌘[ / ⌘]")
                LabeledContent("Open folder", value: "⌥⌘O")
                LabeledContent("Toggle sidebar", value: "⌥⌘S")
                LabeledContent("New / Open / Save", value: "⌘N / ⌘O / ⌘S")
                LabeledContent("Source / Split", value: "⌘\\ / ⌥⌘\\")
                LabeledContent("Find / Replace", value: "⌘F / ⌥⌘F")
            } header: {
                Text("Shortcuts")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 300)
        .padding()
    }
}
