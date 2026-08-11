import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// Single-window workspace: blank on launch, files open from the sidebar or File menu.
/// Supports browser-style back/forward through opened Markdown files.
@MainActor
@Observable
final class WorkspaceModel {
    var text: String = ""
    var fileURL: URL?
    var isDirty = false
    var windowTitle: String = "Untitled"

    /// When set, documents come from a zip package and must not be saved in-place.
    private(set) var packageSession: PackageSession?

    var isReadOnly: Bool { packageSession != nil }

    /// Browser-style history of file URLs visited in this window.
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    @ObservationIgnored private var backStack: [URL] = []
    @ObservationIgnored private var forwardStack: [URL] = []
    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private var securityScopedFile: URL?

    private let markdownTypes: [UTType] = {
        var types: [UTType] = [.plainText, .text]
        if let md = UTType(filenameExtension: "md") { types.insert(md, at: 0) }
        if let markdown = UTType(filenameExtension: "markdown") { types.insert(markdown, at: 0) }
        return types
    }()

    // MARK: - Editing

    /// Update buffer text. Marks dirty only when the string actually changes
    /// (clicks / selection / focus must not trigger a save dialog).
    /// Read-only package mode ignores edits.
    func updateText(_ newText: String) {
        guard !isReadOnly else { return }
        guard newText != text else { return }
        text = newText
        if !isLoading {
            isDirty = true
            refreshTitle()
        }
    }

    func bindPackageSession(_ session: PackageSession?) {
        packageSession = session
        if session != nil {
            isDirty = false
            refreshTitle()
        }
    }

    // MARK: - Navigation history

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        if let current = fileURL {
            forwardStack.append(current)
        }
        updateHistoryFlags()
        _ = openFile(at: previous, confirmIfDirty: true, recordHistory: false)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let current = fileURL {
            backStack.append(current)
        }
        updateHistoryFlags()
        _ = openFile(at: next, confirmIfDirty: true, recordHistory: false)
    }

    private func pushHistory(from oldURL: URL?, to newURL: URL) {
        guard let oldURL, oldURL.standardizedFileURL != newURL.standardizedFileURL else {
            updateHistoryFlags()
            return
        }
        backStack.append(oldURL.standardizedFileURL)
        // Cap history so it can't grow forever
        if backStack.count > 50 {
            backStack.removeFirst(backStack.count - 50)
        }
        forwardStack.removeAll()
        updateHistoryFlags()
    }

    private func updateHistoryFlags() {
        canGoBack = !backStack.isEmpty
        canGoForward = !forwardStack.isEmpty
    }

    // MARK: - New / Open / Save

    func newDocument(confirmIfDirty: Bool = true) {
        if confirmIfDirty && !confirmDiscardIfNeeded() { return }
        if let current = fileURL {
            backStack.append(current)
            forwardStack.removeAll()
        }
        stopAccessingFile()
        isLoading = true
        text = ""
        fileURL = nil
        LinkHandling.currentDocumentURL = nil
        isDirty = false
        isLoading = false
        refreshTitle()
        updateHistoryFlags()
    }

    func openPanel() {
        if !confirmDiscardIfNeeded() { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = markdownTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a Markdown file"
        if let dir = fileURL?.deletingLastPathComponent() ?? LinkHandling.documentDirectory {
            panel.directoryURL = dir
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openFile(at: url)
    }

    @discardableResult
    func openFile(at url: URL, confirmIfDirty: Bool = true, recordHistory: Bool = true) -> Bool {
        if confirmIfDirty && !confirmDiscardIfNeeded() { return false }

        let standardized = url.standardizedFileURL
        let previousURL = fileURL
        let accessed = standardized.startAccessingSecurityScopedResource()
        // Re-assert any Open Folder scopes so `assets/` next to this file is readable.
        SecurityScopedRoots.noteDocumentOpened(standardized)

        do {
            let data = try Data(contentsOf: standardized)
            guard let string = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }

            if let old = securityScopedFile, old != standardized {
                old.stopAccessingSecurityScopedResource()
            }
            securityScopedFile = accessed ? standardized : nil

            if recordHistory {
                pushHistory(from: previousURL, to: standardized)
            } else {
                updateHistoryFlags()
            }

            isLoading = true
            // Set file URL + link base *before* text so Write-mode attributed links resolve
            // against the correct folder on the first paint (not the previous document's).
            fileURL = standardized
            let parent = standardized.deletingLastPathComponent()
            LinkHandling.documentDirectory = parent
            LinkHandling.currentDocumentURL = standardized
            // Keep parent access alive for relative images when the system allows it.
            SecurityScopedRoots.register(parent)
            SecurityScopedRoots.accessForReading(parent)
            text = string
            isDirty = false
            isLoading = false

            refreshTitle()
            NSLog("Markdowner: opened %@ (%d chars)%@", standardized.lastPathComponent, string.count,
                  isReadOnly ? " [read-only package]" : "")
            return true
        } catch {
            if accessed { standardized.stopAccessingSecurityScopedResource() }
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn’t open file"
            alert.runModal()
            return false
        }
    }

    @discardableResult
    func save() -> Bool {
        if isReadOnly {
            presentReadOnlyAlert()
            return false
        }
        if let fileURL {
            return write(to: fileURL)
        }
        return saveAs()
    }

    @discardableResult
    func saveAs() -> Bool {
        if isReadOnly {
            presentReadOnlyAlert()
            return false
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = markdownTypes
        panel.canCreateDirectories = true
        panel.title = "Save Markdown"
        panel.nameFieldStringValue = suggestedFilename
        if let dir = fileURL?.deletingLastPathComponent() ?? LinkHandling.documentDirectory {
            panel.directoryURL = dir
        }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(to: url, becomingCurrent: true)
    }

    // MARK: - Private

    private var suggestedFilename: String {
        if let fileURL {
            return fileURL.lastPathComponent
        }
        return "Untitled.md"
    }

    private func write(to url: URL, becomingCurrent: Bool = false) -> Bool {
        if isReadOnly {
            presentReadOnlyAlert()
            return false
        }
        do {
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
            if becomingCurrent || fileURL == nil || fileURL?.standardizedFileURL != url.standardizedFileURL {
                stopAccessingFile()
                let accessed = url.startAccessingSecurityScopedResource()
                securityScopedFile = accessed ? url : nil
                fileURL = url.standardizedFileURL
            }
            isDirty = false
            refreshTitle()
            return true
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn’t save file"
            alert.runModal()
            return false
        }
    }

    private func refreshTitle() {
        let base = fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        if isReadOnly {
            windowTitle = base
        } else {
            windowTitle = isDirty ? "\(base) — Edited" : base
        }
    }

    private func presentReadOnlyAlert() {
        let alert = NSAlert()
        alert.messageText = "Read-only package"
        let name = packageSession?.displayName ?? "This package"
        alert.informativeText = "“\(name)” is open as a read-only zip package.\n\nExtract the package to a folder if you want to edit and save."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func confirmDiscardIfNeeded() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(fileURL?.lastPathComponent ?? "Untitled")”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return save()
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    private func stopAccessingFile() {
        securityScopedFile?.stopAccessingSecurityScopedResource()
        securityScopedFile = nil
    }
}
