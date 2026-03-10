# Claude Code 사용자 입력 대기 이벤트 분석

## 목적

Claude Code가 작업 중 **사용자의 입력, 선택, 승인 등을 필요로 하여 대기하는 이벤트**를 외부에서 감지하는 방법을 분석한다. 이 문서는 Pixel Agents 같은 외부 감시 도구나 macOS 메뉴바 앱에서 "에이전트가 사용자를 기다리고 있다"는 상태를 파악하는 데 활용할 수 있다.

---

## 핵심 요약: 사용자 입력 대기 이벤트 3가지

Claude Code에서 사용자 입력이 필요한 상황은 크게 3가지다:

| # | 이벤트 | 감지 방법 | 설명 |
|---|--------|-----------|------|
| 1 | **턴 종료 (Turn End)** | JSONL: `system` + `turn_duration` | 에이전트의 응답이 끝나고 다음 사용자 입력을 기다리는 상태 |
| 2 | **권한 요청 (Permission Request)** | JSONL: `tool_use` 후 응답 없음 (타이머 기반) | 도구 실행 전 사용자 승인을 기다리는 상태 |
| 3 | **사용자 질문 (AskUserQuestion)** | JSONL: `tool_use` name=`AskUserQuestion` | 명시적으로 사용자에게 선택지를 제시하고 답변을 기다리는 상태 |

---

## 1. JSONL 트랜스크립트 기반 감지

### 1.1 JSONL 파일 위치

```
~/.claude/projects/<workspace-dir-name>/<session-id>.jsonl
```

- `<workspace-dir-name>`: 워크스페이스 경로에서 `[^a-zA-Z0-9-]`를 `-`로 치환한 이름
- `<session-id>`: UUID v4 형식 (`--session-id`로 지정 가능)
- 서브에이전트: `~/.claude/projects/<workspace-dir-name>/subagents/<agent-id>.jsonl`

### 1.2 JSONL 레코드 타입

| type | 설명 | 사용자 입력 관련 |
|------|------|:---:|
| `user` | 사용자 메시지 또는 도구 결과 | - |
| `assistant` | 어시스턴트 응답 (텍스트, tool_use) | **tool_use 포함** |
| `system` | 시스템 이벤트 | **turn_duration** |
| `progress` | 진행 상황 (hook, agent) | 간접 |
| `file-history-snapshot` | 파일 백업 스냅샷 | - |
| `last-prompt` | 마지막 프롬프트 저장 | - |

### 1.3 레코드 공통 필드

```json
{
  "type": "assistant|user|system|progress",
  "parentUuid": "parent-uuid",
  "uuid": "record-uuid",
  "timestamp": "2026-03-08T08:14:58.655Z",
  "sessionId": "session-uuid",
  "version": "2.1.71",
  "cwd": "/current/working/dir",
  "gitBranch": "main",
  "slug": "wild-soaring-kay",
  "isSidechain": false,
  "isMeta": false,
  "permissionMode": "default"
}
```

---

## 2. 이벤트별 상세 분석

### 2.1 턴 종료 (Turn End) — 가장 확실한 "입력 대기" 신호

**레코드 구조:**
```json
{
  "type": "system",
  "subtype": "turn_duration",
  "durationMs": 165124,
  "timestamp": "2026-03-08T08:14:58.655Z"
}
```

**의미:** 에이전트가 하나의 턴(요청 처리)을 완료했다. 이후 사용자의 다음 프롬프트를 기다린다.

**감지 로직:**
```
JSONL에서 {"type": "system", "subtype": "turn_duration"} 발견
→ 에이전트 상태: "waiting" (사용자 입력 대기)
→ 다음 {"type": "user"} 레코드가 나타나면 → "active" 상태로 전환
```

**한계:**
- 텍스트 전용 응답(도구를 사용하지 않는 응답)에서는 `turn_duration`이 **발행되지 않을 수 있다**
- 이 경우 일정 시간(5초 등) 동안 새 JSONL 데이터가 없으면 idle로 판단해야 한다

### 2.2 권한 요청 (Permission Request) — 간접 감지

Claude Code는 사용자의 `permissionMode` 설정에 따라 도구 실행 전 승인을 요청한다. 그러나 **JSONL에 "권한 대기 중"이라는 명시적 레코드는 기록되지 않는다.**

