import AppKit
import SwiftUI

/// App accent + shared visual constants.
enum Theme {
    /// Macfolio's accent — ink indigo.
    static let primary = Color(red: 0.36, green: 0.36, blue: 0.86)

    /// The Persian fallback font family (IRANSansX NonEnglish variant).
    private static let persianFallback = "IRANSansXNoEn"

    /// UI font: Sofia Sans (Latin) with IRANSansX (Persian) fallback.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        cascaded("Sofia Sans", size: size, weight: weight)
    }

    /// Monospace UI font: Inconsolata (Latin) with IRANSansX (Persian) fallback.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        cascaded("Inconsolata", size: size, weight: weight)
    }

    /// A SwiftUI font whose Latin glyphs come from `family` and whose missing
    /// glyphs (Persian) fall through to IRANSansX — the CoreText equivalent of a
    /// CSS font stack. Falls back to the system font if a family isn't registered.
    private static func cascaded(_ family: String, size: CGFloat, weight: Font.Weight) -> Font {
        let boldWeights: Set<Font.Weight> = [.semibold, .bold, .heavy, .black]
        var base = NSFont(name: family, size: size) ?? NSFont.systemFont(ofSize: size)
        if boldWeights.contains(weight) {
            base = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        }
        let fallback = NSFontDescriptor(fontAttributes: [.name: persianFallback])
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: [fallback]])
        let font = NSFont(descriptor: descriptor, size: size) ?? base
        return Font(font as CTFont)
    }
}

/// The single window's fixed content size.
enum AppWindow {
    static let width: CGFloat = 980
    static let height: CGFloat = 660
    static let sidebar: CGFloat = 240
}
