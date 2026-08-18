import SwiftUI

struct AddVMProjectSheet: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionManager.self) private var sessions
    @Environment(VMStore.self) private var vms
    @Environment(AppSettings.self) private var settings
    @Environment(UIState.self) private var ui
    @Environment(\.dismiss) private var dismiss

    let vmID: UUID
    let vmName: String

    @State private var folders: [String] = []
    @State private var isLoading = true
    @State private var selection: Selection = .new
    @State private var newFolderName = ""
    @State private var isConfirming = false
    @FocusState private var newFolderFocused: Bool

    private enum Selection: Hashable { case existing(String); case new }

    private var canConfirm: Bool {
        guard !isLoading, !isConfirming else { return false }
        switch selection {
        case .existing: return true
        case .new: return !newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        let theme = settings.theme
        VStack(alignment: .leading, spacing: 0) {
            Text("Add Project from \(vmName)")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(theme.t1)

            if isLoading {
                HStack { Spacer(); SpinnerView(); Spacer() }
                    .padding(.vertical, 28)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(folders, id: \.self) { folder in
                            folderRow(folder, theme: theme)
                        }
                        newFolderRow(theme: theme)
                    }
                }
                .frame(maxHeight: 240)
                .padding(.top, 14)
            }

            HStack(spacing: 10) {
                Spacer()
                sheetButton("Cancel", tint: theme.chip, foreground: theme.t1) { dismiss() }
                sheetButton(
                    "Add Project",
                    tint: theme.accentChip,
                    foreground: theme.accentTxt,
                    enabled: canConfirm,
                    action: confirm
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
            RoundedRectangle(cornerRadius: 18).strokeBorder(theme.sideLine, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 40, y: 30)
        .onExitCommand { dismiss() }
        .task {
            folders = await vms.listWorkspaceFolders(vmID: vmID)
            isLoading = false
        }
    }

    private func folderRow(_ folder: String, theme: Theme) -> some View {
        let selected = selection == .existing(folder)
        return Hoverable { hovered in
            Button { selection = .existing(folder) } label: {
                rowContent(icon: "folder", selected: selected, theme: theme) {
                    Text(folder).font(.system(size: 13)).foregroundStyle(theme.t1)
                    Spacer(minLength: 0)
                }
                .glassHighlight(selected || hovered, tint: selected ? theme.sel : theme.hover)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func newFolderRow(theme: Theme) -> some View {
        let selected = selection == .new
        return Hoverable { hovered in
            rowContent(icon: "plus", selected: selected, theme: theme) {
                TextField("New folder", text: $newFolderName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.t1)
                    .focused($newFolderFocused)
                    .onSubmit { if canConfirm { confirm() } }
                    .onChange(of: newFolderName) { _, _ in selection = .new }
            }
            .glassHighlight(selected || hovered, tint: selected ? theme.sel : theme.hover)
            .contentShape(Rectangle())
            .onTapGesture { selection = .new; newFolderFocused = true }
        }
    }

    @ViewBuilder
    private func rowContent<Content: View>(
        icon: String, selected: Bool, theme: Theme, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(theme.accentSoft)
            content()
            if selected {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.accent)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func confirm() {
        guard !isConfirming else { return }
        switch selection {
        case .existing(let folder):
            register(name: folder, guestPath: "/workspace/\(folder)")
        case .new:
            let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            isConfirming = true
            let vmID = self.vmID
            Task {
                guard let guestPath = await vms.makeWorkspaceFolder(vmID: vmID, name: trimmed) else {
                    isConfirming = false
                    ui.showToast("Couldn't create the folder on \(vmName).")
                    return
                }
                register(name: URL(fileURLWithPath: guestPath).lastPathComponent, guestPath: guestPath)
            }
        }
    }

    private func register(name: String, guestPath: String) {
        let project = store.addVMProject(name: name, vmID: vmID, guestPath: guestPath)
        dismiss()
        Task { await sessions.startSession(in: project) }
    }

    private func sheetButton(
        _ title: String, tint: Color, foreground: Color,
        enabled: Bool = true, action: @escaping () -> Void
    ) -> some View {
        Hoverable { hovered in
            Button(action: action) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(foreground)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(hovered && enabled ? tint : tint.opacity(0.92), in: Capsule())
                    .overlay { Capsule().strokeBorder(settings.theme.sideLine, lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.55)
        }
    }
}
