import Foundation

enum EchoText {
    /// What the echo line can show of a key's output: any printable scalar,
    /// in any script. Drops controls, and the private-use scalars AppKit
    /// reports for arrows and function keys (U+F700…), which render as boxes.
    static func displayable(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where isDisplayable(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    private static func isDisplayable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .privateUse, .surrogate, .unassigned:
            return false
        default:
            return true
        }
    }
}
