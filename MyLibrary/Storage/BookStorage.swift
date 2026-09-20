import Foundation

/// Where book files live on disk.
///
/// Originals go in Application Support (backed up, never purged). Unpacked EPUB
/// working copies go in Caches, so the system can reclaim them under storage
/// pressure and we simply unpack again on the next open.
enum BookStorage {
    static let booksDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Books", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    static let unpackedDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Unpacked", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    /// A collision-free file name inside the Books directory.
    static func uniqueFileName(for proposed: String) -> String {
        let name = (proposed as NSString).deletingPathExtension
        let ext = (proposed as NSString).pathExtension
        var candidate = proposed
        var counter = 2
        while FileManager.default.fileExists(atPath: booksDirectory.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(name) \(counter)" : "\(name) \(counter).\(ext)"
            counter += 1
        }
        return candidate
    }

    static func fileSize(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    static func removeFile(named fileName: String) {
        try? FileManager.default.removeItem(at: booksDirectory.appendingPathComponent(fileName))
    }

    static func unpackedLocation(for bookID: UUID) -> URL {
        unpackedDirectory.appendingPathComponent(bookID.uuidString, isDirectory: true)
    }

    static func removeUnpacked(for bookID: UUID) {
        try? FileManager.default.removeItem(at: unpackedLocation(for: bookID))
    }

    /// Total bytes of imported books, for the settings screen.
    static func totalLibraryBytes() -> Int {
        let contents = (try? FileManager.default.contentsOfDirectory(at: booksDirectory,
                                                                    includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return contents.reduce(0) { $0 + fileSize(of: $1) }
    }

    static func clearUnpackedCache() {
        try? FileManager.default.removeItem(at: unpackedDirectory)
        try? FileManager.default.createDirectory(at: unpackedDirectory, withIntermediateDirectories: true)
    }
}
