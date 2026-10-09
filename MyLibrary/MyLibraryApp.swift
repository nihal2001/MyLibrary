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

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .task { PositionSync.shared.start(container: container) }
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { PositionSync.shared.refresh() }
        }
    }
}
