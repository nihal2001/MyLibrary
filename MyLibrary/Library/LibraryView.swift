import SwiftData
import SwiftUI
import UniformTypeIdentifiers

enum LibraryShelf: String, CaseIterable, Identifiable, Hashable {
    case all, reading, finished
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All Books"
        case .reading: return "Reading Now"
        case .finished: return "Finished"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "books.vertical"
        case .reading: return "book"
        case .finished: return "checkmark.circle"
        }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case recent, title, author, added
    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent: return "Recent"
        case .title: return "Title"
        case .author: return "Author"
        case .added: return "Date Added"
        }
    }
}

/// Root view: a sidebar of shelves on iPad, a stack on iPhone.
struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Query private var books: [Book]

    @State private var shelf: LibraryShelf? = .all
    @State private var searchText = ""
    @State private var sort: LibrarySort = .recent
    @State private var showsGrid = true
    @State private var isImporting = false
    @State private var importError: String?
    @State private var openedBook: Book?
    @State private var showsAbout = false
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $shelf) {
                Section("Library") {
                    ForEach(LibraryShelf.allCases) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
            }
            .navigationTitle("My Library")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showsAbout = true } label: { Image(systemName: "gearshape") }
                }
            }
        } detail: {
            NavigationStack {
                shelfContent
            }
        }
        .fileImporter(isPresented: $isImporting,
                      allowedContentTypes: ImportedType.supported,
                      allowsMultipleSelection: true,
                      onCompletion: handleImport)
        .fullScreenCover(item: $openedBook) { book in
            ReaderView(book: book)
        }
        .sheet(isPresented: $showsAbout) { AboutView() }
        .alert("Import Failed",
               isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } }),
               presenting: importError) { _ in
            Button("OK", role: .cancel) { importError = nil }
        } message: { message in
            Text(message)
        }
        .onOpenURL { url in
            // "Open in My Library" from Files, Mail, Safari, and AirDrop.
            do {
                try ImportService.importBook(from: url, into: context)
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    // MARK: - Shelf

    private var shelfContent: some View {
        let visible = filteredBooks
        return Group {
            if books.isEmpty {
                EmptyLibraryView { isImporting = true }
            } else if visible.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else if showsGrid {
                BookGrid(books: visible, onOpen: { openedBook = $0 }, onDelete: delete)
            } else {
                BookList(books: visible, onOpen: { openedBook = $0 }, onDelete: delete)
            }
        }
        .navigationTitle((shelf ?? .all).title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Title or author")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { isImporting = true } label: { Label("Add Book", systemImage: "plus") }
            }
            ToolbarItem(placement: .secondaryAction) {
                Picker("Sort", selection: $sort) {
                    ForEach(LibrarySort.allCases) { Text($0.label).tag($0) }
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button { showsGrid.toggle() } label: {
                    Label(showsGrid ? "List View" : "Grid View",
                          systemImage: showsGrid ? "list.bullet" : "square.grid.2x2")
                }
            }
        }
    }

    private var filteredBooks: [Book] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return books
            .filter { book in
                switch shelf ?? .all {
                case .all: return true
                case .reading: return book.hasStarted && !book.isFinished
                case .finished: return book.isFinished
                }
            }
            .filter { book in
                guard !query.isEmpty else { return true }
                return book.title.lowercased().contains(query)
                    || (book.author?.lowercased().contains(query) ?? false)
            }
            .sorted(by: ordering)
    }

    private func ordering(_ lhs: Book, _ rhs: Book) -> Bool {
        switch sort {
        case .recent:
            return (lhs.lastOpenedAt ?? lhs.addedAt) > (rhs.lastOpenedAt ?? rhs.addedAt)
        case .title:
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        case .author:
            return (lhs.author ?? "").localizedStandardCompare(rhs.author ?? "") == .orderedAscending
        case .added:
            return lhs.addedAt > rhs.addedAt
        }
    }

    // MARK: - Actions

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            var failures: [String] = []
            for url in urls {
                do {
                    try ImportService.importBook(from: url, into: context)
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            importError = failures.first
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func delete(_ book: Book) {
        BookStorage.removeFile(named: book.fileName)
        BookStorage.removeUnpacked(for: book.id)
        context.delete(book)
    }
}

enum ImportedType {
    /// EPUB has a system type on iOS; fall back to the extension if it's absent.
    static let supported: [UTType] = {
        var types: [UTType] = [.pdf, .plainText, .text]
        if let epub = UTType("org.idpf.epub-container") ?? UTType(filenameExtension: "epub") {
            types.append(epub)
        }
        return types
    }()
}

struct EmptyLibraryView: View {
    let onAdd: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Your Library Is Empty", systemImage: "books.vertical")
        } description: {
            Text("Add EPUB, PDF, or text files from Files, iCloud Drive, or another app.")
        } actions: {
            Button("Add Books", action: onAdd)
                .buttonStyle(.borderedProminent)
        }
    }
}
