import Foundation
import VMKit

/// Single-quotes a value for safe embedding in a bash script (same escaping
/// as `VMStore.shellQuote`, but callable off the main actor).
func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

/// Where a session's repository lives and how to run git (and the summarize
/// CLIs) against it — on the Mac directly or inside the attached VM over SSH.
@MainActor
protocol GitSource {
    var repoPath: String { get }
    func exec(bashScript: String, timeoutSeconds: Int) async -> (status: Int32, stdout: String, stderr: String)?
}

/// Host repos: `/bin/bash -lc` so the user's profile (PATH for grok/codex)
/// loads, mirroring how the guest runs the same scripts.
struct HostGitSource: GitSource {
    let repoPath: String

    func exec(bashScript: String, timeoutSeconds: Int) async -> (status: Int32, stdout: String, stderr: String)? {
        let runner = SubprocessRunner(temporaryDirectoryURL: FileManager.default.temporaryDirectory)
        guard let result = try? await runner.run(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-lc", bashScript],
            timeoutSeconds: timeoutSeconds
        ) else { return nil }
        return (result.status, result.stdout, result.stderr)
    }
}

/// VM-attached repos: one-shot SSH through the ready attachment.
struct GuestGitSource: GitSource {
    let repoPath: String
    let projectID: UUID
    let vms: VMStore

    func exec(bashScript: String, timeoutSeconds: Int) async -> (status: Int32, stdout: String, stderr: String)? {
        await vms.execOnAttachedGuest(
            projectID: projectID,
            command: "bash -lc \(shellQuoted(bashScript))",
            timeoutSeconds: timeoutSeconds
        )
    }
}
