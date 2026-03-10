import XCTest

@testable import CCBar

final class HookEventTests: XCTestCase {
    let server = HookServer(port: 0)  // won't actually bind for parsing tests

    func testParseStopEvent() {
        let json = """
            {"session_id":"s1","hook_event_name":"Stop","reason":"completed","cwd":"/test"}
            """.data(using: .utf8)!

        let event = server.handleHookEvent(json)
        if case .turnEnded(let sessionId, _, _) = event {
            XCTAssertEqual(sessionId, "s1")
        } else {
            XCTFail("Expected turnEnded, got \(String(describing: event))")
        }
    }

    func testParseSubagentStopEvent() {
        let json = """
            {"session_id":"s1b","hook_event_name":"SubagentStop","reason":"done","cwd":"/test"}
            """.data(using: .utf8)!

        let event = server.handleHookEvent(json)
        if case .turnEnded(let sessionId, _, _) = event {
            XCTAssertEqual(sessionId, "s1b")
        } else {
            XCTFail("Expected turnEnded, got \(String(describing: event))")
        }
    }

    func testParseAskUserQuestionEvent() {
        let json = """
            {"session_id":"s2","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which one?"}]},"cwd":"/test"}
            """.data(using: .utf8)!

        let event = server.handleHookEvent(json)
        if case .askUserQuestion(let sessionId, _, let question, _) = event {
            XCTAssertEqual(sessionId, "s2")
            XCTAssertEqual(question, "Which one?")
        } else {
            XCTFail("Expected askUserQuestion, got \(String(describing: event))")
        }
    }

    func testParseUserPromptEvent() {
        let json = """
            {"session_id":"s3","hook_event_name":"UserPromptSubmit","user_prompt":"fix it","cwd":"/test"}
            """.data(using: .utf8)!

        let event = server.handleHookEvent(json)
        if case .userPrompt(let sessionId, _) = event {
            XCTAssertEqual(sessionId, "s3")
        } else {
            XCTFail("Expected userPrompt, got \(String(describing: event))")
        }
    }

    func testParsePreToolUseNonAsk() {
        let json = """
            {"session_id":"s4","hook_event_name":"PreToolUse","tool_name":"Read","cwd":"/test"}
            """.data(using: .utf8)!

        let event = server.handleHookEvent(json)
        if case .toolUseStarted(let sessionId, _, let toolName, _) = event {
            XCTAssertEqual(sessionId, "s4")
            XCTAssertEqual(toolName, "Read")
        } else {
            XCTFail("Expected toolUseStarted, got \(String(describing: event))")
        }
    }

    func testParseNotificationPermissionPrompt() {
        let json = """
            {"session_id":"s6","hook_event_name":"Notification","notification_type":"permission_prompt","cwd":"/test"}
            """.data(using: .utf8)!

        let event = server.handleHookEvent(json)
        if case .permissionWaiting(let sessionId, _) = event {
            XCTAssertEqual(sessionId, "s6")
        } else {
            XCTFail("Expected permissionWaiting, got \(String(describing: event))")
        }
    }

    func testParseNotificationIdlePrompt() {
        let json = """
            {"session_id":"s6b","hook_event_name":"Notification","notification_type":"idle_prompt","cwd":"/test"}
            """.data(using: .utf8)!

        let event = server.handleHookEvent(json)
        if case .turnEnded(let sessionId, _, _) = event {
            XCTAssertEqual(sessionId, "s6b")
        } else {
            XCTFail("Expected turnEnded, got \(String(describing: event))")
        }
    }

    func testParseNotificationWithoutType() {
        // Notification without notification_type falls back to turnEnded
        let json = """
            {"session_id":"s6c","hook_event_name":"Notification","cwd":"/test"}
            """.data(using: .utf8)!

        let event = server.handleHookEvent(json)
        if case .turnEnded(let sessionId, _, _) = event {
            XCTAssertEqual(sessionId, "s6c")
        } else {
            XCTFail("Expected turnEnded, got \(String(describing: event))")
        }
    }

    func testParseInvalidJSON() {
        let event = server.handleHookEvent("not json".data(using: .utf8)!)
        XCTAssertNil(event)
    }

    func testParseUnknownEvent() {
        let json = """
            {"session_id":"s5","hook_event_name":"WorktreeCreate","cwd":"/test"}
            """.data(using: .utf8)!

        let event = server.handleHookEvent(json)
        XCTAssertNil(event)
    }

    func testParsePreToolUseWithoutToolName() {
        let json = """
            {"session_id":"s7","hook_event_name":"PreToolUse","cwd":"/test"}
            """.data(using: .utf8)!

        let event = server.handleHookEvent(json)
        XCTAssertNil(event)
    }

    func testParseEventWithoutHookEventName() {
        let json = """
            {"session_id":"s8","cwd":"/test"}
            """.data(using: .utf8)!

        let event = server.handleHookEvent(json)
        XCTAssertNil(event)
    }

    func testAskUserQuestionFallbackText() {
        // tool_input without questions array should fall back to default text
        let json = """
            {"session_id":"s9","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"something":"else"},"cwd":"/test"}
            """.data(using: .utf8)!

        let event = server.handleHookEvent(json)
        if case .askUserQuestion(_, _, let question, _) = event {
            XCTAssertEqual(question, "Waiting for your answer...")
        } else {
            XCTFail("Expected askUserQuestion, got \(String(describing: event))")
        }
    }

    func testParsePostToolUseEvent() {
        let json = """
            {"session_id":"s10","hook_event_name":"PostToolUse","tool_name":"Bash","cwd":"/test"}
            """.data(using: .utf8)!

        let event = server.handleHookEvent(json)
        if case .toolUseCompleted(let sessionId, let toolUseId, _) = event {
            XCTAssertEqual(sessionId, "s10")
            XCTAssertTrue(toolUseId.hasPrefix("hook-"), "PostToolUse should produce synthetic hook- ID")
        } else {
            XCTFail("Expected toolUseCompleted, got \(String(describing: event))")
        }
    }

    func testParseSessionEndEvent() {
        let json = """
            {"session_id":"s11","hook_event_name":"SessionEnd","cwd":"/test"}
            """.data(using: .utf8)!

        let event = server.handleHookEvent(json)
        if case .sessionEnded(let sessionId) = event {
            XCTAssertEqual(sessionId, "s11")
        } else {
            XCTFail("Expected sessionEnded, got \(String(describing: event))")
        }
    }

    func testParseNotificationElicitationDialog() {
        let json = """
            {"session_id":"s12","hook_event_name":"Notification","notification_type":"elicitation_dialog","cwd":"/test"}
            """.data(using: .utf8)!

        let event = server.handleHookEvent(json)
        if case .turnEnded(let sessionId, _, _) = event {
            XCTAssertEqual(sessionId, "s12")
        } else {
            XCTFail("Expected turnEnded for elicitation_dialog, got \(String(describing: event))")
        }
    }

    func testHTTPServerStartStop() throws {
        let testServer = HookServer(port: 27183)
        try testServer.start()
        testServer.stop()
    }
}
