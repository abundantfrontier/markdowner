import AppKit
import SwiftUI

@main
struct MarkdownerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // WindowGroup allows any number of independent workspaces.
        WindowGroup(id: WorkspaceWindowBridge.workspaceWindowID) {
            EditorContainerView()
        }
        .defaultSize(width: 1100, height: 720)
        // Do NOT use handlesExternalEvents for markdowner:// — SwiftUI would open a window
        // and AppDelegate would open a second one. URL handling is only in AppDelegate/bridge.
        .commands {
            fileCommands
            windowCommands
            formattingCommands
            editingCommands
            sidebarCommands
            exportCommands
            helpCommands
        }

        Settings {
            SettingsView()
        }
    }

    // MARK: - File (workspace, not DocumentGroup)

    @CommandsBuilder
    private var fileCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New") {
                NotificationCenter.default.post(name: .markdownerNewDocument, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Open…") {
                NotificationCenter.default.post(name: .markdownerOpenDocument, object: nil)
            }
            .keyboardShortcut("o", modifiers: .command)

            Divider()

            Button("Open Folder in Sidebar…") {
                NotificationCenter.default.post(name: .markdownerOpenFolder, object: nil)
            }
            .keyboardShortcut("o", modifiers: [.command, .option])

            Button("Open Package…") {
                NotificationCenter.default.post(name: .markdownerOpenPackage, object: nil)
            }
            .keyboardShortcut("o", modifiers: [.command, .option, .shift])
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                NotificationCenter.default.post(name: .markdownerSaveDocument, object: nil)
            }
            .keyboardShortcut("s", modifiers: .command)

            Button("Save As…") {
                NotificationCenter.default.post(name: .markdownerSaveDocumentAs, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Divider()

            Button("Extract Package…") {
                NotificationCenter.default.post(name: .markdownerExtractPackage, object: nil)
            }
        }
    }

    @CommandsBuilder
    private var windowCommands: some Commands {
        CommandGroup(after: .newItem) {
            // openWindow is injected into Commands on macOS 13+
            NewWindowCommandButton()
        }
    }

    // MARK: - Format / Edit / Sidebar / Export / Help

    @CommandsBuilder
    private var formattingCommands: some Commands {
        CommandGroup(replacing: .textFormatting) {
            Button("Bold") {
                NotificationCenter.default.post(name: .markdownerFormat, object: "bold")
            }
            .keyboardShortcut("b", modifiers: .command)

            Button("Italic") {
                NotificationCenter.default.post(name: .markdownerFormat, object: "italic")
            }
            .keyboardShortcut("i", modifiers: .command)

            Button("Strikethrough") {
                NotificationCenter.default.post(name: .markdownerFormat, object: "strikethrough")
            }
            .keyboardShortcut("x", modifiers: [.command, .shift])

            Divider()

            Button("Heading 1") {
                NotificationCenter.default.post(name: .markdownerFormat, object: "h1")
            }
            .keyboardShortcut("1", modifiers: [.command, .option])

            Button("Heading 2") {
                NotificationCenter.default.post(name: .markdownerFormat, object: "h2")
            }
            .keyboardShortcut("2", modifiers: [.command, .option])

            Button("Heading 3") {
                NotificationCenter.default.post(name: .markdownerFormat, object: "h3")
            }
            .keyboardShortcut("3", modifiers: [.command, .option])

            Divider()

            Button("Bullet List") {
                NotificationCenter.default.post(name: .markdownerFormat, object: "ul")
            }
            .keyboardShortcut("8", modifiers: [.command, .shift])

            Button("Numbered List") {
                NotificationCenter.default.post(name: .markdownerFormat, object: "ol")
            }
            .keyboardShortcut("7", modifiers: [.command, .shift])

            Button("Task List") {
                NotificationCenter.default.post(name: .markdownerFormat, object: "task")
            }

            Button("Quote") {
                NotificationCenter.default.post(name: .markdownerFormat, object: "quote")
            }
            .keyboardShortcut("'", modifiers: [.command, .shift])

            Divider()

            Button("Insert Link…") {
                NotificationCenter.default.post(name: .markdownerFormat, object: "link")
            }
            .keyboardShortcut("k", modifiers: .command)

            Button("Insert Image…") {
                NotificationCenter.default.post(name: .markdownerInsertImage, object: nil)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])

            Button("Inline Code") {
                NotificationCenter.default.post(name: .markdownerFormat, object: "code")
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])

            Button("Code Block") {
                NotificationCenter.default.post(name: .markdownerFormat, object: "codeblock")
            }

            Button("Horizontal Rule") {
                NotificationCenter.default.post(name: .markdownerFormat, object: "hr")
            }
        }
    }

    @CommandsBuilder
    private var editingCommands: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find…") {
                NotificationCenter.default.post(
                    name: .markdownerShowFind,
                    object: nil,
                    userInfo: ["replace": false]
                )
            }
            .keyboardShortcut("f", modifiers: .command)

            Button("Find and Replace…") {
                NotificationCenter.default.post(
                    name: .markdownerShowFind,
                    object: nil,
                    userInfo: ["replace": true]
                )
            }
            .keyboardShortcut("f", modifiers: [.command, .option])

            Button("Find Next") {
                NotificationCenter.default.post(name: .markdownerFindCommand, object: "next")
            }
            .keyboardShortcut("g", modifiers: .command)

            Button("Find Previous") {
                NotificationCenter.default.post(name: .markdownerFindCommand, object: "previous")
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])

            Divider()

            Button("Write Mode") {
                NotificationCenter.default.post(name: .markdownerFormat, object: "mode-wysiwyg")
            }

            Button("Source Mode") {
                NotificationCenter.default.post(name: .markdownerFormat, object: "mode-source")
            }
            .keyboardShortcut("\\", modifiers: .command)

            Button("Split Mode") {
                NotificationCenter.default.post(name: .markdownerFormat, object: "mode-split")
            }
            .keyboardShortcut("\\", modifiers: [.command, .option])
        }
    }

    @CommandsBuilder
    private var sidebarCommands: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Toggle File Sidebar") {
                NotificationCenter.default.post(name: .markdownerToggleSidebar, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
        }
    }

    @CommandsBuilder
    private var exportCommands: some Commands {
        CommandGroup(after: .importExport) {
            Button("Export as HTML…") {
                NotificationCenter.default.post(name: .markdownerExport, object: "html")
            }

            Button("Export as PDF…") {
                NotificationCenter.default.post(name: .markdownerExport, object: "pdf")
            }
        }
    }

    @CommandsBuilder
    private var helpCommands: some Commands {
        CommandGroup(replacing: .help) {
            Button("Markdowner Help") {
                if let url = URL(string: "https://www.markdownguide.org/basic-syntax/") {
                    NSWorkspace.shared.open(url)
                }
            }
            Divider()
            Button("Build Info…") {
                BuildInfo.presentPanel()
            }
        }

        // Also under the app menu next to standard About (easier to find).
        CommandGroup(after: .appInfo) {
            Button("Build Info…") {
                BuildInfo.presentPanel()
            }
        }
    }
}

