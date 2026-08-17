import Testing
@testable import VMKit

@Suite("Guest provisioning marker parsing")
struct ProvisioningStatusTests {
    @Test("empty marker content is entirely pending")
    func parsesEmptyContent() {
        let status = VMProvisioningStatus.parse(markerText: "")

        #expect(status.operation == .provisioning)
        #expect(!status.isComplete)
        #expect(status.failedPhase == nil)
        #expect(status.activePhases.allSatisfy { status.state(for: $0) == .pending })
    }

    @Test("partial content distinguishes done, running, and pending phases")
    func parsesPartialContent() {
        let status = VMProvisioningStatus.parse(
            markerText: """
            ignored diagnostic output
            PHASE:apt-base:START
            PHASE:apt-base:DONE
            PHASE:node:START

            """
        )

        #expect(status.state(for: .aptBase) == .done)
        #expect(status.state(for: .node) == .running)
        #expect(status.state(for: .claude) == .pending)
        #expect(!status.isComplete)
    }

    @Test("a failure marker identifies its phase")
    func parsesFailure() {
        let status = VMProvisioningStatus.parse(
            markerText: """
            PHASE:apt-base:DONE
            PHASE:node:START
            PHASE:node:FAIL rc=37

            """
        )

        #expect(status.state(for: .node) == .failed)
        #expect(status.failedPhase == .node)
        #expect(!status.isComplete)
    }

    @Test("the aggregate all marker completes initial provisioning")
    func parsesCompleteProvisioning() {
        let status = VMProvisioningStatus.parse(
            markerText: """
            PHASE:apt-base:DONE
            PHASE:node:DONE
            PHASE:claude:DONE
            PHASE:codex:DONE
            PHASE:grok:DONE
            PHASE:workdir:DONE
            PHASE:prune:DONE
            PHASE:all:DONE

            """
        )

        #expect(status.operation == .provisioning)
        #expect(status.isComplete)
        #expect(status.failedPhase == nil)
    }

    @Test("a later phase start supersedes an older aggregate completion")
    func resetsCompletionForLaterAttempt() {
        let status = VMProvisioningStatus.parse(
            markerText: """
            PHASE:all:DONE
            PHASE:node:START

            """
        )

        #expect(status.state(for: .node) == .running)
        #expect(!status.isComplete)
    }

    @Test("update markers supersede prior completion and support retries")
    func parsesUpdateMarkers() {
        let failedUpdate = VMProvisioningStatus.parse(
            markerText: """
            PHASE:all:DONE
            PHASE:update-claude:DONE
            PHASE:update-codex:DONE
            PHASE:update-grok:DONE
            PHASE:update:DONE
            PHASE:update-claude:START
            PHASE:update-claude:DONE
            PHASE:update-codex:START
            PHASE:update-codex:FAIL rc=9

            """
        )

        #expect(failedUpdate.operation == .update)
        #expect(failedUpdate.state(for: .updateClaude) == .done)
        #expect(failedUpdate.state(for: .updateCodex) == .failed)
        #expect(failedUpdate.state(for: .updateGrok) == .pending)
        #expect(failedUpdate.failedPhase == .updateCodex)
        #expect(!failedUpdate.isComplete)

        let completedRetry = VMProvisioningStatus.parse(
            markerText: """
            PHASE:update-claude:START
            PHASE:update-claude:FAIL rc=1
            PHASE:update-claude:START
            PHASE:update-claude:DONE
            PHASE:update-codex:START
            PHASE:update-codex:DONE
            PHASE:update-grok:START
            PHASE:update-grok:DONE
            PHASE:update:DONE

            """
        )

        #expect(completedRetry.operation == .update)
        #expect(completedRetry.activePhases.allSatisfy {
            completedRetry.state(for: $0) == .done
        })
        #expect(completedRetry.failedPhase == nil)
        #expect(completedRetry.isComplete)
    }

    @Test("SKIP markers are terminal and distinct from pending or failed")
    func parsesSkippedPhases() {
        let status = VMProvisioningStatus.parse(
            markerText: """
            PHASE:apt-base:DONE
            PHASE:node:DONE
            PHASE:claude:DONE
            PHASE:codex:SKIP
            PHASE:grok:SKIP
            PHASE:workdir:DONE
            PHASE:prune:DONE
            PHASE:all:DONE

            """
        )

        #expect(status.state(for: .claude) == .done)
        #expect(status.state(for: .codex) == .skipped)
        #expect(status.state(for: .grok) == .skipped)
        #expect(status.state(for: .custom) == .pending)
        #expect(status.isComplete)
        #expect(status.failedPhase == nil)
        #expect(!status.customScriptFailed)
        #expect(VMProvisioningPhase.custom.displayName == "Custom script")
    }

    @Test("a failed custom phase still completes provisioning")
    func customFailureDoesNotFailProvisioning() {
        let status = VMProvisioningStatus.parse(
            markerText: """
            PHASE:apt-base:DONE
            PHASE:node:DONE
            PHASE:claude:SKIP
            PHASE:codex:DONE
            PHASE:grok:SKIP
            PHASE:workdir:DONE
            PHASE:prune:DONE
            PHASE:custom:START
            PHASE:custom:FAIL rc=7
            PHASE:all:DONE

            """
        )

        #expect(status.operation == .provisioning)
        #expect(status.state(for: .claude) == .skipped)
        #expect(status.state(for: .custom) == .failed)
        #expect(status.customScriptFailed)
        #expect(status.isComplete)
        #expect(status.failedPhase == nil)
    }

    @Test("mixed skip, fail, and retry markers keep later events authoritative")
    func parsesMixedSkipAndRetrySequences() {
        let inProgress = VMProvisioningStatus.parse(
            markerText: """
            PHASE:apt-base:DONE
            PHASE:node:DONE
            PHASE:claude:SKIP
            PHASE:codex:START
            PHASE:codex:FAIL rc=2
            PHASE:grok:SKIP

            """
        )

        #expect(inProgress.state(for: .claude) == .skipped)
        #expect(inProgress.state(for: .codex) == .failed)
        #expect(inProgress.state(for: .grok) == .skipped)
        #expect(inProgress.failedPhase == .codex)
        #expect(!inProgress.isComplete)
        #expect(!inProgress.customScriptFailed)

        let retried = VMProvisioningStatus.parse(
            markerText: """
            PHASE:codex:FAIL rc=2
            PHASE:codex:START
            PHASE:codex:DONE
            PHASE:custom:START
            PHASE:custom:FAIL rc=1
            PHASE:all:DONE
            PHASE:update-claude:SKIP
            PHASE:update-codex:START
            PHASE:update-codex:DONE
            PHASE:update-grok:SKIP
            PHASE:update:DONE

            """
        )

        #expect(retried.operation == .update)
        #expect(retried.state(for: .updateClaude) == .skipped)
        #expect(retried.state(for: .updateCodex) == .done)
        #expect(retried.state(for: .updateGrok) == .skipped)
        #expect(retried.state(for: .custom) == .failed)
        #expect(retried.customScriptFailed)
        #expect(retried.isComplete)
        #expect(retried.failedPhase == nil)
    }
}
