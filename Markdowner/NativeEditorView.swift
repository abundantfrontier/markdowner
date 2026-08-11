import AppKit
import SwiftUI

/// Write / Source / Split. Write = editable rich text; Source = Markdown; Split = both + optional synced scroll.
struct NativeEditorView: View {
    @Binding var text: String
    @Binding var viewMode: EditorContainerView.ViewMode
    /// Shared find query driven by the window find bar.
    var findQuery: String = ""
    var findCaseSensitive: Bool = false
    var findNonce: Int = 0
    var findDirection: Int = 1 // 1 next, -1 previous
    /// Package (zip) mode — no typing or rich-text mutation.
    var isReadOnly: Bool = false

    /// Character offset into the shared Markdown used when Sync scroll is on.
    /// Panes map this via text fingerprints (not equal pixel heights).
    @State private var syncCharOffset: Int = 0
    /// Bumped when the follower should jump to `syncCharOffset`.
    @State private var syncGeneration: Int = 0
    @State private var scrollDriver: ScrollDriver = .none
    /// Off by default — independent scrolling until the user opts in.
    /// Key suffix `.v2` resets older installs that defaulted sync to on.
    @AppStorage("markdowner.splitScrollSync.v2") private var scrollSyncEnabled = false

    private enum ScrollDriver {
        case none, source, preview
    }

    var body: some View {
        Group {
            switch viewMode {
            case .wysiwyg:
                writePane
            case .source:
                sourcePane(showChrome: true, syncEnabled: false)
            case .split:
                splitPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .environment(\.openURL, LinkHandling.openURLAction)
    }

    private var writePane: some View {
        RichMarkdownTextView(
            text: $text,
            findQuery: findQuery,
            findCaseSensitive: findCaseSensitive,
            findNonce: findNonce,
            findDirection: findDirection,
            isReadOnly: isReadOnly
        )
        .padding(.horizontal, 40)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private func sourcePane(showChrome: Bool, syncEnabled: Bool) -> some View {
        PlainMarkdownTextView(
            text: $text,
            monospaced: true,
            findQuery: findQuery,
            findCaseSensitive: findCaseSensitive,
            findNonce: findNonce,
            findDirection: findDirection,
            isReadOnly: isReadOnly,
            syncCharOffset: syncEnabled
                ? Binding(
                    get: { syncCharOffset },
                    set: { newValue in
                        guard scrollSyncEnabled else { return }
                        if scrollDriver == .preview { return }
                        scrollDriver = .source
                        if abs(newValue - syncCharOffset) > 8 {
                            syncCharOffset = newValue
                            syncGeneration += 1
                        }
                    }
                )
                : nil,
            // Source is the default authority when sync is idle (driver == none).
            isScrollDriver: !scrollSyncEnabled || scrollDriver != .preview,
            syncGeneration: syncEnabled && scrollSyncEnabled ? syncGeneration : 0,
            syncEnabled: syncEnabled && scrollSyncEnabled
        )
        .padding(showChrome ? 12 : 8)
    }

    private var splitPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Source")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Toggle(isOn: $scrollSyncEnabled) {
                    Label("Sync scroll", systemImage: scrollSyncEnabled ? "link" : "link.badge.plus")
                        .font(.caption)
                }
                .toggleStyle(.checkbox)
                .help("Off by default. When on, scrolling one pane jumps the other to matching text (not equal pixel rates).")
                .onChange(of: scrollSyncEnabled) { _, on in
                    if on {
                        // One-shot: Source reports where it is; Preview jumps to that text.
                        scrollDriver = .source
                        syncGeneration += 1
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            scrollDriver = .none
                        }
                    } else {
                        scrollDriver = .none
                    }
                }
                Button {
                    guard scrollSyncEnabled else { return }
                    syncCharOffset = 0
                    scrollDriver = .source
                    syncGeneration += 1
                } label: {
                    Image(systemName: "arrow.up.to.line")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(!scrollSyncEnabled)
                .help(scrollSyncEnabled ? "Jump both panes to the top" : "Turn on Sync scroll to link panes")
                Spacer(minLength: 8)
                Text("Preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
            .overlay(alignment: .bottom) { Divider() }

            HSplitView {
                sourcePane(showChrome: false, syncEnabled: true)
                    .frame(minWidth: 280)

                HostedMarkdownScrollView(
                    markdown: text,
                    syncCharOffset: Binding(
                        get: { syncCharOffset },
                        set: { newValue in
                            guard scrollSyncEnabled else { return }
                            if scrollDriver == .source { return }
                            scrollDriver = .preview
                            if abs(newValue - syncCharOffset) > 8 {
                                syncCharOffset = newValue
                                syncGeneration += 1
                            }
                        }
                    ),
                    // Preview only drives while the user is actively scrolling it.
                    isScrollDriver: scrollSyncEnabled && scrollDriver == .preview,
                    syncEnabled: scrollSyncEnabled,
                    syncGeneration: scrollSyncEnabled ? syncGeneration : 0
                )
                .frame(minWidth: 280)
            }
        }
        .onChange(of: syncGeneration) { _, _ in
            guard scrollSyncEnabled else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if scrollDriver != .none {
                    scrollDriver = .none
                }
            }
        }
    }
}

// MARK: - Content-based split sync helpers

