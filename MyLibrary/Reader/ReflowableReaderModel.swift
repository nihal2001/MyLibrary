import Foundation
import Observation
import SwiftUI
import UIKit
import WebKit

/// Drives the web view for reflowable books (EPUB and plain text): loads spine
/// documents, restores the saved position, tracks progress, and reports taps.
@MainActor
@Observable
final class ReflowableReaderModel {

    // MARK: - Published state

    private(set) var source: ReadingSource?
    private(set) var documentIndex: Int = 0
    private(set) var page: Int = 0
    private(set) var pageCount: Int = 1
    private(set) var fraction: Double = 0
    /// The table-of-contents entry the engine reports the reader is inside.
    private(set) var tocIndex: Int?
    private(set) var isLoading = true
    private(set) var loadError: String?
    var showsChrome = true

    /// Progress through the whole book, 0...1.
    var overallProgress: Double {
        guard let source, !source.documents.isEmpty else { return 0 }
        return min(1, (Double(documentIndex) + fraction) / Double(source.documents.count))
    }

    var chapterTitle: String {
        guard let source else { return "" }
        if let tocIndex, source.toc.indices.contains(tocIndex) {
            return source.toc[tocIndex].title
        }
        // Before this document's first anchored chapter: the entry that starts
        // the document itself, or else the last one in an earlier document.
        return source.toc.last { entry in
            guard let spine = entry.spineIndex else { return false }
            return spine < documentIndex || (spine == documentIndex && entry.fragment == nil)
        }?.title ?? ""
    }

    var pageDescription: String {
        pageCount > 1 ? "Page \(page + 1) of \(pageCount)" : ""
    }

    // MARK: - Internals

    @ObservationIgnored let webView: WKWebView
    /// The web view with the page-curl layer above it; this is what the view hosts.
    @ObservationIgnored let canvas: ReaderCanvasView
    @ObservationIgnored private let curl: PageCurlController
    /// Whether the engine is laying out two pages per screen.
    @ObservationIgnored private(set) var isSpread = false
    @ObservationIgnored private let bridge = Bridge()
    @ObservationIgnored private let settings = ReaderSettings.shared
    @ObservationIgnored private var book: Book?
    @ObservationIgnored private var pendingFraction: Double?
    @ObservationIgnored private var pendingFragment: String?
    @ObservationIgnored private var appliedStyleSignature = ""

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = true
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.isOpaque = false
        webView.alpha = 0
        canvas = ReaderCanvasView(webView: webView)
        curl = PageCurlController()

