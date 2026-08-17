import SwiftUI

struct TerminalPane: View {
    let session: Session
    @Environment(ProjectStore.self) private var store
    @Environment(SessionManager.self) private var sessions
    @Environment(AppSettings.self) private var settings
    @Environment(VMStore.self) private var vms
    @State private var showPorts = false
    @State private var git = GitPanelModel()

    private var project: Project? {
        store.projects.first { $0.id == session.projectID }
    }

    private var envVMID: UUID? {
        session.vmID ?? project.flatMap { vms.attachment(for: $0.id)?.vm.id }
    }

    private var vmName: String? {
        if let vmID = session.vmID { return vms.vm(vmID)?.name }
        guard let project, let attachment = vms.attachment(for: project.id),
              attachment.state == .ready
        else { return nil }
        return attachment.vm.name
    }

    private var subtitle: String {
        if let project { return project.displayPath }
        switch session.target {
        case .mac: return "~"
        case .vm(let id): return vms.vm(id)?.name ?? ""
        case .project: return ""
        }
    }

    var body: some View {
        let theme = settings.theme
        GeometryReader { geo in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    toolbar(theme)
                    terminalArea(theme)
                }
                .frame(maxWidth: .infinity)
                if git.isOpen {
                    GitSidePanel(git: git)
                        .frame(width: gitPanelWidth(available: geo.size.width))
                        .overlay(alignment: .leading) {
                            PaneResizeHandle(
                                axisSign: -1,
                                width: { settings.gitPanelWidth },
                                setWidth: { settings.gitPanelWidth = min(max(240, $0), 560) }
                            )
                        }
                        .transition(.move(edge: .trailing))
                }
                GitRail(git: git)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: git.isOpen)
        .task(id: session.id) {
            let session = session
            let vms = vms
            let store = store
            git.configure(
                sourceProvider: {
                    guard let projectID = session.projectID,
                          let project = store.projects.first(where: { $0.id == projectID })
                    else {
                        return session.target == .mac
                            ? HostGitSource(repoPath: NSHomeDirectory())
                            : nil
                    }
                    if let attachment = vms.attachment(for: projectID),
                       attachment.state == .ready
                    {
                        return GuestGitSource(
                            repoPath: attachment.guestPath,
                            projectID: projectID,
                            vms: vms
                        )
                    }
                    return HostGitSource(repoPath: project.path)
                },
                settings: settings
            )
            await git.refreshChanges()
        }
    }

    private func gitPanelWidth(available: CGFloat) -> CGFloat {
        min(max(240, settings.gitPanelWidth), max(240, available * 0.5))
    }

    private func terminalArea(_ theme: Theme) -> some View {
        ZStack {
            if settings.reduceTransparency {
                // Terminal follows the theme now.
                settings.appearance == .light
                    ? Color(hex: 0xf3f5fa)
                    : Color(hex: 0x07090f)
            } else {
                // Plain tint over the shared main glass — one uniform
                // surface across sidebar/toolbar/terminal, per the design.
                theme.term
            }
            if let surface = sessions.surface(for: session.id) {
                SurfaceHost(surface: surface)
            } else if sessions.isBooting(session.id) {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(theme.accentSoft)
                    Text("Booting VM…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.t3)
                }
            }
        }
    }

    // MARK: Toolbar

    private func toolbar(_ theme: Theme) -> some View {
        HStack(spacing: 12) {
            if !settings.sidebarVisible {
                // The sidebar normally hosts the traffic-light gap; keep the
                // reopen button clear of them when it is collapsed.
                Spacer().frame(width: 62)
                Hoverable { hovered in
                    Button {
                        settings.sidebarVisible = true
                    } label: {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 12))
                            .foregroundStyle(hovered ? theme.t1 : theme.t2)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show sidebar")
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.t1)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.t3)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let vmName {
                chip(theme) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 9))
                    Text(vmName).fontWeight(.semibold)
                }
                .foregroundStyle(theme.accentSoft)
            }

            if let branch = project?.gitBranch {
                chip(theme) {
                    Image(systemName: "arrow.trianglehead.branch").font(.system(size: 10))
                    Text(branch)
                }
                .foregroundStyle(theme.t2)
            }

            if session.target != .mac {
                let ended = sessions.isEnded(session.id)
                let statusColor = ended ? Color(hex: 0x969eaf, alpha: 0.7) : theme.green
                let vmID = envVMID
                let portCount = vmID.map {
                    vms.mirrorRows(for: $0).count + vms.sharedHostPorts(for: $0).count
                } ?? 0
                Button {
                    showPorts.toggle()
                } label: {
                    chip(theme, interactive: true) {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text("\(portCount)")
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.t2)
                .popover(isPresented: $showPorts, arrowEdge: .bottom) {
                    ForwardedPortsPopover(vmID: vmID)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(settings.reduceTransparency ? theme.solidToolbar : theme.toolbar)
        .overlay(alignment: .bottom) { theme.sideLine.frame(height: 1) }
    }

    private func chip(
        _ theme: Theme,
        interactive: Bool = false,
        @ViewBuilder content: () -> some View
    ) -> some View {
        // Plain fills, not glass: glassEffect samples the backdrop, and over
        // the opaque navbar the capsules vanish into it.
        HStack(spacing: 6, content: content)
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(theme.chip, in: Capsule())
            .overlay { Capsule().strokeBorder(theme.chipHi, lineWidth: 1) }
    }

}

// MARK: - Forwarded ports

private struct ForwardedPortsPopover: View {
    let vmID: UUID?
    @Environment(AppSettings.self) private var settings
    @Environment(VMStore.self) private var vms

    var body: some View {
        let theme = settings.theme
        let rows = vmID.map { vms.mirrorRows(for: $0) } ?? []
        let sharedPorts = vmID.map { vms.sharedHostPorts(for: $0) } ?? []
        let suggestions = vms.hostMirrorSuggestions.filter { $0.vmID == vmID }

        VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty && sharedPorts.isEmpty && suggestions.isEmpty {
                Text("No forwarded ports")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.t3)
            } else {
                if !rows.isEmpty, let vmID {
                    VStack(spacing: 2) {
                        ForEach(rows, id: \.guest) { row in
                            ForwardedPortRow(
                                vmID: vmID,
                                guest: row.guest,
                                host: row.host,
                                status: row.status,
                                theme: theme
                            )
                        }
                    }
                }

                if !sharedPorts.isEmpty {
                    if !rows.isEmpty {
                        theme.sideLine
                            .frame(height: 1)
                            .padding(.vertical, 8)
                    }
                    VStack(spacing: 2) {
                        ForEach(sharedPorts, id: \.self) { port in
                            HStack(spacing: 8) {
                                Text(String(port))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(theme.t1)
                                Spacer(minLength: 8)
                                Image(systemName: "arrow.down.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(theme.accentSoft)
                                    .frame(width: 16, height: 16)
                                Button("Remove") {
                                    if let vmID {
                                        vms.removeHostMirrorPort(vmID: vmID, port: port)
                                    }
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.t3)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                        }
                    }
                }

                if !suggestions.isEmpty {
                    if !rows.isEmpty || !sharedPorts.isEmpty {
                        theme.sideLine
                            .frame(height: 1)
                            .padding(.vertical, 8)
                    }
                    VStack(spacing: 2) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            HStack(spacing: 8) {
                                Text(String(suggestion.port))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(theme.t1)
                                Spacer(minLength: 8)
                                Button("Forward") {
                                    vms.acceptHostMirrorSuggestion(
                                        vmID: suggestion.vmID,
                                        port: suggestion.port
                                    )
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.accent)
                                Button("Dismiss") {
                                    vms.dismissHostMirrorSuggestion(
                                        vmID: suggestion.vmID,
                                        port: suggestion.port
                                    )
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.t3)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 300, alignment: .leading)
        .glassEffect(
            .regular.tint(theme.menu),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(theme.sideLine, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 22, y: 10)
    }
}

private struct ForwardedPortRow: View {
    let vmID: UUID
    let guest: UInt16
    let host: UInt16
    let status: MirrorPortStatus
    let theme: Theme
    @Environment(ProjectStore.self) private var store
    @Environment(VMStore.self) private var vms
    @State private var showRemap = false

    private var isConflict: Bool { status == .conflict }

    var body: some View {
        HStack(spacing: 8) {
            Text(guest == host ? "\(guest)" : "\(guest) → \(host)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.t1)
                .lineLimit(1)

            Text(isConflict ? "Conflict" : "Active")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isConflict ? Color(hex: 0xffb872) : theme.greenBright)
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .background(
                    isConflict
                        ? Color(hex: 0xffaa5a, alpha: 0.16)
                        : Color(hex: 0x4ade9d, alpha: 0.16),
                    in: Capsule()
                )

            Spacer(minLength: 8)

            if isConflict {
                Button("Remap") { showRemap = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xffb872))
                    .popover(isPresented: $showRemap, arrowEdge: .leading) {
                        RemapPortPopover(vmID: vmID, guestPort: guest, currentHost: host) {
                            showRemap = false
                        }
                    }
            } else {
                Button {
                    vms.openInBrowser(hostPort: host)
                } label: {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.accentSoft)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Button("Exclude") {
                Task { await exclude() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.t3)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func exclude() async {
        let attached = vms.attachedProjects(of: vmID, in: store.projects)
        for project in attached {
            await vms.setPortExcluded(attachmentID: project.id, port: guest, excluded: true)
        }
    }
}

private struct RemapPortPopover: View {
    let vmID: UUID
    let guestPort: UInt16
    let currentHost: UInt16
    let onDone: () -> Void
    @Environment(AppSettings.self) private var settings
    @Environment(VMStore.self) private var vms
    @State private var hostPort = ""
    @State private var isSaving = false

    var body: some View {
        let theme = settings.theme
        VStack(alignment: .leading, spacing: 0) {
            Text("Host port")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.t1)

            HStack(spacing: 8) {
                TextField("\(currentHost)", text: $hostPort)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.t1)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(theme.field, in: RoundedRectangle(cornerRadius: 8))
                    .onSubmit { remap() }

                Button("Remap") { remap() }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.t1)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 5)
                    .background(
                        theme.accent.opacity(isSaving ? 0.12 : 0.22),
                        in: Capsule()
                    )
                    .overlay { Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1) }
                    .buttonStyle(.plain)
                    .disabled(isSaving)
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 220, alignment: .leading)
        .glassEffect(
            .regular.tint(theme.menu),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(theme.sideLine, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 22, y: 10)
        .onAppear {
            hostPort = currentHost == 0 ? "" : String(currentHost)
            isSaving = false
        }
    }

    private func remap() {
        guard !isSaving else { return }
        let trimmed = hostPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.allSatisfy(\.isNumber),
              let parsed = UInt32(trimmed),
              (1...UInt32(UInt16.max)).contains(parsed)
        else {
            return
        }
        isSaving = true
        Task {
            await vms.remapConflict(vmID: vmID, guestPort: guestPort, to: UInt16(parsed))
            onDone()
        }
    }
}