**간접 감지 방법 (타이머 기반):**
```
1. assistant 레코드에서 tool_use 블록 발견
2. 타이머 시작 (예: 7초)
3. 타이머 만료 전에 해당 tool_use_id의 tool_result가 도착하면 → 정상 실행
4. 타이머 만료 후에도 tool_result가 없으면 → 권한 대기 추정
5. bash_progress / mcp_progress 등 progress 이벤트가 오면 → 타이머 리셋 (실행 중)
```

**면제 도구 (권한이 필요 없는 도구):**
- `Task` (서브에이전트 생성)
- `AskUserQuestion` (사용자 질문 — 별도 처리)

**권한 결정 소스 (내부):**
- `classifier`: 자동 분류기가 허용
- `hook`: PreToolUse 훅이 결정
- `user`: 사용자가 프롬프트에서 영구/임시 허용
- `user_abort`: 사용자가 중단
- `user_reject`: 사용자가 거부
- `config`: 설정에서 사전 허용

### 2.3 AskUserQuestion — 명시적 사용자 입력 요청

**tool_use 레코드:**
```json
{
  "type": "tool_use",
  "id": "toolu_01Fi5XNEdQv1C1yf8zfWJgm4",
  "name": "AskUserQuestion",
  "input": {
    "questions": [
      {
        "question": "어떤 기술 스택을 사용할까요?",
        "header": "Tech Stack",
        "multiSelect": false,
        "options": [
          {
            "label": "Swift + SwiftUI",
            "description": "네이티브 macOS 앱"
          },
          {
            "label": "Electron + React",
            "description": "웹 기술 기반"
          }
        ]
      }
    ]
  }
}
```

**tool_result 레코드 (사용자 응답 후):**
```json
{
  "type": "tool_result",
  "tool_use_id": "toolu_01Fi5XNEdQv1C1yf8zfWJgm4",
  "content": "User has answered your questions: \"어떤 기술 스택을 사용할까요?\"=\"Swift + SwiftUI\". You can now continue with the user's answers in mind."
}
```

**감지 로직:**
```
assistant 레코드에서 name="AskUserQuestion" tool_use 발견
→ 에이전트 상태: "asking" (사용자 선택 대기)
→ 해당 tool_use_id의 tool_result가 나타나면 → "active" 상태로 전환
```

**AskUserQuestion 제약:**
- 1-4개 질문을 한 번에 요청 가능
- 질문당 2-4개 옵션 (사용자는 항상 "Other"로 자유 입력 가능)
- `multiSelect: true`로 복수 선택 가능
- header는 최대 12자

---

## 3. Hook 시스템 기반 감지 (실시간)

JSONL 파일 감시보다 **더 실시간으로** 이벤트를 감지하려면 Claude Code의 Hook 시스템을 활용할 수 있다.

### 3.1 Hook 이벤트 목록

| Hook Event | 발생 시점 | 사용자 입력 관련 |
|------------|-----------|:---:|
| **`PreToolUse`** | 도구 실행 **전** | **권한 결정 가능** |
| **`PostToolUse`** | 도구 실행 **후** | 도구 완료 감지 |
| **`Stop`** | 메인 에이전트 턴 종료 시도 | **턴 종료 = 입력 대기** |
| **`SubagentStop`** | 서브에이전트 턴 종료 시도 | 서브에이전트 완료 |
| **`UserPromptSubmit`** | 사용자가 프롬프트 제출 | 사용자 입력 발생 |
| **`SessionStart`** | 세션 시작 | - |
| **`SessionEnd`** | 세션 종료 | - |
| **`PreCompact`** | 컨텍스트 압축 전 | - |
| **`Notification`** | 알림 발생 시 | 알림 감지 |
| **`InstructionsLoaded`** | CLAUDE.md/rules 로드 시 | - |
| **`TeammateIdle`** | 팀원 에이전트 유휴 | 팀원 대기 감지 |
| **`TaskCompleted`** | 백그라운드 작업 완료 | 작업 완료 알림 |
| **`WorktreeCreate`** | 워크트리 생성 시 | - |
| **`WorktreeRemove`** | 워크트리 제거 시 | - |

### 3.2 Hook 입력 형식 (stdin JSON)

모든 훅은 stdin으로 JSON을 받는다:

```json
{
  "session_id": "abc123",
  "transcript_path": "/path/to/transcript.jsonl",
  "cwd": "/current/working/dir",
  "permission_mode": "default",
  "hook_event_name": "Stop",
  "agent_id": "optional-for-subagents",
  "agent_type": "optional-agent-type",
  "worktree": {
    "name": "worktree-name",
    "path": "/path/to/worktree",
    "branch": "branch-name",
    "original_repo_dir": "/path/to/repo"
  }
}
```

