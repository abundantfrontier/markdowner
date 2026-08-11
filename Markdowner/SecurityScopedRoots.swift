import Foundation

/// Tracks security-scoped folder URLs so sibling assets (e.g. `assets/*.png` next to a
/// user-opened `.md`) stay readable under App Sandbox.
///
/// Opening a single file only grants access to that file. Images live beside the document,
/// so we keep folder roots from **Open Folder…** / package extract and re-assert them when loading media.
enum SecurityScopedRoots {
    private static let lock = NSLock()
    private static var roots: [URL] = []

    /// Register a user-granted folder (or file’s parent if access succeeds).
    static func register(_ url: URL) {
        var folder = url.standardizedFileURL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), !isDir.boolValue {
            folder = folder.deletingLastPathComponent()
        }
        let accessed = folder.startAccessingSecurityScopedResource()
        lock.lock()
        if !roots.contains(where: { $0.path == folder.path }) {
            roots.append(folder)
            if accessed {
                NSLog("Markdowner: security scope registered %@", folder.path)
            }
        }
        lock.unlock()
    }

    /// Re-start access on every known root that is an ancestor of `url` (or `url` itself).
    @discardableResult
    static func accessForReading(_ url: URL) -> Bool {
        let target = url.standardizedFileURL
        var ok = target.startAccessingSecurityScopedResource()

        let parent = target.deletingLastPathComponent()
        if parent.startAccessingSecurityScopedResource() {
            ok = true
            lock.lock()
            if !roots.contains(where: { $0.path == parent.path }) {
                roots.append(parent)
            }
            lock.unlock()
        }

        lock.lock()
        let snapshot = roots
        lock.unlock()

        for root in snapshot {
            let rootPath = root.path
            if target.path == rootPath || target.path.hasPrefix(rootPath + "/") {
                if root.startAccessingSecurityScopedResource() {
                    ok = true
                }
            }
        }
        return ok
    }

    /// When a document is opened, try to keep its folder usable for relative images.
    static func noteDocumentOpened(_ documentURL: URL) {
        let file = documentURL.standardizedFileURL
        _ = file.startAccessingSecurityScopedResource()
        let parent = file.deletingLastPathComponent()

        lock.lock()
        let snapshot = roots
        lock.unlock()

        for root in snapshot {
            if parent.path == root.path || parent.path.hasPrefix(root.path + "/") {
                _ = root.startAccessingSecurityScopedResource()
                return
            }
        }
        // Try registering parent (succeeds when folder was user-selected; may no-op for bare file open).
        register(parent)
    }
}
