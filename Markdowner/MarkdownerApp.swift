import AppKit
import SwiftUI

@main
struct MarkdownerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // WindowGroup allows any number of independent workspaces.
        WindowGroup(id: "workspace") {
            EditorContainerView()
        }
        .defaultSize(width: 1100, height: 720)
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

/// Menu items that open another workspace window (multi-window).
private struct NewWindowCommandButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Window") {
            openWindow(id: "workspace")
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])

        Button("Open Current Document in New Window") {
            NotificationCenter.default.post(name: .markdownerDuplicateDocumentWindow, object: nil)
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])
    }
}

// MARK: - App delegate (Finder open + no untitled document panel)

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure we never present the legacy NSDocument open panel on launch.
        NSDocumentController.shared.closeAllDocuments(withDelegate: nil, didCloseAllSelector: nil, contextInfo: nil)
        // Log identity so Console/debug sessions can confirm which binary is running.
        NSLog("%@", BuildInfo.summary)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        // We use a WindowGroup workspace, not DocumentGroup.
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let window = NSApp.windows.first(where: { $0.isVisible == false || true }) {
                // Open workspace window via SwiftUI environment if needed
            }
            // Returning true lets the system recreate our Window scene when dock-clicked with no windows.
            return true
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        // Deliver to the active workspace after a beat so the window exists.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .markdownerOpenFileURL, object: url)
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
    static let markdownerNavigateDirectory = Notification.Name("markdowner.navigateDirectory")
    static let markdownerNavigateAnchor = Notification.Name("markdowner.navigateAnchor")
    static let markdownerFindInEditor = Notification.Name("markdowner.findInEditor")
    static let markdownerScrollFraction = Notification.Name("markdowner.scrollFraction")
}