**이벤트별 추가 필드:**

| Event | 추가 필드 |
|-------|----------|
| `PreToolUse` / `PostToolUse` | `tool_name`, `tool_input`, `tool_result`(PostToolUse만) |
| `UserPromptSubmit` | `user_prompt` |
| `Stop` / `SubagentStop` | `reason` |

### 3.3 Hook 출력 형식 (stdout JSON)

**PreToolUse — 도구 실행 제어:**
```json
{
  "hookSpecificOutput": {
    "permissionDecision": "allow|deny|ask",
    "updatedInput": {"file_path": "/modified/path"}
  },
  "systemMessage": "이유 설명"
}
```

**Stop — 턴 종료 제어:**
```json
{
  "decision": "approve|block",
  "reason": "아직 테스트를 실행하지 않았습니다",
  "systemMessage": "추가 컨텍스트"
}
```

**일반 출력:**
```json
{
  "continue": true,
  "suppressOutput": false,
  "systemMessage": "Claude에게 전달할 메시지"
}
```

### 3.4 Hook 설정 방법

**사용자 설정 (`~/.claude/settings.json`):**
```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "curl -s -X POST http://localhost:27182/hook -d @-",
            "timeout": 5
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "AskUserQuestion",
        "hooks": [
          {
            "type": "command",
            "command": "curl -s -X POST http://localhost:27182/hook -d @-",
            "timeout": 5
          }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "curl -s -X POST http://localhost:27182/hook -d @-",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

**플러그인 (`hooks/hooks.json`):**
```json
{
  "description": "사용자 입력 대기 이벤트 감지",
  "hooks": {
    "Stop": [...],
    "PreToolUse": [...],
    "Notification": [...]
  }
}
```

### 3.5 종료 코드

| 코드 | 의미 |
|------|------|
| `0` | 성공 — stdout가 트랜스크립트에 표시됨 |
| `2` | 차단 — stderr가 Claude에게 전달됨 |
| 기타 | 비차단 오류 |

---

## 4. 사용자 입력 대기 감지 전략

### 전략 A: JSONL 파일 감시 (수동적, 비침투적)

Claude Code를 수정하지 않고 파일 시스템만 감시하는 방법.

```
[파일 감시 시작]
    ↓
새 JSONL 줄 읽기 → JSON 파싱
    ↓
┌─ type="system", subtype="turn_duration"
│   → 상태: WAITING (턴 종료, 사용자 입력 대기)
│   → 알림 트리거
│
├─ type="assistant", content에 tool_use 포함
│   ├─ name="AskUserQuestion"
│   │   → 상태: ASKING (사용자 선택 대기)
│   │   → 알림 트리거
│   │
│   └─ 기타 도구
│       → 상태: WORKING
│       → 7초 타이머 시작 (권한 대기 감지용)
│
├─ type="user", content에 tool_result 포함
│   → 도구 완료, 타이머 취소
│   → 상태: WORKING
│
├─ type="user", content가 문자열 (새 프롬프트)
│   → 상태: ACTIVE (사용자가 입력함)
│
├─ type="progress", data.type="agent_progress"
│   → 서브에이전트 활동 중
│
└─ type="progress", data.type="hook_progress"
    → 훅 실행 중 (비동기)
```

**파일 감시 구현 (3중 안전장치):**
1. `fs.watch()` — 이벤트 기반 (macOS에서 불안정할 수 있음)
2. `fs.watchFile()` — stat 기반 폴링 (1초 간격)
3. `setInterval()` — 수동 폴링 (최후의 보루)

### 전략 B: Hook HTTP 서버 (능동적, 실시간)

로컬 HTTP 서버를 띄우고 Claude Code Hook에서 이벤트를 POST하는 방법.

```
[로컬 HTTP 서버 (localhost:27182)]
    ↑
    POST /hook (JSON body)
    ↑
[Claude Code Hook]
    ├── Stop → {"session_id": "...", "reason": "완료"}
    ├── PreToolUse(AskUserQuestion) → {"tool_name": "AskUserQuestion", "tool_input": {...}}
    ├── Notification → {"..."}
    └── UserPromptSubmit → {"user_prompt": "..."} (사용자가 입력 재개)
