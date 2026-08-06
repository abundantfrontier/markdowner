# Markdown support

What Markdowner understands, how it round-trips in Write mode, and known limitations.

## Philosophy

- Files on disk are **plain UTF-8 Markdown** (`.md`, `.markdown`, `.mdown`, `.mkd`, `.mdx`).
- Write mode aims for **readable WYSIWYG**, not a pixel-perfect CommonMark clone.
- When fidelity matters (generated docs, careful tables), use **Source** mode.
- Three renderers exist (Write, Preview, HTML/PDF export). They share ideas but can differ at the edges—see [ARCHITECTURE.md](ARCHITECTURE.md).

## Block elements

| Construct | Syntax (examples) | Write | Preview | Export HTML/PDF |
|-----------|-------------------|-------|---------|-----------------|
| Headings | `#` … `######` | Yes (toolbar H1–H3 emphasize sizes) | Yes | Yes |
| Paragraphs | blank-line separated | Yes | Yes | Yes |
| Soft line breaks | single newline inside a block | Kept in source | Shown | Varies |
| Block quote | `> …` | Yes | Yes | Yes |
| Unordered list | `-` / `*` / `•` | Yes | Yes | Yes |
| Ordered list | `1. item` | **Preserves numbers** | Yes | Yes |
| Task list | `- [ ]` / `- [x]` | Yes | Yes | Basic |
| Fenced code | `` ```lang `` | Yes (mono) | Yes | Yes |
| Horizontal rule | `---` / `***` / visual rule | Yes | Yes | Yes |
| Tables (GFM) | `\| a \| b \|` | **Displayed**; source **preserved** on save | Yes | Yes |
| HTML blocks | raw `<div>` etc. | Mostly plain text | Mostly plain | Limited |
| Footnotes, TOC, math | — | No | No | No |

### Lists (important)

- Ordered lists keep the **number written in the file** (not forced 1…n renumbering on open).
- List items can have **continuation lines** / loose bodies (blank line then indented paragraphs) under the first line.
- Nested lists are only partially modeled; deep nesting may flatten or look wrong in Write.

### Tables

- Parsed as GFM-style pipe tables.
- In Write mode, the original Markdown for the table is stored on the attributed range (`preservedMarkdownKey`) so **editing the visual table does not rewrite pipe syntax**.
- Prefer Source mode to change table structure or cell Markdown.

## Inline elements

| Construct | Syntax | Notes |
|-----------|--------|--------|
| Bold | `**text**` or `__text__` | ⌘B in Write |
| Italic | `*text*` or `_text_` | ⌘I |
| Bold + italic | nested markers | Best-effort |
| Strikethrough | `~~text~~` | ⌘⇧X |
| Inline code | `` `code` `` | ⌘⇧E |
| Links | `[label](url)` | Label may contain code/bold; see Links |
| Images | `![alt](url)` | Data URLs preferred for embeds |
| Autolink | bare `https://…` | Recognized in inline parse |
| HTML inline | `<br>` etc. | Not specially handled |

Nested cases like `**[`path`](url)**` and ``[`code`](url)`` are handled explicitly in `MarkdownInline` so they do not fall through as raw text.

## Links

### Recommended relative forms

```markdown
[Sibling note](other-note.md)
[Nested file](pilot/lesson-01.md)
[Folder in sidebar](pilot/y1-process-wedge/)
[Up one level](../README.md)
[Web](https://example.com)
```

Put the **full relative path in the href**, not only the last segment:

```markdown
<!-- Good -->
[pilot/y1-process-wedge/](pilot/y1-process-wedge/)

<!-- Fragile: label shows path, href is only the leaf -->
[pilot/y1-process-wedge/](y1-process-wedge)
```

The app will **try** to find a unique folder/file named `y1-process-wedge` under the document folder if the short form fails, but correct hrefs are still better.

### What happens on click

| Href | Result |
|------|--------|
| `https://…` / `http://…` / `mailto:…` | System browser / mail |
| Relative / absolute path to a **directory** | Sidebar navigates there (no document history) |
| Path to `.md` | Opens in this window (history **⌘[** / **⌘]**); right-click → new window |
| Path to `.html` | Opens in browser |
| Other existing file | Opens with default app |

Right-click a link for Open, Open in New Window, Show in Sidebar, Copy, etc.

## Images

- Toolbar / **⇧⌘I**, drag-and-drop, or paste from clipboard.
- Embedded as **`data:image/…;base64,…`** in the Markdown so the file stays self-contained (no sidecar required).
- Large images grow the `.md` file; for huge media, prefer external files and normal relative paths if you accept the dependency.

Example:

```markdown
![Diagram](data:image/png;base64,iVBORw0KGgo...)
```

## View modes and fidelity

| Mode | Best for |
|------|----------|
| **Write** | Prose, headings, emphasis, simple lists, light editing |
| **Source** | Exact syntax, tables, generated Markdown, link hrefs |
| **Split** | Reading structure while tweaking source; optional scroll sync |

Switch: toolbar segmented control, or **⌘\\** (Source), **⌥⌘\\** (Split).

## Export

- **HTML** — self-contained document from `ExportService`’s lightweight renderer (not a dump of Write’s attributed string).
- **PDF** — same HTML through a temporary `WKWebView` PDF snapshot.

Neither is guaranteed to match Write’s on-screen typography (fonts, table chrome, list spacing).

## Character encoding

- Open: UTF-8 preferred; ISO Latin-1 fallback.
- Save: UTF-8.

## Intentionally unsupported (for now)

- YAML/TOML front matter as structured metadata (shows as text)
- Definition lists, footnotes, heading IDs / TOC generation
- Math (`$…$`), Mermaid, embedded widgets
- Wiki-style `[[links]]`
- Multi-cursor / structured outline pane
- Live collaboration

Contributions that extend `MarkdownBlockParser` should update Write, Preview, and export together when practical.
