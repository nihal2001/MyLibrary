# My Library

A universal iOS/iPadOS ebook reader in the spirit of Apple Books: a library of
your own files, a paginated reader that remembers where you stopped, and
bookmarks you can jump back to.

Built with SwiftUI and SwiftData, using **only system frameworks** — no third
party packages, no bundled fonts, no bundled images.

## Features

**Library**
- Grid and list views, adaptive from iPhone to full-width iPad
- Shelves: All Books, Reading Now (started but unfinished), Finished
- Search by title or author; sort by recent, title, author, or date added
- Cover art extracted from the file, with a generated cover when there is none
- Import from Files/iCloud Drive, "Open in" from other apps, AirDrop, and
  Finder/iTunes file sharing
- Per-book actions: mark finished, reset progress, share the original file, delete

**Formats**
| Format | Support |
| --- | --- |
| EPUB 2 / EPUB 3 | Reflowable text, images, embedded CSS, EPUB 3 `nav` and EPUB 2 NCX contents |
| PDF | PDFKit rendering, outline, continuous or page-by-page, one or two up |
| Text | `.txt` and `.md`, wrapped into the same reflowable reader |

**Reader**
- Sentence Focus: the page dims and one sentence stays lit, advancing a sentence
  at a time instead of a page (see below)
- Paged (column-based, swipe or tap to turn) or continuous scrolling
- Four themes (Light, Sepia, Gray, Dark), five system typefaces, adjustable
  text size, line spacing, margins, and justification
- Table of contents, tap zones (left/right to turn, center for chrome), and a
  scrubber across the whole book
- Keep-screen-awake toggle

**Position and bookmarks**
- Every position change is written to the book record, so quitting or being
  terminated in the background loses nothing
- Reflowable position is stored as *(spine document, fraction through it)*, which
  survives font size, margin, and orientation changes — unlike a raw page number
- PDFs store the page index
- Bookmarks capture the chapter, a text snippet from the page, and the location;
  tap one to jump straight back

## Sentence Focus

Apple Books' Line Focus dims the page and lights one line at a time. This is the
same effect with a sentence as the unit, which reads far better than a line — a
line break is a typesetting accident, a sentence is a unit of meaning.

Turn it on from the reader's **⋯** menu or in Themes & Settings. While it's on,
tapping the right or left side of the page (or swiping) moves by one sentence
rather than one page, and the page turns by itself when the next sentence falls
onto it. Everything else still works: the scrubber, contents, themes, and
rotation all keep the lit sentence in view. Bookmarking captures the focused
sentence as its preview text.

How it works:

- Every text node in the chapter is rewritten into `<span>`s tagged with a
  sentence index. A sentence that runs through `<em>` or `<a>` produces several
  spans sharing one index, so it still lights up as a single unit.
- Sentence boundaries come from `Intl.Segmenter`, the same Unicode segmentation
  WebKit uses natively — no dictionary is bundled.
- Unicode sentence breaking has no notion of abbreviations, so it splits
  "Mr. Bennet" in two and cuts `"Stop!" she cried.` after the quote. Both read
  badly one sentence at a time, so those breaks are merged back using the text
  around them: a lowercase letter after the break, or a known abbreviation or
  initial before it, means the sentence is still going.
- Dimming is done with `color`, not `opacity`, so a page with thousands of spans
  doesn't get thousands of stacking contexts.
- The rules live in the stylesheet permanently and only bite once the engine adds
  a root class, so the mode toggles instantly with no reload. Wrapping happens
  once, on first use, and is kept afterwards.

Measured on the largest chapter of a real Gutenberg EPUB (184 KB, 1,800
sentences): segmentation 29 ms, span construction 23 ms. DOM insertion is a few
milliseconds in WebKit. Typical chapters are a fraction of that size.

Sentence Focus applies to EPUB and text books. PDFs are fixed-layout, so there
is no reflowable text to segment.

## Size

Apple Books is around 31 MB. This app is small for the same reason: everything
it needs is already on the device.

- No third-party dependencies (no Readium, no FolioReader, no ZIP library)
- EPUB unzipping is ~250 lines over Apple's `Compression` framework
  (`COMPRESSION_ZLIB` is raw DEFLATE, exactly what ZIP stores)