        bridge.model = self
        webView.navigationDelegate = bridge
        // WKWebView copies its configuration at init, so the handler has to be
        // registered on the live copy rather than on the local one.
        webView.configuration.userContentController.add(bridge, name: "reader")
        curl.attach(to: self, canvas: canvas)
    }

    // MARK: - Loading

    func open(book: Book) {
        self.book = book
        isLoading = true
        loadError = nil

        let (id, url, format, title) = (book.id, book.fileURL, book.format, book.title)
        let (savedIndex, savedFraction) = (book.spineIndex, book.spineFraction)
        Task.detached(priority: .userInitiated) {
            do {
                let source = try ReadingSourceLoader.load(id: id, fileURL: url, format: format, title: title)
                await self.begin(with: source, at: savedIndex, fraction: savedFraction)
            } catch {
                await self.fail(with: error.localizedDescription)
            }
        }
    }

    private func begin(with source: ReadingSource, at index: Int, fraction: Double) {
        self.source = source
        documentIndex = min(max(0, index), max(0, source.documents.count - 1))
        pendingFraction = fraction
        applyChrome()
        loadCurrentDocument()
    }

    private func fail(with message: String) {
        isLoading = false
        loadError = message
    }

    private func loadCurrentDocument() {
        guard let source, let url = source.documentURL(at: documentIndex) else { return }
        isLoading = true
        tocIndex = nil
        curl.invalidate()
        webView.alpha = 0
        refreshUserScripts()
        webView.loadFileURL(url, allowingReadAccessTo: source.rootURL)
    }

    /// Rebuilds the injected configuration + engine scripts from current settings.
    private func refreshUserScripts() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()

        // Chapters that start partway through this document, so the engine can
        // tell which one is on screen.
        let anchors: [[String: Any]] = (source?.toc ?? []).enumerated().compactMap { index, entry in
            guard entry.spineIndex == documentIndex, let fragment = entry.fragment else { return nil }
            return ["toc": index, "id": fragment]
        }
        let payload: [String: Any] = ["css": readerCSS(),
                                      "mode": settings.layout.rawValue,
                                      "anchors": anchors,
                                      "curl": settings.pageCurl && settings.layout == .paged]
        let json = (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        controller.addUserScript(WKUserScript(source: "window.__mlConfig = \(json);",
                                              injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: ReaderEngine.script,
                                              injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true))
        appliedStyleSignature = settings.styleSignature
    }

    func applySettingsIfNeeded() {
        applyChrome()
        guard appliedStyleSignature != settings.styleSignature else { return }
        pendingFraction = fraction
        loadCurrentDocument()
    }

    private func applyChrome() {
        webView.backgroundColor = UIColor(settings.theme.background)
        webView.scrollView.backgroundColor = UIColor(settings.theme.background)
        webView.scrollView.isScrollEnabled = settings.layout == .scrolling
        webView.scrollView.indicatorStyle = settings.theme.isDark ? .white : .black
        webView.scrollView.showsVerticalScrollIndicator = settings.layout == .scrolling
    }

    // MARK: - Navigation

    func goToNextPage() { evaluate("window.__ml && window.__ml.next();") }
    func goToPreviousPage() { evaluate("window.__ml && window.__ml.previous();") }

    // MARK: - Page curl

    var curlIsActive: Bool {
        settings.pageCurl && settings.layout == .paged && source != nil && !isLoading && loadError == nil
    }

    var hasPageAfter: Bool {
        page < pageCount - 1 || documentIndex < (source?.documents.count ?? 0) - 1
    }

    var hasPageBefore: Bool { page > 0 || documentIndex > 0 }

    var pageBackground: UIColor { UIColor(settings.theme.background) }

    /// A curl landed: move the live page to match. Crossing a chapter break
    /// loads the neighbouring document, as a tap would.
    func curlDidTurn(forward: Bool) {
        forward ? goToNextPage() : goToPreviousPage()
    }

    /// Shows `page` (or, for `nil`, the reader's own page) without changing the
    /// position, and returns once WebKit has drawn it.
    func showPage(_ page: Int?) async {
        let target = page.map(String.init) ?? "window.__ml.page"
        _ = try? await webView.callAsyncJavaScript(
            """
            if (window.__ml) { window.__ml.showPage(\(target)); }
            await new Promise(function (resolve) {
              requestAnimationFrame(function () { requestAnimationFrame(resolve); });
            });
            """,
            contentWorld: .page)
    }

    func goToDocument(at index: Int, fraction: Double = 0, fragment: String? = nil) {
        guard let source, source.documents.indices.contains(index) else { return }
        documentIndex = index
        pendingFraction = fraction
        pendingFragment = fragment
        loadCurrentDocument()
    }

    func go(to entry: TOCEntry) {
        guard let index = entry.spineIndex else { return }
        goToDocument(at: index, fraction: 0, fragment: entry.fragment)
    }

    func go(to bookmark: Bookmark) {
        goToDocument(at: bookmark.spineIndex, fraction: bookmark.spineFraction)
    }

    /// Jumps to a fraction of the whole book, used by the scrubber.
    func seek(toOverall value: Double) {
        guard let source, !source.documents.isEmpty else { return }
        let clamped = min(max(0, value), 0.9999)
        let scaled = clamped * Double(source.documents.count)
        let index = min(Int(scaled), source.documents.count - 1)
        let within = scaled - Double(index)
        if index == documentIndex {
            evaluate("window.__ml && window.__ml.goToFraction(\(within));")
        } else {
            goToDocument(at: index, fraction: within)
        }
    }

    private func advanceDocument(by offset: Int) {
        guard let source else { return }
        let target = documentIndex + offset
        guard source.documents.indices.contains(target) else { return }
        // Entering a document backwards should land on its last page.
        goToDocument(at: target, fraction: offset < 0 ? 1 : 0)
    }

    // MARK: - Bookmarks

    func currentSnippet() async -> String {
        let result = try? await webView.evaluateJavaScript("window.__ml ? window.__ml.snippet() : ''")
        return (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func makeBookmark() async -> Bookmark {
        let snippet = await currentSnippet()
        return Bookmark(chapterTitle: chapterTitle.isEmpty ? "Chapter \(documentIndex + 1)" : chapterTitle,
                        snippet: snippet,
                        spineIndex: documentIndex,
                        spineFraction: fraction)
    }

    /// True when an existing bookmark points at roughly this spot.
    func matchingBookmark(in book: Book) -> Bookmark? {
        book.bookmarks.first {
            $0.spineIndex == documentIndex && abs($0.spineFraction - fraction) < 0.02
        }
    }

    // MARK: - Messages from JavaScript

    fileprivate func handle(message: [String: Any]) {
        let type = message["type"] as? String ?? "position"

        switch type {
        case "ready", "position":
            // JavaScript numbers arrive as NSNumber, whatever their JS type.
            page = Int(number(message["page"]) ?? 0)
            pageCount = max(1, Int(number(message["pageCount"]) ?? 1))
            fraction = number(message["fraction"]) ?? 0
            let reportedTOC = Int(number(message["toc"]) ?? -1)
            tocIndex = reportedTOC >= 0 ? reportedTOC : nil
            isSpread = (message["spread"] as? NSNumber)?.boolValue ?? false

            var jumped = false
            if type == "ready" {
                if let fragment = pendingFragment {
                    pendingFragment = nil
                    evaluate("window.__ml && window.__ml.goToFragment(\(jsString(fragment)));")
                    jumped = true
                } else if let target = pendingFraction {
                    pendingFraction = nil
                    evaluate("window.__ml && window.__ml.goToFraction(\(target));")
                    jumped = true
                }
                isLoading = false
                reveal()
            }
            // A pending jump reports again once it lands; saving the pre-jump
            // position here would overwrite where the reader actually left off.
            if !jumped { persistPosition() }
            curl.setNeedsRefresh()

        case "edge":
            advanceDocument(by: (message["direction"] as? String) == "next" ? 1 : -1)

        case "link":
            if let href = message["href"] as? String, let url = URL(string: href) {
                follow(link: url)
            }

        case "tap":
            switch message["zone"] as? String {
            case "left": if !curl.turn(forward: false) { goToPreviousPage() }
            case "right": if !curl.turn(forward: true) { goToNextPage() }
            default: withAnimation(.easeInOut(duration: 0.2)) { showsChrome.toggle() }
            }

        default:
            break
        }
    }

    /// Moves to the target of a link inside the book, keeping the spine index
    /// and saved position in step. Targets outside the spine are ignored.
    fileprivate func follow(link url: URL) {
        guard let source else { return }
        let path = url.resolvingSymlinksInPath().path
        guard let index = source.documents.firstIndex(where: { $0.resolvingSymlinksInPath().path == path }) else {
            return
        }
        let fragment = url.fragment(percentEncoded: false).flatMap { $0.isEmpty ? nil : $0 }
        if index != documentIndex {
            goToDocument(at: index, fraction: 0, fragment: fragment)
        } else if let fragment {
            evaluate("window.__ml && window.__ml.goToFragment(\(jsString(fragment)));")
        } else {
            evaluate("window.__ml && window.__ml.goToPage(0);")
        }
    }

    fileprivate func didFinishNavigation() {
        // The engine script reports "ready" itself; this is the safety net for
        // documents where it failed to run at all.
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            if isLoading {
                isLoading = false
                reveal()
            }
        }
    }

    fileprivate func didFail(_ error: Error) {
        isLoading = false
        loadError = error.localizedDescription
        reveal()
    }

    private func reveal() {
        UIView.animate(withDuration: 0.15) { self.webView.alpha = 1 }
    }

    private func persistPosition() {
        guard let book else { return }
        book.spineIndex = documentIndex
        book.spineFraction = fraction
        book.progress = overallProgress
        book.lastOpenedAt = .now
        if overallProgress >= 0.985 { book.isFinished = true }
    }

    private func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private func evaluate(_ script: String) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func jsString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data()
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    // MARK: - Stylesheet

    private func readerCSS() -> String {
        let theme = settings.theme
        let horizontal = Int(settings.margin)
        // The reader view already keeps the bars' height clear above and below.
        let vertical = max(12, Int(settings.margin * 0.5))
        let fontStack = settings.font.cssStack ?? "-apple-system, system-ui, sans-serif"
        let alignment = settings.justified ? "justify" : "initial"
        let linkColor = theme.isDark ? "#6fb0ff" : "#0a58ca"

        var css = """
        :root { color-scheme: \(theme.isDark ? "dark" : "light"); }
        html {
          -webkit-text-size-adjust: none;
          font-size: \(Int(settings.fontScale))%;
          background-color: \(theme.backgroundCSS);
        }
        body {
          box-sizing: border-box;
          margin: 0 !important;
          padding: \(vertical)px \(horizontal)px !important;
          max-width: none !important;
          background-color: \(theme.backgroundCSS);
          color: \(theme.foregroundCSS);
          font-family: \(fontStack);
          line-height: \(String(format: "%.2f", settings.lineHeight));
          text-align: \(alignment);
          -webkit-hyphens: auto;
          hyphens: auto;
          word-wrap: break-word;
        }
        img, svg, image, video, table {
          max-width: 100% !important;
          height: auto !important;
        }
        img, svg, image {
          /* A little shorter than a page: with the line box around an inline
             image, a full-page-tall one never fits a fresh column, and WebKit
             slices it across two pages instead of moving it. */
          max-height: calc(100vh - \(vertical * 2)px - 2em) !important;
          object-fit: contain;
        }
        img, svg, figure { break-inside: avoid; }
        pre, code { white-space: pre-wrap !important; word-break: break-word; }
        a, a * { color: \(linkColor) !important; }
        """

        if theme != .light {
            // Author stylesheets assume a white page; force the chosen palette.
            css += """

            body, body *:not(a):not(a *) {
              color: \(theme.foregroundCSS) !important;
              background-color: transparent !important;
              border-color: currentColor;
            }
            """
        }

        switch settings.layout {
        case .paged:
            css += """

            html, body { height: 100vh !important; }
            /* Clip at the viewport only. Clipping the body would also clip every
               column past the first, and the columns move with its transform. */
            html { overflow: hidden !important; }
            body {
              overflow: visible !important;
              column-width: calc(100vw - \(horizontal * 2)px);
              column-gap: \(horizontal * 2)px;
              column-fill: auto;
              will-change: transform;
            }
            """
            if settings.twoPagesInLandscape && UIDevice.current.userInterfaceIdiom == .pad {
                // Two outer margins plus a gutter of two margins make one spread
                // exactly one viewport wide, so pages still turn by 100vw. The
                // media query follows rotation and split view without a reload.
                let spreadMargin = max(horizontal, 48)
                css += """

                @media (orientation: landscape) and (min-width: 700px) {
                  body {
                    padding-left: \(spreadMargin)px !important;
                    padding-right: \(spreadMargin)px !important;
                    column-width: calc(50vw - \(spreadMargin * 2)px - 1px);
                    column-count: 2;
                    column-gap: \(spreadMargin * 2)px;
                  }
                }
                """
            }
        case .scrolling:
            css += """

            html, body { height: auto !important; overflow-x: hidden !important; }
            body { padding-bottom: \(vertical * 3)px !important; }
            """
        }

        return css
    }
}

/// Keeps WebKit's Objective-C delegates off the observable model.
private final class Bridge: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    weak var model: ReflowableReaderModel?

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated { model?.handle(message: body) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { model?.didFinishNavigation() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { model?.didFail(error) }
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        MainActor.assumeIsolated { model?.didFail(error) }
    }

    /// Internal links stay in the reader; external ones open in Safari.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        guard navigationAction.navigationType == .linkActivated else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if url.isFileURL {
            // The engine normally intercepts these; this catches any it missed.
            MainActor.assumeIsolated { model?.follow(link: url) }
        } else {
            UIApplication.shared.open(url)
        }
    }
}
