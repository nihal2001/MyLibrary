import Foundation
import UIKit

enum PrintPaper: String, CaseIterable, Identifiable {
    case letter, a4, a5, trade, pocket
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .letter: return "US Letter"
        case .a4: return "A4"
        case .a5: return "A5"
        case .trade: return "Trade Paperback (6 × 9 in)"
        case .pocket: return "Pocket (4.25 × 6.87 in)"
        }
    }

    /// Page size in points (1/72 in), which is what PDF and UIKit printing use.
    var size: CGSize {
        switch self {
        case .letter: return CGSize(width: 612, height: 792)
        case .a4: return CGSize(width: 595.28, height: 841.89)
        case .a5: return CGSize(width: 419.53, height: 595.28)
        case .trade: return CGSize(width: 432, height: 648)
        case .pocket: return CGSize(width: 306, height: 494.64)
        }
    }

    /// Letter where the user measures in inches, A4 everywhere else.
    static var regionDefault: PrintPaper {
        Locale.current.measurementSystem == .us ? .letter : .a4
    }
}

/// Which part of a reflowable book goes to the printer.
enum PrintRange: String, CaseIterable, Identifiable {
    case wholeBook, currentChapter, chapters
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wholeBook: return "Whole Book"
        case .currentChapter: return "Current Chapter"
        case .chapters: return "Chapters…"
        }
    }
}

/// How printed EPUB and text pages look. Shared across books and kept in
/// UserDefaults, like the reader's own settings; the page range is per print.
@Observable
final class PrintOptions {
    /// Read and written only from the main actor by the print sheet.
    nonisolated(unsafe) static let shared = PrintOptions()

    private enum Key {
        static let paper = "print.paper"
        static let margin = "print.margin"
        static let font = "print.font"
        static let fontSize = "print.fontSize"
        static let lineHeight = "print.lineHeight"
        static let justified = "print.justified"
        static let hyphenate = "print.hyphenate"
        static let chapterBreaks = "print.chapterBreaks"
        static let includeImages = "print.includeImages"
        static let blackText = "print.blackText"
        static let showsTitle = "print.showsTitle"
        static let showsPageNumbers = "print.showsPageNumbers"
    }

    var paper: PrintPaper { didSet { store(paper.rawValue, Key.paper) } }
    /// Margin on every side of the page, in points.
    var margin: Double { didSet { store(margin, Key.margin) } }
    /// `nil` keeps the typeface the book's stylesheet asks for.
    var font: ReaderFont? { didSet { store(font?.rawValue ?? "", Key.font) } }
    /// Body text size in points.
    var fontSize: Double { didSet { store(fontSize, Key.fontSize) } }
    var lineHeight: Double { didSet { store(lineHeight, Key.lineHeight) } }
    var justified: Bool { didSet { store(justified, Key.justified) } }
    var hyphenate: Bool { didSet { store(hyphenate, Key.hyphenate) } }
    /// Each chapter starts at the top of a fresh page.
    var chapterBreaks: Bool { didSet { store(chapterBreaks, Key.chapterBreaks) } }
    var includeImages: Bool { didSet { store(includeImages, Key.includeImages) } }
    /// Drops the book's colors and backgrounds, which saves ink.
    var blackText: Bool { didSet { store(blackText, Key.blackText) } }
    var showsTitle: Bool { didSet { store(showsTitle, Key.showsTitle) } }
    var showsPageNumbers: Bool { didSet { store(showsPageNumbers, Key.showsPageNumbers) } }

    private init() {
        let defaults = UserDefaults.standard
        paper = PrintPaper(rawValue: defaults.string(forKey: Key.paper) ?? "") ?? .regionDefault
        margin = defaults.object(forKey: Key.margin) as? Double ?? Self.defaultMargin
        font = ReaderFont(rawValue: defaults.string(forKey: Key.font) ?? "")
        fontSize = defaults.object(forKey: Key.fontSize) as? Double ?? Self.defaultFontSize
        lineHeight = defaults.object(forKey: Key.lineHeight) as? Double ?? Self.defaultLineHeight
        justified = defaults.object(forKey: Key.justified) as? Bool ?? true
        hyphenate = defaults.object(forKey: Key.hyphenate) as? Bool ?? true
        chapterBreaks = defaults.object(forKey: Key.chapterBreaks) as? Bool ?? true
        includeImages = defaults.object(forKey: Key.includeImages) as? Bool ?? true
        blackText = defaults.object(forKey: Key.blackText) as? Bool ?? true
        showsTitle = defaults.object(forKey: Key.showsTitle) as? Bool ?? true
        showsPageNumbers = defaults.object(forKey: Key.showsPageNumbers) as? Bool ?? true
    }

