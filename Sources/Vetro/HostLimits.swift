import Foundation

/// Host-derived ceilings for VM resource pickers.
enum HostLimits {
    static let maxCPUs = ProcessInfo.processInfo.activeProcessorCount

    /// Leaves 8 GB of headroom for macOS; never below the old 16 GB cap.
    static let maxRAMGB = max(16, Int(ProcessInfo.processInfo.physicalMemory / (1 << 30)) - 8)
}
