import SwiftUI

/// Simplified Finder-style column: navigate folders, open Markdown files.
struct FileSidebarView: View {
    @Bindable var browser: FolderBrowserModel
    var activeDocumentURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            footer
        }
        .background(Color.clear)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Back / location row
            HStack(spacing: 8) {
                Button {
                    browser.goUp()
                } label: {
                    Label {
                        Text(browser.parentFolderName.map { "\($0)" } ?? "Up")
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "chevron.backward")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!browser.canGoUp)
                .help(browser.canGoUp
                      ? "Go to parent folder “\(browser.parentFolderName ?? "")” (⌘↑)"
                      : "No parent folder available")
                .keyboardShortcut(.upArrow, modifiers: [.command])

                Spacer(minLength: 4)

                Button {
                    browser.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
                .disabled(browser.currentDirectory == nil)

                Button {
                    browser.pickFolder()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("Open Folder… (⌥⌘O)")
                .keyboardShortcut("o", modifiers: [.command, .option])

                Button {
                    browser.pickPackage()
                } label: {
                    Image(systemName: "doc.zipper")
                }
                .buttonStyle(.borderless)
                .help("Open Package… (.zip)")
            }

            // Package identity (always includes .zip so it’s obvious this isn’t a normal folder)
            if browser.isPackageMode, let pkg = browser.activePackage {
                HStack(spacing: 6) {
                    Image(systemName: "doc.zipper")
                        .foregroundStyle(Color.accentColor)
                    Text(pkg.sidebarRootLabel)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .help(pkg.packageURL.path)
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Read-only")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            // Clickable breadcrumb trail
            if !browser.breadcrumbSegments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(Array(browser.breadcrumbSegments.enumerated()), id: \.offset) { index, segment in
                            if index > 0 {
                                Image(systemName: "chevron.forward")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Button {
                                browser.navigateToBreadcrumbIndex(index)
                            } label: {
                                HStack(spacing: 3) {
                                    if index == 0, browser.isPackageMode {
                                        Image(systemName: "doc.zipper")
                                            .font(.caption2)
                                    }
                                    Text(segment)
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.caption.weight(index == browser.breadcrumbSegments.count - 1 ? .semibold : .regular))
                            .foregroundStyle(index == browser.breadcrumbSegments.count - 1 ? .primary : Color.accentColor)
                            .lineLimit(1)
                            .help(index < browser.breadcrumbSegments.count - 1 ? "Go to \(segment)" : segment)
                        }
                    }
                }
                .help(browser.isPackageMode
                      ? (browser.activePackage.map { "\($0.sidebarRootLabel) — \($0.packageURL.path)" } ?? "")
                      : (browser.currentDirectory?.path ?? ""))
            }

            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("Filter by name", text: $browser.filterText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .onChange(of: browser.filterText) { _, _ in
                        browser.refresh()
                    }
                if !browser.filterText.isEmpty {
                    Button {
                        browser.filterText = ""
                        browser.refresh()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        if browser.currentDirectory == nil {
            emptyState
        } else if let error = browser.errorMessage {
            VStack(spacing: 12) {
                ContentUnavailableView {
                    Label("Can’t read folder", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    if browser.canGoUp {
                        Button("Go Up") { browser.goUp() }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Open Folder…") { browser.pickFolder() }
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if browser.entries.isEmpty && !browser.canGoUp {
            ContentUnavailableView {
                Label(
                    browser.filterText.isEmpty ? "No Markdown files" : "No matches",
                    systemImage: "doc.text.magnifyingglass"
                )
            } description: {
                Text(browser.filterText.isEmpty
                     ? "This folder has no .md files. Toggle “Markdown only” off to see everything."
                     : "Try a different filter.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $browser.selectedURL) {
                // Explicit parent-folder row (Finder-style)
                if browser.canGoUp {
                    Button {
                        browser.goUp()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("..")
                                    .font(.body.weight(.medium))
                                if let name = browser.parentFolderName {
                                    Text("Up to \(name)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.backward")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                }

                ForEach(browser.entries) { entry in
                    FileSidebarRow(
                        entry: entry,
                        isActiveDocument: activeDocumentURL.map {
                            $0.standardizedFileURL == entry.url
                        } ?? false
                    )
                    .tag(entry.url as URL?)
                    .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        browser.openEntry(entry)
                    }
                    .onTapGesture(count: 1) {
                        browser.selectedURL = entry.url
                        switch entry.kind {
                        case .markdown, .directory, .package:
                            browser.openEntry(entry)
                        case .other:
                            break
                        }
                    }
                    .contextMenu {
                        switch entry.kind {
                        case .directory:
                            Button("Open Folder") { browser.openEntry(entry) }
                        case .markdown:
                            Button("Open") { browser.openEntry(entry) }
                        case .package:
                            Button("Open Package") { browser.openEntry(entry) }
                        case .other:
                            Button("Open with Default App") { browser.openEntry(entry) }
                        }
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                        }
                        if entry.kind == .directory {
                            Button("Set as Sidebar Root") {
                                browser.openFolder(entry.url, securityScoped: false)
                            }
                        }
                        Divider()
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.url.path, forType: .string)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onKeyPress(.return) {
                openSelection()
            }
            .onKeyPress(.rightArrow) {
                if let entry = selectedEntry, entry.kind == .directory || entry.kind == .package {
                    browser.openEntry(entry)
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.leftArrow) {
                if browser.canGoUp {
                    browser.goUp()
                    return .handled
                }
                return .ignored
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Browse a folder", systemImage: "folder.badge.questionmark")
        } description: {
            Text("Open a folder of notes, or a .zip package, then click Markdown files to open them.")
        } actions: {
            Button("Open Folder…") {
                browser.pickFolder()
            }
            .buttonStyle(.borderedProminent)
            Button("Open Package…") {
                browser.pickPackage()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Toggle(isOn: $browser.showOnlyMarkdown) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(browser.showOnlyMarkdown ? "Folders + Markdown + Zips" : "All files")
                            .font(.caption)
                        Text(browser.showOnlyMarkdown
                             ? "Hide images/txt; still shows .zip packages"
                             : "Show every file in this folder")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
                .help(browser.showOnlyMarkdown
                      ? "On: folders, .md, and .zip packages. Turn off for images and other files."
                      : "Off: list all files. Turn on to focus on Markdown and packages.")
                .onChange(of: browser.showOnlyMarkdown) { _, _ in
                    browser.refresh()
                }

                Spacer(minLength: 8)

                Text(countLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
            }

            if browser.showOnlyMarkdown, browser.hiddenNonMarkdownCount > 0 {
                Button {
                    browser.showOnlyMarkdown = false
                    browser.refresh()
                } label: {
                    Text("\(browser.hiddenNonMarkdownCount) other file\(browser.hiddenNonMarkdownCount == 1 ? "" : "s") hidden — show all")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var countLabel: String {
        let folders = browser.entries.filter { $0.kind == .directory }.count
        let packages = browser.entries.filter { $0.kind == .package }.count
        let md = browser.entries.filter { $0.kind == .markdown }.count
        let other = browser.entries.filter { $0.kind == .other }.count
        var parts: [String] = []
        if folders > 0 { parts.append("\(folders) folder\(folders == 1 ? "" : "s")") }
        if packages > 0 { parts.append("\(packages) zip") }
        if md > 0 { parts.append("\(md) md") }
        if other > 0 { parts.append("\(other) other") }
        return parts.isEmpty ? "0" : parts.joined(separator: " · ")
    }

    private var selectedEntry: FolderEntry? {
        guard let url = browser.selectedURL else { return nil }
        return browser.entries.first { $0.url == url }
    }

    @discardableResult
    private func openSelection() -> KeyPress.Result {
        if let entry = selectedEntry {
            browser.openEntry(entry)
            return .handled
        }
        return .ignored
    }
}

private struct FileSidebarRow: View {
    let entry: FolderEntry
    let isActiveDocument: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.systemImage)
                .foregroundStyle(entry.kind == .directory ? Color.accentColor : .secondary)
                .frame(width: 18)
                .symbolRenderingMode(.hierarchical)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .lineLimit(1)
                    .font(.body.weight(isActiveDocument ? .semibold : .regular))
                if entry.kind != .directory {
                    HStack(spacing: 4) {
                        switch entry.kind {
                        case .package:
                            Text("ZIP package")
                        case .other:
                            Text(entry.url.pathExtension.isEmpty ? "file" : entry.url.pathExtension.uppercased())
                        case .markdown:
                            EmptyView()
                        case .directory:
                            EmptyView()
                        }
                        if !entry.modifiedLabel.isEmpty {
                            if entry.kind == .package || entry.kind == .other { Text("·") }
                            Text(entry.modifiedLabel)
                        }
                        if !entry.sizeLabel.isEmpty {
                            Text("·")
                            Text(entry.sizeLabel)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)

            if entry.kind == .directory {
                Image(systemName: "chevron.forward")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.quaternary)
            } else if entry.kind == .package {
                Image(systemName: "arrow.up.right.square")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.quaternary)
            } else if isActiveDocument {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .padding(.vertical, 2)
        .accessibilityLabel(entry.name)
        .accessibilityValue({
            switch entry.kind {
            case .directory: return "Folder"
            case .package: return "Zip package"
            case .markdown: return isActiveDocument ? "Current document" : "Markdown"
            case .other: return "File"
            }
        }())
    }
}
