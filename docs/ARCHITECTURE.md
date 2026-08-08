# Architecture

How Markdowner is structured and how data moves through the app. For supported Markdown syntax, see [MARKDOWN.md](MARKDOWN.md). For packaging, see the root [README](../README.md).

## Goals

- Feel like a **word processor**, not a code editor, while keeping files as plain `.md`
- Browse a **folder of notes** without fighting macOS sandbox rules
- Open **read-only `.zip` packages** as a virtual folder tree (see [PACKAGES.md](PACKAGES.md))
- Support **multi-window** workspaces with independent open files and sidebar paths
- Prefer **native AppKit/SwiftUI** over web views for editing (reliable on current macOS)

## High-level layout

```
┌─────────────────────────────────────────────────────────────────┐
│  MarkdownerApp (WindowGroup "workspace")                        │
│  menus → NotificationCenter → key window handlers               │
└────────────────────────────┬────────────────────────────────────┘
                             │
              ┌──────────────▼──────────────┐
              │   EditorContainerView       │
              │   NavigationSplitView       │
              ├─────────────┬───────────────┤
              │ Sidebar     │ Detail        │
              │ FileSidebar │ toolbar       │
              │ FolderBrowser │ NativeEditor│
              │             │ WorkspaceModel│
              └─────────────┴───────────────┘
```

Each window owns:

| Piece | Role |
|-------|------|
| `WorkspaceModel` | Buffer text, dirty flag, file URL, document history, package read-only |
| `FolderBrowserModel` | Sidebar directory / package root, bookmarks, live listing |
| `ZipPackageService` | Expand zip → cache; package session lifecycle |
| `NativeEditorView` | Write / Source / Split UI bound to `workspace.text` |
| `LinkHandling` bases | Document folder + sidebar roots for resolving relative links |

Windows do **not** share the open document. Link-handling bases are process-global and updated when a window becomes key.

## Why WindowGroup (not DocumentGroup)

`DocumentGroup` assumes one file ↔ one window and fights a “blank workspace + open from sidebar” flow. Markdowner uses:

- `WindowGroup(id: "workspace")` → blank launch, any number of windows
- Manual open/save via `NSOpenPanel` / `NSSavePanel` and security-scoped URLs
- `AppDelegate.applicationShouldOpenUntitledFile` → `false` so no NSDocument open sheet on launch
- Finder double-click → `application(_:open:)` posts `.markdownerOpenFileURL`

## Data flow

### Open a file

```
Sidebar click / File → Open / Finder / link
        │
        ▼
WorkspaceModel.openFile(at:)
  • optional dirty confirm
  • startAccessingSecurityScopedResource
  • read UTF-8 (fallback ISO Latin-1)
  • push document history (unless recordHistory: false)
  • text / fileURL / isDirty = false
        │
        ▼
NativeEditorView(text: $workspace.text)
  Write:  MarkdownRichText.attributedString → NSTextView
  Source: plain String in NSTextView
  Split:  both + live preview from same text
```

### Edit and save

```
Write mode: NSTextView edits
  → MarkdownRichText.markdown(from:)
  → workspace.text (isDirty = true)

Source mode: plain string edits
  → workspace.text

⌘S → WorkspaceModel.save()
  → write UTF-8 to fileURL (or Save As panel)
```

There is **no autosave**. Dirty state is reflected in the window title (`— Edited`).

### Mode switching

| Mode | Editor surface | Preview |
|------|----------------|---------|
| **Write** | Editable `NSTextView` + rich attributes | (none) |
| **Source** | Monospace `NSTextView` of raw Markdown | (none) |
| **Split** | Source left + block preview right | `MarkdownDocumentView` in `NSScrollView` |

Optional **scroll sync** in Split (`@AppStorage("markdowner.splitScrollSync.v2")`, default **off**) aligns panes by **Markdown character offset + line fingerprints** (`SplitScrollSync`), not equal pixel heights.

## Zip packages

```
User picks .zip
    → ZipPackageService.open
    → unzip -d ~/Library/Caches/MarkdownerPackages/<uuid>/
    → FolderBrowserModel.activePackage = session
    → sidebar root = extractRoot (clamped navigation)
    → WorkspaceModel.packageSession → isReadOnly
    → banner + non-editable editors + save blocked
Extract…
    → copy extractRoot → user folder
    → optional openFolder (writable)
```

- List kind `.package` for `.zip` in normal folder browsing (always visible with the MD filter).
- Links/images use normal `file://` paths under the extract tree.
- Details and product rules: [PACKAGES.md](PACKAGES.md).

## Two Markdown pipelines

Important: Write and Preview do **not** share one live AST.

### 1. Write pipeline (edit + round-trip)

```
.md string
  → MarkdownBlockParser.parse
  → MarkdownRichText.attributedBlock / inlineAttributed
  → NSAttributedString in NSTextView
  → (user edits)
  → MarkdownRichText.markdown(from:)
  → .md string
```

- Block structure comes from `MarkdownBlockParser` (same parser as preview).
- Inline runs use `MarkdownInline` bridged into AppKit attributes.
- **Tables** store the original Markdown on the attributed range (`preservedMarkdownKey`) so save does not invent a new table serialization from the visual layout.
- Lists keep source numbers and support multi-line / “loose” item bodies.

### 2. Preview / export pipeline (read-only)

```
.md string
  → MarkdownBlockParser.parse
  → MarkdownDocumentView (SwiftUI blocks)
       + MarkdownInline for inline runs
```

Export uses a **third** path:

