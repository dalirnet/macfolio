import AppKit
import SwiftUI

/// App accent + shared visual constants.
enum Theme {
    /// Macfolio's accent — ink indigo.
    static let primary = Color(red: 0.36, green: 0.36, blue: 0.86)

    /// The Persian fallback font family (Dana NonEnglish variant).
    private static let persianFallback = "DanaNoEn"

    /// UI font: Sofia Sans (Latin) with Dana (Persian) fallback.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font(nsUI(size, weight) as CTFont)
    }

    /// Monospace UI font: Inconsolata (Latin) with Dana (Persian) fallback.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font(cascaded("Inconsolata", size: size, weight: weight) as CTFont)
    }

    /// The UI font as an `NSFont`, for AppKit views (e.g. the prompt's NSTextView).
    static func nsUI(_ size: CGFloat, _ weight: Font.Weight = .regular) -> NSFont {
        cascaded("Sofia Sans", size: size, weight: weight)
    }

    /// A line height that fits both the Latin (Sofia) and Persian (Dana) faces at
    /// `size`. Pin text to this so RTL rows don't grow taller than LTR ones —
    /// Dana's metrics are taller, so an unpinned line stretches for Persian.
    static func lineHeight(_ size: CGFloat) -> CGFloat {
        let heights = ["Sofia Sans", persianFallback]
            .compactMap { NSFont(name: $0, size: size) }
            .map { $0.ascender - $0.descender + $0.leading }
        return ceil(heights.max() ?? size * 1.4)
    }

    /// An `NSFont` whose Latin glyphs come from `family` and whose missing glyphs
    /// (Persian) fall through to Dana — the CoreText equivalent of a CSS font
    /// stack. Falls back to the system font if a family isn't registered.
    private static func cascaded(_ family: String, size: CGFloat, weight: Font.Weight) -> NSFont {
        let boldWeights: Set<Font.Weight> = [.semibold, .bold, .heavy, .black]
        var base = NSFont(name: family, size: size) ?? NSFont.systemFont(ofSize: size)
        if boldWeights.contains(weight) {
            base = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        }
        let fallback = NSFontDescriptor(fontAttributes: [.name: persianFallback])
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: [fallback]])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

/// The single window's fixed content size.
enum AppWindow {
    static let width: CGFloat = 980
    static let height: CGFloat = 660
    static let sidebar: CGFloat = 240
}