/// Maps Source ↔ Preview by Markdown character offset + text fingerprints
/// (preview layout height ≠ source layout height, so pure pixel fractions drift).
enum SplitScrollSync {
    /// First non-empty line at/after `offset`, stripped of heading markers / light markup.
    static func fingerprint(at offset: Int, in markdown: String) -> String {
        let ns = markdown as NSString
        guard ns.length > 0 else { return "" }
        let o = min(max(offset, 0), ns.length - 1)
        var lineStart = 0, lineEnd = 0, contentsEnd = 0
        ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: o, length: 0))
        var line = ns.substring(with: NSRange(location: lineStart, length: max(0, contentsEnd - lineStart)))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // If blank, walk forward a few lines for something matchable.
        var probe = lineEnd
        var hops = 0
        while line.isEmpty, probe < ns.length, hops < 6 {
            ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: probe, length: 0))
            line = ns.substring(with: NSRange(location: lineStart, length: max(0, contentsEnd - lineStart)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if lineEnd <= probe { break }
            probe = lineEnd
            hops += 1
        }

        // Strip leading markdown heading hashes.
        while line.hasPrefix("#") { line = String(line.dropFirst()) }
        line = line.trimmingCharacters(in: .whitespaces)
        line = LinkHandling.stripInlineMarkup(line)
        // Keep a stable prefix for search.
        if line.count > 48 { line = String(line.prefix(48)) }
        return line
    }

    /// Best character offset for a fingerprint (prefer near `hint`).
    static func offset(ofFingerprint raw: String, in markdown: String, near hint: Int) -> Int? {
        let fp = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard fp.count >= 3 else { return nil }
        let ns = markdown as NSString
        var search = NSRange(location: 0, length: ns.length)
        var best: Int?
        var bestDist = Int.max
        while search.length > 0 {
            let found = ns.range(of: fp, options: [.caseInsensitive], range: search)
            if found.location == NSNotFound { break }
            let dist = abs(found.location - hint)
            if dist < bestDist {
                bestDist = dist
                best = found.location
            }
            let next = found.location + max(found.length, 1)
            if next >= ns.length { break }
            search = NSRange(location: next, length: ns.length - next)
        }
        if best != nil { return best }

        // Try without punctuation differences: search line-by-line by slug.
        let needleSlug = LinkHandling.headingSlug(fp)
        guard !needleSlug.isEmpty else { return best }
        var idx = 0
        while idx < ns.length {
            var lineStart = 0, lineEnd = 0, contentsEnd = 0
            ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: idx, length: 0))
            let line = ns.substring(with: NSRange(location: lineStart, length: max(0, contentsEnd - lineStart)))
            let plain = LinkHandling.stripInlineMarkup(line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))
            if LinkHandling.headingSlug(plain) == needleSlug
                || plain.localizedCaseInsensitiveContains(fp) {
                let dist = abs(lineStart - hint)
                if dist < bestDist {
                    bestDist = dist
                    best = lineStart
                }
            }
            if lineEnd <= idx { break }
            idx = lineEnd
        }
        return best
    }

    static func clampOffset(_ offset: Int, in markdown: String) -> Int {
        max(0, min(offset, max(markdown.count - 1, 0)))
    }
}

// MARK: - Block preview inside NSScrollView (for scroll sync with source)

/// Hosts `MarkdownDocumentView` in an `NSScrollView` so we can mirror scroll with the source editor.
struct HostedMarkdownScrollView: NSViewRepresentable {
    let markdown: String
    @Binding var syncCharOffset: Int
    var isScrollDriver: Bool
    var syncEnabled: Bool
    var syncGeneration: Int = 0