```
.md → ExportService.SimpleMarkdownHTML → HTML string
  HTML save as-is
  PDF: temporary WKWebView.createPDF
```

So visual Write, SwiftUI preview, and HTML/PDF can differ slightly at the edges. Prefer Source mode when exact characters matter.

## Link handling

All local navigation goes through `LinkHandling`.

### Storage

Relative Markdown hrefs are **not** stored as bare `URL(string: "pilot/foo")` (Foundation can mangle multi-segment relatives). They become:

```text
markdowner-rel://doc?p=pilot/y1-process-wedge/
```

Web URLs (`http` / `https` / `mailto:`) stay normal. Absolute filesystem paths stay `file:` URLs.

On save, `markdownHref(for:)` writes the original relative path back into the Markdown source.

### Resolution (on click)

1. Decode `markdowner-rel` query `p`, or take scheme-less / file relative pieces.
2. Join onto `documentDirectory` **component-by-component** (`..` supported).
3. If the candidate path does not exist, **search by last path component** under:
   - document directory
   - its parent
   - `searchRoots` (sidebar root + current directory)
4. Prefer a unique / shallowest match; directories when the href ends with `/`.

### Dispatch

| Target | Action | Document history |
|--------|--------|------------------|
| `http` / `https` / `mailto:` | Default browser / mail | No |
| Local `.html` / `.htm` | Browser | No |
| Local directory | `.markdownerNavigateDirectory` → sidebar only | **No** |
| Local `.md` / `.markdown` / … | Open in this window (or new window via menu) | **Yes** (same window) |
| Other existing file | `NSWorkspace.open` | No |

Right-click on a link: Open / Open in New Window / Show in Sidebar / Browser / Copy.

Document back/forward (**⌘[** / **⌘]**) only tracks **Markdown file** navigations, not sidebar folder changes.

## Sidebar and sandbox

App is sandboxed (`Markdowner.entitlements`):

- `com.apple.security.app-sandbox`
- `files.user-selected.read-write`
- `files.bookmarks.app-scope`
- Network client **off** (no remote fetches)

`FolderBrowserModel`:

1. User picks a folder (or restores last bookmark from `UserDefaults`).
2. Starts security-scoped access; keeps grant roots.
3. Lists only what it can access; live refresh via directory monitoring.
4. **Up** always uses the real filesystem parent (`deletingLastPathComponent`), not a virtual stack.
5. Navigating to a directory link expands access when under a known grant root.

Opening a document also scopes that file URL for read/write until replaced.

## Multi-window

- **⌘⇧N** / New Window → another `WindowGroup` instance.
- Each has its own `WorkspaceModel` + `FolderBrowserModel`.
- Menu commands broadcast via `NotificationCenter`; only the **key** window applies them (`controlActiveState == .key`).
- Open in New Window: `PendingWindowOpen.fileURL` + open window, consumed on appear.

## Notifications (command bus)

Menus and toolbars avoid hard wiring by posting names defined on `Notification.Name` in `MarkdownerApp.swift`, including:

| Name | Purpose |
|------|---------|
| `.markdownerFormat` | Bold, headings, mode switches, lists, … |
| `.markdownerShowFind` / `.markdownerFindCommand` | Find UI |
| `.markdownerOpenFileURL` | Open `.md` in key workspace |
| `.markdownerOpenFileURLInNewWindow` | Open `.md` in a new window |
| `.markdownerNavigateDirectory` | Sidebar-only folder change |
| `.markdownerSaveDocument` / `…As` / `New` / `Open` | File ops |
| `.markdownerScrollFraction` | Split scroll sync |

## Module map

| File | Responsibility |
|------|----------------|
| `MarkdownerApp.swift` | App entry, menus, notifications, app delegate |
| `EditorContainerView.swift` | Split shell, toolbar, wire models + link bases |
| `WorkspaceModel.swift` | Text buffer, open/save, document history |
| `FolderBrowser.swift` | Directory / package root, bookmarks, monitoring |
| `ZipPackageService.swift` | Zip expand, extract-to-folder, session |
| `BuildInfo.swift` | Generated per compile (timestamp) |
| `FileSidebarView.swift` | Sidebar UI |
| `NativeEditorView.swift` | Write / Source / Split, find in text views |
| `MarkdownRichText.swift` | Markdown ↔ `NSAttributedString` for Write |
| `MarkdownDocumentView.swift` | Block parser + SwiftUI preview |
| `MarkdownInline.swift` | Inline emphasis, code, links |
| `LinkHandling.swift` | Resolve and open links |
| `ExportService.swift` | HTML + PDF |
| `FindReplaceBar.swift` | Find / replace chrome |

## Known edges / non-goals

- Not a full CommonMark/GFM implementation; see [MARKDOWN.md](MARKDOWN.md).
- Table **cells** are not freely WYSIWYG-edited; source is preserved for round-trip.
- No collaboration, iCloud package format, or plugin host.
- PDF depends on a short-lived `WKWebView` (export only; not the editor).
- Ad-hoc signed DMGs are not notarized; Gatekeeper may warn on other machines.

## Extension points

Useful places to change behavior:

1. **More Markdown constructs** — `MarkdownBlockParser` + both `MarkdownRichText` and `MarkdownDocumentView` (and optionally `SimpleMarkdownHTML`).
2. **Link types** — `LinkHandling.handle` / `resolveLocalURL`.
3. **New export formats** — `ExportService`.
4. **Sidebar filters / VCS status** — `FolderBrowserModel.refresh` / `FileSidebarView`.
