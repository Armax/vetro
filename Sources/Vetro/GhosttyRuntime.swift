import AppKit
import GhosttyKit

enum GhosttyError: LocalizedError {
    case appCreationFailed
    case surfaceCreationFailed

    var errorDescription: String? {
        switch self {
        case .appCreationFailed: "Could not start the terminal engine."
        case .surfaceCreationFailed: "Could not create the terminal session."
        }
    }
}

/// Owns the single libghostty app instance and its runtime callbacks.
/// All callbacks except wakeup are invoked during `ghostty_app_tick`,
/// i.e. on the main thread.
@MainActor
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?

    private init() {}

    func start() throws {
        guard app == nil else { return }

        guard let config = ghostty_config_new() else { throw GhosttyError.appCreationFailed }
        ghostty_config_load_default_files(config)
        // Design overrides (loaded last so they win): terminal surface colors
        // matching the Glass Terminal v3 design. The terminal now follows the
        // theme; appearance is read once at start (a relaunch picks up a change).
        // background-opacity is kept low so the SwiftUI glass/wallpaper layered
        // behind the surface shows through, matching v3's translucent --term.
        let light = UserDefaults.standard.string(forKey: "appearance") == "light"
        let overrides = light ? """
        background = #f4f6fb
        background-opacity = 0.1
        background-opacity-cells = true
        foreground = #141c2c
        window-padding-x = 12
        window-padding-y = 8
        cursor-color = #2b52c9
        selection-background = #141c2c
        selection-foreground = #f4f6fb
        """ : """
        background = #0a0c12
        background-opacity = 0.1
        background-opacity-cells = true
        foreground = #eef1f8
        window-padding-x = 12
        window-padding-y = 8
        cursor-color = #8ab4ff
        selection-background = #eef1f8
        selection-foreground = #0a0c12
        """
        let overridesURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vetro-ghostty-config")
        try? overrides.write(to: overridesURL, atomically: true, encoding: .utf8)
        ghostty_config_load_file(config, overridesURL.path)
        ghostty_config_finalize(config)
        self.config = config

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = nil
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GhosttyRuntime.shared.tick() }
            }
        }
        runtime.action_cb = { app, target, action in
            MainActor.assumeIsolated { GhosttyRuntime.handleAction(app, target, action) }
        }
        runtime.read_clipboard_cb = { userdata, location, state in
            MainActor.assumeIsolated { GhosttyRuntime.readClipboard(userdata, location, state) }
        }
        runtime.confirm_read_clipboard_cb = { userdata, string, state, _ in
            MainActor.assumeIsolated {
                guard let surface = TerminalSurface.from(userdata) else { return }
                ghostty_surface_complete_clipboard_request(surface.surface, string, state, true)
            }
        }
        runtime.write_clipboard_cb = { userdata, location, contents, count, _ in
            MainActor.assumeIsolated { GhosttyRuntime.writeClipboard(userdata, location, contents, count) }
        }
        runtime.close_surface_cb = { userdata, _ in
            MainActor.assumeIsolated {
                TerminalSurface.from(userdata)?.emit(.closeRequested)
            }
        }

        guard let app = ghostty_app_new(&runtime, config) else {
            throw GhosttyError.appCreationFailed
        }
        self.app = app
        ghostty_app_set_focus(app, NSApp.isActive)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if let app = GhosttyRuntime.shared.app { ghostty_app_set_focus(app, true) }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if let app = GhosttyRuntime.shared.app { ghostty_app_set_focus(app, false) }
            }
        }
    }

    private func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    // MARK: - Actions

    private static func handleAction(
        _ app: ghostty_app_t?,
        _ target: ghostty_target_s,
        _ action: ghostty_action_s
    ) -> Bool {
        let surface: TerminalSurface? = {
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let s = target.target.surface
            else { return nil }
            return TerminalSurface.from(ghostty_surface_userdata(s))
        }()

        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let surface, let title = action.action.set_title.title else { return false }
            surface.emit(.titleChanged(String(cString: title)))

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            guard let surface else { return false }
            surface.emit(.processEnded(exitCode: Int(action.action.child_exited.exit_code)))

        case GHOSTTY_ACTION_CLOSE_WINDOW, GHOSTTY_ACTION_CLOSE_TAB:
            guard let surface else { return false }
            surface.emit(.closeRequested)

        case GHOSTTY_ACTION_NEW_WINDOW, GHOSTTY_ACTION_NEW_TAB:
            guard let surface else { return false }
            surface.emit(.newSessionRequested)

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            surface?.view.mouseShape(action.action.mouse_shape)

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            if action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN {
                NSCursor.setHiddenUntilMouseMoves(true)
            }

        case GHOSTTY_ACTION_RING_BELL:
            NSSound.beep()
            surface?.emit(.attention)

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            guard let surface else { return false }
            let payload = action.action.desktop_notification
            surface.emit(.notification(
                title: payload.title.map { String(cString: $0) } ?? "",
                body: payload.body.map { String(cString: $0) } ?? ""
            ))

        case GHOSTTY_ACTION_NEW_SPLIT:
            guard let surface else { return false }
            surface.emit(.splitRequested(action.action.new_split))

        case GHOSTTY_ACTION_GOTO_SPLIT:
            guard let surface else { return false }
            surface.emit(.focusSplit(action.action.goto_split))

        case GHOSTTY_ACTION_RESIZE_SPLIT:
            guard let surface else { return false }
            let r = action.action.resize_split
            surface.emit(.resizeSplit(direction: r.direction, amount: r.amount))

        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            guard let surface else { return false }
            surface.emit(.equalizeSplits)

        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
            guard let surface else { return false }
            surface.emit(.toggleSplitZoom)

        case GHOSTTY_ACTION_QUIT:
            NSApp.terminate(nil)

        default:
            return false
        }
        return true
    }

    // MARK: - Clipboard

    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        _ location: ghostty_clipboard_e,
        _ state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let surface = TerminalSurface.from(userdata),
              location == GHOSTTY_CLIPBOARD_STANDARD,
              let string = NSPasteboard.general.string(forType: .string)
        else { return false }
        ghostty_surface_complete_clipboard_request(surface.surface, string, state, false)
        return true
    }

    private static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        _ location: ghostty_clipboard_e,
        _ contents: UnsafePointer<ghostty_clipboard_content_s>?,
        _ count: Int
    ) {
        guard location == GHOSTTY_CLIPBOARD_STANDARD, let contents, count > 0 else { return }
        for i in 0..<count {
            let content = contents[i]
            guard let mime = content.mime, let data = content.data else { continue }
            if String(cString: mime).hasPrefix("text/plain") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(String(cString: data), forType: .string)
                return
            }
        }
    }
}
