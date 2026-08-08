# Markdowner

A native **macOS 26+ WYSIWYG Markdown word processor**. Write formatted text like a normal document; files stay clean, portable Markdown (`.md`). Browse whole folders of notes from a Finder-style sidebar.

![Markdowner — folder sidebar and Write mode](docs/images/screenshot.jpg)

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
- **Read-only packages** — open a `.zip` of Markdown (and assets) as a browseable tree; banner + no save; **Extract…** to a folder when you need to edit
- **macOS 26 design** — `NavigationSplitView`, Liquid Glass controls, `@Observable` browser model, security-scoped folder bookmarks

## Documentation

| Doc | Contents |
|-----|----------|
| **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** | Data flow, dual Markdown pipelines, links, sandbox, modules |
| **[docs/MARKDOWN.md](docs/MARKDOWN.md)** | Supported syntax, round-trip behavior, limitations |
| This README | Features, build, DMG, shortcuts, quick “how it works” |

### Which build am I running?

Every compile embeds a **build date/time**. In the app:

- **Markdowner → Build Info…** (app menu), or  
- **Help → Build Info…**

Shows version, Debug/Release, full timestamp, compact stamp (e.g. `20260806.230654`), and the bundle path. Use **Copy** to paste it. Console also logs one line at launch (`Markdowner 1.0 (1) · Debug · built …`).

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

## How it works (quick)

Markdowner is a SwiftUI **WindowGroup** workspace (not `DocumentGroup`): each window has its own open buffer and sidebar folder.

```
Open .md  →  WorkspaceModel.text
                 │
     ┌───────────┼───────────┐
     ▼           ▼           ▼
  Write       Source       Split
  rich        raw MD       source + preview
  NSTextView               │
     │                     ▼
     │              MarkdownDocumentView
     ▼
  save UTF-8 .md
```

- **Write** — `MarkdownRichText` converts Markdown ↔ `NSAttributedString` for a native rich-text editor. Tables keep original Markdown for faithful save.
- **Source / Split** — edit or view the same string; preview uses `MarkdownBlockParser` + SwiftUI (a separate path from Write’s live typing).
- **Links** — relative hrefs use an internal lossless scheme; directories move the **sidebar only**; `.md` files use **document** back/forward (**⌘[** / **⌘]**).
- **Sandbox** — folder access via user grant + security-scoped bookmarks; last sidebar folder is restored on launch.
- **PDF export** — HTML in a temporary `WKWebView` via `createPDF` (export only; editing is native).

Details: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Syntax matrix: [docs/MARKDOWN.md](docs/MARKDOWN.md).

## Folder sidebar

Built for the “folder of AI Markdown dumps” workflow:

1. **⌥⌘O** or the folder button — grant access to a directory  
   **Open Package…** (toolbar zip icon / **⇧⌥⌘O**) — open a **`.zip`** of Markdown as a read-only tree
2. Click a **`.md`** file to open it
3. Click a **folder** (or → / Return) to go deeper; **⌘↑** or the up chevron to go up
4. Use the breadcrumb to jump to any level of the path
5. Sidebar remembers the last **folder** via a security-scoped bookmark (packages are session-only)
6. Directory links inside documents navigate the sidebar only (not document history)

### Zip packages (read-only)

- Expanding a package uses a private cache so relative **links and images** resolve like a normal folder.
- A **banner** shows “Read-only package”; Save / editing are disabled.
- **Extract…** (banner or **File → Extract Package…**) copies the tree to a real folder so you can open it and edit with full save support.

| Sidebar action        | Shortcut / gesture     |
|-----------------------|------------------------|
| Toggle sidebar        | ⌥⌘S                    |
| Open folder           | ⌥⌘O                    |
| Enclosing folder      | ⌘↑ / ←                 |
| Open selection        | Return / → on folders  |

## Shortcuts

| Action              | Shortcut     |
|---------------------|--------------|
| New document        | ⌘N           |
| New window          | ⌘⇧N          |
| Open file           | ⌘O           |
| Open folder         | ⌥⌘O          |
| Save / Save As      | ⌘S / ⌘⇧S     |
| Document back       | ⌘[           |
| Document forward    | ⌘]           |
| Bold / Italic       | ⌘B / ⌘I      |
| Strikethrough       | ⌘⇧X          |
| Link                | ⌘K           |
| Insert image        | ⇧⌘I          |
| Inline code         | ⌘⇧E          |
| Heading 1–3         | ⌥⌘1 / 2 / 3  |
| Bullet / numbered   | ⌘⇧8 / ⌘⇧7    |
| Quote               | ⌘⇧'          |
| Source mode         | ⌘\\          |
| Split mode          | ⌥⌘\\         |
| Find                | ⌘F           |
| Find & Replace      | ⌥⌘F          |
| Find next / previous| ⌘G / ⇧⌘G     |
| Toggle sidebar      | ⌥⌘S          |

Split **scroll sync** is a toggle in the Split chrome (stored as `markdowner.splitScrollSync`, default on).

## View modes

| Mode   | Description |
|--------|-------------|
| **Write**  | WYSIWYG word-processor editing (`NSTextView`) |
| **Source** | Raw Markdown (monospace) — best for tables and exact hrefs |
| **Split**  | Source + live preview (optional scroll sync) |

## Project layout

```
Markdowner/
  MarkdownerApp.swift          # App entry, menus, shortcuts, notifications
  EditorContainerView.swift    # NavigationSplitView shell + toolbar
  NativeEditorView.swift       # Write / Source / Split editors
  MarkdownRichText.swift       # Markdown ↔ NSAttributedString (Write)
  MarkdownDocumentView.swift   # Block parser + read-only preview
  MarkdownInline.swift         # Inline styling + links
  LinkHandling.swift           # Open .md / dirs / web links
  WorkspaceModel.swift         # Open / save / document history
  FileSidebarView.swift        # Finder-style folder browser UI
  FolderBrowser.swift          # @Observable directory model + bookmarks
  ExportService.swift          # HTML + PDF export
  FindReplaceBar.swift         # Find / replace UI
  Assets.xcassets/             # App icon + accent color
docs/
  ARCHITECTURE.md              # System design and data flow
  MARKDOWN.md                  # Supported Markdown + limitations
scripts/
  package-dmg.sh               # Release build + DMG
```

## License

MIT — see [LICENSE](LICENSE).
