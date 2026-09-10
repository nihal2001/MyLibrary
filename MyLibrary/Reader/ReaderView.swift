import SwiftData
import SwiftUI
import WebKit

/// Picks the right renderer for a book and owns the shared reader chrome.
struct ReaderView: View {
    @Bindable var book: Book

    var body: some View {
        Group {
            switch book.format {
            case .pdf: PDFReaderView(book: book)
            case .epub, .text: ReflowableReaderView(book: book)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(false)
        .onAppear { book.lastOpenedAt = .now }
    }
}

// MARK: - Reflowable reader (EPUB, text)

struct ReflowableReaderView: View {
    @Bindable var book: Book
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var model = ReflowableReaderModel()
    @State private var settings = ReaderSettings.shared
    @State private var showsTOC = false
    @State private var showsBookmarks = false
    @State private var showsSettings = false
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false

    var body: some View {
        ZStack {
            settings.theme.background.ignoresSafeArea()

            WebViewContainer(webView: model.webView)
                .ignoresSafeArea(edges: .bottom)

            if model.isLoading {
                ProgressView()
                    .controlSize(.large)
                    .tint(settings.theme.foreground)
            }

            if let message = model.loadError {
                ReaderErrorView(message: message) { dismiss() }
            }

            ReaderChrome(book: book,
                         model: model,
                         settings: settings,
                         scrubValue: $scrubValue,
                         isScrubbing: $isScrubbing,
                         onClose: { dismiss() },
                         onContents: { showsTOC = true },
                         onBookmarks: { showsBookmarks = true },
                         onSettings: { showsSettings = true },
                         onToggleBookmark: toggleBookmark)
        }
        .task { model.open(book: book) }
        .onChange(of: settings.styleSignature) { model.applySettingsIfNeeded() }
        .onChange(of: model.overallProgress) { _, value in
            if !isScrubbing { scrubValue = value }
        }
        .sheet(isPresented: $showsTOC) {
            TableOfContentsView(entries: model.source?.toc ?? [],
                                currentIndex: model.documentIndex,
                                currentEntryIndex: model.tocIndex) { entry in
                model.go(to: entry)
            }
        }
        .sheet(isPresented: $showsBookmarks) {
            BookmarkListView(book: book) { bookmark in
                model.go(to: bookmark)
            }
        }
        .sheet(isPresented: $showsSettings) {
            ReaderSettingsView(settings: settings)
                .presentationDetents([.height(420), .large])
        }
        .persistentSystemOverlays(model.showsChrome ? .visible : .hidden)
        .preferredColorScheme(settings.theme.isDark ? .dark : .light)
    }

    private func toggleBookmark() {
        if let existing = model.matchingBookmark(in: book) {
            context.delete(existing)
            return
        }
        Task {
            let bookmark = await model.makeBookmark()
            bookmark.book = book
            context.insert(bookmark)
        }
    }
}

/// Hosts the reader's `WKWebView`, which is owned by the model so it survives
/// SwiftUI view updates.
struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct ReaderErrorView: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Can't Open Book", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Back to Library", action: onClose)
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Chrome

private struct ReaderChrome: View {
    @Bindable var book: Book
    let model: ReflowableReaderModel
    let settings: ReaderSettings
    @Binding var scrubValue: Double
    @Binding var isScrubbing: Bool
    let onClose: () -> Void
    let onContents: () -> Void
    let onBookmarks: () -> Void
    let onSettings: () -> Void
    let onToggleBookmark: () -> Void

    private var isBookmarked: Bool { model.matchingBookmark(in: book) != nil }

    var body: some View {
        VStack(spacing: 0) {
            if model.showsChrome {
                topBar.transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
            if model.showsChrome {
                bottomBar.transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                footer
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.showsChrome)
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            Button(action: onClose) {
                Label("Library", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
            }
            VStack(spacing: 2) {
                Text(book.title).font(.footnote.weight(.semibold)).lineLimit(1)
                if !model.chapterTitle.isEmpty {
                    Text(model.chapterTitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)

            Button(action: onToggleBookmark) {
                Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
            }
            Menu {
                Button { onContents() } label: { Label("Contents", systemImage: "list.bullet") }
                Button { onBookmarks() } label: { Label("Bookmarks", systemImage: "bookmark") }
                Button { onSettings() } label: { Label("Themes & Settings", systemImage: "textformat.size") }
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
            Slider(value: $scrubValue, in: 0...1) { editing in
                isScrubbing = editing
                if !editing { model.seek(toOverall: scrubValue) }
            }
            HStack {
                Text(model.pageDescription)
                Spacer()
                Text("\(Int((model.overallProgress * 100).rounded()))% read")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.bar)
    }

    /// A quiet progress line while the chrome is hidden.
    private var footer: some View {
        HStack {
            Text(model.pageDescription)
            Spacer()
            Text("\(Int((model.overallProgress * 100).rounded()))%")
        }
        .font(.caption2)
        .foregroundStyle(settings.theme.foreground.opacity(0.45))
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }
}
