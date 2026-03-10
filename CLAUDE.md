# CLAUDE.md

## Project Overview

CCBar is a macOS menu bar app (Swift, SPM) that monitors Claude Code agent sessions and sends notifications when agents need user input. It uses dual detection: JSONL file watching + Hook HTTP server.

## Tech Stack

- **Language**: Swift 5.9+
- **Platform**: macOS 13+ (Ventura)
- **UI**: AppKit (NSStatusItem menu bar)
- **Networking**: SwiftNIO (HTTP server on port 27182)
- **Notifications**: UNUserNotificationCenter with osascript fallback
- **Build**: Swift Package Manager

## Build & Run

```bash
swift build          # Debug build
swift build -c release  # Release build
swift run            # Build and run
swift test           # Unit tests
./Scripts/run_e2e.sh # E2E tests (launches app, tests JSONL + hooks)
./Scripts/install.sh # Full install (build + copy binary + configure hooks)
```

## Project Structure

```
Sources/CCBar/
├── main.swift                    # NSApplication entry (.accessory policy)
├── AppDelegate.swift             # Service wiring and lifecycle
├── Models/
│   ├── SessionState.swift        # AgentStatus, WaitingReason, SessionInfo
│   ├── HookEvent.swift           # Hook JSON payload (snake_case mapped)
│   └── JSONLRecord.swift         # JSONL record types, ContentBlock, AnyCodable
├── Services/
│   ├── FileWatcher.swift         # Polls ~/.claude/projects/*/*.jsonl (1s interval)
│   ├── JSONLParser.swift         # JSONL → DetectedEvent (supports multi-tool_use)
│   ├── HookServer.swift          # SwiftNIO HTTP: POST /claude-event, GET /status
│   ├── SessionManager.swift      # State machine, permission timers (7s), idle pruning (30min)
│   └── NotificationManager.swift # UNUserNotification + osascript fallback, 30s debounce
└── UI/
    └── MenuBarController.swift   # NSStatusItem with 4 icon states (idle/active/waiting/urgent)

Tests/CCBarTests/      # Unit tests
TestFixtures/                     # Sample JSONL and hook JSON files
Scripts/                          # install.sh, uninstall.sh, run_e2e.sh
```

## Key Architecture Patterns

- **Event-driven pipeline**: `FileWatcher`/`HookServer` → `DetectedEvent` → `SessionManager` → UI callbacks
- **DetectedEvent enum**: All events (turnEnded, toolUseStarted, toolUseCompleted, askUserQuestion, userPrompt, progressEvent, sessionEnded) funnel through a single enum
- **Thread safety**: `SessionManager` uses a serial `DispatchQueue` for all state mutations
- **Permission detection**: Timer-based (7s after tool_use with no tool_result = permission waiting)
- **Icon priority**: `urgent` (permission/question) > `waiting` (turn end) > `active` > `idle`

## Code Conventions

- No external dependencies except SwiftNIO
- Models use `Codable` with explicit `CodingKeys` for snake_case JSON mapping
- `AnyCodable` wrapper for dynamic JSON fields (tool inputs/outputs)
- `@unchecked Sendable` only on NIO handler (required by framework)
- Test methods use descriptive names: `testXxxYyyZzz()`

## Important Constants

| Constant | Value | Location |
|----------|-------|----------|
| Hook server port | 27182 | `HookServer.init` |
| Permission timeout | 7.0s | `SessionManager.startPermissionTimer` |
| Idle prune interval | 30min | `SessionManager.pruneIdleSessions` |
| Notification debounce | 30.0s | `NotificationManager.debounceInterval` |
| File poll interval | 1.0s | `FileWatcher.start` |

## Common Tasks

- **Add new hook event**: Map in `HookServer.mapHookEvent()`, add `DetectedEvent` case if needed, handle in `SessionManager._handleEvent()`
- **Add new icon state**: Add case to `MenuBarController.IconState`, update `determineIconState()` and `updateIcon()`
- **Add new JSONL record type**: Extend `JSONLRecord` model, add parsing in `JSONLParser.detectEvents()`
- **Change detection timing**: Modify constants in `SessionManager` (permission timer) or `FileWatcher` (poll interval)

## Reference Documents

- [STATES.md](STATES.md) - App icon state transition diagrams (Mermaid)
- [CLAUDE_CODE_EVENTS.md](CLAUDE_CODE_EVENTS.md) - Claude Code event detection analysis
- [PIXEL_AGENTS.md](PIXEL_AGENTS.md) - Pixel Agents project analysis (reference)
