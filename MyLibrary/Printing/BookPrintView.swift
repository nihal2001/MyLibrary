import PDFKit
import SwiftUI

/// Print setup for EPUB and text books: a live preview of the printed pages
/// beside the options that shape them.
struct BookPrintView: View {
    let book: Book
    /// The reader's already-unpacked book; the sheet unpacks it when opened from the library.
    var source: ReadingSource?
    /// The spine document the reader is showing.
    var currentIndex: Int

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var options = PrintOptions.shared
    @State private var loadedSource: ReadingSource?
    @State private var loadError: String?
    @State private var range: PrintRange = .wholeBook
    @State private var firstChapter = 0
    @State private var lastChapter = 0

    @State private var previewComposer: BookPrintComposer?
    @State private var preview: PrintedBook?
    @State private var isRenderingPreview = false
    @State private var previewError: String?

    @State private var jobTask: Task<Void, Never>?
    @State private var jobProgress: Double?
    @State private var jobError: String?

    private var activeSource: ReadingSource? { source ?? loadedSource }
    private var documentCount: Int { activeSource?.documents.count ?? 0 }

    var body: some View {
        NavigationStack {
            Group {
                if let loadError {
                    ReaderErrorView(message: loadError) { dismiss() }
                } else if activeSource == nil {
                    ProgressView().controlSize(.large)
                } else if sizeClass == .regular {
                    HStack(spacing: 0) {
                        previewPane
                        Divider()
                        optionsForm.frame(width: 380)
                    }
                } else {
                    VStack(spacing: 0) {
                        previewPane.frame(height: 300)
                        Divider()
                        optionsForm
                    }
                }
            }
            .navigationTitle("Print")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        jobTask?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { runJob(share: false) } label: { Label("Print…", systemImage: "printer") }
                        Button { runJob(share: true) } label: { Label("Save as PDF…", systemImage: "doc.richtext") }
                    } label: {
                        Text("Print").fontWeight(.semibold)
                    } primaryAction: {
                        runJob(share: false)
                    }
                    .disabled(activeSource == nil || jobProgress != nil)
                }
            }
            .overlay { if let jobProgress { jobOverlay(jobProgress) } }
            .alert("Can't Print",
                   isPresented: Binding(get: { jobError != nil }, set: { if !$0 { jobError = nil } }),
                   presenting: jobError) { _ in
                Button("OK", role: .cancel) { jobError = nil }
            } message: { Text($0) }
        }
        .task { await loadSourceIfNeeded() }
        .task(id: previewKey) { await refreshPreview() }
        .onChange(of: firstChapter) { _, value in if lastChapter < value { lastChapter = value } }
        .onChange(of: lastChapter) { _, value in if firstChapter > value { firstChapter = value } }
        .onAppear {
            firstChapter = currentIndex
            lastChapter = currentIndex
        }
        .onDisappear { jobTask?.cancel() }
    }

    // MARK: - Preview

    private var previewPane: some View {
        ZStack {
            Color(.systemGray5)
            if let preview {
                PrintPreview(data: preview.data)
            } else if let previewError {
                Text(previewError).font(.footnote).foregroundStyle(.secondary).padding()
            }
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    if isRenderingPreview { ProgressView().controlSize(.small) }
                    Text(previewCaption).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 10)
            }
        }
    }

    private var previewCaption: String {
        guard let preview else { return "Preparing preview" }
        let pages = preview.pageCount == 1 ? "1 page" : "\(preview.pageCount) pages"
        if documentCount <= 1 { return pages }
        return "\(chapterTitle(previewIndex)) · \(pages)"
    }

    /// One chapter stands in for the whole job, which keeps the preview quick
    /// on a long book: the reader's chapter when it is being printed, otherwise
    /// the first one printed.
    private var previewIndex: Int {
        let documents = selectedDocuments
        return documents.contains(currentIndex) ? currentIndex : documents.lowerBound
    }

    private struct PreviewKey: Hashable {
        var layout: PrintLayout
        var index: Int
        var ready: Bool
    }

    private var previewKey: PreviewKey {
        PreviewKey(layout: options.layout, index: previewIndex, ready: activeSource != nil)
    }

    private func refreshPreview() async {
        guard let activeSource else { return }
        // Steppers fire quickly; wait for them to settle before laying out again.
        if preview != nil {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        }
        let composer = previewComposer ?? BookPrintComposer(source: activeSource)
        previewComposer = composer
        isRenderingPreview = true
        defer { isRenderingPreview = false }
        let index = previewIndex
        do {
            preview = try await composer.render(documents: index..<(index + 1),
                                                layout: options.layout,
                                                title: book.title)
            previewError = nil
        } catch is CancellationError {
        } catch {
            previewError = error.localizedDescription
        }
    }

    // MARK: - Options

    private var optionsForm: some View {
        Form {
            if documentCount > 1 {
                Section("Pages") {
                    Picker("Print", selection: $range) {
                        ForEach(PrintRange.allCases) { Text($0.displayName).tag($0) }
                    }
                    if range == .chapters {
                        Picker("From", selection: $firstChapter) { chapterOptions }
                        Picker("Through", selection: $lastChapter) { chapterOptions }
                    }
                }
            }

            Section("Paper") {
                Picker("Size", selection: $options.paper) {
                    ForEach(PrintPaper.allCases) { Text($0.displayName).tag($0) }
                }
                LabeledStepper(title: "Margins",
                               value: $options.margin,
                               range: 18...108,
                               step: 9,
                               format: Self.formatLength)
            }

            Section("Text") {
                Picker("Typeface", selection: $options.font) {
                    Text("Book's Typeface").tag(ReaderFont?.none)
                    ForEach(ReaderFont.allCases) { Text($0.displayName).tag(ReaderFont?.some($0)) }
                }
                LabeledStepper(title: "Text Size",
                               value: $options.fontSize,
                               range: 7...20,
                               step: 0.5,
                               format: { String(format: $0.rounded() == $0 ? "%.0f pt" : "%.1f pt", $0) })
                LabeledStepper(title: "Line Spacing",
                               value: $options.lineHeight,
                               range: 1.0...2.4,
                               step: 0.1,
                               format: { String(format: "%.1f", $0) })
                Toggle("Justify Text", isOn: $options.justified)
                Toggle("Hyphenate", isOn: $options.hyphenate)
            }

            Section {
                Toggle("Chapters Start a New Page", isOn: $options.chapterBreaks)
                Toggle("Images", isOn: $options.includeImages)
                Toggle("Black Text on White", isOn: $options.blackText)
                Toggle("Book Title at Top", isOn: $options.showsTitle)
                Toggle("Page Numbers", isOn: $options.showsPageNumbers)
            } header: {
                Text("Layout")
            } footer: {
                Text("Black Text on White drops the book's colors and backgrounds, which saves ink. The printer's own options, such as copies and double-sided printing, come next.")
            }

            Section {
                Button("Reset to Defaults") { options.resetToDefaults() }
            }
        }
    }

    @ViewBuilder
    private var chapterOptions: some View {
        ForEach(0..<documentCount, id: \.self) { index in
            Text(chapterTitle(index)).tag(index)
        }
    }

    private func chapterTitle(_ index: Int) -> String {
        let entries = activeSource?.toc.filter { $0.spineIndex == index } ?? []
        if let entry = entries.min(by: { $0.level < $1.level }) { return entry.title }
        return "Section \(index + 1)"
    }

    private static func formatLength(_ points: Double) -> String {
        if Locale.current.measurementSystem == .metric {
            return "\(Int((points / 72 * 25.4).rounded())) mm"
        }
        return String(format: "%g in", (points / 72 * 1000).rounded() / 1000)
    }

    private var selectedDocuments: Range<Int> {
        let count = max(1, documentCount)
        let current = min(max(0, currentIndex), count - 1)
        switch range {
        case .wholeBook: return 0..<count
        case .currentChapter: return current..<(current + 1)
        case .chapters:
            let first = min(max(0, firstChapter), count - 1)
            let last = min(max(first, lastChapter), count - 1)
            return first..<(last + 1)
        }
    }

    // MARK: - Job

    private func jobOverlay(_ progress: Double) -> some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 14) {
                Text("Preparing Pages").font(.headline)
                ProgressView(value: progress).frame(width: 200)
                Button("Cancel", role: .cancel) { jobTask?.cancel() }
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func runJob(share: Bool) {
        guard let activeSource, jobTask == nil else { return }
        let documents = selectedDocuments
        let layout = options.layout
        let title = book.title
        jobProgress = 0
        jobTask = Task {
            defer {
                jobProgress = nil
                jobTask = nil
            }
            // Its own web view, so the preview can keep updating meanwhile.
            let composer = BookPrintComposer(source: activeSource)
            do {
                let printed = try await composer.render(documents: documents, layout: layout, title: title) { value in
                    jobProgress = value
                }
                if share {
                    PrintPresenter.share(printed, fileName: title)
                } else {
                    PrintPresenter.print(printed, jobName: title)
                }
            } catch is CancellationError {
            } catch {
                jobError = error.localizedDescription
            }
        }
    }

    private func loadSourceIfNeeded() async {
        guard source == nil, loadedSource == nil else { return }
        let id = book.id, url = book.fileURL, format = book.format, title = book.title
        do {
            loadedSource = try await Task.detached(priority: .userInitiated) {
                try ReadingSourceLoader.load(id: id, fileURL: url, format: format, title: title)
            }.value
        } catch {
            loadError = error.localizedDescription
        }
    }
}

/// The rendered pages, side by side, as they will print.
private struct PrintPreview: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .horizontal
        view.autoScales = true
        view.pageShadowsEnabled = true
        view.backgroundColor = .clear
        view.document = PDFDocument(data: data)
        context.coordinator.data = data
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        guard context.coordinator.data != data else { return }
        context.coordinator.data = data
        // Keep the reader's place in the preview while the options change.
        let page = view.currentPage.flatMap { view.document?.index(for: $0) } ?? 0
        let document = PDFDocument(data: data)
        view.document = document
        if let target = document?.page(at: min(page, max(0, (document?.pageCount ?? 1) - 1))) {
            view.go(to: target)
        }
        view.autoScales = true
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var data: Data?
    }
}
