import AppKit
import Foundation
import SwiftUI

/// Opens Markdown links: web/HTML → browser, `.md` → document, directories → sidebar.
enum LinkHandling {
    /// Custom scheme that stores a relative path losslessly (no host/path splitting).
    /// Format: `markdowner-rel://doc?p=pilot/y1-process-wedge/`
    static let relativeScheme = "markdowner-rel"

    /// Base folder of the open document (for resolving relative links).
    nonisolated(unsafe) static var documentDirectory: URL?

    /// Currently open document URL (for same-file `#anchor` detection).
    nonisolated(unsafe) static var currentDocumentURL: URL?

    /// Extra roots to search when a relative path does not resolve directly
    /// (typically the sidebar folder grant / current browser root).
    nonisolated(unsafe) static var searchRoots: [URL] = []

    @MainActor
    static var openURLAction: OpenURLAction {
        OpenURLAction { url in
            handle(url, preferNewWindow: false)
        }
    }

    @MainActor
    @discardableResult
    static func handle(_ url: URL, preferNewWindow: Bool = false) -> OpenURLAction.Result {
        if isWeb(url) {
            openInBrowser(url)
            return .handled
        }

        // Same-document fragment only: `#heading-id` or `url` with empty path + fragment.
        if let fragment = fragmentOnly(from: url) {
            navigateToAnchor(fragment)
            return .handled
        }

        let fragment = extractFragment(from: url)

        guard let local = resolveLocalURL(url) else {
            // Path failed but we might still have a bare fragment in the raw string
            if let frag = fragment, !frag.isEmpty {
                navigateToAnchor(frag)
                return .handled
            }
            presentOpenFailed(url, hint: nil)
            return .discarded
        }

        if isDirectory(local) {
            // Sidebar only — no document open, no back/forward history.
            NotificationCenter.default.post(name: .markdownerNavigateDirectory, object: local)
            return .handled
        }

        if isHTMLPath(local.path) {
            openInBrowser(local)
            return .handled
        }

        if isMarkdownPath(local.path) {
            let sameDoc = isSameDocument(local)
            if sameDoc, let fragment, !fragment.isEmpty {
                navigateToAnchor(fragment)
                return .handled
            }
            let result = openLocalMarkdown(local, newWindow: preferNewWindow)
            if let fragment, !fragment.isEmpty, !preferNewWindow {
                // Scroll after the new file has been loaded into the workspace.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    navigateToAnchor(fragment)
                }
            }
            return result
        }

        if FileManager.default.fileExists(atPath: local.path) {
            NSWorkspace.shared.open(local)
            return .handled
        }

