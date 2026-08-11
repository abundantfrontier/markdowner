import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// One row in the simplified Finder-style list.
struct FolderEntry: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case directory
        case markdown
        /// A `.zip` Markdown package — always listed, opens as read-only package.
        case package
        case other
    }

    let id: URL
    let url: URL
    let name: String
    let kind: Kind
    let modified: Date?
    let fileSize: Int64?

    var systemImage: String {
        switch kind {
        case .directory: return "folder.fill"
        case .markdown: return "doc.richtext.fill"
        case .package: return "doc.zipper"
        case .other:
            let ext = url.pathExtension.lowercased()
            switch ext {
            case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp":
                return "photo"
            case "pdf":
                return "doc.richtext"
            case "html", "htm":
                return "chevron.left.forwardslash.chevron.right"
            case "json", "yaml", "yml", "toml", "csv":
                return "curlybraces"
            case "txt", "rtf":
                return "doc.plaintext"
            default:
                return "doc"
            }
        }
    }
}

/// Browses a user-selected (or document-parent) directory tree.
/// Each window owns its own instance so sidebars stay independent.
@MainActor
@Observable
final class FolderBrowserModel {
    /// Optional shared instance (bookmarks restore); windows prefer their own model.
    static let shared = FolderBrowserModel()

    init() {}

    private(set) var currentDirectory: URL?
    private(set) var rootDirectory: URL?
    private(set) var entries: [FolderEntry] = []
    private(set) var errorMessage: String?
    /// Files hidden by the “Markdown only” filter in the current directory (not folders).
    private(set) var hiddenNonMarkdownCount: Int = 0
    var selectedURL: URL?
    /// When true, list folders + Markdown; hide other file types (images, txt, …).
    var showOnlyMarkdown = true
    var filterText = ""

    /// Active read-only zip package, if any.
    private(set) var activePackage: PackageSession?

    var isPackageMode: Bool { activePackage != nil }

    /// Root label for breadcrumbs / “up” — includes `.zip` in package mode.
    var rootDisplayName: String {
        if let pkg = activePackage { return pkg.sidebarRootLabel }
        return rootDirectory?.lastPathComponent ?? "Files"
    }

    /// Called when the user opens a Markdown file from the sidebar (in-window load).
    @ObservationIgnored var onOpenMarkdown: ((URL) -> Void)?
    /// Called when a package is opened or closed (workspace should flip read-only).
    @ObservationIgnored var onPackageSessionChanged: ((PackageSession?) -> Void)?

    /// Security-scoped roots the user explicitly granted.
    @ObservationIgnored private var scopedRoots: [URL] = []
    @ObservationIgnored private var directoryMonitor: DispatchSourceFileSystemObject?
    @ObservationIgnored private var monitorFD: Int32 = -1
    /// Folder we were browsing before entering a zip (so Back can leave the package).
    @ObservationIgnored private var folderBeforePackage: URL?

    private let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx"]

    /// True when Back should be enabled: parent inside package, or leave package at root.
    var canGoUp: Bool {
        if activePackage != nil {
            return parentDirectory != nil || canExitPackage
        }
        return parentDirectory != nil
    }

    /// At package extract root with a place to return to (previous folder or zip’s parent).
    var canExitPackage: Bool {
        guard isPackageMode, parentDirectory == nil else { return false }
        return exitPackageTarget != nil
    }

    /// Destination after leaving the zip (sidebar folder before open, else parent of the .zip file).
    var exitPackageTarget: URL? {
        guard activePackage != nil else { return nil }
        if let folderBeforePackage {
            return Self.canonical(folderBeforePackage)
        }
        if let pkg = activePackage {
            let parent = pkg.packageURL.deletingLastPathComponent().standardizedFileURL
            if canList(parent) { return Self.canonical(parent) }
        }
        return nil
    }

    /// Label for the Back button.
    var parentFolderName: String? {
        if canExitPackage {
            if let target = exitPackageTarget {
                return target.lastPathComponent
            }
            return "Close package"
        }
        guard let parent = parentDirectory else { return nil }
        if let pkg = activePackage, Self.samePath(parent, pkg.extractRoot) {
            return pkg.sidebarRootLabel
        }
        return parent.lastPathComponent
    }

