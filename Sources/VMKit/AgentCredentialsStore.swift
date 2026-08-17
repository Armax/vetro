import CryptoKit
import Foundation
import Security

/// A credential used by an agent or its guest development tools.
public enum VMAgentKey: CaseIterable, Hashable, Sendable {
    /// Claude Code's OAuth token.
    case claudeOAuthToken

    /// GitHub's command-line token.
    case githubToken

    /// The Git author name.
    case gitUserName

    /// The Git author email.
    case gitUserEmail

    /// The environment variable consumed by this credential's guest tool.
    public var environmentVariable: String {
        switch self {
        case .claudeOAuthToken:
            "CLAUDE_CODE_OAUTH_TOKEN"
        case .githubToken:
            "GH_TOKEN"
        case .gitUserName:
            "GIT_AUTHOR_NAME"
        case .gitUserEmail:
            "GIT_AUTHOR_EMAIL"
        }
    }
}

/// The credentials made available to guest agent sessions.
public struct GuestCredentials: Sendable, Equatable {
    public var claudeOAuthToken: String?
    public var githubToken: String?
    public var gitUserName: String?
    public var gitUserEmail: String?

    /// Creates guest credentials.
    public init(
        claudeOAuthToken: String? = nil,
        githubToken: String? = nil,
        gitUserName: String? = nil,
        gitUserEmail: String? = nil
    ) {
        self.claudeOAuthToken = claudeOAuthToken
        self.githubToken = githubToken
        self.gitUserName = gitUserName
        self.gitUserEmail = gitUserEmail
    }
}

/// The schema version included in guest credential content versions.
public let guestCredentialsSchemaVersion = 1

/// Stores agent credentials without exposing a persistence mechanism to callers.
public protocol VMAgentCredentialsStoring: Sendable {
    /// Loads the credential for an agent.
    ///
    /// - Parameter key: The credential to load.
    /// - Returns: The stored credential, or `nil` when none exists.
    func get(_ key: VMAgentKey) async throws -> String?

    /// Stores the credential for an agent, or deletes it when `value` is empty.
    ///
    /// - Parameters:
    ///   - value: The credential to persist. An empty value selects no-key mode.
    ///   - key: The credential to store.
    func set(_ value: String, for key: VMAgentKey) async throws

    /// Deletes the credential for an agent.
    ///
    /// - Parameter key: The credential to remove.
    func delete(_ key: VMAgentKey) async throws

    /// Builds the environment used for guest agent sessions.
    ///
    /// - Returns: Only non-empty credentials, keyed by their environment variables.
    func agentEnvironment() async throws -> [String: String]

    /// Removes credentials stored by older Vetro versions.
    func deleteLegacyAPIKeys() async throws
}

extension VMAgentCredentialsStoring {
    /// Builds the environment used for guest agent sessions.
    ///
    /// - Returns: Only non-empty credentials, keyed by their environment variables.
    public func agentEnvironment() async throws -> [String: String] {
        var environment: [String: String] = [:]
        for key in VMAgentKey.allCases {
            guard let value = try await get(key), !value.isEmpty else { continue }
            environment[key.environmentVariable] = value
        }
        return environment
    }

    /// Removes credentials stored by older Vetro versions.
    public func deleteLegacyAPIKeys() async throws {}

    /// Loads the credentials used by guest agent sessions.
    ///
    /// - Returns: Guest credentials with empty stored values omitted.
    public func guestCredentials() async throws -> GuestCredentials {
        func nonEmpty(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            return value
        }

        return GuestCredentials(
            claudeOAuthToken: nonEmpty(try await get(.claudeOAuthToken)),
            githubToken: nonEmpty(try await get(.githubToken)),
            gitUserName: nonEmpty(try await get(.gitUserName)),
            gitUserEmail: nonEmpty(try await get(.gitUserEmail))
        )
    }
}

/// Renders the guest environment file for the supplied credentials.
public func renderEnvFile(_ credentials: GuestCredentials) -> String {
    let fields: [(String, String?)] = [
        (VMAgentKey.claudeOAuthToken.environmentVariable, credentials.claudeOAuthToken),
        (VMAgentKey.githubToken.environmentVariable, credentials.githubToken),
        (VMAgentKey.gitUserName.environmentVariable, credentials.gitUserName),
        (VMAgentKey.gitUserEmail.environmentVariable, credentials.gitUserEmail),
    ]
    let lines = fields.compactMap { name, value -> String? in
        guard let value, !value.isEmpty else { return nil }
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "export \(name)='\(escaped)'"
    }
    return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
}

