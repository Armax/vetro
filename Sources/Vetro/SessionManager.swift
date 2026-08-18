import AppKit
import Foundation
import GhosttyKit
import Observation

enum VMTerminalLaunchDecision: Sendable {
    case local
    case remote(command: String)
    case unavailable(message: String)
}

/// Everything a split needs to open another leaf in an existing session.
@MainActor
private struct SplitLaunch {
    let workingDirectory: String
    let resolve: (UUID) async -> VMTerminalLaunchDecision
}

/// Owns all live terminal sessions and the selection state.
@MainActor
@Observable
final class SessionManager {
    private(set) var sessions: [Session] = []
    var selectedSessionID: UUID? {
        didSet {
            // Opening a chat marks it read: green goes back to gray.
            if let id = selectedSessionID, activities[id] == .finished {
                setActivity(.idle, for: id)
            }
            if let id = selectedSessionID {
                lastActivatedAt[id] = .now
            }
        }
    }

    private var trees: [UUID: SplitTree] = [:]
    /// Per-session launch context so a split re-resolves the same target
    /// (same cwd, same VM SSH shell) with the session's shared VETRO_SESSION_ID.
    @ObservationIgnored private var splitLaunches: [UUID: SplitLaunch] = [:]
    private var endedSessions: Set<UUID> = []
    private var bootingSessions: Set<UUID> = []
    private(set) var activities: [UUID: ChatActivity] = [:]
    @ObservationIgnored private var shellPIDs: [UUID: pid_t] = [:]
    /// VM-backed sessions: host `ps` cannot see the guest agent, so
    /// they are excluded from the shell-PID heuristic.
    @ObservationIgnored private var vmBacked: Set<UUID> = []
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var lastHarness: [UUID: AgentHarness] = [:]
    @ObservationIgnored private var titleActive: [UUID: Bool] = [:]
    /// Last raw title seen per session: ghostty forwards one SET_TITLE per
    /// OSC write with no dedup, and claude re-emits its (glyph-bearing)
    /// title on every frame — only *changes* count as activity.
    @ObservationIgnored private var lastRawTitle: [UUID: String] = [:]
    /// When a glyph-bearing title last arrived. Codex animates its title
    /// glyph (continuous updates) so this stays fresh while working; Claude
    /// sets ✳ once at turn start and lets it go stale, so a stale glyph
    /// falls back to CPU detection.
    @ObservationIgnored private var glyphSeenAt: [UUID: Date] = [:]
    @ObservationIgnored private var quietTicks: [UUID: Int] = [:]
    @ObservationIgnored private var activeTicks: [UUID: Int] = [:]
    /// Sessions with lifecycle hooks reporting: hooks are authoritative;
    /// heuristics stop driving their state.
    @ObservationIgnored private var hookManaged: Set<UUID> = []
    @ObservationIgnored private var lastActivatedAt: [UUID: Date] = [:]

    private func glyphFresh(_ id: UUID) -> Bool {
        glyphSeenAt[id].map { Date.now.timeIntervalSince($0) < 3 } ?? false
    }

