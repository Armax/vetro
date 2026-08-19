import SwiftUI
import VMKit

/// Hosts a desktop VM's display in the main content area, in place of the terminal.
struct DesktopPane: View {
    let vmID: UUID

    @Environment(VMStore.self) private var vms
    @Environment(AppSettings.self) private var settings
    @State private var handle: VMDisplayHandle?

    var body: some View {
        let vm = vms.vm(vmID)
        let ready = vm?.state == .ready
        ZStack {
            Color.black
            if let handle, ready {
                VMDisplayHost(handle: handle)
            } else if ready {
                ProgressView()
                    .controlSize(.large)
            } else {
                Text(vm == nil ? "VM removed" : "VM not running")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(settings.theme.t3)
            }
        }
        .task(id: "\(vmID)-\(ready)") {
            handle = ready ? await vms.desktopHandle(for: vmID) : nil
        }
        .onAppear { vms.desktopWindowOpened(vmID) }
        .onDisappear { vms.desktopWindowClosed(vmID) }
    }
}
