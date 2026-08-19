import SwiftUI
import VMKit

/// A separate window hosting one desktop VM's `VZVirtualMachineView`.
struct DesktopWindow: View {
    let vmID: UUID

    @Environment(VMStore.self) private var vms
    @Environment(AppSettings.self) private var settings
    @State private var handle: VMDisplayHandle?

    var body: some View {
        ZStack {
            Color.black
            if let handle {
                VMDisplayHost(handle: handle)
            } else {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .ignoresSafeArea()
        .navigationTitle(vms.vm(vmID)?.name ?? "Desktop")
        .task { handle = await vms.desktopHandle(for: vmID) }
        .onAppear { vms.desktopWindowOpened(vmID) }
        .onDisappear { vms.desktopWindowClosed(vmID) }
    }
}
