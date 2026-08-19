import SwiftUI

struct NewVMSheet: View {
    @Environment(AppSettings.self) private var settings
    @Environment(VMStore.self) private var vms
    @Environment(\.dismiss) private var dismiss

    let defaultName: String
    let attachingProject: Project?

    @State private var name: String
    @State private var cpus = 4
    @State private var ramGB = 8
    @State private var diskGB = 32
    @State private var selectedAgents: Set<String>
    @State private var transferAuth = true
    @State private var desktopEnabled = false
    @State private var cuaDriverEnabled = false
    @State private var setupScript = ""
    @State private var isScriptExpanded = false
    @State private var isCreating = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name
    }

    private static let agentNames = ["claude", "codex", "grok"]

    init(defaultName: String, attachingProject: Project? = nil) {
        self.defaultName = defaultName
        self.attachingProject = attachingProject
        _name = State(initialValue: defaultName)
        _selectedAgents = State(initialValue: Set(Self.agentNames))
    }

    var body: some View {
        let theme = settings.theme

        VStack(alignment: .leading, spacing: 0) {
            Text("New VM")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(theme.t1)

            if let attachingProject {
                Text("▣ Attaches \(attachingProject.name) after setup")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.accentSoft)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Color(hex: 0x7a9bff, alpha: 0.14), in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(Color(hex: 0x7a9bff, alpha: 0.20), lineWidth: 1)
                    }
                    .padding(.top, 8)
            }

            HStack(spacing: 12) {
                Text("Name")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.t2)
                    .frame(width: 42, alignment: .leading)
                TextField("VM name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.t1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(theme.field, in: RoundedRectangle(cornerRadius: 8))
                    .focused($focusedField, equals: .name)
                    .onSubmit(createVM)
            }
            .padding(.top, 14)

            VStack(spacing: 8) {
                configurationRow(
                    label: "CPU",
                    stepper: GlassStepper(
                        value: "\(cpus) cores",
                        canDecrement: cpus > 1,
                        canIncrement: cpus < HostLimits.maxCPUs,
                        onDecrement: { cpus = max(1, cpus - 1) },
                        onIncrement: { cpus = min(HostLimits.maxCPUs, cpus + 1) }
                    )
                )
                configurationRow(
                    label: "RAM",
                    stepper: GlassStepper(
                        value: "\(ramGB) GB",
                        canDecrement: ramGB > 1,
                        canIncrement: ramGB < HostLimits.maxRAMGB,
                        onDecrement: { ramGB = max(1, ramGB - 1) },
                        onIncrement: { ramGB = min(HostLimits.maxRAMGB, ramGB + 1) }
                    )
                )
                configurationRow(
                    label: "Disk",
                    stepper: GlassStepper(
                        value: "\(diskGB) GB",
                        canDecrement: diskGB > 16,
                        canIncrement: diskGB < 256,
                        onDecrement: { diskGB = max(16, diskGB - 8) },
                        onIncrement: { diskGB = min(256, diskGB + 8) }
                    )
                )
            }
            .padding(.top, 12)

            Text("Agents")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.t2)
                .padding(.top, 14)

            HStack(spacing: 16) {
                ForEach(Self.agentNames, id: \.self) { agent in
                    agentToggle(agent, theme: theme)
                }
            }
            .padding(.top, 8)

            authToggle(theme: theme)
                .padding(.top, 12)

            desktopToggle(theme: theme)
                .padding(.top, 10)

            cuaToggle(theme: theme)
                .padding(.top, 10)

            if isScriptExpanded {
                Text("Setup script")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.t2)
                    .padding(.top, 14)

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $setupScript)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.t1)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)

                    if setupScript.isEmpty {
                        Text("# runs once after provisioning")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(theme.t3)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 84)
                .background(theme.field, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(theme.fieldHi, lineWidth: 1)
                }
                .padding(.top, 8)
            } else {
                Hoverable { hovered in
                    Button("+ Setup script") {
                        withAnimation(.easeOut(duration: 0.15)) {
                            isScriptExpanded = true
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .underline(hovered)
                }
                .padding(.top, 14)
            }

            HStack(spacing: 10) {
                Spacer()
                sheetButton("Cancel", tint: theme.chip, foreground: theme.t1) {
                    dismiss()
                }
                sheetButton(
                    "Create VM",
                    tint: theme.accentChip,
                    foreground: theme.accentTxt,
                    enabled: !isCreating,
                    action: createVM
                )
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(width: 380)
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
        .onExitCommand { dismiss() }
        .onAppear { focusedField = .name }
    }

    private func configurationRow(label: String, stepper: GlassStepper) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(settings.theme.t2)
            Spacer()
            stepper
        }
    }

    private func agentToggle(_ agent: String, theme: Theme) -> some View {
        let selected = selectedAgents.contains(agent)
        return Hoverable { hovered in
            Button {
                if selected {
                    selectedAgents.remove(agent)
                } else {
                    selectedAgents.insert(agent)
                }
            } label: {
                HStack(spacing: 7) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(selected ? Color(hex: 0x7a9bff, alpha: 0.9) : theme.field)
                            .frame(width: 15, height: 15)
                            .overlay {
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(
                                        selected ? .white.opacity(0.15) : theme.sideLine,
                                        lineWidth: 1
                                    )
                            }
                        if selected {
                            Text("✓")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    Text(agent)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.t1)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(hovered ? theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func authToggle(theme: Theme) -> some View {
        Hoverable { hovered in
            Button {
                transferAuth.toggle()
            } label: {
                HStack(spacing: 7) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(transferAuth ? Color(hex: 0x7a9bff, alpha: 0.9) : theme.field)
                            .frame(width: 15, height: 15)
                            .overlay {
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(
                                        transferAuth ? .white.opacity(0.15) : theme.sideLine,
                                        lineWidth: 1
                                    )
                            }
                        if transferAuth {
                            Text("✓")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    Text("Transfer authentication from this Mac")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.t1)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(hovered ? theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func desktopToggle(theme: Theme) -> some View {
        Hoverable { hovered in
            Button {
                desktopEnabled.toggle()
                // Computer Use implies Desktop: disabling Desktop clears it.
                if !desktopEnabled { cuaDriverEnabled = false }
            } label: {
                HStack(spacing: 7) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(desktopEnabled ? Color(hex: 0x7a9bff, alpha: 0.9) : theme.field)
                            .frame(width: 15, height: 15)
                            .overlay {
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(
                                        desktopEnabled ? .white.opacity(0.15) : theme.sideLine,
                                        lineWidth: 1
                                    )
                            }
                        if desktopEnabled {
                            Text("✓")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    Text("Desktop")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.t1)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(hovered ? theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func cuaToggle(theme: Theme) -> some View {
        Hoverable { hovered in
            Button {
                cuaDriverEnabled.toggle()
                // Computer Use implies Desktop: enabling it force-enables Desktop.
                if cuaDriverEnabled { desktopEnabled = true }
            } label: {
                HStack(spacing: 7) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(cuaDriverEnabled ? Color(hex: 0x7a9bff, alpha: 0.9) : theme.field)
                            .frame(width: 15, height: 15)
                            .overlay {
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(
                                        cuaDriverEnabled ? .white.opacity(0.15) : theme.sideLine,
                                        lineWidth: 1
                                    )
                            }
                        if cuaDriverEnabled {
                            Text("✓")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    Text("Computer Use")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.t1)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(hovered ? theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func sheetButton(
        _ title: String,
        tint: Color,
        foreground: Color,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Hoverable { hovered in
            Button(action: action) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(foreground)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(
                        hovered && enabled ? tint : tint.opacity(0.92),
                        in: Capsule()
                    )
                    .overlay { Capsule().strokeBorder(settings.theme.sideLine, lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.55)
        }
    }

    private func createVM() {
        guard !isCreating else { return }
        isCreating = true

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedScript = setupScript.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuration = NewVMConfiguration(
            name: trimmedName.isEmpty ? defaultName : trimmedName,
            cpus: cpus,
            memoryMB: ramGB * 1_024,
            diskSizeGB: diskGB,
            agents: Self.agentNames.filter { selectedAgents.contains($0) },
            transferAuth: transferAuth,
            customScript: trimmedScript.isEmpty ? nil : trimmedScript,
            desktopEnabled: desktopEnabled,
            cuaDriverEnabled: cuaDriverEnabled
        )
        let project = attachingProject
        dismiss()

        Task { @MainActor in
            if let project, vms.attachment(for: project.id) != nil {
                await vms.detach(project: project, deleteGuestCopy: false)
                guard vms.attachment(for: project.id) == nil else { return }
            }
            _ = await vms.createVM(configuration: configuration, attaching: project)
        }
    }
}
