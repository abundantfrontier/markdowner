import SwiftUI

/// Renders inline Markdown reliably, including nested patterns like
/// `**[`path`](url)**` that Foundation's AttributedString often leaves raw.
enum MarkdownInline {
    static func text(_ source: String) -> some View {
        Text(attributed(source))
            .textSelection(.enabled)
    }

    static func attributed(_ source: String) -> AttributedString {
        var result = AttributedString()
        var i = source.startIndex

        while i < source.endIndex {
            // Bold link with optional code: **[ ... ](url)**  or **[`code`](url)**
            // Capture groups (after drop full match): 0=tick?, 1=label, 2=url
            if let match = matchPrefix(
                source, from: i,
                pattern: #"^\*\*\[(`?)([^\]]+?)\1\]\(([^)\s]+)\)\*\*"#
            ), match.groups.count >= 3 {
                let codeFence = match.groups[0]
                let label = match.groups[1]
                let url = match.groups[2]
                result.append(linkRun(label: label, url: url, bold: true, code: !codeFence.isEmpty))
                i = match.end
                continue
            }

            // Link with code label: [`code`](url)
            if let match = matchPrefix(
                source, from: i,
                pattern: #"^\[`([^`]+)`\]\(([^)\s]+)\)"#
            ), match.groups.count >= 2 {
                result.append(linkRun(label: match.groups[0], url: match.groups[1], bold: false, code: true))
                i = match.end
                continue
            }

            // Normal link: [text](url)
            if let match = matchPrefix(
                source, from: i,
                pattern: #"^\[([^\]]+)\]\(([^)\s]+)\)"#
            ), match.groups.count >= 2 {
                // Recursively style link label (may contain `code` or **bold**)
                var labelAttr = attributed(match.groups[0])
                if let u = makeURL(match.groups[1]) {
                    labelAttr.link = u
                    labelAttr.foregroundColor = .accentColor
                    labelAttr.underlineStyle = .single
                }
                result.append(labelAttr)
                i = match.end
                continue
            }

            // Bold **...**
            if let match = matchPrefix(source, from: i, pattern: #"^\*\*(.+?)\*\*"#),
               match.groups.count >= 1 {
                var chunk = attributed(match.groups[0])
                chunk.inlinePresentationIntent = .stronglyEmphasized
                result.append(chunk)
                i = match.end
                continue
            }

            // Bold __...__
            if let match = matchPrefix(source, from: i, pattern: #"^__(.+?)__"#),
               match.groups.count >= 1 {
                var chunk = attributed(match.groups[0])
                chunk.inlinePresentationIntent = .stronglyEmphasized
                result.append(chunk)
                i = match.end
                continue
            }

            // Italic *...* (not **)
            if source[i] == "*", !source[i...].hasPrefix("**"),
               let match = matchPrefix(source, from: i, pattern: #"^\*([^*]+?)\*"#),
               match.groups.count >= 1 {
                var chunk = attributed(match.groups[0])
                chunk.inlinePresentationIntent = .emphasized
                result.append(chunk)
                i = match.end
                continue
            }

            // Italic _..._
            if source[i] == "_", !source[i...].hasPrefix("__"),
               let match = matchPrefix(source, from: i, pattern: #"^_([^_]+?)_"#),
               match.groups.count >= 1 {
                var chunk = attributed(match.groups[0])
                chunk.inlinePresentationIntent = .emphasized
                result.append(chunk)
                i = match.end
                continue
            }

            // Strikethrough ~~...~~
            if let match = matchPrefix(source, from: i, pattern: #"^~~(.+?)~~"#),
               match.groups.count >= 1 {
                var chunk = attributed(match.groups[0])
                chunk.inlinePresentationIntent = .strikethrough
                result.append(chunk)
                i = match.end
                continue
            }

            // Inline code `...`
            if let match = matchPrefix(source, from: i, pattern: #"^`([^`]+)`"#),
               match.groups.count >= 1 {
                var chunk = AttributedString(match.groups[0])
                chunk.font = .system(.body, design: .monospaced).weight(.medium)
                chunk.backgroundColor = Color.primary.opacity(0.08)
                result.append(chunk)
                i = match.end
                continue
            }

            // Autolink-ish bare URL
            if let match = matchPrefix(
                source, from: i,
                pattern: #"^(https?://[^\s<]+[^\s<\.,:;!?\)\]])"#
            ), match.groups.count >= 1 {
                var chunk = AttributedString(match.groups[0])
                if let u = URL(string: match.groups[0]) {
                    chunk.link = u
                    chunk.foregroundColor = .accentColor
                }
                result.append(chunk)
                i = match.end
                continue
            }

            // Plain character
            result.append(AttributedString(String(source[i])))
            i = source.index(after: i)
        }

        return result
    }

    private static func linkRun(label: String, url: String, bold: Bool, code: Bool) -> AttributedString {
        var chunk = AttributedString(label)
        if code {
            chunk.font = .system(.body, design: .monospaced).weight(bold ? .bold : .medium)
            chunk.backgroundColor = Color.primary.opacity(0.08)
        } else if bold {
            chunk.inlinePresentationIntent = .stronglyEmphasized
        }
        chunk.link = makeURL(url)
        chunk.foregroundColor = .accentColor
        chunk.underlineStyle = .single
        return chunk
    }

    /// Prefer absolute web URLs; resolve multi-segment relative paths against the document folder.
    private static func makeURL(_ string: String) -> URL? {
        LinkHandling.urlFromMarkdownLink(string)
    }

    private struct Match {
        let groups: [String]
        let end: String.Index
    }

    private static func matchPrefix(_ source: String, from: String.Index, pattern: String) -> Match? {
        let slice = String(source[from...])
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(slice.startIndex..., in: slice)
        guard let m = re.firstMatch(in: slice, options: [], range: range), m.range.location == 0 else {
            return nil
        }
        var groups: [String] = []
        for i in 0..<m.numberOfRanges {
            if let r = Range(m.range(at: i), in: slice) {
                groups.append(String(slice[r]))
            } else {
                groups.append("")
            }
        }
        // groups[0] is full match; capture groups start at 1
        let fullLen = m.range.length
        let end = source.index(from, offsetBy: fullLen)
        return Match(groups: Array(groups.dropFirst()), end: end)
    }
}
