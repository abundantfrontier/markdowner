import SwiftUI

/// Renders Markdown as a spaced document (not a single wall of text).
struct MarkdownDocumentView: View {
    let markdown: String
    /// Called when the user wants to edit (e.g. double-click the document).
    var onRequestEdit: (() -> Void)? = nil
    /// When false, the caller provides scrolling (e.g. NSScrollView for split sync).
    var embedsOwnScroll: Bool = true

    var body: some View {
        Group {
            if embedsOwnScroll {
                ScrollView {
                    documentBody
                }
            } else {
                documentBody
            }
        }
        .environment(\.openURL, LinkHandling.openURLAction)
        .contextMenu {
            Button("Find…") {
                NotificationCenter.default.post(
                    name: .markdownerShowFind,
                    object: nil,
                    userInfo: ["replace": false]
                )
            }
        }
    }

    private var documentBody: some View {
        let blocks = MarkdownBlockParser.parse(markdown)
        return LazyVStack(alignment: .leading, spacing: 0) {
            if blocks.isEmpty {
                Text("Open a file from the sidebar, or switch to Source to start writing.")
                    .foregroundStyle(.tertiary)
                    .padding(.top, 40)
            } else {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                        .padding(.bottom, block.bottomSpacing)
                }
            }
        }
        .frame(maxWidth: 740, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 48)
        .padding(.top, 36)
        .padding(.bottom, 80)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onRequestEdit?()
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level):
            MarkdownInline.text(block.text)
                .font(headingFont(level))
                .fontWeight(level <= 2 ? .bold : .semibold)
                .foregroundStyle(.primary)
                .padding(.top, headingTop(level))
                .fixedSize(horizontal: false, vertical: true)

        case .paragraph:
            MarkdownInline.text(block.text)
                .font(.system(size: 17))
                .foregroundStyle(.primary)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)

        case .blockquote:
            HStack(alignment: .top, spacing: 0) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 3)
                    .padding(.trailing, 14)
                MarkdownInline.text(block.text)
                    .font(.system(size: 16.5))
                    .foregroundStyle(.secondary)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)

        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    unorderedListItemView(text: item)
                }
            }

        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    orderedListItemView(number: item.number, text: item.text)
                }
            }

        case .taskList(let items):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    let parts = splitListItemBody(item.text)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: item.checked ? "checkmark.square.fill" : "square")
                                .foregroundStyle(item.checked ? Color.accentColor : .secondary)
                                .font(.system(size: 16))
                                .frame(width: 20, alignment: .center)
                            MarkdownInline.text(parts.title)
                                .font(.system(size: 17, weight: .semibold))
                                .strikethrough(item.checked, color: .secondary)
                                .foregroundStyle(item.checked ? .secondary : .primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(Array(parts.body.enumerated()), id: \.offset) { _, para in
                            MarkdownInline.text(para)
                                .font(.system(size: 16.5))
                                .foregroundStyle(item.checked ? .secondary : .primary)
                                .lineSpacing(5)
                                .padding(.leading, 30)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

        case .codeBlock(let language, let code):
            VStack(alignment: .leading, spacing: 0) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                }
                Text(code)
                    .font(.system(size: 13.5, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, language == nil || language?.isEmpty == true ? 14 : 8)
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )

        case .horizontalRule:
            Divider()
                .padding(.vertical, 12)

        case .table(let headers, let rows):
            // Use equal flexible columns so multi-line cells wrap cleanly.
            let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(0..<columnCount, id: \.self) { col in
                        let header = col < headers.count ? headers[col] : ""
                        MarkdownInline.text(header)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor))

                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(0..<columnCount, id: \.self) { col in
                            let cell = col < row.count ? row[col] : ""
                            MarkdownInline.text(cell)
                                .font(.system(size: 14))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                    }
                    .background(rowIndex.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.04))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 32, weight: .bold)
        case 2: return .system(size: 26, weight: .bold)
        case 3: return .system(size: 21, weight: .semibold)
        case 4: return .system(size: 18, weight: .semibold)
        default: return .system(size: 16, weight: .semibold)
        }
    }

    private func headingTop(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 8
        case 2: return 20
        case 3: return 16
        default: return 12
        }
    }

    /// Title line + following body paragraphs for a list item.
    private func splitListItemBody(_ text: String) -> (title: String, body: [String]) {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return ("", []) }

        // Prefer blank-line paragraph splits; otherwise first line is title.
        let paragraphs = normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if paragraphs.count >= 2 {
            return (paragraphs[0], Array(paragraphs.dropFirst()))
        }

        let lines = normalized.components(separatedBy: "\n")
        if lines.count >= 2 {
            let title = lines[0].trimmingCharacters(in: .whitespaces)
            let rest = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if rest.isEmpty { return (title, []) }
            // Split rest into paragraphs on blank lines
            let body = rest
                .components(separatedBy: "\n\n")
                .map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if body.isEmpty {
                let soft = lines.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                return (title, soft)
            }
            return (title, body)
        }
        return (normalized, [])
    }

    @ViewBuilder
    private func orderedListItemView(number: Int, text: String) -> some View {
        let parts = splitListItemBody(text)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(number).")
                    .font(.system(size: 17, weight: .bold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 28, alignment: .trailing)
                MarkdownInline.text(parts.title)
                    .font(.system(size: 17, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(parts.body.enumerated()), id: \.offset) { _, para in
                MarkdownInline.text(para)
                    .font(.system(size: 16.5))
                    .foregroundStyle(.primary)
                    .lineSpacing(5)
                    .padding(.leading, 38)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func unorderedListItemView(text: String) -> some View {
        let parts = splitListItemBody(text)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("•")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 18, alignment: .center)
                MarkdownInline.text(parts.title)
                    .font(.system(size: 17, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(parts.body.enumerated()), id: \.offset) { _, para in
                MarkdownInline.text(para)
                    .font(.system(size: 16.5))
                    .lineSpacing(5)
                    .padding(.leading, 28)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Model

struct MarkdownBlock {
    enum Kind {
        case heading(level: Int)
        case paragraph
        case blockquote
        case unorderedList(items: [String])
        case orderedList(items: [(number: Int, text: String)])
        case taskList(items: [(checked: Bool, text: String)])
        case codeBlock(language: String?, code: String)
        case horizontalRule
        case table(headers: [String], rows: [[String]])
    }

    let kind: Kind
    let text: String

    var bottomSpacing: CGFloat {
        switch kind {
        case .heading(let level):
            return level == 1 ? 16 : 12
        case .paragraph:
            return 16
        case .blockquote:
            return 18
        case .unorderedList, .orderedList, .taskList:
            return 18
        case .codeBlock:
            return 20
        case .horizontalRule:
            return 8
        case .table:
            return 20
        }
    }
}

// MARK: - Parser

enum MarkdownBlockParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = normalized.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip blank lines between blocks
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Fenced code block
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                i += 1
                var codeLines: [String] = []
                while i < lines.count {
                    let l = lines[i]
                    if l.trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        i += 1
                        break
                    }
                    codeLines.append(l)
                    i += 1
                }
                // Drop trailing empty line inside fence for cleaner display
                while codeLines.last?.isEmpty == true { codeLines.removeLast() }
                blocks.append(
                    MarkdownBlock(
                        kind: .codeBlock(
                            language: language.isEmpty ? nil : language,
                            code: codeLines.joined(separator: "\n")
                        ),
                        text: ""
                    )
                )
                continue
            }

            // Horizontal rule
            if isHorizontalRule(trimmed) {
                blocks.append(MarkdownBlock(kind: .horizontalRule, text: ""))
                i += 1
                continue
            }

            // Heading
            if let heading = parseHeading(trimmed) {
                blocks.append(MarkdownBlock(kind: .heading(level: heading.level), text: heading.text))
                i += 1
                continue
            }

            // Table (header + separator + rows)
            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                let headers = splitTableRow(trimmed)
                i += 2
                var rows: [[String]] = []
                while i < lines.count {
                    let rowLine = lines[i].trimmingCharacters(in: .whitespaces)
                    if rowLine.isEmpty || !rowLine.contains("|") { break }
                    rows.append(splitTableRow(rowLine))
                    i += 1
                }
                blocks.append(MarkdownBlock(kind: .table(headers: headers, rows: rows), text: ""))
                continue
            }

            // Blockquote (consecutive > lines)
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if l.hasPrefix(">") {
                        var content = String(l.dropFirst())
                        if content.hasPrefix(" ") { content = String(content.dropFirst()) }
                        quoteLines.append(content)
                        i += 1
                    } else if l.isEmpty {
                        // allow single blank inside quote
                        if i + 1 < lines.count, lines[i + 1].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                            quoteLines.append("")
                            i += 1
                        } else {
                            break
                        }
                    } else {
                        break
                    }
                }
                blocks.append(
                    MarkdownBlock(
                        kind: .blockquote,
                        text: quoteLines.joined(separator: "\n")
                    )
                )
                continue
            }

            // Task list
            if isTaskListItem(trimmed) {
                var items: [(Bool, String)] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if let task = parseTaskItem(l) {
                        items.append(task)
                        i += 1
                    } else if l.isEmpty {
                        break
                    } else {
                        break
                    }
                }
                blocks.append(
                    MarkdownBlock(
                        kind: .taskList(items: items.map { (checked: $0.0, text: $0.1) }),
                        text: ""
                    )
                )
                continue
            }

            // Unordered list (title line + following body until next block marker)
            if isUnorderedListItem(trimmed) {
                var items: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if let item = parseUnorderedItem(l) {
                        i += 1
                        let body = collectListItemBody(lines: lines, index: &i)
                        items.append(mergeListTitle(item, body: body))
                    } else {
                        break
                    }
                }
                blocks.append(MarkdownBlock(kind: .unorderedList(items: items), text: ""))
                continue
            }

            // Ordered list — keep source numbers; attach following paragraphs to each item
            if isOrderedListItem(trimmed) {
                var items: [(number: Int, text: String)] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if let item = parseOrderedItem(l) {
                        i += 1
                        let body = collectListItemBody(lines: lines, index: &i)
                        items.append((item.number, mergeListTitle(item.text, body: body)))
                    } else {
                        break
                    }
                }
                blocks.append(MarkdownBlock(kind: .orderedList(items: items), text: ""))
                continue
            }

            // Paragraph (gather until blank line or new block)
            var paraLines: [String] = [trimmed]
            i += 1
            while i < lines.count {
                let l = lines[i]
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if t.hasPrefix("#")
                    || t.hasPrefix("```")
                    || t.hasPrefix("~~~")
                    || t.hasPrefix(">")
                    || isHorizontalRule(t)
                    || isUnorderedListItem(t)
                    || isOrderedListItem(t)
                    || isTaskListItem(t)
                    || (t.contains("|") && i + 1 < lines.count && isTableSeparator(lines[i + 1])) {
                    break
                }
                paraLines.append(t)
                i += 1
            }
            blocks.append(
                MarkdownBlock(
                    kind: .paragraph,
                    text: paraLines.joined(separator: " ")
                )
            )
        }

        return blocks
    }

    // MARK: - Helpers

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6 else { return nil }
        guard line.count == level || line[line.index(line.startIndex, offsetBy: level)] == " " else {
            return nil
        }
        let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
        return (level, String(text))
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let s = line.replacingOccurrences(of: " ", with: "")
        return (s.allSatisfy { $0 == "-" } && s.count >= 3)
            || (s.allSatisfy { $0 == "*" } && s.count >= 3)
            || (s.allSatisfy { $0 == "_" } && s.count >= 3)
    }

    private static func isUnorderedListItem(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
    }

    private static func parseUnorderedItem(_ line: String) -> String? {
        if line.hasPrefix("- ") { return String(line.dropFirst(2)) }
        if line.hasPrefix("* ") { return String(line.dropFirst(2)) }
        if line.hasPrefix("+ ") { return String(line.dropFirst(2)) }
        return nil
    }

    private static func isOrderedListItem(_ line: String) -> Bool {
        // e.g. 1. item
        guard let dot = line.firstIndex(of: ".") else { return false }
        let num = line[line.startIndex..<dot]
        guard !num.isEmpty, num.allSatisfy(\.isNumber) else { return false }
        let after = line[dot...].dropFirst()
        return after.first == " "
    }

    private static func parseOrderedItem(_ line: String) -> (number: Int, text: String)? {
        guard let dot = line.firstIndex(of: ".") else { return nil }
        let numStr = line[line.startIndex..<dot]
        guard !numStr.isEmpty, numStr.allSatisfy(\.isNumber), let number = Int(numStr) else { return nil }
        let text = line[dot...].dropFirst().trimmingCharacters(in: .whitespaces)
        return (number, text)
    }

    /// Gather non-marker lines that belong under the current list item.
    /// Stops before the next list item, heading, rule, code fence, table, or blockquote.
    private static func collectListItemBody(lines: [String], index i: inout Int) -> [String] {
        var body: [String] = []
        var pendingBlanks = 0

        while i < lines.count {
            let raw = lines[i]
            let t = raw.trimmingCharacters(in: .whitespaces)

            if t.isEmpty {
                pendingBlanks += 1
                i += 1
                // Allow blank lines inside an item; stop only if followed by a new block
                // (handled when we see the next non-empty line).
                continue
            }

            if t.hasPrefix("#")
                || t.hasPrefix("```")
                || t.hasPrefix("~~~")
                || t.hasPrefix(">")
                || isHorizontalRule(t)
                || isUnorderedListItem(t)
                || isOrderedListItem(t)
                || isTaskListItem(t)
                || (t.contains("|") && i + 1 < lines.count && isTableSeparator(lines[i + 1])) {
                // Don't consume this line — leave it for the outer parser.
                // Rewind past trailing blanks so outer parser sees the blank separation.
                if pendingBlanks > 0 {
                    i -= pendingBlanks
                }
                break
            }

            if pendingBlanks > 0 {
                body.append("") // paragraph break inside item
                pendingBlanks = 0
            }
            body.append(t)
            i += 1
        }
        return body
    }

    private static func mergeListTitle(_ title: String, body: [String]) -> String {
        if body.isEmpty { return title }
        var parts: [String] = [title]
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty {
                parts.append(paragraph.joined(separator: " "))
                paragraph.removeAll()
            }
        }
        for line in body {
            if line.isEmpty {
                flush()
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return parts.joined(separator: "\n\n")
    }

    private static func isTaskListItem(_ line: String) -> Bool {
        line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ")
            || line.hasPrefix("* [ ] ") || line.hasPrefix("* [x] ") || line.hasPrefix("* [X] ")
    }

    private static func parseTaskItem(_ line: String) -> (Bool, String)? {
        let prefixes = [
            ("- [x] ", true), ("- [X] ", true), ("- [ ] ", false),
            ("* [x] ", true), ("* [X] ", true), ("* [ ] ", false),
        ]
        for (prefix, checked) in prefixes {
            if line.hasPrefix(prefix) {
                return (checked, String(line.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") else { return false }
        return t.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s = String(s.dropFirst()) }
        if s.hasSuffix("|") { s = String(s.dropLast()) }
        return s.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