/// Extra File-menu items (SwiftUI). **New Window** is installed as a real AppKit
/// `NSMenuItem` in `AppDelegate` so ClingBar’s AX “File → New Window” path works
/// without activating the app first.
private struct NewWindowCommandButton: View {
    var body: some View {
        Button("Open Current Document in New Window") {
            NotificationCenter.default.post(name: .markdownerDuplicateDocumentWindow, object: nil)
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])
    }
}

// MARK: - App delegate (Finder open + Dock reopen + URL scheme)

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Marker so we can rebind SwiftUI-generated “New Window” items after menu rebuilds.
    private static let newWindowMarker = "markdowner.newWindow"
    private var windowRestorableObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure we never present the legacy NSDocument open panel on launch.
        NSDocumentController.shared.closeAllDocuments(withDelegate: nil, didCloseAllSelector: nil, contextInfo: nil)
        // Prevent macOS from restoring a stack of old workspace windows (looks like “double open”).
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        NSWindow.allowsAutomaticWindowTabbing = false

        windowRestorableObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { note in
            (note.object as? NSWindow)?.isRestorable = false
        }
        NSApp.windows.forEach { $0.isRestorable = false }

        // Log identity so Console/debug sessions can confirm which binary is running.
        NSLog("%@", BuildInfo.summary)

        // Install AppKit File → New Window (AX-visible, works when app is not frontmost).
        installOrRebindNewWindowMenuItem()
        // SwiftUI rebuilds the menu asynchronously — rebind a few times.
        for delay in [0.3, 1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.installOrRebindNewWindowMenuItem()
            }
        }

        // Collapse restored duplicates after SwiftUI finishes restoring scenes.
        for delay in [0.15, 0.5, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Self.collapseRestoredWorkspaceWindowsIfNeeded()
            }
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let windowRestorableObserver {
            NotificationCenter.default.removeObserver(windowRestorableObserver)
        }
    }

    /// If state restoration left several workspace windows, keep the key/main one only.
    @MainActor
    private static func collapseRestoredWorkspaceWindowsIfNeeded() {
        let workspaces = NSApp.windows.filter { window in
            guard window.level == .normal, window.isVisible || window.isMiniaturized else { return false }
            let s = window.frame.size
            return s.width >= 600 && s.height >= 400
        }
        guard workspaces.count > 1 else { return }
        let keep = workspaces.first(where: \.isKeyWindow)
            ?? workspaces.first(where: \.isMainWindow)
            ?? workspaces.first
        guard let keep else { return }
        NSLog("Markdowner: collapsing %d restored windows → keep 1", workspaces.count)
        for window in workspaces where window !== keep {
            window.isRestorable = false
            window.close()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        installOrRebindNewWindowMenuItem()
        // Do not open a window on every activation — races with markdowner://new-window.
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        // We use a WindowGroup workspace, not DocumentGroup — create windows explicitly.
        false
    }

    /// Dock click / second activation when there may be no window on the active Space.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            if !flag || !WorkspaceWindowBridge.hasUsableWorkspaceWindow() {
                NSLog("Markdowner: reopen — opening workspace window (hasVisibleWindows=%@)", flag ? "true" : "false")
                // Dock expects the app to come forward.
                WorkspaceWindowBridge.openNewWorkspaceWindow(activate: true)
            }
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            // Prefer a single new-window URL even if the system delivers duplicates.
            var handledNewWindow = false
            for url in urls {
                if url.scheme?.lowercased() == "markdowner" {
                    if !handledNewWindow, WorkspaceWindowBridge.handleURL(url) {
                        handledNewWindow = true
                    }
                    continue
                }
                if !WorkspaceWindowBridge.hasUsableWorkspaceWindow() {
                    WorkspaceWindowBridge.openNewWorkspaceWindow(activate: false)
                }
                NotificationCenter.default.post(name: .markdownerOpenFileURL, object: url)
            }
        }
    }

    /// AppKit menu / AX target — **do not activate** (ClingBar stay-on-Space).
    @objc func markdownerNewWindow(_ sender: Any?) {
        Task { @MainActor in
            NSLog("Markdowner: New Window (menu/AX)")
            WorkspaceWindowBridge.openNewWorkspaceWindow(activate: false)
        }
    }

    /// Ensure File → **New Window** exists as a real `NSMenuItem` with this object as target.
    /// ClingBar presses this via Accessibility without bringing Markdowner front first.
    private func installOrRebindNewWindowMenuItem() {
        guard let mainMenu = NSApp.mainMenu else { return }

        for top in mainMenu.items {
            guard let submenu = top.submenu else { continue }
            let menuTitle = top.title.trimmingCharacters(in: .whitespacesAndNewlines)
            // English "File"; also match empty localized edge cases via known first items.
            let isFileMenu = menuTitle == "File"
                || submenu.items.contains { $0.title == "New" || $0.title == "Open…" || $0.title.hasPrefix("Open") }
            guard isFileMenu else { continue }

            // Prefer rebinding an existing "New Window" (SwiftUI Commands may have created it).
            if let existing = submenu.items.first(where: { $0.title == "New Window" }) {
                existing.target = self
                existing.action = #selector(markdownerNewWindow(_:))
                existing.keyEquivalent = "n"
                existing.keyEquivalentModifierMask = [.command, .shift]
                existing.representedObject = Self.newWindowMarker
                existing.isEnabled = true
                return
            }

            let item = NSMenuItem(
                title: "New Window",
                action: #selector(markdownerNewWindow(_:)),
                keyEquivalent: "n"
            )
            item.keyEquivalentModifierMask = [.command, .shift]
            item.target = self
            item.representedObject = Self.newWindowMarker
            item.isEnabled = true

            // Place after "New" if present, otherwise near the top of File.
            var insertAt = 0
            for (index, mi) in submenu.items.enumerated() {
                if mi.title == "New" {
                    insertAt = index + 1
                    break
                }
            }
            if insertAt < submenu.numberOfItems, submenu.items[insertAt].isSeparatorItem {
                insertAt += 1
            }
            submenu.insertItem(item, at: min(insertAt, submenu.numberOfItems))
            return
        }
    }

}

