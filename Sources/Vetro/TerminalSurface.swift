import AppKit
import GhosttyKit

/// One live terminal: a libghostty surface plus the NSView it renders into.
/// libghostty drives Metal itself through the NSView pointer; the view only
/// forwards input, size, scale, and focus.
@MainActor
final class TerminalSurface {
    enum Event {
        case titleChanged(String)
        case processEnded(exitCode: Int)
        case closeRequested
        case newSessionRequested
        /// Bell: the running agent wants attention.
        case attention
        /// OSC 9 / OSC 777 desktop notification with the harness's own text.
        case notification(title: String, body: String)
        case splitRequested(ghostty_action_split_direction_e)
        case focusSplit(ghostty_action_goto_split_e)
        case resizeSplit(direction: ghostty_action_resize_split_direction_e, amount: UInt16)
        case equalizeSplits
        case toggleSplitZoom
    }

    let id = UUID()
    let view: TerminalSurfaceView
    private(set) var surface: ghostty_surface_t?
    private let onEvent: (TerminalSurface, Event) -> Void
    /// Invoked when this surface's view becomes first responder (click / focus).
    var onFocused: (() -> Void)?
    private var closed = false

    init(
        workingDirectory: String,
        command: String? = nil,
        fontSize: Int = 13,
        sessionID: UUID = UUID(),
        context: ghostty_surface_context_e = GHOSTTY_SURFACE_CONTEXT_WINDOW,
        onEvent: @escaping (TerminalSurface, Event) -> Void
    ) throws {
        try GhosttyRuntime.shared.start()
        guard let app = GhosttyRuntime.shared.app else { throw GhosttyError.appCreationFailed }
        self.onEvent = onEvent
        // Non-zero initial frame is required so the layer bounds are non-zero.
        self.view = TerminalSurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(view).toOpaque()
        ))
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        cfg.font_size = Float(fontSize)
        cfg.context = context

        // C-string lifetimes: strdup'd, freed after ghostty_surface_new copies.
        var cStrings: [UnsafeMutablePointer<CChar>] = []
        defer { cStrings.forEach { free($0) } }
        func cstr(_ s: String) -> UnsafeMutablePointer<CChar> {
            let p = strdup(s)!
            cStrings.append(p)
            return p
        }

        cfg.working_directory = UnsafePointer(cstr(workingDirectory))
        if let command {
            cfg.command = UnsafePointer(cstr(command))
        }

        // Session identity for harness lifecycle hooks (see HookServer).
        var envVars = [
            ghostty_env_var_s(
                key: UnsafePointer(cstr("VETRO_SESSION_ID")),
                value: UnsafePointer(cstr(sessionID.uuidString))
            ),
            ghostty_env_var_s(
                key: UnsafePointer(cstr("VETRO_SOCK")),
                value: UnsafePointer(cstr(HookServer.socketPath))
            ),
        ]

        let created: ghostty_surface_t? = envVars.withUnsafeMutableBufferPointer { buf in
            cfg.env_vars = buf.baseAddress
            cfg.env_var_count = buf.count
            return ghostty_surface_new(app, &cfg)
        }
        guard let created else { throw GhosttyError.surfaceCreationFailed }
        self.surface = created
        view.owner = self
    }

    static func from(_ userdata: UnsafeMutableRawPointer?) -> TerminalSurface? {
        guard let userdata else { return nil }
        return Unmanaged<TerminalSurface>.fromOpaque(userdata).takeUnretainedValue()
    }

    func emit(_ event: Event) {
        guard !closed else { return }
        onEvent(self, event)
    }

    func close() {
        guard !closed, let surface else { return }
        closed = true
        self.surface = nil
        view.owner = nil
        view.removeFromSuperview()
        ghostty_surface_free(surface)
    }

    func sendText(_ text: String) {
        guard let surface else { return }
        text.withCString { cString in
            ghostty_surface_text(surface, cString, UInt(text.utf8.count))
        }
    }

    func sendReturn() {
        // No text payload: the real keyboard path only attaches text for
        // codepoints >= 0x20, so ghostty encodes Return from the keycode.
        guard surface != nil else { return }
        view.sendSyntheticKey(keycode: 0x24, unshiftedCodepoint: 0x0d)
    }

    func sendEscape() {
        guard surface != nil else { return }
        view.sendSyntheticKey(keycode: 0x35, unshiftedCodepoint: 0x1b)
    }
}

/// The NSView libghostty renders into. Must not set `wantsLayer` or override
/// `draw` — libghostty installs its own IOSurface-backed layer.
final class TerminalSurfaceView: NSView {
    weak var owner: TerminalSurface?
    private var currentCursor: NSCursor = .iBeam
    private var currentTrackingArea: NSTrackingArea?

    private var surface: ghostty_surface_t? { owner?.surface }

    /// Set by SurfaceHost from the split tree: only the focused pane may
    /// claim first responder when it (re)enters a window, so split
    /// re-layouts can't misroute keyboard focus.
    var claimsFocus = true
    /// Generation of the SurfaceHost currently owning this view; stale
    /// hosts (lower generation) may not reparent it or change focus policy.
    var hostGeneration = 0