    /// Help string for Back.
    var goUpHelp: String {
        if canExitPackage {
            if let name = exitPackageTarget?.lastPathComponent {
                return "Leave package and return to “\(name)” (⌘↑)"
            }
            return "Leave package (⌘↑)"
        }
        if canGoUp, let name = parentFolderName {
            return "Go to parent folder “\(name)” (⌘↑)"
        }
        return "No parent folder available"
    }

    /// Real parent URL *inside* the package tree (nil at package root).
    var parentDirectory: URL? {
        guard let current = currentDirectory else { return nil }
        if let pkg = activePackage {
            let root = Self.canonical(pkg.extractRoot)
            let cur = Self.canonical(current)
            if Self.samePath(cur, root) { return nil }
            let parent = cur.deletingLastPathComponent()
            // Parent must stay inside the extract tree (root inclusive).
            if Self.samePath(parent, root) || Self.isUnder(parent, root: root) {
                return parent
            }
            return nil
        }
        let parent = current.deletingLastPathComponent().standardizedFileURL
        if parent.path == current.standardizedFileURL.path { return nil }
        return parent
    }

    /// Breadcrumbs from the granted root (or package root) down to current.
    var breadcrumbSegments: [String] {
        guard let current = currentDirectory else { return [] }
        // Package: show zip display name as root segment.
        if let pkg = activePackage {
            let root = Self.canonical(pkg.extractRoot)
            let cur = Self.canonical(current)
            let rootLabel = pkg.sidebarRootLabel
            if Self.samePath(cur, root) { return [rootLabel] }
            if Self.isUnder(cur, root: root) {
                let rootPath = root.path
                let currentPath = cur.path
                let rel = String(currentPath.dropFirst(rootPath.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if rel.isEmpty { return [rootLabel] }
                return [rootLabel] + rel.split(separator: "/").map(String.init)
            }
            return [rootLabel]
        }
        // Prefer path relative to grant root when still under it; otherwise show last few components.
        if let root = rootDirectory {
            let rootPath = root.standardizedFileURL.path
            let currentPath = current.standardizedFileURL.path
            if currentPath == rootPath { return [root.lastPathComponent] }
            if currentPath.hasPrefix(rootPath + "/") || currentPath.hasPrefix(rootPath) {
                let rel = String(currentPath.dropFirst(rootPath.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if rel.isEmpty { return [root.lastPathComponent] }
                return [root.lastPathComponent] + rel.split(separator: "/").map(String.init)
            }
        }
        // Outside original root — show last 3 path components for context
        let parts = current.pathComponents.filter { $0 != "/" }
        return Array(parts.suffix(3))
    }

    var breadcrumb: String {
        let segs = breadcrumbSegments
        return segs.isEmpty ? "No folder" : segs.joined(separator: " › ")
    }

    // MARK: - Public API

    /// Prefer opening a folder the user picks (best sandbox experience).
    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "Choose a folder of Markdown files to browse"
        panel.prompt = "Open Folder"
        if let currentDirectory, activePackage == nil {
            panel.directoryURL = currentDirectory
        }
        if panel.runModal() == .OK, let url = panel.url {
            closePackageIfNeeded()
            openFolder(url, securityScoped: true)
        }
    }

    /// Open a `.zip` of Markdown (and assets) as a read-only package in the sidebar.
    func pickPackage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ZipPackageService.zipContentTypes
        panel.message = "Choose a zip package of Markdown files"
        panel.prompt = "Open Package"
        if panel.runModal() == .OK, let url = panel.url {
            openPackage(url)
        }
    }

    func openPackage(_ url: URL) {
        do {
            // Remember where we were so Back at package root can leave the zip.
            if activePackage == nil {
                folderBeforePackage = currentDirectory.map { Self.canonical($0) }
                    ?? url.deletingLastPathComponent().standardizedFileURL
            }
            closePackageIfNeeded(clearReturnFolder: false)
            let session = try ZipPackageService.open(url)
            activePackage = session
            // Browse the expanded tree; do not bookmark the temp extract as “last folder”.
            rootDirectory = session.extractRoot
            currentDirectory = session.extractRoot
            selectedURL = nil
            errorMessage = nil
            refresh()
            startMonitoring(session.extractRoot)
            onPackageSessionChanged?(session)
            NSLog("Markdowner: opened package %@ → %@", session.displayName, session.extractRoot.path)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn’t open package"
            alert.runModal()
        }
    }

    func closePackageIfNeeded(clearReturnFolder: Bool = true) {
        guard let session = activePackage else { return }
        stopMonitoring()
        ZipPackageService.close(session)
        activePackage = nil
        if clearReturnFolder {
            folderBeforePackage = nil
        }
        onPackageSessionChanged?(nil)
    }

    /// Leave package mode and restore the folder we came from (or the zip’s parent).
    func exitPackage() {
        let restore = exitPackageTarget
        closePackageIfNeeded(clearReturnFolder: true)
        guard let restore else {
            currentDirectory = nil
            rootDirectory = nil
            entries = []
            errorMessage = nil
            return
        }
        SecurityScopedRoots.accessForReading(restore)
        // Prefer treating as already-granted navigation when under a scoped root.
        let needsScope = !scopedRoots.contains { Self.samePath($0, restore) || Self.isUnder(restore, root: $0) }
        openFolder(restore, securityScoped: needsScope)
        NSLog("Markdowner: exited package → %@", restore.path)
    }

    /// Copy the package contents to a real folder so the user can edit with full save support.
    func extractActivePackage() {
        guard let session = activePackage else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to extract “\(session.displayName)” into"
        panel.prompt = "Extract"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        do {
            let dest = try ZipPackageService.extractToUserFolder(session, destinationParent: parent)
            let alert = NSAlert()
            alert.messageText = "Package extracted"
            alert.informativeText = "Saved to:\n\(dest.path)\n\nOpen that folder to edit and save."
            alert.addButton(withTitle: "Open Folder")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn {
                closePackageIfNeeded()
                openFolder(dest, securityScoped: true)
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn’t extract package"
            alert.runModal()
        }
    }

    func openFolder(_ url: URL, securityScoped: Bool) {
        var folder = url.standardizedFileURL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), !isDir.boolValue {
            folder = folder.deletingLastPathComponent()
        }

        if securityScoped {
            _ = folder.startAccessingSecurityScopedResource()
            if !scopedRoots.contains(where: { $0.standardizedFileURL == folder }) {
                scopedRoots.append(folder)
            }
            SecurityScopedRoots.register(folder)
            persistBookmark(for: folder)
        } else {
            // Still re-assert known scopes when navigating inside an already-granted tree.
            SecurityScopedRoots.accessForReading(folder)
        }

        // Leaving package mode when opening a normal folder.
        if activePackage != nil, securityScoped {
            closePackageIfNeeded()
        }

        // Initial grant sets the bookmark root, but "Up" always uses the real filesystem parent.
        rootDirectory = folder
        currentDirectory = folder
        selectedURL = nil
        errorMessage = nil
        refresh()
        startMonitoring(folder)

        // Write/Preview may have opened the .md before folder access existed — reload images.
        if securityScoped {
            NotificationCenter.default.post(name: .markdownerFolderAccessGranted, object: folder)
        }
    }

    /// Navigate the sidebar to a directory without changing the open document
    /// or document back/forward history. Parent/Back always target the real parent folder.
    func navigateToDirectory(_ url: URL) {
        var folder = url.standardizedFileURL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir) {
            if !isDir.boolValue {
                folder = folder.deletingLastPathComponent()
            }
        }

        // Package mode: clamp navigation inside the extract tree.
        if let pkg = activePackage {
            let root = Self.canonical(pkg.extractRoot)
            var target = Self.canonical(folder)
            if !Self.samePath(target, root) && !Self.isUnder(target, root: root) {
                target = root
            }
            rootDirectory = root
            currentDirectory = target
            selectedURL = nil
            errorMessage = nil
            refresh()
            startMonitoring(target)
            return
        }

        // Re-assert access via any ancestor security-scoped root.
        for root in scopedRoots {
            if folder.path.hasPrefix(root.standardizedFileURL.path) {
                _ = root.startAccessingSecurityScopedResource()
            }
        }
        _ = folder.startAccessingSecurityScopedResource()

        guard canList(folder) else {
            errorMessage = "Can’t access “\(folder.lastPathComponent)”. Use Open Folder… to grant access."
            return
        }

        // Keep the granted root for bookmarks, but never pretend a subfolder is the root.
        // Only move root upward if we're navigating outside it (so breadcrumbs still make sense).
        if let root = rootDirectory {
            let folderPath = folder.path
            let rootPath = root.path
            if !folderPath.hasPrefix(rootPath) && !rootPath.hasPrefix(folderPath) {
                // Disjoint paths — adopt the new folder as root of this branch.
                rootDirectory = folder
            } else if rootPath.hasPrefix(folderPath) && rootPath != folderPath {
                // Navigating to an ancestor of the grant root — expand root to that ancestor.
                rootDirectory = folder
            }
        } else {
            rootDirectory = folder
        }

        currentDirectory = folder
        selectedURL = nil
        errorMessage = nil
        refresh()
        startMonitoring(folder)
    }

    /// When a document is opened, try to show its parent folder.
    func revealDocument(at fileURL: URL?) {
        guard let fileURL else { return }
        selectedURL = fileURL.standardizedFileURL
        let parent = fileURL.deletingLastPathComponent().standardizedFileURL

        if let current = currentDirectory {
            let currentPath = current.path
            let parentPath = parent.path
            if parentPath == currentPath || parentPath.hasPrefix(currentPath + "/") || currentPath.hasPrefix(parentPath + "/") || currentPath == parentPath {
                if currentDirectory != parent {
                    currentDirectory = parent
                    refresh()
                    startMonitoring(parent)
                }
                return
            }
        }

        if canList(parent) {
            if rootDirectory == nil || !(parent.path.hasPrefix(rootDirectory!.path)) {
                rootDirectory = parent
            }
            currentDirectory = parent
            errorMessage = nil
            refresh()
            startMonitoring(parent)
        }
    }

    func goUp() {
        // At package root → leave the zip entirely (don’t trap the user).
        if activePackage != nil, parentDirectory == nil, canExitPackage {
            exitPackage()
            return
        }
        guard let parent = parentDirectory else { return }
        // Real parent only — never invent a synthetic parent.
        navigateToDirectory(parent)
    }

    func navigateToBreadcrumbIndex(_ index: Int) {
        let segs = breadcrumbSegments
        guard index >= 0, index < segs.count else { return }

        // Package: segment 0 is the synthetic zip name; path is under extractRoot.
        if let pkg = activePackage {
            let root = Self.canonical(pkg.extractRoot)
            if index == 0 {
                currentDirectory = root
            } else {
                var url = root
                // segs = [zipName, real, components…] — skip synthetic name.
                for seg in segs.dropFirst().prefix(index) {
                    url = url.appendingPathComponent(seg)
                }
                currentDirectory = Self.canonical(url)
            }
            refresh()
            if let currentDirectory {
                startMonitoring(currentDirectory)
            }
            return
        }

        guard let root = rootDirectory else { return }
        if index == 0 {
            currentDirectory = root
        } else {
            var url = root
            for seg in segs.dropFirst().prefix(index) {
                url = url.appendingPathComponent(seg)
            }
            currentDirectory = url
        }
        refresh()
        if let currentDirectory {
            startMonitoring(currentDirectory)
        }
    }

    func openEntry(_ entry: FolderEntry) {
        switch entry.kind {
        case .directory:
            // Canonicalize so package back/up compares cleanly against extractRoot.
            let dir = activePackage != nil ? Self.canonical(entry.url) : entry.url
            currentDirectory = dir
            refresh()
            startMonitoring(dir)
        case .markdown:
            selectedURL = entry.url
            openMarkdownFile(entry.url)
        case .package:
            openPackage(entry.url)
        case .other:
            NSWorkspace.shared.open(entry.url)
        }
    }

    func refresh() {
        guard let directory = currentDirectory else {
            entries = []
            hiddenNonMarkdownCount = 0
            return
        }

        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .contentModificationDateKey,
                    .fileSizeKey,
                    .isHiddenKey,
                    .isSymbolicLinkKey,
                ],
                options: [.skipsPackageDescendants]
            )

