import Foundation
import Testing
@testable import VMKit

@Suite("SSH invocation construction")
struct SSHClientTests {
    @Test("forwarded destinations use loopback, port, and a stable host-key alias")
    func constructsForwardedDestinationArguments() {
        let client = makeClient()
        let invocation = client.destinationDescription(
            ip: "192.168.64.3",
            port: 49_152
        )

        #expect(invocation.last == "vetro@127.0.0.1")
        #expect(invocation.contains("HostKeyAlias=vetro-vm"))
        let portOption = invocation.firstIndex(of: "-p")
        #expect(portOption != nil)
        if let portOption {
            #expect(invocation[portOption + 1] == "49152")
        }
    }

    @Test("direct destinations retain the guest IP without forwarded options")
    func constructsDirectDestinationArguments() {
        let client = makeClient()
        let invocation = client.destinationDescription(ip: "192.168.64.3")

        #expect(invocation.last == "vetro@192.168.64.3")
        #expect(!invocation.contains("-p"))
        #expect(!invocation.contains("HostKeyAlias=vetro-vm"))
    }

    @Test("identityFile overrides the per-VM private key and defaults stay unchanged")
    func identityFileOverride() {
        let client = makeClient()
        let defaultInvocation = client.destinationDescription(ip: "192.0.2.8")
        let identity = URL(fileURLWithPath: "/tmp/golden-access_ed25519", isDirectory: false)
        let overridden = client.destinationDescription(
            ip: "192.0.2.8",
            identityFile: identity
        )

        let defaultIdentityIndex = defaultInvocation.firstIndex(of: "-i")
        #expect(defaultIdentityIndex != nil)
        if let defaultIdentityIndex {
            #expect(defaultInvocation[defaultIdentityIndex + 1].hasSuffix("id_ed25519"))
        }
        let overrideIndex = overridden.firstIndex(of: "-i")
        #expect(overrideIndex != nil)
        if let overrideIndex {
            #expect(overridden[overrideIndex + 1] == identity.path)
        }
    }

    @Test("all environment assignments ride one SetEnv option in stable key order")
    func constructsStableEnvironmentArguments() {
        let client = makeClient()
        let invocation = client.destinationDescription(
            ip: "192.0.2.8",
            environment: [
                "XAI_API_KEY": "x-key",
                "OPENAI_API_KEY": "o-key",
                "ANTHROPIC_API_KEY": "a-key",
            ]
        )
        let setEnvArguments = invocation.filter { $0.hasPrefix("SetEnv=") }

        // OpenSSH honors only the first -o SetEnv= per invocation, so every
        // assignment must share a single option.
        #expect(
            setEnvArguments == [
                "SetEnv=ANTHROPIC_API_KEY=a-key OPENAI_API_KEY=o-key XAI_API_KEY=x-key"
            ]
        )
        #expect(invocation.last == "vetro@192.0.2.8")
        let index = invocation.firstIndex(of: setEnvArguments[0])!
        #expect(invocation[index - 1] == "-o")
        #expect(index < invocation.count - 1)
    }

    @Test("SetEnv quotes a value with spaces inside the combined option")
    func quotesEnvironmentValuesWithSpaces() {
        let client = makeClient()
        let invocation = client.destinationDescription(
            ip: "192.0.2.9",
            environment: [
                "GH_TOKEN": "plain",
                "OPENAI_API_KEY": "value with spaces",
            ]
        )

        #expect(
            invocation.contains(#"SetEnv=GH_TOKEN=plain OPENAI_API_KEY="value with spaces""#)
        )
    }

    @Test("diagnostic redaction masks every SetEnv value")
    func redactsEnvironmentValues() {
        let client = makeClient()
        let invocation = client.destinationDescription(
            ip: "192.0.2.10",
            environment: [
                "ANTHROPIC_API_KEY": "anthropic-secret",
                "OPENAI_API_KEY": "open ai secret",
                "QUOTED": #"back\slash "and quote"#,
            ]
        )
        let redacted = SSHClient.redactedInvocation(invocation)
        let rendered = redacted.joined(separator: " ")

        #expect(!rendered.contains("anthropic-secret"))
        #expect(!rendered.contains("open ai secret"))
        #expect(!rendered.contains("slash"))
        #expect(
            redacted.contains(
                "SetEnv=ANTHROPIC_API_KEY=<redacted> OPENAI_API_KEY=<redacted> QUOTED=<redacted>"
            )
        )
    }

    /// Creates an SSH client whose paths need not exist for pure argv construction.
    private func makeClient() -> SSHClient {
        SSHClient(
            stateDirectory: StateDirectory(
                rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "SSHClientTests-\(UUID().uuidString)",
                    isDirectory: true
                ),
                imagesDirectoryURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("SSHClientTests-images", isDirectory: true)
            )
        )
    }
}
