import Foundation

/// Installs Vetro's lifecycle hooks into the harness configs:
/// per-event script files (direct-exec runtimes like codex don't run a shell,
/// so no args/inline snippets), marker-based idempotent merges, never
/// clobbering user entries, skipping writes when nothing changed.
enum HookInstaller {
    /// Ownership marker: any hook command containing this substring is ours.
    static let marker = "vetro-hook"
    static let events = ["prompt-submit", "stop", "notification", "session-end"]

    /// Script dir deliberately has no spaces in its path (codex execs the
    /// command string directly).
    static var scriptDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vetro", isDirectory: true)
    }

    static func scriptPath(_ event: String) -> String {
        scriptDirectory.appendingPathComponent("vetro-hook-\(event).sh").path
    }

    private static let sentinelBegin = "# >>> vetro hooks >>>"
    private static let sentinelEnd = "# <<< vetro hooks <<<"

    static func installAll() {
        writeScripts()
        installClaude()
        installCodex()
        installGrok()
    }

    static func uninstallAll() {
        removeHooks(fromJSONAt: claudeSettingsURL)
        removeHooks(fromJSONAt: codexHooksURL)
        try? FileManager.default.removeItem(at: grokHooksFileURL)
        removeCodexSentinel()
    }

    // MARK: Paths

    private static var claudeSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    private static var codexHome: URL {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"] {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    private static var codexHooksURL: URL { codexHome.appendingPathComponent("hooks.json") }
    private static var codexConfigURL: URL { codexHome.appendingPathComponent("config.toml") }

    private static var grokHooksDir: URL {
        if let env = ProcessInfo.processInfo.environment["GROK_HOME"] {
            return URL(fileURLWithPath: env).appendingPathComponent("hooks")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/hooks")
    }

    private static var grokHooksFileURL: URL {
        grokHooksDir.appendingPathComponent("vetro-session.json")
    }

    // MARK: Scripts

    private static func writeScripts() {
        try? FileManager.default.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)
        for event in events {
            let script = """
            #!/bin/sh
            # vetro-hook v2 — reports harness lifecycle events to the Vetro app.
            # Safe no-op outside Vetro chats or when Vetro isn't running.
            [ "$VETRO_HOOKS_DISABLED" = 1 ] && { echo '{}'; exit 0; }
            SOCK="${VETRO_SOCK:-$HOME/Library/Application Support/Vetro/hook.sock}"
            [ -S "$SOCK" ] || { echo '{}'; exit 0; }
            payload=$(head -c 4096 2>/dev/null | tr -d '\\n\\t')
            # Walk up to the harness process so Vetro knows who fired the hook
            # and can drop events from agents it does not own.
            hname=""; hpid=""; pid=$PPID; i=0
            while [ $i -lt 6 ] && [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
              name=$(/bin/ps -o comm= -p "$pid" 2>/dev/null); name=${name##*/}
              case "$name" in
                claude*|codex*|grok*) hname="$name"; hpid="$pid"; break;;
              esac
              pid=$(/bin/ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
              i=$((i+1))
            done
            printf '%s\\t%s\\t%s\\t%s\\t%s\\n' "${VETRO_SESSION_ID:-}" "\(event)" "$payload" "$hname" "$hpid" \\
              | /usr/bin/nc -U -w 1 "$SOCK" >/dev/null 2>&1
            echo '{}'
            exit 0
            """
            let path = scriptPath(event)
            let existing = try? String(contentsOfFile: path, encoding: .utf8)
            if existing != script {
                try? script.write(toFile: path, atomically: true, encoding: .utf8)
            }
            chmod(path, 0o755)
        }
    }

    // MARK: Shared JSON hook merge

    /// Hook group in the shape all three harnesses accept.
    private static func group(_ event: String, matcher: Bool) -> [String: Any] {
        var g: [String: Any] = [
            "hooks": [["type": "command", "command": scriptPath(event), "timeout": 5]]
        ]
        if matcher { g["matcher"] = "" }
        return g
    }

    /// Removes our entries from an event's group array, preserving user hooks.
    private static func strippingOurs(_ groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { g in
            var g = g
            var inner = g["hooks"] as? [[String: Any]] ?? []
            let hadOurs = inner.contains { ($0["command"] as? String)?.contains(marker) == true }
            inner.removeAll { ($0["command"] as? String)?.contains(marker) == true }
            if inner.isEmpty && hadOurs { return nil }
            g["hooks"] = inner
            return g
        }
    }

    private static func merge(events eventMap: [(event: String, arg: String)], matcher: Bool, into root: inout [String: Any]) {
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, arg) in eventMap {
            var groups = strippingOurs(hooks[event] as? [[String: Any]] ?? [])
            groups.append(group(arg, matcher: matcher))
            hooks[event] = groups
        }
        root["hooks"] = hooks
    }

    private static func readJSON(_ url: URL) -> [String: Any]?? {
        guard let data = try? Data(contentsOf: url) else { return .some(nil) } // missing file
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil // invalid JSON — caller must abort, never clobber
        }
        return obj
    }

    private static func writeJSONIfChanged(_ root: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return }
        if let existing = try? Data(contentsOf: url), existing == data { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    private static func removeHooks(fromJSONAt url: URL) {
        guard case .some(.some(var root)) = readJSON(url) else { return }
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let stripped = strippingOurs(groups)
            if stripped.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = stripped
            }
        }
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        writeJSONIfChanged(root, to: url)
    }

    // MARK: Per-harness installs

    private static func installClaude() {
        guard case .some(let existing) = readJSON(claudeSettingsURL) else { return }
        var root = existing ?? [:]
        merge(
            events: [("UserPromptSubmit", "prompt-submit"), ("Stop", "stop"), ("Notification", "notification")],
            matcher: true,
            into: &root
        )
        writeJSONIfChanged(root, to: claudeSettingsURL)
    }

    private static func installCodex() {
        guard case .some(let existing) = readJSON(codexHooksURL) else { return }
        var root = existing ?? [:]
        merge(
            events: [("UserPromptSubmit", "prompt-submit"), ("Stop", "stop"), ("SessionEnd", "session-end")],
            matcher: false,
            into: &root
        )
        writeJSONIfChanged(root, to: codexHooksURL)
        ensureCodexSentinel()
    }

    private static func installGrok() {
        var root: [String: Any] = [:]
        merge(
            events: [
                ("UserPromptSubmit", "prompt-submit"), ("Stop", "stop"),
                ("SessionEnd", "session-end"), ("Notification", "notification"),
            ],
            matcher: false,
            into: &root
        )
        writeJSONIfChanged(root, to: grokHooksFileURL)
    }

    // MARK: codex config.toml feature flag

    private static func ensureCodexSentinel() {
        // codex >= 0.147 types `hooks` as a table; the old `hooks = true`
        // boolean fails config parsing, so managed blocks migrate to an
        // empty `[hooks]` table (0.147 reads hooks.json without any flag).
        let text = (try? String(contentsOf: codexConfigURL, encoding: .utf8)) ?? ""
        var outside = text
        var managedRange: Range<String.Index>?
        if let begin = text.range(of: sentinelBegin),
           let end = text.range(of: sentinelEnd)
        {
            let range = begin.lowerBound..<end.upperBound
            managedRange = range
            outside.removeSubrange(range)
        }
        let hasTable = outside.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("[hooks]")
        }
        let body = hasTable ? "" : "[hooks]\n"
        let block = "\(sentinelBegin)\n\(body)\(sentinelEnd)"
        if let managedRange {
            var updated = text
            updated.replaceSubrange(managedRange, with: block)
            guard updated != text else { return }
            try? updated.write(to: codexConfigURL, atomically: true, encoding: .utf8)
            return
        }
        // Respect an existing hooks flag or table, whatever its value.
        let hasFlag = text.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("hooks")
                && $0.contains("=")
        }
        guard !hasFlag, !hasTable else { return }
        try? (text + "\n" + block + "\n").write(
            to: codexConfigURL, atomically: true, encoding: .utf8
        )
    }

    private static func removeCodexSentinel() {
        guard var text = try? String(contentsOf: codexConfigURL, encoding: .utf8),
              let begin = text.range(of: sentinelBegin),
              let end = text.range(of: sentinelEnd)
        else { return }
        text.removeSubrange(begin.lowerBound..<text.index(end.upperBound, offsetBy: 0))
        try? text.write(to: codexConfigURL, atomically: true, encoding: .utf8)
    }
}
