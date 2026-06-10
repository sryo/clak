import SwiftUI

// MARK: - Key Cap Glass

struct KeyCapGlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: 6))
        } else {
            content
                .background(Color.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
