import XCTest

@testable import CCBar

/// E2E tests verifying the full pipeline:
/// Events → SessionManager → IconState determination
///
/// Key invariants:
/// - Hook mode: Notification(permission_prompt) → permissionWaiting → instant red speech bubble (urgent)
/// - JSONL fallback: Permission timeout (7s) → waitingPermission → red speech bubble (urgent)
/// - Turn ended (processing done, awaiting next input) → waitingTurnEnd → white speech bubble (waiting)
final class IconStateE2ETests: XCTestCase {
    var manager: SessionManager!

    override func setUp() {
        super.setUp()
        manager = SessionManager()
    }

    override func tearDown() {
        manager.stop()
        super.tearDown()
    }

    private func iconState() -> MenuBarController.IconState {
        MenuBarController.determineIconState(from: manager.getAllSessions())
    }

    // MARK: - Permission Timeout → Red Speech Bubble (urgent)

    func testPermissionTimeout_showsRedBubble() {
        // Tool starts → 7s timeout fires → waitingPermission → urgent (red bubble)
        manager.handleEventSync(.toolUseStarted(sessionId: "s1", toolUseId: "t1", toolName: "Bash", cwd: "/project"))
        XCTAssertEqual(iconState(), .active, "Tool running → active (terminal icon)")

        // Simulate timer fire: manually send events to reach waitingPermission
        // Since handleEventSync doesn't trigger async timers, simulate the state after timeout
        simulatePermissionTimeout(sessionId: "s1")

        XCTAssertEqual(iconState(), .urgent, "Permission timeout → urgent (RED speech bubble)")
        XCTAssertEqual(manager.getSession("s1")?.status, .waitingPermission)
        XCTAssertEqual(manager.getSession("s1")?.waitingReason, .permissionTimeout)
    }

    func testPermissionTimeout_thenApproved_returnsToActive() {
        manager.handleEventSync(.toolUseStarted(sessionId: "s1", toolUseId: "t1", toolName: "Write", cwd: "/project"))
        simulatePermissionTimeout(sessionId: "s1")
        XCTAssertEqual(iconState(), .urgent, "Timed out → red bubble")

        // User approves → toolUseCompleted
        manager.handleEventSync(.toolUseCompleted(sessionId: "s1", toolUseId: "t1", cwd: nil))
        XCTAssertEqual(iconState(), .active, "Approved → back to active")
        XCTAssertEqual(manager.getSession("s1")?.status, .active)
    }

    func testPermissionTimeout_thenRejected_returnsToActive() {
        manager.handleEventSync(.toolUseStarted(sessionId: "s1", toolUseId: "t1", toolName: "Bash", cwd: "/project"))
        simulatePermissionTimeout(sessionId: "s1")
        XCTAssertEqual(iconState(), .urgent)

        // User rejects → toolUseCompleted (same event for reject)
        manager.handleEventSync(.toolUseCompleted(sessionId: "s1", toolUseId: "t1", cwd: nil))
        XCTAssertEqual(iconState(), .active)
    }

    func testPermissionTimeout_withAsyncTimer() {
        // Test the actual 7-second async timer fires correctly
        let expectation = XCTestExpectation(description: "permission timeout fires")

        manager.onSessionChanged = { session in
            if session.status == .waitingPermission {
                expectation.fulfill()
            }
        }

        manager.handleEventSync(.toolUseStarted(sessionId: "s1", toolUseId: "t1", toolName: "Edit", cwd: "/project"))
        XCTAssertEqual(manager.getSession("s1")?.status, .active)

        // Wait for 7s timer to fire
        wait(for: [expectation], timeout: 10.0)

        XCTAssertEqual(manager.getSession("s1")?.status, .waitingPermission)
        XCTAssertEqual(iconState(), .urgent, "7s async timer → red bubble")
    }

    func testToolCompletedBeforeTimeout_noRedBubble() {
        // Tool completes within 7s → should never become urgent
        manager.handleEventSync(.toolUseStarted(sessionId: "s1", toolUseId: "t1", toolName: "Read", cwd: "/project"))
        XCTAssertEqual(iconState(), .active)

        // Tool completes quickly (before 7s timer)
        manager.handleEventSync(.toolUseCompleted(sessionId: "s1", toolUseId: "t1", cwd: nil))
        XCTAssertEqual(iconState(), .active, "Completed before timeout → stays active, no red bubble")

        // Wait a bit to ensure timer was cancelled and doesn't fire
        let noTimeout = XCTestExpectation(description: "no timeout should fire")
        noTimeout.isInverted = true

        manager.onSessionChanged = { session in
            if session.status == .waitingPermission {
                noTimeout.fulfill()  // Should NOT happen
            }
        }

        wait(for: [noTimeout], timeout: 8.0)
    }