    // A closed surface's view must never take focus.
    override var acceptsFirstResponder: Bool { owner != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(Array(Self.dropTypes))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Lifecycle / geometry

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        updateDisplayID()
        syncScale()
        syncSize()
        if claimsFocus, owner != nil {
            window?.makeFirstResponder(self)
        }
    }

    override func layout() {
        super.layout()
        syncSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncScale()
        syncSize()
    }

    private func syncSize() {
        guard let surface else { return }
        let backing = convertToBacking(bounds)
        guard backing.width > 0, backing.height > 0 else { return }
        ghostty_surface_set_size(surface, UInt32(backing.width), UInt32(backing.height))
    }

    private func syncScale() {
        guard let window else { return }
        let scale = window.backingScaleFactor
        if let layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contentsScale = scale
            CATransaction.commit()
        }
        if let surface {
            ghostty_surface_set_content_scale(surface, scale, scale)
        }
    }

    private func updateDisplayID() {
        guard let surface,
              let screen = window?.screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
        else { return }
        ghostty_surface_set_display_id(surface, number)
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let surface { ghostty_surface_set_focus(surface, true) }
        if ok { owner?.onFocused?() }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok, let surface { ghostty_surface_set_focus(surface, false) }
        return ok
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        sendKey(event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS, event: event)
    }

    override func keyUp(with event: NSEvent) {
        sendKey(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let mods = event.modifierFlags
        let pressed: Bool
        switch event.keyCode {
        case 0x39: pressed = mods.contains(.capsLock)
        case 0x38, 0x3C: pressed = mods.contains(.shift)
        case 0x3B, 0x3E: pressed = mods.contains(.control)
        case 0x3A, 0x3D: pressed = mods.contains(.option)
        case 0x37, 0x36: pressed = mods.contains(.command)
        default: return
        }
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.action = pressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
        key.mods = Self.ghosttyMods(mods)
        key.keycode = UInt32(event.keyCode)
        key.text = nil
        _ = ghostty_surface_key(surface, key)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Give ghostty keybindings (Cmd+C/V, etc.) a shot before the menu,
        // but only when this terminal is focused.
        guard event.type == .keyDown,
              window?.firstResponder === self,
              surface != nil
        else { return false }
        return sendKey(GHOSTTY_ACTION_PRESS, event: event)
    }

    @discardableResult
    private func sendKey(_ action: ghostty_input_action_e, event: NSEvent) -> Bool {
        let mods = Self.ghosttyMods(event.modifierFlags)
        let unshiftedCodepoint = event.characters(byApplyingModifiers: [])?
            .unicodeScalars.first?.value

        var text: String?
        if action != GHOSTTY_ACTION_RELEASE,
           let characters = event.characters,
           let first = characters.unicodeScalars.first,
           first.value >= 0x20,
           !(0xF700...0xF8FF).contains(first.value) {
            text = characters
        }

        return sendKey(
            action,
            keycode: UInt32(event.keyCode),
            mods: mods,
            unshiftedCodepoint: unshiftedCodepoint,
            text: text
        )
    }

    func sendSyntheticKey(
        keycode: UInt32,
        unshiftedCodepoint: UInt32,
        text: String? = nil
    ) {
        _ = sendKey(
            GHOSTTY_ACTION_PRESS,
            keycode: keycode,
            mods: GHOSTTY_MODS_NONE,
            unshiftedCodepoint: unshiftedCodepoint,
            text: text
        )
        _ = sendKey(
            GHOSTTY_ACTION_RELEASE,
            keycode: keycode,
            mods: GHOSTTY_MODS_NONE,
            unshiftedCodepoint: unshiftedCodepoint
        )
    }

    @discardableResult
    private func sendKey(
        _ action: ghostty_input_action_e,
        keycode: UInt32,
        mods: ghostty_input_mods_e,
        unshiftedCodepoint: UInt32?,
        text: String? = nil
    ) -> Bool {
        guard let surface else { return false }
        var key = ghostty_input_key_s()
        key.action = action
        key.mods = mods
        key.keycode = keycode
        key.composing = false

        if let unshiftedCodepoint {
            key.unshifted_codepoint = unshiftedCodepoint
        }

        if let text {
            // Heuristic from the reference app: mods that produced the text
            // are consumed, except ctrl/super which ghostty encodes itself.
            key.consumed_mods = ghostty_input_mods_e(
                key.mods.rawValue
                    & ~(GHOSTTY_MODS_CTRL.rawValue | GHOSTTY_MODS_SUPER.rawValue)
            )
            return text.withCString { cstr in
                key.text = cstr
                return ghostty_surface_key(surface, key)
            }
        }
        key.text = nil
        return ghostty_surface_key(surface, key)
    }

    private static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(mods)
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let currentTrackingArea { removeTrackingArea(currentTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        currentTrackingArea = area
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event)
    }

    override func mouseUp(with event: NSEvent) {
        sendMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event)
    }

    override func rightMouseDown(with event: NSEvent) {
        if !sendMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, event) {
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        if !sendMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, event) {
            super.rightMouseUp(with: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        sendMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, event)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        sendMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, event)
    }

    // Reached via super.rightMouseDown when ghostty doesn't capture the
    // click (mouse-reporting apps consume it, matching Ghostty's behavior).
    override func menu(for event: NSEvent) -> NSMenu? {
        guard event.type == .rightMouseDown else { return nil }
        let menu = NSMenu()
        if let surface, ghostty_surface_has_selection(surface) {
            addItem(to: menu, title: "Copy", action: #selector(copySelection(_:)))
        }
        addItem(to: menu, title: "Paste", action: #selector(pasteClipboard(_:)))
        menu.addItem(.separator())
        addItem(to: menu, title: "Split Right", action: #selector(splitRight(_:)))
        addItem(to: menu, title: "Split Left", action: #selector(splitLeft(_:)))
        addItem(to: menu, title: "Split Down", action: #selector(splitDown(_:)))
        addItem(to: menu, title: "Split Up", action: #selector(splitUp(_:)))
        return menu
    }

    private func addItem(to menu: NSMenu, title: String, action: Selector) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
    }

    private func bindingAction(_ action: String) {
        guard let surface else { return }
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    @objc private func copySelection(_ sender: Any?) { bindingAction("copy_to_clipboard") }
    @objc private func pasteClipboard(_ sender: Any?) { bindingAction("paste_from_clipboard") }
    @objc private func splitRight(_ sender: Any?) { owner?.emit(.splitRequested(GHOSTTY_SPLIT_DIRECTION_RIGHT)) }
    @objc private func splitLeft(_ sender: Any?) { owner?.emit(.splitRequested(GHOSTTY_SPLIT_DIRECTION_LEFT)) }
    @objc private func splitDown(_ sender: Any?) { owner?.emit(.splitRequested(GHOSTTY_SPLIT_DIRECTION_DOWN)) }
    @objc private func splitUp(_ sender: Any?) { owner?.emit(.splitRequested(GHOSTTY_SPLIT_DIRECTION_UP)) }

    override func mouseMoved(with event: NSEvent) { sendMousePos(event) }
    override func mouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func mouseEntered(with event: NSEvent) { sendMousePos(event) }

    override func mouseExited(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, Self.ghosttyMods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        var scrollMods: Int32 = 0
        if event.hasPreciseScrollingDeltas {
            x *= 2
            y *= 2
            scrollMods |= 1
        }
        let momentum: Int32
        switch event.momentumPhase {
        case .began: momentum = 1
        case .stationary: momentum = 2
        case .changed: momentum = 3
        case .ended: momentum = 4
        case .cancelled: momentum = 5
        case .mayBegin: momentum = 6
        default: momentum = 0
        }
        scrollMods |= momentum << 1
        ghostty_surface_mouse_scroll(surface, x, y, scrollMods)
    }

    @discardableResult
    private func sendMouseButton(
        _ state: ghostty_input_mouse_state_e,
        _ button: ghostty_input_mouse_button_e,
        _ event: NSEvent
    ) -> Bool {
        guard let surface else { return false }
        return ghostty_surface_mouse_button(surface, state, button, Self.ghosttyMods(event.modifierFlags))
    }

    private func sendMousePos(_ event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, Self.ghosttyMods(event.modifierFlags))
    }

    // MARK: - Cursor

    func mouseShape(_ shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT: currentCursor = .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER: currentCursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: currentCursor = .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB: currentCursor = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: currentCursor = .closedHand
        default: currentCursor = .arrow
        }
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: currentCursor)
    }

    // MARK: - Drag & drop

    static let dropTypes: Set<NSPasteboard.PasteboardType> = [.string, .fileURL]

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types else { return [] }
        return Set(types).isDisjoint(with: Self.dropTypes) ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let content = sender.draggingPasteboard.vetroDropStringContents() else { return false }
        owner?.sendText(content)
        return true
    }
}

private extension NSPasteboard {
    /// File-URL items become shell-escaped paths; plain strings pass through.
    /// Multiple items join with a space. Nil when nothing usable was dropped.
    func vetroDropStringContents() -> String? {
        let strings = (pasteboardItems ?? []).compactMap { item -> String? in
            if let plist = item.propertyList(forType: .fileURL),
               let url = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?,
               url.isFileURL {
                return shellEscape(url.path)
            }
            return item.string(forType: .string)
        }
        return strings.isEmpty ? nil : strings.joined(separator: " ")
    }
}

// Characters to escape in the shell.
private let shellEscapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

/// Prefix each shell-sensitive character with a backslash.
private func shellEscape(_ str: String) -> String {
    var result = str
    for char in shellEscapeCharacters {
        result = result.replacingOccurrences(of: String(char), with: "\\\(char)")
    }
    return result
}
