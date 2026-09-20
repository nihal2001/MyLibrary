import Foundation

/// One entry in a book's table of contents.
struct TOCEntry: Identifiable, Hashable, Sendable {
    let id = UUID()
    var title: String
    var href: String        // package-relative, fragment stripped
    var fragment: String?
    var level: Int
    var spineIndex: Int?
}

/// A parsed EPUB 2 or 3 package: metadata, reading order, and navigation.
struct EPUBDocument {
    var title: String
    var author: String?
    var language: String?
    var spine: [String]             // package-relative hrefs, in reading order
    var toc: [TOCEntry]
    var coverHref: String?
    var opfDirectory: String        // relative to the container root, "" when at top level

    /// Reads just enough of the archive to describe the book, without extracting it.
    init?(archive: ZipArchive) {
        guard let containerData = archive.data(for: "META-INF/container.xml"),
              let container = XMLTree.parse(containerData),
              let rootfile = container.firstDescendant(named: "rootfile"),
              let opfPath = rootfile.attribute("full-path"),
              let opfData = archive.data(for: opfPath),
              let package = XMLTree.parse(opfData) else { return nil }

        let opfDirectory = (opfPath as NSString).deletingLastPathComponent
        self.opfDirectory = opfDirectory

        // --- Metadata -------------------------------------------------------
        let metadata = package.firstDescendant(named: "metadata")
        let fallbackTitle = (opfPath as NSString).lastPathComponent
        self.title = metadata?.firstDescendant(named: "title")?.collectedText.nilIfBlank
            ?? (fallbackTitle as NSString).deletingPathExtension
        self.author = metadata?.firstDescendant(named: "creator")?.collectedText.nilIfBlank
        self.language = metadata?.firstDescendant(named: "language")?.collectedText.nilIfBlank

        // --- Manifest -------------------------------------------------------
        var hrefByID: [String: String] = [:]
        var propertiesByID: [String: String] = [:]
        var mediaTypeByID: [String: String] = [:]
        for item in package.firstDescendant(named: "manifest")?.children(named: "item") ?? [] {
            guard let id = item.attribute("id"), let href = item.attribute("href") else { continue }
            hrefByID[id] = href.removingPercentEncoding ?? href
            propertiesByID[id] = item.attribute("properties") ?? ""
            mediaTypeByID[id] = item.attribute("media-type") ?? ""
        }

        // --- Spine ----------------------------------------------------------
        let spineElement = package.firstDescendant(named: "spine")
        var spine: [String] = []
        for itemref in spineElement?.children(named: "itemref") ?? [] {
            guard let idref = itemref.attribute("idref"), let href = hrefByID[idref] else { continue }
            if itemref.attribute("linear") == "no" { continue }
            spine.append(EPUBDocument.resolve(href, in: ""))
        }
        self.spine = spine

        // --- Cover ----------------------------------------------------------
        var coverID = propertiesByID.first { $0.value.contains("cover-image") }?.key
        if coverID == nil {
            coverID = metadata?.descendants(named: "meta")
                .first { $0.attribute("name") == "cover" }?
                .attribute("content")
        }
        if coverID == nil {
            coverID = hrefByID.keys.first { $0.lowercased().contains("cover") && (mediaTypeByID[$0]?.hasPrefix("image/") ?? false) }
        }
        self.coverHref = coverID.flatMap { hrefByID[$0] }

        // --- Navigation -----------------------------------------------------
        var toc: [TOCEntry] = []
        if let navID = propertiesByID.first(where: { $0.value.contains("nav") })?.key,
           let navHref = hrefByID[navID],
           let navData = archive.data(for: EPUBDocument.resolve(navHref, in: opfDirectory)) {
            toc = EPUBDocument.parseNavigationDocument(navData, relativeTo: navHref)
        }
        if toc.isEmpty {
            let ncxID = spineElement?.attribute("toc")
                ?? hrefByID.keys.first { mediaTypeByID[$0] == "application/x-dtbncx+xml" }
            if let ncxID, let ncxHref = hrefByID[ncxID],
               let ncxData = archive.data(for: EPUBDocument.resolve(ncxHref, in: opfDirectory)) {
                toc = EPUBDocument.parseNCX(ncxData, relativeTo: ncxHref)
            }
        }

        // Link each TOC entry to the spine item it lands in.
        let spinePositions = Dictionary(spine.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        self.toc = toc.map { entry in
            var entry = entry
            entry.spineIndex = spinePositions[entry.href]
            return entry
        }
    }

    /// Absolute path inside the archive for a package-relative href.
    func archivePath(for href: String) -> String {
        EPUBDocument.resolve(href, in: opfDirectory)
    }

    // MARK: - Navigation parsing

    private static func parseNavigationDocument(_ data: Data, relativeTo navHref: String) -> [TOCEntry] {
        guard let root = XMLTree.parse(data) else { return [] }
        let navs = root.descendants(named: "nav")
        let tocNav = navs.first { $0.attribute("type") == "toc" } ?? navs.first
        guard let list = tocNav?.firstDescendant(named: "ol") else { return [] }

        let navDirectory = (navHref as NSString).deletingLastPathComponent
        var entries: [TOCEntry] = []

        func walk(_ list: XMLElement, level: Int) {
            for item in list.children(named: "li") {
                if let anchor = item.firstChild(named: "a") ?? item.firstDescendant(named: "a"),
                   let raw = anchor.attribute("href") {
                    entries.append(makeEntry(title: anchor.collectedText,
                                             rawHref: raw,
                                             directory: navDirectory,
                                             level: level))
                }
                for nested in item.children(named: "ol") { walk(nested, level: level + 1) }
            }
        }
        walk(list, level: 0)
        return entries
    }

    private static func parseNCX(_ data: Data, relativeTo ncxHref: String) -> [TOCEntry] {
        guard let root = XMLTree.parse(data),
              let navMap = root.firstDescendant(named: "navMap") else { return [] }

        let ncxDirectory = (ncxHref as NSString).deletingLastPathComponent
        var entries: [TOCEntry] = []

        func walk(_ parent: XMLElement, level: Int) {
            for point in parent.children(named: "navPoint") {
                if let raw = point.firstChild(named: "content")?.attribute("src") {
                    let title = point.firstChild(named: "navLabel")?.collectedText ?? ""
                    entries.append(makeEntry(title: title, rawHref: raw, directory: ncxDirectory, level: level))
                }
                walk(point, level: level + 1)
            }
        }
        walk(navMap, level: 0)
        return entries
    }

    private static func makeEntry(title: String, rawHref: String, directory: String, level: Int) -> TOCEntry {
        let decoded = rawHref.removingPercentEncoding ?? rawHref
        let parts = decoded.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts.first ?? "")
        let fragment = parts.count > 1 ? String(parts[1]) : nil
        return TOCEntry(title: title.nilIfBlank ?? "Untitled",
                        href: resolve(path, in: directory),
                        fragment: fragment,
                        level: level,
                        spineIndex: nil)
    }

    // MARK: - Path helpers

    /// Joins `href` onto `directory` and collapses `.`/`..` segments.
    static func resolve(_ href: String, in directory: String) -> String {
        guard !href.isEmpty else { return directory }
        let combined = directory.isEmpty ? href : directory + "/" + href
        var stack: [String] = []
        for segment in combined.split(separator: "/") {
            switch segment {
            case ".": continue
            case "..": if !stack.isEmpty { stack.removeLast() }
            default: stack.append(String(segment))
            }
        }
        return stack.joined(separator: "/")
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
