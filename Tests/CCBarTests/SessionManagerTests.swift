import XCTest

@testable import CCBar

final class SessionManagerTests: XCTestCase {
    var manager: SessionManager!

    override func setUp() {
        super.setUp()
        manager = SessionManager()
    }

    override func tearDown() {
        manager.stop()
        super.tearDown()
    }

    func testTurnEndedSetsWaitingState() {
        manager.handleEventSync(.turnEnded(sessionId: "s1", durationMs: 5000, cwd: nil))

        let session = manager.getSession("s1")
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.status, .waitingTurnEnd)
        XCTAssertEqual(session?.waitingReason, .turnEnded)
    }

    func testUserPromptSetsActiveState() {
        manager.handleEventSync(.turnEnded(sessionId: "s1", durationMs: 5000, cwd: nil))
        manager.handleEventSync(.userPrompt(sessionId: "s1", cwd: nil))

        let session = manager.getSession("s1")
        XCTAssertEqual(session?.status, .active)
        XCTAssertNil(session?.waitingReason)
    }

    func testToolUseStartedSetsActive() {
        manager.handleEventSync(.toolUseStarted(sessionId: "s1", toolUseId: "t1", toolName: "Read", cwd: nil))

        let session = manager.getSession("s1")
        XCTAssertEqual(session?.status, .active)
        XCTAssertTrue(session?.pendingToolUseIds.contains("t1") ?? false)
    }

    func testToolUseCompletedRemovesPending() {
        manager.handleEventSync(.toolUseStarted(sessionId: "s1", toolUseId: "t1", toolName: "Read", cwd: nil))
        manager.handleEventSync(.toolUseCompleted(sessionId: "s1", toolUseId: "t1", cwd: nil))

        let session = manager.getSession("s1")
        XCTAssertFalse(session?.pendingToolUseIds.contains("t1") ?? true)
    }

    func testAskUserQuestionSetsWaitingQuestion() {
        manager.handleEventSync(.askUserQuestion(sessionId: "s1", toolUseId: "t1", questionText: "Which?", cwd: nil))

        let session = manager.getSession("s1")
        XCTAssertEqual(session?.status, .waitingQuestion)
        XCTAssertEqual(session?.waitingReason, .askUserQuestion)
        XCTAssertEqual(session?.questionText, "Which?")
    }

    func testMultipleSessions() {
        manager.handleEventSync(.turnEnded(sessionId: "s1", durationMs: 1000, cwd: nil))
        manager.handleEventSync(.toolUseStarted(sessionId: "s2", toolUseId: "t1", toolName: "Bash", cwd: nil))
        manager.handleEventSync(.askUserQuestion(sessionId: "s3", toolUseId: "t2", questionText: "Q?", cwd: nil))

        XCTAssertEqual(manager.getAllSessions().count, 3)
        XCTAssertEqual(manager.getSession("s1")?.status, .waitingTurnEnd)
        XCTAssertEqual(manager.getSession("s2")?.status, .active)
        XCTAssertEqual(manager.getSession("s3")?.status, .waitingQuestion)
    }

    func testTurnEndClearsPendingTools() {
        manager.handleEventSync(.toolUseStarted(sessionId: "s1", toolUseId: "t1", toolName: "Read", cwd: nil))
        manager.handleEventSync(.toolUseStarted(sessionId: "s1", toolUseId: "t2", toolName: "Grep", cwd: nil))
        manager.handleEventSync(.turnEnded(sessionId: "s1", durationMs: 1000, cwd: nil))

        let session = manager.getSession("s1")
        XCTAssertTrue(session?.pendingToolUseIds.isEmpty ?? false)
    }

    func testProgressEventUpdatesActivity() {
        manager.handleEventSync(.toolUseStarted(sessionId: "s1", toolUseId: "t1", toolName: "Bash", cwd: nil))
        let before = manager.getSession("s1")?.lastActivity

        Thread.sleep(forTimeInterval: 0.01)
        manager.handleEventSync(.progressEvent(sessionId: "s1", dataType: "bash_progress"))

        let after = manager.getSession("s1")?.lastActivity
        XCTAssertNotNil(before)
        XCTAssertNotNil(after)
        if let b = before, let a = after {
            XCTAssertGreaterThan(a, b)
        }
    }

    func testSessionAutoCreation() {
        // Events for unknown sessions should auto-create them
        manager.handleEventSync(.turnEnded(sessionId: "new-session", durationMs: 100, cwd: nil))
        XCTAssertNotNil(manager.getSession("new-session"))
    }

    func testPermissionWaitingThenRejectClearsWaiting() {
        // Hook flow: permissionWaiting → user rejects → toolUseCompleted
        manager.handleEventSync(.permissionWaiting(sessionId: "s1", cwd: "/test"))
        XCTAssertEqual(manager.getSession("s1")?.status, .waitingPermission)

        manager.handleEventSync(.toolUseCompleted(sessionId: "s1", toolUseId: "hook-reject", cwd: nil))
        XCTAssertEqual(manager.getSession("s1")?.status, .active)
        XCTAssertNil(manager.getSession("s1")?.waitingReason)
    }

    func testPermissionWaitingThenApproveClearsWaiting() {
        // Hook flow: permissionWaiting → user approves → toolUseCompleted
        manager.handleEventSync(.permissionWaiting(sessionId: "s1", cwd: "/test"))
        XCTAssertEqual(manager.getSession("s1")?.status, .waitingPermission)

        manager.handleEventSync(.toolUseCompleted(sessionId: "s1", toolUseId: "hook-approve", cwd: nil))
        XCTAssertEqual(manager.getSession("s1")?.status, .active)
    }

    func testSyntheticToolUseIdClearsWaiting() {
        // Hook-generated synthetic IDs should still clear waiting states
        manager.handleEventSync(.toolUseStarted(sessionId: "s1", toolUseId: "t1", toolName: "Write", cwd: nil))
        XCTAssertEqual(manager.getSession("s1")?.status, .active)

        manager.handleEventSync(.toolUseCompleted(sessionId: "s1", toolUseId: "hook-synthetic", cwd: nil))
        XCTAssertEqual(manager.getSession("s1")?.status, .active)
    }

    func testHookFullFlow_preToolUse_permissionWaiting_postToolUse() {
        // Simulates the full Hook event sequence for permission prompt
        // PreToolUse → Notification(permission_prompt) → PostToolUse
        manager.handleEventSync(.toolUseStarted(sessionId: "s1", toolUseId: "hook-1", toolName: "Bash", cwd: "/project"))
        XCTAssertEqual(manager.getSession("s1")?.status, .active)

        manager.handleEventSync(.permissionWaiting(sessionId: "s1", cwd: "/project"))
        XCTAssertEqual(manager.getSession("s1")?.status, .waitingPermission)

        manager.handleEventSync(.toolUseCompleted(sessionId: "s1", toolUseId: "hook-2", cwd: "/project"))
        XCTAssertEqual(manager.getSession("s1")?.status, .active)
    }

    func testAskUserQuestionEscClearsWaiting() {
        // Simulate: AskUserQuestion → user presses ESC → tool_result arrives
        manager.handleEventSync(.askUserQuestion(sessionId: "s1", toolUseId: "t1", questionText: "Which?", cwd: nil))
        XCTAssertEqual(manager.getSession("s1")?.status, .waitingQuestion)

        // ESC produces a tool_result (user_abort), which triggers toolUseCompleted
        manager.handleEventSync(.toolUseCompleted(sessionId: "s1", toolUseId: "t1", cwd: nil))

        let session = manager.getSession("s1")
        XCTAssertEqual(session?.status, .active)
        XCTAssertNil(session?.waitingReason)
        XCTAssertNil(session?.questionText)
    }

    func testSessionEndedRemovesSession() {
        manager.handleEventSync(.turnEnded(sessionId: "s1", durationMs: 1000, cwd: nil))
        XCTAssertNotNil(manager.getSession("s1"))

        manager.handleEventSync(.sessionEnded(sessionId: "s1"))
        XCTAssertNil(manager.getSession("s1"))
    }

    func testSessionEndedWhileWaitingQuestion() {
        manager.handleEventSync(.askUserQuestion(sessionId: "s1", toolUseId: "t1", questionText: "Q?", cwd: nil))
        XCTAssertEqual(manager.getSession("s1")?.status, .waitingQuestion)

        manager.handleEventSync(.sessionEnded(sessionId: "s1"))
        XCTAssertNil(manager.getSession("s1"))
    }

    func testMultipleSessionsEndedCleansUpAll() {
        manager.handleEventSync(.turnEnded(sessionId: "s1", durationMs: 1000, cwd: nil))
        manager.handleEventSync(.toolUseStarted(sessionId: "s2", toolUseId: "t1", toolName: "Bash", cwd: nil))
        manager.handleEventSync(.askUserQuestion(sessionId: "s3", toolUseId: "t2", questionText: "Q?", cwd: nil))
        XCTAssertEqual(manager.getAllSessions().count, 3)

        manager.handleEventSync(.sessionEnded(sessionId: "s1"))
        manager.handleEventSync(.sessionEnded(sessionId: "s2"))
        manager.handleEventSync(.sessionEnded(sessionId: "s3"))
        XCTAssertEqual(manager.getAllSessions().count, 0)
    }

    func testPermissionWaitingEventSetsWaitingPermission() {
        manager.handleEventSync(.permissionWaiting(sessionId: "s1", cwd: "/test"))

        let session = manager.getSession("s1")
        XCTAssertEqual(session?.status, .waitingPermission)
        XCTAssertEqual(session?.waitingReason, .permissionTimeout)
    }

    func testHookActiveSkipsPermissionTimer() {
        manager.setHookActive(true)

        // Tool starts but timer should NOT fire since hookActive is true
        let noTimeout = XCTestExpectation(description: "no timer should fire")
        noTimeout.isInverted = true

        manager.onSessionChanged = { session in
            if session.status == .waitingPermission {
                noTimeout.fulfill()
            }
        }

        manager.handleEventSync(.toolUseStarted(sessionId: "s1", toolUseId: "t1", toolName: "Bash", cwd: nil))
        wait(for: [noTimeout], timeout: 8.0)
        XCTAssertEqual(manager.getSession("s1")?.status, .active)
    }

    func testOnSessionChangedCallback() {
        let expectation = XCTestExpectation(description: "callback called")

        manager.onSessionChanged = { session in
            XCTAssertEqual(session.id, "s1")
            XCTAssertEqual(session.status, .waitingTurnEnd)
            expectation.fulfill()
        }

        manager.handleEventSync(.turnEnded(sessionId: "s1", durationMs: 1000, cwd: nil))

        wait(for: [expectation], timeout: 2.0)
    }
}
