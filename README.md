# CCBar

A macOS menu bar app that monitors Claude Code agent sessions and notifies you when they need your attention.
<img width="359" height="38" alt="image" src="https://github.com/user-attachments/assets/c41d8047-6c4c-4dd2-8226-96a3ec48f5ef" />

## What It Does

CCBar sits in your menu bar and watches all active Claude Code sessions across projects. When an agent finishes its turn, needs permission, or asks a question, the icon changes and you get a native macOS notification.

### Menu Bar Icon States

| Icon | State | Meaning |
|------|-------|---------|
| `terminal` (outline) | Idle | No active sessions |
| `terminal.fill` (white) | Active | Agent(s) working |
| `bubble.left.fill` (white) | Waiting | Agent finished, awaiting your input |
| `bubble.left.fill` (red) | Urgent | Agent needs permission or has a question |

See [STATES.md](STATES.md) for the full state transition diagram.


## How It Works

Two detection strategies run simultaneously:

1. **JSONL File Watching** - Polls `~/.claude/projects/*/` for JSONL transcript files and parses new lines to detect turn endings, tool usage, and user prompts.

2. **Hook HTTP Server** - Listens on `localhost:27182` for real-time events from Claude Code hooks (`Stop`, `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `Notification`, `SessionEnd`).

Both feed into a `SessionManager` that tracks each session's state and drives the menu bar icon and notifications.

## Requirements

- macOS 13.0+
- Swift 5.9+
- Claude Code installed

## Installation

```bash
# Clone and install (builds, copies binary, configures hooks)
git clone <repo-url>
cd CCBar
./Scripts/install.sh
```

The install script:
1. Builds the release binary via `swift build -c release`
2. Copies it to `~/Applications/CCBar`
3. Adds hook entries to `~/.claude/settings.json` (backs up existing file)

To auto-start on login, add `~/Applications/CCBar` to **System Settings > General > Login Items**.

> **Note:** Restart any running Claude Code sessions after installation for hooks to take effect.

## Uninstallation

```bash
./Scripts/uninstall.sh
```

Stops the process, removes the binary, and cleans hook entries from `~/.claude/settings.json`.

## Development

```bash
# Build
swift build

# Run
swift run

# Unit tests
swift test

# E2E tests (builds, launches app, tests JSONL + hook detection)
./Scripts/run_e2e.sh
```

## Architecture

```
Sources/CCBar/
├── main.swift                  # Entry point (NSApplication .accessory)
├── AppDelegate.swift           # Wires FileWatcher/HookServer → SessionManager → UI
├── Models/
│   ├── SessionState.swift      # AgentStatus enum, SessionInfo struct
│   ├── HookEvent.swift         # Hook JSON payload model
│   └── JSONLRecord.swift       # JSONL transcript record models
├── Services/
│   ├── FileWatcher.swift       # Polls ~/.claude/projects/ for JSONL changes
│   ├── JSONLParser.swift       # Parses JSONL lines into DetectedEvent
│   ├── HookServer.swift        # HTTP server on :27182 (SwiftNIO)
│   ├── SessionManager.swift    # Session state machine + permission timers
│   └── NotificationManager.swift  # macOS notifications (UNUserNotification + osascript fallback)
└── UI/
    └── MenuBarController.swift # NSStatusItem icon + dropdown menu
```

### Event Flow

```
FileWatcher ──┐
              ├──► SessionManager ──► MenuBarController (icon)
HookServer ───┘                  └──► NotificationManager (alerts)
```

### Key Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| Hook server port | `27182` | HTTP server for Claude Code hooks |
| Permission timeout | 7s | Estimate permission-waiting after tool_use |
| Idle prune threshold | 30min | Mark inactive sessions as idle |
| Notification debounce | 30s | Minimum interval between notifications per session |
| File poll interval | 1s | JSONL file scanning frequency |

## API

### `GET /status`

Returns current session state as JSON:

```json
{
  "totalSessions": 3,
  "waitingSessions": 1,
  "sessions": [
    { "id": "session-uuid", "project": "my-project", "status": "waitingTurnEnd" }
  ]
}

```

### `POST /claude-event`

Receives Claude Code hook events. See [CLAUDE_CODE_EVENTS.md](CLAUDE_CODE_EVENTS.md) for the full event schema.

## License

MIT
