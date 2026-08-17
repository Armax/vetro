import SwiftUI
import AppKit

/// Native Liquid Glass helpers. Every glass surface in the app goes through
/// these so the "Reduce transparency" fallback stays consistent.
extension View {
    /// Large glass panel (sidebar, toolbar, main pane) with a design tint.
    @ViewBuilder
    func glassPanel(tint: Color, enabled: Bool, fallback: Color? = nil) -> some View {
        if enabled {
            // .clear keeps the wallpaper hue vivid (.regular frosts it gray);
            // the design tint is layered explicitly on top of the glass —
            // Glass.tint() alone is too weak to reach the design's darkness.
            self.background(tint).glassEffect(.clear, in: .rect)
        } else if let fallback {
            self.background(fallback)
        } else {
            self
        }
    }

    /// Hover / selection highlight. A plain translucent fill, not glass: the
    /// glass material adds its own luminance and reads far brighter than the
    /// design's subtle rgba fills.
    @ViewBuilder
    func glassHighlight(_ active: Bool, tint: Color, cornerRadius: CGFloat = 9) -> some View {
        if active {
            self.background(tint, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            self
        }
    }

    /// Always-on glass capsule (pills, chips, toasts).
    func glassCapsule(tint: Color, interactive: Bool = false) -> some View {
        glassEffect(
            interactive ? .regular.tint(tint).interactive() : .regular.tint(tint),
            in: .capsule
        )
    }
}

/// Invisible drag strip laid over a pane's edge to resize it. `axisSign` is
/// +1 when the handle sits on the pane's trailing edge (drag right = wider)
/// and −1 on the leading edge.
struct PaneResizeHandle: View {
    let axisSign: Double
    let width: () -> Double
    let setWidth: (Double) -> Void
    @State private var baseWidth: Double?

    var body: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.set()
                } else if baseWidth == nil {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if baseWidth == nil { baseWidth = width() }
                        NSCursor.resizeLeftRight.set()
                        setWidth((baseWidth ?? 0) + axisSign * Double(value.translation.width))
                    }
                    .onEnded { _ in
                        baseWidth = nil
                        NSCursor.arrow.set()
                    }
            )
    }
}
