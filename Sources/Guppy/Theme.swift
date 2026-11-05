import SwiftUI

// Guppy's look: white and orange, calm and minimal (the same palette as Guppy for Windows).

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }

    static let guppyOrange = Color(hex: 0xFF7010)
    static let guppyOrangeStrong = Color(hex: 0xEA5D00)
    static let guppySoft = Color(hex: 0xFFF1E6)
    static let guppySurface = Color(hex: 0xFFFAF5)
    static let guppyBorder = Color(hex: 0xEADFD5)
    static let guppySeparator = Color(hex: 0xF1E7DE)
    static let guppyLabel = Color(hex: 0x1F1915)
    static let guppySecondary = Color(hex: 0x7D716A)
    static let guppyTertiary = Color(hex: 0xB5AAA2)
    static let guppyRed = Color(hex: 0xD93A1F)
    static let guppyGreen = Color(hex: 0x2F9E5B)
    static let guppyShadow = Color(hex: 0x502800)
}

// MARK: - Logo

/// The Guppy logo (public/logo.svg in Guppy for Windows), drawn in a 512 × 512 space.
struct GuppyLogo: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 512
            context.translateBy(x: (size.width - 512 * scale) / 2, y: (size.height - 512 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            Self.draw(in: &context)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private static func gradient(_ from: UInt32, _ to: UInt32, _ start: CGPoint, _ end: CGPoint) -> GraphicsContext.Shading {
        .linearGradient(Gradient(colors: [Color(hex: from), Color(hex: to)]), startPoint: start, endPoint: end)
    }

    private static func circle(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
    }

    private static func draw(in context: inout GraphicsContext) {
        // Fan tail with a soft wavy edge.
        var tail = Path()
        tail.move(to: CGPoint(x: 276, y: 256))
        tail.addCurve(to: CGPoint(x: 420, y: 92), control1: CGPoint(x: 318, y: 214), control2: CGPoint(x: 360, y: 140))
        tail.addCurve(to: CGPoint(x: 470, y: 150), control1: CGPoint(x: 446, y: 108), control2: CGPoint(x: 458, y: 126))
        tail.addCurve(to: CGPoint(x: 500, y: 256), control1: CGPoint(x: 492, y: 186), control2: CGPoint(x: 504, y: 220))
        tail.addCurve(to: CGPoint(x: 470, y: 362), control1: CGPoint(x: 504, y: 292), control2: CGPoint(x: 492, y: 326))
        tail.addCurve(to: CGPoint(x: 420, y: 420), control1: CGPoint(x: 458, y: 386), control2: CGPoint(x: 446, y: 404))
        tail.addCurve(to: CGPoint(x: 276, y: 256), control1: CGPoint(x: 360, y: 372), control2: CGPoint(x: 318, y: 298))
        tail.closeSubpath()
        context.fill(tail, with: gradient(0xFF7410, 0xFFB54A, CGPoint(x: 276, y: 0), CGPoint(x: 504, y: 0)))
        for (x, y, radius) in [(420, 196, 13), (452, 256, 11), (420, 316, 13), (372, 232, 8), (372, 280, 8)] as [(CGFloat, CGFloat, CGFloat)] {
            context.fill(circle(x, y, radius), with: .color(.white.opacity(0.55)))
        }

        // Dorsal and belly fins.
        var dorsal = Path()
        dorsal.move(to: CGPoint(x: 186, y: 186))
        dorsal.addCurve(to: CGPoint(x: 304, y: 124), control1: CGPoint(x: 206, y: 140), control2: CGPoint(x: 254, y: 118))
        dorsal.addCurve(to: CGPoint(x: 238, y: 204), control1: CGPoint(x: 294, y: 162), control2: CGPoint(x: 270, y: 192))
        dorsal.closeSubpath()
        context.fill(dorsal, with: gradient(0xFFC56B, 0xFF8A1F, CGPoint(x: 0, y: 118), CGPoint(x: 0, y: 204)))

        var belly = Path()
        belly.move(to: CGPoint(x: 206, y: 322))
        belly.addCurve(to: CGPoint(x: 264, y: 374), control1: CGPoint(x: 214, y: 352), control2: CGPoint(x: 236, y: 372))
        belly.addCurve(to: CGPoint(x: 232, y: 322), control1: CGPoint(x: 262, y: 350), control2: CGPoint(x: 250, y: 332))
        belly.closeSubpath()
        context.fill(belly, with: gradient(0xFFC56B, 0xFF8A1F, CGPoint(x: 0, y: 322), CGPoint(x: 0, y: 374)))

        // Body.
        var body = Path()
        body.move(to: CGPoint(x: 36, y: 262))
        body.addCurve(to: CGPoint(x: 188, y: 178), control1: CGPoint(x: 36, y: 210), control2: CGPoint(x: 104, y: 178))
        body.addCurve(to: CGPoint(x: 312, y: 256), control1: CGPoint(x: 248, y: 178), control2: CGPoint(x: 290, y: 206))
        body.addCurve(to: CGPoint(x: 188, y: 334), control1: CGPoint(x: 290, y: 306), control2: CGPoint(x: 248, y: 334))
        body.addCurve(to: CGPoint(x: 36, y: 262), control1: CGPoint(x: 104, y: 334), control2: CGPoint(x: 36, y: 312))
        body.closeSubpath()
        context.fill(body, with: gradient(0xFF9A2E, 0xF25A00, CGPoint(x: 0, y: 178), CGPoint(x: 0, y: 334)))

        var gill = Path()
        gill.move(to: CGPoint(x: 146, y: 212))
        gill.addCurve(to: CGPoint(x: 146, y: 306), control1: CGPoint(x: 132, y: 238), control2: CGPoint(x: 132, y: 282))
        context.stroke(gill, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 9, lineCap: .round))

        // Eye.
        context.fill(circle(96, 244, 22), with: .color(.white))
        context.fill(circle(91, 246, 11), with: .color(Color(hex: 0x2B1405)))
        context.fill(circle(87, 241, 4), with: .color(.white))
    }
}