    func makeCoordinator() -> Coordinator {
        Coordinator(syncCharOffset: $syncCharOffset)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true

        let width = max(scroll.contentView.bounds.width, 320)
        let document = FlippedDocumentView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        let host = NSHostingView(rootView: AnyView(
            MarkdownDocumentView(markdown: markdown, embedsOwnScroll: false)
                .frame(width: width, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
        ))
        host.frame = document.bounds
        host.autoresizingMask = [.width]
        document.addSubview(host)

        scroll.documentView = document
        context.coordinator.scrollView = scroll
        context.coordinator.host = host
        context.coordinator.documentView = document
        context.coordinator.markdown = markdown
        context.coordinator.observeScroll()
        context.coordinator.observeAnchors()

        DispatchQueue.main.async {
            context.coordinator.relayout(markdown: markdown, width: scroll.contentView.bounds.width)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.syncCharOffset = $syncCharOffset
        context.coordinator.syncEnabled = syncEnabled
        context.coordinator.isScrollDriver = isScrollDriver
        context.coordinator.markdown = markdown
        let width = max(scroll.contentView.bounds.width, 100)
        if context.coordinator.lastMarkdown != markdown || abs(context.coordinator.lastWidth - width) > 1 {
            context.coordinator.relayout(markdown: markdown, width: width)
        }
        if syncEnabled, context.coordinator.lastSyncGeneration != syncGeneration {
            context.coordinator.lastSyncGeneration = syncGeneration
            if !isScrollDriver {
                DispatchQueue.main.async {
                    context.coordinator.applyCharOffset(syncCharOffset)
                }
            }
        }
    }

    final class Coordinator: NSObject {
        var syncCharOffset: Binding<Int>
        var syncEnabled = false
        var isScrollDriver = true
        var isApplyingScroll = false
        var lastMarkdown = ""
        var lastWidth: CGFloat = 0
        var lastSyncGeneration = -1
        var markdown = ""
        private var reportDebounce: DispatchWorkItem?
        weak var scrollView: NSScrollView?
        var host: NSHostingView<AnyView>?
        weak var documentView: NSView?

        init(syncCharOffset: Binding<Int>) {
            self.syncCharOffset = syncCharOffset
        }

        func observeScroll() {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsChanged),
                name: NSView.boundsDidChangeNotification,
                object: scrollView?.contentView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(frameChanged),
                name: NSView.frameDidChangeNotification,
                object: scrollView?.contentView
            )
        }

        func observeAnchors() {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(navigateAnchor(_:)),
                name: .markdownerNavigateAnchor,
                object: nil
            )
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc func navigateAnchor(_ note: Notification) {
            guard let fragment = note.object as? String,
                  let range = LinkHandling.rangeOfAnchor(fragment, in: markdown, markdownSource: markdown)
            else { return }
            syncCharOffset.wrappedValue = range.location
            applyCharOffset(range.location)
        }

        func relayout(markdown: String, width: CGFloat) {
            lastMarkdown = markdown
            lastWidth = width
            self.markdown = markdown
            guard let scrollView, let documentView else { return }
            let w = max(width, 100)

            let view = AnyView(
                MarkdownDocumentView(markdown: markdown, embedsOwnScroll: false)
                    .frame(width: w, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
            )

            if let host {
                host.rootView = view
            } else {
                let host = NSHostingView(rootView: view)
                host.autoresizingMask = [.width]
                documentView.subviews.forEach { $0.removeFromSuperview() }
                documentView.addSubview(host)
                self.host = host
            }

            guard let host else { return }
            host.frame = NSRect(x: 0, y: 0, width: w, height: 10)
            host.layoutSubtreeIfNeeded()
            let fitting = host.fittingSize
            let intrinsic = host.intrinsicContentSize
            let contentH = max(fitting.height, intrinsic.height, 400)
            let h = max(contentH, scrollView.contentView.bounds.height, 1)
            documentView.setFrameSize(NSSize(width: w, height: h))
            host.frame = NSRect(x: 0, y: 0, width: w, height: h)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        @objc func boundsChanged(_ note: Notification) {
            // Report whenever the user scrolls (not while we are applying a jump).
            guard syncEnabled, !isApplyingScroll else { return }
            reportDebounce?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.reportOffsetFromPixels()
            }
            reportDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        }

        private func reportOffsetFromPixels() {
            guard syncEnabled, !isApplyingScroll, let scrollView else { return }
            let clip = scrollView.contentView
            let docHeight = max(scrollView.documentView?.bounds.height ?? 1, 1)
            let visible = max(clip.bounds.height, 1)
            let maxY = max(docHeight - visible, 1)
            let pixelFraction = min(max(clip.bounds.origin.y / maxY, 0), 1)
            // Approximate char offset, then snap to a real line fingerprint in the Markdown.
            let approx = Int(round(pixelFraction * CGFloat(max(markdown.count - 1, 0))))
            let fp = SplitScrollSync.fingerprint(at: approx, in: markdown)
            let snapped = SplitScrollSync.offset(ofFingerprint: fp, in: markdown, near: approx) ?? approx
            let clamped = SplitScrollSync.clampOffset(snapped, in: markdown)
            if abs(clamped - syncCharOffset.wrappedValue) > 8 {
                syncCharOffset.wrappedValue = clamped
            }
        }

        @objc func frameChanged(_ note: Notification) {
            guard let scrollView else { return }
            let width = scrollView.contentView.bounds.width
            if abs(width - lastWidth) > 1, !lastMarkdown.isEmpty {
                relayout(markdown: lastMarkdown, width: width)
            }
        }

        /// Jump preview so the same Markdown offset is near the top (via length fraction + fingerprint snap).
        func applyCharOffset(_ offset: Int) {
            guard let scrollView else { return }
            isApplyingScroll = true
            defer { isApplyingScroll = false }

            let total = max(markdown.count - 1, 1)
            var fraction = CGFloat(SplitScrollSync.clampOffset(offset, in: markdown)) / CGFloat(total)

            // Prefer fingerprint match when the source gave us a real line.
            let fp = SplitScrollSync.fingerprint(at: offset, in: markdown)
            if let found = SplitScrollSync.offset(ofFingerprint: fp, in: markdown, near: offset) {
                fraction = CGFloat(found) / CGFloat(total)
            }

            let clip = scrollView.contentView
            let docHeight = max(scrollView.documentView?.bounds.height ?? 1, 1)
            let visible = max(clip.bounds.height, 1)
            let maxY = max(docHeight - visible, 1)
            let y = min(max(fraction, 0), 1) * maxY
            clip.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(clip)
        }
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Editable rich Write mode

/// `NSTextView` that follows Markdown links with a plain click (or ⌘-click),
/// toggles task checkboxes, and accepts image drag-and-drop.
private final class LinkAwareTextView: NSTextView {
    var onImagesDropped: (([URL]) -> Void)?
    var onImagePaste: ((NSImage) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .tiff, .png])
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        registerForDraggedTypes([.fileURL, .tiff, .png])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL, .tiff, .png])
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, !event.modifierFlags.contains(.shift) {
            if let charIndex = characterIndex(at: event),
               toggleTaskCheckbox(at: charIndex) {
                return
            }
            if let hit = linkHit(at: event) {
                if let del = delegate as? any NSTextViewDelegate {
                    let handled = del.textView?(self, clickedOnLink: hit.link, at: hit.charIndex) ?? false
                    if handled { return }
                }
                if let url = hit.link as? URL {
                    _ = LinkHandling.handle(url)
                    return
                }
                if let s = hit.link as? String, let url = LinkHandling.urlFromMarkdownLink(s) {
                    _ = LinkHandling.handle(url)
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let imgs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage], let img = imgs.first {
            onImagePaste?(img)
            return
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], urls.contains(where: { isImageFile($0) }) {
            onImagesDropped?(urls.filter { isImageFile($0) })
            return
        }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL] {
            let images = urls.filter { isImageFile($0) }
            if !images.isEmpty {
                onImagesDropped?(images)
                return true
            }
        }
        if let imgs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage], let img = imgs.first {
            onImagePaste?(img)
            return true
        }
        return super.performDragOperation(sender)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if hasImagePayload(sender.draggingPasteboard) { return .copy }
        return super.draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if hasImagePayload(sender.draggingPasteboard) { return true }
        return super.prepareForDragOperation(sender)
    }

    private func hasImagePayload(_ pb: NSPasteboard) -> Bool {
        if pb.canReadObject(forClasses: [NSImage.self], options: nil) { return true }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            return urls.contains(where: isImageFile)
        }
        return false
    }

    private func isImageFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "bmp", "heic"].contains(ext)
    }

    /// Toggle `- [ ]` / `- [x]` when the user clicks ☑ / ☐.
    @discardableResult
    private func toggleTaskCheckbox(at charIndex: Int) -> Bool {
        guard isEditable, let storage = textStorage else { return false }
        guard charIndex >= 0, charIndex < storage.length else { return false }
        guard storage.attribute(MarkdownRichText.taskCheckboxKey, at: charIndex, effectiveRange: nil) != nil else {
            return false
        }
        let ch = (storage.string as NSString).character(at: charIndex)
        let checked = ch == 0x2611 // ☑
        let unchecked = ch == 0x2610 // ☐
        guard checked || unchecked else { return false }
        let newChar = checked ? "☐" : "☑"
        let range = NSRange(location: charIndex, length: 1)
        if shouldChangeText(in: range, replacementString: newChar) {
            storage.replaceCharacters(in: range, with: newChar)
            storage.addAttribute(
                MarkdownRichText.taskCheckboxKey,
                value: !checked,
                range: range
            )
            // Restyle rest of line
            var lineStart = 0, lineEnd = 0, contentsEnd = 0
            (storage.string as NSString).getLineStart(
                &lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                for: NSRange(location: charIndex, length: 0)
            )
            let bodyStart = min(charIndex + 1, contentsEnd)
            // skip tab after box
            var rest = bodyStart
            if rest < contentsEnd, (storage.string as NSString).character(at: rest) == 9 {
                rest += 1
            }
            let bodyRange = NSRange(location: rest, length: max(0, contentsEnd - rest))
            if bodyRange.length > 0 {
                if checked {
                    // was checked → now unchecked: remove strike/secondary
                    storage.removeAttribute(.strikethroughStyle, range: bodyRange)
                    storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: bodyRange)
                } else {
                    storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: bodyRange)
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: bodyRange)
                }
            }
            didChangeText()
        }
        return true
    }

    private func characterIndex(at event: NSEvent) -> Int? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let inset = textContainerInset
        let adjusted = NSPoint(x: point.x - inset.width, y: point.y - inset.height)
        var fraction: CGFloat = 0
        let glyphIndex = lm.glyphIndex(for: adjusted, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        let charIndex = lm.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < storage.length else { return nil }
        return charIndex
    }

    private func linkHit(at event: NSEvent) -> (link: Any, charIndex: Int)? {
        guard let storage = textStorage, let charIndex = characterIndex(at: event) else { return nil }
        guard let link = storage.attribute(.link, at: charIndex, effectiveRange: nil) else { return nil }
        return (link, charIndex)
    }
}