    init() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollAgents() }
        }
    }

    /// Set by the UI: starts a new chat in the given target
    /// (Cmd+N/Cmd+T pressed inside a terminal).
    @ObservationIgnored var newSessionRequest: ((SessionTarget) -> Void)?

    /// Target of the currently selected session, used by Cmd-N.
    var selectedTarget: SessionTarget? {
        selectedSessionID.flatMap { session($0)?.target }
    }

    /// Font size for newly created terminal surfaces (kept in sync with settings).
    @ObservationIgnored var terminalFontSize: Int = 13

    /// Classifies and prepares terminal launch without conflating an unavailable
    /// VM attachment with a genuinely local project.
    @ObservationIgnored var vmTerminalLaunchProvider:
        (@MainActor (Project, UUID, String?) async -> VMTerminalLaunchDecision)?

    /// Resolves the launch for a project-free VM environment chat.
    @ObservationIgnored var vmEnvironmentLaunchProvider:
        (@MainActor (UUID, UUID) async -> VMTerminalLaunchDecision)?

    /// Called when a terminal session closes or its process ends.
    @ObservationIgnored var sessionDidEnd: ((UUID) -> Void)?

    /// Project of the currently selected session, used by Cmd-N.
    var selectedProjectID: UUID? {
        guard let id = selectedSessionID else { return nil }
        return session(id)?.projectID
    }

    func session(_ id: UUID) -> Session? {
        sessions.first { $0.id == id }
    }

    func sessions(in project: Project) -> [Session] {
        sessions.filter { $0.projectID == project.id }
    }

    func sessions(inVM vmID: UUID) -> [Session] {
        sessions.filter { $0.vmID == vmID }
    }

    var macSessions: [Session] {
        sessions.filter { $0.target == .mac }
    }

    func surface(for id: UUID) -> TerminalSurface? {
        trees[id]?.rootSurface
    }

    func tree(for id: UUID) -> SplitTree? {
        trees[id]
    }

    func isBooting(_ id: UUID) -> Bool {
        bootingSessions.contains(id)
    }

    func isEnded(_ id: UUID) -> Bool {
        endedSessions.contains(id)
    }

    func mostRecentlyActivatedProject(in projectIDs: Set<UUID>) -> UUID? {
        sessions
            .filter { ($0.projectID.map(projectIDs.contains) ?? false) && !isEnded($0.id) }
            .max { lhs, rhs in
                let left = lastActivatedAt[lhs.id] ?? lhs.createdAt
                let right = lastActivatedAt[rhs.id] ?? rhs.createdAt
                return left < right
            }?
            .projectID
    }

    func activity(for id: UUID) -> ChatActivity {
        activities[id] ?? .idle
    }

    // MARK: - Agent activity

    private func pollAgents() {
        let roots = shellPIDs
        guard !roots.isEmpty else { return }
        Task.detached(priority: .utility) {
            let scan = ProcessScan.take()
            let found = roots.mapValues { scan.agent(underShell: $0) }
            await MainActor.run { [weak self] in self?.applyAgentScan(found) }
        }
    }

    private func applyAgentScan(_ found: [UUID: AgentPresence?]) {
        for (id, presence) in found {
            guard sessions.contains(where: { $0.id == id }) else { continue }
            let current = activities[id] ?? .idle
            guard let presence else {
                quietTicks[id] = 0
                if case .working = current {
                    setActivity(id == selectedSessionID ? .idle : .finished, for: id)
                    notifyFinished(id)
                }
                lastHarness[id] = nil
                continue
            }
            lastHarness[id] = presence.harness

            // Hooks are authoritative once seen; the scan only provides
            // harness identity (above, plus correcting a mislabeled turn —
            // hook events cannot always name the harness) and the
            // agent-exited fallback.
            if hookManaged.contains(id) {
                if case let .working(active) = current, active != presence.harness {
                    setActivity(.working(presence.harness), for: id)
                }
                continue
            }

            // Heuristic fallback: a live (recently refreshed) title glyph, or
            // sustained CPU burn in the shell subtree (grok idles at ~3%, so
            // the bar is 5% and entry needs two consecutive active ticks to
            // ignore CLI startup bursts).
            let glyph = glyphFresh(id)
            let active = glyph || presence.maxCPU >= 5.0

            if active {
                quietTicks[id] = 0
                let ticks = (activeTicks[id] ?? 0) + 1
                activeTicks[id] = ticks
                // A bell already marked it finished-unread; keep that sticky
                // until the chat is opened.
                if current == .finished && id != selectedSessionID { continue }
                if glyph || ticks >= 2 {
                    setActivity(.working(presence.harness), for: id)
                }
            } else {
                activeTicks[id] = 0
                let quiet = (quietTicks[id] ?? 0) + 1
                quietTicks[id] = quiet
                // A few quiet ticks before ending: network stalls look idle.
                if case .working = current, quiet >= 3 {
                    setActivity(id == selectedSessionID ? .idle : .finished, for: id)
                    notifyFinished(id)
                }
            }
        }
    }

    /// Bell / OSC notification from the terminal: the agent finished a task.
    private func markAttention(_ id: UUID) {
        guard id != selectedSessionID else { return }
        setActivity(.finished, for: id)
    }

    /// Lifecycle hook event from a harness (via HookServer).
    func handleHookEvent(
        sessionID: UUID?,
        event: String,
        payload: String,
        harnessName: String? = nil,
        harnessPID: pid_t? = nil
    ) {
        let claimed = harnessName.flatMap { AgentHarness.match(processName: $0) }
        if let sessionID, sessions.contains(where: { $0.id == sessionID }) {
            applyHookEvent(to: [sessionID], claimed: claimed, event: event, payload: payload)
            return
        }
        if let harnessPID {
            // v2 host script without a session id (env-sanitizing runtime):
            // attribute by process ancestry. A harness running outside a
            // Vetro terminal matches no shell subtree and is dropped.
            let roots = shellPIDs
            guard !roots.isEmpty else { return }
            Task.detached(priority: .utility) {
                let scan = ProcessScan.take()
                let owners = roots.compactMap {
                    scan.contains(harnessPID, underShell: $0.value) ? $0.key : nil
                }
                await MainActor.run { [weak self] in
                    self?.applyHookEvent(to: owners, claimed: claimed, event: event, payload: payload)
                }
            }
            return
        }
        applyHookEvent(to: attributeByPayload(payload), claimed: claimed, event: event, payload: payload)
    }

    private func applyHookEvent(to targets: [UUID], claimed: AgentHarness?, event: String, payload: String) {
        for id in targets {
            hookManaged.insert(id)
            switch event {
            case "prompt-submit":
                if let claimed { lastHarness[id] = claimed }
                setActivity(.working(claimed ?? lastHarness[id] ?? .claude), for: id)
            case "stop", "session-end":
                if case .working = activities[id] ?? .idle {
                    setActivity(id == selectedSessionID ? .idle : .finished, for: id)
                    notifyFinished(id)
                }
            case "notification":
                markAttention(id)
                AgentNotifier.shared.notify(
                    sessionID: id,
                    title: session(id)?.title ?? "Agent",
                    body: payloadField(payload, "message") ?? "Needs your input"
                )
            default:
                break
            }
        }
    }

    /// Guest hook lines carry no harness pid, and some guest runtimes strip
    /// the session id: attribute by the payload's cwd, but only to VM-backed
    /// sessions — local events always carry a harness pid (v2 scripts), so a
    /// cwd match against host paths would capture agents Vetro doesn't own.
    /// VM sessions report the guest workspace path, not the host project path.
    private func attributeByPayload(_ payload: String) -> [UUID] {
        guard let cwd = payloadField(payload, "cwd") else { return [] }
        return sessions.compactMap { session in
            guard vmBacked.contains(session.id),
                  let root = session.projectID.flatMap({ guestPathProvider?($0) }),
                  cwd == root || cwd.hasPrefix(root + "/")
            else { return nil }
            return session.id
        }
    }

    private func payloadField(_ payload: String, _ key: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj[key] as? String
    }

    /// Set by the UI: resolves a project ID to its filesystem path.
    @ObservationIgnored var projectPathProvider: ((UUID) -> String?)?

    /// Set by the UI: resolves a project ID to its VM guest workspace path.
    @ObservationIgnored var guestPathProvider: ((UUID) -> String?)?

    /// A working turn ended (spinner stopped): tell the user if they're away.
    private func notifyFinished(_ id: UUID) {
        guard let session = session(id) else { return }
        let harness = lastHarness[id]?.displayName ?? "Agent"
        AgentNotifier.shared.notify(
            sessionID: id,
            title: "\(harness) finished — \(session.title)",
            body: "Waiting for your input."
        )
    }

    private func captureShellPID(for id: UUID, excluding before: Set<pid_t>) {
        Task { @MainActor [weak self] in
            for _ in 0..<20 {
                guard let self else { return }
                let known = Set(self.shellPIDs.values)
                if let pid = directChildPIDs().subtracting(before).subtracting(known).first {
                    self.shellPIDs[id] = pid
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    var runningCount: Int {
        sessions.count { !endedSessions.contains($0.id) }
    }

    var pinnedSessions: [Session] {
        sessions.filter(\.pinned)
    }

    func togglePin(_ id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].pinned.toggle()
    }

    @discardableResult
    func startSession(
        in project: Project,
        remoteCommand: String? = nil,
        title: String? = nil
    ) async -> Session? {
        await start(
            target: .project(project.id),
            count: sessions(in: project).count,
            title: title,
            workingDirectory: project.url?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
        ) { sessionID in
            await self.vmTerminalLaunchProvider?(project, sessionID, remoteCommand) ?? .local
        }
    }

    @discardableResult
    func startMacSession(title: String? = nil) async -> Session? {
        await start(
            target: .mac,
            count: macSessions.count,
            title: title,
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        ) { _ in .local }
    }

    @discardableResult
    func startVMSession(vmID: UUID, title: String? = nil) async -> Session? {
        await start(
            target: .vm(vmID),
            count: sessions(inVM: vmID).count,
            title: title,
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        ) { sessionID in
            await self.vmEnvironmentLaunchProvider?(vmID, sessionID)
                ?? .unavailable(message: "VM environment unavailable.")
        }
    }

    @discardableResult
    private func start(
        target: SessionTarget,
        count: Int,
        title: String?,
        workingDirectory: String,
        resolveLaunch: @escaping (UUID) async -> VMTerminalLaunchDecision
    ) async -> Session? {
        let sessionID = UUID()
        // Publish the session before the launch await so the chat pane can
        // show a boot placeholder while a stopped VM comes up.
        let session = Session(
            id: sessionID,
            target: target,
            title: title ?? "Chat \(count + 1)"
        )
        sessions.append(session)
        bootingSessions.insert(sessionID)
        selectedSessionID = sessionID
        defer { bootingSessions.remove(sessionID) }

        let launch = await resolveLaunch(sessionID)
        let command: String?
        switch launch {
        case .local:
            command = nil
        case let .remote(remoteCommand):
            command = remoteCommand
        case let .unavailable(message):
            removePlaceholderSession(sessionID)
            let alert = NSAlert()
            alert.messageText = "VM unavailable"
            alert.informativeText = message
            alert.runModal()
            return nil
        }

        do {
            let childrenBefore = directChildPIDs()
            let surface = try makeSurface(
                sessionID: session.id,
                workingDirectory: workingDirectory,
                command: command,
                context: GHOSTTY_SURFACE_CONTEXT_WINDOW
            )
            let tree = SplitTree(surface: surface)
            bindFocus(surface, in: tree)
            trees[session.id] = tree
            splitLaunches[session.id] = SplitLaunch(
                workingDirectory: workingDirectory,
                resolve: resolveLaunch
            )
            if command != nil {
                vmBacked.insert(session.id)
            } else {
                captureShellPID(for: session.id, excluding: childrenBefore)
            }
            return session
        } catch {
            removePlaceholderSession(sessionID)
            NSAlert(error: error).runModal()
            return nil
        }
    }

    private func makeSurface(
        sessionID: UUID,
        workingDirectory: String,
        command: String?,
        context: ghostty_surface_context_e
    ) throws -> TerminalSurface {
        try TerminalSurface(
            workingDirectory: workingDirectory,
            command: command,
            fontSize: terminalFontSize,
            sessionID: sessionID,
            context: context
        ) { [weak self] surface, event in
            self?.handle(event, from: surface, for: sessionID)
        }
    }

    /// Clicking / focusing a leaf updates the tree's focus.
    private func bindFocus(_ surface: TerminalSurface, in tree: SplitTree) {
        surface.onFocused = { [weak tree, weak surface] in
            guard let tree, let surface, let node = tree.leaf(for: surface) else { return }
            tree.focused = node
        }
    }

    /// Opens another leaf in an existing session, re-resolving the launch so a
    /// VM split becomes a second independent SSH shell into the same VM.
    private func createSplit(
        in id: UUID,
        from origin: TerminalSurface,
        direction: ghostty_action_split_direction_e
    ) async {
        guard trees[id]?.leaf(for: origin) != nil,
              let launch = splitLaunches[id]
        else { return }

        let command: String?
        switch await launch.resolve(id) {
        case .local:
            command = nil
        case let .remote(remoteCommand):
            command = remoteCommand
        case let .unavailable(message):
            let alert = NSAlert()
            alert.messageText = "VM unavailable"
            alert.informativeText = message
            alert.runModal()
            return
        }

        // The await above yields; re-check the tree and origin still exist.
        guard let tree = trees[id], let node = tree.leaf(for: origin) else { return }
        do {
            let surface = try makeSurface(
                sessionID: id,
                workingDirectory: launch.workingDirectory,
                command: command,
                context: GHOSTTY_SURFACE_CONTEXT_SPLIT
            )
            bindFocus(surface, in: tree)
            tree.split(node, direction: direction, newSurface: surface)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Menu / toolbar entry point: split the selected session's focused leaf.
    func splitFocused(in id: UUID, direction: ghostty_action_split_direction_e) {
        guard let tree = trees[id],
              let origin = (tree.zoomed ?? tree.focused).surface
        else { return }
        Task { await createSplit(in: id, from: origin, direction: direction) }
    }

    /// Cmd+W in a terminal: collapse the focused leaf, or close the whole
    /// session when it is the last one. Never marks the session ended while
    /// other leaves are alive (the VM ref-count depends on it).
    private func closeSplit(_ surface: TerminalSurface, in id: UUID) {
        guard let tree = trees[id], let node = tree.leaf(for: surface) else { return }
        if tree.leaves.count > 1 {
            surface.close()
            tree.close(node)
        } else {
            closeSession(id)
        }
    }

    private func removePlaceholderSession(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        bootingSessions.remove(id)
        if selectedSessionID == id {
            selectedSessionID = sessions.last?.id
        }
    }

    func closeSession(_ id: UUID) {
        sessionDidEnd?(id)
        if let tree = trees[id] {
            for leaf in tree.leaves { leaf.surface?.close() }
        }
        trees[id] = nil
        splitLaunches[id] = nil
        endedSessions.remove(id)
        activities[id] = nil
        shellPIDs[id] = nil
        vmBacked.remove(id)
        lastHarness[id] = nil
        titleActive[id] = nil
        glyphSeenAt[id] = nil
        quietTicks[id] = nil
        activeTicks[id] = nil
        lastRawTitle[id] = nil
        hookManaged.remove(id)
        lastActivatedAt[id] = nil
        sessions.removeAll { $0.id == id }
        if selectedSessionID == id {
            selectedSessionID = sessions.last?.id
        }
    }

    func closeSessions(in project: Project) {
        for session in sessions(in: project) {
            closeSession(session.id)
        }
    }

    private func handle(_ event: TerminalSurface.Event, from surface: TerminalSurface, for id: UUID) {
        switch event {
        case .titleChanged(let raw):
            guard trees[id]?.rootSurface === surface else { return }
            guard lastRawTitle[id] != raw else { return }
            lastRawTitle[id] = raw
            let (title, active) = TitleActivity.parse(raw)
            if let i = sessions.firstIndex(where: { $0.id == id }), !title.isEmpty {
                sessions[i].title = title
            }
            guard !hookManaged.contains(id) else { return }
            let wasActive = titleActive[id] == true
            let wasFresh = glyphFresh(id)
            titleActive[id] = active
            if active {
                glyphSeenAt[id] = .now
                if let harness = lastHarness[id],
                   !(activities[id] == .finished && id != selectedSessionID) {
                    setActivity(.working(harness), for: id)
                }
            } else if wasActive, wasFresh, case .working = activities[id] ?? .idle {
                // A live (animated) glyph disappeared: the turn is over.
                glyphSeenAt[id] = nil
                setActivity(id == selectedSessionID ? .idle : .finished, for: id)
                notifyFinished(id)
            }
        case .processEnded:
            guard let tree = trees[id], let node = tree.leaf(for: surface) else { return }
            if tree.leaves.count > 1 {
                // A non-last leaf's shell exited: collapse just that pane.
                surface.close()
                tree.close(node)
            } else {
                // Last leaf: keep today's behavior — mark ended, surface stays.
                endedSessions.insert(id)
                sessionDidEnd?(id)
            }
        case .attention:
            guard trees[id]?.rootSurface === surface else { return }
            markAttention(id)
        case .notification(let title, let body):
            guard trees[id]?.rootSurface === surface else { return }
            markAttention(id)
            let fallback = session(id)?.title ?? "Agent"
            AgentNotifier.shared.notify(
                sessionID: id,
                title: title.isEmpty ? fallback : title,
                body: body
            )
        case .closeRequested:
            closeSplit(surface, in: id)
        case .newSessionRequested:
            if let target = session(id)?.target {
                newSessionRequest?(target)
            }
        case .splitRequested(let direction):
            Task { await createSplit(in: id, from: surface, direction: direction) }
        case .focusSplit(let goto):
            guard let tree = trees[id], let node = tree.leaf(for: surface),
                  let target = tree.neighbor(of: node, goto: goto) else { return }
            tree.focused = target
            tree.zoomed = nil
        case .resizeSplit(let direction, let amount):
            guard let tree = trees[id], let node = tree.leaf(for: surface) else { return }
            tree.resize(node, direction: direction, amount: amount)
        case .equalizeSplits:
            trees[id]?.equalize()
        case .toggleSplitZoom:
            guard let tree = trees[id], tree.leaves.count > 1,
                  let node = tree.leaf(for: surface) else { return }
            tree.zoomed = (tree.zoomed === node) ? nil : node
            if tree.zoomed != nil { tree.focused = node }
        }
    }

    private func setActivity(_ activity: ChatActivity, for id: UUID) {
        guard activities[id] != activity else { return }
        activities[id] = activity
    }
}
