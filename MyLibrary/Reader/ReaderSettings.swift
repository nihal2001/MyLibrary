import SwiftUI
import UIKit

enum ReaderTheme: String, CaseIterable, Identifiable {
    case light, sepia, gray, dark
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light: return "Light"
        case .sepia: return "Sepia"
        case .gray: return "Gray"
        case .dark: return "Dark"
        }
    }

    /// CSS colors injected into the reader document.
    var backgroundCSS: String {
        switch self {
        case .light: return "#ffffff"
        case .sepia: return "#f7efdf"
        case .gray: return "#43474c"
        case .dark: return "#0d0d0f"
        }
    }

    var foregroundCSS: String {
        switch self {
        case .light: return "#16171a"
        case .sepia: return "#43382a"
        case .gray: return "#e8e8ea"
        case .dark: return "#d3d3d6"
        }
    }

    var background: Color {
        switch self {
        case .light: return Color(red: 1, green: 1, blue: 1)
        case .sepia: return Color(red: 0.969, green: 0.937, blue: 0.875)
        case .gray: return Color(red: 0.263, green: 0.278, blue: 0.298)
        case .dark: return Color(red: 0.051, green: 0.051, blue: 0.059)
        }
    }

    var foreground: Color {
        switch self {
        case .light: return Color(red: 0.086, green: 0.090, blue: 0.102)
        case .sepia: return Color(red: 0.263, green: 0.220, blue: 0.165)
        case .gray, .dark: return Color(red: 0.827, green: 0.827, blue: 0.839)
        }
    }

    var isDark: Bool { self == .dark || self == .gray }
}

enum ReaderFont: String, CaseIterable, Identifiable {
    case system, serif, georgia, palatino, times
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .serif: return "Serif"
        case .georgia: return "Georgia"
        case .palatino: return "Palatino"
        case .times: return "Times"
        }
    }

    /// All faces are already on the device — the app bundles no fonts.
    var cssStack: String? {
        switch self {
        case .system: return "-apple-system, system-ui, sans-serif"
        case .serif: return "\"New York\", ui-serif, Georgia, serif"
        case .georgia: return "Georgia, serif"
        case .palatino: return "\"Palatino\", \"Palatino Linotype\", serif"
        case .times: return "\"Times New Roman\", Times, serif"
        }
    }
}

enum ReaderLayout: String, CaseIterable, Identifiable {
    case paged, scrolling
    var id: String { rawValue }
    var displayName: String { self == .paged ? "Paged" : "Scrolling" }
}

/// Reader preferences, shared across books and persisted in UserDefaults.
@Observable
final class ReaderSettings {
    /// Read and written only from the main actor by the reader UI.
    nonisolated(unsafe) static let shared = ReaderSettings()

    private enum Key {
        static let theme = "reader.theme"
        static let font = "reader.font"
        static let fontScale = "reader.fontScale"
        static let lineHeight = "reader.lineHeight"
        static let margin = "reader.margin"
        static let layout = "reader.layout"
        static let justified = "reader.justified"
        static let keepScreenOn = "reader.keepScreenOn"
        static let twoPagesInLandscape = "reader.twoPagesInLandscape"
        static let pdfSwipeToTurn = "reader.pdfSwipeToTurn"
    }

    var theme: ReaderTheme { didSet { store(theme.rawValue, Key.theme) } }
    var font: ReaderFont { didSet { store(font.rawValue, Key.font) } }
    /// Root font size as a percentage of the default, 70...220.
    var fontScale: Double { didSet { store(fontScale, Key.fontScale) } }
    var lineHeight: Double { didSet { store(lineHeight, Key.lineHeight) } }
    /// Horizontal page margin in points.
    var margin: Double { didSet { store(margin, Key.margin) } }
    var layout: ReaderLayout { didSet { store(layout.rawValue, Key.layout) } }
    var justified: Bool { didSet { store(justified, Key.justified) } }
    /// iPad: show facing pages while the reader is wider than it is tall.
    var twoPagesInLandscape: Bool { didSet { store(twoPagesInLandscape, Key.twoPagesInLandscape) } }
    /// PDFs: turn pages by swiping sideways instead of scrolling.
    var pdfSwipeToTurn: Bool { didSet { store(pdfSwipeToTurn, Key.pdfSwipeToTurn) } }
    var keepScreenOn: Bool {
        didSet {
            store(keepScreenOn, Key.keepScreenOn)
            let enabled = keepScreenOn
            Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = enabled }
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        theme = ReaderTheme(rawValue: defaults.string(forKey: Key.theme) ?? "") ?? .light
        font = ReaderFont(rawValue: defaults.string(forKey: Key.font) ?? "") ?? .system
        fontScale = defaults.object(forKey: Key.fontScale) as? Double ?? 100
        lineHeight = defaults.object(forKey: Key.lineHeight) as? Double ?? 1.5
        margin = defaults.object(forKey: Key.margin) as? Double ?? 24
        layout = ReaderLayout(rawValue: defaults.string(forKey: Key.layout) ?? "") ?? .paged
        justified = defaults.object(forKey: Key.justified) as? Bool ?? false
        twoPagesInLandscape = defaults.object(forKey: Key.twoPagesInLandscape) as? Bool ?? true
        pdfSwipeToTurn = defaults.object(forKey: Key.pdfSwipeToTurn) as? Bool ?? false
        keepScreenOn = defaults.object(forKey: Key.keepScreenOn) as? Bool ?? false
    }

    private func store(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    /// Bumped whenever a change requires the web view to re-render.
    var styleSignature: String {
        "\(theme.rawValue)|\(font.rawValue)|\(Int(fontScale))|\(lineHeight)|\(Int(margin))|\(layout.rawValue)|\(justified)|\(twoPagesInLandscape)"
    }
}
