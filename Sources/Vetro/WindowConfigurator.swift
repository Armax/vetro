import SwiftUI
import AppKit

/// Window chrome to match the design: transparent full-size titlebar with the
/// traffic lights lowered (~y26) onto the sidebar header row. The lights are
/// repositioned manually — the earlier empty unified toolbar achieved the same
/// alignment but its invisible titlebar strip swallowed clicks on the session
/// toolbar.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ConfigView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ConfigView: NSView {
        private var observers: [any NSObjectProtocol] = []

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert(.fullSizeContentView)
            window.toolbar = nil
            lowerTrafficLights()
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didExitFullScreenNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.lowerTrafficLights()
                    }
                }
            }
        }

        private func lowerTrafficLights() {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for type in types {
                guard let button = window.standardWindowButton(type),
                      let bar = button.superview
                else { continue }
                // Center the button on the 52pt header row measured from the
                // window top; the titlebar container uses a bottom-left origin.
                let targetY = bar.frame.height - 26 - button.frame.height / 2
                if abs(button.frame.origin.y - targetY) > 0.5 {
                    button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: targetY))
                }
            }
        }
    }
}
