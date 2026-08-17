import Foundation
import Observation
import VMKit

/// Summarize providers from the design's git panel picker. `chatgpt` runs
/// through the codex CLI; both are pre-authenticated in the guest.
enum GitProvider: String, CaseIterable {
    case grok, chatgpt

    var displayName: String { self == .grok ? "Grok" : "ChatGPT" }
    var glyph: String { self == .grok ? "✦" : "⊙" }

    static let models: [GitProvider: [String]] = [
        .grok: ["grok-4.6", "grok-4-fast"],
        .chatgpt: ["gpt-5.6-luna", "gpt-5.6-terra"],
    ]

    func commandLine(model: String, prompt: String) -> String {
        let q = shellQuoted
        switch self {
        case .grok:
            return "grok -p \(q(prompt)) -m \(q(model)) --reasoning-effort high"
        case .chatgpt:
            // -o keeps stdout to the final message only (exec logs go to /dev/null).
            return """
            f=$(mktemp /tmp/vetro-sum.XXXXXX)
            codex exec -s read-only --color never -m \(q(model)) -o "$f" \(q(prompt)) >/dev/null
            st=$?
            cat "$f"; rm -f "$f"
            exit $st
            """
        }
    }
}

/// State for one session's git side panel: changed files, per-file diff,
/// history, and the summarize flow.
@MainActor
@Observable
final class GitPanelModel {
    enum Tab { case changes, history }
    enum SummaryState {
        case idle
        case running(provider: GitProvider, model: String)
        case done(GitSummary, provider: GitProvider, model: String)
        case error(String)
    }

    private(set) var isOpen = false
    private(set) var tab: Tab = .changes
    private(set) var hasRepo = false
    private(set) var branch: String?
    private(set) var files: [GitFileChange] = []
    private(set) var commits: [GitCommit] = []
    private(set) var selectedPath: String?
    private(set) var diffRows: [DiffRow] = []
    private(set) var summary: SummaryState = .idle

    private var sourceProvider: () -> (any GitSource)? = { nil }
    private weak var settings: AppSettings?
    private var loadedHistory = false

    var totalAdded: Int { files.map { max($0.added, 0) }.reduce(0, +) }
    var totalDeleted: Int { files.map { max($0.deleted, 0) }.reduce(0, +) }
    var countLabel: String { "\(files.count) files · +\(totalAdded) −\(totalDeleted)" }
    var selectedFile: GitFileChange? { files.first { $0.path == selectedPath } }

    var provider: GitProvider {
        GitProvider(rawValue: settings?.gitSummaryProvider ?? "") ?? .grok
    }

    func model(for provider: GitProvider) -> String {
        let stored = provider == .grok
            ? settings?.gitSummaryModelGrok
            : settings?.gitSummaryModelChatGPT
        let known = GitProvider.models[provider] ?? []
        if let stored, known.contains(stored) { return stored }
        return known.first ?? ""
    }

    var selectedModel: String { model(for: provider) }

    func pick(provider: GitProvider, model: String) {
        settings?.gitSummaryProvider = provider.rawValue
        if provider == .grok {
            settings?.gitSummaryModelGrok = model
        } else {
            settings?.gitSummaryModelChatGPT = model
        }
    }

    func configure(sourceProvider: @escaping () -> (any GitSource)?, settings: AppSettings) {
        self.sourceProvider = sourceProvider
        self.settings = settings
    }

    func toggle(tab newTab: Tab) {
        if isOpen && tab == newTab {
            isOpen = false
            return
        }
        tab = newTab
        isOpen = true
        Task {
            if newTab == .history {
                await refreshHistory(ifNeeded: true)
            } else {
                await refreshChanges()
            }
        }
    }

    func close() { isOpen = false }

    // MARK: Fetching

