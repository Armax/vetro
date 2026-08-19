import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionManager.self) private var sessions
    @Environment(AppSettings.self) private var settings
    @Environment(VMStore.self) private var vms
    @Environment(UIState.self) private var ui

    var body: some View {
        @Bindable var ui = ui
        let theme = settings.theme
        HStack(spacing: 0) {
            if settings.sidebarVisible {
                SidebarView()
                    .frame(width: settings.sidebarWidth)
                    .glassPanel(
                        tint: theme.sideBG,
                        enabled: !settings.reduceTransparency,
                        fallback: theme.solidSide
                    )
                    .overlay(alignment: .trailing) {
                        theme.sideLine.frame(width: 1)
                    }
                    .overlay(alignment: .trailing) {
                        PaneResizeHandle(
                            axisSign: 1,
                            width: { settings.sidebarWidth },
                            setWidth: { settings.sidebarWidth = min(max(220, $0), 420) }
                        )
                    }
                    .transition(.move(edge: .leading))
            }

            Group {
                switch ui.view {
                case .settings:
                    SettingsPane()
                case .app:
                    if let sessionID = sessions.selectedSessionID,
                       let session = sessions.session(sessionID) {
                        TerminalPane(session: session)
                            .id(session.id)
                    } else {
                        EmptyMainView()
                    }
                case .desktop(let vmID):
                    DesktopPane(vmID: vmID)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassPanel(
                tint: theme.main,
                enabled: !settings.reduceTransparency,
                fallback: theme.desk
            )
        }
        .background {
            WallpaperView(wallpaper: settings.wallpaper, theme: theme)
        }
        .overlay(alignment: .bottom) {
            if let toast = ui.toast {
                ToastView(message: toast, theme: theme)
                    .padding(.bottom, 36)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: ui.toast)
        .animation(.easeInOut(duration: 0.18), value: settings.sidebarVisible)
        .sheet(item: $ui.newVMRequest) { request in
            NewVMSheet(
                defaultName: request.defaultName,
                attachingProject: request.attachingProject
            )
            .presentationBackground(.clear)
        }
        .sheet(item: $ui.addVMProjectRequest) { request in
            AddVMProjectSheet(vmID: request.vmID, vmName: request.vmName)
                .presentationBackground(.clear)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowConfigurator())
        .frame(minWidth: 900, minHeight: 560)
        .onAppear {
            sessions.terminalFontSize = settings.fontSize
            AgentNotifier.shared.settings = settings
            AgentNotifier.shared.isSessionSelected = { sessions.selectedSessionID == $0 }
            AgentNotifier.shared.selectSession = { id in
                ui.view = .app
                sessions.selectedSessionID = id
            }
            if settings.agentNotifications {
                AgentNotifier.shared.requestAuthorizationIfNeeded()
            }
            let projectPathProvider: (UUID) -> String? = { id in
                store.projects.first(where: { $0.id == id })?.path
            }
            sessions.projectPathProvider = projectPathProvider
            sessions.guestPathProvider = { id in
                store.projects.first(where: { $0.id == id })?.vmOrigin?.guestPath
                    ?? vms.attachments[id]?.guestPath
            }
            sessions.vmTerminalLaunchProvider = { project, sessionID, remoteCommand in
                await vms.prepareTerminalLaunch(
                    for: project,
                    sessionID: sessionID,
                    remoteCommand: remoteCommand
                )
            }
            sessions.vmEnvironmentLaunchProvider = { vmID, sessionID in
                await vms.prepareEnvironmentLaunch(vmID: vmID, sessionID: sessionID)
            }
            vms.sessionLaunchProvider = { project, remoteCommand, title in
                let session = await sessions.startSession(
                    in: project,
                    remoteCommand: remoteCommand,
                    title: title
                )
                return session?.id
            }
            sessions.sessionDidEnd = { sessionID in
                vms.handleSessionEnd(sessionID)
            }
            vms.projectResolver = { id in
                store.projects.first(where: { $0.id == id })
            }
            vms.vmOnlyGuestPathsProvider = { vmID in
                store.projects.compactMap { project in
                    guard let origin = project.vmOrigin, origin.vmID == vmID else { return nil }
                    return origin.guestPath
                }
            }
            vms.errorPresenter = { message in
                ui.showToast(message)
            }
            vms.openSessionsProvider = { projectID in
                sessions.sessions.filter {
                    $0.projectID == projectID && !sessions.isEnded($0.id)
                }.count
            }
            vms.openVMSessionsProvider = { vmID in
                sessions.sessions.filter {
                    $0.vmID == vmID && !sessions.isEnded($0.id)
                }.count
            }
            vms.selectedProjectProvider = { sessions.selectedProjectID }
            vms.recentSessionProjectProvider = { projectIDs in
                sessions.mostRecentlyActivatedProject(in: projectIDs)
            }
            HookServer.shared.onEvent = { sessionID, event, payload, harnessName, harnessPID in
                sessions.handleHookEvent(
                    sessionID: sessionID,
                    event: event,
                    payload: payload,
                    harnessName: harnessName,
                    harnessPID: harnessPID
                )
            }
            vms.hookEventHandler = { sessionID, event, payload in
                HookServer.shared.deliver(sessionID: sessionID, event: event, payload: payload)
            }
            HookServer.shared.start()
            if settings.harnessHooks {
                HookInstaller.installAll()
            }
            sessions.newSessionRequest = { target in
                switch target {
                case .project(let projectID):
                    guard let project = store.projects.first(where: { $0.id == projectID }) else { return }
                    Task { await sessions.startSession(in: project) }
                case .mac:
                    Task { await sessions.startMacSession() }
                case .vm(let vmID):
                    Task { await sessions.startVMSession(vmID: vmID) }
                }
            }
            if let path = ProcessInfo.processInfo.environment["VETRO_OPEN"] {
                let project = store.addProject(at: URL(fileURLWithPath: path))
                Task { await sessions.startSession(in: project) }
            }
        }
        .onChange(of: settings.fontSize) { _, size in
            sessions.terminalFontSize = size
        }
    }
}

// MARK: - Empty main state

struct EmptyMainView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ProjectStore.self) private var store
    @Environment(SessionManager.self) private var sessions

    var body: some View {
        let theme = settings.theme
        VStack(spacing: 8) {
            Text(">_")
                .font(.system(size: 20, design: .monospaced))
                .foregroundStyle(theme.t2)
                .frame(width: 64, height: 52)
                .background(theme.field, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(theme.sideLine, lineWidth: 1)
                }
                .padding(.bottom, 8)

            Text("No Chat Selected")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(theme.t1)

            Text("Add a project folder, then start a chat — a shell opens in that directory.")
                .font(.system(size: 13))
                .foregroundStyle(theme.t3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            Button {
                addProjectAndStart(store: store, sessions: sessions)
            } label: {
                Label("Add Project", systemImage: "folder.badge.plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.accentTxt)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
                    .glassCapsule(tint: theme.accentChip, interactive: true)
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
func addProjectAndStart(store: ProjectStore, sessions: SessionManager) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Add"
    panel.message = "Choose a project folder"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let project = store.addProject(at: url)
    Task { await sessions.startSession(in: project) }
}

// MARK: - Toast

struct ToastView: View {
    let message: String
    let theme: Theme

    var body: some View {
        Text(message)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.t1)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .glassCapsule(tint: theme.menu)
            .overlay {
                Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 15, y: 10)
    }
}