// MARK: - Buttons

/// Guppy's buttons: white with a hairline border, or orange when `prominent`.
struct GuppyButtonStyle: ButtonStyle {
    var prominent = false
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        GuppyButton(configuration: configuration, prominent: prominent, large: large)
    }

    private struct GuppyButton: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        let large: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: large ? 11 : 9, style: .continuous)
            configuration.label
                .labelStyle(.titleAndIcon)
                .font(.system(size: large ? 14 : 13, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : Color.guppyLabel)
                .padding(.horizontal, large ? 20 : 14)
                .frame(minHeight: large ? 38 : 32)
                .background(shape.fill(background))
                .overlay(shape.strokeBorder(prominent ? Color.clear : border, lineWidth: 1))
                .shadow(color: prominent ? Color.guppyOrange.opacity(0.25) : .clear, radius: 6, y: 3)
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { isHovered = $0 }
        }

        private var background: Color {
            if prominent { return isHovered && isEnabled ? .guppyOrangeStrong : .guppyOrange }
            return isHovered && isEnabled ? .guppySoft : .white
        }

        private var border: Color {
            isHovered && isEnabled ? Color.guppyOrange.opacity(0.35) : .guppyBorder
        }
    }
}

/// A borderless icon button that turns orange on hover.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconButton(configuration: configuration)
    }

    private struct IconButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isHovered && isEnabled ? Color.guppyOrangeStrong : Color.guppySecondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(isHovered && isEnabled ? Color.guppyOrange.opacity(0.12) : .clear))
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { isHovered = $0 }
        }
    }
}

/// Small grey text buttons, such as "Clear finished".
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietButton(configuration: configuration)
    }

    private struct QuietButton: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .labelStyle(.titleAndIcon)
                .font(.system(size: 12))
                .foregroundStyle(isHovered ? Color.guppyOrangeStrong : Color.guppySecondary)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(isHovered ? Color.guppyOrange.opacity(0.06) : .clear))
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
        }
    }
}

// MARK: - Progress

/// A thin orange bar; nil shows a moving stripe while the amount is unknown.
struct GuppyProgressBar: View {
    let value: Double?
    @State private var phase: CGFloat = -0.35

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.guppyOrange.opacity(0.12))
                if let value {
                    Capsule()
                        .fill(LinearGradient(colors: [Color(hex: 0xFF9A3C), .guppyOrange], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geometry.size.width * min(max(value, 0), 1))
                        .animation(.easeOut(duration: 0.25), value: value)
                } else {
                    Capsule()
                        .fill(Color.guppyOrange)
                        .frame(width: geometry.size.width * 0.35)
                        .offset(x: geometry.size.width * phase)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) { phase = 1 }
                        }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityValue(value.map { "\(Int($0 * 100)) percent" } ?? "In progress")
    }
}

/// A rounded card with Guppy's border and soft shadow.
struct CardModifier: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(shape.fill(Color.white))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.guppyBorder, lineWidth: 1))
            .shadow(color: Color.guppyShadow.opacity(0.06), radius: 8, y: 3)
    }
}

extension View {
    func card(cornerRadius: CGFloat = 16) -> some View {
        modifier(CardModifier(cornerRadius: cornerRadius))
    }
}
