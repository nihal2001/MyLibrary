import PDFKit
import SwiftData
import SwiftUI

/// PDFKit-backed reader for fixed-layout books. Position is a page index.
struct PDFReaderView: View {
    @Bindable var book: Book
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var controller = PDFReaderController()
    @State private var settings = ReaderSettings.shared
    @State private var showsChrome = true
    @State private var showsBookmarks = false
    @State private var showsOutline = false
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false

    private var isBookmarked: Bool {
        book.bookmarks.contains { $0.pageIndex == controller.pageIndex }
    }

    var body: some View {
        ZStack {
            (settings.theme.isDark ? Color.black : Color(.systemGray6)).ignoresSafeArea()

            PDFViewContainer(controller: controller)
                .ignoresSafeArea(edges: .bottom)

            if !controller.isLoaded {
                if let message = controller.loadError {
                    ReaderErrorView(message: message) { dismiss() }
                } else {
                    ProgressView().controlSize(.large)
                }
            }

            VStack(spacing: 0) {
                if showsChrome { topBar.transition(.move(edge: .top).combined(with: .opacity)) }
                Spacer(minLength: 0)
                if showsChrome { bottomBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
        }
        .task {
            controller.onCenterTap = {
                withAnimation(.easeInOut(duration: 0.2)) { showsChrome.toggle() }
            }
            controller.twoPagesInLandscape = settings.twoPagesInLandscape
            controller.swipesToTurn = settings.pdfSwipeToTurn
            controller.load(url: book.fileURL, startingAt: book.pageIndex)
        }
        .onChange(of: settings.twoPagesInLandscape) { _, value in
            controller.twoPagesInLandscape = value
        }
        .onChange(of: settings.pdfSwipeToTurn) { _, value in
            controller.swipesToTurn = value
        }
        .onChange(of: controller.pageIndex) { _, page in
            book.pageIndex = page
            if controller.pageCount > 0 {
                book.progress = min(1, Double(page + 1) / Double(controller.pageCount))
                if book.progress >= 0.995 { book.isFinished = true }
            }
            book.lastOpenedAt = .now
            if !isScrubbing { scrubValue = Double(page) }
        }
        .sheet(isPresented: $showsBookmarks) {
            BookmarkListView(book: book) { bookmark in
                controller.go(toPage: bookmark.pageIndex)
            }
        }
        .sheet(isPresented: $showsOutline) {
            PDFOutlineView(entries: controller.outline) { page in
                controller.go(toPage: page)
            }
        }
        .preferredColorScheme(settings.theme.isDark ? .dark : nil)
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            Button { dismiss() } label: { Image(systemName: "chevron.left") }
            VStack(spacing: 2) {
                Text(book.title).font(.footnote.weight(.semibold)).lineLimit(1)
                Text("\(controller.pageIndex + 1) of \(max(controller.pageCount, 1))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            Button(action: toggleBookmark) {
                Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
            }
            Menu {
                if !controller.outline.isEmpty {
                    Button { showsOutline = true } label: { Label("Contents", systemImage: "list.bullet") }
                }
                Button { showsBookmarks = true } label: { Label("Bookmarks", systemImage: "bookmark") }
                Divider()
                Picker("Page Turning", selection: $settings.pdfSwipeToTurn) {
                    Label("Scroll", systemImage: "arrow.up.and.down").tag(false)
                    Label("Swipe", systemImage: "arrow.left.and.right").tag(true)
                }
                if UIDevice.current.userInterfaceIdiom == .pad {
                    Toggle("Two Pages in Landscape", isOn: $settings.twoPagesInLandscape)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            if controller.pageCount > 1 {
                Slider(value: $scrubValue,
                       in: 0...Double(controller.pageCount - 1),
                       step: 1) { editing in
                    isScrubbing = editing
                    if !editing { controller.go(toPage: Int(scrubValue)) }
                }
            }
            Text(book.progressDescription)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.bar)
    }

    private func toggleBookmark() {
        if let existing = book.bookmarks.first(where: { $0.pageIndex == controller.pageIndex }) {
            context.delete(existing)
            return
        }
        let bookmark = Bookmark(chapterTitle: controller.outlineTitle(forPage: controller.pageIndex)
                                    ?? "Page \(controller.pageIndex + 1)",
                                snippet: controller.snippet(forPage: controller.pageIndex),
                                pageIndex: controller.pageIndex)
        bookmark.book = book
        context.insert(bookmark)
    }
}

struct PDFOutlineEntry: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var page: Int
    var level: Int
}

/// Owns the `PDFView` and mirrors its state into SwiftUI.
@MainActor
@Observable
final class PDFReaderController {
    private(set) var pageIndex = 0
    private(set) var pageCount = 0
    private(set) var isLoaded = false
    private(set) var loadError: String?
    private(set) var outline: [PDFOutlineEntry] = []

    /// One page (or spread) at a time, turned sideways, instead of a scroll.
    var swipesToTurn = false { didSet { applyDisplayMode() } }
    var twoPagesInLandscape = true { didSet { applyDisplayMode() } }

    @ObservationIgnored let pdfView = ReaderPDFView()
    @ObservationIgnored private var observer: NSObjectProtocol?
    /// The page to open at. PDFView ignores `go(to:)` until it has a size, and
    /// meanwhile reports page 0, which would overwrite the saved position.
    @ObservationIgnored private var pendingPage: Int?
    @ObservationIgnored private var isLandscape = false
    /// Taps that don't turn a page, used to show or hide the reader's bars.
    @ObservationIgnored var onCenterTap: (() -> Void)?

    init() {
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.usePageViewController(false)
        pdfView.backgroundColor = .systemGray6
        // PDFKit reuses tiles aggressively; this keeps memory flat on big files.
        pdfView.pageShadowsEnabled = false
        pdfView.onLayout = { [weak self] in self?.viewDidLayout() }
        pdfView.onSwipe = { [weak self] forward in self?.turnPage(forward: forward) }
        pdfView.onTap = { [weak self] point in self?.handleTap(at: point) }

        observer = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: pdfView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncPageIndex() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func load(url: URL, startingAt page: Int) {
        guard !isLoaded, loadError == nil else { return }
        guard let document = PDFDocument(url: url) else {
            loadError = "This PDF couldn't be opened. The file may be damaged."
            return
        }
        pdfView.document = document
        pageCount = document.pageCount
        outline = Self.flattenOutline(document)
        isLoaded = true
        pendingPage = page
        applyPendingPage()
    }

    private func viewDidLayout() {
        let landscape = pdfView.bounds.width > pdfView.bounds.height
        if landscape != isLandscape {
            isLandscape = landscape
            applyDisplayMode()
        }
        applyPendingPage()
    }

    private func applyPendingPage() {
        guard let page = pendingPage, pdfView.bounds.width > 0, pdfView.bounds.height > 0 else { return }
        pendingPage = nil
        go(toPage: page)
    }

    func go(toPage index: Int) {
        guard let document = pdfView.document,
              let page = document.page(at: min(max(0, index), max(0, document.pageCount - 1))) else { return }
        pdfView.go(to: page)
        syncPageIndex()
    }

    /// In swipe mode the outer thirds turn pages, as in the EPUB reader; the
    /// middle, and any tap while scrolling, shows or hides the bars.
    private func handleTap(at point: CGPoint) {
        let width = pdfView.bounds.width
        if swipesToTurn, width > 0 {
            if point.x < width / 3 { turnPage(forward: false); return }
            if point.x > width * 2 / 3 { turnPage(forward: true); return }
        }
        onCenterTap?()
    }

    /// Swipe mode: moves one page, or one spread, with a sideways slide.
    func turnPage(forward: Bool) {
        guard swipesToTurn else { return }
        // While zoomed in, a swipe pans the page rather than turning it.
        guard pdfView.scaleFactor <= pdfView.scaleFactorForSizeToFit * 1.01 else { return }
        guard forward ? pdfView.canGoToNextPage : pdfView.canGoToPreviousPage else { return }

        let transition = CATransition()
        transition.type = .push
        transition.subtype = forward ? .fromRight : .fromLeft
        transition.duration = 0.25
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pdfView.layer.add(transition, forKey: "pageTurn")

        if forward { pdfView.goToNextPage(nil) } else { pdfView.goToPreviousPage(nil) }
    }

    func snippet(forPage index: Int) -> String {
        guard let page = pdfView.document?.page(at: index), let text = page.string else { return "" }
        let clean = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count > 180 ? String(clean.prefix(180)) + "…" : clean
    }

    func outlineTitle(forPage index: Int) -> String? {
        outline.last { $0.page <= index }?.title
    }

    private func syncPageIndex() {
        guard pendingPage == nil, let document = pdfView.document, let current = pdfView.currentPage else { return }
        let index = document.index(for: current)
        if index != pageIndex { pageIndex = index }
    }

    private func applyDisplayMode() {
        // Facing pages only on iPad, and only while the reader is landscape.
        let twoUp = twoPagesInLandscape && isLandscape && UIDevice.current.userInterfaceIdiom == .pad
        let current = pdfView.currentPage
        switch (swipesToTurn, twoUp) {
        case (false, false): pdfView.displayMode = .singlePageContinuous
        case (false, true): pdfView.displayMode = .twoUpContinuous
        case (true, false): pdfView.displayMode = .singlePage
        case (true, true): pdfView.displayMode = .twoUp
        }
        // Swipe mode turns pages itself, so PDFKit never scrolls between them.
        pdfView.displayDirection = .vertical
        // Book-style spreads: the cover stands alone, then left/right pairs.
        pdfView.displaysAsBook = twoUp
        // Refit to the new layout: a whole page or spread, or the column width.
        // Re-setting autoScales while it is already on doesn't rescale, and a
        // mode change during layout isn't measured until the next pass.
        refitScale()
        DispatchQueue.main.async { [weak self] in self?.refitScale() }
        if let current, pendingPage == nil { pdfView.go(to: current) }
    }

    private func refitScale() {
        pdfView.autoScales = false
        pdfView.autoScales = true
    }

    private static func flattenOutline(_ document: PDFDocument) -> [PDFOutlineEntry] {
        guard let root = document.outlineRoot else { return [] }
        var entries: [PDFOutlineEntry] = []

        func walk(_ node: PDFOutline, level: Int) {
            for index in 0..<node.numberOfChildren {
                guard let child = node.child(at: index) else { continue }
                if let destination = child.destination,
                   let page = destination.page,
                   let title = child.label?.nilIfBlank {
                    entries.append(PDFOutlineEntry(title: title,
                                                   page: document.index(for: page),
                                                   level: level))
                }
                walk(child, level: level + 1)
            }
        }
        walk(root, level: 0)
        return entries
    }
}

/// Reports layout passes, so the saved page can be restored once there is a real
/// size, plus taps and sideways swipes. PDFKit's own recognizers consume touches
/// before SwiftUI gestures on the hosting view would see them, so these live here.
final class ReaderPDFView: PDFView {
    var onLayout: (() -> Void)?
    /// Called with `true` for a swipe toward the next page.
    var onSwipe: ((Bool) -> Void)?
    /// Called with the tap location in this view's coordinates.
    var onTap: ((CGPoint) -> Void)?
    private let gestureDelegate = SimultaneousGestures()
    private let tap = UITapGestureRecognizer()
    private var waitsForDoubleTaps = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        for direction: UISwipeGestureRecognizer.Direction in [.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = direction
            // Work alongside PDFKit's own gestures (selection, links, zoom).
            swipe.delegate = gestureDelegate
            addGestureRecognizer(swipe)
        }
        tap.addTarget(self, action: #selector(tapped(_:)))
        tap.delegate = gestureDelegate
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // PDFKit builds its scroll view lazily; once it exists, make a single
        // tap wait for double-tap zoom so a double tap doesn't also turn a page.
        if !waitsForDoubleTaps {
            let doubleTaps = Self.recognizers(in: self).compactMap { $0 as? UITapGestureRecognizer }
                .filter { $0 !== tap && $0.numberOfTapsRequired == 2 }
            if !doubleTaps.isEmpty {
                doubleTaps.forEach { tap.require(toFail: $0) }
                waitsForDoubleTaps = true
            }
        }
        onLayout?()
    }

    @objc private func swiped(_ gesture: UISwipeGestureRecognizer) {
        onSwipe?(gesture.direction == .left)
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        onTap?(gesture.location(in: self))
    }

    private static func recognizers(in view: UIView) -> [UIGestureRecognizer] {
        (view.gestureRecognizers ?? []) + view.subviews.flatMap { recognizers(in: $0) }
    }
}

private final class SimultaneousGestures: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

struct PDFViewContainer: UIViewRepresentable {
    let controller: PDFReaderController

    func makeUIView(context: Context) -> PDFView { controller.pdfView }
    func updateUIView(_ uiView: PDFView, context: Context) {}
}

struct PDFOutlineView: View {
    let entries: [PDFOutlineEntry]
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(entries) { entry in
                Button {
                    onSelect(entry.page)
                    dismiss()
                } label: {
                    HStack {
                        Text(entry.title).lineLimit(2)
                        Spacer()
                        Text("\(entry.page + 1)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.leading, CGFloat(entry.level) * 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