    // MARK: - Hook-based Permission Detection (instant, no 7s delay)

    func testPermissionWaitingEvent_showsRedBubble() {
        // Hook sends permissionWaiting directly → instant red bubble
        manager.handleEventSync(.toolUseStarted(sessionId: "s1", toolUseId: "t1", toolName: "Bash", cwd: "/project"))
        XCTAssertEqual(iconState(), .active)

        manager.handleEventSync(.permissionWaiting(sessionId: "s1", cwd: "/project"))
        XCTAssertEqual(iconState(), .urgent, "Hook permissionWaiting → instant RED bubble (no 7s delay)")
        XCTAssertEqual(manager.getSession("s1")?.status, .waitingPermission)
    }

    func testPermissionWaitingEvent_thenApproved_returnsToActive() {
        manager.handleEventSync(.permissionWaiting(sessionId: "s1", cwd: "/project"))
        XCTAssertEqual(iconState(), .urgent)

        manager.handleEventSync(.toolUseCompleted(sessionId: "s1", toolUseId: "hook-abc", cwd: nil))
        XCTAssertEqual(iconState(), .active)
    }

    func testPermissionWaitingEvent_thenTurnEnd_showsWhiteBubble() {
        // Hook: permissionWaiting → approve → turn ends → white bubble
        manager.handleEventSync(.toolUseStarted(sessionId: "s1", toolUseId: "t1", toolName: "Bash", cwd: "/project"))
        manager.handleEventSync(.permissionWaiting(sessionId: "s1", cwd: "/project"))
        XCTAssertEqual(iconState(), .urgent)

        manager.handleEventSync(.toolUseCompleted(sessionId: "s1", toolUseId: "hook-abc", cwd: nil))
        XCTAssertEqual(iconState(), .active)

        manager.handleEventSync(.turnEnded(sessionId: "s1", durationMs: 1000, cwd: nil))
        XCTAssertEqual(iconState(), .waiting, "After permission approved and turn ended → WHITE bubble")
    }

    func testHookMode_noTimerFires_permissionWaitingOnly() {
        // With hookActive, permission detection is instant, no 7s delay
        manager.setHookActive(true)

        manager.handleEventSync(.toolUseStarted(sessionId: "s1", toolUseId: "t1", toolName: "Bash", cwd: "/project"))
        XCTAssertEqual(iconState(), .active, "Tool started → active")

        // Without permissionWaiting event, stays active (no timer)
        // With permissionWaiting event, goes urgent instantly
        manager.handleEventSync(.permissionWaiting(sessionId: "s1", cwd: "/project"))
        XCTAssertEqual(iconState(), .urgent, "Hook permissionWaiting → instant urgent")
    }

    // MARK: - Hook-based Multi-Session Priority

    func testMultiSession_hookPermissionWaiting_takesPriority() {
        // Session 1: turn ended (white)
        manager.handleEventSync(.turnEnded(sessionId: "s1", durationMs: 1000, cwd: "/project-a"))
        XCTAssertEqual(iconState(), .waiting)

        // Session 2: hook permissionWaiting (red) → should override
        manager.handleEventSync(.permissionWaiting(sessionId: "s2", cwd: "/project-b"))
        XCTAssertEqual(iconState(), .urgent, "Hook permissionWaiting takes priority over waiting")
    }

    func testMultiSession_hookPermissionCleared_fallsBackToWaiting() {
        // Session 1: waiting (white)
        manager.handleEventSync(.turnEnded(sessionId: "s1", durationMs: 1000, cwd: "/project-a"))

        // Session 2: hook permissionWaiting (red)
        manager.handleEventSync(.permissionWaiting(sessionId: "s2", cwd: "/project-b"))
        XCTAssertEqual(iconState(), .urgent)

        // Session 2 approved
        manager.handleEventSync(.toolUseCompleted(sessionId: "s2", toolUseId: "hook-ok", cwd: nil))
        XCTAssertEqual(iconState(), .waiting, "Hook permission cleared → falls back to white bubble from s1")
    }

    // MARK: - Hook Full Lifecycle E2E

