import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// One row in the simplified Finder-style list.
struct FolderEntry: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case directory
        case markdown
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
        case .other: return "doc"
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
    var selectedURL: URL?
    var showOnlyMarkdown = true
    var filterText = ""

    /// Active read-only zip package, if any.
    private(set) var activePackage: PackageSession?

    var isPackageMode: Bool { activePackage != nil }

    /// Called when the user opens a Markdown file from the sidebar (in-window load).
    @ObservationIgnored var onOpenMarkdown: ((URL) -> Void)?
    /// Called when a package is opened or closed (workspace should flip read-only).
    @ObservationIgnored var onPackageSessionChanged: ((PackageSession?) -> Void)?

    /// Security-scoped roots the user explicitly granted.
    @ObservationIgnored private var scopedRoots: [URL] = []
    @ObservationIgnored private var directoryMonitor: DispatchSourceFileSystemObject?
    @ObservationIgnored private var monitorFD: Int32 = -1

    private let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx"]

    /// True when the real filesystem parent exists and is readable (not limited to grant root).
    /// In package mode, never climb above the extract root.
    var canGoUp: Bool {
        guard let current = currentDirectory else { return false }
        if let pkg = activePackage {
            let root = pkg.extractRoot.standardizedFileURL
            if current.standardizedFileURL.path == root.path { return false }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            return parent.path.hasPrefix(root.path)
        }
        let parent = current.deletingLastPathComponent().standardizedFileURL
        if parent.path == current.standardizedFileURL.path { return false }
        return canList(parent)
    }

    /// Real parent folder name (filesystem parent of the current directory).
    var parentFolderName: String? {
        guard canGoUp, let parent = parentDirectory else { return nil }
        if let pkg = activePackage, parent.standardizedFileURL == pkg.extractRoot.standardizedFileURL {
            return pkg.displayName
        }
        return parent.lastPathComponent
    }

    /// Real parent URL when `canGoUp`.
    var parentDirectory: URL? {
        guard let current = currentDirectory else { return nil }
        if let pkg = activePackage {
            let root = pkg.extractRoot.standardizedFileURL
            if current.standardizedFileURL.path == root.path { return nil }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path.hasPrefix(root.path) || parent.path == root.path {
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
            let rootPath = pkg.extractRoot.standardizedFileURL.path
            let currentPath = current.standardizedFileURL.path
            let rootLabel = "\(pkg.displayName).zip"
            if currentPath == rootPath { return [rootLabel] }
            if currentPath.hasPrefix(rootPath + "/") {
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
            closePackageIfNeeded()
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

    func closePackageIfNeeded() {
        guard let session = activePackage else { return }
        stopMonitoring()
        ZipPackageService.close(session)
        activePackage = nil
        onPackageSessionChanged?(nil)
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
            persistBookmark(for: folder)
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
            let rootPath = pkg.extractRoot.standardizedFileURL.path
            if !folder.path.hasPrefix(rootPath) {
                folder = pkg.extractRoot
            }
            rootDirectory = pkg.extractRoot
            currentDirectory = folder
            selectedURL = nil
            errorMessage = nil
            refresh()
            startMonitoring(folder)
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
        guard let parent = parentDirectory else { return }
        // Real parent only — never invent a synthetic parent.
        navigateToDirectory(parent)
    }

    func navigateToBreadcrumbIndex(_ index: Int) {
        guard let root = rootDirectory else { return }
        let segs = breadcrumbSegments
        guard index >= 0, index < segs.count else { return }
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
            currentDirectory = entry.url
            refresh()
            startMonitoring(entry.url)
        case .markdown:
            selectedURL = entry.url
            openMarkdownFile(entry.url)
        case .other:
            NSWorkspace.shared.open(entry.url)
        }
    }

    func refresh() {
        guard let directory = currentDirectory else {
            entries = []
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
                } else if markdownExtensions.contains(ext) {
                    kind = .markdown
                } else {
                    kind = .other
                }

                if showOnlyMarkdown && kind == .other { continue }

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

            built.sort { a, b in
                if a.kind == .directory && b.kind != .directory { return true }
                if a.kind != .directory && b.kind == .directory { return false }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }

            if !filterText.isEmpty {
                let q = filterText
                built = built.filter { $0.name.localizedCaseInsensitiveContains(q) }
            }

            entries = built
            errorMessage = nil
        } catch {
            entries = []
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
