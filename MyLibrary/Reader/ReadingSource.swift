import Foundation

/// Everything the reflowable reader needs to display a book: a read-access root
/// for the web view, the documents in reading order, and the table of contents.
struct ReadingSource: Sendable {
    var rootURL: URL
    var documents: [URL]
    var toc: [TOCEntry]

    func documentURL(at index: Int) -> URL? {
        documents.indices.contains(index) ? documents[index] : nil
    }
}

enum ReadingSourceError: LocalizedError {
    case cannotOpen
    case emptyBook

    var errorDescription: String? {
        switch self {
        case .cannotOpen: return "This book couldn't be opened. The file may be damaged."
        case .emptyBook: return "This book doesn't contain any readable pages."
        }
    }
}

enum ReadingSourceLoader {

    /// Unpacks (once) and describes a reflowable book. Call off the main thread.
    ///
    /// Takes plain values rather than the `Book` model object so it can run
    /// outside the main actor.
    static func load(id: UUID, fileURL: URL, format: BookFormat, title: String) throws -> ReadingSource {
        switch format {
        case .epub: return try loadEPUB(id: id, fileURL: fileURL)
        case .text: return try loadText(id: id, fileURL: fileURL, title: title)
        case .pdf: throw ReadingSourceError.cannotOpen   // PDFs are rendered by PDFKit
        }
    }

    private static func loadEPUB(id: UUID, fileURL: URL) throws -> ReadingSource {
        guard let archive = ZipArchive(url: fileURL),
              let document = EPUBDocument(archive: archive) else {
            throw ReadingSourceError.cannotOpen
        }
        guard !document.spine.isEmpty else { throw ReadingSourceError.emptyBook }

        let root = BookStorage.unpackedLocation(for: id)
        let marker = root.appendingPathComponent(".unpacked")
        if !FileManager.default.fileExists(atPath: marker.path) {
            // The cache may have been partially reclaimed; start clean.
            try? FileManager.default.removeItem(at: root)
            try archive.extractAll(to: root)
            try? Data().write(to: marker)
        }

        let documents = document.spine.map { root.appendingPathComponent(document.archivePath(for: $0)) }
        return ReadingSource(rootURL: root, documents: documents, toc: document.toc)
    }

    /// Plain text is wrapped in a minimal HTML document so it can share the
    /// EPUB reader's pagination, theming, and position tracking.
    private static func loadText(id: UUID, fileURL: URL, title: String) throws -> ReadingSource {
        let raw = (try? String(contentsOf: fileURL, encoding: .utf8))
            ?? (try? String(contentsOf: fileURL, encoding: .isoLatin1))
        guard let raw else { throw ReadingSourceError.cannotOpen }

        let root = BookStorage.unpackedLocation(for: id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("text.xhtml")

        let paragraphs = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "<p>" + escapeHTML($0).replacingOccurrences(of: "\n", with: "<br/>") + "</p>" }
            .joined(separator: "\n")

        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"/><title>\(escapeHTML(title))</title></head>
        <body>\(paragraphs)</body></html>
        """
        try html.write(to: destination, atomically: true, encoding: .utf8)

        return ReadingSource(rootURL: root, documents: [destination], toc: [])
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
