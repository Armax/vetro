import AppKit
import SwiftUI

/// Recursive layout for a session's split tree. Leaves mount the reparenting
/// `SurfaceHost`; branches divide the space with a draggable `SplitDivider`.
struct SplitContainer: View {
    let node: SplitNode
    let focusedID: UUID
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if let surface = node.surface {
            leaf(surface)
        } else if let axis = node.axis, let a = node.a, let b = node.b {
            branch(axis: axis, a: a, b: b)
        }
    }

    private func leaf(_ surface: TerminalSurface) -> some View {
        // A lone root leaf has no parent: no ring until the pane is split.
        let focused = node.id == focusedID && node.parent != nil
        return SurfaceHost(surface: surface, focused: node.id == focusedID)
            .id(surface.id)
            .overlay {
                if focused {
                    Rectangle()
                        .strokeBorder(settings.theme.accentSoft.opacity(0.7), lineWidth: 1)
                }
            }
    }

    private func branch(axis: SplitAxis, a: SplitNode, b: SplitNode) -> some View {
        GeometryReader { geo in
            let horizontal = axis == .horizontal
            let total = horizontal ? geo.size.width : geo.size.height
            let aSize = max(60, min(max(total - 60, 60), total * node.ratio))
            let ratio = Binding(get: { node.ratio }, set: { node.ratio = $0 })
            if horizontal {
                HStack(spacing: 0) {
                    SplitContainer(node: a, focusedID: focusedID).frame(width: aSize)
                    SplitDivider(axis: axis, ratio: ratio, total: total)
                    SplitContainer(node: b, focusedID: focusedID).frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    SplitContainer(node: a, focusedID: focusedID).frame(height: aSize)
                    SplitDivider(axis: axis, ratio: ratio, total: total)
                    SplitContainer(node: b, focusedID: focusedID).frame(maxHeight: .infinity)
                }
            }
        }
    }
}

/// A thin drag strip with a centered 1px glass line, resizing its branch's
/// `ratio` fractionally on either axis.
struct SplitDivider: View {
    let axis: SplitAxis
    @Binding var ratio: CGFloat
    let total: CGFloat
    @Environment(AppSettings.self) private var settings
    @State private var base: CGFloat?

    var body: some View {
        let horizontal = axis == .horizontal
        let line = settings.theme.sideLine
        Color.clear
            .frame(width: horizontal ? 7 : nil, height: horizontal ? nil : 7)
            .frame(maxWidth: horizontal ? nil : .infinity, maxHeight: horizontal ? .infinity : nil)
            .overlay {
                line.frame(width: horizontal ? 1 : nil, height: horizontal ? nil : 1)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                } else if base == nil {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if base == nil { base = ratio }
                        (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                        let moved = horizontal ? value.translation.width : value.translation.height
                        ratio = min(0.9, max(0.1, (base ?? ratio) + moved / max(total, 1)))
                    }
                    .onEnded { _ in
                        base = nil
                        NSCursor.arrow.set()
                    }
            )
    }
}
