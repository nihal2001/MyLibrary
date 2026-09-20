import Foundation
import PDFKit
import SwiftData
import UIKit

enum ImportError: LocalizedError {
    case unsupportedFormat(String)
    case unreadableFile
    case copyFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return ext.isEmpty
                ? "That file type isn't supported. Add EPUB, PDF, or text files."
                : "\(ext.uppercased()) files aren't supported yet. Add EPUB, PDF, or text files."
        case .unreadableFile: return "The file couldn't be read."
        case .copyFailed: return "The file couldn't be copied into your library."
        }
    }
}

/// Copies incoming files into the library and extracts title, author, and cover.
enum ImportService {

    @discardableResult
    static func importBook(from source: URL, into context: ModelContext) throws -> Book {
        let needsScopedAccess = source.startAccessingSecurityScopedResource()
        defer { if needsScopedAccess { source.stopAccessingSecurityScopedResource() } }

        let ext = source.pathExtension
        guard let format = BookFormat.from(fileExtension: ext) else {
            throw ImportError.unsupportedFormat(ext)
        }

        let fileName = BookStorage.uniqueFileName(for: source.lastPathComponent)
        let destination = BookStorage.booksDirectory.appendingPathComponent(fileName)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw ImportError.copyFailed
        }

        let metadata = readMetadata(at: destination, format: format)
        let book = Book(title: metadata.title,
                        author: metadata.author,
                        fileName: fileName,
                        format: format,
                        fileSize: BookStorage.fileSize(of: destination),
                        coverData: metadata.cover)
        context.insert(book)
        return book
    }

    struct Metadata {
        var title: String
        var author: String?
        var cover: Data?
    }

    static func readMetadata(at url: URL, format: BookFormat) -> Metadata {
        let fallbackTitle = (url.deletingPathExtension().lastPathComponent as String)
            .replacingOccurrences(of: "_", with: " ")

        switch format {
        case .epub:
            guard let archive = ZipArchive(url: url),
                  let document = EPUBDocument(archive: archive) else {
                return Metadata(title: fallbackTitle, author: nil, cover: nil)
            }
            var cover: Data?
            if let href = document.coverHref,
               let raw = archive.data(for: document.archivePath(for: href)) {
                cover = CoverImage.thumbnail(from: raw)
            }
            if cover == nil { cover = coverFromFirstSpineImage(archive: archive, document: document) }
            return Metadata(title: document.title.nilIfBlank ?? fallbackTitle,
                            author: document.author,
                            cover: cover)

        case .pdf:
            guard let pdf = PDFDocument(url: url) else {
                return Metadata(title: fallbackTitle, author: nil, cover: nil)
            }
            let attributes = pdf.documentAttributes ?? [:]
            let title = (attributes[PDFDocumentAttribute.titleAttribute] as? String)?.nilIfBlank
            let author = (attributes[PDFDocumentAttribute.authorAttribute] as? String)?.nilIfBlank
            return Metadata(title: title ?? fallbackTitle,
                            author: author,
                            cover: CoverImage.thumbnail(fromPDFPage: pdf.page(at: 0)))

        case .text:
            return Metadata(title: fallbackTitle, author: nil, cover: nil)
        }
    }

    /// Some EPUBs point their cover at an XHTML wrapper page rather than the
    /// image itself; fall back to the first image referenced by that page.
    private static func coverFromFirstSpineImage(archive: ZipArchive, document: EPUBDocument) -> Data? {
        guard let firstHref = document.spine.first,
              let html = archive.string(for: document.archivePath(for: firstHref)) else { return nil }

        let pattern = "(?:src|xlink:href|href)\\s*=\\s*[\"']([^\"']+\\.(?:jpe?g|png|gif|webp))[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }

        let directory = (firstHref as NSString).deletingLastPathComponent
        let resolved = EPUBDocument.resolve(String(html[range]), in: directory)
        guard let raw = archive.data(for: document.archivePath(for: resolved)) else { return nil }
        return CoverImage.thumbnail(from: raw)
    }
}

/// Cover art is stored as a small JPEG so a large library stays a few megabytes.
enum CoverImage {
    static let maxDimension: CGFloat = 480
    static let compressionQuality: CGFloat = 0.8

    static func thumbnail(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return encode(downscale(image))
    }

    static func thumbnail(fromPDFPage page: PDFPage?) -> Data? {
        guard let page else { return nil }
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(maxDimension / bounds.width, maxDimension / bounds.height, 1)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = page.thumbnail(of: size, for: .cropBox)
        return encode(image)
    }

    private static func downscale(_ image: UIImage) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let size = CGSize(width: (image.size.width * scale).rounded(),
                          height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private static func encode(_ image: UIImage) -> Data? {
        image.jpegData(compressionQuality: compressionQuality)
    }
}
