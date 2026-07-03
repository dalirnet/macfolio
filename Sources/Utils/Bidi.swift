import Foundation

/// Direction detection for chat + inputs: is the first strong character RTL?
/// Mirrors `dir="auto"` so Persian/Arabic/Hebrew text aligns right, Latin left.
enum Bidi {
    static func isRTL(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            // Strong LTR: Latin letters.
            if (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) { return false }
            // Strong RTL: Hebrew, Arabic, Persian, Arabic presentation forms.
            if (0x0590...0x08FF).contains(v)
                || (0xFB1D...0xFDFF).contains(v)
                || (0xFE70...0xFEFF).contains(v)
            {
                return true
            }
        }
        return false
    }
}
