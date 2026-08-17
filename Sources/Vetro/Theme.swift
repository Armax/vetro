import SwiftUI

/// Design tokens from the Glass Terminal v3 design (claude.ai/design).
/// Graphite dark is the default; light mirrors the reworked `.vetro-light`
/// CSS variables. Accents are per-theme since v3: the terminal and chat
/// follow the theme instead of always staying dark.
struct Theme {
    let desk: Color
    let sideBG: Color
    let sideLine: Color
    let t1: Color
    let t2: Color
    let t3: Color
    let field: Color
    let fieldHi: Color
    let hover: Color
    let sel: Color
    let selRing: Color
    let toolbar: Color
    let navbar: Color
    let chip: Color
    let chipHi: Color
    let main: Color
    let card: Color
    let cardLine: Color
    let menu: Color
    let menuSolid: Color
    let wallpaperOpacity: Double
    let solidSide: Color
    let solidToolbar: Color

    // Terminal / chat surface tokens (--term / --termsub / --code).
    let term: Color
    let termSub: Color
    let code: Color

    // Terminal text tokens (--tx…--tx4).
    let tx: Color
    let tx2: Color
    let tx3: Color
    let tx4: Color

    // Accents (theme-dependent since v3).
    let accent: Color
    let accentSoft: Color
    let accentTxt: Color
    let accentChip: Color
    let green: Color
    let greenBright: Color
    let promptGreen: Color
    let amber: Color
    let red: Color
    let orange: Color

    // Diff colors (--d-hunk…--gut).
    let diffHunk: Color
    let diffAdd: Color
    let diffDel: Color
    let diffCtx: Color
    let diffAddGutter: Color
    let diffDelGutter: Color
    let diffGutter: Color

    // Summarize provider accents (git panel picker).
    let providerGrok: Color
    let providerChatGPT: Color

    // Dark tint opacities are boosted far above the CSS variables: the CSS
    // gets its darkness from blurring an almost-black desk, while macOS
    // Liquid Glass adds its own brightness — matching the *rendered* v3
    // look (near-black graphite) needs high-opacity dark tints over glass.
    static let dark = Theme(
        desk: Color(hex: 0x07090f),
        sideBG: Color(hex: 0x0a0c12, alpha: 0.86),
        sideLine: .white.opacity(0.06),
        t1: Color(hex: 0xedf3ff, alpha: 0.94),
        t2: Color(hex: 0xe6eeff, alpha: 0.62),
        t3: Color(hex: 0xe1ebff, alpha: 0.40),
        field: .white.opacity(0.07),
        fieldHi: .white.opacity(0.12),
        hover: .white.opacity(0.055),
        sel: .white.opacity(0.09),
        selRing: .white.opacity(0.09),
        // Toolbar / terminal / chat tints are plain overlays on the main
        // glass (like the CSS layers them over --main), so they stay barely
        // darker than the shared surface instead of re-glassing it.
        toolbar: Color(hex: 0x0a0c12, alpha: 0.05),
        navbar: Color(hex: 0x10131b),
        chip: .white.opacity(0.08),
        chipHi: .white.opacity(0.16),
        main: Color(hex: 0x0a0c12, alpha: 0.86),
        card: .white.opacity(0.05),
        cardLine: Color(hex: 0x96b9ff, alpha: 0.13),
        menu: Color(hex: 0x0e1119, alpha: 0.86),
        menuSolid: Color(hex: 0x161a26, alpha: 0.88),
        wallpaperOpacity: 0.35,
        solidSide: Color(hex: 0x14171f),
        solidToolbar: Color(hex: 0x10131b),
        term: Color(hex: 0x0a0c12, alpha: 0.08),
        termSub: Color(hex: 0x0a0c12, alpha: 0.06),
        code: Color(hex: 0x080c18, alpha: 0.35),
        tx: Color(hex: 0xeef1f8),
        tx2: Color(hex: 0xc8cede),
        tx3: Color(hex: 0xebf0fa, alpha: 0.60),
        tx4: Color(hex: 0xebf0fa, alpha: 0.42),
        accent: Color(hex: 0x8ab4ff),
        accentSoft: Color(hex: 0x9db9ff),
        accentTxt: Color(hex: 0xa8c4ff),
        accentChip: Color(hex: 0x789bff, alpha: 0.22),
        green: Color(hex: 0x34d399),
        greenBright: Color(hex: 0x4ade9d),
        promptGreen: Color(hex: 0x7ee2a8),
        amber: Color(hex: 0xffd479),
        red: Color(hex: 0xff8a80),
        orange: Color(hex: 0xffb38a),
        diffHunk: Color(hex: 0x8fb0ff),
        diffAdd: Color(hex: 0xc4eed6),
        diffDel: Color(hex: 0xf2c6c1),
        diffCtx: Color(hex: 0xebeef8, alpha: 0.55),
        diffAddGutter: Color(hex: 0x4ade9d, alpha: 0.45),
        diffDelGutter: Color(hex: 0xff6e62, alpha: 0.45),
        diffGutter: .white.opacity(0.22),
        providerGrok: Color(hex: 0xc9b3ff),
        providerChatGPT: Color(hex: 0x5ad7c8)
    )

