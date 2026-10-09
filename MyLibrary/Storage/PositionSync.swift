import Foundation
import SwiftData

/// Keeps reading positions in step across the user's devices through iCloud
/// key-value storage.
///
/// Book files stay on the device they were imported on, and each device gives
/// its copy its own record, so a book is matched by a hash of its contents: the
/// same file imported on two devices shares one small entry, and the newest
/// write wins. Without an iCloud account the store is simply local and nothing
/// here fails.
@MainActor
final class PositionSync {
    static let shared = PositionSync()

    /// Posted after a newer position from another device was written to a book,
    /// with the book's `id` as the object, so an open reader can follow it.
    static let didApplyRemotePosition = Notification.Name("PositionSyncDidApplyRemotePosition")

    private static let keyPrefix = "pos."
    /// iCloud allows 1024 keys; the least recently read books make room.
    private static let maxEntries = 900

    private let store = NSUbiquitousKeyValueStore.default
    private var context: ModelContext?
    private var observer: NSObjectProtocol?

    func start(container: ModelContainer) {
        guard context == nil else { return }
        context = container.mainContext
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.merge() }
        }
        refresh()
        hashUnhashedBooks()
    }

    /// Asks iCloud for anything new; called when the app returns to the foreground.
    func refresh() {
        store.synchronize()
        merge()
    }

    /// The reader moved, or the user changed the book's progress by hand.
    func recordLocalChange(_ book: Book) {
        // Always later than the position it replaces, even when that one came
        // from a device whose clock runs ahead.
        let previous = book.positionUpdatedAt ?? .distantPast
        book.positionUpdatedAt = max(.now, previous.addingTimeInterval(0.001))
        push(book)
    }

    /// Reconciles every book with iCloud: whichever side moved last wins.
    func merge() {
        guard let context, let books = try? context.fetch(FetchDescriptor<Book>()) else { return }
        for book in books {
            guard let key = key(for: book) else { continue }
            let remote = Entry(store.dictionary(forKey: key))
            // Books read before syncing existed have no stamp of their own.
            let local = book.positionUpdatedAt ?? (book.progress > 0 ? book.lastOpenedAt : nil)

            if let remote, remote.time > (local ?? .distantPast) {
                apply(remote, to: book)
            } else if let local, local > (remote?.time ?? .distantPast) {
                book.positionUpdatedAt = local
                push(book)
            }
        }
        prune()
    }

    private func apply(_ entry: Entry, to book: Book) {
        book.spineIndex = entry.spineIndex
        book.spineFraction = entry.spineFraction
        book.pageIndex = entry.pageIndex
        book.progress = entry.progress
        book.isFinished = entry.isFinished
        book.positionUpdatedAt = entry.time
        // Read elsewhere counts as opened, so the book joins Reading Now here.
        book.lastOpenedAt = max(book.lastOpenedAt ?? .distantPast, entry.time)
        NotificationCenter.default.post(name: Self.didApplyRemotePosition, object: book.id)
    }

    private func push(_ book: Book) {
        guard let key = key(for: book), let time = book.positionUpdatedAt else { return }
        let entry = Entry(time: time,
                          spineIndex: book.spineIndex,
                          spineFraction: book.spineFraction,
                          pageIndex: book.pageIndex,
                          progress: book.progress,
                          isFinished: book.isFinished)
        store.set(entry.dictionary, forKey: key)
    }

    private func key(for book: Book) -> String? {
        book.contentHash.map { Self.keyPrefix + $0.prefix(40) }
    }

    private func prune() {
        let entries = store.dictionaryRepresentation.compactMap { key, value -> (String, Date)? in
            guard key.hasPrefix(Self.keyPrefix) else { return nil }
            return (key, Entry(value as? [String: Any])?.time ?? .distantPast)
        }
        guard entries.count > Self.maxEntries else { return }
        for (key, _) in entries.sorted(by: { $0.1 < $1.1 }).prefix(entries.count - Self.maxEntries) {
            store.removeObject(forKey: key)
        }
    }

    /// Books imported before syncing existed are hashed once, off the main thread.
    private func hashUnhashedBooks() {
        let files = unhashedBooks().map { ($0.id, $0.fileURL) }
        guard !files.isEmpty else { return }
        Task {
            let hashes = await Task.detached(priority: .utility) {
                files.reduce(into: [UUID: String]()) { $0[$1.0] = BookStorage.contentHash(of: $1.1) }
            }.value
            // Fetched again: a book may have been deleted in the meantime.
            for book in unhashedBooks() { book.contentHash = hashes[book.id] }
            merge()
        }
    }

    private func unhashedBooks() -> [Book] {
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.contentHash == nil })
        return (try? context?.fetch(descriptor)) ?? []
    }

    /// One book's position as stored in iCloud.
    private struct Entry {
        var time: Date
        var spineIndex: Int
        var spineFraction: Double
        var pageIndex: Int
        var progress: Double
        var isFinished: Bool

        init(time: Date, spineIndex: Int, spineFraction: Double, pageIndex: Int, progress: Double, isFinished: Bool) {
            self.time = time
            self.spineIndex = spineIndex
            self.spineFraction = spineFraction
            self.pageIndex = pageIndex
            self.progress = progress
            self.isFinished = isFinished
        }

        init?(_ dictionary: [String: Any]?) {
            guard let dictionary, let time = dictionary["t"] as? Double else { return nil }
            self.time = Date(timeIntervalSinceReferenceDate: time)
            spineIndex = max(0, dictionary["s"] as? Int ?? 0)
            spineFraction = min(1, max(0, dictionary["f"] as? Double ?? 0))
            pageIndex = max(0, dictionary["p"] as? Int ?? 0)
            progress = min(1, max(0, dictionary["g"] as? Double ?? 0))
            isFinished = dictionary["d"] as? Bool ?? false
        }

        var dictionary: [String: Any] {
            ["t": time.timeIntervalSinceReferenceDate,
             "s": spineIndex,
             "f": spineFraction,
             "p": pageIndex,
             "g": progress,
             "d": isFinished]
        }
    }
}
