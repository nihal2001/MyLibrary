import UIKit
import WebKit

/// A rendered print job: the PDF that goes to the printer, and its length.
struct PrintedBook {
    var data: Data
    var pageCount: Int
}

enum PrintError: LocalizedError {
    case cannotLoad
    case nothingToPrint

    var errorDescription: String? {
        switch self {
        case .cannotLoad: return "This book couldn't be prepared for printing."
        case .nothingToPrint: return "There's nothing to print in the selected pages."
        }
    }
}

/// Lays a reflowable book out as printed pages.
///
/// The chosen spine documents are merged into one page inside an offscreen
/// `WKWebView`, the print stylesheet is applied, and WebKit's print formatter
/// paginates the result into a PDF at the chosen paper size. What the preview
/// shows is exactly what the printer receives.
@MainActor
final class BookPrintComposer: NSObject, WKNavigationDelegate {
    private let source: ReadingSource
    private let webView: WKWebView
    /// The documents currently merged into the page, so a change that only
    /// touches the stylesheet doesn't re-read and re-parse the book.
    private var assembled: [URL]?
    private var shellLoaded = false
    private var navigation: CheckedContinuation<Void, Error>?
    /// Renders run one at a time; a new one waits for the last to wind down.
    private var tail: Task<Void, Never>?

