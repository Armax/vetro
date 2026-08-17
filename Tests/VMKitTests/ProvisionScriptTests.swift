import Foundation
import Testing
@testable import VMKit

@Suite("M2 guest provisioning script contract")
struct ProvisionScriptTests {
    @Test("contains the durable marker and phase contract")
    func containsMarkerContract() throws {
        let script = try loadScript()

        for phase in ["apt-base", "node", "workdir", "prune"] {
            #expect(script.contains("run_phase \(phase) "))
        }
        for agent in ["claude", "codex", "grok"] {
            #expect(script.contains("run_selected_agent_phase \(agent) "))
            #expect(script.contains("run_selected_update_phase \(agent) "))
        }
        #expect(script.contains("run_update_phase \"update-${agent}\" \"update_${agent}\""))
        #expect(script.contains("/var/lib/vetro"))
        #expect(script.contains("/var/log/vetro-provision.log"))
        #expect(script.contains("provision-status"))
        #expect(script.contains("PHASE:${current_phase}:FAIL rc=${rc}"))
        #expect(script.contains("PHASE:${phase}:SKIP"))
        #expect(script.contains("PHASE:all:DONE"))
        #expect(script.contains("PHASE:update:DONE"))
    }

    @Test("contains the official package and installer contracts")
    func containsInstallContracts() throws {
        let script = try loadScript()

        for package in [
            "git", "curl", "ripgrep", "build-essential", "python3", "rsync",
            "openssh-client", "ca-certificates", "gnupg",
        ] {
            #expect(script.contains("    \(package)\n"))
        }
        #expect(script.contains("https://deb.nodesource.com/setup_22.x"))
        #expect(script.contains("https://downloads.claude.ai/keys/claude-code.asc"))
        #expect(script.contains("https://downloads.claude.ai/claude-code/apt/latest"))
        #expect(script.contains("apt-get install -y claude-code"))
        #expect(script.contains("npm install -g @openai/codex"))
        #expect(!script.contains("npm install -g codex"))
        #expect(script.contains("https://x.ai/cli/install.sh | bash"))
        #expect(script.contains("sudo -u vetro"))
        #expect(script.contains("install -d -o vetro -g vetro /workspace"))
    }

    @Test("disables one-shot boot work but preserves sparse-disk trim")
    func containsBootPruningContract() throws {
        let script = try loadScript()

        #expect(script.contains("touch /etc/cloud/cloud-init.disabled"))
        #expect(script.contains("apt-daily.timer"))
        #expect(script.contains("apt-daily-upgrade.timer"))
        #expect(script.contains("man-db.timer"))
        #expect(script.contains("e2scrub_all.timer"))
        #expect(script.contains("systemctl disable --now \"${unit}\""))
        #expect(script.contains("systemctl mask \"${unit}\""))
        #expect(script.contains("Keep fstrim.timer enabled"))
        #expect(!script.contains("systemctl mask fstrim.timer"))
        #expect(!script.contains("disable_and_mask_timer fstrim.timer"))
        #expect(script.contains("systemd-analyze blame"))
        #expect(script.contains("head -20"))
        #expect(script.contains("true boot-time delta will be visible on the next boot"))
    }

    @Test("guards completed work before running mutating steps")
    func containsIdempotencyGuards() throws {
        let script = try loadScript()

        #expect(script.contains("set -euo pipefail"))
        #expect(script.contains("trap on_error ERR"))
        #expect(script.contains("phase_is_done"))
        #expect(script.contains("provisioning_is_complete"))
        #expect(script.contains("package_is_installed"))
        #expect(script.contains("node_is_compatible"))
        #expect(script.contains("claude_is_installed"))
        #expect(script.contains("codex_is_installed"))
        #expect(script.contains("grok_is_installed"))
        #expect(script.contains("[[ ! -e /etc/cloud/cloud-init.disabled ]]"))
        #expect(script.contains("grep -Fqx \"${GROK_PATH_LINE}\""))
        #expect(script.contains("/etc/vetro/agents.conf"))
        #expect(script.contains("load_selected_agents"))
        #expect(script.contains("agent_is_selected"))
        #expect(script.contains("skip_phase"))
    }