/// Renders a GitHub credential helper entry for a token.
public func renderGitCredentialsLine(token: String) -> String? {
    guard !token.isEmpty else { return nil }
    return "https://x-access-token:\(token)@github.com"
}

/// Computes the stable guest credential content version.
public func contentVersion(_ credentials: GuestCredentials) -> String {
    let values = [
        credentials.claudeOAuthToken,
        credentials.githubToken,
        credentials.gitUserName,
        credentials.gitUserEmail,
    ].map { value -> String in
        guard let value else { return "0:" }
        return "1:\(value.utf8.count):\(value)"
    }
    let material = (["schema:\(guestCredentialsSchemaVersion)"] + values)
        .joined(separator: "\u{0}")
    let digest = SHA256.hash(data: Data(material.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// Merges onboarding and trusted-project state into Claude's JSON settings.
public func mergeClaudeJSON(_ existing: String, trustedProjectPaths: [String]) -> String {
    var root = (try? JSONSerialization.jsonObject(with: Data(existing.utf8))) as? [String: Any]
        ?? [:]
    root["hasCompletedOnboarding"] = true

    if !trustedProjectPaths.isEmpty {
        var projects = root["projects"] as? [String: Any] ?? [:]
        for path in trustedProjectPaths {
            var project = projects[path] as? [String: Any] ?? [:]
            project["hasTrustDialogAccepted"] = true
            projects[path] = project
        }
        root["projects"] = projects
    }

    guard let data = try? JSONSerialization.data(
        withJSONObject: root,
        options: [.prettyPrinted, .sortedKeys]
    ) else {
        return "{}"
    }
    return String(decoding: data, as: UTF8.self)
}

/// Stores agent credentials as macOS Keychain generic-password items.
public actor KeychainAgentCredentialsStore: VMAgentCredentialsStoring {
    private struct KeychainFailure: Error, Sendable {
        let status: OSStatus
    }

    private static let service = "vetro.agent-keys"
    private static let legacyAccounts = [
        "ANTHROPIC_API_KEY",
        "OPENAI_API_KEY",
        "XAI_API_KEY",
    ]

    /// Creates a Keychain-backed credential store.
    public init() {}

    /// Loads the credential for an agent.
    ///
    /// - Parameter key: The credential to load.
    /// - Returns: The stored credential, or `nil` when no item exists.
    public func get(_ key: VMAgentKey) throws -> String? {
        var query = Self.baseQuery(for: key)
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainFailure(status: status)
        }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            throw KeychainFailure(status: errSecDecode)
        }
        return value
    }

    /// Stores the credential for an agent, or deletes it when `value` is empty.
    ///
    /// - Parameters:
    ///   - value: The credential to persist. An empty value selects no-key mode.
    ///   - key: The credential to store.
    public func set(_ value: String, for key: VMAgentKey) throws {
        guard !value.isEmpty else {
            try delete(key)
            return
        }

        let data = Data(value.utf8)
        let query = Self.baseQuery(for: key)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainFailure(status: updateStatus)
        }

        var item = query
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(
                query as CFDictionary,
                attributes as CFDictionary
            )
            guard retryStatus == errSecSuccess else {
                throw KeychainFailure(status: retryStatus)
            }
            return
        }
        guard addStatus == errSecSuccess else {
            throw KeychainFailure(status: addStatus)
        }
    }

    /// Deletes the credential for an agent.
    ///
    /// - Parameter key: The credential to remove.
    public func delete(_ key: VMAgentKey) throws {
        let status = SecItemDelete(Self.baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainFailure(status: status)
        }
    }

    /// Removes credentials stored by older Vetro versions.
    public func deleteLegacyAPIKeys() throws {
        for account in Self.legacyAccounts {
            let status = SecItemDelete(Self.baseQuery(account: account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainFailure(status: status)
            }
        }
    }

    private nonisolated static func baseQuery(for key: VMAgentKey) -> [CFString: Any] {
        baseQuery(account: key.environmentVariable)
    }

    private nonisolated static func baseQuery(account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
        ]
    }
}