- PDF rendering is PDFKit; EPUB rendering is WKWebView; both ship with iOS
- All icons are SF Symbols; all reader fonts are system fonts
- Release builds use `-Osize`, whole-module optimization, LTO, dead-code
  stripping, and a stripped binary

The expected download is a **few megabytes**, dominated by the Swift/SwiftUI
runtime rather than app code. Book files themselves live in Application Support
and don't count against the app download.

Storage is deliberately frugal at runtime too: cover art is downscaled to 480px
JPEG in external storage, and EPUBs are unpacked into **Caches**, so iOS can
reclaim that space at any time — the reader just unpacks again on the next open.
Settings → Clear Unpacked Cache does it manually.

## Building

Requires Xcode 16 or later (the project uses file-system synchronized groups)
and an iOS 17 or later device or simulator.

```sh
open MyLibrary.xcodeproj
```

Then set your development team on the `MyLibrary` target (Signing &
Capabilities) and run. The bundle identifier defaults to
`com.example.MyLibrary`; change it to your own.

Command line:

```sh
xcodebuild -project MyLibrary.xcodeproj -scheme MyLibrary \
  -destination 'platform=iOS Simulator,name=iPhone 16' build
```

The project file is checked in and ready to open. `project.yml` is an optional
[XcodeGen](https://github.com/yonaskolb/XcodeGen) spec for regenerating it from
scratch (`xcodegen generate`).

Because files are added through a synchronized group, new Swift files under
`MyLibrary/` are picked up automatically — there is no pbxproj to edit.

## Layout

```
MyLibrary/
  MyLibraryApp.swift        App entry point and SwiftData container
  Models/Book.swift         Book and Bookmark records
  Storage/
    BookStorage.swift       On-disk locations for originals and unpacked copies
    ImportService.swift     Copy in, read metadata, build cover thumbnails
  Formats/
    ZipArchive.swift        Minimal ZIP reader (central directory + DEFLATE)
    XMLTree.swift           Small read-only DOM over XMLParser
    EPUBDocument.swift      OPF metadata, spine, cover, EPUB 3 nav / EPUB 2 NCX
  Library/
    LibraryView.swift       Sidebar, shelves, search, sort, import
    BookViews.swift         Covers, grid, list, per-book menu, settings
  Reader/
    ReadingSource.swift     Unpacking and preparing a book for reading
    ReaderSettings.swift    Themes, fonts, layout preferences
    ReaderEngine.swift      The pagination and sentence-focus JavaScript
    ReflowableReaderModel.swift  WKWebView driver: position, chapters, taps
    ReaderView.swift        Reader shell and chrome
    PDFReaderView.swift     PDFKit reader and outline
    ReaderSheets.swift      Contents, bookmarks, and settings sheets
Config/Info.plist           Document types, orientations, file sharing
Tests/ReaderEngine/         Node tests for the reader JavaScript (optional)
```

## How the EPUB reader works

1. `ZipArchive` reads the EPUB's central directory and inflates entries on demand.
2. `EPUBDocument` parses `META-INF/container.xml` → the OPF package → metadata,
   manifest, spine, cover, and table of contents.
3. On open, the archive is unpacked once into Caches so relative links to CSS,
   fonts, and images resolve normally.
4. Each spine document is loaded into a `WKWebView`. Injected CSS lays the body
   out in viewport-wide CSS columns; `ReaderEngine`'s script measures the column
   count and turns pages with a `translateX` transform.
5. The script reports the current page and fraction back to Swift, which stores
   it on the `Book` record and reports taps for page turns and chrome toggling.

## Tests

The reader's JavaScript lives in a Swift string literal, where no XCTest target
can reach it, so it is tested separately under `Tests/ReaderEngine` — the tests
extract the script from the Swift source and run it in jsdom. See the README
there. The EPUB container and package parsing were likewise verified against
generated EPUB 2/3 fixtures and a real 24 MB EPUB.

## Not included

Scoped deliberately to the basics that were asked for. Natural next steps:
highlights and notes, full-text search inside a book, collections, iCloud sync
of position across devices, DRM-free audiobook support, per-book typography
overrides, and a paragraph option alongside Sentence Focus.
