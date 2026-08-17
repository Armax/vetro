import Foundation
import Testing
@testable import VMKit

@Suite("Cloud-init seed rendering")
struct CloudInitSeedTests {
    @Test("renders the Vetro user, SSH policy, guest services, and metadata")
    func rendersGuestConfiguration() throws {
        let seed = CloudInitSeed(
            stateDirectory: StateDirectory(
                rootURL: URL(
                    fileURLWithPath: "/tmp/vetro-cloud-init-render-test",
                    isDirectory: true
                ),
                imagesDirectoryURL: URL(
                    fileURLWithPath: "/tmp/vetro-cloud-init-render-test-images",
                    isDirectory: true
                )
            )
        )
        let resources = try seed.loadGuestResources()
        let publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestFixtureKey vetro"

        let rendered = try seed.render(publicKey: publicKey, hostname: "dev-vm-1")

        #expect(rendered.userData.hasPrefix("#cloud-config\n"))
        #expect(rendered.userData.contains("hostname: dev-vm-1"))
        #expect(rendered.userData.contains("name: vetro"))
        #expect(rendered.userData.contains("shell: /bin/bash"))
        #expect(rendered.userData.contains("sudo: ALL=(ALL) NOPASSWD:ALL"))
        #expect(rendered.userData.contains("ssh_pwauth: false"))
        #expect(rendered.userData.contains(publicKey))
        #expect(
            rendered.userData.contains(
                "AcceptEnv CLAUDE_CODE_OAUTH_TOKEN GH_TOKEN GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL VETRO_CRED_VERSION"
            )
        )
        #expect(rendered.userData.contains("/etc/systemd/system/vetro-guest-agent.service"))
        #expect(
            rendered.userData.contains(
                "ExecStart=/usr/bin/python3 /usr/local/lib/vetro/guest-agent.py"
            )
        )
        #expect(rendered.userData.contains("[systemctl, enable, --now, vetro-guest-agent.service]"))
        #expect(rendered.userData.contains("/usr/local/lib/vetro/vsock-ssh-bridge.py"))
        #expect(rendered.userData.contains("/etc/systemd/system/vetro-vsock-ssh.service"))
        #expect(rendered.userData.contains("After=network.target ssh.service sshd.service"))
        #expect(
            rendered.userData.contains(
                "ExecStart=/usr/bin/python3 /usr/local/lib/vetro/vsock-ssh-bridge.py"
            )
        )
        #expect(rendered.userData.contains("[systemctl, enable, --now, vetro-vsock-ssh.service]"))
        #expect(rendered.userData.contains("/usr/local/lib/vetro/vsock-port-bridge.py"))
        #expect(rendered.userData.contains("/etc/systemd/system/vetro-vsock-port.service"))
        #expect(
            rendered.userData.contains(
                "ExecStart=/usr/bin/python3 /usr/local/lib/vetro/vsock-port-bridge.py"
            )
        )
        #expect(rendered.userData.contains("[systemctl, enable, --now, vetro-vsock-port.service]"))
        #expect(rendered.userData.contains("/usr/local/lib/vetro/vsock-host-bridge.py"))
        #expect(rendered.userData.contains("/etc/systemd/system/vetro-vsock-host.service"))
        #expect(
            rendered.userData.contains(
                "ExecStart=/usr/bin/python3 /usr/local/lib/vetro/vsock-host-bridge.py"
            )
        )
        #expect(rendered.userData.contains("[systemctl, enable, --now, vetro-vsock-host.service]"))
        #expect(rendered.userData.contains("/usr/local/lib/vetro/vetro-portwatch.py"))
        #expect(rendered.userData.contains("/etc/systemd/system/vetro-portwatch.service"))
        #expect(
            rendered.userData.contains(
                "ExecStart=/usr/bin/python3 /usr/local/lib/vetro/vetro-portwatch.py"
            )
        )
        #expect(rendered.userData.contains("[systemctl, enable, --now, vetro-portwatch.service]"))
        #expect(rendered.userData.contains("/usr/local/lib/vetro/vetro-hook-post.py"))
        #expect(!rendered.userData.contains("\npackages:"))
        #expect(!rendered.userData.contains("__VETRO_"))
        #expect(
            rendered.userData.contains(
                Data(resources.guestAgent.utf8).base64EncodedString()
            )
        )
        #expect(
            rendered.userData.contains(
                Data(resources.provisionScript.utf8).base64EncodedString()
            )
        )
        #expect(
            rendered.userData.contains(
                Data(resources.vsockSSHBridge.utf8).base64EncodedString()
            )
        )
        #expect(
            rendered.userData.contains(
                Data(resources.vsockPortBridge.utf8).base64EncodedString()
            )
        )
        #expect(
            rendered.userData.contains(
                Data(resources.vsockHostBridge.utf8).base64EncodedString()
            )
        )
        #expect(
            rendered.userData.contains(
                Data(resources.portwatch.utf8).base64EncodedString()
            )
        )
        #expect(resources.portwatch.contains("vetro-refused "))
        #expect(resources.portwatch.contains("/dev/kmsg"))
        #expect(resources.portwatch.contains("\"refused\""))
        #expect(
            rendered.userData.contains(
                Data(resources.hookPost.utf8).base64EncodedString()
            )
        )
        #expect(rendered.metaData.contains("instance-id: iid-vetro-1"))
        #expect(rendered.metaData.contains("local-hostname: dev-vm-1"))
        #expect(rendered.userData.contains("path: /etc/vetro/agents.conf"))
        #expect(rendered.userData.contains("\"claude codex grok\""))
        #expect(!rendered.userData.contains("/usr/local/lib/vetro/custom-setup.sh"))
        try assertParseableCloudConfig(rendered.userData)
    }

    @Test("writes the selected agent manifest and omits an empty custom script")
    func rendersAgentManifestWithoutCustomScript() throws {
        let seed = makeSeed()
        let rendered = try seed.render(
            publicKey: Self.publicKey,
            hostname: "dev-vm-1",
            installAgents: ["claude"],
            customScript: "  \n"
        )

        #expect(rendered.userData.contains("path: /etc/vetro/agents.conf"))
        #expect(rendered.userData.contains("\"claude\""))
        #expect(!rendered.userData.contains("\"claude codex grok\""))
        #expect(!rendered.userData.contains("/usr/local/lib/vetro/custom-setup.sh"))
        #expect(!rendered.userData.contains("__VETRO_"))
        try assertParseableCloudConfig(rendered.userData)
    }

    @Test("embeds a custom setup script as a base64 write_files entry")
    func embedsCustomSetupScript() throws {
        let seed = makeSeed()
        let script = "#!/bin/sh\necho ready\n"
        let rendered = try seed.render(
            publicKey: Self.publicKey,
            hostname: "dev-vm-1",
            installAgents: ["claude", "codex", "grok"],
            customScript: script
        )

        #expect(rendered.userData.contains("path: /usr/local/lib/vetro/custom-setup.sh"))
        #expect(rendered.userData.contains("permissions: '0755'"))
        #expect(rendered.userData.contains("encoding: b64"))
        #expect(rendered.userData.contains(Data(script.utf8).base64EncodedString()))
        #expect(rendered.userData.contains("\"claude codex grok\""))
        #expect(!rendered.userData.contains("__VETRO_"))
        try assertParseableCloudConfig(rendered.userData)
    }

    private func makeSeed() -> CloudInitSeed {
        CloudInitSeed(
            stateDirectory: StateDirectory(
                rootURL: URL(
                    fileURLWithPath: "/tmp/vetro-cloud-init-render-test",
                    isDirectory: true
                ),
                imagesDirectoryURL: URL(
                    fileURLWithPath: "/tmp/vetro-cloud-init-render-test-images",
                    isDirectory: true
                )
            )
        )
    }

    private static let publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestFixtureKey vetro"

    private func assertParseableCloudConfig(_ userData: String) throws {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby", isDirectory: false)
        process.arguments = [
            "-e",
            "require 'yaml'; YAML.safe_load($stdin.read)",
        ]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stdout
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: Data(userData.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "cloud-config YAML was not parseable: \(output)")
    }
}
