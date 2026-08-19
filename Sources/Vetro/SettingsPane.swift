import AppKit
import SwiftUI

struct SettingsPane: View {
    @Environment(AppSettings.self) private var settings
    @Environment(UIState.self) private var ui

    var body: some View {
        let theme = settings.theme
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(ui.settingsTab.rawValue)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(theme.t1)
                    .padding(.bottom, 26)

                switch ui.settingsTab {
                case .general: GeneralTab()
                case .appearance: AppearanceTab()
                case .vm: VMTab()
                case .shortcuts: ShortcutsTab()
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(EdgeInsets(top: 36, leading: 44, bottom: 36, trailing: 44))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Shared building blocks

private struct SectionLabel: View {
    let text: String
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(settings.theme.t2)
            .padding(.bottom, 10)
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(spacing: 0, content: { content })
            .background(settings.theme.card, in: RoundedRectangle(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(settings.theme.cardLine, lineWidth: 1)
            }
            .shadow(color: Color(hex: 0x000414, alpha: 0.28), radius: 20, y: 16)
            .padding(.bottom, 28)
    }
}

private struct CardRow<Trailing: View>: View {
    let title: String
    var desc: String?
    var divider = true
    @ViewBuilder let trailing: Trailing
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let theme = settings.theme
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.t1)
                if let desc {
                    Text(desc)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.t3)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
        .overlay(alignment: .bottom) {
            if divider { theme.sideLine.frame(height: 1).padding(.leading, 0) }
        }
    }
}

/// The design's 36×22 toggle.
struct GlassToggle: View {
    @Binding var isOn: Bool
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Theme.toggleOn : settings.theme.field)
                    .frame(width: 36, height: 22)
                Circle()
                    .fill(.white)
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                    .padding(2)
            }
        }
        .buttonStyle(.plain)
    }
}

/// The design's compact − / value / + control.
struct GlassStepper: View {
    let value: String
    let canDecrement: Bool
    let canIncrement: Bool
    let onDecrement: () -> Void
    let onIncrement: () -> Void

    @Environment(AppSettings.self) private var settings

    var body: some View {
        HStack(spacing: 2) {
            stepButton("−", enabled: canDecrement, action: onDecrement)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(settings.theme.t1)
                .frame(minWidth: 58)
            stepButton("+", enabled: canIncrement, action: onIncrement)
        }
        .padding(2)
        .background(settings.theme.field, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.07), lineWidth: 1)
        }
    }

    private func stepButton(
        _ label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Hoverable { hovered in
            Button(action: action) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(enabled ? settings.theme.t1 : settings.theme.t3)
                    .frame(width: 22, height: 20)
                    .background(
                        hovered && enabled ? settings.theme.hover : .clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
        }
    }
}

private struct HostPortAddField: View {
    let onAdd: (UInt16) -> Void
    @Environment(AppSettings.self) private var settings
    @State private var draft = ""

    var body: some View {
        let theme = settings.theme
        HStack(spacing: 8) {
            TextField("Port", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.t1)
                .padding(.horizontal, 10)
                .frame(width: 90, height: 26)
                .background(theme.field, in: RoundedRectangle(cornerRadius: 8))
                .onSubmit { submit() }

            Button("Add") { submit() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.t1)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(theme.chip, in: Capsule())
                .overlay { Capsule().strokeBorder(theme.sideLine, lineWidth: 1) }
        }
    }

