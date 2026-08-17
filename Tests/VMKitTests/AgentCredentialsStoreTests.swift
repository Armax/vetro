import Foundation
import Testing
@testable import VMKit

@Suite("Agent credentials")
struct AgentCredentialsStoreTests {
    @Test(
        "agent keys map to their guest environment variables",
        arguments: [
            (VMAgentKey.claudeOAuthToken, "CLAUDE_CODE_OAUTH_TOKEN"),
            (VMAgentKey.githubToken, "GH_TOKEN"),
            (VMAgentKey.gitUserName, "GIT_AUTHOR_NAME"),
            (VMAgentKey.gitUserEmail, "GIT_AUTHOR_EMAIL"),
        ]
    )
    func environmentVariableMapping(key: VMAgentKey, expected: String) {
        #expect(key.environmentVariable == expected)
    }

    @Test("agentEnvironment returns only non-empty stored credentials")
    func environmentComposition() async throws {
        let store = InMemoryAgentCredentialsStore(values: [
            .claudeOAuthToken: "claude-test-value",
            .githubToken: "",
            .gitUserName: "Vetro",
            .gitUserEmail: "vetro@example.com",
        ])

        let environment = try await store.agentEnvironment()

        #expect(environment == [
            "CLAUDE_CODE_OAUTH_TOKEN": "claude-test-value",
            "GIT_AUTHOR_NAME": "Vetro",
            "GIT_AUTHOR_EMAIL": "vetro@example.com",
        ])
    }

    @Test("guestCredentials omits empty stored values")
    func guestCredentialsComposition() async throws {
        let store = InMemoryAgentCredentialsStore(values: [
            .claudeOAuthToken: "claude-test-value",
            .githubToken: "",
            .gitUserName: "Vetro",
            .gitUserEmail: "",
        ])

        let credentials = try await store.guestCredentials()
        #expect(credentials == GuestCredentials(
            claudeOAuthToken: "claude-test-value",
            gitUserName: "Vetro"
        ))
    }

    @Test("renderEnvFile writes ordered, escaped exports and omits empty fields")
    func rendersEnvironmentFile() {
        let credentials = GuestCredentials(
            claudeOAuthToken: "it's-a-token",
            githubToken: "github-token",
            gitUserName: "Vetro",
            gitUserEmail: ""
        )

        let expected = "export CLAUDE_CODE_OAUTH_TOKEN='it'\\''s-a-token'\n"
            + "export GH_TOKEN='github-token'\n"
            + "export GIT_AUTHOR_NAME='Vetro'\n"
        #expect(renderEnvFile(credentials) == expected)
    }

    @Test("renderEnvFile is empty without credentials")
    func rendersEmptyEnvironmentFile() {
        #expect(renderEnvFile(GuestCredentials()) == "")
    }

    @Test("renderGitCredentialsLine renders a GitHub token entry")
    func rendersGitCredentialsLine() {
        #expect(renderGitCredentialsLine(token: "github-token") == "https://x-access-token:github-token@github.com")
        #expect(renderGitCredentialsLine(token: "") == nil)
    }

    @Test("contentVersion is stable and changes with credentials")
    func contentVersionIsStable() {
        let credentials = GuestCredentials(
            claudeOAuthToken: "claude-token",
            githubToken: "github-token"
        )
        let version = contentVersion(credentials)

        #expect(version == contentVersion(credentials))
        #expect(version != contentVersion(GuestCredentials(
            claudeOAuthToken: "different-token",
            githubToken: "github-token"
        )))
        #expect(version.count == 64)
    }

    @Test("authContentVersion is deterministic and changes with the bundle")
    func authContentVersionIsStable() {
        let bundle = HostAgentAuthBundle(
            claudeCredentialsJSON: "{\"token\":\"claude\"}",
            codexAuthJSON: "{\"token\":\"codex\"}"
        )
        let version = authContentVersion(bundle)

        #expect(version == authContentVersion(bundle))
        #expect(version != authContentVersion(HostAgentAuthBundle(
            claudeCredentialsJSON: "{\"token\":\"different\"}",
            codexAuthJSON: "{\"token\":\"codex\"}"
        )))
        #expect(version != authContentVersion(HostAgentAuthBundle()))
        #expect(version.count == 64)
    }

    @Test("mergeClaudeJSON preserves settings and trusts projects")
    func mergesClaudeJSON() throws {
        let existing = """
        {"other": {"value": 1}, "projects": {"/workspace/existing": {"note": "keep"}}}
        """
        let merged = mergeClaudeJSON(
            existing,
            trustedProjectPaths: ["/workspace/existing", "/workspace/new"]
        )

        #expect(mergeClaudeJSON(
            merged,
            trustedProjectPaths: ["/workspace/existing", "/workspace/new"]
        ) == merged)
        let root = try #require(
            JSONSerialization.jsonObject(with: Data(merged.utf8)) as? [String: Any]
        )
        #expect(root["hasCompletedOnboarding"] as? Bool == true)
        #expect((root["other"] as? [String: Any])?["value"] as? Int == 1)
        let projects = try #require(root["projects"] as? [String: Any])
        #expect((projects["/workspace/existing"] as? [String: Any])?["note"] as? String == "keep")
        #expect((projects["/workspace/existing"] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool == true)
        #expect((projects["/workspace/new"] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool == true)
    }

    @Test("mergeClaudeJSON uses an empty object for malformed input")
    func mergesMalformedClaudeJSON() throws {
        let merged = mergeClaudeJSON("not-json", trustedProjectPaths: ["/workspace/project"])
        let root = try #require(
            JSONSerialization.jsonObject(with: Data(merged.utf8)) as? [String: Any]
        )
        #expect(root["hasCompletedOnboarding"] as? Bool == true)
        #expect((root["projects"] as? [String: Any])?["/workspace/project"] as? [String: Any] != nil)
    }
}

private actor InMemoryAgentCredentialsStore: VMAgentCredentialsStoring {
    private var values: [VMAgentKey: String]

    init(values: [VMAgentKey: String] = [:]) {
        self.values = values
    }

    func get(_ key: VMAgentKey) -> String? {
        values[key]
    }

    func set(_ value: String, for key: VMAgentKey) {
        if value.isEmpty {
            values.removeValue(forKey: key)
        } else {
            values[key] = value
        }
    }

    func delete(_ key: VMAgentKey) {
        values.removeValue(forKey: key)
    }
}