    private static let defaultMargin: Double = 54        // 3/4 in
    private static let defaultFontSize: Double = 11
    private static let defaultLineHeight: Double = 1.4

    func resetToDefaults() {
        paper = .regionDefault
        margin = Self.defaultMargin
        font = nil
        fontSize = Self.defaultFontSize
        lineHeight = Self.defaultLineHeight
        justified = true
        hyphenate = true
        chapterBreaks = true
        includeImages = true
        blackText = true
        showsTitle = true
        showsPageNumbers = true
    }

    private func store(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    /// A value copy for one rendering, so a change made mid-render can't
    /// produce a document that is half one layout and half another.
    var layout: PrintLayout {
        PrintLayout(paper: paper, margin: margin, font: font, fontSize: fontSize,
                    lineHeight: lineHeight, justified: justified, hyphenate: hyphenate,
                    chapterBreaks: chapterBreaks, includeImages: includeImages,
                    blackText: blackText, showsTitle: showsTitle, showsPageNumbers: showsPageNumbers)
    }
}

/// One fixed set of print options, and the page geometry and CSS they produce.
struct PrintLayout: Hashable {
    var paper: PrintPaper
    var margin: Double
    var font: ReaderFont?
    var fontSize: Double
    var lineHeight: Double
    var justified: Bool
    var hyphenate: Bool
    var chapterBreaks: Bool
    var includeImages: Bool
    var blackText: Bool
    var showsTitle: Bool
    var showsPageNumbers: Bool

    var paperRect: CGRect { CGRect(origin: .zero, size: paper.size) }
    var printableRect: CGRect { paperRect.insetBy(dx: margin, dy: margin) }

    /// Room for the running title and the page number, scaled with the text.
    var headerHeight: CGFloat { showsTitle ? CGFloat(fontSize) * 2.6 : 0 }
    var footerHeight: CGFloat { showsPageNumbers ? CGFloat(fontSize) * 2.6 : 0 }

    /// The text block: what is left of the page once margins, header, and footer are taken.
    var contentHeight: CGFloat { printableRect.height - headerHeight - footerHeight }

    var css: String {
        let alignment = justified ? "p { text-align: justify !important; }" : ""
        let hyphens = hyphenate ? "auto" : "manual"
        // Slightly shorter than the text block, so a full-page image fits a
        // fresh page instead of being sliced across two.
        let imageHeight = max(72, Int(contentHeight) - 12)

        var css = """
        @page { margin: 0; }
        html {
          -webkit-text-size-adjust: none;
          font-size: \(String(format: "%.1f", fontSize))pt !important;
          background: #ffffff !important;
          -webkit-print-color-adjust: exact;
        }
        body {
          margin: 0 !important;
          padding: 0 !important;
          max-width: none !important;
          background: #ffffff !important;
          font-size: 1rem;
          line-height: \(String(format: "%.2f", lineHeight)) !important;
          -webkit-hyphens: \(hyphens);
          hyphens: \(hyphens);
          word-wrap: break-word;
        }
        body p, body li, body blockquote, body dd, body dt { line-height: inherit !important; }
        \(alignment)
        p { orphans: 2; widows: 2; }
        h1, h2, h3, h4, h5, h6 { break-after: avoid; page-break-after: avoid; break-inside: avoid; }
        img, svg, video, table { max-width: 100% !important; }
        img, svg, video {
          height: auto !important;
          max-height: \(imageHeight)pt !important;
          object-fit: contain;
          break-inside: avoid;
          page-break-inside: avoid;
        }
        figure { break-inside: avoid; page-break-inside: avoid; }
        pre, code { white-space: pre-wrap !important; word-break: break-word; }
        .ml-chapter { display: block; }
        """

        if let stack = font?.cssStack {
            css += """

            body, body *:not(pre):not(code):not(kbd):not(samp):not(tt) {
              font-family: \(stack) !important;
            }
            """
        }
        if chapterBreaks {
            css += """

            .ml-chapter + .ml-chapter { break-before: page; page-break-before: always; }
            """
        }
        if !includeImages {
            css += """

            img, svg, picture, video, image { display: none !important; }
            """
        }
        if blackText {
            css += """

            body, body * {
              color: #000000 !important;
              background-color: transparent !important;
              background-image: none !important;
              text-shadow: none !important;
            }
            """
        }
        return css
    }
}