            var built: [FolderEntry] = []
            var hiddenOthers = 0
            for url in urls {
                let values = try? url.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .contentModificationDateKey,
                    .fileSizeKey,
                    .isHiddenKey,
                ])
                if values?.isHidden == true { continue }
                let name = url.lastPathComponent
                if name.hasPrefix(".") { continue }

                let isDirectory = values?.isDirectory == true
                let ext = url.pathExtension.lowercased()
                let kind: FolderEntry.Kind
                if isDirectory {
                    kind = .directory
                } else if ext == "zip" {
                    // Zip packages stay visible even with “Folders + Markdown” so you can open them.
                    kind = .package
                } else if markdownExtensions.contains(ext) {
                    kind = .markdown
                } else {
                    kind = .other
                }

                if showOnlyMarkdown && kind == .other {
                    hiddenOthers += 1
                    continue
                }

                built.append(
                    FolderEntry(
                        id: url.standardizedFileURL,
                        url: url.standardizedFileURL,
                        name: name,
                        kind: kind,
                        modified: values?.contentModificationDate,
                        fileSize: values?.fileSize.map { Int64($0) }
                    )
                )
            }

            // Folders, then packages, then markdown, then other — alpha within each.
            built.sort { a, b in
                func rank(_ k: FolderEntry.Kind) -> Int {
                    switch k {
                    case .directory: return 0
                    case .package: return 1
                    case .markdown: return 2
                    case .other: return 3
                    }
                }
                let ra = rank(a.kind), rb = rank(b.kind)
                if ra != rb { return ra < rb }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }

            if !filterText.isEmpty {
                let q = filterText
                built = built.filter { $0.name.localizedCaseInsensitiveContains(q) }
            }

            entries = built
            hiddenNonMarkdownCount = hiddenOthers
            errorMessage = nil
        } catch {
            entries = []
            hiddenNonMarkdownCount = 0
            errorMessage = error.localizedDescription
        }
    }

    func restoreLastFolderIfNeeded() {
        guard currentDirectory == nil else { return }
        // Never auto-restore into a temp package extract.
        guard activePackage == nil else { return }
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            _ = url.startAccessingSecurityScopedResource()
            if !scopedRoots.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
                scopedRoots.append(url)
            }
            SecurityScopedRoots.register(url)
            if isStale {
                persistBookmark(for: url)
            }
            rootDirectory = url
            currentDirectory = url
            refresh()
            startMonitoring(url)
        } catch {
            // Bookmark expired — ignore.
        }
    }

    // MARK: - Private

    private static let bookmarkKey = "markdowner.sidebarFolderBookmark"

    private func persistBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        } catch {
            // Non-fatal
        }
    }

    private func canList(_ directory: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) != nil
    }

    /// Resolve `/var` ↔ `/private/var` and standardize for package path comparisons.
    private static func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func samePath(_ a: URL, _ b: URL) -> Bool {
        canonical(a).path == canonical(b).path
    }

    /// True when `url` is strictly inside `root` (not equal).
    private static func isUnder(_ url: URL, root: URL) -> Bool {
        let path = canonical(url).path
        let rootPath = canonical(root).path
        return path.hasPrefix(rootPath + "/")
    }

    private func openMarkdownFile(_ url: URL) {
        if let onOpenMarkdown {
            onOpenMarkdown(url)
            return
        }
        // Fallback if no workspace is attached yet.
        NotificationCenter.default.post(name: .markdownerOpenFileURL, object: url)
    }

    private func startMonitoring(_ directory: URL) {
        stopMonitoring()
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        monitorFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.refresh()
        }
        source.setCancelHandler {
            close(fd)
        }
        directoryMonitor = source
        source.resume()
    }

    private func stopMonitoring() {
        directoryMonitor?.cancel()
        directoryMonitor = nil
        monitorFD = -1
    }
}

extension FolderEntry {
    var modifiedLabel: String {
        guard let modified else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: modified, relativeTo: Date())
    }

    var sizeLabel: String {
        guard kind != .directory, let fileSize else { return "" }
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}
