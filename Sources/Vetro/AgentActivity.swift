import Foundation

enum AgentHarness: String, Sendable {
    case claude, codex, grok

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .grok: "Grok"
        }
    }

    /// Maps a process/executable name (optionally a full path) to a harness.
    static func match(processName: String) -> AgentHarness? {
        let name = (processName as NSString).lastPathComponent.lowercased()
        if let harness = AgentHarness(rawValue: name) { return harness }
        if name.hasPrefix("claude") { return .claude }
        if name.hasPrefix("codex") { return .codex }
        if name.hasPrefix("grok") { return .grok }
        return nil
    }
}

/// Per-chat state: spinner while an agent runs, green (unread)
/// when it finishes, back to gray once the chat is opened.
enum ChatActivity: Equatable {
    case idle
    case working(AgentHarness)
    case finished
}

/// What a scan found for one session's shell subtree.
struct AgentPresence: Sendable, Equatable {
    let harness: AgentHarness
    /// Highest %CPU of any process in the subtree (agent + its tools) —
    /// a busy agent burns CPU; one idling at its prompt doesn't.
    let maxCPU: Double
}

/// Snapshot of the system process table, taken off the main thread.
struct ProcessScan: Sendable {
    let childrenByParent: [pid_t: [pid_t]]
    let harnessByPID: [pid_t: AgentHarness]
    let cpuByPID: [pid_t: Double]

    /// Whether `pid` lives in the subtree rooted at the session's shell.
    func contains(_ pid: pid_t, underShell root: pid_t) -> Bool {
        var queue = [root]
        var visited = Set<pid_t>()
        while let current = queue.popLast() {
            guard visited.insert(current).inserted else { continue }
            if current == pid { return true }
            queue.append(contentsOf: childrenByParent[current] ?? [])
        }
        return false
    }

    /// Agent presence in the subtree rooted at the session's shell.
    func agent(underShell root: pid_t) -> AgentPresence? {
        var queue = [root]
        var visited = Set<pid_t>()
        var harness: AgentHarness?
        var maxCPU = 0.0
        while let pid = queue.popLast() {
            guard visited.insert(pid).inserted else { continue }
            if pid != root {
                if harness == nil { harness = harnessByPID[pid] }
                maxCPU = max(maxCPU, cpuByPID[pid] ?? 0)
            }
            queue.append(contentsOf: childrenByParent[pid] ?? [])
        }
        guard let harness else { return nil }
        return AgentPresence(harness: harness, maxCPU: maxCPU)
    }

    static func take() -> ProcessScan {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,pcpu=,args="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else {
            return ProcessScan(childrenByParent: [:], harnessByPID: [:], cpuByPID: [:])
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var children: [pid_t: [pid_t]] = [:]
        var harnesses: [pid_t: AgentHarness] = [:]
        var cpus: [pid_t: Double] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count >= 4,
                  let pid = pid_t(fields[0]),
                  let ppid = pid_t(fields[1])
            else { continue }
            children[ppid, default: []].append(pid)
            cpus[pid] = Double(fields[2].replacingOccurrences(of: ",", with: ".")) ?? 0
            let command = String(fields[3].split(separator: " ", maxSplits: 1)[0])
            if let harness = AgentHarness.match(processName: command) {
                harnesses[pid] = harness
            }
        }
        return ProcessScan(childrenByParent: children, harnessByPID: harnesses, cpuByPID: cpus)
    }
}

/// Harnesses put an activity glyph at the front of the terminal title while
/// a turn runs (codex uses braille spinners / "⋮"). We use it as a precise
/// turn signal and strip it from the displayed chat name.
enum TitleActivity {
    private static let activeGlyphs = Set("✳✶✻✽✢⋮·◐◓◑◒○◍●⏳".unicodeScalars)
    private static let inertGlyphs = Set("✔✓✗✘".unicodeScalars)

    static func parse(_ raw: String) -> (title: String, active: Bool) {
        var scalars = Substring(raw).unicodeScalars
        var active = false
        var stripped = false
        while let first = scalars.first {
            if (0x2800...0x28FF).contains(first.value) || activeGlyphs.contains(first) {
                active = true
                stripped = true
                scalars.removeFirst()
            } else if inertGlyphs.contains(first) {
                stripped = true
                scalars.removeFirst()
            } else if first.properties.isWhitespace && stripped {
                scalars.removeFirst()
            } else {
                break
            }
        }
        return (String(scalars).trimmingCharacters(in: .whitespaces), active)
    }
}

/// Direct children of this app (each terminal session's `login` process).
func directChildPIDs() -> Set<pid_t> {
    let size = proc_listchildpids(getpid(), nil, 0)
    guard size > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(size))
    let count = proc_listchildpids(getpid(), &pids, size * Int32(MemoryLayout<pid_t>.size))
    guard count > 0 else { return [] }
    return Set(pids.prefix(Int(count)).filter { $0 > 0 })
}

@_silgen_name("proc_listchildpids")
private func proc_listchildpids(
    _ pid: pid_t,
    _ buffer: UnsafeMutableRawPointer?,
    _ buffersize: Int32
) -> Int32
