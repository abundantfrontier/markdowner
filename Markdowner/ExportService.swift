import AppKit
import UniformTypeIdentifiers
import WebKit

enum ExportService {
    static func exportHTML(markdown: String, suggestedName: String = "Document") {
        let html = wrapHTMLDocument(body: renderBodyHTML(from: markdown), title: suggestedName)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = suggestedName.hasSuffix(".html") ? suggestedName : "\(suggestedName).html"
        panel.canCreateDirectories = true
        panel.title = "Export HTML"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try html.data(using: .utf8)?.write(to: url, options: .atomic)
            } catch {
                presentError(error, title: "Couldn’t export HTML")
            }
        }
    }

    static func exportPDF(markdown: String, suggestedName: String = "Document") {
        let html = wrapHTMLDocument(body: renderBodyHTML(from: markdown), title: suggestedName)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = suggestedName.hasSuffix(".pdf") ? suggestedName : "\(suggestedName).pdf"
        panel.canCreateDirectories = true
        panel.title = "Export PDF"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            generatePDF(html: html) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let data):
                        do {
                            try data.write(to: url, options: .atomic)
                        } catch {
                            presentError(error, title: "Couldn’t export PDF")
                        }
                    case .failure(let error):
                        presentError(error, title: "Couldn’t export PDF")
                    }
                }
            }
        }
    }

    // MARK: - Rendering

    /// Lightweight Markdown → HTML for export (GFM-ish subset + images).
    static func renderBodyHTML(from markdown: String) -> String {
        SimpleMarkdownHTML.render(markdown)
    }

    static func wrapHTMLDocument(body: String, title: String) -> String {
        let safeTitle = title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(safeTitle)</title>
        <style>
          :root { color-scheme: light dark; }
          body {
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
            line-height: 1.7;
            font-size: 16px;
            max-width: 720px;
            margin: 2.5rem auto;
            padding: 0 1.5rem 3rem;
            color: #1a1a1a;
          }
          @media (prefers-color-scheme: dark) {
            body { color: #f5f5f7; background: #1c1c1e; }
            pre, code { background: #2c2c2e !important; }
            blockquote { color: #98989d; border-color: #48484a; }
            th, td { border-color: #38383a; }
            th { background: #2c2c2e; }
            a { color: #60a5fa; }
          }
          h1,h2,h3,h4 { line-height: 1.25; letter-spacing: -0.02em; }
          a { color: #2563eb; }
          code {
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            font-size: 0.9em;
            background: #f3f4f6;
            padding: 0.12em 0.4em;
            border-radius: 4px;
          }
          pre {
            background: #f3f4f6;
            padding: 14px 16px;
            border-radius: 10px;
            overflow-x: auto;
          }
          pre code { background: transparent; padding: 0; }
          blockquote {
            margin: 0 0 1em;
            padding-left: 1em;
            border-left: 3px solid #d1d5db;
            color: #6b7280;
          }
          img { max-width: 100%; border-radius: 8px; }
          table { border-collapse: collapse; width: 100%; }
          th, td { border: 1px solid #e5e7eb; padding: 8px 12px; text-align: left; }
          th { background: #f3f4f6; }
          hr { border: none; border-top: 1px solid #e5e7eb; margin: 1.6em 0; }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    private static func generatePDF(html: String, completion: @escaping (Result<Data, Error>) -> Void) {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 1100), configuration: config)
        // Keep a strong reference until done
        PDFExportSession.start(webView: webView, html: html, completion: completion)
    }

    private static func presentError(_ error: Error, title: String) {
        let alert = NSAlert(error: error)
        alert.messageText = title
        alert.runModal()
    }
}

/// Holds a temporary WKWebView long enough to produce a PDF.
private final class PDFExportSession: NSObject, WKNavigationDelegate {
    static var active: PDFExportSession?

    private let webView: WKWebView
    private let completion: (Result<Data, Error>) -> Void
    private var finished = false

    static func start(webView: WKWebView, html: String, completion: @escaping (Result<Data, Error>) -> Void) {
        let session = PDFExportSession(webView: webView, completion: completion)
        active = session
        webView.navigationDelegate = session
        webView.loadHTMLString(html, baseURL: nil)
    }

    private init(webView: WKWebView, completion: @escaping (Result<Data, Error>) -> Void) {
        self.webView = webView
        self.completion = completion
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Allow layout/images a beat to settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.createPDF()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    private func createPDF() {
        let config = WKPDFConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter
        webView.createPDF(configuration: config) { [weak self] result in
            switch result {
            case .success(let data):
                self?.finish(.success(data))
            case .failure(let error):
                self?.finish(.failure(error))
            }
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard !finished else { return }
        finished = true
        completion(result)
        PDFExportSession.active = nil
    }
}

/// Simple offline Markdown → HTML for export.
enum SimpleMarkdownHTML {
    static func render(_ markdown: String) -> String {
        var text = markdown.replacingOccurrences(of: "\r\n", with: "\n")

        // Fenced code blocks
        text = replaceFencedCode(text)

        // Headings
        text = replaceLineAnchored(text, pattern: #"^######\s+(.+)$"#, template: "<h6>$1</h6>")
        text = replaceLineAnchored(text, pattern: #"^#####\s+(.+)$"#, template: "<h5>$1</h5>")
        text = replaceLineAnchored(text, pattern: #"^####\s+(.+)$"#, template: "<h4>$1</h4>")
        text = replaceLineAnchored(text, pattern: #"^###\s+(.+)$"#, template: "<h3>$1</h3>")
        text = replaceLineAnchored(text, pattern: #"^##\s+(.+)$"#, template: "<h2>$1</h2>")
        text = replaceLineAnchored(text, pattern: #"^#\s+(.+)$"#, template: "<h1>$1</h1>")

        // HR
        text = replaceLineAnchored(text, pattern: #"^(-{3,}|\*{3,}|_{3,})\s*$"#, template: "<hr>")

        // Blockquotes (simple)
        text = replaceLineAnchored(text, pattern: #"^>\s?(.*)$"#, template: "<blockquote>$1</blockquote>")

        // Images then links
        text = replaceRegex(text, pattern: #"!\[([^\]]*)\]\(([^)\s]+)(?:\s+\"([^\"]*)\")?\)"#) { m in
            let alt = escape(m[1])
            let src = m[2]
            return "<img src=\"\(escapeAttr(src))\" alt=\"\(alt)\">"
        }
        text = replaceRegex(text, pattern: #"\[([^\]]+)\]\(([^)\s]+)(?:\s+\"([^\"]*)\")?\)"#) { m in
            "<a href=\"\(escapeAttr(m[2]))\">\(escape(m[1]))</a>"
        }

        // Inline code (avoid already-tagged)
        text = replaceRegex(text, pattern: #"`([^`]+)`"#) { m in
            "<code>\(escape(m[1]))</code>"
        }

        // Bold / italic / strike
        text = replaceRegex(text, pattern: #"\*\*([^*]+)\*\*"#) { m in "<strong>\(m[1])</strong>" }
        text = replaceRegex(text, pattern: #"__([^_]+)__"#) { m in "<strong>\(m[1])</strong>" }
        text = replaceRegex(text, pattern: #"(?<!\*)\*([^*]+)\*(?!\*)"#) { m in "<em>\(m[1])</em>" }
        text = replaceRegex(text, pattern: #"(?<!_)_([^_]+)_(?!_)"#) { m in "<em>\(m[1])</em>" }
        text = replaceRegex(text, pattern: #"~~([^~]+)~~"#) { m in "<s>\(m[1])</s>" }

        // Task / unordered / ordered lists (line based, then wrap)
        var lines = text.components(separatedBy: "\n")
        var out: [String] = []
        var listBuffer: [String] = []
        var listType: String? // ul | ol

        func flushList() {
            guard let type = listType, !listBuffer.isEmpty else { return }
            out.append("<\(type)>")
            out.append(contentsOf: listBuffer)
            out.append("</\(type)>")
            listBuffer.removeAll()
            listType = nil
        }

        for line in lines {
            if let m = match(line, #"^[-*+]\s+\[([ xX])\]\s+(.*)$"#) {
                if listType != "ul" { flushList(); listType = "ul" }
                let checked = m[1].lowercased() == "x" ? " checked" : ""
                listBuffer.append("<li><input type=\"checkbox\" disabled\(checked)> \(m[2])</li>")
            } else if let m = match(line, #"^[-*+]\s+(.*)$"#) {
                if listType != "ul" { flushList(); listType = "ul" }
                listBuffer.append("<li>\(m[1])</li>")
            } else if let m = match(line, #"^\d+\.\s+(.*)$"#) {
                if listType != "ol" { flushList(); listType = "ol" }
                listBuffer.append("<li>\(m[1])</li>")
            } else {
                flushList()
                out.append(line)
            }
        }
        flushList()

        // Paragraphs: wrap plain runs
        var htmlParts: [String] = []
        var para: [String] = []
        func flushPara() {
            let joined = para.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            para.removeAll()
            guard !joined.isEmpty else { return }
            if joined.hasPrefix("<") {
                htmlParts.append(joined)
            } else {
                htmlParts.append("<p>\(joined)</p>")
            }
        }

        for line in out {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushPara()
                continue
            }
            if trimmed.hasPrefix("<h") || trimmed.hasPrefix("<ul") || trimmed.hasPrefix("<ol")
                || trimmed.hasPrefix("<pre") || trimmed.hasPrefix("<blockquote")
                || trimmed.hasPrefix("<hr") || trimmed.hasPrefix("</")
                || trimmed.hasPrefix("<li") || trimmed.hasPrefix("<table") {
                flushPara()
                htmlParts.append(trimmed)
            } else {
                para.append(trimmed)
            }
        }
        flushPara()

        return htmlParts.joined(separator: "\n")
    }

    private static func replaceFencedCode(_ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"```([^\n]*)\n([\s\S]*?)```"#, options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        var result = ""
        var last = text.startIndex
        re.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, let full = Range(match.range, in: text),
                  let codeRange = Range(match.range(at: 2), in: text) else { return }
            result += text[last..<full.lowerBound]
            let code = escape(String(text[codeRange]))
            result += "<pre><code>\(code)</code></pre>"
            last = full.upperBound
        }
        result += text[last...]
        return result
    }

    private static func replaceLineAnchored(_ text: String, pattern: String, template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    private static func replaceRegex(_ text: String, pattern: String, replacer: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        var result = ""
        var last = text.startIndex
        re.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, let full = Range(match.range, in: text) else { return }
            result += text[last..<full.lowerBound]
            var groups: [String] = [String(text[full])]
            for i in 1..<match.numberOfRanges {
                if let r = Range(match.range(at: i), in: text) {
                    groups.append(String(text[r]))
                } else {
                    groups.append("")
                }
            }
            result += replacer(groups)
            last = full.upperBound
        }
        result += text[last...]
        return result
    }

    private static func match(_ line: String, _ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let m = re.firstMatch(in: line, options: [], range: range) else { return nil }
        var groups: [String] = []
        for i in 0..<m.numberOfRanges {
            if let r = Range(m.range(at: i), in: line) {
                groups.append(String(line[r]))
            } else {
                groups.append("")
            }
        }
        return groups
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttr(_ s: String) -> String {
        escape(s).replacingOccurrences(of: "\"", with: "&quot;")
    }
}
