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
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showsChrome.toggle() } }

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
            controller.twoPagesInLandscape = settings.twoPagesInLandscape
            controller.load(url: book.fileURL, startingAt: book.pageIndex)
        }
        .onChange(of: settings.twoPagesInLandscape) { _, value in
            controller.twoPagesInLandscape = value
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
                Picker("Scrolling", selection: $controller.isContinuous) {
                    Text("Continuous").tag(true)
                    Text("Page by Page").tag(false)
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

    var isContinuous = true { didSet { applyDisplayMode() } }
    var twoPagesInLandscape = true { didSet { applyDisplayMode() } }

    @ObservationIgnored let pdfView = LayoutReportingPDFView()
    @ObservationIgnored private var observer: NSObjectProtocol?
    /// The page to open at. PDFView ignores `go(to:)` until it has a size, and
    /// meanwhile reports page 0, which would overwrite the saved position.
    @ObservationIgnored private var pendingPage: Int?
    @ObservationIgnored private var isLandscape = false

    init() {
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.usePageViewController(false)
        pdfView.backgroundColor = .systemGray6
        // PDFKit reuses tiles aggressively; this keeps memory flat on big files.
        pdfView.pageShadowsEnabled = false
        pdfView.onLayout = { [weak self] in self?.viewDidLayout() }

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
        switch (isContinuous, twoUp) {
        case (true, false): pdfView.displayMode = .singlePageContinuous
        case (true, true): pdfView.displayMode = .twoUpContinuous
        case (false, false): pdfView.displayMode = .singlePage
        case (false, true): pdfView.displayMode = .twoUp
        }
        pdfView.displayDirection = isContinuous ? .vertical : .horizontal
        // Book-style spreads: the cover stands alone, then left/right pairs.
        pdfView.displaysAsBook = twoUp
        if let current, pendingPage == nil { pdfView.go(to: current) }
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

/// Tells the controller when it has been laid out, so the saved page can be
/// restored once there is a real size to scroll within.
final class LayoutReportingPDFView: PDFView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
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
