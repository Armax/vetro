import Foundation
import Testing
@testable import VMKit

@Suite("Guest hook-post script")
struct GuestHookPostTests {
    @Test("posts the hook-server wire format and installs harness configs")
    func installsHarnessConfigsAndExitsWithoutSession() throws {
        let script = try CloudInitSeed.hookPostScript()
        #expect(script.contains("HOST_PORT = 1025"))
        #expect(script.contains("VETRO_SESSION_ID"))
        #expect(script.contains("AF_VSOCK"))
        #expect(script.contains("UserPromptSubmit"))
        #expect(script.contains("SessionEnd"))

        let fileManager = FileManager()
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "GuestHookPostTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let scriptURL = root.appendingPathComponent("vetro-hook-post.py")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let home = root.appendingPathComponent("home", isDirectory: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)

        try runPython(
            arguments: [scriptURL.path, "--install"],
            environment: ["HOME": home.path]
        )

        let claude = try readJSON(home.appendingPathComponent(".claude/settings.json"))
        let claudeHooks = try #require(claude["hooks"] as? [String: Any])
        #expect(claudeHooks["UserPromptSubmit"] != nil)
        #expect(claudeHooks["Stop"] != nil)
        #expect(claudeHooks["Notification"] != nil)
        #expect(claudeHooks["SessionEnd"] == nil)

        let codex = try readJSON(home.appendingPathComponent(".codex/hooks.json"))
        let codexHooks = try #require(codex["hooks"] as? [String: Any])
        #expect(codexHooks["UserPromptSubmit"] != nil)
        #expect(codexHooks["Stop"] != nil)
        #expect(codexHooks["SessionEnd"] != nil)
        #expect(codexHooks["Notification"] == nil)
        let toml = try String(
            contentsOf: home.appendingPathComponent(".codex/config.toml"),
            encoding: .utf8
        )
        #expect(toml.contains("[hooks]"))
        #expect(!toml.contains("hooks = true"))

        let grok = try readJSON(home.appendingPathComponent(".grok/hooks/vetro-session.json"))
        let grokHooks = try #require(grok["hooks"] as? [String: Any])
        #expect(grokHooks["UserPromptSubmit"] != nil)
        #expect(grokHooks["Stop"] != nil)
        #expect(grokHooks["SessionEnd"] != nil)
        #expect(grokHooks["Notification"] != nil)

        let unset = try runPython(
            arguments: [scriptURL.path, "prompt-submit"],
            environment: ["HOME": home.path],
            stdin: "{\"cwd\":\"/tmp\"}\n"
        )
        #expect(unset.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "{}")
        #expect(unset.status == 0)
    }

    @Test("migrates a legacy boolean hooks sentinel to a table")
    func migratesLegacyCodexSentinel() throws {
        let script = try CloudInitSeed.hookPostScript()
        let fileManager = FileManager()
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "GuestHookPostTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        try fileManager.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let scriptURL = root.appendingPathComponent("vetro-hook-post.py")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let configURL = codexHome.appendingPathComponent("config.toml")
        try "\n# >>> vetro hooks >>>\nhooks = true\n# <<< vetro hooks <<<\n"
            .write(to: configURL, atomically: true, encoding: .utf8)

        try runPython(
            arguments: [scriptURL.path, "--install"],
            environment: ["HOME": home.path]
        )

        let toml = try String(contentsOf: configURL, encoding: .utf8)
        #expect(toml.contains("[hooks]"))
        #expect(!toml.contains("hooks = true"))
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    @discardableResult
    private func runPython(
        arguments: [String],
        environment: [String: String],
        stdin: String = ""
    ) throws -> (status: Int32, stdout: String) {
        let process = Process()
        let stdout = Pipe()
        let stdinPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = arguments
        var merged = ProcessInfo.processInfo.environment
        merged.removeValue(forKey: "VETRO_SESSION_ID")
        for (key, value) in environment {
            merged[key] = value
        }
        process.environment = merged
        process.standardOutput = stdout
        process.standardError = stdout
        process.standardInput = stdinPipe
        try process.run()
        if !stdin.isEmpty {
            try stdinPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
        }
        try stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "python3 failed: \(output)")
        return (process.terminationStatus, output)
    }
}
