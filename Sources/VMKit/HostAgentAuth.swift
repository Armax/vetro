import CryptoKit
import Foundation
import Security

/// The host agent authentication material transferred into a guest at boot.
///
/// Every field is read fresh from this Mac at push time, so token rotation is
/// picked up automatically without a second copy living in Vetro's Keychain.
public struct HostAgentAuthBundle: Sendable, Equatable {
    /// Claude Code's login-Keychain credentials JSON blob.
    public var claudeCredentialsJSON: String?

    /// Codex's `~/.codex/auth.json` contents.
    public var codexAuthJSON: String?

    /// Grok's `~/.grok/auth.json` contents.
    public var grokAuthJSON: String?

    /// Grok's `~/.grok/agent_id` contents.
    public var grokAgentID: String?

    /// Creates a host agent authentication bundle.
    public init(
        claudeCredentialsJSON: String? = nil,
        codexAuthJSON: String? = nil,
        grokAuthJSON: String? = nil,
        grokAgentID: String? = nil
    ) {
        self.claudeCredentialsJSON = claudeCredentialsJSON
        self.codexAuthJSON = codexAuthJSON
        self.grokAuthJSON = grokAuthJSON
        self.grokAgentID = grokAgentID
    }

    /// Whether every source was absent, denied, or unreadable.
    public var isEmpty: Bool {
        claudeCredentialsJSON == nil
            && codexAuthJSON == nil
            && grokAuthJSON == nil
            && grokAgentID == nil
    }
}

/// The schema version included in host agent auth content versions.
public let hostAgentAuthSchemaVersion = 1

/// Reads agent authentication from this Mac's file-based sources.
///
/// Errors — a missing file, a denied Keychain prompt, a decode failure — resolve
/// to `nil` silently and never retry, so one "Always Allow" makes the Keychain
/// read a one-time approval.
public enum HostAgentAuthReader {
    /// Reads Claude Code's credentials JSON from the login Keychain.
    ///
    /// The item lives in the file-based login keychain, so
    /// `kSecUseDataProtectionKeychain` is deliberately left unset. The query
    /// matches by service only. A not-found, cancelled, or auth-denied status
    /// resolves to `nil` without a retry to avoid repeated prompts.
    public static func claudeCredentialsJSON() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "Claude Code-credentials",
            kSecReturnData: kCFBooleanTrue as Any,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    /// Reads Codex's `~/.codex/auth.json`, or `nil` when it is absent.
    public static func codexAuthJSON() -> String? {
        readHomeFile(".codex/auth.json")
    }

    /// Reads Grok's `~/.grok/auth.json`, or `nil` when it is absent.
    public static func grokAuthJSON() -> String? {
        readHomeFile(".grok/auth.json")
    }

    /// Reads Grok's `~/.grok/agent_id`, or `nil` when it is absent.
    public static func grokAgentID() -> String? {
        readHomeFile(".grok/agent_id")
    }

    /// Reads only the auth sources for the selected agents.
    ///
    /// - Parameter agents: The normalized agent names to read auth for.
    /// - Returns: A bundle populated with each present, readable source.
    public static func bundle(forAgents agents: [String]) -> HostAgentAuthBundle {
        let selected = Set(agents)
        var bundle = HostAgentAuthBundle()
        if selected.contains("claude") {
            bundle.claudeCredentialsJSON = claudeCredentialsJSON()
        }
        if selected.contains("codex") {
            bundle.codexAuthJSON = codexAuthJSON()
        }
        if selected.contains("grok") {
            bundle.grokAuthJSON = grokAuthJSON()
            bundle.grokAgentID = grokAgentID()
        }
        return bundle
    }

    /// Reads a file relative to this user's home directory.
    private static func readHomeFile(_ relativePath: String) -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url),
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }
}

/// Computes the stable content version of a host agent auth bundle.
public func authContentVersion(_ bundle: HostAgentAuthBundle) -> String {
    let values = [
        bundle.claudeCredentialsJSON,
        bundle.codexAuthJSON,
        bundle.grokAuthJSON,
        bundle.grokAgentID,
    ].map { value -> String in
        guard let value else { return "0:" }
        return "1:\(value.utf8.count):\(value)"
    }
    let material = (["auth-schema:\(hostAgentAuthSchemaVersion)"] + values)
        .joined(separator: "\u{0}")
    let digest = SHA256.hash(data: Data(material.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}
