import SwiftUI
import AppKit

/// Reusable hover-tracking wrapper (the design uses hover fills everywhere).
struct Hoverable<Content: View>: View {
    @State private var hovered = false
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        content(hovered)
            .onHover { hovered = $0 }
    }
}

struct SidebarView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionManager.self) private var sessions
    @Environment(AppSettings.self) private var settings
    @Environment(VMStore.self) private var vms
    @Environment(UIState.self) private var ui

    var body: some View {
        @Bindable var ui = ui
        let theme = settings.theme
        VStack(spacing: 0) {
            header(theme)
            if ui.view == .settings {
                settingsNav(theme)
            } else {
                appNav(theme)
            }
            footer(theme)
        }
        .sheet(item: $ui.transferPreviewRequest) { request in
            TransferPreviewSheet(
                project: request.project,
                direction: request.direction
            )
            .presentationBackground(.clear)
        }
    }

    // MARK: Header

    private func header(_ theme: Theme) -> some View {
        HStack(spacing: 8) {
            // Native traffic lights sit over this leading gap, on this row.
            Spacer().frame(width: 74)
            Text("Vetro")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(theme.t1)
            Spacer()
            Hoverable { hovered in
                Button {
                    settings.sidebarVisible = false
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 12))
                        .foregroundStyle(hovered ? theme.t1 : theme.t2)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide sidebar")
            }
        }
        // Same height as the unified toolbar; the traffic lights are centered
        // on this row (y26), so the content stays on the natural centerline.
        .frame(height: 52)
        .padding(.horizontal, 16)
    }

    // MARK: App navigation

    @ViewBuilder
    private func appNav(_ theme: Theme) -> some View {
        SearchField(placeholder: "Search chats", shortcutHint: "⌘K")
            .padding(EdgeInsets(top: 6, leading: 12, bottom: 10, trailing: 12))

        sectionLabel("Environments", theme)
        VStack(spacing: 3) {
            EnvironmentGroup(kind: .mac)
            ForEach(vms.vms) { EnvironmentGroup(kind: .vm($0)) }
        }
        .padding(EdgeInsets(top: 2, leading: 8, bottom: 6, trailing: 8))

        if store.projects.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 26))
                    .foregroundStyle(theme.t3)
                Text("No Projects")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.t1)
                if vms.vms.isEmpty {
                    Hoverable { hovered in
                        Button {
                            addProjectAndStart(store: store, sessions: sessions)
                        } label: {
                            addProjectCapsule(theme, hovered: hovered)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Hoverable { hovered in
                        Menu {
                            Button("From Mac…") {
                                addProjectAndStart(store: store, sessions: sessions)
                            }
                            Divider()
                            ForEach(vms.vms) { vm in
                                Button("From \(vm.name)…") {
                                    ui.presentAddVMProject(vmID: vm.id, vmName: vm.name)
                                }
                            }
                        } label: {
                            addProjectCapsule(theme, hovered: hovered)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
        } else {
            let pinned = sessions.pinnedSessions
            if !pinned.isEmpty {
                sectionLabel("Pinned", theme)
                VStack(spacing: 2) {
                    ForEach(pinned) { session in
                        PinnedRow(session: session)
                    }
                }
                .padding(EdgeInsets(top: 2, leading: 8, bottom: 6, trailing: 8))
            }
            Hoverable { rowHovered in
                HStack(spacing: 0) {
                    Text("PROJECTS")
                        .font(.system(size: 11, weight: .semibold))
                        .kerning(0.6)
                        .foregroundStyle(theme.t3)
                    Spacer()
                    AddProjectControl()
                        .opacity(rowHovered ? 1 : 0)
                }
                .padding(EdgeInsets(top: 4, leading: 16, bottom: 2, trailing: 12))
                .contentShape(Rectangle())
            }
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(store.projects) { project in
                        ProjectGroup(project: project)
                    }
                }
                .padding(EdgeInsets(top: 2, leading: 8, bottom: 8, trailing: 8))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func addProjectCapsule(_ theme: Theme, hovered: Bool) -> some View {
        Text("Add Project")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.t1)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .glassCapsule(tint: theme.chip, interactive: true)
            .brightness(hovered ? 0.1 : 0)
    }

    private func sectionLabel(_ text: String, _ theme: Theme) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(theme.t3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 4, leading: 16, bottom: 2, trailing: 16))
    }

    // MARK: Settings navigation

    @ViewBuilder
    private func settingsNav(_ theme: Theme) -> some View {
        Hoverable { hovered in
            Button {
                ui.view = .app
            } label: {
                HStack(spacing: 8) {
                    Text("←").font(.system(size: 14))
                    Text("Back to app").font(.system(size: 13))
                }
                .foregroundStyle(hovered ? theme.t1 : theme.t2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        SearchField(placeholder: "Search settings…", shortcutHint: nil)
            .padding(EdgeInsets(top: 6, leading: 12, bottom: 12, trailing: 12))
        sectionLabel("Personal", theme)
        VStack(spacing: 1) {
            ForEach(UIState.SettingsTab.allCases, id: \.self) { tab in
                Hoverable { hovered in
                    Button {
                        ui.settingsTab = tab
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: tab.glyph)
                                .font(.system(size: 11))
                                .foregroundStyle(theme.t2)
                                .frame(width: 16)
                            Text(tab.rawValue)
                                .font(.system(size: 13))
                                .foregroundStyle(theme.t1)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .glassHighlight(
                            ui.settingsTab == tab || hovered,
                            tint: ui.settingsTab == tab ? theme.sel : theme.hover
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
        Spacer()
    }

    // MARK: Footer

    private func footer(_ theme: Theme) -> some View {
        HStack(spacing: 10) {
            Text(String(NSUserName().prefix(1)).uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(
                    LinearGradient(
                        colors: [Color(hex: 0x5b7cfa), Color(hex: 0x8a5bfa)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    in: Circle()
                )
            VStack(alignment: .leading, spacing: 0) {
                Text(NSUserName())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.t1)
                Text(activeCountLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.t3)
            }
            Spacer()
            Hoverable { hovered in
                Button {
                    ui.view = ui.view == .settings ? .app : .settings
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .foregroundStyle(hovered ? theme.t1 : theme.t2)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .overlay(alignment: .top) { settings.theme.sideLine.frame(height: 1) }
    }

    private var activeCountLabel: String {
        if store.projects.isEmpty { return "No projects yet" }
        let n = sessions.runningCount
        return "\(n) active chat\(n == 1 ? "" : "s")"
    }
}

// MARK: - Add-project control

/// The "+" beside the PROJECTS header: a plain add button when there are no
/// VMs, otherwise a menu offering Mac or any VM as the project source.
private struct AddProjectControl: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionManager.self) private var sessions
    @Environment(AppSettings.self) private var settings
    @Environment(VMStore.self) private var vms
    @Environment(UIState.self) private var ui

    var body: some View {
        let theme = settings.theme
        if vms.vms.isEmpty {
            Hoverable { hovered in
                Button {
                    addProjectAndStart(store: store, sessions: sessions)
                } label: { plusIcon(hovered, theme) }
                .buttonStyle(.plain)
                .help("Add project")
            }
        } else {
            Hoverable { hovered in
                Menu {
                    Button("From Mac…") {
                        addProjectAndStart(store: store, sessions: sessions)
                    }
                    Divider()
                    ForEach(vms.vms) { vm in
                        Button("From \(vm.name)…") {
                            ui.presentAddVMProject(vmID: vm.id, vmName: vm.name)
                        }
                    }
                } label: { plusIcon(hovered, theme) }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    private func plusIcon(_ hovered: Bool, _ theme: Theme) -> some View {
        Image(systemName: "plus")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(hovered ? theme.t1 : theme.t3)
            .frame(width: 20, height: 16)
            .contentShape(Rectangle())
    }
}

// MARK: - Search field

struct SearchField: View {
    let placeholder: String
    let shortcutHint: String?
    @Environment(AppSettings.self) private var settings
    @Environment(UIState.self) private var ui

    var body: some View {
        @Bindable var ui = ui
        let theme = settings.theme
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
            // Note: @FocusState/.focused here aborts window creation on the
            // macOS 27 beta; Cmd-K focuses via first responder instead.
            TextField(placeholder, text: $ui.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(theme.t1)
            if let hint = shortcutHint, ui.searchText.isEmpty {
                Text(hint)
                    .font(.system(size: 11))
                    .opacity(0.75)
            }
        }
        .foregroundStyle(theme.t3)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // Plain translucent fill, not glass — the glass material's own
        // luminance reads far brighter than the design's field.
        .background(theme.field, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        }
        .onChange(of: ui.searchFieldFocused) { _, wants in
            guard wants else { return }
            ui.searchFieldFocused = false
            DispatchQueue.main.async {
                guard let window = NSApp.keyWindow ?? NSApp.windows.first,
                      let content = window.contentView,
                      let field = Self.firstEditableTextField(in: content)
                else { return }
                window.makeFirstResponder(field)
            }
        }
    }

    private static func firstEditableTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for sub in view.subviews {
            if let field = firstEditableTextField(in: sub) { return field }
        }
        return nil
    }
}

// MARK: - Pinned row

private struct PinnedRow: View {
    let session: Session
    @Environment(ProjectStore.self) private var store
    @Environment(SessionManager.self) private var sessions
    @Environment(AppSettings.self) private var settings
    @Environment(VMStore.self) private var vms

    private var contextLabel: String {
        switch session.target {
        case .project(let id): store.projects.first(where: { $0.id == id })?.name ?? ""
        case .mac: "Mac"
        case .vm(let id): vms.vm(id)?.name ?? ""
        }
    }

    var body: some View {
        let theme = settings.theme
        let selected = sessions.selectedSessionID == session.id
        Hoverable { hovered in
            Button {
                sessions.selectedSessionID = session.id
            } label: {
                HStack(spacing: 8) {
                    Text("★")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.star)
                    Text(session.title)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.t1)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(contextLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.t3)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5.5)
                .glassHighlight(selected || hovered, tint: selected ? theme.sel : theme.hover)
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(theme.selRing, lineWidth: 1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .contextMenu { SessionContextMenu(session: session) }
    }
}

// MARK: - Environment group

private struct EnvironmentGroup: View {
    enum Kind { case mac; case vm(VM) }
    let kind: Kind
    @State private var open = true
    @Environment(SessionManager.self) private var sessions
    @Environment(AppSettings.self) private var settings
    @Environment(UIState.self) private var ui

    var body: some View {
        let theme = settings.theme
        VStack(spacing: 2) {
            environmentRow(theme)
            if open {
                VStack(spacing: 2) {
                    ForEach(filteredSessions) { session in
                        ChatRow(session: session)
                    }
                }
                .padding(.leading, 14)
            }
        }
    }

    private var name: String {
        switch kind {
        case .mac: "Mac"
        case .vm(let vm): vm.name
        }
    }

    private var icon: String {
        switch kind {
        case .mac: "desktopcomputer"
        case .vm: "square.grid.2x2"
        }
    }

    private var envSessions: [Session] {
        switch kind {
        case .mac: sessions.macSessions
        case .vm(let vm): sessions.sessions(inVM: vm.id)
        }
    }

    private var filteredSessions: [Session] {
        let query = ui.searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return envSessions }
        return envSessions.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private func startChat() {
        switch kind {
        case .mac: Task { await sessions.startMacSession() }
        case .vm(let vm): Task { await sessions.startVMSession(vmID: vm.id) }
        }
    }

    private var desktopVM: VM? {
        if case .vm(let vm) = kind, vm.desktopEnabled { return vm }
        return nil
    }

    private func environmentRow(_ theme: Theme) -> some View {
        Hoverable { hovered in
            let row = HStack(spacing: 7) {
                Text(open ? "▾" : "▸")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.t3)
                    .frame(width: 10)
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.accentSoft)
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.t1)
                    .lineLimit(1)
                    .frame(minWidth: 56, maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 4)
                stateChip
                Hoverable { plusHovered in
                    Button {
                        startChat()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(plusHovered ? theme.t1 : theme.t3)
                            .frame(width: 20, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("New chat")
                }
                .opacity(hovered ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5.5)
            .glassHighlight(hovered, tint: theme.hover)
            .contentShape(Rectangle())
            .onTapGesture { open.toggle() }

            if let vm = desktopVM {
                row.contextMenu {
                    Button("Show Desktop") { ui.view = .desktop(vm.id) }
                        .disabled(vm.state != .ready)
                }
            } else {
                row
            }
        }
    }

    @ViewBuilder
    private var stateChip: some View {
        if case .vm(let vm) = kind {
            switch vm.state {
            case .starting, .provisioning, .downloading:
                SpinnerView()
            default:
                Text(vm.chipLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(settings.theme.accentSoft)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color(hex: 0x7a9bff, alpha: 0.16), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color(hex: 0x7a9bff, alpha: 0.22), lineWidth: 1)
                    }
            }
        }
    }
}

// MARK: - Project group

private struct ProjectGroup: View {
    let project: Project
    @State private var open = true
    @Environment(ProjectStore.self) private var store
    @Environment(SessionManager.self) private var sessions
    @Environment(AppSettings.self) private var settings
    @Environment(VMStore.self) private var vms
    @Environment(UIState.self) private var ui

    var body: some View {
        let theme = settings.theme
        VStack(spacing: 2) {
            projectRow(theme)
            hostMirrorSuggestionRow(theme)
            projectStatus(theme)
            if open {
                VStack(spacing: 2) {
                    ForEach(filteredSessions) { session in
                        ChatRow(session: session)
                    }
                }
                .padding(.leading, 14)
            }
        }
    }

    private var filteredSessions: [Session] {
        let all = sessions.sessions(in: project)
        let query = ui.searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private func projectRow(_ theme: Theme) -> some View {
        let hasImportError = attachment?.state == .error
        return Hoverable { hovered in
            HStack(spacing: 7) {
                Text(open ? "▾" : "▸")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.t3)
                    .frame(width: 10)
                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.folderBlue)
                Text(project.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.t1)
                    .lineLimit(1)
                    .frame(minWidth: 56, maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 4)
                vmBadge
                Hoverable { menuHovered in
                    Menu {
                        ProjectContextMenu(project: project)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(menuHovered ? theme.t1 : theme.t3)
                            .frame(width: 20, height: 16)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .opacity(hovered ? 1 : 0)
                Hoverable { plusHovered in
                    Button {
                        Task { await sessions.startSession(in: project) }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(plusHovered ? theme.t1 : theme.t3)
                            .frame(width: 20, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("New chat")
                }
                .opacity(hovered ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5.5)
            .background {
                if hasImportError {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color(hex: 0xff8a6e, alpha: 0.08))
                }
            }
            .glassHighlight(hovered, tint: theme.hover)
            .contentShape(Rectangle())
            .onTapGesture { open.toggle() }
            .contextMenu {
                ProjectContextMenu(project: project)
            }
        }
    }

    private var attachment: (
        vm: VM,
        state: ProjectVMState,
        importProgress: Double,
        guestPath: String
    )? {
        vms.attachment(for: project.id)
    }

    @ViewBuilder
    private func hostMirrorSuggestionRow(_ theme: Theme) -> some View {
        let suggestions = vms.hostMirrorSuggestions.filter {
            attachment?.vm.id == $0.vmID
        }
        VStack(spacing: 1) {
            ForEach(suggestions, id: \.self) { suggestion in
                HStack(spacing: 6) {
                    Circle()
                        .fill(theme.accent)
                        .frame(width: 6, height: 6)

                    HStack(spacing: 0) {
                        Text("Mac port ")
                        Text(String(suggestion.port))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.t1)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(theme.t2)

                    Button("Forward") {
                        vms.acceptHostMirrorSuggestion(vmID: suggestion.vmID, port: suggestion.port)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.accent)

                    Button("Dismiss") {
                        vms.dismissHostMirrorSuggestion(vmID: suggestion.vmID, port: suggestion.port)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.t3)
                }
                .padding(EdgeInsets(top: 2, leading: 27, bottom: 4, trailing: 10))
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private func projectStatus(_ theme: Theme) -> some View {
        if let attachment {
            switch attachment.state {
            case .importing:
                transferProgress(
                    label: "Importing into \(attachment.vm.name)…",
                    progress: attachment.importProgress,
                    theme: theme
                )
            case .settingUp:
                if attachment.vm.state == .downloading {
                    transferProgress(
                        label: "Downloading VM image…",
                        progress: attachment.vm.downloadProgress,
                        theme: theme
                    )
                } else {
                    transferProgress(
                        label: "Setting up \(attachment.vm.name)…",
                        progress: provisioningProgress(for: attachment.vm),
                        theme: theme
                    )
                }
            case .starting:
                Text("VM starting…")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: 2, leading: 27, bottom: 4, trailing: 10))
            case .error:
                HStack(spacing: 0) {
                    Text("Import failed · ")
                        .foregroundStyle(theme.orange)
                    Button("Retry") {
                        Task { await vms.importProject(project) }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accent)
                    .underline()
                }
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 2, leading: 27, bottom: 4, trailing: 10))
            case .ready:
                EmptyView()
            }
        }
    }

    private func transferProgress(label: String, progress: Double, theme: Theme) -> some View {
        let percent = min(max(progress, 0), 100)
        return VStack(spacing: 3) {
            HStack(spacing: 8) {
                Text(label)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(Int(percent.rounded()))%")
            }
            .font(.system(size: 11))
            .foregroundStyle(theme.t3)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(theme.field)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(theme.accent)
                        .frame(width: proxy.size.width * percent / 100)
                }
            }
            .frame(height: 3)
        }
        .padding(EdgeInsets(top: 2, leading: 27, bottom: 4, trailing: 10))
    }

    private func provisioningProgress(for vm: VM) -> Double {
        guard !vm.phases.isEmpty else { return 0 }
        let completed = vm.phases.count { $0.state == .done }
        return Double(completed) / Double(vm.phases.count) * 100
    }

    /// The static "VM" chip, shared by ready attachments and VM-only projects.
    private var vmChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 8))
            Text("VM")
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(settings.theme.accentSoft)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Color(hex: 0x7a9bff, alpha: 0.16), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(hex: 0x7a9bff, alpha: 0.22), lineWidth: 1)
        }
    }

    /// VM state badge driven by the operational VMStore.
    @ViewBuilder
    private var vmBadge: some View {
        if project.isVMOnly {
            vmChip.help(
                project.vmOrigin.flatMap { vms.vm($0.vmID) }
                    .map { "Running in \($0.name)" } ?? "VM project"
            )
        } else if let attachment {
            switch attachment.state {
            case .ready:
                vmChip.help(
                    attachment.vm.state == .stopped
                        ? "Stopped — projects stay imported"
                        : "Running in \(attachment.vm.name)"
                )
            case .starting, .importing, .settingUp:
                SpinnerView()
            case .error:
                Text("⚠")
                    .font(.system(size: 11))
                    .foregroundStyle(settings.theme.orange)
            }
        }
    }
}

// MARK: - Chat row

private struct ChatRow: View {
    let session: Session
    @Environment(SessionManager.self) private var sessions
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let theme = settings.theme
        let selected = sessions.selectedSessionID == session.id
        let ended = sessions.isEnded(session.id)
        Hoverable { hovered in
            Button {
                sessions.selectedSessionID = session.id
            } label: {
                HStack(spacing: 8) {
                    Group {
                        switch sessions.activity(for: session.id) {
                        case .working:
                            SpinnerView()
                        case .finished:
                            Circle().fill(theme.green).frame(width: 6, height: 6)
                        case .idle:
                            Circle()
                                .fill(Color(hex: 0x969eaf, alpha: ended ? 0.25 : 0.45))
                                .frame(width: 6, height: 6)
                        }
                    }
                    .frame(width: 10, height: 10)
                    Text(session.title)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.t1)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(session.timeLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.t3)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5.5)
                .glassHighlight(selected || hovered, tint: selected ? theme.sel : theme.hover)
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(theme.selRing, lineWidth: 1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .contextMenu { SessionContextMenu(session: session) }
    }
}

// MARK: - Spinner

/// The design's 9px spinning ring (faint track, bright accent arc).
struct SpinnerView: View {
    @Environment(AppSettings.self) private var settings
    @State private var spinning = false

    var body: some View {
        let theme = settings.theme
        return ZStack {
            Circle()
                .stroke(theme.accent.opacity(0.25), lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(theme.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(.linear(duration: 0.7).repeatForever(autoreverses: false), value: spinning)
        }
        .frame(width: 9, height: 9)
        .onAppear { spinning = true }
    }
}

// MARK: - Context menus

struct SessionContextMenu: View {
    let session: Session
    @Environment(SessionManager.self) private var sessions

    var body: some View {
        Button(session.pinned ? "Unpin" : "Pin") {
            sessions.togglePin(session.id)
        }
        Button("Close Chat", role: .destructive) {
            sessions.closeSession(session.id)
        }
    }
}

struct ProjectContextMenu: View {
    let project: Project
    @Environment(ProjectStore.self) private var store
    @Environment(SessionManager.self) private var sessions
    @Environment(VMStore.self) private var vms
    @Environment(UIState.self) private var ui

    var body: some View {
        Button("New Chat") {
            Task { await sessions.startSession(in: project) }
        }

        if !project.isVMOnly {
        if let attachment = vms.attachment(for: project.id) {
            Button("Edit Import Filters") {
                editImportFilters()
            }
            Button("Re-import from Mac") {
                ui.presentTransferPreview(for: project, direction: .importFromMac)
            }
            Button("Export to Mac") {
                ui.presentTransferPreview(for: project, direction: .exportToMac)
            }
            Menu("Share Port") {
                ForEach(vms.reAddCandidates(for: attachment.vm.id), id: \.self) { port in
                    Button(String(port)) {
                        var ports = vms.hostMirrorPorts(for: attachment.vm.id)
                        if !ports.contains(port) {
                            ports.append(port)
                        }
                        vms.setHostMirrorPorts(vmID: attachment.vm.id, ports)
                    }
                }
            }
            Menu("Move to VM") {
                ForEach(vms.vms) { vm in
                    Button(vmPickerLabel(vm)) {
                        Task {
                            await vms.detach(project: project, deleteGuestCopy: false)
                            guard vms.attachment(for: project.id) == nil else { return }
                            await vms.attach(project: project, to: vm.id)
                        }
                    }
                }
                Divider()
                Button("New VM…") {
                    ui.presentNewVM(
                        defaultName: "dev-vm-\(vms.vms.count + 1)",
                        attaching: project
                    )
                }
            }
            Divider()
            Menu("Disable VM") {
                Button("Keep copy on VM") {
                    Task { await vms.detach(project: project, deleteGuestCopy: false) }
                }
                Button("Delete copy", role: .destructive) {
                    Task { await vms.detach(project: project, deleteGuestCopy: true) }
                }
            }
        } else {
            Menu("Enable VM") {
                ForEach(vms.vms) { vm in
                    Button(vmPickerLabel(vm)) {
                        Task { await vms.attach(project: project, to: vm.id) }
                    }
                }
                Divider()
                Button("New VM…") {
                    ui.presentNewVM(
                        defaultName: "dev-vm-\(vms.vms.count + 1)",
                        attaching: project
                    )
                }
            }
        }
        }

        Divider()
        if let url = project.url {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        Button("Remove Project", role: .destructive) {
            Task {
                if vms.attachment(for: project.id) != nil {
                    await vms.detach(project: project, deleteGuestCopy: false)
                }
                guard vms.attachment(for: project.id) == nil else { return }
                sessions.closeSessions(in: project)
                store.removeProject(project)
            }
        }
    }

    private func vmPickerLabel(_ vm: VM) -> String {
        let state = vm.state == .ready ? "running" : vm.state.rawValue
        return "\(vm.name) — \(state)"
    }

    private func editImportFilters() {
        guard let projectURL = project.url else { return }
        let url = projectURL.appendingPathComponent(".vetroignore")
        if !FileManager.default.fileExists(atPath: url.path) {
            guard (try? "# rsync exclude patterns, one per line\n".write(
                to: url,
                atomically: true,
                encoding: .utf8
            )) != nil else {
                return
            }
        }
        NSWorkspace.shared.open(url)
    }
}
