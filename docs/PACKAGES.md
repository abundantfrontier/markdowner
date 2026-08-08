# Zip packages (read-only)

Markdowner can open a **`.zip`** of Markdown (and assets) as a **browseable tree** without the user unzipping first. Packages are **read-only** in v1.1: extract to a folder when you need to edit and save.

## Why

People email curriculum / note dumps as zips. Opening the package shows the hierarchy in the sidebar, resolves relative links and assets, and avoids “where do I extract this?”

## How to open

| Method | How |
|--------|-----|
| Menu | **File → Open Package…** |
| Shortcut | **⇧⌥⌘O** |
| Toolbar | Zip icon (`doc.zipper`) |
| Sidebar | Zip icon next to Open Folder |
| Browse | Navigate to a folder that contains a `.zip` and **click the zip row** |

`.zip` files stay visible even when the type filter is **Folders + Markdown + Zips** (images/txt still hidden until you show all files).

## What happens

1. The archive is expanded under a private cache  
   (`~/Library/Caches/MarkdownerPackages/<uuid>/`).
2. The sidebar root is that extract tree; the **breadcrumb / package chip** shows the full archive name including **`.zip`**.
3. Opening `.md` files uses the same editor as disk files.
4. Relative links and file paths resolve against the extract tree (same as a normal folder).
5. **Workspace is read-only**: editors not editable; Save / Save As blocked; format tools disabled.
6. An orange **banner** explains read-only mode and offers **Extract…**.

Closing the package (open another folder/package) removes the cache for that session.

## Extract (edit later)

**Extract…** on the banner, or **File → Extract Package…**:

1. Choose a destination folder.
2. Markdowner copies the expanded tree as `DisplayName/` (no `.zip` suffix on the folder).
3. Optionally open that folder for full edit + save.

Do **not** rely on Save As for a single file from a package if the doc needs sibling images or linked notes—extract the package instead.

## Sample package

| Path | Description |
|------|-------------|
| [samples/sample-curriculum-package.zip](samples/sample-curriculum-package.zip) | Nested `docs/`, pilots, shared notes, anchors, cross-links, sample image |
| [samples/sample-curriculum-package/](samples/sample-curriculum-package/) | Unpacked source of the same tree (for inspection / regeneration) |

Suggested checks:

- [ ] Open zip → package chip shows `….zip` + lock  
- [ ] Open `README.md` and follow links into `docs/`  
- [ ] Same-document `#anchors`  
- [ ] Directory links move sidebar only  
- [ ] Save disabled; Extract creates an editable folder  

## Limitations (v1.1)

| Not supported yet | Notes |
|-------------------|--------|
| Write-back into the zip | Extract → edit on disk |
| Auto-restore last package on launch | Only folder bookmarks restore |
| Encrypted / multi-volume zips | Use plain `.zip` |
| Guaranteed image display for all relative paths | Assets resolve on disk after extract; data-URL embeds always work |

## Implementation sketch

- `ZipPackageService` — `unzip` into cache; `PackageSession` metadata  
- `FolderBrowserModel.activePackage` — clamps navigation to extract root; package-aware breadcrumbs  
- `WorkspaceModel.isReadOnly` / `packageSession` — blocks save & edits  
- UI — banner, disabled controls, package chip in sidebar  

Future writable packages can reuse the same session model with atomic archive replace.
