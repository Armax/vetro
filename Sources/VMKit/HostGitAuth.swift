import Foundation

/// Git and GitHub authentication detected from this Mac's command-line tools.
///
/// Every field is read fresh from this Mac at push time by running `gh` and
/// `git`, so rotation is picked up automatically without a copy living in
/// Vetro's Keychain.
public struct HostGitAuth: Sendable, Equatable {
    /// The GitHub token from `gh auth token`.
    public var githubToken: String?

    /// The Git author name from `git config --global user.name`.
    public var gitUserName: String?

    /// The Git author email from `git config --global user.email`.
    public var gitUserEmail: String?

    /// Creates a host Git authentication bundle.
    public init(
        githubToken: String? = nil,
        gitUserName: String? = nil,
        gitUserEmail: String? = nil
    ) {
        self.githubToken = githubToken
        self.gitUserName = gitUserName
        self.gitUserEmail = gitUserEmail
    }

    /// Whether every source was absent or unreadable.
    public var isEmpty: Bool {
        githubToken == nil && gitUserName == nil && gitUserEmail == nil
    }
}

/// Reads Git and GitHub authentication from this Mac's command-line tools.
///
/// Errors — a missing tool, a nonzero exit, an unreadable value — resolve to
/// `nil` silently, so detection failure just leaves a field unset.
public enum HostGitAuthReader {
    /// Reads the GitHub token from `gh auth token`, or `nil` when unavailable.
    public static func githubToken() -> String? {
        commandOutput(["gh", "auth", "token"])
    }

    /// Reads the Git author name from `git config --global user.name`.
    public static func gitUserName() -> String? {
        commandOutput(["git", "config", "--global", "user.name"])
    }

    /// Reads the Git author email from `git config --global user.email`.
    public static func gitUserEmail() -> String? {
        commandOutput(["git", "config", "--global", "user.email"])
    }

    /// Detects all Git and GitHub authentication available on this Mac.
    public static func detect() -> HostGitAuth {
        HostGitAuth(
            githubToken: githubToken(),
            gitUserName: gitUserName(),
            gitUserEmail: gitUserEmail()
        )
    }

    /// Runs a command through `/usr/bin/env` and returns its trimmed stdout.
    ///
    /// Resolving through `env` locates the tool on the user's `PATH`. A launch
    /// failure or nonzero exit resolves to `nil`.
    private static func commandOutput(_ arguments: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let value = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