    @Test("isolates the custom phase from the ERR trap and still completes")
    func containsCustomPhaseIsolationContract() throws {
        let script = try loadScript()

        #expect(script.contains("/usr/local/lib/vetro/custom-setup.sh"))
        #expect(script.contains("${STATUS_DIRECTORY}/custom-script.log"))
        #expect(script.contains("custom-script.log"))
        #expect(script.contains("run_custom_phase"))
        #expect(script.contains("PHASE:custom:START"))
        #expect(script.contains("PHASE:custom:DONE"))
        #expect(script.contains("PHASE:custom:FAIL rc=${rc}"))
        #expect(script.contains("cd /home/vetro && exec /usr/local/lib/vetro/custom-setup.sh"))
        #expect(script.contains("sudo -u vetro bash -c"))

        let customPhase = try #require(script.range(of: "\nrun_custom_phase() {\n"))
        let customEnd = try #require(script.range(of: "\n}\n\nload_selected_agents\n"))
        let customBody = script[customPhase.lowerBound..<customEnd.upperBound]
        #expect(customBody.contains("trap - ERR"))
        #expect(customBody.contains("set +e"))
        #expect(customBody.contains("trap on_error ERR"))
        #expect(customBody.contains("PHASE:custom:FAIL rc=${rc}"))

        let customCall = try #require(script.range(of: "\nrun_custom_phase\n"))
        #expect(script[customCall.upperBound...].contains("append_marker \"PHASE:all:DONE\""))
    }

    @Test("supports single-agent update and rejects unknown names")
    func containsUpdateAgentModeContract() throws {
        let script = try loadScript()

        #expect(script.contains("update-agent"))
        #expect(script.contains("usage: provision.sh update-agent {claude|codex|grok}"))
        #expect(script.contains("unknown agent: ${agent}"))
        #expect(script.contains("is_known_agent"))
        #expect(script.contains("[[ \"${mode}\" == \"update-agent\" ]]"))
        #expect(script.contains("run_update_phase \"update-${agent}\" \"update_${agent}\""))
        #expect(script.contains("PHASE:update:DONE"))
    }

    @Test("heals and starts the vsock SSH bridge before completed-provisioning exit")
    func containsVsockSSHBridgeHealingContract() throws {
        let resources = try loadResources()
        let script = resources.provisionScript

        #expect(script.contains(resources.vsockSSHBridge))
        #expect(script.contains("cat >\"${bridge_script}\" <<'PYTHON'"))
        #expect(script.contains("cat >\"${bridge_unit}\" <<'UNIT'"))
        #expect(script.contains("After=network.target ssh.service sshd.service"))
        #expect(
            script.contains(
                "ExecStart=/usr/bin/python3 /usr/local/lib/vetro/vsock-ssh-bridge.py"
            )
        )
        #expect(script.contains("cmp -s \"${bridge_script}\""))
        #expect(script.contains("cmp -s \"${bridge_unit}\""))
        #expect(script.contains("systemctl enable --now vetro-vsock-ssh.service"))

