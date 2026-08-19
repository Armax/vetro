import SwiftUI
import Virtualization
import VMKit

/// Hosts a live `VZVirtualMachineView` for a desktop VM. The view is itself the
/// long-lived NSView, so no reparenting machinery is needed.
struct VMDisplayHost: NSViewRepresentable {
    let handle: VMDisplayHandle

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true  // guest resolution follows the window
        view.virtualMachine = handle.virtualMachine
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        if view.virtualMachine !== handle.virtualMachine {
            view.virtualMachine = handle.virtualMachine
        }
    }
}