    func testHookFullLifecycle() {
        // Full lifecycle using Hook events only (no timers)
        manager.setHookActive(true)

        // 1. No sessions → idle
        XCTAssertEqual(iconState(), .idle)

        // 2. PreToolUse → active
        manager.handleEventSync(.toolUseStarted(sessionId: "s1", toolUseId: "hook-1", toolName: "Bash", cwd: "/project"))
        XCTAssertEqual(iconState(), .active)

        // 3. Notification(permission_prompt) → urgent (instant, no 7s)
        manager.handleEventSync(.permissionWaiting(sessionId: "s1", cwd: "/project"))
        XCTAssertEqual(iconState(), .urgent, "Hook permission → instant RED bubble")

        // 4. PostToolUse (approved) → active
        manager.handleEventSync(.toolUseCompleted(sessionId: "s1", toolUseId: "hook-2", cwd: nil))
        XCTAssertEqual(iconState(), .active)

        // 5. Stop → waiting (white)
        manager.handleEventSync(.turnEnded(sessionId: "s1", durationMs: 0, cwd: nil))
        XCTAssertEqual(iconState(), .waiting)

        // 6. UserPromptSubmit → active
        manager.handleEventSync(.userPrompt(sessionId: "s1", cwd: nil))
        XCTAssertEqual(iconState(), .active)

        // 7. AskUserQuestion → urgent
        manager.handleEventSync(.askUserQuestion(sessionId: "s1", toolUseId: "hook-3", questionText: "Continue?", cwd: nil))
        XCTAssertEqual(iconState(), .urgent)

        // 8. PostToolUse (answered) → active
        manager.handleEventSync(.toolUseCompleted(sessionId: "s1", toolUseId: "hook-3", cwd: nil))
        XCTAssertEqual(iconState(), .active)

        // 9. SessionEnd → idle
        manager.handleEventSync(.sessionEnded(sessionId: "s1"))
        XCTAssertEqual(iconState(), .idle)
    }

    func testHookActive_timerNeverFires() {
        // With hookActive, the 7s timer should never fire even after long waits
        manager.setHookActive(true)

        let noTimeout = XCTestExpectation(description: "no timer in hook mode")
        noTimeout.isInverted = true

        manager.onSessionChanged = { session in
            if session.status == .waitingPermission {
                noTimeout.fulfill()
            }
        }

        manager.handleEventSync(.toolUseStarted(sessionId: "s1", toolUseId: "t1", toolName: "Bash", cwd: "/project"))

        // Wait past the 7s timeout — should NOT become urgent
        wait(for: [noTimeout], timeout: 8.0)
        XCTAssertEqual(iconState(), .active, "hookActive → no timer fires, stays active")
    }

    // MARK: - Turn Ended → White Speech Bubble (waiting)

    func testTurnEnded_showsWhiteBubble() {
        // Processing completes → turn ends → white bubble (waiting for next input)
        manager.handleEventSync(.toolUseStarted(sessionId: "s1", toolUseId: "t1", toolName: "Read", cwd: "/project"))
        manager.handleEventSync(.toolUseCompleted(sessionId: "s1", toolUseId: "t1", cwd: nil))
        manager.handleEventSync(.turnEnded(sessionId: "s1", durationMs: 3000, cwd: nil))

        XCTAssertEqual(iconState(), .waiting, "Turn ended → WHITE speech bubble (waiting)")
        XCTAssertEqual(manager.getSession("s1")?.status, .waitingTurnEnd)
        XCTAssertEqual(manager.getSession("s1")?.waitingReason, .turnEnded)
    }

    func testTurnEnded_thenUserInput_returnsToActive() {
        manager.handleEventSync(.turnEnded(sessionId: "s1", durationMs: 5000, cwd: "/project"))
        XCTAssertEqual(iconState(), .waiting, "White bubble while waiting for input")

        // User types next prompt
        manager.handleEventSync(.userPrompt(sessionId: "s1", cwd: nil))
        XCTAssertEqual(iconState(), .active, "User input → back to active")
    }

    // MARK: - AskUserQuestion → Red Speech Bubble (urgent)

    func testAskUserQuestion_showsRedBubble() {
        manager.handleEventSync(.askUserQuestion(sessionId: "s1", toolUseId: "t1", questionText: "Continue?", cwd: "/project"))

        XCTAssertEqual(iconState(), .urgent, "AskUserQuestion → RED speech bubble (urgent)")
        XCTAssertEqual(manager.getSession("s1")?.status, .waitingQuestion)
    }