    static let light = Theme(
        desk: Color(hex: 0xb9c2d4),
        sideBG: .white.opacity(0.55),
        sideLine: .black.opacity(0.09),
        t1: Color(hex: 0x12141c, alpha: 0.92),
        t2: Color(hex: 0x12141c, alpha: 0.60),
        t3: Color(hex: 0x12141c, alpha: 0.42),
        field: .black.opacity(0.055),
        fieldHi: .white.opacity(0.50),
        hover: .black.opacity(0.06),
        sel: .black.opacity(0.09),
        selRing: .black.opacity(0.05),
        toolbar: .white.opacity(0.60),
        navbar: Color(hex: 0xeef0f6),
        chip: .black.opacity(0.06),
        chipHi: .white.opacity(0.60),
        main: Color(hex: 0xf3f5fa, alpha: 0.78),
        card: .white.opacity(0.55),
        cardLine: .black.opacity(0.09),
        menu: Color(hex: 0xf8f9fd, alpha: 0.90),
        menuSolid: Color(hex: 0xf6f8fc, alpha: 0.92),
        wallpaperOpacity: 0.175,
        solidSide: Color(hex: 0xe8ebf2),
        solidToolbar: Color(hex: 0xeef0f6),
        term: .white.opacity(0.40),
        termSub: .white.opacity(0.32),
        code: Color(hex: 0x121a2c, alpha: 0.05),
        tx: Color(hex: 0x141c2c),
        tx2: Color(hex: 0x33405a),
        tx3: Color(hex: 0x162034, alpha: 0.62),
        tx4: Color(hex: 0x162034, alpha: 0.46),
        accent: Color(hex: 0x2b52c9),
        accentSoft: Color(hex: 0x2b52c9),
        accentTxt: Color(hex: 0x2b52c9),
        accentChip: Color(hex: 0x466ef0, alpha: 0.14),
        green: Color(hex: 0x0e8a5f),
        greenBright: Color(hex: 0x0e8a5f),
        promptGreen: Color(hex: 0x0c7a52),
        amber: Color(hex: 0x8a5f00),
        red: Color(hex: 0xc0392b),
        orange: Color(hex: 0xa34a17),
        diffHunk: Color(hex: 0x2b52c9),
        diffAdd: Color(hex: 0x0d6b45),
        diffDel: Color(hex: 0x8c2f24),
        diffCtx: Color(hex: 0x182030, alpha: 0.62),
        diffAddGutter: Color(hex: 0x0e8a5f, alpha: 0.50),
        diffDelGutter: Color(hex: 0xc0392b, alpha: 0.50),
        diffGutter: .black.opacity(0.25),
        providerGrok: Color(hex: 0x6a48c4),
        providerChatGPT: Color(hex: 0x0b7d6e)
    )

    // Accents identical in both themes.
    static let star = Color(hex: 0xe8b84b)
    static let toggleOn = Color(hex: 0x34c759)
    static let folderBlue = Color(hex: 0x789bfa, alpha: 0.8)
}

enum Wallpaper: String, CaseIterable, Codable {
    case haloBlue = "Halo Blue"
    case dusk = "Dusk"
    case graphite = "Graphite"

    /// Radial gradients matching the CSS design: `radius` is a fraction of
    /// the window width (the CSS ellipse rx / 1400), and each gradient fades
    /// to transparent at 60% of its radius like the CSS color stops.
    var gradients: [(color: Color, center: UnitPoint, radius: CGFloat)] {
        switch self {
        case .haloBlue: [
            (Color(hex: 0x2b4bb8), UnitPoint(x: 0.15, y: 0.08), 0.64),
            (Color(hex: 0x6d3aa8), UnitPoint(x: 0.85, y: 0.20), 0.79),
            (Color(hex: 0x0f6f8f), UnitPoint(x: 0.55, y: 1.00), 0.71),
        ]
        case .dusk: [
            (Color(hex: 0xa84b2b), UnitPoint(x: 0.20, y: 1.00), 0.71),
            (Color(hex: 0x45246e), UnitPoint(x: 0.80, y: 0.00), 0.79),
            (Color(hex: 0x23305e), UnitPoint(x: 0.50, y: 0.40), 0.57),
        ]
        case .graphite: [
            (Color(hex: 0x3a3f4c), UnitPoint(x: 0.25, y: 0.10), 0.71),
            (Color(hex: 0x2a2e3a), UnitPoint(x: 0.80, y: 0.90), 0.64),
        ]
        }
    }
}

struct WallpaperView: View {
    let wallpaper: Wallpaper
    let theme: Theme

    var body: some View {
        GeometryReader { geo in
            ZStack {
                theme.desk
                // v3 dims only the gradient overlay (opacity wallop × .35),
                // never the desk color underneath it.
                ForEach(Array(wallpaper.gradients.enumerated()), id: \.offset) { _, g in
                    RadialGradient(
                        stops: [
                            .init(color: g.color, location: 0),
                            .init(color: g.color.opacity(0), location: 0.6),
                        ],
                        center: g.center,
                        startRadius: 0,
                        endRadius: geo.size.width * g.radius
                    )
                    .opacity(theme.wallpaperOpacity)
                }
            }
        }
        .ignoresSafeArea()
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: alpha
        )
    }
}
