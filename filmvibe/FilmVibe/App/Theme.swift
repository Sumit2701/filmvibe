import SwiftUI

enum Theme {
    static let accent = Color(red: 0.957, green: 0.678, blue: 0.290)
    static let background = Color.black
    static let panel = Color(white: 0.075)
    static let panel2 = Color(white: 0.13)
    static let text = Color(white: 0.93)
    static let dim = Color(white: 0.55)
    static let faint = Color(white: 0.3)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func label(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight)
    }
}

/// Small rounded tag, e.g. "RAW", "DR400".
struct Tag: View {
    let text: String
    var color: Color = Theme.dim
    var filled = false

    var body: some View {
        Text(text)
            .font(Theme.mono(10, .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .foregroundStyle(filled ? Color.black : color)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(filled ? color : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(color, lineWidth: filled ? 0 : 1)
            )
    }
}