        presentOpenFailed(local, hint: storedRelativePath(from: url))
        return .discarded
    }

    /// Post a scroll-to-heading request for the active editor(s).
    @MainActor
    static func navigateToAnchor(_ fragment: String) {
        let cleaned = fragment
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .removingPercentEncoding ?? fragment
        let cleaned2 = cleaned
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard !cleaned2.isEmpty else { return }
        NotificationCenter.default.post(name: .markdownerNavigateAnchor, object: cleaned2)
    }

    /// Scroll an `NSTextView` to a same-document heading.
    /// - Parameters:
    ///   - fragment: heading slug or plain title (no leading `#`)
    ///   - textView: Write or Source editor
    ///   - markdownSource: raw Markdown (needed in Write mode — display text has no `#` markers)
    @discardableResult
    nonisolated static func scrollTextView(
        _ textView: NSTextView,
        toAnchor fragment: String,
        markdownSource: String?
    ) -> Bool {
        let displayed = textView.string
        let source = markdownSource ?? displayed
        guard let range = rangeOfAnchor(fragment, in: displayed, markdownSource: source) else {
            return false
        }
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        // Nudge a bit so the heading isn’t glued under the toolbar.
        if let scroll = textView.enclosingScrollView {
            let clip = scroll.contentView
            let y = max(0, clip.bounds.origin.y - 24)
            clip.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(clip)
        }
        return true
    }

    /// GitHub-ish slug for a heading line (best-effort).
    nonisolated static func headingSlug(_ text: String) -> String {
        let plain = stripInlineMarkup(text)
        let lowered = plain.lowercased()
        var out = ""
        out.reserveCapacity(lowered.count)
        var lastWasHyphen = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasHyphen = false
            } else if ch == " " || ch == "-" || ch == "_" {
                if !lastWasHyphen && !out.isEmpty {
                    out.append("-")
                    lastWasHyphen = true
                }
            }
            // drop other punctuation (including `.` so "0.5" → "05" like many renderers)
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /// Remove light inline markup so display text matches Write-mode strings.
    nonisolated static func stripInlineMarkup(_ text: String) -> String {
        var t = text
        let patterns = [
            #"\*\*([^*]+)\*\*"#,
            #"__([^_]+)__"#,
            #"\*([^*]+)\*"#,
            #"_([^_]+)_"#,
            #"`([^`]+)`"#,
            #"~~([^~]+)~~"#,
            #"\[([^\]]+)\]\([^)]+\)"#, // [label](url) → label
        ]
        for p in patterns {
            t = t.replacingOccurrences(of: p, with: "$1", options: .regularExpression)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Titles of Markdown headings that match `fragment` (slug or plain text), in document order.
    nonisolated static func matchingHeadingTitles(_ fragment: String, in markdown: String) -> [String] {
        let needle = fragment
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard !needle.isEmpty else { return [] }
        let slugNeedle = headingSlug(needle)
        var titles: [String] = []

        let ns = markdown as NSString
        var idx = 0
        while idx < ns.length {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            ns.getLineStart(
                &lineStart,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: idx, length: 0)
            )
            let lineRange = NSRange(location: lineStart, length: max(0, contentsEnd - lineStart))
            let line = ns.substring(with: lineRange)

            if let title = markdownHeadingTitle(line) {
                let slug = headingSlug(title)
                let plain = stripInlineMarkup(title)
                if slug == slugNeedle
                    || plain.compare(needle, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                    || plain.localizedCaseInsensitiveContains(needle)
                    || slugNeedle == headingSlug(needle) && slug == slugNeedle {
                    titles.append(plain)
                }
            }

            if lineEnd <= idx { break }
            idx = lineEnd
        }
        return titles
    }

    /// `"## Hello *world*"` → `"Hello *world*"`; non-headings → nil.
    nonisolated private static func markdownHeadingTitle(_ line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        var i = line.startIndex
        var count = 0
        while i < line.endIndex, line[i] == "#", count < 6 {
            i = line.index(after: i)
            count += 1
        }
        guard count >= 1, count <= 6 else { return nil }
        // Require a space (or end) after hashes — avoids matching horizontal rules later.
        if i < line.endIndex, !line[i].isWhitespace { return nil }
        while i < line.endIndex, line[i].isWhitespace { i = line.index(after: i) }
        let title = String(line[i...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// Find the range of a heading matching `fragment` inside `text`.
    ///
    /// - In **Source** mode `text` is Markdown (`## Title`).
    /// - In **Write** mode `text` is the plain display string (no `#`); pass `markdownSource`
    ///   so we can resolve the slug against the real headings, then locate the title text.
    nonisolated static func rangeOfAnchor(
        _ fragment: String,
        in text: String,
        markdownSource: String? = nil
    ) -> NSRange? {
        let needle = fragment
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard !needle.isEmpty else { return nil }

        let source = markdownSource ?? text
        let ns = text as NSString

        // 1. Prefer titles resolved from Markdown headings (works for Write + Source).
        for title in matchingHeadingTitles(needle, in: source) {
            let found = ns.range(of: title, options: [.caseInsensitive, .diacriticInsensitive])
            if found.location != NSNotFound { return found }
        }

        // 2. Direct Markdown heading lines in `text` itself (Source / raw).
        if let r = rangeOfMarkdownHeadingLine(needle, in: text) {
            return r
        }

        // 3. Plain-line slug match (Write display: each line may be a heading visually).
        if let r = rangeOfPlainLineSlug(needle, in: text) {
            return r
        }

        // 4. Substring fallback
        let found = ns.range(of: needle, options: [.caseInsensitive])
        return found.location == NSNotFound ? nil : found
    }

    nonisolated private static func rangeOfMarkdownHeadingLine(_ fragment: String, in text: String) -> NSRange? {
        let slugNeedle = headingSlug(fragment)
        let ns = text as NSString
        var idx = 0
        while idx < ns.length {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            ns.getLineStart(
                &lineStart,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: idx, length: 0)
            )
            let lineRange = NSRange(location: lineStart, length: max(0, contentsEnd - lineStart))
            let line = ns.substring(with: lineRange)
            if let title = markdownHeadingTitle(line) {
                let slug = headingSlug(title)
                let plain = stripInlineMarkup(title)
                if slug == slugNeedle
                    || plain.compare(fragment, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                    return lineRange
                }
            }
            if lineEnd <= idx { break }
            idx = lineEnd
        }
        return nil
    }

    nonisolated private static func rangeOfPlainLineSlug(_ fragment: String, in text: String) -> NSRange? {
        let slugNeedle = headingSlug(fragment)
        guard !slugNeedle.isEmpty else { return nil }
        let ns = text as NSString
        var idx = 0
        while idx < ns.length {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            ns.getLineStart(
                &lineStart,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: idx, length: 0)
            )
            let lineRange = NSRange(location: lineStart, length: max(0, contentsEnd - lineStart))
            let line = ns.substring(with: lineRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip empty / list / very long paragraph lines as unlikely headings
            if !line.isEmpty, line.count < 120, !line.hasPrefix("-"), !line.hasPrefix("*"),
               headingSlug(line) == slugNeedle {
                return lineRange
            }
            if lineEnd <= idx { break }
            idx = lineEnd
        }
        return nil
    }

    /// Any fragment on the URL, including `markdowner-rel` query values like `p=file.md#sec`.
    nonisolated private static func extractFragment(from url: URL) -> String? {
        if let frag = url.fragment, !frag.isEmpty {
            return frag.removingPercentEncoding ?? frag
        }
        if let rel = storedRelativePath(from: url), let hash = rel.firstIndex(of: "#") {
            let frag = String(rel[rel.index(after: hash)...])
            return frag.isEmpty ? nil : (frag.removingPercentEncoding ?? frag)
        }
        let abs = url.absoluteString
        if let hash = abs.firstIndex(of: "#"), hash < abs.endIndex {
            let frag = String(abs[abs.index(after: hash)...])
            return frag.isEmpty ? nil : (frag.removingPercentEncoding ?? frag)
        }
        return nil
    }

    nonisolated private static func fragmentOnly(from url: URL) -> String? {
        // `#heading` → absoluteString often "#heading", fragment set
        if let frag = url.fragment, !frag.isEmpty {
            let path = url.path
            let rel = url.relativeString
            if path.isEmpty || path == "/" {
                // No file path — pure in-document anchor
                if url.scheme == nil || url.scheme?.lowercased() == relativeScheme {
                    return frag.removingPercentEncoding ?? frag
                }
                // file URL with empty path is unusual; still allow
                if !url.isFileURL, url.host == nil {
                    return frag.removingPercentEncoding ?? frag
                }
            }
            // Relative string that is only a fragment
            if rel.hasPrefix("#") {
                return frag.removingPercentEncoding ?? frag
            }
        }
        let abs = url.absoluteString
        if abs.hasPrefix("#") {
            return String(abs.dropFirst()).removingPercentEncoding ?? String(abs.dropFirst())
        }
        // markdowner-rel with p=#heading only
        if let rel = storedRelativePath(from: url), rel.hasPrefix("#") {
            return String(rel.dropFirst()).removingPercentEncoding ?? String(rel.dropFirst())
        }
        return nil
    }

    nonisolated private static func isSameDocument(_ url: URL) -> Bool {
        guard let current = currentDocumentURL else { return false }
        return current.standardizedFileURL.path == url.standardizedFileURL.path
    }

    /// Context menu: Open / Open in New Window / Show in Sidebar / Browser / Copy.
    @MainActor
    static func presentMenu(for url: URL, relativeTo view: NSView? = nil) {
        let local = resolveLocalURL(url) ?? url
        let menu = NSMenu(title: "Link")
        let target = LinkMenuTarget.shared

        if isDirectory(local) {
            addMenuItem(menu, title: "Show in Sidebar", action: #selector(LinkMenuTarget.openLink(_:)), object: local, target: target)
            addMenuItem(menu, title: "Show in Finder", action: #selector(LinkMenuTarget.revealInFinder(_:)), object: local, target: target)
        } else if isMarkdownPath(local.path) {
            addMenuItem(menu, title: "Open", action: #selector(LinkMenuTarget.openLink(_:)), object: local, target: target)
            addMenuItem(menu, title: "Open in New Window", action: #selector(LinkMenuTarget.openLinkNewWindow(_:)), object: local, target: target)
        } else if isWeb(url) || isHTMLPath(local.path) {
            addMenuItem(menu, title: "Open in Browser", action: #selector(LinkMenuTarget.openLink(_:)), object: isWeb(url) ? url : local, target: target)
        } else {
            addMenuItem(menu, title: "Open", action: #selector(LinkMenuTarget.openLink(_:)), object: local, target: target)
        }

        menu.addItem(.separator())
        addMenuItem(menu, title: "Copy Link", action: #selector(LinkMenuTarget.copyLink(_:)), object: displayString(for: local, original: url), target: target)

        if let event = NSApp.currentEvent, let view {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    // MARK: - Create / decode relative links

    /// Build a resolvable URL from a raw Markdown link string (used when creating attributed links).
    ///
    /// Prefer a real `file://` URL when the document folder is known — `NSTextView` and SwiftUI
    /// `openURL` handle those reliably. Fall back to `markdowner-rel` (lossless multi-segment
    /// relative) only when there is no base yet; resolution then happens on click.
    nonisolated static func urlFromMarkdownLink(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("mailto:") {
            return URL(string: trimmed)
        }
        if trimmed.hasPrefix("file:") {
            return URL(string: trimmed)
        }
        if trimmed.hasPrefix(relativeScheme + ":") {
            return URL(string: trimmed)
        }

        // Pure in-document anchor: `#section-id`
        if trimmed.hasPrefix("#") {
            return URL(string: trimmed)
        }

        // Split path + fragment: `other.md#section` or `pilot/x/#y`
        let pathPart: String
        let fragment: String?
        if let hash = trimmed.firstIndex(of: "#") {
            pathPart = String(trimmed[..<hash])
            let frag = String(trimmed[trimmed.index(after: hash)...])
            fragment = frag.isEmpty ? nil : frag
        } else {
            pathPart = trimmed
            fragment = nil
        }

        // Absolute filesystem path
        if pathPart.hasPrefix("/") {
            var u = URL(fileURLWithPath: pathPart)
            if let fragment, var c = URLComponents(url: u, resolvingAgainstBaseURL: false) {
                c.fragment = fragment
                u = c.url ?? u
            }
            return u
        }

        // Relative path: resolve against the open document's folder when available so the
        // attributed-string link is a normal file URL (Cmd/click works; sandbox paths are clear).
        if pathPart.isEmpty {
            // Only fragment was present after split — should have been caught above
            if let fragment { return URL(string: "#\(fragment)") }
            return nil
        }

        if let base = documentDirectory,
           let resolved = resolvePathString(pathPart, base: base) {
            if let fragment, var c = URLComponents(url: resolved, resolvingAgainstBaseURL: false) {
                c.fragment = fragment
                return c.url ?? resolved
            }
            return resolved
        }

        // No document base yet — keep the full relative path (including #frag) in a custom scheme.
        return makeRelativeLinkURL(trimmed)
    }

    /// Encode a relative path so Foundation cannot treat the first segment as a host.
    nonisolated static func makeRelativeLinkURL(_ relative: String) -> URL? {
        var components = URLComponents()
        components.scheme = relativeScheme
        components.host = "doc"
        components.queryItems = [URLQueryItem(name: "p", value: relative)]
        return components.url
    }

    /// Extract the original relative path from a `markdowner-rel` URL, if any.
    nonisolated static func storedRelativePath(from url: URL) -> String? {
        guard url.scheme?.lowercased() == relativeScheme else { return nil }
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let p = items.first(where: { $0.name == "p" })?.value,
           !p.isEmpty {
            return p
        }
        // Fallbacks for older/alternate encodings
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.isEmpty { return path.removingPercentEncoding ?? path }
        return nil
    }

    /// Markdown-facing string for a link attribute (relative when possible).
    nonisolated static func markdownHref(for url: URL) -> String {
        if let rel = storedRelativePath(from: url) {
            return rel
        }
        if isWeb(url) {
            return url.absoluteString
        }
        if url.isFileURL, let base = documentDirectory {
            let basePath = base.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            if path == basePath { return "." }
            if path.hasPrefix(basePath + "/") {
                return String(path.dropFirst(basePath.count + 1))
            }
            return path
        }
        if url.scheme == nil {
            return url.relativeString.removingPercentEncoding ?? url.relativeString
        }
        return url.absoluteString
    }

    // MARK: - Resolve

    /// Resolve any link URL (absolute, relative, file, markdowner-rel) to a local file URL when possible.
    nonisolated static func resolveLocalURL(_ url: URL) -> URL? {
        if isWeb(url) { return nil }

        // 1. Lossless relative scheme (may include `path#fragment` in the query)
        if let rel = storedRelativePath(from: url) {
            let pathOnly: String
            if let hash = rel.firstIndex(of: "#") {
                pathOnly = String(rel[..<hash])
            } else {
                pathOnly = rel
            }
            if pathOnly.isEmpty {
                // Pure fragment stored in scheme — not a local file
                return nil
            }
            return resolveRelativeLink(pathOnly)
        }

        // 2. Already an absolute existing path
        if url.isFileURL, FileManager.default.fileExists(atPath: url.path) {
            return url.standardizedFileURL
        }

        // 3. Scheme-less relative reference (legacy / raw URL(string: "a/b"))
        if url.scheme == nil {
            let candidates = [
                url.relativeString.removingPercentEncoding ?? url.relativeString,
                url.relativePath,
                url.path,
            ]
            for raw in candidates {
                let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty, cleaned != "." else { continue }
                if cleaned.hasPrefix("http") || cleaned.hasPrefix("mailto:") { continue }
                if let resolved = resolveRelativeLink(cleaned) {
                    return resolved
                }
            }
        }

        // 4. File URL that doesn't exist — try path reconstruction
        if url.isFileURL {
            let path = url.path
            if let base = documentDirectory {
                let basePath = base.standardizedFileURL.path
                if path.hasPrefix(basePath + "/") {
                    let rel = String(path.dropFirst(basePath.count + 1))
                    if let found = resolveRelativeLink(rel) { return found }
                }
            }
            // lastPathComponent search (handles host-mangled multi-segment paths)
            if let found = findNamed(url.lastPathComponent, preferDirectory: path.hasSuffix("/")) {
                return found
            }
            return url.standardizedFileURL
        }

        return nil
    }

    /// Resolve a path string that may contain multiple components and `..` segments,
    /// then fall back to a name search under document / sidebar roots.
    nonisolated static func resolvePathString(_ raw: String, base: URL? = documentDirectory) -> URL? {
        resolveRelativeLink(raw, base: base)
    }

    nonisolated private static func resolveRelativeLink(_ raw: String, base: URL? = documentDirectory) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }

        if s.hasPrefix("file:") {
            if let u = URL(string: s) {
                return existingOrSearch(u, name: u.lastPathComponent, preferDirectory: s.hasSuffix("/"))
            }
        }
        // Strip query/fragment only for plain paths (not our scheme)
        if !s.hasPrefix(relativeScheme) {
            if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
            if let h = s.firstIndex(of: "#") { s = String(s[..<h]) }
        }
        s = s.removingPercentEncoding ?? s

        let wantsDirectory = s.hasSuffix("/")

        // Absolute filesystem path
        if s.hasPrefix("/") {
            let u = URL(fileURLWithPath: s).standardizedFileURL
            return existingOrSearch(u, name: u.lastPathComponent, preferDirectory: wantsDirectory)
        }

        // Multi-component relative path: join onto document directory component-by-component
        // (do NOT use appendingPathComponent on the whole "a/b/c" string).
        guard var root = base?.standardizedFileURL else {
            // No document base — still try search roots by name
            if let found = findNamed(
                (s as NSString).lastPathComponent,
                preferDirectory: wantsDirectory
            ) {
                return found
            }
            return URL(fileURLWithPath: s).standardizedFileURL
        }

        if s.hasPrefix("./") {
            s = String(s.dropFirst(2))
        }

        for part in s.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                root = root.deletingLastPathComponent()
            } else {
                root = root.appendingPathComponent(String(part), isDirectory: false)
            }
        }
        let candidate = root.standardizedFileURL
        return existingOrSearch(candidate, name: candidate.lastPathComponent, preferDirectory: wantsDirectory)
    }

    /// If `candidate` exists, return it; otherwise search for `name` under known roots.
    nonisolated private static func existingOrSearch(
        _ candidate: URL,
        name: String,
        preferDirectory: Bool
    ) -> URL? {
        let path = candidate.path
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            return candidate.standardizedFileURL
        }
        // Trailing-slash variants
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        if FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDir) {
            return URL(fileURLWithPath: trimmed).standardizedFileURL
        }

        if let found = findNamed(name, preferDirectory: preferDirectory) {
            return found
        }
        // Return the intended path so the error dialog shows a useful full path
        return candidate.standardizedFileURL
    }

    /// Breadth-first search for a file or folder named `name` under document + sidebar roots.
    nonisolated static func findNamed(_ name: String, preferDirectory: Bool) -> URL? {
        let needle = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !needle.isEmpty, needle != ".", needle != ".." else { return nil }

        var roots: [URL] = []
        if let d = documentDirectory {
            roots.append(d.standardizedFileURL)
            // Parent of the document folder (e.g. repo root when doc is in docs/)
            let parent = d.deletingLastPathComponent().standardizedFileURL
            if parent.path != d.path {
                roots.append(parent)
            }
        }
        for r in searchRoots {
            roots.append(r.standardizedFileURL)
        }

        // De-dupe roots
        var seenRoots = Set<String>()
        roots = roots.filter { seenRoots.insert($0.path).inserted }

        var matches: [URL] = []
        let fm = FileManager.default
        let maxDepth = 8

        for root in roots {
            var queue: [(URL, Int)] = [(root, 0)]
            var visited = Set<String>()
            while !queue.isEmpty {
                let (dir, depth) = queue.removeFirst()
                let key = dir.path
                if visited.contains(key) { continue }
                visited.insert(key)
                guard depth <= maxDepth else { continue }

                let contents: [URL]
                do {
                    contents = try fm.contentsOfDirectory(
                        at: dir,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                    )
                } catch {
                    continue
                }

                for item in contents {
                    if item.lastPathComponent == needle {
                        matches.append(item.standardizedFileURL)
                    }
                    let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if isDir, depth < maxDepth {
                        queue.append((item, depth + 1))
                    }
                }
            }
        }

        guard !matches.isEmpty else { return nil }

        // Prefer unique path
        var unique: [URL] = []
        var seen = Set<String>()
        for m in matches where seen.insert(m.path).inserted {
            unique.append(m)
        }

        if unique.count == 1 { return unique[0] }

        // Prefer directory vs file based on link style
        let dirs = unique.filter { isDirectory($0) }
        let files = unique.filter { !isDirectory($0) }
        let pool = preferDirectory ? (dirs.isEmpty ? unique : dirs) : (files.isEmpty ? unique : files)

        // Prefer shallowest under document directory
        if let base = documentDirectory?.path {
            let underDoc = pool.filter { $0.path.hasPrefix(base) }
            if let best = underDoc.min(by: { $0.pathComponents.count < $1.pathComponents.count }) {
                return best
            }
        }
        return pool.min(by: { $0.pathComponents.count < $1.pathComponents.count })
    }

    // MARK: - Internals

    private static func addMenuItem(
        _ menu: NSMenu,
        title: String,
        action: Selector,
        object: Any?,
        target: AnyObject
    ) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.representedObject = object
        item.target = target
    }

    private static func openInBrowser(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private static func openLocalMarkdown(_ url: URL, newWindow: Bool) -> OpenURLAction.Result {
        let fileURL = url.isFileURL ? url : URL(fileURLWithPath: url.path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            presentOpenFailed(fileURL, hint: nil)
            return .discarded
        }
        if newWindow {
            NotificationCenter.default.post(name: .markdownerOpenFileURLInNewWindow, object: fileURL)
        } else {
            NotificationCenter.default.post(name: .markdownerOpenFileURL, object: fileURL)
        }
        return .handled
    }

    nonisolated private static func isWeb(_ url: URL) -> Bool {
        let s = url.scheme?.lowercased()
        return s == "http" || s == "https" || s == "mailto"
    }

    nonisolated private static func isMarkdownPath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["md", "markdown", "mdown", "mkd", "mdx"].contains(ext)
    }

    nonisolated private static func isHTMLPath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "html" || ext == "htm"
    }

    nonisolated private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let path = url.path
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            return true
        }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDir) && isDir.boolValue
    }

    nonisolated private static func displayString(for url: URL, original: URL? = nil) -> String {
        if let original, let rel = storedRelativePath(from: original) {
            return rel
        }
        if let rel = storedRelativePath(from: url) {
            return rel
        }
        if isWeb(url) { return url.absoluteString }
        if let dir = documentDirectory {
            let base = dir.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            if path == base { return dir.lastPathComponent }
            if path.hasPrefix(base + "/") {
                return String(path.dropFirst(base.count + 1))
            }
        }
        return url.isFileURL ? url.path : (url.relativeString.removingPercentEncoding ?? url.absoluteString)
    }

    private static func presentOpenFailed(_ url: URL, hint: String?) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t open link"
        let shown = hint ?? displayString(for: url)
        let full = url.isFileURL ? url.path : (storedRelativePath(from: url) ?? url.absoluteString)
        var text = "Couldn't resolve “\(shown)”."
        if full != shown, url.isFileURL {
            text += "\n\nTried:\n\(full)"
        }
        if let base = documentDirectory {
            text += "\n\nDocument folder:\n\(base.path)"
        }
        // Suggest search hit if any
        let name = (shown as NSString).lastPathComponent
        if let found = findNamed(name, preferDirectory: shown.hasSuffix("/")),
           found.path != full {
            text += "\n\nDid you mean:\n\(found.path)"
        }
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy Link")
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(shown, forType: .string)
        }
    }
}

final class LinkMenuTarget: NSObject {
    static let shared = LinkMenuTarget()

    @objc func openLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        Task { @MainActor in
            _ = LinkHandling.handle(url, preferNewWindow: false)
        }
    }

    @objc func openLinkNewWindow(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        Task { @MainActor in
            _ = LinkHandling.handle(url, preferNewWindow: true)
        }
    }

    @objc func copyLink(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    @objc func revealInFinder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
