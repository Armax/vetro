/// A durable guest-provisioning or agent-update phase.
public enum VMProvisioningPhase: String, CaseIterable, Sendable {
    /// Installs the baseline Debian packages.
    case aptBase = "apt-base"

    /// Installs a system-wide Node.js 22 or newer runtime.
    case node

    /// Installs the Claude Code CLI.
    case claude

    /// Installs the OpenAI Codex CLI.
    case codex

    /// Installs the xAI Grok CLI.
    case grok

    /// Creates the guest project working directory.
    case workdir

    /// Disables one-shot boot work while preserving trim.
    case prune

    /// Runs the optional per-VM custom setup script.
    case custom

    /// Marks the complete initial-provisioning operation.
    case all

    /// Updates the Claude Code CLI.
    case updateClaude = "update-claude"

    /// Updates the OpenAI Codex CLI.
    case updateCodex = "update-codex"

    /// Updates the xAI Grok CLI.
    case updateGrok = "update-grok"

    /// Marks the complete agent-update operation.
    case update

    /// The human-readable label for this phase.
    public var displayName: String {
        switch self {
        case .aptBase: "Base tools"
        case .node: "Node.js"
        case .claude: "Claude"
        case .codex: "Codex"
        case .grok: "Grok"
        case .workdir: "Workspace"
        case .prune: "Cleanup"
        case .custom: "Custom script"
        case .all: "Provisioning"
        case .updateClaude: "Update Claude"
        case .updateCodex: "Update Codex"
        case .updateGrok: "Update Grok"
        case .update: "Update agents"
        }
    }
}

/// A parsed snapshot of the guest's persistent provisioning marker file.
///
/// ```swift
/// let status = VMProvisioningStatus.parse(
///     markerText: "PHASE:apt-base:DONE\nPHASE:node:START\n"
/// )
/// let nodeState = status.state(for: .node)
/// ```
public struct VMProvisioningStatus: Sendable, Equatable {
    /// The state most recently recorded for one provisioning phase.
    public enum PhaseState: String, Sendable {
        /// The phase has not started.
        case pending

        /// A start marker exists without a later terminal marker.
        case running

        /// The phase completed successfully.
        case done

        /// The phase's latest terminal marker records a failure.
        case failed

        /// The phase was intentionally omitted and is treated as complete.
        case skipped
    }

    /// The operation represented by the latest recognized marker.
    public enum Operation: Sendable {
        /// The initial guest toolbox installation.
        case provisioning

        /// An explicit refresh of the installed agent CLIs.
        case update
    }

    /// The operation represented by this snapshot.
    public let operation: Operation

    /// The latest state of every known marker phase.
    public let phaseStates: [VMProvisioningPhase: PhaseState]

    /// The ordered work phases belonging to ``operation``.
    public var activePhases: [VMProvisioningPhase] {
        switch operation {
        case .provisioning:
            Self.provisioningPhases
        case .update:
            Self.updatePhases
        }
    }

    /// Whether the active operation's aggregate completion marker is present.
    public var isComplete: Bool {
        switch operation {
        case .provisioning:
            state(for: .all) == .done
        case .update:
            state(for: .update) == .done
        }
    }

    /// Whether the optional custom setup script recorded a failure.
    ///
    /// A failed custom phase does not make the aggregate provisioning state failed.
    public var customScriptFailed: Bool {
        state(for: .custom) == .failed
    }

    /// The first failed active phase in execution order, if one exists.
    ///
    /// A failed ``VMProvisioningPhase/custom`` phase is ignored here so a
    /// script error cannot fail the VM.
    public var failedPhase: VMProvisioningPhase? {
        guard !isComplete else { return nil }
        if let phase = activePhases.first(where: {
            $0 != .custom && state(for: $0) == .failed
        }) {
            return phase
        }
        let aggregate: VMProvisioningPhase = operation == .provisioning ? .all : .update
        return state(for: aggregate) == .failed ? aggregate : nil
    }

    /// Returns the latest state for a phase, defaulting to pending.
    ///
    /// - Parameter phase: The phase to inspect.
    /// - Returns: Its latest parsed marker state.
    public func state(for phase: VMProvisioningPhase) -> PhaseState {
        phaseStates[phase] ?? .pending
    }

    /// Returns the latest state for a phase, defaulting to pending.
    ///
    /// - Parameter phase: The phase to inspect.
    public subscript(phase: VMProvisioningPhase) -> PhaseState {
        state(for: phase)
    }

    /// Parses append-only `PHASE:<name>:<event>` markers into a current snapshot.
    ///
    /// Unknown and malformed lines are ignored. Repeated markers are applied in
    /// file order, so a retry's later `START` or `DONE` supersedes an earlier
    /// failure. A new `update-claude:START` begins a fresh update operation even
    /// when the file contains a completed older update.
    ///
    /// - Parameter markerText: The complete `/var/lib/vetro/provision-status` content.
    /// - Returns: A deterministic snapshot; empty content yields all phases pending.
    public static func parse(markerText: String) -> VMProvisioningStatus {
        var states = Dictionary(
            uniqueKeysWithValues: VMProvisioningPhase.allCases.map { ($0, PhaseState.pending) }
        )
        var operation = Operation.provisioning

        for rawLine in markerText.split(whereSeparator: \Character.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let fields = line.split(
                separator: ":",
                maxSplits: 2,
                omittingEmptySubsequences: false
            )
            guard fields.count == 3,
                  fields[0] == "PHASE",
                  let phase = VMProvisioningPhase(rawValue: String(fields[1]))
            else {
                continue
            }

            let event = String(fields[2])
            operation = Self.operation(for: phase)
            if event == "START" {
                switch operation {
                case .update:
                    if phase == .updateClaude {
                        for updatePhase in updatePhases + [.update] {
                            states[updatePhase] = .pending
                        }
                    } else if states[.update] == .done {
                        states[.update] = .pending
                    }
                case .provisioning:
                    if phase != .all, states[.all] == .done {
                        states[.all] = .pending
                    }
                }
            }

            switch event {
            case "START":
                states[phase] = .running
            case "DONE":
                states[phase] = .done
            case "SKIP":
                states[phase] = .skipped
            default:
                if event == "FAIL" || event.hasPrefix("FAIL ") {
                    states[phase] = .failed
                }
            }
        }

        return VMProvisioningStatus(operation: operation, phaseStates: states)
    }

    private static let provisioningPhases: [VMProvisioningPhase] = [
        .aptBase,
        .node,
        .claude,
        .codex,
        .grok,
        .workdir,
        .prune,
        .custom,
    ]

    private static let updatePhases: [VMProvisioningPhase] = [
        .updateClaude,
        .updateCodex,
        .updateGrok,
    ]

    /// Selects the operation whose progress includes a marker phase.
    private static func operation(for phase: VMProvisioningPhase) -> Operation {
        switch phase {
        case .updateClaude, .updateCodex, .updateGrok, .update:
            .update
        case .aptBase, .node, .claude, .codex, .grok, .workdir, .prune, .custom, .all:
            .provisioning
        }
    }
}
