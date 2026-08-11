import AppKit

/// Converts between Markdown and rich `NSAttributedString` for editable Write mode.
enum MarkdownRichText {
    /// When present, this substring should be written back as this exact Markdown
    /// (used for tables so visual layout can differ from source).
    static let preservedMarkdownKey = NSAttributedString.Key("com.markdowner.preservedMarkdown")
    /// Bool on the checkbox glyph of a task-list line (`☑` / `☐`).
    static let taskCheckboxKey = NSAttributedString.Key("com.markdowner.taskCheckbox")

    // MARK: - Markdown → rich text

    static func attributedString(from markdown: String) -> NSAttributedString {
        let blocks = MarkdownBlockParser.parse(markdown)
        let result = NSMutableAttributedString()
        let baseSize: CGFloat = 16.5

        for (index, block) in blocks.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n"))
            }
            result.append(attributedBlock(block, baseSize: baseSize))
        }

        if result.length == 0 {
            return NSAttributedString(
                string: "",
                attributes: baseAttributes(size: baseSize)
            )
        }
        return result
    }

    private static func attributedBlock(_ block: MarkdownBlock, baseSize: CGFloat) -> NSAttributedString {
        switch block.kind {
        case .heading(let level):
            let size: CGFloat
            switch level {
            case 1: size = 30
            case 2: size = 24
            case 3: size = 20
            case 4: size = 17
            default: size = 16
            }
            var attrs = baseAttributes(size: size, weight: .bold)
            attrs[.paragraphStyle] = paragraphStyle(
                before: level == 1 ? 6 : 14,
                after: 8,
                lineSpacing: 2
            )
            return inlineAttributed(block.text, base: attrs)

        case .paragraph:
            var attrs = baseAttributes(size: baseSize)
            attrs[.paragraphStyle] = paragraphStyle(before: 0, after: 10, lineSpacing: 5)
            return inlineAttributed(block.text, base: attrs)

        case .blockquote:
            var attrs = baseAttributes(size: baseSize - 0.5)
            attrs[.foregroundColor] = NSColor.secondaryLabelColor
            let ps = paragraphStyle(before: 4, after: 10, lineSpacing: 4)
            ps.firstLineHeadIndent = 14
            ps.headIndent = 14
            attrs[.paragraphStyle] = ps
            return inlineAttributed(block.text, base: attrs)

        case .unorderedList(let items):
            return attributedLooseList(
                items: items.map { (marker: "•", body: $0) },
                baseSize: baseSize,
                markerWidthHint: 18
            )

        case .orderedList(let items):
            return attributedLooseList(
                items: items.map { (marker: "\($0.number).", body: $0.text) },
                baseSize: baseSize,
                markerWidthHint: 28
            )

        case .taskList(let items):
            let out = NSMutableAttributedString()
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(NSAttributedString(string: "\n")) }
                var attrs = baseAttributes(size: baseSize)
                if item.checked {
                    attrs[.foregroundColor] = NSColor.secondaryLabelColor
                    attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
                let ps = paragraphStyle(before: 2, after: 2, lineSpacing: 3)
                ps.headIndent = 22
                ps.tabStops = [NSTextTab(textAlignment: .left, location: 22, options: [:])]
                attrs[.paragraphStyle] = ps
                let box = item.checked ? "☑\t" : "☐\t"
                let line = NSMutableAttributedString(string: box, attributes: attrs)
                // Mark checkbox glyph so Write mode can toggle on click.
                let boxRange = NSRange(location: 0, length: 1)
                line.addAttribute(taskCheckboxKey, value: item.checked, range: boxRange)
                line.addAttribute(.cursor, value: NSCursor.pointingHand, range: boxRange)
                line.append(inlineAttributed(item.text, base: attrs))
                out.append(line)
            }
            return out

        case .codeBlock(let language, let code):
            return attributedCodeBlock(code: code, language: language, baseSize: baseSize)

        case .horizontalRule:
            var attrs = baseAttributes(size: baseSize)
            attrs[.foregroundColor] = NSColor.separatorColor
            attrs[.paragraphStyle] = paragraphStyle(before: 10, after: 10, lineSpacing: 0)
            return NSAttributedString(string: "────────────────────────────────", attributes: attrs)

        case .table(let headers, let rows):
            return attributedTable(headers: headers, rows: rows, baseSize: baseSize)
        }
    }

    /// List item may contain title + body paragraphs separated by blank lines.
    /// `body` may start with `"\t\t…"` depth markers from the block parser (two spaces = one level).
    private static func attributedLooseList(
        items: [(marker: String, body: String)],
        baseSize: CGFloat,
        markerWidthHint: CGFloat
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (index, item) in items.enumerated() {
            if index > 0 {
                out.append(NSAttributedString(string: "\n"))
            }
            let depth = listDepth(from: item.body)
            let bodyText = stripListDepthPrefix(item.body)
            let indent = CGFloat(depth) * 22

            let parts = bodyText
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let title = parts.first ?? bodyText
            let bodyParas = Array(parts.dropFirst())

            var titleAttrs = baseAttributes(size: baseSize, weight: .semibold)
            let titlePS = paragraphStyle(before: index == 0 ? 4 : 10, after: bodyParas.isEmpty ? 8 : 4, lineSpacing: 3)
            titlePS.headIndent = markerWidthHint + indent
            titlePS.firstLineHeadIndent = indent
            titlePS.tabStops = [NSTextTab(textAlignment: .left, location: markerWidthHint + indent, options: [:])]
            titleAttrs[.paragraphStyle] = titlePS

            let titleLine = NSMutableAttributedString(string: "\(item.marker)\t", attributes: titleAttrs)
            titleLine.append(inlineAttributed(title, base: titleAttrs))
            if !titleLine.string.hasSuffix("\n") {
                titleLine.append(NSAttributedString(string: "\n", attributes: titleAttrs))
            }
            out.append(titleLine)

            for (bi, para) in bodyParas.enumerated() {
                var bodyAttrs = baseAttributes(size: baseSize - 0.5)
                let bodyPS = paragraphStyle(
                    before: 2,
                    after: bi == bodyParas.count - 1 ? 10 : 6,
                    lineSpacing: 4
                )
                bodyPS.headIndent = markerWidthHint + 10 + indent
                bodyPS.firstLineHeadIndent = markerWidthHint + 10 + indent
                bodyAttrs[.paragraphStyle] = bodyPS
                let bodyLine = NSMutableAttributedString(attributedString: inlineAttributed(para, base: bodyAttrs))
                if !bodyLine.string.hasSuffix("\n") {
                    bodyLine.append(NSAttributedString(string: "\n", attributes: bodyAttrs))
                }
                out.append(bodyLine)
            }
        }
        return out
    }

    /// Depth encoded as leading `"›"` characters from the parser (one per indent level).
    private static func listDepth(from body: String) -> Int {
        var d = 0
        for ch in body {
            if ch == "›" { d += 1 } else { break }
        }
        return d
    }

    private static func stripListDepthPrefix(_ body: String) -> String {
        var s = body
        while s.hasPrefix("›") { s = String(s.dropFirst()) }
        return s
    }

    private static func attributedCodeBlock(code: String, language: String?, baseSize: CGFloat) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
        var base: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.controlBackgroundColor,
            .paragraphStyle: paragraphStyle(before: 8, after: 10, lineSpacing: 2),
        ]
        let out = NSMutableAttributedString(string: code, attributes: base)
        // Light syntax coloring (keywords / strings / comments) — best-effort, not a full highlighter.
        applyLightSyntaxHighlight(to: out, language: language)
        // Preserve original fenced block for round-trip when language or content is fragile.
        let lang = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fence = "```\(lang)\n\(code)\n```"
        if out.length > 0 {
            out.addAttribute(preservedMarkdownKey, value: fence, range: NSRange(location: 0, length: out.length))
        }
        return out
    }

    private static func applyLightSyntaxHighlight(to storage: NSMutableAttributedString, language: String?) {
        let full = storage.string as NSString
        guard full.length > 0 else { return }
        let whole = NSRange(location: 0, length: full.length)
        let lang = (language ?? "").lowercased()

        let keywordSets: [String: [String]] = [
            "swift": ["func", "var", "let", "if", "else", "guard", "return", "import", "struct", "class", "enum", "protocol", "extension", "true", "false", "nil", "self", "async", "await", "throws", "try", "switch", "case", "for", "while", "in", "where", "some", "any"],
            "js": ["function", "const", "let", "var", "if", "else", "return", "import", "export", "class", "true", "false", "null", "async", "await", "for", "while", "of", "in", "new", "typeof"],
            "javascript": [],
            "ts": [],
            "typescript": [],
            "python": ["def", "class", "if", "elif", "else", "return", "import", "from", "as", "True", "False", "None", "for", "while", "in", "with", "try", "except", "async", "await", "yield", "lambda"],
            "py": [],
            "json": ["true", "false", "null"],
            "bash": ["if", "then", "else", "fi", "for", "do", "done", "in", "echo", "export", "return"],
            "sh": [],
        ]
        var keywords = keywordSets[lang] ?? []
        if keywords.isEmpty {
            // Generic fallback
            keywords = keywordSets["swift"]! + keywordSets["python"]! + keywordSets["js"]!
        }
        if lang == "javascript" || lang == "js" || lang == "ts" || lang == "typescript" {
            keywords = keywordSets["js"]!
        }
        if lang == "py" || lang == "python" {
            keywords = keywordSets["python"]!
        }
        if lang == "sh" || lang == "bash" || lang == "zsh" {
            keywords = keywordSets["bash"]!
        }

        let keywordColor = NSColor.systemPurple
        let stringColor = NSColor.systemRed.withAlphaComponent(0.9)
        let commentColor = NSColor.secondaryLabelColor

        for word in Set(keywords) {
            guard let re = try? NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b") else { continue }
            re.enumerateMatches(in: storage.string, options: [], range: whole) { match, _, _ in
                guard let match else { return }
                storage.addAttribute(.foregroundColor, value: keywordColor, range: match.range)
            }
        }
        // Strings
        if let re = try? NSRegularExpression(pattern: #"("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')"#) {
            re.enumerateMatches(in: storage.string, options: [], range: whole) { match, _, _ in
                guard let match else { return }
                storage.addAttribute(.foregroundColor, value: stringColor, range: match.range)
            }
        }
        // Line comments // and #
        if let re = try? NSRegularExpression(pattern: #"(//.*$|#(?!\!).*$)"#, options: [.anchorsMatchLines]) {
            re.enumerateMatches(in: storage.string, options: [], range: whole) { match, _, _ in
                guard let match else { return }
                storage.addAttribute(.foregroundColor, value: commentColor, range: match.range)
            }
        }
    }

    /// Real AppKit text table (not raw pipe characters).
    private static func attributedTable(
        headers: [String],
        rows: [[String]],
        baseSize: CGFloat
    ) -> NSAttributedString {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else {
            return NSAttributedString(string: "")
        }

        let table = NSTextTable()
        table.numberOfColumns = columnCount
        table.collapsesBorders = true
        table.layoutAlgorithm = .automaticLayoutAlgorithm

        let out = NSMutableAttributedString()

        func appendCell(
            _ markdownCell: String,
            row: Int,
            column: Int,
            isHeader: Bool
        ) {
            let block = NSTextTableBlock(
                table: table,
                startingRow: row,
                rowSpan: 1,
                startingColumn: column,
                columnSpan: 1
            )
            block.setBorderColor(NSColor.separatorColor)
            block.setWidth(1.0, type: .absoluteValueType, for: .border)
            block.setWidth(10.0, type: .absoluteValueType, for: .padding)
            if isHeader {
                block.backgroundColor = NSColor.controlBackgroundColor
            } else if row % 2 == 0 {
                // subtle zebra (row 0 is header; body starts at 1)
                block.backgroundColor = NSColor.labelColor.withAlphaComponent(0.03)
            }

            let ps = NSMutableParagraphStyle()
            ps.textBlocks = [block]
            ps.paragraphSpacing = 0
            ps.paragraphSpacingBefore = 0

            var base = baseAttributes(
                size: isHeader ? 13 : 13.5,
                weight: isHeader ? .semibold : .regular
            )
            base[.paragraphStyle] = ps

            let cellBody = inlineAttributed(markdownCell.isEmpty ? " " : markdownCell, base: base)
            let cell = NSMutableAttributedString(attributedString: cellBody)
            // Paragraph style (with text block) must apply to the whole cell paragraph.
            cell.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: cell.length))
            if !cell.string.hasSuffix("\n") {
                cell.append(NSAttributedString(string: "\n", attributes: base))
            }
            out.append(cell)
        }

        // Header row
        for col in 0..<columnCount {
            let text = col < headers.count ? headers[col] : ""
            appendCell(text, row: 0, column: col, isHeader: true)
        }

        // Body rows
        for (r, row) in rows.enumerated() {
            for col in 0..<columnCount {
                let text = col < row.count ? row[col] : ""
                appendCell(text, row: r + 1, column: col, isHeader: false)
            }
        }

        // Preserve exact Markdown for round-trip (cell edits in visual table are limited).
        var mdLines: [String] = []
        mdLines.append("| " + headers.joined(separator: " | ") + " |")
        mdLines.append("| " + headers.map { _ in "---" }.joined(separator: " | ") + " |")
        for row in rows {
            let padded = (0..<columnCount).map { $0 < row.count ? row[$0] : "" }
            mdLines.append("| " + padded.joined(separator: " | ") + " |")
        }
        let preserved = mdLines.joined(separator: "\n")
        if out.length > 0 {
            out.addAttribute(
                preservedMarkdownKey,
                value: preserved,
                range: NSRange(location: 0, length: out.length)
            )
        }

        // Trailing spacing after table
        let spacer = NSMutableAttributedString(
            string: "\n",
            attributes: baseAttributes(size: baseSize)
        )
        out.append(spacer)
        return out
    }

    private static func inlineAttributed(_ markdown: String, base: [NSAttributedString.Key: Any]) -> NSAttributedString {
        // Split on images so Write mode can show real NSTextAttachments.
        let segments = MarkdownInlineSegments.parse(markdown)
        if segments.isEmpty {
            return NSAttributedString(string: "", attributes: base)
        }

        let result = NSMutableAttributedString()
        for segment in segments {
            switch segment {
            case .image(let alt, let src):
                result.append(MarkdownImage.attachmentString(alt: alt, src: src, base: base))
            case .text(let piece):
                guard !piece.isEmpty else { continue }
                let styled = MarkdownInline.attributed(piece)
                let chunk = NSMutableAttributedString(attributedString: NSAttributedString(styled))
                chunk.enumerateAttributes(in: NSRange(location: 0, length: chunk.length)) { attrs, range, _ in
                    var merged = base
                    for (k, v) in attrs {
                        merged[k] = v
                    }
                    if merged[.font] == nil, let baseFont = base[.font] {
                        merged[.font] = baseFont
                    }
                    if merged[.foregroundColor] == nil, let c = base[.foregroundColor] {
                        merged[.foregroundColor] = c
                    }
                    if merged[.paragraphStyle] == nil, let p = base[.paragraphStyle] {
                        merged[.paragraphStyle] = p
                    }
                    chunk.setAttributes(merged, range: range)
                }
                result.append(chunk)
            }
        }
        if result.length == 0 {
            return NSAttributedString(string: markdown, attributes: base)
        }
        return result
    }

    private static func baseAttributes(size: CGFloat, weight: NSFont.Weight = .regular) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.labelColor,
        ]
    }

    private static func paragraphStyle(before: CGFloat, after: CGFloat, lineSpacing: CGFloat) -> NSMutableParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.paragraphSpacingBefore = before
        ps.paragraphSpacing = after
        ps.lineSpacing = lineSpacing
        return ps
    }

    // MARK: - Rich text → Markdown

    static func markdown(from attributed: NSAttributedString) -> String {
        if attributed.length == 0 { return "" }

        let full = attributed.string as NSString
        var pieces: [String] = []
        var location = 0

        while location < full.length {
            // Emit preserved blocks (tables) as original Markdown
            var preservedRange = NSRange(location: 0, length: 0)
            let preserved = attributed.attribute(
                preservedMarkdownKey,
                at: location,
                longestEffectiveRange: &preservedRange,
                in: NSRange(location: location, length: full.length - location)
            ) as? String

            if let preserved, preservedRange.location == location, preservedRange.length > 0 {
                if let last = pieces.last, !last.isEmpty { pieces.append("") }
                pieces.append(preserved)
                pieces.append("")
                location = preservedRange.location + preservedRange.length
                // Skip trailing newlines already included after table
                while location < full.length && full.character(at: location) == 10 {
                    location += 1
                }
                continue
            }

            var lineEnd = location
            while lineEnd < full.length && full.character(at: lineEnd) != 10 {
                // Don't walk into a preserved block mid-line
                if attributed.attribute(preservedMarkdownKey, at: lineEnd, effectiveRange: nil) != nil {
                    break
                }
                lineEnd += 1
            }
            let range = NSRange(location: location, length: max(0, lineEnd - location))
            if range.length > 0 {
                let lineAttr = attributed.attributedSubstring(from: range)
                pieces.append(markdownLine(from: lineAttr))
            } else {
                pieces.append("")
            }
            location = min(lineEnd + 1, full.length)
            if lineEnd >= full.length { break }
        }

        // Collapse excess blank lines
        var cleaned: [String] = []
        var blankRun = 0
        for line in pieces {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blankRun += 1
                if blankRun <= 1 { cleaned.append("") }
            } else {
                blankRun = 0
                cleaned.append(line)
            }
        }
        return cleaned.joined(separator: "\n")
    }

    private static func markdownLine(from line: NSAttributedString) -> String {
        if line.length == 0 { return "" }

        // Detect heading by font size
        let mid = min(0, line.length - 1)
        let font = line.attribute(.font, at: mid, effectiveRange: nil) as? NSFont
        let size = font?.pointSize ?? 16.5
        let plain = line.string

        // Horizontal rule heuristic
        if plain.trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == "─" || $0 == "-" })
            && plain.count >= 8 {
            return "---"
        }

        // List heuristics
        let trimmed = plain.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("•") || trimmed.hasPrefix("·") {
            let rest = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            return "- " + inlineMarkdown(from: substringDroppingPrefix(line, prefixes: ["•", "·", "\t", " "]))
        }
        if trimmed.hasPrefix("☑") || trimmed.hasPrefix("☐") {
            let checked = trimmed.hasPrefix("☑")
            let body = inlineMarkdown(from: substringDroppingPrefix(line, prefixes: ["☑", "☐", "\t", " "]))
            return "- [\(checked ? "x" : " ")] " + body
        }
        if let ordered = orderedListPrefix(trimmed) {
            let body = inlineMarkdown(from: substringDroppingPrefix(line, prefixes: [ordered, "\t", " "]))
            return ordered + " " + body
        }

        let body = inlineMarkdown(from: line)

        if size >= 28 { return "# " + body }
        if size >= 22 { return "## " + body }
        if size >= 19 { return "### " + body }
        if size >= 17.5 { return "#### " + body }

        // Monospaced multi-token line → treat as code-ish plain
        if isMostlyMonospaced(line), body.contains("|") {
            return body
        }

        return body
    }

    private static func orderedListPrefix(_ trimmed: String) -> String? {
        // "1." or "12."
        guard let dot = trimmed.firstIndex(of: ".") else { return nil }
        let num = trimmed[trimmed.startIndex..<dot]
        guard !num.isEmpty, num.allSatisfy(\.isNumber) else { return nil }
        return String(num) + "."
    }

    private static func substringDroppingPrefix(
        _ line: NSAttributedString,
        prefixes: [String]
    ) -> NSAttributedString {
        var s = line.string
        var dropped = 0
        var changed = true
        while changed {
            changed = false
            for p in prefixes {
                if s.hasPrefix(p) {
                    s = String(s.dropFirst(p.count))
                    dropped += p.count
                    changed = true
                }
            }
        }
        if dropped == 0 { return line }
        let range = NSRange(location: dropped, length: line.length - dropped)
        guard range.length >= 0, range.location + range.length <= line.length else { return line }
        return line.attributedSubstring(from: range)
    }

    private static func inlineMarkdown(from attr: NSAttributedString) -> String {
        if attr.length == 0 { return "" }
        var out = ""
        attr.enumerateAttributes(in: NSRange(location: 0, length: attr.length)) { attrs, range, _ in
            // Exact preserved image / table fragment
            if let preserved = attrs[preservedMarkdownKey] as? String, !preserved.isEmpty {
                // Only emit once for image/table runs that carry full markdown
                if preserved.hasPrefix("![") || preserved.hasPrefix("|") {
                    out += preserved
                    return
                }
            }
            if attrs[.attachment] != nil {
                let src = attrs[MarkdownImage.srcKey] as? String ?? ""
                let alt = attrs[MarkdownImage.altKey] as? String ?? ""
                if let preserved = attrs[preservedMarkdownKey] as? String, preserved.hasPrefix("![") {
                    out += preserved
                } else if !src.isEmpty {
                    out += MarkdownImage.markdown(alt: alt, src: src)
                }
                return
            }

            var chunk = (attr.string as NSString).substring(with: range)
            if chunk.isEmpty { return }

            let font = attrs[.font] as? NSFont
            let symbolic = font?.fontDescriptor.symbolicTraits ?? []
            let bold = symbolic.contains(.bold) || isBoldTrait(font)
            let italic = symbolic.contains(.italic) || isItalicTrait(font)
            let mono = font?.fontName.lowercased().contains("mono") == true
                || font?.fontDescriptor.design == .monospaced
            let link = attrs[.link]
            let strike = (attrs[.strikethroughStyle] as? Int).map { $0 != 0 } ?? false

            if mono {
                chunk = "`" + chunk.replacingOccurrences(of: "`", with: "'") + "`"
            }
            if bold {
                chunk = "**" + chunk + "**"
            } else if italic {
                chunk = "*" + chunk + "*"
            }
            if strike {
                chunk = "~~" + chunk + "~~"
            }
            if let link {
                let urlString: String
                if let u = link as? URL {
                    urlString = LinkHandling.markdownHref(for: u)
                } else if let s = link as? String {
                    urlString = s
                } else {
                    urlString = ""
                }
                if !urlString.isEmpty {
                    chunk = "[\(chunk)](\(urlString))"
                }
            }
            out += chunk
        }
        return out
    }

    private static func isBoldTrait(_ font: NSFont?) -> Bool {
        guard let font else { return false }
        return font.fontDescriptor.symbolicTraits.contains(.bold)
            || font.fontName.lowercased().contains("bold")
    }

    private static func isItalicTrait(_ font: NSFont?) -> Bool {
        guard let font else { return false }
        return font.fontDescriptor.symbolicTraits.contains(.italic)
            || font.fontName.lowercased().contains("italic")
            || font.fontName.lowercased().contains("oblique")
    }

    private static func isMostlyMonospaced(_ line: NSAttributedString) -> Bool {
        guard line.length > 0 else { return false }
        var mono = 0
        line.enumerateAttribute(.font, in: NSRange(location: 0, length: line.length)) { value, range, _ in
            if let font = value as? NSFont,
               font.fontName.lowercased().contains("mono") || font.fontDescriptor.design == .monospaced {
                mono += range.length
            }
        }
        return mono * 2 >= line.length
    }

    private static func relativePath(for fileURL: URL) -> String {
        if let base = LinkHandling.documentDirectory {
            let basePath = base.path
            let path = fileURL.path
            if path.hasPrefix(basePath) {
                var rel = String(path.dropFirst(basePath.count))
                if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
                return rel.isEmpty ? fileURL.lastPathComponent : rel
            }
        }
        return fileURL.lastPathComponent
    }
}

private extension NSFontDescriptor {
    var design: NSFontDescriptor.SystemDesign? {
        // Best-effort monospaced detection via traits / name only above.
        nil
    }
}