struct RichMarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    var findQuery: String = ""
    var findCaseSensitive: Bool = false
    var findNonce: Int = 0
    var findDirection: Int = 1
    var isReadOnly: Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let tv = LinkAwareTextView(frame: .zero)
        tv.delegate = context.coordinator
        tv.isRichText = true
        tv.isEditable = !isReadOnly
        tv.isSelectable = true
        tv.allowsUndo = !isReadOnly
        // We handle image paste/drag ourselves so Markdown stays portable.
        tv.importsGraphics = false
        tv.isAutomaticQuoteSubstitutionEnabled = !isReadOnly
        tv.isAutomaticDashSubstitutionEnabled = !isReadOnly
        tv.isAutomaticTextReplacementEnabled = !isReadOnly
        tv.isAutomaticLinkDetectionEnabled = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.textContainerInset = NSSize(width: 16, height: 28)
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textColor = .labelColor
        tv.insertionPointColor = .labelColor
        tv.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        tv.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 16.5),
            .foregroundColor: NSColor.labelColor,
        ]
        let coordinator = context.coordinator
        tv.onImagesDropped = { [weak coordinator] urls in
            coordinator?.insertImageFiles(urls)
        }
        tv.onImagePaste = { [weak coordinator] image in
            coordinator?.insertPastedImage(image)
        }

        tv.textStorage?.setAttributedString(MarkdownRichText.attributedString(from: text))
        context.coordinator.lastMarkdown = text
        context.coordinator.textView = tv

        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        tv.isEditable = !isReadOnly
        tv.allowsUndo = !isReadOnly
        if context.coordinator.lastMarkdown != text, !context.coordinator.isEditing {
            let selected = tv.selectedRanges
            tv.textStorage?.setAttributedString(MarkdownRichText.attributedString(from: text))
            tv.selectedRanges = selected
            context.coordinator.lastMarkdown = text
        }
        if context.coordinator.lastFindNonce != findNonce {
            context.coordinator.lastFindNonce = findNonce
            context.coordinator.performFind(
                query: findQuery,
                caseSensitive: findCaseSensitive,
                direction: findDirection
            )
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var lastMarkdown: String = ""
        var isEditing = false
        /// True only after real typing / paste — not mere click/focus.
        var contentChanged = false
        var lastFindNonce = 0
        weak var textView: NSTextView?
        private var debounce: DispatchWorkItem?

        init(text: Binding<String>) {
            self.text = text
            super.init()
            NotificationCenter.default.addObserver(
                self, selector: #selector(handleFormat(_:)),
                name: .markdownerFormat, object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(navigateAnchor(_:)),
                name: .markdownerNavigateAnchor,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(folderAccessGranted(_:)),
                name: .markdownerFolderAccessGranted,
                object: nil
            )
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc func navigateAnchor(_ note: Notification) {
            guard let fragment = note.object as? String, let tv = textView else { return }
            // Write mode shows plain text without `#` markers — resolve against source Markdown.
            _ = LinkHandling.scrollTextView(
                tv,
                toAnchor: fragment,
                markdownSource: lastMarkdown.isEmpty ? text.wrappedValue : lastMarkdown
            )
        }

        /// After Open Folder…, re-parse so relative images can load under App Sandbox.
        @objc func folderAccessGranted(_ note: Notification) {
            guard let tv = textView else { return }
            let md = lastMarkdown.isEmpty ? text.wrappedValue : lastMarkdown
            let selected = tv.selectedRanges
            tv.textStorage?.setAttributedString(MarkdownRichText.attributedString(from: md))
            tv.selectedRanges = selected
        }

        func textDidBeginEditing(_ notification: Notification) {
            isEditing = true
            contentChanged = false
        }
        func textDidEndEditing(_ notification: Notification) {
            isEditing = false
            // Only round-trip Markdown if the user actually changed content.
            // Clicks/selection must not rewrite source or mark the doc dirty.
            if contentChanged {
                commitMarkdown()
            }
            contentChanged = false
        }

        func textDidChange(_ notification: Notification) {
            isEditing = true
            contentChanged = true
            debounce?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.commitMarkdown() }
            debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url: URL? = {
                if let u = link as? URL { return u }
                if let s = link as? String { return LinkHandling.urlFromMarkdownLink(s) }
                return nil
            }()
            guard let url else { return false }
            // Stay synchronous on the main thread — async Task could miss the click context.
            _ = LinkHandling.handle(url)
            return true
        }

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            guard let storage = view.textStorage, charIndex >= 0, charIndex < storage.length else {
                return menu
            }
            // Image attachment context menu
            if storage.attribute(.attachment, at: charIndex, effectiveRange: nil) != nil
                || storage.attribute(MarkdownImage.srcKey, at: charIndex, effectiveRange: nil) != nil {
                let src = storage.attribute(MarkdownImage.srcKey, at: charIndex, effectiveRange: nil) as? String ?? ""
                let alt = storage.attribute(MarkdownImage.altKey, at: charIndex, effectiveRange: nil) as? String ?? ""
                let imageMenu = NSMenu(title: "Image")
                let save = NSMenuItem(title: "Save Image…", action: #selector(saveImage(_:)), keyEquivalent: "")
                save.target = self
                save.representedObject = src
                imageMenu.addItem(save)
                let copy = NSMenuItem(title: "Copy Image", action: #selector(copyImage(_:)), keyEquivalent: "")
                copy.target = self
                copy.representedObject = src
                imageMenu.addItem(copy)
                let copyMD = NSMenuItem(title: "Copy Markdown", action: #selector(copyImageMarkdown(_:)), keyEquivalent: "")
                copyMD.target = self
                copyMD.representedObject = MarkdownImage.markdown(alt: alt, src: src)
                imageMenu.addItem(copyMD)
                if let fileURL = MarkdownImage.resolveFileURL(src), !src.hasPrefix("data:") {
                    let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(revealImage(_:)), keyEquivalent: "")
                    reveal.target = self
                    reveal.representedObject = fileURL
                    imageMenu.addItem(reveal)
                }
                return imageMenu
            }
            if let link = storage.attribute(.link, at: charIndex, effectiveRange: nil) {
                let url: URL? = {
                    if let u = link as? URL { return u }
                    if let s = link as? String { return LinkHandling.urlFromMarkdownLink(s) }
                    return nil
                }()
                if let url {
                    LinkHandling.presentMenu(for: url, relativeTo: view)
                    return NSMenu()
                }
            }
            return menu
        }

        @objc private func saveImage(_ sender: NSMenuItem) {
            guard let src = sender.representedObject as? String else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "image.png"
            if src.hasPrefix("data:"), let mime = MarkdownImage.parseDataURL(src)?.mime {
                if mime.contains("jpeg") {
                    panel.allowedContentTypes = [.jpeg]
                    panel.nameFieldStringValue = "image.jpg"
                }
            } else if let url = MarkdownImage.resolveFileURL(src) {
                panel.nameFieldStringValue = url.lastPathComponent
            }
            panel.begin { response in
                guard response == .OK, let dest = panel.url else { return }
                if let data = MarkdownImage.originalData(src: src) {
                    try? data.write(to: dest, options: .atomic)
                } else if let img = MarkdownImage.loadNSImage(src: src),
                          let data = MarkdownImage.pngData(from: img) {
                    try? data.write(to: dest, options: .atomic)
                }
            }
        }

        @objc private func copyImage(_ sender: NSMenuItem) {
            guard let src = sender.representedObject as? String,
                  let img = MarkdownImage.loadNSImage(src: src) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([img])
        }

        @objc private func copyImageMarkdown(_ sender: NSMenuItem) {
            guard let md = sender.representedObject as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(md, forType: .string)
        }

        @objc private func revealImage(_ sender: NSMenuItem) {
            guard let url = sender.representedObject as? URL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }

        func insertImageFiles(_ urls: [URL]) {
            guard !isReadOnly else { return }
            var snippets: [String] = []
            for url in urls {
                if let s = MarkdownImage.markdownSnippet(forFileURL: url, mode: .copyToAssets) {
                    snippets.append(s.trimmingCharacters(in: .newlines))
                }
            }
            guard !snippets.isEmpty else {
                presentImageNeedsSaveAlert()
                return
            }
            insertMarkdownSnippet("\n\n" + snippets.joined(separator: "\n\n") + "\n\n")
        }

        func insertPastedImage(_ image: NSImage) {
            guard !isReadOnly else { return }
            if let s = MarkdownImage.markdownSnippet(forImage: image) {
                insertMarkdownSnippet(s)
            } else {
                presentImageNeedsSaveAlert()
            }
        }

        private func insertMarkdownSnippet(_ snippet: String) {
            // Prefer end of document for drop; paste at selection if available.
            if let tv = textView, tv.selectedRange().location != NSNotFound,
               tv.selectedRange().location <= (tv.string as NSString).length {
                let range = tv.selectedRange()
                if tv.shouldChangeText(in: range, replacementString: snippet) {
                    // Insert into markdown binding via string splice for reliable round-trip.
                    let ns = text.wrappedValue as NSString
                    // Map rich selection to end of markdown is hard; append is safer after re-parse.
                    _ = ns
                }
            }
            let next = text.wrappedValue + (text.wrappedValue.hasSuffix("\n") ? "" : "\n") + snippet
            lastMarkdown = next
            text.wrappedValue = next
            contentChanged = true
            if let tv = textView {
                tv.textStorage?.setAttributedString(MarkdownRichText.attributedString(from: next))
            }
        }

        private func presentImageNeedsSaveAlert() {
            let alert = NSAlert()
            alert.messageText = "Save the document first"
            alert.informativeText = "Images are stored in an assets folder next to your Markdown file. Save the document, then drop or paste the image again.\n\nAlternatively use Insert Image… which can embed small images as data URLs."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }

        private var isReadOnly: Bool {
            !(textView?.isEditable ?? true)
        }

        private func commitMarkdown() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let md = MarkdownRichText.markdown(from: storage)
            if md != text.wrappedValue {
                lastMarkdown = md
                text.wrappedValue = md
            }
        }

        func performFind(query: String, caseSensitive: Bool, direction: Int) {
            guard let tv = textView, !query.isEmpty else { return }
            let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
            let full = tv.string as NSString
            let sel = tv.selectedRange()
            let searchRange: NSRange
            if direction >= 0 {
                let start = sel.location + sel.length
                searchRange = NSRange(location: start, length: max(0, full.length - start))
            } else {
                searchRange = NSRange(location: 0, length: sel.location)
            }
            var found = full.range(of: query, options: direction >= 0 ? options : options.union(.backwards), range: searchRange)
            if found.location == NSNotFound {
                // wrap
                let wrapRange = NSRange(location: 0, length: full.length)
                found = full.range(of: query, options: direction >= 0 ? options : options.union(.backwards), range: wrapRange)
            }
            if found.location != NSNotFound {
                tv.setSelectedRange(found)
                tv.scrollRangeToVisible(found)
                NotificationCenter.default.post(
                    name: .markdownerFindResult,
                    object: nil,
                    userInfo: ["count": 1, "index": 0]
                )
            } else {
                NotificationCenter.default.post(
                    name: .markdownerFindResult,
                    object: nil,
                    userInfo: ["count": 0, "index": -1]
                )
            }
        }

        @objc private func handleFormat(_ note: Notification) {
            guard let tv = textView, let action = note.object as? String else { return }
            guard tv.window?.isKeyWindow == true, tv.isEditable else { return }
            switch action {
            case "bold": applyTrait(.bold, to: tv)
            case "italic": applyTrait(.italic, to: tv)
            case "link": insertLink(in: tv)
            case "h1": applyHeading(size: 30, in: tv)
            case "h2": applyHeading(size: 24, in: tv)
            case "h3": applyHeading(size: 20, in: tv)
            case "code": applyCode(in: tv)
            case "ul": insertPrefix("•\t", in: tv)
            case "ol": insertPrefix("1.\t", in: tv)
            case "task": insertPrefix("☐\t", in: tv)
            case "hr": insertText("\n────────────────────────────────\n", in: tv)
            default: break
            }
            commitMarkdown()
        }

        private func applyTrait(_ trait: NSFontDescriptor.SymbolicTraits, to tv: NSTextView) {
            let range = tv.selectedRange()
            guard range.length > 0, let storage = tv.textStorage else {
                var attrs = tv.typingAttributes
                let font = (attrs[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 16.5)
                var traits = font.fontDescriptor.symbolicTraits
                if traits.contains(trait) { traits.remove(trait) } else { traits.insert(trait) }
                let desc = font.fontDescriptor.withSymbolicTraits(traits)
                attrs[.font] = NSFont(descriptor: desc, size: font.pointSize) ?? font
                tv.typingAttributes = attrs
                return
            }
            storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: 16.5)
                var traits = font.fontDescriptor.symbolicTraits
                if traits.contains(trait) { traits.remove(trait) } else { traits.insert(trait) }
                let desc = font.fontDescriptor.withSymbolicTraits(traits)
                let newFont = NSFont(descriptor: desc, size: font.pointSize) ?? font
                storage.addAttribute(.font, value: newFont, range: subrange)
            }
        }

        private func applyHeading(size: CGFloat, in tv: NSTextView) {
            let range = (tv.string as NSString).paragraphRange(for: tv.selectedRange())
            tv.textStorage?.addAttribute(
                .font, value: NSFont.systemFont(ofSize: size, weight: .bold), range: range
            )
        }

        private func applyCode(in tv: NSTextView) {
            let range = tv.selectedRange().length > 0
                ? tv.selectedRange()
                : (tv.string as NSString).paragraphRange(for: tv.selectedRange())
            tv.textStorage?.addAttribute(
                .font, value: NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular), range: range
            )
        }

        private func insertLink(in tv: NSTextView) {
            let range = tv.selectedRange()
            let selected = (tv.string as NSString).substring(with: range)
            let label = selected.isEmpty ? "link" : selected
            let alert = NSAlert()
            alert.messageText = "Link URL"
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.stringValue = "https://"
            alert.accessoryView = field
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            guard let url = URL(string: field.stringValue) else { return }
            let attr = NSAttributedString(string: label, attributes: [
                .link: url,
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .font: NSFont.systemFont(ofSize: 16.5),
            ])
            if tv.shouldChangeText(in: range, replacementString: label) {
                tv.textStorage?.replaceCharacters(in: range, with: attr)
                tv.didChangeText()
            }
        }

        private func insertPrefix(_ prefix: String, in tv: NSTextView) {
            let range = tv.selectedRange()
            if tv.shouldChangeText(in: range, replacementString: prefix) {
                tv.replaceCharacters(in: range, with: prefix)
                tv.didChangeText()
            }
        }

        private func insertText(_ string: String, in tv: NSTextView) {
            let range = tv.selectedRange()
            if tv.shouldChangeText(in: range, replacementString: string) {
                tv.replaceCharacters(in: range, with: string)
                tv.didChangeText()
            }
        }
    }
}

