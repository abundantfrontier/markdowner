import AppKit

/// Converts between Markdown and rich `NSAttributedString` for editable Write mode.
enum MarkdownRichText {
    /// When present, this substring should be written back as this exact Markdown
    /// (used for tables so visual layout can differ from source).
    static let preservedMarkdownKey = NSAttributedString.Key("com.markdowner.preservedMarkdown")

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
                attrs[.paragraphStyle] = ps
                let box = item.checked ? "☑\t" : "☐\t"
                let line = NSMutableAttributedString(string: box, attributes: attrs)
                line.append(inlineAttributed(item.text, base: attrs))
                out.append(line)
            }
            return out

        case .codeBlock(_, let code):
            var attrs = baseAttributes(size: 13.5)
            attrs[.font] = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
            attrs[.backgroundColor] = NSColor.controlBackgroundColor
            let ps = paragraphStyle(before: 8, after: 10, lineSpacing: 2)
            attrs[.paragraphStyle] = ps
            return NSAttributedString(string: code, attributes: attrs)

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
            let parts = item.body
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let title = parts.first ?? item.body
            let bodyParas = Array(parts.dropFirst())

            var titleAttrs = baseAttributes(size: baseSize, weight: .semibold)
            let titlePS = paragraphStyle(before: index == 0 ? 4 : 10, after: bodyParas.isEmpty ? 8 : 4, lineSpacing: 3)
            titlePS.headIndent = markerWidthHint
            titlePS.firstLineHeadIndent = 0
            titlePS.tabStops = [NSTextTab(textAlignment: .left, location: markerWidthHint, options: [:])]
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
                bodyPS.headIndent = markerWidthHint + 10
                bodyPS.firstLineHeadIndent = markerWidthHint + 10
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
        let styled = MarkdownInline.attributed(markdown)
        let result = NSMutableAttributedString(attributedString: NSAttributedString(styled))
        // Apply base font/paragraph where not already specialized
        result.enumerateAttributes(in: NSRange(location: 0, length: result.length)) { attrs, range, _ in
            var merged = base
            for (k, v) in attrs {
                // Map SwiftUI-ish keys already applied via NSAttributedString bridge
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
            result.setAttributes(merged, range: range)
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
            var chunk = (attr.string as NSString).substring(with: range)
            if chunk.isEmpty { return }

            let font = attrs[.font] as? NSFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            let isBold = traits.contains(.bold) || (font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
            // NSFontDescriptor.SymbolicTraits
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
                    // Avoid double-wrapping if already linked text is plain
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