    func refreshChanges() async {
        guard let source = sourceProvider() else {
            hasRepo = false
            files = []
            return
        }
        let script = """
        cd \(shellQuoted(source.repoPath)) 2>/dev/null || { echo "@@VETRO_NOREPO@@"; exit 0; }
        git rev-parse --git-dir >/dev/null 2>&1 || { echo "@@VETRO_NOREPO@@"; exit 0; }
        printf '@@BRANCH@@\\n'; git branch --show-current 2>/dev/null
        printf '@@STATUS@@\\n'; git -c core.quotePath=false status --porcelain=v1 -z -uall 2>/dev/null
        printf '\\n@@NUMSTAT@@\\n'; git -c core.quotePath=false diff HEAD --numstat -M 2>/dev/null
        printf '@@END@@\\n'
        """
        guard let result = await source.exec(bashScript: script, timeoutSeconds: 15),
              result.status == 0, !result.stdout.contains("@@VETRO_NOREPO@@")
        else {
            hasRepo = false
            files = []
            return
        }
        hasRepo = true
        let out = result.stdout
        let branchText = section(of: out, from: "@@BRANCH@@\n", to: "@@STATUS@@\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        branch = branchText.isEmpty ? "HEAD" : branchText
        let status = section(of: out, from: "@@STATUS@@\n", to: "\n@@NUMSTAT@@\n")
        let numstat = section(of: out, from: "\n@@NUMSTAT@@\n", to: "@@END@@")
        files = GitDiffParser.parseStatus(porcelainZ: status, numstat: numstat)
        if selectedFile == nil { selectedPath = files.first?.path }
        if let selectedPath { await loadDiff(path: selectedPath) }
    }

    func select(path: String) {
        guard path != selectedPath else { return }
        selectedPath = path
        diffRows = []
        Task { await loadDiff(path: path) }
    }

    private func loadDiff(path: String) async {
        guard let source = sourceProvider(), let file = files.first(where: { $0.path == path })
        else { return }
        let q = shellQuoted
        let diffCommand = switch file.status {
        case .untracked:
            "git -c core.quotePath=false diff --no-index -- /dev/null \(q(path))"
        case .renamed where file.oldPath != nil:
            // Both paths in the pathspec, or -M can't pair the rename.
            "git -c core.quotePath=false diff HEAD -M -- \(q(file.oldPath!)) \(q(path))"
        default:
            "git -c core.quotePath=false diff HEAD -M -- \(q(path))"
        }
        let script = "cd \(q(source.repoPath)) && { \(diffCommand) 2>/dev/null; true; }"
        guard let result = await source.exec(bashScript: script, timeoutSeconds: 15) else { return }
        guard selectedPath == path else { return }
        diffRows = GitDiffParser.parseUnifiedDiff(result.stdout)
    }

    func refreshHistory(ifNeeded: Bool = false) async {
        if ifNeeded && loadedHistory { return }
        guard let source = sourceProvider() else { return }
        let script = """
        cd \(shellQuoted(source.repoPath)) 2>/dev/null || exit 0
        git -c core.quotePath=false log -n 50 --no-color \
          --pretty=format:'%x1e%H%x1f%h%x1f%an%x1f%ar%x1f%s' --numstat 2>/dev/null
        """
        guard let result = await source.exec(bashScript: script, timeoutSeconds: 15) else { return }
        commits = GitDiffParser.parseLog(result.stdout)
        loadedHistory = true
    }

    // MARK: Summarize

    func summarize() async {
        if case .running = summary { return }
        guard let source = sourceProvider(), !files.isEmpty else { return }
        let provider = provider
        let model = selectedModel
        summary = .running(provider: provider, model: model)

        let q = shellQuoted
        let untracked = files.filter { $0.status == .untracked }
            .map { "git -c core.quotePath=false diff --no-index -- /dev/null \(q($0.path)) 2>/dev/null;" }
            .joined(separator: " ")
        let diffScript = """
        cd \(q(source.repoPath)) 2>/dev/null || exit 0
        git -c core.quotePath=false diff HEAD 2>/dev/null
        \(untracked)
        true
        """
        guard let diffResult = await source.exec(bashScript: diffScript, timeoutSeconds: 30),
              !diffResult.stdout.isEmpty
        else {
            summary = .error("Could not read the diff.")
            return
        }
        var diff = diffResult.stdout
        let maxDiffLength = 200_000
        if diff.count > maxDiffLength {
            diff = String(diff.prefix(maxDiffLength)) + "\n[diff truncated]"
        }

        let prompt = """
        You are summarizing a git diff for a code-review side panel.
        Respond with ONLY a single JSON object, no prose, no markdown fences.
        Schema: {"headline": string (one plain sentence, at most 80 characters), \
        "bullets": [{"path": string, "text": string}], "note": string|null}
        One bullet per meaningfully-changed file (group trivial ones); "text" is a terse \
        present-tense description of what changed in that file. "note" is one sentence on \
        behavior impact or caveats, or null.
        Branch: \(branch ?? "HEAD"). \(countLabel).

        The unified diff follows:

        \(diff)
        """
        let script = "cd \(q(source.repoPath)) 2>/dev/null; \(provider.commandLine(model: model, prompt: prompt))"
        guard let result = await source.exec(bashScript: script, timeoutSeconds: 180) else {
            summary = .error("The VM is not reachable.")
            return
        }
        guard case .running = summary else { return }
        if result.status == 124 {
            summary = .error("\(model) timed out.")
            return
        }
        guard result.status == 0 else {
            let tail = result.stderr.split(separator: "\n").suffix(2).joined(separator: " ")
            summary = .error(tail.isEmpty ? "\(model) failed (status \(result.status))." : tail)
            return
        }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            summary = .error("\(model) returned no output.")
            return
        }
        summary = .done(GitDiffParser.parseSummary(output), provider: provider, model: model)
    }

    func clearSummary() { summary = .idle }

    var summaryPlainText: String? {
        guard case .done(let sum, _, _) = summary else { return nil }
        if let raw = sum.rawFallback { return raw }
        var lines = [sum.headline]
        lines.append(contentsOf: sum.bullets.map { "• \($0.path) — \($0.text)" })
        if let note = sum.note, !note.isEmpty { lines.append(note) }
        return lines.joined(separator: "\n")
    }

    private func section(of text: String, from start: String, to end: String) -> String {
        guard let startRange = text.range(of: start) else { return "" }
        let tail = text[startRange.upperBound...]
        guard let endRange = tail.range(of: end) else { return String(tail) }
        return String(tail[..<endRange.lowerBound])
    }
}
