import Foundation
import SwiftData

enum BookFormat: String, Codable, CaseIterable {
    case epub, pdf, text

    static func from(fileExtension: String) -> BookFormat? {
        switch fileExtension.lowercased() {
        case "epub": return .epub
        case "pdf": return .pdf
        case "txt", "text", "md", "markdown": return .text
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .epub: return "EPUB"
        case .pdf: return "PDF"
        case .text: return "Text"
        }
    }

    /// EPUB and plain text are reflowable, so they page by fraction rather than by page number.
    var isReflowable: Bool { self != .pdf }
}

@Model
final class Book {
    @Attribute(.unique) var id: UUID
    var title: String
    var author: String?
    /// File name inside the app's Books directory. Never store absolute paths —
    /// the container path changes between launches and installs.
    var fileName: String
    var formatRaw: String
    var fileSize: Int
    var addedAt: Date
    var lastOpenedAt: Date?

    /// Fraction of the whole book that has been read, 0...1.
    var progress: Double
    /// Reflowable position: which spine document, and how far into it.
    var spineIndex: Int
    var spineFraction: Double
    /// Fixed-layout position.
    var pageIndex: Int

    var isFinished: Bool

    @Attribute(.externalStorage) var coverData: Data?

    @Relationship(deleteRule: .cascade, inverse: \Bookmark.book)
    var bookmarks: [Bookmark] = []

    init(id: UUID = UUID(),
         title: String,
         author: String? = nil,
         fileName: String,
         format: BookFormat,
         fileSize: Int = 0,
         coverData: Data? = nil) {
        self.id = id
        self.title = title
        self.author = author
        self.fileName = fileName
        self.formatRaw = format.rawValue
        self.fileSize = fileSize
        self.addedAt = .now
        self.lastOpenedAt = nil
        self.progress = 0
        self.spineIndex = 0
        self.spineFraction = 0
        self.pageIndex = 0
        self.isFinished = false
        self.coverData = coverData
    }

    var format: BookFormat {
        get { BookFormat(rawValue: formatRaw) ?? .epub }
        set { formatRaw = newValue.rawValue }
    }

    var fileURL: URL { BookStorage.booksDirectory.appendingPathComponent(fileName) }

    var hasStarted: Bool { lastOpenedAt != nil && progress > 0 }

    var progressDescription: String {
        if isFinished { return "Finished" }
        if progress <= 0 { return "Not started" }
        return "\(Int((progress * 100).rounded()))%"
    }
}

@Model
final class Bookmark {
    var id: UUID
    var createdAt: Date
    var chapterTitle: String
    var snippet: String
    var spineIndex: Int
    var spineFraction: Double
    var pageIndex: Int
    var book: Book?

    init(chapterTitle: String,
         snippet: String,
         spineIndex: Int = 0,
         spineFraction: Double = 0,
         pageIndex: Int = 0) {
        self.id = UUID()
        self.createdAt = .now
        self.chapterTitle = chapterTitle
        self.snippet = snippet
        self.spineIndex = spineIndex
        self.spineFraction = spineFraction
        self.pageIndex = pageIndex
    }
}
