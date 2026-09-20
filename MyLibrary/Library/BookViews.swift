import SwiftData
import SwiftUI
import UIKit

/// Cover art, or a generated placeholder when the file has none.
struct BookCoverView: View {
    let book: Book
    var cornerRadius: CGFloat = 6

    private var palette: [Color] {
        // Stable per-title color so placeholders stay recognizable.
        let hue = Double(abs(book.title.hashValue) % 360) / 360
        return [Color(hue: hue, saturation: 0.45, brightness: 0.62),
                Color(hue: hue, saturation: 0.55, brightness: 0.38)]
    }

    var body: some View {
        // The 2:3 frame sets the size; cover art fills it and is cropped, so a
        // wide image (a landscape or letter-size PDF page) can't widen the cell.
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay { artwork }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
    }

    @ViewBuilder
    private var artwork: some View {
        ZStack {
            if let data = book.coverData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 6) {
                    Text(book.title)
                        .font(.caption.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                    if let author = book.author {
                        Text(author).font(.caption2).lineLimit(1).opacity(0.85)
                    }
                }
                .foregroundStyle(.white)
                .padding(10)
            }
        }
    }
}

/// Adaptive grid — three columns on a phone, more on an iPad or in Split View.
struct BookGrid: View {
    let books: [Book]
    let onOpen: (Book) -> Void
    let onDelete: (Book) -> Void

    private let columns = [GridItem(.adaptive(minimum: 108, maximum: 170), spacing: 18, alignment: .top)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 22) {
                ForEach(books) { book in
                    Button { onOpen(book) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            BookCoverView(book: book)
                            Text(book.title)
                                .font(.caption.weight(.medium))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            if let author = book.author {
                                Text(author)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            ProgressBadge(book: book)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { BookMenu(book: book, onDelete: onDelete) }
                }
            }
            .padding(20)
        }
    }
}

struct BookList: View {
    let books: [Book]
    let onOpen: (Book) -> Void
    let onDelete: (Book) -> Void

    var body: some View {
        List {
            ForEach(books) { book in
                Button { onOpen(book) } label: {
                    HStack(spacing: 14) {
                        BookCoverView(book: book, cornerRadius: 4)
                            .frame(width: 54)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(book.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                            if let author = book.author {
                                Text(author).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            }
                            ProgressBadge(book: book)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { onDelete(book) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .contextMenu { BookMenu(book: book, onDelete: onDelete) }
            }
        }
        .listStyle(.plain)
    }
}

private struct ProgressBadge: View {
    @Bindable var book: Book

    var body: some View {
        HStack(spacing: 5) {
            if book.isFinished {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if book.progress > 0 {
                ProgressView(value: book.progress).frame(width: 34)
            }
            Text(book.isFinished ? "Finished" : book.progressDescription)
            if !book.bookmarks.isEmpty {
                Image(systemName: "bookmark.fill").foregroundStyle(.orange)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

private struct BookMenu: View {
    @Bindable var book: Book
    let onDelete: (Book) -> Void

    var body: some View {
        Button {
            book.isFinished.toggle()
            if book.isFinished { book.progress = 1 }
        } label: {
            Label(book.isFinished ? "Mark as Unread" : "Mark as Finished",
                  systemImage: book.isFinished ? "arrow.uturn.backward" : "checkmark.circle")
        }

        Button {
            book.progress = 0
            book.spineIndex = 0
            book.spineFraction = 0
            book.pageIndex = 0
            book.isFinished = false
        } label: {
            Label("Reset Progress", systemImage: "arrow.counterclockwise")
        }

        ShareLink(item: book.fileURL) { Label("Share File", systemImage: "square.and.arrow.up") }

        Divider()

        Button(role: .destructive) { onDelete(book) } label: {
            Label("Delete Book", systemImage: "trash")
        }
    }
}

/// Storage and format information, reachable from the sidebar.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var books: [Book]
    @State private var libraryBytes = 0
    @State private var cacheCleared = false

    private var formatter: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Library") {
                    LabeledContent("Books", value: "\(books.count)")
                    LabeledContent("Bookmarks", value: "\(books.reduce(0) { $0 + $1.bookmarks.count })")
                    LabeledContent("Storage Used", value: formatter.string(fromByteCount: Int64(libraryBytes)))
                }

                Section {
                    Button {
                        BookStorage.clearUnpackedCache()
                        cacheCleared = true
                    } label: {
                        Label(cacheCleared ? "Cache Cleared" : "Clear Unpacked Cache",
                              systemImage: "trash")
                    }
                    .disabled(cacheCleared)
                } header: {
                    Text("Storage")
                } footer: {
                    Text("EPUB files are unpacked into a cache while you read. Clearing it frees space; books re-open normally afterwards.")
                }

                Section("Supported Formats") {
                    LabeledContent("EPUB", value: "2 and 3")
                    LabeledContent("PDF", value: "All")
                    LabeledContent("Text", value: "TXT, MD")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { libraryBytes = BookStorage.totalLibraryBytes() }
        }
    }
}
