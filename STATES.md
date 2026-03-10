# App Icon State Transition Diagram

## Overview

The CCBar menu bar app icon reflects the **aggregated state of all monitored sessions**.
Individual session `AgentStatus` values are aggregated by priority to determine a single icon state.

---

## Icon State Definitions

| Icon State | Meaning | Visual |
|------------|---------|--------|
| `noSession` | No active sessions | Inactive icon (gray) |
| `allActive` | All sessions are working | Default icon |
| `hasWaiting` | 1+ sessions awaiting user input | Notification icon (badge) |
| `hasPermission` | 1+ sessions awaiting permission approval | Warning icon (!) |
| `hasQuestion` | 1+ sessions awaiting question response | Question icon (?) |

**Priority**: `hasQuestion` > `hasPermission` > `hasWaiting` > `allActive` > `noSession`

---

## Icon State Transition Diagram

```mermaid
stateDiagram-v2
    [*] --> noSession: App launch

    %% === Session lifecycle ===
    noSession --> allActive: Session detected\n(JSONL file found / Hook received)
    allActive --> noSession: Last session closed

    %% === Active → Waiting transitions ===
    allActive --> hasWaiting: turn_duration received\n(turn ended)
    allActive --> hasPermission: tool_use with no result\nafter 7s timeout\n(permission wait estimated)
    allActive --> hasQuestion: AskUserQuestion\ntool_use detected

    %% === Waiting → Active transitions ===
    hasWaiting --> allActive: user record received\n(new prompt submitted)
    hasPermission --> allActive: tool_result received\n(permission granted/denied)
    hasQuestion --> allActive: tool_result received\n(user responded)

    %% === Waiting → higher priority waiting ===
    hasWaiting --> hasPermission: Another session\nenters permission wait
    hasWaiting --> hasQuestion: Another session\nenters question wait
    hasPermission --> hasQuestion: Another session\nenters question wait

    %% === Priority downgrade (higher wait resolved) ===
    hasQuestion --> hasPermission: Question answered\n+ permission wait session exists
    hasQuestion --> hasWaiting: Question answered\n+ turn-end wait session exists
    hasPermission --> hasWaiting: Permission resolved\n+ turn-end wait session exists

    %% === All sessions closed ===
    hasWaiting --> noSession: Last session closed
    hasPermission --> noSession: Last session closed
    hasQuestion --> noSession: Last session closed
```

---

## Individual Session State Transition (AgentStatus)

```mermaid
stateDiagram-v2
    [*] --> active: Session started

    state "active" as active
    state "waitingTurnEnd" as turnEnd
    state "waitingPermission" as perm
    state "waitingQuestion" as question
    state "idle" as idle

    %% === Active → Waiting transitions ===
    active --> turnEnd: system.turn_duration\n(turn ended)
    active --> perm: tool_use with 7s timeout\n(permission wait estimated)
    active --> question: tool_use\nname=AskUserQuestion
    active --> idle: 5s inactivity\n(text-only response)

    %% === Waiting → Active transitions ===
    turnEnd --> active: user record\n(new prompt)
    perm --> active: tool_result received\n(permission granted)
    perm --> active: bash_progress/mcp_progress\n(execution confirmed)
    question --> active: tool_result received\n(user responded)
    idle --> active: user record\n(new prompt)

    %% === Session termination ===
    active --> [*]: Session closed
    turnEnd --> [*]: Session closed
    perm --> [*]: Session closed
    question --> [*]: Session closed
    idle --> [*]: Session closed
```

---

## Event-State Mapping Summary

```mermaid
flowchart LR
    subgraph Events["Detection Events"]
        E1["system.turn_duration"]
        E2["tool_use + 7s timeout"]
        E3["tool_use: AskUserQuestion"]
        E4["user (new prompt)"]
        E5["tool_result"]
        E6["progress (bash/mcp)"]
        E7["5s inactivity"]
    end

    subgraph States["Session States"]
        S1["active"]
        S2["waitingTurnEnd"]
        S3["waitingPermission"]
        S4["waitingQuestion"]
        S5["idle"]
    end

    E1 --> S2
    E2 --> S3
    E3 --> S4
    E7 --> S5
    E4 --> S1
    E5 --> S1
    E6 --> S1
```

---

## Icon Aggregation Logic (Pseudocode)

```
func computeIconState(sessions: [SessionInfo]) -> IconState {
    if sessions.isEmpty { return .noSession }
    if sessions.contains(where: { $0.status == .waitingQuestion })   { return .hasQuestion }
    if sessions.contains(where: { $0.status == .waitingPermission }) { return .hasPermission }
    if sessions.contains(where: { $0.status == .waitingTurnEnd || $0.status == .idle }) { return .hasWaiting }
    return .allActive
}
```
