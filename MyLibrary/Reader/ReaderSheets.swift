import SwiftData
import SwiftUI

/// EPUB table of contents.
struct TableOfContentsView: View {
    let entries: [TOCEntry]
    let currentIndex: Int
    /// The entry the reader is inside, when known. Several entries can share a
    /// spine document, so this is more precise than `currentIndex`.
    var currentEntryIndex: Int? = nil
    let onSelect: (TOCEntry) -> Void
    @Environment(\.dismiss) private var dismiss

    private func isCurrent(_ offset: Int) -> Bool {
        if let currentEntryIndex { return offset == currentEntryIndex }
        return entries[offset].spineIndex == currentIndex
    }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView("No Contents",
                                           systemImage: "list.bullet",
                                           description: Text("This book doesn't include a table of contents."))
                } else {
                    List(Array(entries.enumerated()), id: \.element.id) { offset, entry in
                        Button {
                            onSelect(entry)
                            dismiss()
                        } label: {
                            HStack {
                                Text(entry.title)
                                    .lineLimit(2)
                                    .fontWeight(isCurrent(offset) ? .semibold : .regular)
                                Spacer()
                                if isCurrent(offset) {
                                    Image(systemName: "book.fill")
                                        .font(.caption)
                                        .foregroundStyle(.tint)
                                }
                            }
                            .padding(.leading, CGFloat(entry.level) * 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Bookmarks for one book, from inside the reader or the library.
struct BookmarkListView: View {
    @Bindable var book: Book
    var onSelect: ((Bookmark) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    private var sorted: [Bookmark] {
        book.bookmarks.sorted {
            ($0.spineIndex, $0.spineFraction, $0.pageIndex) < ($1.spineIndex, $1.spineFraction, $1.pageIndex)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if sorted.isEmpty {
                    ContentUnavailableView("No Bookmarks",
                                           systemImage: "bookmark",
                                           description: Text("Tap the bookmark button while reading to save your place."))
                } else {
                    List {
                        ForEach(sorted) { bookmark in
                            Button {
                                onSelect?(bookmark)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(bookmark.chapterTitle)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                    if !bookmark.snippet.isEmpty {
                                        Text(bookmark.snippet)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(3)
                                    }
                                    Text(bookmark.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(onSelect == nil)
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func delete(at offsets: IndexSet) {
        let targets = sorted
        for index in offsets where targets.indices.contains(index) {
            context.delete(targets[index])
        }
    }
}

/// Themes, fonts, and layout — the reader's equivalent of the "aA" menu.
struct ReaderSettingsView: View {
    @Bindable var settings: ReaderSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Theme") {
                    HStack(spacing: 12) {
                        ForEach(ReaderTheme.allCases) { theme in
                            Button {
                                settings.theme = theme
                            } label: {
                                Text("A")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(theme.foreground)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(theme.background)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 10)
                                            .strokeBorder(settings.theme == theme ? Color.accentColor : Color.secondary.opacity(0.3),
                                                          lineWidth: settings.theme == theme ? 2.5 : 1)
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(theme.displayName)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Text") {
                    Picker("Typeface", selection: $settings.font) {
                        ForEach(ReaderFont.allCases) { Text($0.displayName).tag($0) }
                    }
                    LabeledStepper(title: "Text Size",
                                   value: $settings.fontScale,
                                   range: 70...220,
                                   step: 10,
                                   format: { "\(Int($0))%" })
                    LabeledStepper(title: "Line Spacing",
                                   value: $settings.lineHeight,
                                   range: 1.1...2.4,
                                   step: 0.1,
                                   format: { String(format: "%.1f", $0) })
                    LabeledStepper(title: "Margins",
                                   value: $settings.margin,
                                   range: 8...72,
                                   step: 8,
                                   format: { "\(Int($0))" })
                    Toggle("Justify Text", isOn: $settings.justified)
                }

                Section("Layout") {
                    Picker("Scrolling", selection: $settings.layout) {
                        ForEach(ReaderLayout.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Page Curl", isOn: $settings.pageCurl)
                        .disabled(settings.layout != .paged)
                    if UIDevice.current.userInterfaceIdiom == .pad {
                        Toggle("Two Pages in Landscape", isOn: $settings.twoPagesInLandscape)
                            .disabled(settings.layout != .paged)
                    }
                    Toggle("Keep Screen Awake", isOn: $settings.keepScreenOn)
                }
            }
            .navigationTitle("Reading")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct LabeledStepper: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}