    init(source: ReadingSource) {
        self.source = source
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = true
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 612, height: 792), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func render(documents: Range<Int>,
                layout: PrintLayout,
                title: String,
                progress: @escaping (Double) -> Void = { _ in }) async throws -> PrintedBook {
        let previous = tail
        let work = Task {
            await previous?.value
            try Task.checkCancellation()
            return try await self.performRender(documents: documents, layout: layout,
                                                title: title, progress: progress)
        }
        tail = Task { _ = try? await work.value }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func performRender(documents: Range<Int>,
                               layout: PrintLayout,
                               title: String,
                               progress: (Double) -> Void) async throws -> PrintedBook {
        let urls = documents.compactMap { source.documentURL(at: $0) }
        guard !urls.isEmpty else { throw PrintError.nothingToPrint }

        try await loadShellIfNeeded()
        if assembled != urls {
            try await assemble(urls)
            assembled = urls
        }
        try Task.checkCancellation()
        _ = try await webView.callAsyncJavaScript(Self.applyScript,
                                                  arguments: ["css": layout.css],
                                                  contentWorld: .page)
        try Task.checkCancellation()
        return try await drawPDF(layout: layout, title: title, progress: progress)
    }

    // MARK: - Page

    private func loadShellIfNeeded() async throws {
        guard !shellLoaded else { return }
        // A file inside the book's own folder, so the web view may read the
        // book's stylesheets, fonts, and images from it.
        let shell = source.rootURL.appendingPathComponent(".ml-print.html")
        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"/><style id="ml-print"></style></head><body></body></html>
        """
        do {
            try html.write(to: shell, atomically: true, encoding: .utf8)
        } catch {
            throw PrintError.cannotLoad
        }
        try await withCheckedThrowingContinuation { continuation in
            navigation = continuation
            webView.loadFileURL(shell, allowingReadAccessTo: source.rootURL)
        }
        shellLoaded = true
    }

    private func assemble(_ urls: [URL]) async throws {
        let chapters: [[String: Any]] = urls.map { url in
            let text = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1))
                ?? ""
            let isXML = ["xhtml", "xml", "xht"].contains(url.pathExtension.lowercased())
            return ["url": url.absoluteString, "text": text, "xml": isXML]
        }
        _ = try await webView.callAsyncJavaScript(Self.assembleScript,
                                                  arguments: ["chapters": chapters],
                                                  contentWorld: .page)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.navigation?.resume()
        self.navigation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.navigation?.resume(throwing: PrintError.cannotLoad)
        self.navigation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.navigation?.resume(throwing: PrintError.cannotLoad)
        self.navigation = nil
    }

    // MARK: - PDF

    private func drawPDF(layout: PrintLayout, title: String, progress: (Double) -> Void) async throws -> PrintedBook {
        let renderer = BookPageRenderer(layout: layout, title: title)
        renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)

        let count = renderer.numberOfPages
        guard count > 0 else { throw PrintError.nothingToPrint }
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: count))

        let data = NSMutableData()
        var mediaBox = layout.paperRect
        let info = [kCGPDFContextTitle as String: title,
                    kCGPDFContextCreator as String: "My Library"] as CFDictionary
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info) else {
            throw PrintError.cannotLoad
        }

        for page in 0..<count {
            if Task.isCancelled {
                context.closePDF()
                throw CancellationError()
            }
            context.beginPDFPage(nil)
            context.saveGState()
            // UIKit draws top-down; PDF pages are bottom-up.
            context.translateBy(x: 0, y: mediaBox.height)
            context.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(context)
            renderer.drawPage(at: page, in: mediaBox)
            UIGraphicsPopContext()
            context.restoreGState()
            context.endPDFPage()

            progress(Double(page + 1) / Double(count))
            // Let the progress bar and the Cancel button breathe on long books.
            if page % 6 == 5 { await Task.yield() }
        }
        context.closePDF()
        return PrintedBook(data: data as Data, pageCount: count)
    }

    // MARK: - Scripts

    /// Merges the chapters into the shell page, each in its own `<section>`.
    /// Chapters may live in different folders, so every relative reference is
    /// made absolute against the chapter it came from before it moves.
    private static let assembleScript = """
    const XLINK = 'http://www.w3.org/1999/xlink';
    const XML = 'http://www.w3.org/XML/1998/namespace';
    const anchor = document.getElementById('ml-print');
    document.body.textContent = '';
    document.querySelectorAll('.ml-book-style').forEach(node => node.remove());

    const absolute = (value, base) => {
      if (!value || value.startsWith('#') || /^(data|blob|https?|mailto|tel):/i.test(value)) return value;
      try { return new URL(value, base).href; } catch (e) { return value; }
    };
    const fixCSS = (text, base) => text.replace(/url\\(\\s*(['"]?)([^'")]+)\\1\\s*\\)/g,
      (match, quote, url) => 'url("' + absolute(url.trim(), base) + '")');
    const addToHead = node => { node.classList.add('ml-book-style'); document.head.insertBefore(node, anchor); };

    const seen = new Set();
    let lang = '';
    for (const chapter of chapters) {
      const parser = new DOMParser();
      let doc = parser.parseFromString(chapter.text, chapter.xml ? 'application/xhtml+xml' : 'text/html');
      if (doc.getElementsByTagName('parsererror').length) doc = parser.parseFromString(chapter.text, 'text/html');
      const root = doc.documentElement;
      if (!lang && root) lang = root.getAttribute('lang') || root.getAttributeNS(XML, 'lang') || '';

      for (const link of doc.querySelectorAll('link[href]')) {
        if (!/stylesheet/i.test(link.getAttribute('rel') || '')) continue;
        const href = absolute(link.getAttribute('href'), chapter.url);
        if (seen.has(href)) continue;
        seen.add(href);
        const node = document.createElement('link');
        node.rel = 'stylesheet';
        node.href = href;
        addToHead(node);
      }
      for (const style of doc.querySelectorAll('head style')) {
        const text = fixCSS(style.textContent, chapter.url);
        if (seen.has(text)) continue;
        seen.add(text);
        const node = document.createElement('style');
        node.textContent = text;
        addToHead(node);
      }

      const body = doc.body || doc.getElementsByTagName('body')[0];
      if (!body) continue;
      body.querySelectorAll('script').forEach(node => node.remove());
      for (const el of body.getElementsByTagName('*')) {
        const isLink = el.localName === 'a';
        for (const attr of ['src', 'href', 'poster', 'data']) {
          if (isLink && attr === 'href') continue;
          const value = el.getAttribute(attr);
          if (value !== null) el.setAttribute(attr, absolute(value, chapter.url));
        }
        const xlink = el.getAttributeNS(XLINK, 'href');
        if (xlink !== null && !isLink) el.setAttributeNS(XLINK, 'xlink:href', absolute(xlink, chapter.url));
        if (el.hasAttribute('style')) el.setAttribute('style', fixCSS(el.getAttribute('style'), chapter.url));
        if (el.hasAttribute('srcset')) el.removeAttribute('srcset');
        if (el.hasAttribute('loading')) el.removeAttribute('loading');
      }
      for (const style of body.querySelectorAll('style')) style.textContent = fixCSS(style.textContent, chapter.url);

      const section = document.createElement('section');
      section.className = ('ml-chapter ' + (body.getAttribute('class') || '')).trim();
      for (const child of Array.from(body.childNodes)) section.appendChild(document.importNode(child, true));
      document.body.appendChild(section);
    }
    if (lang) document.documentElement.lang = lang;
    """

    /// Swaps in the print stylesheet and waits for fonts and images, so the
    /// formatter never paginates a page that is still changing size.
    private static let applyScript = """
    document.getElementById('ml-print').textContent = css;
    const pending = Array.from(document.images)
      .filter(img => !img.complete)
      .map(img => new Promise(resolve => { img.addEventListener('load', resolve); img.addEventListener('error', resolve); }));
    const links = Array.from(document.querySelectorAll('link.ml-book-style'))
      .filter(link => !link.sheet)
      .map(link => new Promise(resolve => { link.addEventListener('load', resolve); link.addEventListener('error', resolve); }));
    await Promise.race([
      Promise.all([...pending, ...links]).then(() => document.fonts.ready),
      new Promise(resolve => setTimeout(resolve, 8000))
    ]);
    document.body.getBoundingClientRect();
    """
}

/// Paper and margins come from the print options rather than a printer, so the
/// PDF looks the same wherever it ends up; the printer scales it to its paper.
private final class BookPageRenderer: UIPrintPageRenderer {
    private let layout: PrintLayout
    private let title: String

    init(layout: PrintLayout, title: String) {
        self.layout = layout
        self.title = title
        super.init()
        headerHeight = layout.headerHeight
        footerHeight = layout.footerHeight
    }

    override var paperRect: CGRect { layout.paperRect }
    override var printableRect: CGRect { layout.printableRect }

    private var attributes: [NSAttributedString.Key: Any] {
        let size = max(7, CGFloat(layout.fontSize) * 0.78)
        let font: UIFont
        if let name = layout.font?.uiFontName, let face = UIFont(name: name, size: size) {
            font = face
        } else {
            font = .systemFont(ofSize: size)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        return [.font: font, .foregroundColor: UIColor(white: 0.35, alpha: 1), .paragraphStyle: paragraph]
    }

    override func drawHeaderForPage(at pageIndex: Int, in headerRect: CGRect) {
        guard layout.showsTitle, !title.isEmpty else { return }
        let text = NSAttributedString(string: title, attributes: attributes)
        let height = text.size().height
        text.draw(in: CGRect(x: headerRect.minX, y: headerRect.minY,
                             width: headerRect.width, height: height))
    }

    override func drawFooterForPage(at pageIndex: Int, in footerRect: CGRect) {
        guard layout.showsPageNumbers else { return }
        let text = NSAttributedString(string: "\(pageIndex + 1)", attributes: attributes)
        let height = text.size().height
        text.draw(in: CGRect(x: footerRect.minX, y: footerRect.maxY - height,
                             width: footerRect.width, height: height))
    }
}

private extension ReaderFont {
    /// The face used for the running title and page numbers.
    var uiFontName: String? {
        switch self {
        case .system, .serif: return nil
        case .georgia: return "Georgia"
        case .palatino: return "Palatino-Roman"
        case .times: return "TimesNewRomanPSMT"
        }
    }
}

// MARK: - Presenting

/// Hands a file or a rendered PDF to the system print panel, or to the share sheet.
@MainActor
enum PrintPresenter {
    private static let parent = ParentProvider()

    static func canPrint(_ url: URL) -> Bool {
        UIPrintInteractionController.canPrint(url)
    }

    /// Prints a file as-is. PDFs go through this: they are already paginated.
    static func printFile(at url: URL, jobName: String) {
        present(item: url, jobName: jobName)
    }

    static func print(_ book: PrintedBook, jobName: String) {
        present(item: book.data, jobName: jobName)
    }

    /// Offers the rendered PDF to Files, Mail, AirDrop, and the rest.
    static func share(_ book: PrintedBook, fileName: String) {
        let safeName = fileName
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent((safeName.isEmpty ? "Book" : safeName) + ".pdf")
        do {
            try book.data.write(to: url, options: .atomic)
        } catch {
            return
        }
        guard let presenter = ParentProvider.topViewController() else { return }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        presenter.present(activity, animated: true)
    }

    private static func present(item: Any, jobName: String) {
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo.printInfo()
        info.jobName = jobName
        info.outputType = .general
        controller.printInfo = info
        controller.printingItem = item
        controller.delegate = parent
        controller.present(animated: true)
    }

    /// The print panel presents from whatever is frontmost, which may be a
    /// sheet, rather than from the window's root.
    private final class ParentProvider: NSObject, UIPrintInteractionControllerDelegate {
        func printInteractionControllerParentViewController(_ controller: UIPrintInteractionController) -> UIViewController? {
            MainActor.assumeIsolated { Self.topViewController() }
        }

        @MainActor
        static func topViewController() -> UIViewController? {
            let window = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow }
            var top = window?.rootViewController
            while let presented = top?.presentedViewController, !presented.isBeingDismissed {
                top = presented
            }
            return top
        }
    }
}