    func testAskUserQuestion_thenAnswer_returnsToActive() {
        manager.handleEventSync(.askUserQuestion(sessionId: "s1", toolUseId: "t1", questionText: "Which file?", cwd: "/project"))
        XCTAssertEqual(iconState(), .urgent)

        manager.handleEventSync(.toolUseCompleted(sessionId: "s1", toolUseId: "t1", cwd: nil))
        XCTAssertEqual(iconState(), .active)
    }

    // MARK: - Multi-Session Priority

    func testMultiSession_urgentTakesPriority() {
        // Session 1: turn ended (white bubble)
        manager.handleEventSync(.turnEnded(sessionId: "s1", durationMs: 1000, cwd: "/project-a"))
        XCTAssertEqual(iconState(), .waiting)

        // Session 2: permission timeout (red bubble) → should override
        manager.handleEventSync(.toolUseStarted(sessionId: "s2", toolUseId: "t1", toolName: "Bash", cwd: "/project-b"))
        simulatePermissionTimeout(sessionId: "s2")

        XCTAssertEqual(iconState(), .urgent, "Urgent takes priority over waiting (red > white)")
    }

    func testMultiSession_urgentCleared_fallsBackToWaiting() {
        // Session 1: waiting (white)
        manager.handleEventSync(.turnEnded(sessionId: "s1", durationMs: 1000, cwd: "/project-a"))

        // Session 2: urgent (red)
        manager.handleEventSync(.toolUseStarted(sessionId: "s2", toolUseId: "t1", toolName: "Bash", cwd: "/project-b"))
        simulatePermissionTimeout(sessionId: "s2")
        XCTAssertEqual(iconState(), .urgent)

        // Session 2 approved → urgent cleared
        manager.handleEventSync(.toolUseCompleted(sessionId: "s2", toolUseId: "t1", cwd: nil))

        XCTAssertEqual(iconState(), .waiting, "Urgent cleared → falls back to white bubble from s1")
    }

    func testMultiSession_activeTakesPriorityOverIdle() {
        manager.handleEventSync(.toolUseStarted(sessionId: "s1", toolUseId: "t1", toolName: "Read", cwd: "/project"))
        XCTAssertEqual(iconState(), .active, "Active session → active icon")
    }

    // MARK: - Full Lifecycle E2E

    func testFullLifecycle_idleToUrgentToWaitingToActive() {
        // 1. No sessions → idle
        XCTAssertEqual(iconState(), .idle, "No sessions → idle")

        // 2. Agent starts working → active
        manager.handleEventSync(.toolUseStarted(sessionId: "s1", toolUseId: "t1", toolName: "Bash", cwd: "/project"))
        XCTAssertEqual(iconState(), .active, "Agent working → active")

        // 3. Permission timeout → urgent (RED bubble)
        simulatePermissionTimeout(sessionId: "s1")
        XCTAssertEqual(iconState(), .urgent, "Permission timeout → RED bubble")

        // 4. User approves → active
        manager.handleEventSync(.toolUseCompleted(sessionId: "s1", toolUseId: "t1", cwd: nil))
        XCTAssertEqual(iconState(), .active, "Approved → active")

        // 5. Turn ends → waiting (WHITE bubble)
        manager.handleEventSync(.turnEnded(sessionId: "s1", durationMs: 2000, cwd: nil))
        XCTAssertEqual(iconState(), .waiting, "Turn ended → WHITE bubble")

        // 6. User sends next prompt → active
        manager.handleEventSync(.userPrompt(sessionId: "s1", cwd: nil))
        XCTAssertEqual(iconState(), .active, "New prompt → active")

        // 7. Session ends → idle
        manager.handleEventSync(.sessionEnded(sessionId: "s1"))
        XCTAssertEqual(iconState(), .idle, "Session ended → idle")
    }

    func testFullLifecycle_askQuestionFlow() {
        // Agent works → asks question (RED) → user answers → turn ends (WHITE)
        manager.handleEventSync(.toolUseStarted(sessionId: "s1", toolUseId: "t1", toolName: "Read", cwd: "/project"))
        manager.handleEventSync(.toolUseCompleted(sessionId: "s1", toolUseId: "t1", cwd: nil))

        manager.handleEventSync(.askUserQuestion(sessionId: "s1", toolUseId: "t2", questionText: "Proceed?", cwd: nil))
        XCTAssertEqual(iconState(), .urgent, "Question → RED bubble")

        manager.handleEventSync(.toolUseCompleted(sessionId: "s1", toolUseId: "t2", cwd: nil))
        XCTAssertEqual(iconState(), .active, "Answered → active")

        manager.handleEventSync(.turnEnded(sessionId: "s1", durationMs: 1000, cwd: nil))
        XCTAssertEqual(iconState(), .waiting, "Processing done → WHITE bubble")
    }

