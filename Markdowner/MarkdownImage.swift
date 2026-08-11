import AppKit
import UniformTypeIdentifiers

/// Load, display, and serialize Markdown images (`![alt](src)`).
enum MarkdownImage {
    static let srcKey = NSAttributedString.Key("com.markdowner.imageSrc")
    static let altKey = NSAttributedString.Key("com.markdowner.imageAlt")

    static let maxDisplayWidth: CGFloat = 640
    static let maxEmbedBytes = 2_500_000 // ~2.5 MB raw; larger → copy to assets when possible

    // MARK: - Parse

    /// Regex-friendly image match at the start of `slice`. Groups: alt, src.
    static func matchImagePrefix(_ slice: String) -> (alt: String, src: String, end: String.Index)? {
        guard slice.hasPrefix("![") else { return nil }
        guard let re = try? NSRegularExpression(
            pattern: #"^!\[([^\]]*)\]\(([^)\s]+)(?:\s+\"([^\"]*)\")?\)"#,
            options: []
        ) else { return nil }
        let range = NSRange(slice.startIndex..., in: slice)
        guard let m = re.firstMatch(in: slice, options: [], range: range), m.range.location == 0,
              m.numberOfRanges >= 3,
              let altR = Range(m.range(at: 1), in: slice),
              let srcR = Range(m.range(at: 2), in: slice),
              let fullR = Range(m.range, in: slice)
        else { return nil }
        return (String(slice[altR]), String(slice[srcR]), fullR.upperBound)
    }

    // MARK: - Load

    static func loadNSImage(src: String) -> NSImage? {
        let trimmed = src.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("data:") {
            return loadDataURL(trimmed)
        }
        if let url = resolveFileURL(trimmed) {
            // Sandbox: re-assert Open Folder scopes before reading sibling assets.
            SecurityScopedRoots.accessForReading(url)
            if let img = NSImage(contentsOf: url), img.isValid, img.size.width > 0 {
                return img
            }
            // Retry via Data (sometimes more reliable with security scopes)
            if let data = try? Data(contentsOf: url), let img = NSImage(data: data), img.isValid {
                return img
            }
            return nil
        }
        // Remote http(s) — no network client entitlement; skip.
        return nil
    }

    static func resolveFileURL(_ src: String) -> URL? {
        if src.hasPrefix("file:"), let u = URL(string: src) { return u }
        if src.hasPrefix("/") {
            return URL(fileURLWithPath: src)
        }
        if let resolved = LinkHandling.resolvePathString(src) {
            return resolved
        }
        if let base = LinkHandling.documentDirectory {
            return base.appendingPathComponent(src)
        }
        if let doc = LinkHandling.currentDocumentURL {
            return doc.deletingLastPathComponent().appendingPathComponent(src)
        }
        return nil
    }

    private static func loadDataURL(_ src: String) -> NSImage? {
        guard let parsed = parseDataURL(src) else { return nil }
        return NSImage(data: parsed.data)
    }

