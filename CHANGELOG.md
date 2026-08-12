# Changelog

## 1.1.2 (2026-08-11)

### Added
- **Images in Write & Preview** — `![alt](path)` and data URLs render as real pictures (not plain link text)
- **Image insert** — **⇧⌘I**, drag-in from Finder, paste/screenshot; prefer **`assets/`** next to a saved document (embed only when unsaved)
- **Image drag-out** to Finder / other apps; **right-click** Save / Copy / Copy Markdown / Reveal in Finder
- **Drop caret** — blue insertion bar shows where a dragged image will land
- **Reorder images** in Write by dragging attachments within the document
- Clickable **task list** checkboxes in Write
- Nested list indent display; light **syntax coloring** in fenced code blocks (Write)
- **Leave zip package** — Back at package root (and package **Close**) returns to the previous folder

### Fixed
- Sandbox: relative images need **Open Folder** access; no more permission alert when clicking missing images
- Package path comparisons (`/var` vs `/private/var`) so Back works inside zip trees
- Tiny 1×1 assets upscaled so they stay visible; sample `dot.png` fixtures are striped for testing

### Samples / docs
- `docs/samples/phase12-test/` test document
- Updated `docs/samples/sample-curriculum-package.zip` assets
- `docs/MARKDOWN.md` image behavior

## 1.1.1 (2026-08-09)

### Fixed
- **ClingBar / multi-Space “new window here”** — single window per request (no doubles)
- Dock reopen and `markdowner://new-window` no longer race to open two workspaces
- Disabled aggressive window restoration that reopened stacks of old windows
- AppKit **File → New Window** (AX-friendly) without force-activating (avoids Space jumps)
- **ClingBar window cycle on the current Space** — `markdowner://focus` / `markdowner://next-window` order only on-screen workspaces (SwiftUI AX raise was stuck on one window)

### Integration
- URL scheme: `markdowner://new-window` (for ClingBar and scripts)
- URL scheme: `markdowner://focus` / `markdowner://next-window` — focus or cycle workspaces on the **current Space only**
- Debounced / tokenized `WorkspaceWindowBridge` as the sole open-window path

## 1.1.0 (2026-08-08)

### Added

- **Read-only zip packages** — open a `.zip` of Markdown (and assets) as a sidebar tree without unzipping first  
  - **File → Open Package…** / **⇧⌥⌘O** / toolbar & sidebar zip controls  
  - Click a `.zip` in the folder list to open as a package  
  - Package chip + breadcrumb show the full archive name (including `.zip`)  
  - Orange **Read-only** banner; editing and Save disabled  
  - **Extract…** copies the tree to a real folder for full editing  
- **Build Info…** menu (app menu + Help) with version, configuration, and compile timestamp  
- Sample package: `docs/samples/sample-curriculum-package.zip`  
- Docs: `docs/PACKAGES.md`, architecture updates  

### Improved

- Split **Sync scroll** — off by default; content/fingerprint-based alignment when enabled  
- Sidebar type filter — “Folders + Markdown + Zips”; hidden-file count; clearer labels  
- Same-document `#anchor` navigation (Write + Source + Split)  
- Relative multi-segment links; document dirty only on real text changes  
- Open current document in a new window (**⌘⇧D**)  

### Fixed

- Link path resolution (lossless relative links / package extract tree)  
- Various Write-mode link and dirty-flag edge cases  

## 1.0.0

Initial Markdowner release: Write / Source / Split, folder sidebar, export, multi-window, native rich text.
