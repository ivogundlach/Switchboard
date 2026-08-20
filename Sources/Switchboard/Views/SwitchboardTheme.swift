import SwiftUI

enum SwitchboardTheme {
    static let background = Color(red: 0.035, green: 0.04, blue: 0.055)
    static let panel = Color.white.opacity(0.055)
    static let inset = Color.black.opacity(0.22)
    static let border = Color.white.opacity(0.10)
    static let accent = Color(red: 0.38, green: 0.76, blue: 1.0)
    static let success = Color(red: 0.34, green: 0.82, blue: 0.55)
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.32)
}

extension View {
    func switchboardPanel(cornerRadius: CGFloat = 16) -> some View {
        self
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(SwitchboardTheme.border, lineWidth: 1)
            )
    }
}
