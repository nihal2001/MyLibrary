import SwiftData
import SwiftUI

@main
struct MyLibraryApp: App {
    /// One lightweight store for books and bookmarks. Cover art is kept in
    /// external storage so the database file stays small.
    private let container: ModelContainer = {
        do {
            return try ModelContainer(for: Book.self, Bookmark.self)
        } catch {
            // A corrupt store shouldn't brick the app; start over in memory.
            return try! ModelContainer(for: Book.self, Bookmark.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
    }()

    var body: some Scene {
        WindowGroup {
            LibraryView()
        }
        .modelContainer(container)
    }
}