```

**장점:**
- 실시간 감지 (JSONL 폴링 딜레이 없음)
- 이벤트 타입이 명확하게 구분됨
- 권한 대기를 추론할 필요 없음 (PreToolUse에서 직접 제어 가능)

**단점:**
- Claude Code 설정 변경 필요 (`settings.json`에 hooks 추가)
- 훅은 세션 시작 시에만 로드됨 (변경 후 재시작 필요)
- HTTP 서버가 응답하지 않으면 훅 타임아웃

### 전략 C: 둘 다 (Hook + JSONL) — 권장

Hook을 주 데이터 소스로, JSONL을 보조/백업으로 사용한다.

| 이벤트 | Hook 감지 | JSONL 감지 |
|--------|:---------:|:----------:|
| 턴 종료 | `Stop` 훅 | `turn_duration` 레코드 |
| 권한 대기 | `PreToolUse` 훅 (직접) | 타이머 기반 추정 |
| AskUserQuestion | `PreToolUse(AskUserQuestion)` | `tool_use` name 확인 |
| 사용자 입력 재개 | `UserPromptSubmit` 훅 | `user` 레코드 (새 프롬프트) |
| 알림 | `Notification` 훅 | 해당 없음 |
| 세션 시작/종료 | `SessionStart`/`SessionEnd` | 새 JSONL 파일 생성/마지막 레코드 |

---

## 5. JSONL 레코드 상세 스키마

### 5.1 assistant 레코드 (도구 사용)

```json
{
  "type": "assistant",
  "message": {
    "model": "claude-opus-4-6",
    "id": "msg_...",
    "role": "assistant",
    "content": [
      {
        "type": "text",
        "text": "파일을 읽어보겠습니다."
      },
      {
        "type": "tool_use",
        "id": "toolu_01ABC...",
        "name": "Read",
        "input": {
          "file_path": "/path/to/file.ts"
        },
        "caller": {"type": "direct"}
      }
    ],
    "usage": {
      "input_tokens": 15000,
      "cache_creation_input_tokens": 5000,
      "cache_read_input_tokens": 10000,
      "output_tokens": 500
    }
  },
  "requestId": "req_...",
  "uuid": "...",
  "timestamp": "ISO-8601"
}
```

### 5.2 user 레코드 (도구 결과)

```json
{
  "type": "user",
  "message": {
    "role": "user",
    "content": [
      {
        "type": "tool_result",
        "tool_use_id": "toolu_01ABC...",
        "content": "파일 내용...",
        "is_error": false
      }
    ]
  },
  "toolUseResult": {
    "stdout": "...",
    "stderr": "...",
    "interrupted": false,
    "isImage": false
  },
  "sourceToolAssistantUUID": "assistant-msg-uuid"
}
```

### 5.3 user 레코드 (새 사용자 프롬프트)

```json
{
  "type": "user",
  "userType": "external",
  "message": {
    "role": "user",
    "content": "새로운 사용자 요청 텍스트"
  },
  "permissionMode": "default"
}
```

### 5.4 progress 레코드 (서브에이전트)

```json
{
  "type": "progress",
  "parentToolUseID": "toolu_parent...",
  "toolUseID": "toolu_child...",
  "data": {
    "type": "agent_progress",
    "message": {
      "type": "assistant",
      "message": {
        "content": [
          {"type": "tool_use", "id": "toolu_sub...", "name": "Read", "input": {...}}
        ]
      }
    }
  }
}
```

### 5.5 progress 레코드 (Hook 실행)

```json
{
  "type": "progress",
  "data": {
    "type": "hook_progress",
    "hookEvent": "PostToolUse",
    "hookName": "PostToolUse:Read",
    "command": "callback"
  },
  "parentToolUseID": "toolu_...",
  "toolUseID": "toolu_..."
}
```

---

## 6. StatusLine — 보조 상태 정보

Claude Code의 `statusLine` 설정으로 커스텀 스크립트가 실행되며, 스크립트는 stdin으로 현재 상태 JSON을 받는다:

```json
{
  "session_id": "session-uuid",
  "version": "2.1.71",
  "cwd": "/current/dir",
  "model": {
    "display_name": "Claude Opus 4.6",
    "version": "claude-opus-4-6"
  },
  "workspace": {
    "current_dir": "/current/dir",
    "added_dirs": ["/extra/dir"]
  },
  "output_style": {
    "name": "style-name"
  }
}
```

StatusLine은 사용자 입력 대기를 직접 감지하는 용도는 아니지만, 세션 메타데이터(모델, 디렉토리 등)를 실시간으로 얻을 수 있다.

---

## 7. 도구 이름 → 애니메이션 상태 매핑

외부 시각화 도구에서 도구 이름에 따라 캐릭터 상태를 결정할 때의 참고 매핑:

| 도구 이름 | 동작 분류 | 시각적 상태 |
|-----------|----------|------------|
| `Read` | 읽기 | Reading 애니메이션 |
| `Grep`, `Glob` | 검색 | Reading 애니메이션 |
| `WebFetch`, `WebSearch` | 웹 조회 | Reading 애니메이션 |
| `Edit`, `Write` | 파일 수정 | Typing 애니메이션 |
| `Bash` | 명령 실행 | Typing 애니메이션 |
| `Task` (Agent) | 서브에이전트 생성 | 새 캐릭터 스폰 |
| `AskUserQuestion` | 사용자 질문 | **입력 대기 (말풍선)** |
| `EnterPlanMode` | 계획 수립 | Typing 애니메이션 |
| `NotebookEdit` | 노트북 편집 | Typing 애니메이션 |
| `ToolSearch` | 도구 탐색 | Reading 애니메이션 |

---

## 8. 타이밍 상수 참고

| 상수 | 권장 값 | 용도 |
|------|--------|------|
| JSONL 폴링 간격 | 1000ms | 파일 변경 감시 |
| 권한 대기 임계값 | 7000ms | tool_use 후 응답 없으면 권한 대기 추정 |
| 텍스트 idle 임계값 | 5000ms | 텍스트 전용 응답 후 입력 대기 판단 |
| 도구 완료 딜레이 | 300ms | 도구 완료 표시 전 짧은 대기 |
| 프로젝트 스캔 간격 | 1000ms | 새 JSONL 파일 탐지 (/clear 감지) |

---

## 9. 제한사항 및 주의사항

1. **JSONL에 명시적 "permission waiting" 레코드가 없다** — 권한 대기는 "tool_use 후 일정 시간 내 tool_result가 없음"으로 간접 추정해야 한다
2. **텍스트 전용 턴에서 `turn_duration`이 발행되지 않을 수 있다** — 침묵 기반 타이머가 필요하다
3. **Hook은 세션 시작 시에만 로드된다** — 설정 변경 후 Claude Code 재시작 필요
4. **모든 매칭 Hook은 병렬 실행된다** — 실행 순서를 보장할 수 없다
5. **Hook 타임아웃** — 커맨드 훅 기본 60초, 프롬프트 훅 기본 30초
6. **macOS에서 `fs.watch()`가 불안정** — 반드시 폴링 백업 필요
7. **바이너리 패키지** — Claude Code는 Bun 컴파일 바이너리로 배포되어 소스 코드 직접 분석이 불가능

---

## 10. 실전 구현 예시: 입력 대기 감지 Hook 설정

`~/.claude/settings.json`에 추가:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "echo '{\"event\":\"turn_end\",\"session_id\":\"'$SESSION_ID'\"}' | curl -s -X POST -H 'Content-Type: application/json' -d @- http://localhost:27182/claude-event 2>/dev/null; exit 0",
            "timeout": 3
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "AskUserQuestion",
        "hooks": [
          {
            "type": "command",
            "command": "input=$(cat); echo \"$input\" | curl -s -X POST -H 'Content-Type: application/json' -d @- http://localhost:27182/claude-event 2>/dev/null; exit 0",
            "timeout": 3
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "echo '{\"event\":\"user_input\"}' | curl -s -X POST -H 'Content-Type: application/json' -d @- http://localhost:27182/claude-event 2>/dev/null; exit 0",
            "timeout": 3
          }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "input=$(cat); echo \"$input\" | curl -s -X POST -H 'Content-Type: application/json' -d @- http://localhost:27182/claude-event 2>/dev/null; exit 0",
            "timeout": 3
          }
        ]
      }
    ]
  }
}
```

이 설정으로 로컬 HTTP 서버에서 다음 이벤트를 실시간으로 수신할 수 있다:
- **턴 종료** → `Stop` 훅 → 사용자 입력 대기 상태
- **AskUserQuestion** → `PreToolUse` 훅 → 사용자 선택 대기
- **사용자 입력 재개** → `UserPromptSubmit` 훅 → 작업 재개
- **알림** → `Notification` 훅 → 에이전트 알림 발생
