import Foundation
import Observation

struct NewVMRequest: Identifiable {
    let id = UUID()
    let defaultName: String
    let attachingProject: Project?
}

struct TransferPreviewRequest: Identifiable {
    let id = UUID()
    let project: Project
    let direction: TransferDirection
}

struct AddVMProjectRequest: Identifiable {
    let id = UUID()
    let vmID: UUID
    let vmName: String
}

/// In-window navigation and transient UI state.
@MainActor
@Observable
final class UIState {
    enum View { case app, settings }
    enum SettingsTab: String, CaseIterable {
        case general = "General"
        case appearance = "Appearance"
        case vm = "VM"
        case shortcuts = "Shortcuts"

        var glyph: String {
            switch self {
            case .general: "gearshape"
            case .appearance: "circle.lefthalf.filled"
            case .vm: "server.rack"
            case .shortcuts: "command"
            }
        }
    }

    var view: View = .app
    var settingsTab: SettingsTab = .general
    var searchText: String = ""
    var searchFieldFocused: Bool = false
    var newVMRequest: NewVMRequest?
    var transferPreviewRequest: TransferPreviewRequest?
    var addVMProjectRequest: AddVMProjectRequest?
    private(set) var toast: String?

    private var toastTask: Task<Void, Never>?

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.2))
            if !Task.isCancelled { toast = nil }
        }
    }

    func presentNewVM(defaultName: String, attaching project: Project? = nil) {
        newVMRequest = NewVMRequest(
            defaultName: defaultName,
            attachingProject: project
        )
    }

    func presentAddVMProject(vmID: UUID, vmName: String) {
        addVMProjectRequest = AddVMProjectRequest(vmID: vmID, vmName: vmName)
    }

    func presentTransferPreview(for project: Project, direction: TransferDirection) {
        transferPreviewRequest = TransferPreviewRequest(
            project: project,
            direction: direction
        )
    }
}
