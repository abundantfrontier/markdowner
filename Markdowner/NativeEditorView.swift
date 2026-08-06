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

    @State private var scrollFraction: CGFloat = 0
    @State private var scrollDriver: ScrollDriver = .none
    @AppStorage("markdowner.splitScrollSync") private var scrollSyncEnabled = true

    private enum ScrollDriver {
        case none, source, preview
    }

    var body: some View {
        Group {
            switch viewMode {
            case .wysiwyg:
                writePane
            case .source:
                sourcePane(showChrome: true, syncScroll: false)
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
            findDirection: findDirection
        )
        .padding(.horizontal, 40)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private func sourcePane(showChrome: Bool, syncScroll: Bool) -> some View {
        PlainMarkdownTextView(
            text: $text,
            monospaced: true,
            findQuery: findQuery,
            findCaseSensitive: findCaseSensitive,
            findNonce: findNonce,
            findDirection: findDirection,
            scrollFraction: syncScroll
                ? Binding(
                    get: { scrollFraction },
                    set: { newValue in
                        guard scrollSyncEnabled else { return }
                        if scrollDriver != .preview {
                            scrollDriver = .source
                            scrollFraction = newValue
                        }
                    }
                )
                : nil,
            isScrollDriver: !syncScroll || scrollDriver == .source || scrollDriver == .none
        )
        .padding(showChrome ? 12 : 8)
    }

    private var splitPane: some View {
        VStack(spacing: 0) {
            // Shared strip: labels + sync toggle (keeps both panes aligned, no title bleed)
            HStack(spacing: 12) {
                Text("Source")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Toggle(isOn: $scrollSyncEnabled) {
                    Label("Sync scroll", systemImage: scrollSyncEnabled ? "arrow.up.arrow.down" : "arrow.up.arrow.down.circle")
                        .font(.caption)
                }
                .toggleStyle(.checkbox)
                .help("Keep Source and Preview scrolled to the same relative position")
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
                sourcePane(showChrome: false, syncScroll: true)
                    .frame(minWidth: 280)

                HostedMarkdownScrollView(
                    markdown: text,
                    scrollFraction: Binding(
                        get: { scrollFraction },
                        set: { newValue in
                            guard scrollSyncEnabled else { return }
                            if scrollDriver != .source {
                                scrollDriver = .preview
                                scrollFraction = newValue
                            }
                        }
                    ),
                    isScrollDriver: scrollDriver == .preview,
                    syncEnabled: scrollSyncEnabled
                )
                .frame(minWidth: 280)
            }
        }
        .onChange(of: scrollFraction) { _, _ in
            guard scrollSyncEnabled else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                scrollDriver = .none
            }
        }
    }
}

// MARK: - Block preview inside NSScrollView (for scroll sync with source)

/// Hosts `MarkdownDocumentView` in an `NSScrollView` so we can mirror scroll with the source editor.
struct HostedMarkdownScrollView: NSViewRepresentable {
    let markdown: String
    @Binding var scrollFraction: CGFloat
    var isScrollDriver: Bool
    var syncEnabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(scrollFraction: $scrollFraction)
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
        context.coordinator.observeScroll()

        DispatchQueue.main.async {
            context.coordinator.relayout(markdown: markdown, width: scroll.contentView.bounds.width)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.scrollFraction = $scrollFraction
        context.coordinator.syncEnabled = syncEnabled
        let width = max(scroll.contentView.bounds.width, 100)
        if context.coordinator.lastMarkdown != markdown || abs(context.coordinator.lastWidth - width) > 1 {
            context.coordinator.relayout(markdown: markdown, width: width)
        }
        if syncEnabled, !isScrollDriver {
            context.coordinator.applyFraction(scrollFraction)
        }
    }

    final class Coordinator: NSObject {
        var scrollFraction: Binding<CGFloat>
        var syncEnabled = true
        var isApplyingScroll = false
        var lastMarkdown = ""
        var lastWidth: CGFloat = 0
        weak var scrollView: NSScrollView?
        var host: NSHostingView<AnyView>?
        weak var documentView: NSView?