extension Notification.Name {
    static let markdownerFormat = Notification.Name("markdowner.format")
    static let markdownerShowFind = Notification.Name("markdowner.showFind")
    static let markdownerFindCommand = Notification.Name("markdowner.findCommand")
    static let markdownerFindResult = Notification.Name("markdowner.findResult")
    static let markdownerExport = Notification.Name("markdowner.export")
    static let markdownerInsertImage = Notification.Name("markdowner.insertImage")
    static let markdownerOpenFolder = Notification.Name("markdowner.openFolder")
    static let markdownerOpenPackage = Notification.Name("markdowner.openPackage")
    static let markdownerExtractPackage = Notification.Name("markdowner.extractPackage")
    static let markdownerToggleSidebar = Notification.Name("markdowner.toggleSidebar")
    static let markdownerNewDocument = Notification.Name("markdowner.newDocument")
    static let markdownerOpenDocument = Notification.Name("markdowner.openDocument")
    static let markdownerSaveDocument = Notification.Name("markdowner.saveDocument")
    static let markdownerSaveDocumentAs = Notification.Name("markdowner.saveDocumentAs")
    static let markdownerOpenFileURL = Notification.Name("markdowner.openFileURL")
    static let markdownerOpenFileURLInNewWindow = Notification.Name("markdowner.openFileURLInNewWindow")
    static let markdownerDuplicateDocumentWindow = Notification.Name("markdowner.duplicateDocumentWindow")
    /// Request a new `WindowGroup(id: "workspace")` from AppDelegate / URL / non-key context.
    static let markdownerOpenNewWindow = Notification.Name("markdowner.openNewWindow")
    /// Posted when the user grants folder access (Open Folder…) so Write can reload images.
    static let markdownerFolderAccessGranted = Notification.Name("markdowner.folderAccessGranted")
    static let markdownerNavigateDirectory = Notification.Name("markdowner.navigateDirectory")
    static let markdownerNavigateAnchor = Notification.Name("markdowner.navigateAnchor")
    static let markdownerFindInEditor = Notification.Name("markdowner.findInEditor")
    static let markdownerScrollFraction = Notification.Name("markdowner.scrollFraction")
}