        let ensureCall = try #require(script.range(of: "\nensure_vsock_ssh_bridge\n"))
        let completeGuard = try #require(script.range(of: "\nif provisioning_is_complete; then"))
        #expect(ensureCall.lowerBound < completeGuard.lowerBound)
    }

    @Test("heals and starts the vsock port bridge before completed-provisioning exit")
    func containsVsockPortBridgeHealingContract() throws {
        let resources = try loadResources()
        let script = resources.provisionScript

        #expect(script.contains(resources.vsockPortBridge))
        #expect(script.contains("cat >\"${bridge_script}\" <<'PYTHON'"))
        #expect(script.contains("cat >\"${bridge_unit}\" <<'UNIT'"))
        #expect(script.contains("After=network.target"))
        #expect(
            script.contains(
                "ExecStart=/usr/bin/python3 /usr/local/lib/vetro/vsock-port-bridge.py"
            )
        )
        #expect(script.contains("systemctl enable --now vetro-vsock-port.service"))

        let ensureCall = try #require(script.range(of: "\nensure_vsock_port_bridge\n"))
        let completeGuard = try #require(script.range(of: "\nif provisioning_is_complete; then"))
        #expect(ensureCall.lowerBound < completeGuard.lowerBound)
    }

    @Test("heals guest hook scripts and harness configs before completed-provisioning exit")
    func containsGuestHookHealingContract() throws {
        let resources = try loadResources()
        let script = resources.provisionScript

        #expect(script.contains(resources.hookPost))
        #expect(script.contains("cat >\"${hook_script}\" <<'HOOKPYTHON'"))
        #expect(script.contains("/usr/local/lib/vetro/vetro-hook-post.py"))
        #expect(script.contains("ln -sfn vetro-hook-post.py"))
        #expect(script.contains("prompt-submit stop notification session-end"))
        #expect(script.contains("vetro-hook-${event}"))
        #expect(
            script.contains(
                "sudo -H -u vetro /usr/bin/python3 /usr/local/lib/vetro/vetro-hook-post.py --install"
            )
        )

        let ensureCall = try #require(script.range(of: "\nensure_guest_hooks\n"))
        let completeGuard = try #require(script.range(of: "\nif provisioning_is_complete; then"))
        #expect(ensureCall.lowerBound < completeGuard.lowerBound)
    }

    @Test("heals and starts the port watcher before completed-provisioning exit")
    func containsPortwatchHealingContract() throws {
        let resources = try loadResources()
        let script = resources.provisionScript

        #expect(script.contains(resources.portwatch))
        #expect(script.contains("cat >\"${watch_script}\" <<'PYTHON'"))
        #expect(script.contains("cat >\"${watch_unit}\" <<'UNIT'"))
        #expect(script.contains("After=network.target"))
        #expect(
            script.contains(
                "ExecStart=/usr/bin/python3 /usr/local/lib/vetro/vetro-portwatch.py"
            )
        )
        #expect(script.contains("systemctl enable --now vetro-portwatch.service"))
        #expect(resources.portwatch.contains("vetro-refused "))
        #expect(resources.portwatch.contains("/dev/kmsg"))
        #expect(resources.portwatch.contains("\"refused\""))
        #expect(resources.portwatch.contains("nft"))

        let ensureCall = try #require(script.range(of: "\nensure_portwatch\n"))
        let completeGuard = try #require(script.range(of: "\nif provisioning_is_complete; then"))
        #expect(ensureCall.lowerBound < completeGuard.lowerBound)
    }

    @Test("heals and starts the vsock host reverse bridge before completed-provisioning exit")
    func containsVsockHostBridgeHealingContract() throws {
        let resources = try loadResources()
        let script = resources.provisionScript

        #expect(script.contains(resources.vsockHostBridge))
        #expect(script.contains("cat >\"${bridge_script}\" <<'PYTHON'"))
        #expect(script.contains("cat >\"${bridge_unit}\" <<'UNIT'"))
        #expect(script.contains("/etc/vetro/host-mirror.ports"))
        #expect(
            script.contains(
                "ExecStart=/usr/bin/python3 /usr/local/lib/vetro/vsock-host-bridge.py"
            )
        )
        #expect(script.contains("systemctl enable --now vetro-vsock-host.service"))

        let ensureCall = try #require(script.range(of: "\nensure_vsock_host_bridge\n"))
        let completeGuard = try #require(script.range(of: "\nif provisioning_is_complete; then"))
        #expect(ensureCall.lowerBound < completeGuard.lowerBound)
    }

    /// Loads the processed SwiftPM resource through the production bundle path.
    private func loadScript() throws -> String {
        try loadResources().provisionScript
    }

    private func loadResources() throws -> CloudInitSeed.GuestResources {
        let seed = CloudInitSeed(
            stateDirectory: StateDirectory(
                rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "ProvisionScriptTests-\(UUID().uuidString)",
                    isDirectory: true
                ),
                imagesDirectoryURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("ProvisionScriptTests-images", isDirectory: true)
            )
        )
        return try seed.loadGuestResources()
    }
}
