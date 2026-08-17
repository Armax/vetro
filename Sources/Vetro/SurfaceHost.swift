import SwiftUI
import AppKit

/// Hosts a live, long-lived NSView (a terminal surface) inside SwiftUI.
/// The surface view outlives this representable: switching chats reparents
/// the same NSView so the terminal keeps its state.
struct SurfaceHost: NSViewRepresentable {
    let surface: TerminalSurface

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ container: NSView, context: Context) {
        let view = surface.view
        if view.superview !== container {
            view.removeFromSuperview()
            container.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
            }
        }
    }
}
