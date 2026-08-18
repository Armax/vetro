import SwiftUI
import AppKit

/// Hosts a live, long-lived NSView (a terminal surface) inside SwiftUI.
/// The surface view outlives this representable: switching chats reparents
/// the same NSView so the terminal keeps its state.
///
/// During split re-layouts SwiftUI can transiently keep an old host and a
/// new host alive for the same surface, with no update-order guarantee.
/// Each host gets a monotonically increasing generation; the view remembers
/// its owner's generation, and a stale (lower-generation) host may not
/// reparent it or change its focus policy — the newest host always wins.
struct SurfaceHost: NSViewRepresentable {
    let surface: TerminalSurface
    /// Whether this pane is the session's focused leaf. Only the focused
    /// pane may claim first responder, so split re-layouts can't lose or
    /// misroute keyboard focus.
    var focused: Bool = true

    @MainActor private enum Generation {
        static var counter = 0
        static func next() -> Int { counter += 1; return counter }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator {
        let generation = Generation.next()
        var wasFocused = false
    }

    func updateNSView(_ container: NSView, context: Context) {
        let view = surface.view
        guard context.coordinator.generation >= view.hostGeneration else { return }
        view.hostGeneration = context.coordinator.generation
        let reparented = view.superview !== container
        if reparented {
            view.removeFromSuperview()
            container.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        view.claimsFocus = focused
        let becameFocused = focused && !context.coordinator.wasFocused
        context.coordinator.wasFocused = focused
        guard focused else { return }
        if becameFocused {
            // Focus moved here without a re-layout (goto_split, click on
            // another pane's divider side): claim directly.
            DispatchQueue.main.async {
                if view.claimsFocus { view.window?.makeFirstResponder(view) }
            }
        } else {
            // AppKit silently resets first responder to the window when a
            // sibling pane's view is removed; reclaim only then so other
            // controls (search field, sheets) keep their focus.
            DispatchQueue.main.async {
                if view.claimsFocus, let w = view.window, w.firstResponder === w {
                    w.makeFirstResponder(view)
                }
            }
        }
    }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }
}