    private func submit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.allSatisfy(\.isNumber),
              let parsed = UInt32(trimmed),
              (1...UInt32(UInt16.max)).contains(parsed)
        else {
            return
        }
        onAdd(UInt16(parsed))
        draft = ""
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        SectionLabel(text: "Behavior")
        Card {
            CardRow(
                title: "Show in menu bar",
                desc: "Keep Vetro in the menu bar when the window is closed"
            ) { GlassToggle(isOn: $settings.showInMenuBar) }
            CardRow(
                title: "Restore chats on launch",
                desc: "Reopen a chat in each project from the last session"
            ) { GlassToggle(isOn: $settings.restoreChats) }
            CardRow(
                title: "Prevent sleep while a chat is running",
                desc: "Keep the Mac awake while a command runs"
            ) { GlassToggle(isOn: $settings.preventSleep) }
            CardRow(
                title: "Harness hooks",
                desc: "Precise agent status via claude / codex / grok lifecycle hooks"
            ) { GlassToggle(isOn: $settings.harnessHooks) }
            CardRow(
                title: "Default shell",
                desc: "Shell launched for every new chat",
                divider: false
            ) {
                Text(ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(settings.theme.t1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(settings.theme.field, in: RoundedRectangle(cornerRadius: 9))
            }
        }

        SectionLabel(text: "Notifications")
        Card {
            CardRow(
                title: "Agent notifications",
                desc: "When an agent finishes or needs input in a chat"
            ) { GlassToggle(isOn: $settings.agentNotifications) }
            CardRow(title: "Only when Vetro is in background", divider: false) {
                GlassToggle(isOn: $settings.notifyOnlyInBackground)
            }
            .opacity(settings.agentNotifications ? 1 : 0.4)
            .disabled(!settings.agentNotifications)
        }
        .onChange(of: settings.agentNotifications) { _, on in
            if on { AgentNotifier.shared.requestAuthorizationIfNeeded() }
        }
        .onChange(of: settings.harnessHooks) { _, on in
            if on { HookInstaller.installAll() } else { HookInstaller.uninstallAll() }
        }
    }
}

// MARK: - Appearance

private struct AppearanceTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        let theme = settings.theme
        SectionLabel(text: "Theme")
        Card {
            CardRow(title: "Appearance", desc: "Terminal and chat follow the theme") {
                HStack(spacing: 2) {
                    segment("Dark", selected: settings.appearance == .dark) {
                        settings.appearance = .dark
                    }
                    segment("Light", selected: settings.appearance == .light) {
                        settings.appearance = .light
                    }
                }
                .padding(2)
                .background(theme.field, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.07), lineWidth: 1)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Wallpaper")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.t1)
                Text("Tints the glass behind the window")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.t3)
                HStack(spacing: 12) {
                    ForEach(Wallpaper.allCases, id: \.self) { wp in
                        wallpaperSwatch(wp, theme: theme)
                    }
                }
                .padding(.top, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
            .overlay(alignment: .bottom) { theme.sideLine.frame(height: 1) }

            CardRow(title: "Reduce transparency", desc: "Solid surfaces instead of glass") {
                GlassToggle(isOn: $settings.reduceTransparency)
            }

            CardRow(title: "Terminal font size", desc: "Applies to new chats", divider: false) {
                HStack(spacing: 2) {
                    stepButton("−") { settings.fontSize = max(11, settings.fontSize - 1) }
                    Text("\(settings.fontSize)px")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.t1)
                        .frame(minWidth: 42)
                    stepButton("+") { settings.fontSize = min(17, settings.fontSize + 1) }
                }
                .padding(2)
                .background(theme.field, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.07), lineWidth: 1)
                }
            }
        }
    }

    private func segment(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(settings.theme.t1)
                .padding(.horizontal, 14)
                .padding(.vertical, 3)
                .background(selected ? settings.theme.sel : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func stepButton(_ label: String, action: @escaping () -> Void) -> some View {
        Hoverable { hovered in
            Button(action: action) {
                Text(label)
                    .font(.system(size: 14))
                    .foregroundStyle(settings.theme.t1)
                    .frame(width: 22, height: 20)
                    .background(hovered ? settings.theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
    }

    private func wallpaperSwatch(_ wp: Wallpaper, theme: Theme) -> some View {
        let selected = settings.wallpaper == wp
        return Button {
            settings.wallpaper = wp
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Color(hex: 0x07090f)
                    ForEach(Array(wp.gradients.enumerated()), id: \.offset) { _, g in
                        RadialGradient(
                            stops: [
                                .init(color: g.color, location: 0),
                                .init(color: g.color.opacity(0), location: 0.6),
                            ],
                            center: g.center,
                            startRadius: 0,
                            endRadius: 84 * g.radius
                        )
                    }
                }
                .frame(width: 84, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(
                            selected ? Color(hex: 0x7a9bff) : theme.sideLine,
                            lineWidth: selected ? 2 : 1
                        )
                }
                .shadow(
                    color: selected ? Color(hex: 0x7a9bff, alpha: 0.25) : .clear,
                    radius: 3
                )
                Text(wp.rawValue)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? theme.t1 : theme.t3)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - VM

private struct VMTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(VMStore.self) private var vms
    @Environment(ProjectStore.self) private var projects
    @Environment(SessionManager.self) private var sessions
    @Environment(UIState.self) private var ui
    @State private var renamingVMID: UUID?
    @State private var renameDraft = ""
    @State private var lifecycleVMID: UUID?
    @State private var customScriptLogVM: VM?

    var body: some View {
        let theme = settings.theme
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Virtual machines")
            Card {
                if vms.vms.isEmpty {
                    Text("No VMs yet. A VM is a shared Linux machine — one VM can host many projects.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.t3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                }
                ForEach(vms.vms) { vm in
                    vmRow(vm, theme: theme)
                }
                Hoverable { hovered in
                    Button {
                        ui.presentNewVM(defaultName: "dev-vm-\(vms.vms.count + 1)")
                    } label: {
                        Text("+ New VM")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(EdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18))
                            .background(hovered ? theme.hover.opacity(0.5) : .clear, in: Rectangle())
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if let vm = vms.vm(vms.selectedVMID) {
                vmDetail(vm, theme: theme)
            }
        }
        .sheet(item: $customScriptLogVM) { vm in
            CustomScriptLogSheet(vm: vm)
                .presentationBackground(.clear)
        }
    }

    private func vmRow(_ vm: VM, theme: Theme) -> some View {
        let selected = vms.selectedVMID == vm.id
        let attachedCount = vms.attachedProjects(of: vm.id, in: projects.projects).count

        return Hoverable { hovered in
            Button {
                vms.selectedVMID = vm.id
                renamingVMID = nil
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.accentSoft)
                    Text(vm.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.t1)
                        .frame(minWidth: 90, alignment: .leading)
                    stateChip(vm.state, theme: theme)
                    Spacer(minLength: 8)
                    Text("\(attachedCount) \(attachedCount == 1 ? "project" : "projects")")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.t3)
                    Text("\(vm.ram) · \(formatGB(vm.diskUsedGB))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.t3)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.t3.opacity(0.8))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 13, leading: 18, bottom: 13, trailing: 18))
                .background(selected ? theme.sel.opacity(0.65) : hovered ? theme.hover.opacity(0.5) : .clear, in: Rectangle())
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .overlay(alignment: .bottom) { theme.sideLine.frame(height: 1) }
    }

    private func vmDetail(_ vm: VM, theme: Theme) -> some View {
        Card {
            vmDetailHeader(vm, theme: theme)

            if vm.state == .downloading || vm.state == .provisioning {
                setupSection(vm, theme: theme)
            }

            if vm.state == .ready || vm.state == .stopped || vm.state == .starting || vm.state == .error {
                attachedProjectsSection(vm, theme: theme)
                mirroredPortsSection(vm, theme: theme)
                hostPortsSection(vm, theme: theme)
                resourcesSection(vm, theme: theme)
                agentsSection(vm, theme: theme)
                idleStopRow(vm)
                networkAccessRow(vm)
                desktopAccessRow(vm)
                cuaAccessRow(vm)
                if vm.customScriptFailed {
                    customScriptWarningRow(vm, theme: theme)
                }
                manageSection(vm, theme: theme)
            }
        }
    }

    private func vmDetailHeader(_ vm: VM, theme: Theme) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    if renamingVMID == vm.id {
                        TextField("VM name", text: $renameDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.t1)
                            .frame(width: 140)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(theme.field, in: RoundedRectangle(cornerRadius: 7))
                            .onSubmit { saveRename(vm) }
                            .onExitCommand { cancelRename() }

                        Button("Save") { saveRename(vm) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.accent)
                            .disabled(trimmedRename.isEmpty)
                    } else {
                        Text(vm.name)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(theme.t1)
                            .lineLimit(1)

                        Hoverable { hovered in
                            Button { beginRename(vm) } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(hovered ? theme.accent : theme.t3)
                                    .frame(width: 20, height: 20)
                                    .background(hovered ? theme.hover : .clear, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Rename \(vm.name)")
                        }
                    }

                    stateChip(vm.state, theme: theme)
                }

                vmMeta(vm, theme: theme)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if vm.state == .ready || vm.state == .stopped || vm.state == .error {
                startStopButton(vm, theme: theme)
            }
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .overlay(alignment: .bottom) { theme.sideLine.frame(height: 1) }
    }

    @ViewBuilder
    private func vmMeta(_ vm: VM, theme: Theme) -> some View {
        switch vm.state {
        case .ready:
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text("\(vm.ip) · up \(vms.uptimeLabel(for: vm.id, at: context.date))")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.t3)
            }
        case .stopped:
            Text("Stopped — projects stay imported")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.t3)
        case .error:
            Text(vm.errorMessage ?? "VM setup failed")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.red)
                .lineLimit(1)
        case .downloading, .provisioning, .starting:
            Text("Setting up…")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.t3)
        }
    }

    private func startStopButton(_ vm: VM, theme: Theme) -> some View {
        let busy = lifecycleVMID == vm.id
        return Hoverable { hovered in
            Button {
                guard !busy else { return }
                lifecycleVMID = vm.id
                Task {
                    if vm.state == .ready {
                        await vms.stopVM(vm.id)
                    } else {
                        await vms.startVM(vm.id)
                    }
                    lifecycleVMID = nil
                }
            } label: {
                HStack(spacing: 7) {
                    if busy { SpinnerView() }
                    Text(vm.state == .ready ? "Stop" : "Start")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.t1)
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .background(hovered && !busy ? theme.hover : theme.chip, in: Capsule())
                .overlay { Capsule().strokeBorder(theme.sideLine, lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .disabled(busy)
        }
    }

    @ViewBuilder
    private func setupSection(_ vm: VM, theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if vm.state == .downloading {
                if vm.isVerifyingImage {
                    HStack(spacing: 8) {
                        SpinnerView().frame(width: 11, height: 11)
                        Text("Verifying checksum…")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.t1)
                    }
                } else {
                    Text("Downloading Debian 12 image")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.t1)

                    HStack {
                        Text(downloadLabel(vm))
                        Spacer()
                        Text(downloadPercentLabel(vm))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(theme.t3)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                    progressBar(
                        fraction: clampedPercent(vm.downloadProgress) / 100,
                        tint: theme.accent,
                        track: theme.field
                    )
                }
            } else {
                Text("Provisioning")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.t1)
                    .padding(.bottom, 10)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(vm.phases.filter {
                        $0.state != .skipped && ($0.id != "custom" || vm.hasCustomScript)
                    }) { phase in
                        HStack(spacing: 10) {
                            Group {
                                if phase.state == .running {
                                    SpinnerView()
                                } else {
                                    Text(phaseGlyph(phase.state))
                                        .font(.system(size: 12, weight: .medium))
                                }
                            }
                            .frame(width: 14)

                            Text(phase.label)
                                .font(.system(size: 12))

                            if phase.id == "custom", phase.state == .failed {
                                Spacer(minLength: 8)
                                Button("view log") {
                                    customScriptLogVM = vm
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11))
                                .foregroundStyle(theme.accent)
                                .underline()
                            }
                        }
                        .foregroundStyle(
                            phase.id == "custom" && phase.state == .failed
                                ? theme.orange
                                : phaseColor(phase.state, theme: theme)
                        )
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            phase.id == "custom" && phase.state == .failed
                                ? theme.orange.opacity(0.07)
                                : .clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                    }
                }
            }

            Text("The image is downloaded once and shared by all VMs.")
                .font(.system(size: 11))
                .foregroundStyle(theme.t3)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .overlay(alignment: .bottom) { theme.sideLine.frame(height: 1) }
    }

    private func attachedProjectsSection(_ vm: VM, theme: Theme) -> some View {
        let attached = vms.attachedProjects(of: vm.id, in: projects.projects)
        return VStack(alignment: .leading, spacing: 0) {
            Text("Attached projects")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.t2)
                .padding(.bottom, 8)

            if attached.isEmpty {
                Text("None — right-click a project and choose Enable VM.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.t3)
            } else {
                VStack(spacing: 2) {
                    ForEach(attached) { project in
                        attachedProjectRow(project, theme: theme)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 13, leading: 18, bottom: 13, trailing: 18))
        .overlay(alignment: .bottom) { theme.sideLine.frame(height: 1) }
    }

    private func attachedProjectRow(_ project: Project, theme: Theme) -> some View {
        let guestPath = vms.attachment(for: project.id)?.guestPath ?? "/workspace/\(project.name)"
        return Hoverable { hovered in
            Button {
                sessions.selectedSessionID = sessions.sessions(in: project).first?.id
                ui.view = .app
            } label: {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.folderBlue)
                        Text(project.name)
                            .font(.system(size: 13))
                            .foregroundStyle(theme.t1)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        Text(guestPath)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.t3)
                            .lineLimit(1)
                        if let transfer = vms.attachmentTransferLabel(
                            for: project.id,
                            now: context.date
                        ) {
                            Text(transfer)
                                .font(.system(size: 11))
                                .foregroundStyle(theme.t3)
                                .frame(minWidth: 98, alignment: .trailing)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(hovered ? theme.hover.opacity(0.65) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, -8)
    }

    private func mirroredPortsSection(_ vm: VM, theme: Theme) -> some View {
        let live = vms.mirrorRows(for: vm.id)
        let excluded = Set(vms.excludedMirrorPorts(for: vm.id))
        let extraExcluded = excluded.subtracting(live.map(\.guest)).sorted()
        return VStack(alignment: .leading, spacing: 0) {
            Text("Mirrored Ports")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.t2)
                .padding(.bottom, 8)

            VStack(spacing: 2) {
                ForEach(live, id: \.guest) { row in
                    mirroredPortRow(
                        guest: row.guest,
                        host: row.host,
                        status: row.status,
                        excluded: excluded.contains(row.guest),
                        vm: vm,
                        theme: theme
                    )
                }
                ForEach(extraExcluded, id: \.self) { port in
                    mirroredPortRow(
                        guest: port,
                        host: port,
                        status: nil,
                        excluded: true,
                        vm: vm,
                        theme: theme
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 13, leading: 18, bottom: 13, trailing: 18))
        .overlay(alignment: .bottom) { theme.sideLine.frame(height: 1) }
    }

    private func mirroredPortRow(
        guest: UInt16,
        host: UInt16,
        status: MirrorPortStatus?,
        excluded: Bool,
        vm: VM,
        theme: Theme
    ) -> some View {
        HStack(spacing: 8) {
            Text("\(guest)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.t1)
            Text("·")
                .foregroundStyle(theme.t3)
            Text("\(host)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.t1)
            if let status {
                Text(status == .conflict ? "Conflict" : "Active")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(status == .conflict ? theme.orange : theme.green)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(
                        (status == .conflict ? theme.orange : theme.green).opacity(0.16),
                        in: Capsule()
                    )
            }
            Spacer(minLength: 8)
            Text("Exclude")
                .font(.system(size: 11))
                .foregroundStyle(theme.t3)
            GlassToggle(isOn: Binding(
                get: { excluded },
                set: { on in
                    Task { await setPortExcluded(vm: vm, port: guest, excluded: on) }
                }
            ))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func hostPortsSection(_ vm: VM, theme: Theme) -> some View {
        let current = vms.hostMirrorPorts(for: vm.id)
        let suggestions: [UInt16] = [27_017, 5_432, 6_379, 3_306]
        let dismissed = vms.dismissedHostMirrorPorts(for: vm.id).filter {
            !current.contains($0) && !suggestions.contains($0)
        }
        return VStack(alignment: .leading, spacing: 0) {
            Text("Host Ports")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.t2)
                .padding(.bottom, 8)

            HStack(spacing: 6) {
                ForEach(suggestions, id: \.self) { port in
                    let added = current.contains(port)
                    Button {
                        guard !added else { return }
                        setHostPorts(current + [port], on: vm)
                    } label: {
                        Text(String(port))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(added ? theme.t3 : theme.t1)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(
                                added ? theme.field : theme.chip,
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(theme.sideLine, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(added)
                }
                ForEach(dismissed, id: \.self) { port in
                    Button {
                        setHostPorts(current + [port], on: vm)
                    } label: {
                        Text(String(port))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.t1)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(theme.chip, in: RoundedRectangle(cornerRadius: 7))
                            .overlay {
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(theme.sideLine, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, current.isEmpty ? 0 : 8)

            if !current.isEmpty {
                HStack(spacing: 6) {
                    ForEach(current, id: \.self) { port in
                        HStack(spacing: 3) {
                            Text(String(port))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(theme.t1)
                            Button {
                                setHostPorts(current.filter { $0 != port }, on: vm)
                            } label: {
                                Text("×")
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.t3)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(theme.field, in: RoundedRectangle(cornerRadius: 7))
                    }
                }
                .padding(.bottom, 8)
            }

            HostPortAddField { port in
                guard !current.contains(port) else { return }
                setHostPorts(current + [port], on: vm)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 13, leading: 18, bottom: 13, trailing: 18))
        .overlay(alignment: .bottom) { theme.sideLine.frame(height: 1) }
    }

    private func setPortExcluded(vm: VM, port: UInt16, excluded: Bool) async {
        let attached = vms.attachedProjects(of: vm.id, in: projects.projects)
        if attached.isEmpty {
            return
        }
        for project in attached {
            await vms.setPortExcluded(attachmentID: project.id, port: port, excluded: excluded)
        }
    }

    private func setHostPorts(_ ports: [UInt16], on vm: VM) {
        vms.setHostMirrorPorts(vmID: vm.id, ports)
    }

    private func resourcesSection(_ vm: VM, theme: Theme) -> some View {
        let diskFraction = vm.diskMaxGB > 0
            ? min(max(vm.diskUsedGB / vm.diskMaxGB, 0), 1)
            : 0

        return VStack(alignment: .leading, spacing: 0) {
            Text("Resources")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.t2)
                .padding(.bottom, 8)

            if vm.state == .stopped {
                VStack(spacing: 6) {
                    resourceStepperRow(
                        label: "CPU",
                        stepper: GlassStepper(
                            value: "\(vm.cpu) cores",
                            canDecrement: vm.cpu > 1,
                            canIncrement: vm.cpu < HostLimits.maxCPUs,
                            onDecrement: {
                                Task { await vms.updateResources(on: vm.id, cpus: max(1, vm.cpu - 1)) }
                            },
                            onIncrement: {
                                Task { await vms.updateResources(on: vm.id, cpus: min(HostLimits.maxCPUs, vm.cpu + 1)) }
                            }
                        )
                    )
                    resourceStepperRow(
                        label: "RAM",
                        stepper: GlassStepper(
                            value: "\(ramGB(for: vm)) GB",
                            canDecrement: ramGB(for: vm) > 1,
                            canIncrement: ramGB(for: vm) < HostLimits.maxRAMGB,
                            onDecrement: {
                                Task {
                                    await vms.updateResources(
                                        on: vm.id,
                                        memoryMB: max(1, ramGB(for: vm) - 1) * 1_024
                                    )
                                }
                            },
                            onIncrement: {
                                Task {
                                    await vms.updateResources(
                                        on: vm.id,
                                        memoryMB: min(HostLimits.maxRAMGB, ramGB(for: vm) + 1) * 1_024
                                    )
                                }
                            }
                        )
                    )
                    resourceStepperRow(
                        label: "Disk max",
                        stepper: GlassStepper(
                            value: formatCapacityGB(vm.diskMaxGB),
                            canDecrement: false,
                            canIncrement: vm.diskMaxGB < 256,
                            onDecrement: {},
                            onIncrement: {
                                Task {
                                    await vms.updateResources(
                                        on: vm.id,
                                        diskSizeGB: min(256, Int(vm.diskMaxGB) + 8)
                                    )
                                }
                            }
                        )
                    )
                }
            } else {
                HStack(spacing: 28) {
                    Text("\(vm.cpu) cores")
                    Text("\(vm.ram) RAM")
                }
                .font(.system(size: 12))
                .foregroundStyle(theme.t1)
            }

            HStack {
                Text("Disk")
                Spacer()
                Text("\(formatGB(vm.diskUsedGB)) of \(formatCapacityGB(vm.diskMaxGB))")
            }
            .font(.system(size: 11))
            .foregroundStyle(theme.t3)
            .padding(.top, 10)
            .padding(.bottom, 4)

            progressBar(
                fraction: diskFraction,
                tint: theme.accentSoft.opacity(0.6),
                track: theme.field
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 13, leading: 18, bottom: 13, trailing: 18))
        .overlay(alignment: .bottom) { theme.sideLine.frame(height: 1) }
    }

    private func resourceStepperRow(label: String, stepper: GlassStepper) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(settings.theme.t2)
            Spacer()
            stepper
        }
    }

    private func agentsSection(_ vm: VM, theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Agents")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.t2)
                Spacer()
                transferAuthButton(vm, theme: theme)
                updateAgentsButton(vm, theme: theme)
            }
            .padding(.bottom, 8)

            VStack(spacing: 6) {
                ForEach(vm.agents) { agent in
                    agentRow(agent, vm: vm, theme: theme)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 13, leading: 18, bottom: 13, trailing: 18))
        .overlay(alignment: .bottom) { theme.sideLine.frame(height: 1) }
    }

    private func transferAuthButton(_ vm: VM, theme: Theme) -> some View {
        let enabled = vm.state == .ready
        return Hoverable { hovered in
            Button {
                guard enabled else { return }
                Task { await vms.transferAuth(vmID: vm.id) }
            } label: {
                Text("Transfer auth from Mac")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.t1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(hovered && enabled ? theme.hover : theme.chip, in: Capsule())
                    .overlay { Capsule().strokeBorder(theme.chipHi, lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.55)
        }
    }

    private func updateAgentsButton(_ vm: VM, theme: Theme) -> some View {
        let enabled = vm.state == .ready && vm.updateState != .running && vm.updateState != .done
        return Hoverable { hovered in
            Button {
                guard enabled else { return }
                Task { await vms.updateAgents(on: vm.id) }
            } label: {
                Text(updateButtonLabel(vm.updateState))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(vm.updateState == .done ? successColor : theme.t1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(hovered && enabled ? theme.hover : theme.chip, in: Capsule())
                    .overlay { Capsule().strokeBorder(theme.chipHi, lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(vm.state == .ready ? 1 : 0.55)
        }
    }

    private func agentRow(_ agent: VMAgent, vm: VM, theme: Theme) -> some View {
        HStack(spacing: 10) {
            Text(agent.name)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.t1)
                .frame(minWidth: 60, alignment: .leading)
            Text(agent.version)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.t3)
            Spacer()
            HStack(spacing: 6) {
                switch agent.status {
                case .ok:
                    Button("Update") {
                        guard vm.state == .ready, vm.updateState != .running else { return }
                        Task { await vms.updateAgent(agent.name, on: vm) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.accent)
                    .underline()
                    .disabled(vm.state != .ready || vm.updateState == .running)
                case .updating:
                    SpinnerView()
                case .updated:
                    Text("✓ updated")
                        .font(.system(size: 11))
                        .foregroundStyle(successColor)
                case .failed:
                    Text("✗ failed")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.red)
                    Button("Retry") {
                        guard vm.state == .ready, vm.updateState != .running else { return }
                        Task { await vms.updateAgent(agent.name, on: vm) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.accent)
                    .underline()
                    .disabled(vm.state != .ready || vm.updateState == .running)
                }
                if agent.name == "codex" || agent.name == "grok" {
                    Button("Login…") {
                        guard vm.state == .ready else { return }
                        Task {
                            if agent.name == "codex" {
                                await vms.loginCodex(vmID: vm.id)
                            } else {
                                await vms.loginGrok(vmID: vm.id)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.accent)
                    .underline()
                    .disabled(vm.state != .ready)
                }
            }
        }
        .font(.system(size: 12))
    }

    private func idleStopRow(_ vm: VM) -> some View {
        let enabled = vm.idleStopMinutes != nil
        let minutes = vm.idleStopMinutes ?? 30

        return CardRow(title: "Stop when idle") {
            HStack(spacing: 12) {
                if enabled {
                    GlassStepper(
                        value: "\(minutes) min",
                        canDecrement: minutes > 5,
                        canIncrement: minutes < 120,
                        onDecrement: {
                            Task { @MainActor in
                                await vms.setIdleStop(minutes: max(5, minutes - 5), on: vm.id)
                            }
                        },
                        onIncrement: {
                            Task { @MainActor in
                                await vms.setIdleStop(minutes: min(120, minutes + 5), on: vm.id)
                            }
                        }
                    )
                }

                GlassToggle(isOn: Binding(
                    get: { vm.idleStopMinutes != nil },
                    set: { on in
                        Task { @MainActor in
                            await vms.setIdleStop(minutes: on ? max(5, minutes) : nil, on: vm.id)
                        }
                    }
                ))
            }
        }
    }

    private func networkAccessRow(_ vm: VM) -> some View {
        let theme = settings.theme
        return CardRow(title: "Network access", divider: true) {
            HStack(spacing: 10) {
                if vm.networkChangePending {
                    Text("applies after restart")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(theme.orange.opacity(0.14), in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(theme.orange.opacity(0.20), lineWidth: 1)
                        }
                }

                GlassToggle(isOn: Binding(
                    get: { vm.networkEnabled },
                    set: { on in
                        Task { @MainActor in
                            await vms.setNetworkEnabled(on, on: vm.id)
                        }
                    }
                ))
            }
        }
    }

    private func desktopAccessRow(_ vm: VM) -> some View {
        let theme = settings.theme
        return CardRow(title: "Desktop", divider: true) {
            HStack(spacing: 10) {
                if vm.desktopChangePending {
                    Text("applies after restart")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(theme.orange.opacity(0.14), in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(theme.orange.opacity(0.20), lineWidth: 1)
                        }
                }

                GlassToggle(isOn: Binding(
                    get: { vm.desktopEnabled },
                    set: { on in
                        Task { @MainActor in
                            await vms.setDesktopEnabled(on, on: vm.id)
                        }
                    }
                ))
            }
        }
    }

    private func cuaAccessRow(_ vm: VM) -> some View {
        let theme = settings.theme
        return CardRow(title: "Computer Use", divider: true) {
            HStack(spacing: 10) {
                if vm.cuaDriverChangePending {
                    Text("applies after restart")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(theme.orange.opacity(0.14), in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(theme.orange.opacity(0.20), lineWidth: 1)
                        }
                }

                GlassToggle(isOn: Binding(
                    get: { vm.cuaDriverEnabled },
                    set: { on in
                        Task { @MainActor in
                            await vms.setCuaDriverEnabled(on, on: vm.id)
                        }
                    }
                ))
            }
        }
    }

    private func customScriptWarningRow(_ vm: VM, theme: Theme) -> some View {
        HStack(spacing: 8) {
            Text("⚠ Custom script failed during setup")
                .font(.system(size: 12))
                .foregroundStyle(theme.orange)
            Spacer(minLength: 8)
            Button("view log") {
                customScriptLogVM = vm
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(theme.accent)
            .underline()
        }
        .padding(EdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 18))
        .background(theme.orange.opacity(0.07))
        .overlay(alignment: .bottom) { theme.sideLine.frame(height: 1) }
    }

    private func manageSection(_ vm: VM, theme: Theme) -> some View {
        HStack(spacing: 14) {
            Button("Delete VM") { confirmDeletion(of: vm) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(theme.red)
            Spacer()
        }
        .padding(EdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18))
    }

    private func stateChip(_ state: VM.State, theme: Theme) -> some View {
        Text(chipLabel(state))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(chipForeground(state, theme: theme))
            .padding(.horizontal, 9)
            .padding(.vertical, 2)
            .background(chipBackground(state, theme: theme), in: Capsule())
    }

    private func progressBar(fraction: Double, tint: Color, track: Color) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(track)
                RoundedRectangle(cornerRadius: 2)
                    .fill(tint)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 4)
    }

    private func beginRename(_ vm: VM) {
        renamingVMID = vm.id
        renameDraft = vm.name
    }

    private func saveRename(_ vm: VM) {
        guard !trimmedRename.isEmpty else { return }
        let name = trimmedRename
        renamingVMID = nil
        Task { await vms.renameVM(vm.id, to: name) }
    }

    private func cancelRename() {
        renamingVMID = nil
    }

    private func confirmDeletion(of vm: VM) {
        let attachedCount = vms.attachedProjects(of: vm.id, in: projects.projects).count
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete \(vm.name)?"
        if attachedCount == 0 {
            alert.informativeText = "This permanently deletes the VM and its disk. This action can’t be undone."
        } else {
            let noun = attachedCount == 1 ? "project" : "projects"
            alert.informativeText = "This permanently deletes the VM and detaches \(attachedCount) \(noun). This action can’t be undone."
        }
        alert.addButton(withTitle: "Delete VM")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let id = vm.id
        let name = vm.name
        Task {
            await vms.deleteVM(id)
            if vms.vm(id) == nil {
                if renamingVMID == id { cancelRename() }
                ui.showToast("Deleted \(name)")
            }
        }
    }

    private var trimmedRename: String {
        renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func chipLabel(_ state: VM.State) -> String {
        switch state {
        case .ready: "Ready"
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .provisioning: "Provisioning"
        case .downloading: "Downloading"
        case .error: "Error"
        }
    }

    private func chipForeground(_ state: VM.State, theme: Theme) -> Color {
        switch state {
        case .ready: successColor
        case .stopped: theme.t2
        case .starting, .provisioning, .downloading: theme.accent
        case .error: theme.red
        }
    }

    private func chipBackground(_ state: VM.State, theme: Theme) -> Color {
        switch state {
        case .ready: Color(hex: 0x34d399, alpha: 0.15)
        case .stopped: theme.field
        case .starting, .provisioning, .downloading: Color(hex: 0x8ab4ff, alpha: 0.15)
        case .error: theme.red.opacity(0.14)
        }
    }

    private func phaseGlyph(_ state: VMPhase.State) -> String {
        switch state {
        case .done: "✓"
        case .failed: "✗"
        case .pending: "○"
        case .running: ""
        case .skipped: "–"
        }
    }

    private func phaseColor(_ state: VMPhase.State, theme: Theme) -> Color {
        switch state {
        case .done: successColor
        case .failed: theme.red
        case .running: theme.t1
        case .pending, .skipped: theme.t3
        }
    }

    private func updateButtonLabel(_ state: VMUpdateState) -> String {
        switch state {
        case .idle: "Update agents"
        case .running: "Updating…"
        case .partial: "Retry failed"
        case .done: "Up to date ✓"
        }
    }

    private func clampedPercent(_ percent: Double) -> Double {
        min(max(percent, 0), 100)
    }

    private func downloadLabel(_ vm: VM) -> String {
        let downloaded = formatBytesAsGB(vm.downloadedImageBytes)
        guard let expected = vm.expectedImageBytes, expected > 0 else {
            return "\(downloaded) downloaded"
        }
        return "\(downloaded) of \(formatBytesAsGB(expected))"
    }

    private func downloadPercentLabel(_ vm: VM) -> String {
        guard vm.expectedImageBytes.map({ $0 > 0 }) == true else { return "—" }
        return "\(Int(clampedPercent(vm.downloadProgress).rounded()))%"
    }

    private func formatBytesAsGB(_ bytes: Int64) -> String {
        formatGB(Double(max(0, bytes)) / 1_000_000_000)
    }

    private func formatGB(_ value: Double) -> String {
        "\(String(format: "%.1f", max(0, value))) GB"
    }

    private func formatCapacityGB(_ value: Double) -> String {
        let value = max(0, value)
        if value.rounded() == value { return "\(Int(value)) GB" }
        return formatGB(value)
    }

    private func ramGB(for vm: VM) -> Int {
        guard let raw = vm.ram.split(separator: " ").first,
              let value = Double(raw)
        else {
            return 4
        }
        return max(1, Int(value.rounded()))
    }

    private var successColor: Color {
        settings.theme.greenBright
    }

}

private struct CustomScriptLogSheet: View {
    let vm: VM

    @Environment(AppSettings.self) private var settings
    @Environment(VMStore.self) private var vms
    @Environment(\.dismiss) private var dismiss
    @State private var log = ""
    @State private var isLoading = true

    var body: some View {
        let theme = settings.theme

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Custom script log")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(theme.t1)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }

            Group {
                if isLoading {
                    HStack(spacing: 8) {
                        SpinnerView()
                        Text("Loading…")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.t3)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollView {
                        Text(log.isEmpty ? "No log available." : log)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.t1)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(10)
                    }
                    .background(theme.field, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(height: 260)
            .padding(.top, 14)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(width: 460)
        .glassPanel(
            tint: theme.menu,
            enabled: !settings.reduceTransparency,
            fallback: theme.solidToolbar
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(theme.sideLine, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 40, y: 30)
        .task(id: vm.id) {
            log = await vms.customScriptLog(for: vm)
            isLoading = false
        }
        .onExitCommand { dismiss() }
    }
}

// MARK: - Shortcuts

private struct ShortcutsTab: View {
    @Environment(AppSettings.self) private var settings

    private static let rows: [(String, String)] = [
        ("New chat", "⌘N"),
        ("New chat in current project", "⌘T"),
        ("Close chat", "⌘W"),
        ("Search chats", "⌘K"),
        ("Settings", "⌘,"),
    ]

    var body: some View {
        let theme = settings.theme
        SectionLabel(text: "Keyboard")
        Card {
            ForEach(Array(Self.rows.enumerated()), id: \.offset) { i, row in
                HStack(spacing: 16) {
                    Text(row.0)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.t1)
                    Spacer()
                    Text(row.1)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.t2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(theme.field, in: RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(theme.sideLine, lineWidth: 1)
                        }
                }
                .padding(EdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18))
                .overlay(alignment: .bottom) {
                    if i < Self.rows.count - 1 { theme.sideLine.frame(height: 1) }
                }
            }
        }
    }
}