    static func parseDataURL(_ src: String) -> (mime: String, data: Data)? {
        // data:image/png;base64,....
        guard src.hasPrefix("data:") else { return nil }
        let rest = String(src.dropFirst(5))
        guard let comma = rest.firstIndex(of: ",") else { return nil }
        let meta = String(rest[rest.startIndex..<comma])
        let payload = String(rest[rest.index(after: comma)...])
        let mime = meta.split(separator: ";").first.map(String.init) ?? "image/png"
        let isBase64 = meta.lowercased().contains("base64")
        if isBase64 {
            guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]) else {
                return nil
            }
            return (mime, data)
        }
        if let data = payload.removingPercentEncoding?.data(using: .utf8) {
            return (mime, data)
        }
        return nil
    }

    // MARK: - Attachment (Write mode)

    static func attachmentString(alt: String, src: String, base: [NSAttributedString.Key: Any]) -> NSAttributedString {
        guard let image = loadNSImage(src: src) else {
            // Do NOT attach a file: link — clicking would call NSWorkspace.open and show
            // “Markdowner does not have permission to open sample.png” under sandbox.
            let label = alt.isEmpty ? "image" : alt
            var attrs = base
            attrs[.foregroundColor] = NSColor.secondaryLabelColor
            let hint: String
            if src.hasPrefix("data:") {
                hint = "🖼 \(label) (couldn’t decode)"
            } else if src.hasPrefix("http://") || src.hasPrefix("https://") {
                hint = "🖼 \(label) (remote image)"
            } else {
                hint = "🖼 \(label) — open the document’s folder (File → Open Folder…) to show images"
            }
            let md = "![\(alt)](\(src))"
            let s = NSMutableAttributedString(string: hint, attributes: attrs)
            let range = NSRange(location: 0, length: s.length)
            s.addAttribute(preservedSourceKey, value: md, range: range)
            s.addAttribute(srcKey, value: src, range: range)
            s.addAttribute(altKey, value: alt, range: range)
            return s
        }

        let display = presentationImage(image, maxWidth: maxDisplayWidth)
        let attachment = NSTextAttachment()
        attachment.image = display
        // Bounds for layout (points) — never use raw 1×1 so tiny assets stay visible.
        let size = displaySize(for: display, maxWidth: maxDisplayWidth)
        attachment.bounds = CGRect(x: 0, y: -4, width: size.width, height: size.height)

        let attr = NSMutableAttributedString(attachment: attachment)
        let range = NSRange(location: 0, length: attr.length)
        attr.addAttribute(srcKey, value: src, range: range)
        attr.addAttribute(altKey, value: alt, range: range)
        attr.addAttribute(preservedSourceKey, value: markdown(alt: alt, src: src), range: range)
        // Carry paragraph style / font baseline from base where useful
        if let ps = base[.paragraphStyle] {
            attr.addAttribute(.paragraphStyle, value: ps, range: range)
        }
        return attr
    }

    /// Same key as tables — exact Markdown for round-trip.
    private static var preservedSourceKey: NSAttributedString.Key {
        MarkdownRichText.preservedMarkdownKey
    }

    /// Pixel/point size for layout. Upscales tiny images (e.g. 1×1 `dot.png`) so they remain visible.
    static func displaySize(for image: NSImage, maxWidth: CGFloat) -> NSSize {
        var size = intrinsicSize(image)
        let minSide: CGFloat = 28
        if size.width < minSide && size.height < minSide {
            let scale = minSide / max(max(size.width, size.height), 0.001)
            size = NSSize(width: size.width * scale, height: size.height * scale)
        }
        if size.width > maxWidth, size.width > 0 {
            let scale = maxWidth / size.width
            size = NSSize(width: maxWidth, height: max(1, size.height * scale))
        }
        return size
    }

    static func intrinsicSize(_ image: NSImage) -> NSSize {
        var size = image.size
        if size.width <= 0 || size.height <= 0 {
            if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
                size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            } else if let rep = image.representations.first {
                size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            }
        }
        if size.width <= 0 { size.width = 28 }
        if size.height <= 0 { size.height = 28 }
        return size
    }

    /// Scale for on-screen presentation (downscale large; upscale tiny).
    static func presentationImage(_ image: NSImage, maxWidth: CGFloat) -> NSImage {
        let target = displaySize(for: image, maxWidth: maxWidth)
        let source = intrinsicSize(image)
        // Already a sensible size and within max width — keep original.
        if abs(target.width - source.width) < 0.5, abs(target.height - source.height) < 0.5 {
            return image
        }
        return redraw(image, to: target)
    }

    static func scaledImage(_ image: NSImage, maxWidth: CGFloat) -> NSImage {
        presentationImage(image, maxWidth: maxWidth)
    }

    private static func redraw(_ image: NSImage, to newSize: NSSize) -> NSImage {
        let pixelW = max(Int(newSize.width.rounded(.up)), 1)
        let pixelH = max(Int(newSize.height.rounded(.up)), 1)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelW,
            pixelsHigh: pixelH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return image }
        rep.size = newSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = newSize.width > intrinsicSize(image).width
            ? .none // keep tiny pixel art / dots crisp when upscaled
            : .high
        image.draw(
            in: NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: intrinsicSize(image)),
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: newSize)
        out.addRepresentation(rep)
        return out
    }

    static func markdown(alt: String, src: String) -> String {
        "![\(alt)](\(src))"
    }

    // MARK: - Insert policy (drag / paste / panel)

    enum InsertMode {
        /// Copy file next to the document under `assets/` and use a relative path.
        case copyToAssets
        /// Embed as data URL (self-contained; avoid for large files).
        case embedDataURL
    }

    /// Build Markdown snippet for a user-chosen image file.
    static func markdownSnippet(
        forFileURL url: URL,
        mode: InsertMode = .copyToAssets
    ) -> String? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let alt = url.deletingPathExtension().lastPathComponent

        switch mode {
        case .copyToAssets:
            if let rel = try? copyIntoAssets(from: url) {
                return "\n\n\(markdown(alt: alt, src: rel))\n\n"
            }
            // Fall through to embed if no document directory yet
            fallthrough
        case .embedDataURL:
            guard let data = try? Data(contentsOf: url) else { return nil }
            if data.count > maxEmbedBytes, mode == .embedDataURL {
                // Still embed but warn via NSLog; UI can alert later
                NSLog("Markdowner: embedding large image (%d bytes)", data.count)
            }
            let mime = mimeType(for: url)
            let b64 = data.base64EncodedString()
            return "\n\n\(markdown(alt: alt, src: "data:\(mime);base64,\(b64)"))\n\n"
        }
    }

    static func markdownSnippet(forImage image: NSImage, preferredName: String = "pasted") -> String? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:])
        else { return nil }

        if let rel = try? writeDataIntoAssets(data, preferredName: preferredName, ext: "png") {
            return "\n\n\(markdown(alt: preferredName, src: rel))\n\n"
        }
        let b64 = data.base64EncodedString()
        return "\n\n\(markdown(alt: preferredName, src: "data:image/png;base64,\(b64)"))\n\n"
    }

    static func copyIntoAssets(from source: URL) throws -> String {
        guard let base = documentFolderForAssets() else {
            throw ImageError.noDocumentFolder
        }
        let assets = base.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

        var name = source.lastPathComponent
        if name.isEmpty { name = "image.png" }
        var dest = assets.appendingPathComponent(name)
        var n = 1
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = assets.appendingPathComponent("\(stem)-\(n).\(ext)")
            n += 1
        }
        try FileManager.default.copyItem(at: source, to: dest)
        return "assets/\(dest.lastPathComponent)"
    }

    static func writeDataIntoAssets(_ data: Data, preferredName: String, ext: String) throws -> String {
        guard let base = documentFolderForAssets() else {
            throw ImageError.noDocumentFolder
        }
        let assets = base.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        var stem = preferredName
        if stem.isEmpty { stem = "image" }
        var dest = assets.appendingPathComponent("\(stem).\(ext)")
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = assets.appendingPathComponent("\(stem)-\(n).\(ext)")
            n += 1
        }
        try data.write(to: dest, options: .atomic)
        return "assets/\(dest.lastPathComponent)"
    }

    private static func documentFolderForAssets() -> URL? {
        if let dir = LinkHandling.documentDirectory { return dir }
        if let doc = LinkHandling.currentDocumentURL {
            return doc.deletingLastPathComponent()
        }
        return nil
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "tif", "tiff": return "image/tiff"
        case "heic": return "image/heic"
        case "bmp": return "image/bmp"
        default: return "image/png"
        }
    }

    // MARK: - Export / save attachment bytes

    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func originalData(src: String) -> Data? {
        if let parsed = parseDataURL(src) { return parsed.data }
        if let url = resolveFileURL(src) {
            return try? Data(contentsOf: url)
        }
        return nil
    }

    enum ImageError: LocalizedError {
        case noDocumentFolder

        var errorDescription: String? {
            switch self {
            case .noDocumentFolder:
                return "Save the document first so images can be stored in an assets folder next to it."
            }
        }
    }
}

// MARK: - SwiftUI preview helper

/// Split inline Markdown into text runs and images for Preview.
enum MarkdownInlineSegment: Equatable {
    case text(String)
    case image(alt: String, src: String)
}

enum MarkdownInlineSegments {
    static func parse(_ source: String) -> [MarkdownInlineSegment] {
        var result: [MarkdownInlineSegment] = []
        var i = source.startIndex
        var textBuf = ""

        func flushText() {
            if !textBuf.isEmpty {
                result.append(.text(textBuf))
                textBuf = ""
            }
        }

        while i < source.endIndex {
            let slice = String(source[i...])
            if let img = MarkdownImage.matchImagePrefix(slice) {
                flushText()
                result.append(.image(alt: img.alt, src: img.src))
                let len = slice.distance(from: slice.startIndex, to: img.end)
                i = source.index(i, offsetBy: len)
                continue
            }
            textBuf.append(source[i])
            i = source.index(after: i)
        }
        flushText()
        return result
    }
}