        init(scrollFraction: Binding<CGFloat>) {
            self.scrollFraction = scrollFraction
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

        deinit { NotificationCenter.default.removeObserver(self) }

        func relayout(markdown: String, width: CGFloat) {
            lastMarkdown = markdown
            lastWidth = width
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
            // fittingSize can under-report; also try intrinsic content size
            let intrinsic = host.intrinsicContentSize
            let contentH = max(fitting.height, intrinsic.height, 400)
            let h = max(contentH, scrollView.contentView.bounds.height, 1)
            documentView.setFrameSize(NSSize(width: w, height: h))
            host.frame = NSRect(x: 0, y: 0, width: w, height: h)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        @objc func boundsChanged(_ note: Notification) {
            guard syncEnabled, !isApplyingScroll, let scrollView else { return }
            let clip = scrollView.contentView
            let docHeight = max(scrollView.documentView?.bounds.height ?? 1, 1)
            let visible = max(clip.bounds.height, 1)
            let maxY = max(docHeight - visible, 1)
            let fraction = min(max(clip.bounds.origin.y / maxY, 0), 1)
            if abs(scrollFraction.wrappedValue - fraction) > 0.002 {
                scrollFraction.wrappedValue = fraction
            }
        }

        @objc func frameChanged(_ note: Notification) {
            guard let scrollView else { return }
            let width = scrollView.contentView.bounds.width
            if abs(width - lastWidth) > 1, !lastMarkdown.isEmpty {
                relayout(markdown: lastMarkdown, width: width)
            }
        }

        func applyFraction(_ fraction: CGFloat) {
            guard syncEnabled, let scrollView else { return }
            isApplyingScroll = true
            defer { isApplyingScroll = false }
            let clip = scrollView.contentView
            let docHeight = max(scrollView.documentView?.bounds.height ?? 1, 1)
            let visible = max(clip.bounds.height, 1)
            let maxY = max(docHeight - visible, 1)
            clip.scroll(to: NSPoint(x: 0, y: fraction * maxY))
            scrollView.reflectScrolledClipView(clip)
        }
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Editable rich Write mode

struct RichMarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    var findQuery: String = ""
    var findCaseSensitive: Bool = false
    var findNonce: Int = 0
    var findDirection: Int = 1

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let tv = NSTextView()
        tv.delegate = context.coordinator
        tv.isRichText = true
        tv.allowsUndo = true
        tv.importsGraphics = false
        tv.isAutomaticQuoteSubstitutionEnabled = true
        tv.isAutomaticDashSubstitutionEnabled = true
        tv.isAutomaticTextReplacementEnabled = true
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

        tv.textStorage?.setAttributedString(MarkdownRichText.attributedString(from: text))
        context.coordinator.lastMarkdown = text
        context.coordinator.textView = tv

        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
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
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        func textDidBeginEditing(_ notification: Notification) { isEditing = true }
        func textDidEndEditing(_ notification: Notification) {
            isEditing = false
            commitMarkdown()
        }

        func textDidChange(_ notification: Notification) {
            isEditing = true
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
            Task { @MainActor in _ = LinkHandling.handle(url) }
            return true
        }

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            guard let storage = view.textStorage, charIndex >= 0, charIndex < storage.length else {
                return menu
            }
            if let link = storage.attribute(.link, at: charIndex, effectiveRange: nil) {
                let url: URL? = {
                    if let u = link as? URL { return u }
                    if let s = link as? String { return LinkHandling.urlFromMarkdownLink(s) }
                    return nil
                }()
                if let url {
                    Task { @MainActor in
                        LinkHandling.presentMenu(for: url, relativeTo: view)
                    }
                    return NSMenu()
                }
            }
            return menu
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
            guard tv.window?.isKeyWindow == true else { return }
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
    var scrollFraction: Binding<CGFloat>?
    var isScrollDriver: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, scrollFraction: scrollFraction)
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
        textView.allowsUndo = true
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
        context.coordinator.observeScroll()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.scrollFraction = scrollFraction
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
        if let scrollFraction, !isScrollDriver {
            context.coordinator.applyFraction(scrollFraction.wrappedValue)
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
        var scrollFraction: Binding<CGFloat>?
        var lastFindNonce = 0
        var isApplyingScroll = false
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?

        init(text: Binding<String>, scrollFraction: Binding<CGFloat>?) {
            self.text = text
            self.scrollFraction = scrollFraction
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

        @objc func boundsChanged(_ note: Notification) {
            guard !isApplyingScroll, let scrollView, let scrollFraction else { return }
            let clip = scrollView.contentView
            let docHeight = (scrollView.documentView?.bounds.height ?? 1)
            let visible = clip.bounds.height
            let maxY = max(docHeight - visible, 1)
            let fraction = min(max(clip.bounds.origin.y / maxY, 0), 1)
            if abs(scrollFraction.wrappedValue - fraction) > 0.002 {
                scrollFraction.wrappedValue = fraction
            }
        }

        func applyFraction(_ fraction: CGFloat) {
            guard let scrollView else { return }
            isApplyingScroll = true
            defer { isApplyingScroll = false }
            let clip = scrollView.contentView
            let docHeight = (scrollView.documentView?.bounds.height ?? 1)
            let visible = clip.bounds.height
            let maxY = max(docHeight - visible, 1)
            clip.scroll(to: NSPoint(x: 0, y: fraction * maxY))
            scrollView.reflectScrolledClipView(clip)
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
            guard tv.window?.isKeyWindow == true else { return }
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
