# Markdowner

A native **macOS 26+ WYSIWYG Markdown word processor**. Write formatted text like a normal document; files stay clean, portable Markdown (`.md`). Browse whole folders of notes from a Finder-style sidebar.

## Features

- **File sidebar** — simplified Finder browser for folders of `.md` files (↑ parent, click folders, filter, live refresh)
- **True WYSIWYG editing** — headings, bold, italic, lists, quotes, code, links, tables, task lists (native `NSTextView`)
- **Images** — drag & drop, paste from clipboard, or insert via toolbar / **⇧⌘I**; embedded as data URLs so the file stays self-contained
- **Write / Source / Split** — word processor, raw Markdown, or both with optional synced scrolling
- **Links** — `.md` opens in-app (or new window via context menu); directories open in the sidebar; `http(s)` / HTML open in the browser; relative multi-segment paths resolve correctly
- **Find & Replace** — **⌘F** / **⌥⌘F** with next/previous, case sensitivity, and replace all
- **Export** — **File → Export as HTML…** or **Export as PDF…**
- **Multi-window** — independent workspaces; document back/forward history when following Markdown links
- **Blank launch** — workspace + sidebar ready (no open dialog); pick files from the nav
- **macOS 26 design** — `NavigationSplitView`, Liquid Glass controls, `@Observable` browser model, security-scoped folder bookmarks

## Requirements

- **macOS 26** or later
- Xcode 26+ (to build)

## Build & run

```bash
open Markdowner.xcodeproj
```

Then press **⌘R** in Xcode, or:

```bash
xcodebuild -scheme Markdowner -configuration Debug -derivedDataPath build CODE_SIGN_IDENTITY="-" build
open build/Build/Products/Debug/Markdowner.app
```

## Package a DMG

```bash
./scripts/package-dmg.sh
```

Produces:

- `dist/Markdowner-1.0.dmg` (versioned)
- `dist/Markdowner.dmg` (convenience copy)
- Release app at `build/Build/Products/Release/Markdowner.app`

The DMG is **ad-hoc signed** (fine for personal use). For public download, use a Developer ID certificate and Apple notarization (`notarytool`). First open on another Mac may need **right-click → Open**.

## Folder sidebar

Built for the “folder of AI Markdown dumps” workflow:

1. **⌥⌘O** or the folder button — grant access to a directory
2. Click a **`.md`** file to open it
3. Click a **folder** (or → / Return) to go deeper; **⌘↑** or the up chevron to go up
4. Use the breadcrumb to jump to any level of the path
5. Sidebar remembers the last folder via a security-scoped bookmark
6. Directory links inside documents navigate the sidebar only (not document history)

| Sidebar action        | Shortcut / gesture     |
|-----------------------|------------------------|
| Toggle sidebar        | ⌥⌘S                    |
| Open folder           | ⌥⌘O                    |
| Enclosing folder      | ⌘↑ / ←                 |
| Open selection        | Return / → on folders  |

## Shortcuts

| Action              | Shortcut     |
|---------------------|--------------|
| Bold                | ⌘B           |
| Italic              | ⌘I           |
| Link                | ⌘K           |
| Insert image        | ⇧⌘I          |
| Inline code         | ⇧⌘E          |
| Heading 1–3         | ⌥⌘1 / 2 / 3  |
| Source mode         | ⌘\\          |
| Split mode          | ⌥⌘\\         |
| Find                | ⌘F           |
| Find & Replace      | ⌥⌘F          |
| Find next / previous| ⌘G / ⇧⌘G     |

## View modes

| Mode   | Description |
|--------|-------------|
| **Write**  | WYSIWYG word-processor editing (`NSTextView`) |
| **Source** | Raw Markdown (monospace) |
| **Split**  | Source + live preview (optional scroll sync) |

## How it works

Markdowner is a SwiftUI **WindowGroup** workspace app (not `DocumentGroup`):

1. **Write mode** — `MarkdownRichText` converts Markdown ↔ `NSAttributedString` for a native rich-text editor
2. **Preview / Split** — `MarkdownDocumentView` + `MarkdownInline` render structured blocks and links
3. **Links** — relative paths use a lossless internal scheme and resolve against the document folder (with name search fallback)
4. **PDF export** — HTML is rendered in a temporary `WKWebView` via `createPDF`

## Project layout

```
Markdowner/
  MarkdownerApp.swift          # App entry, menus, shortcuts
  EditorContainerView.swift    # NavigationSplitView shell + toolbar
  NativeEditorView.swift       # Write / Source / Split editors
  MarkdownRichText.swift       # Markdown ↔ NSAttributedString
  MarkdownDocumentView.swift   # Read-only structured preview
  MarkdownInline.swift         # Inline styling + links
  LinkHandling.swift           # Open .md / dirs / web links
  WorkspaceModel.swift         # Open / save / document history
  FileSidebarView.swift        # Finder-style folder browser UI
  FolderBrowser.swift          # @Observable directory model + bookmarks
  ExportService.swift          # HTML + PDF export
  FindReplaceBar.swift         # Find / replace UI
  Assets.xcassets/             # App icon + accent color
scripts/
  package-dmg.sh               # Release build + DMG
```

## License

MIT — use it, fork it, ship it.