// MARK: - Plain source editor

struct PlainMarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    var monospaced: Bool
    var findQuery: String = ""
    var findCaseSensitive: Bool = false
    var findNonce: Int = 0
    var findDirection: Int = 1
    var isReadOnly: Bool = false
    /// Shared Markdown character offset when Split sync is on.
    var syncCharOffset: Binding<Int>?
    var isScrollDriver: Bool = true
    var syncGeneration: Int = 0
    var syncEnabled: Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, syncCharOffset: syncCharOffset)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = !isReadOnly
        textView.isSelectable = true
        textView.allowsUndo = !isReadOnly
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 8, height: 12)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scroll.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.drawsBackground = false
        textView.string = text
        applyFont(to: textView)

        scroll.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scroll
        context.coordinator.syncEnabled = syncEnabled
        context.coordinator.isScrollDriver = isScrollDriver
        context.coordinator.observeScroll()
        context.coordinator.observeAnchors()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.syncCharOffset = syncCharOffset
        context.coordinator.syncEnabled = syncEnabled
        context.coordinator.isScrollDriver = isScrollDriver
        textView.isEditable = !isReadOnly
        textView.allowsUndo = !isReadOnly
        applyFont(to: textView)
        if textView.string != text {
            let selected = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selected
        }
        if context.coordinator.lastFindNonce != findNonce {
            context.coordinator.lastFindNonce = findNonce
            context.coordinator.performFind(
                query: findQuery,
                caseSensitive: findCaseSensitive,
                direction: findDirection
            )
        }
        if syncEnabled, context.coordinator.lastSyncGeneration != syncGeneration {
            context.coordinator.lastSyncGeneration = syncGeneration
            if !isScrollDriver, let syncCharOffset {
                context.coordinator.applyCharOffset(syncCharOffset.wrappedValue)
            } else if isScrollDriver {
                // Driver (usually Source) reports its current top so Preview can align on enable.
                context.coordinator.reportTopOffset()
            }
        }
    }

    private func applyFont(to textView: NSTextView) {
        if monospaced {
            textView.font = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
        } else {
            textView.font = NSFont.systemFont(ofSize: 16.5)
        }
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.labelColor
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var syncCharOffset: Binding<Int>?
        var syncEnabled = false
        var isScrollDriver = true
        var lastFindNonce = 0
        var lastSyncGeneration = -1
        var isApplyingScroll = false
        private var reportDebounce: DispatchWorkItem?
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?

        init(text: Binding<String>, syncCharOffset: Binding<Int>?) {
            self.text = text
            self.syncCharOffset = syncCharOffset
            super.init()
            NotificationCenter.default.addObserver(
                self, selector: #selector(handleFormat(_:)),
                name: .markdownerFormat, object: nil
            )
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        func observeScroll() {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsChanged),
                name: NSView.boundsDidChangeNotification,
                object: scrollView?.contentView
            )
        }

        func observeAnchors() {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(navigateAnchor(_:)),
                name: .markdownerNavigateAnchor,
                object: nil
            )
        }

        @objc func navigateAnchor(_ note: Notification) {
            guard let fragment = note.object as? String, let tv = textView else { return }
            _ = LinkHandling.scrollTextView(
                tv,
                toAnchor: fragment,
                markdownSource: text.wrappedValue
            )
            if syncEnabled, let syncCharOffset {
                syncCharOffset.wrappedValue = tv.selectedRange().location
            }
        }

        @objc func boundsChanged(_ note: Notification) {
            // User-driven scroll reports a fingerprint offset; ignored while applying a jump.
            guard syncEnabled, !isApplyingScroll else { return }
            reportDebounce?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.reportTopOffset()
            }
            reportDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        }

        func reportTopOffset() {
            guard syncEnabled, !isApplyingScroll,
                  let tv = textView, let scrollView, let syncCharOffset
            else { return }
            let idx = topCharacterIndex(for: tv, in: scrollView)
            let md = text.wrappedValue
            let fp = SplitScrollSync.fingerprint(at: idx, in: md)
            let snapped = SplitScrollSync.offset(ofFingerprint: fp, in: md, near: idx) ?? idx
            let clamped = SplitScrollSync.clampOffset(snapped, in: md)
            if abs(clamped - syncCharOffset.wrappedValue) > 8 {
                syncCharOffset.wrappedValue = clamped
            }
        }

        private func topCharacterIndex(for tv: NSTextView, in scrollView: NSScrollView) -> Int {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return 0 }
            let clip = scrollView.contentView
            let originInTV = tv.convert(clip.bounds.origin, from: clip)
            let inset = tv.textContainerInset
            let point = NSPoint(x: max(0, originInTV.x - inset.width), y: max(0, originInTV.y - inset.height))
            var frac: CGFloat = 0
            let glyph = lm.glyphIndex(for: point, in: tc, fractionOfDistanceThroughGlyph: &frac)
            guard lm.numberOfGlyphs > 0 else { return 0 }
            return lm.characterIndexForGlyph(at: min(glyph, lm.numberOfGlyphs - 1))
        }

        func applyCharOffset(_ offset: Int) {
            guard let tv = textView else { return }
            isApplyingScroll = true
            defer { isApplyingScroll = false }
            let md = text.wrappedValue
            let fp = SplitScrollSync.fingerprint(at: offset, in: md)
            let target = SplitScrollSync.offset(ofFingerprint: fp, in: md, near: offset)
                ?? SplitScrollSync.clampOffset(offset, in: md)
            let range = NSRange(location: target, length: 0)
            tv.setSelectedRange(range)
            tv.scrollRangeToVisible(range)
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            if text.wrappedValue != tv.string {
                text.wrappedValue = tv.string
            }
        }

        func performFind(query: String, caseSensitive: Bool, direction: Int) {
            guard let tv = textView, !query.isEmpty else { return }
            let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
            let full = tv.string as NSString
            let sel = tv.selectedRange()
            let searchRange: NSRange
            if direction >= 0 {
                let start = sel.location + sel.length
                searchRange = NSRange(location: start, length: max(0, full.length - start))
            } else {
                searchRange = NSRange(location: 0, length: sel.location)
            }
            var found = full.range(
                of: query,
                options: direction >= 0 ? options : options.union(.backwards),
                range: searchRange
            )
            if found.location == NSNotFound {
                found = full.range(
                    of: query,
                    options: direction >= 0 ? options : options.union(.backwards),
                    range: NSRange(location: 0, length: full.length)
                )
            }
            if found.location != NSNotFound {
                tv.setSelectedRange(found)
                tv.scrollRangeToVisible(found)
                NotificationCenter.default.post(
                    name: .markdownerFindResult,
                    object: nil,
                    userInfo: ["count": countMatches(query, caseSensitive: caseSensitive, in: full), "index": 0]
                )
            } else {
                NotificationCenter.default.post(
                    name: .markdownerFindResult,
                    object: nil,
                    userInfo: ["count": 0, "index": -1]
                )
            }
        }

        private func countMatches(_ query: String, caseSensitive: Bool, in full: NSString) -> Int {
            var count = 0
            var search = NSRange(location: 0, length: full.length)
            let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
            while true {
                let found = full.range(of: query, options: options, range: search)
                if found.location == NSNotFound { break }
                count += 1
                let next = found.location + max(found.length, 1)
                if next >= full.length { break }
                search = NSRange(location: next, length: full.length - next)
            }
            return count
        }

        @objc private func handleFormat(_ note: Notification) {
            guard let tv = textView, let action = note.object as? String else { return }
            guard tv.window?.isKeyWindow == true, tv.isEditable else { return }
            switch action {
            case "bold": wrap("**", "**", in: tv)
            case "italic": wrap("*", "*", in: tv)
            case "code": wrap("`", "`", in: tv)
            case "strikethrough": wrap("~~", "~~", in: tv)
            case "link": wrap("[", "](https://)", in: tv)
            case "h1": insert("\n# ", in: tv)
            case "h2": insert("\n## ", in: tv)
            case "h3": insert("\n### ", in: tv)
            case "ul": insert("\n- ", in: tv)
            case "ol": insert("\n1. ", in: tv)
            case "task": insert("\n- [ ] ", in: tv)
            case "quote": insert("\n> ", in: tv)
            case "hr": insert("\n\n---\n\n", in: tv)
            case "codeblock": insert("\n```\ncode\n```\n", in: tv)
            default: break
            }
        }

        private func wrap(_ before: String, _ after: String, in tv: NSTextView) {
            let range = tv.selectedRange()
            let selected = (tv.string as NSString).substring(with: range)
            let replacement = before + (selected.isEmpty ? "text" : selected) + after
            if tv.shouldChangeText(in: range, replacementString: replacement) {
                tv.replaceCharacters(in: range, with: replacement)
                tv.didChangeText()
            }
        }

        private func insert(_ string: String, in tv: NSTextView) {
            let range = tv.selectedRange()
            if tv.shouldChangeText(in: range, replacementString: string) {
                tv.replaceCharacters(in: range, with: string)
                tv.didChangeText()
            }
        }
    }
}