    // MARK: - File Disappearance → Idle

    func testAllSessionsEndedViaFileRemoval_goesIdle() {
        // Simulate what happens when FileWatcher detects JSONL files disappearing
        // and emits sessionEnded events for each
        manager.handleEventSync(.turnEnded(sessionId: "s1", durationMs: 1000, cwd: "/project-a"))
        manager.handleEventSync(.toolUseStarted(sessionId: "s2", toolUseId: "t1", toolName: "Bash", cwd: "/project-b"))
        simulatePermissionTimeout(sessionId: "s2")

        XCTAssertEqual(iconState(), .urgent, "Before cleanup: urgent from s2")

        // FileWatcher emits sessionEnded for both (files deleted)
        manager.handleEventSync(.sessionEnded(sessionId: "s1"))
        manager.handleEventSync(.sessionEnded(sessionId: "s2"))

        XCTAssertEqual(iconState(), .idle, "All sessions ended via file removal → idle")
        XCTAssertEqual(manager.getAllSessions().count, 0)
    }

    func testOneSessionEndedViaFileRemoval_fallsBackToRemaining() {
        manager.handleEventSync(.turnEnded(sessionId: "s1", durationMs: 1000, cwd: "/project-a"))
        manager.handleEventSync(.askUserQuestion(sessionId: "s2", toolUseId: "t1", questionText: "Q?", cwd: "/project-b"))
        XCTAssertEqual(iconState(), .urgent)

        // Only s2's file disappears
        manager.handleEventSync(.sessionEnded(sessionId: "s2"))

        XCTAssertEqual(iconState(), .waiting, "s2 gone, s1 still waiting → waiting icon")
        XCTAssertEqual(manager.getAllSessions().count, 1)
    }

    // MARK: - Edge Cases

    func testExemptTool_noPermissionTimeout() {
        // AskUserQuestion and Task are exempt from permission timer
        manager.handleEventSync(.toolUseStarted(sessionId: "s1", toolUseId: "t1", toolName: "Task", cwd: "/project"))
        XCTAssertEqual(iconState(), .active)

        // Wait past the 7s timeout — should NOT become urgent
        let noTimeout = XCTestExpectation(description: "exempt tool should not trigger timeout")
        noTimeout.isInverted = true

        manager.onSessionChanged = { session in
            if session.status == .waitingPermission {
                noTimeout.fulfill()
            }
        }

        wait(for: [noTimeout], timeout: 8.0)
        XCTAssertEqual(iconState(), .active, "Exempt tool (Task) → no red bubble")
    }

    func testProgressEvent_resetsPermissionTimer() {
        // Tool starts → progress events keep coming → should delay permission timeout
        let noTimeout = XCTestExpectation(description: "progress should reset timer")
        noTimeout.isInverted = true

        manager.onSessionChanged = { session in
            if session.status == .waitingPermission {
                noTimeout.fulfill()
            }
        }

        manager.handleEventSync(.toolUseStarted(sessionId: "s1", toolUseId: "t1", toolName: "Bash", cwd: "/project"))

        // Send progress events every 5s (before 7s timeout)
        DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) {
            self.manager.handleEventSync(.progressEvent(sessionId: "s1", dataType: "bash_progress"))
        }

        // Within 8s, no timeout should fire because progress reset the timer
        wait(for: [noTimeout], timeout: 8.0)
    }

    // MARK: - Helpers

    /// Simulate 7s permission timer fire for JSONL-only mode tests.
    /// Uses forceStatusForTesting since handleEventSync doesn't trigger async timers.
    private func simulatePermissionTimeout(sessionId: String) {
        if manager.getSession(sessionId) == nil {
            manager.handleEventSync(.toolUseStarted(sessionId: sessionId, toolUseId: "setup", toolName: "Bash", cwd: "/project"))
        }
        manager.forceStatusForTesting(sessionId: sessionId, status: .waitingPermission, reason: .permissionTimeout)
    }
}
