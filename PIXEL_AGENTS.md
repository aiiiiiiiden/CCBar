# Pixel Agents - 프로젝트 분석 문서

## 개요

**Pixel Agents**는 VS Code 익스텐션으로, Claude Code 터미널 에이전트를 픽셀 아트 캐릭터로 시각화하는 가상 오피스 환경이다. 각 Claude Code 터미널을 열면 캐릭터가 생성되어 오피스를 돌아다니고, 책상에 앉아 작업하며, 에이전트의 실제 활동(코드 작성, 파일 검색, 명령 실행 등)에 따라 애니메이션이 변화한다.

- **저장소**: https://github.com/pablodelucca/pixel-agents
- **라이선스**: MIT
- **기술 스택**: TypeScript, VS Code Webview API, esbuild (Extension) / React 19, Vite, Canvas 2D (Webview)

---

## 디렉토리 구조

```
pixel-agents/
├── src/                          # VS Code Extension (백엔드)
│   ├── extension.ts              # 익스텐션 진입점 (activate/deactivate)
│   ├── PixelAgentsViewProvider.ts # WebviewViewProvider - 핵심 컨트롤러
│   ├── agentManager.ts           # 에이전트 생명주기 관리 (생성/제거/복원/영속화)
│   ├── fileWatcher.ts            # JSONL 파일 감시 및 프로젝트 스캔
│   ├── transcriptParser.ts       # Claude Code JSONL 트랜스크립트 파싱
│   ├── timerManager.ts           # 대기/권한 타이머 관리
│   ├── assetLoader.ts            # 스프라이트/타일셋 에셋 로딩
│   ├── layoutPersistence.ts      # 레이아웃 파일 저장/로드/동기화
│   ├── types.ts                  # AgentState, PersistedAgent 타입
│   └── constants.ts              # 타이밍, 표시, 식별자 상수
├── webview-ui/                   # Webview UI (프론트엔드, React + Vite)
│   └── src/
│       ├── App.tsx               # React 루트 컴포넌트
│       ├── hooks/
│       │   ├── useExtensionMessages.ts  # Extension↔Webview 메시지 핸들러
│       │   ├── useEditorActions.ts      # 레이아웃 에디터 액션
│       │   └── useEditorKeyboard.ts     # 에디터 키보드 단축키
│       ├── office/
│       │   ├── engine/
│       │   │   ├── officeState.ts   # OfficeState 클래스 - 게임 상태 관리
│       │   │   ├── characters.ts    # 캐릭터 FSM (상태머신) 및 업데이트
│       │   │   ├── gameLoop.ts      # requestAnimationFrame 게임 루프
│       │   │   ├── renderer.ts      # Canvas 2D 렌더링 (타일, 가구, 캐릭터, 버블)
│       │   │   └── matrixEffect.ts  # 매트릭스 스폰/디스폰 이펙트
│       │   ├── layout/
│       │   │   ├── layoutSerializer.ts  # 레이아웃 ↔ 타일맵/가구/좌석 변환
│       │   │   ├── tileMap.ts           # BFS 경로탐색, 이동 가능 타일 판별
│       │   │   └── furnitureCatalog.ts  # 가구 카탈로그 (정적/동적)
│       │   ├── sprites/             # 스프라이트 캐싱 및 데이터
│       │   ├── editor/              # 레이아웃 에디터 (EditorToolbar, editorState)
│       │   ├── components/          # OfficeCanvas, ToolOverlay
│       │   └── types.ts             # Character, OfficeLayout, Seat 등 타입
│       └── components/              # BottomToolbar, ZoomControls, DebugView 등
├── scripts/                         # 에셋 빌드 스크립트
├── esbuild.js                       # Extension 번들링
└── package.json                     # VS Code contributes 정의
```

---

## 핵심 동작 원리

### 1. 에이전트 추적 — JSONL 트랜스크립트 감시

Pixel Agents의 핵심은 **Claude Code가 생성하는 JSONL 트랜스크립트 파일을 관찰**하는 것이다. Claude Code를 수정하지 않고, 순수하게 파일 시스템 감시만으로 동작한다.

```
~/.claude/projects/<workspace-dir-name>/<session-id>.jsonl
```

**파일 감시 전략** (`fileWatcher.ts`):
- `fs.watch()` — 기본 이벤트 기반 감시 (macOS에서 불안정)
- `fs.watchFile()` — stat 기반 폴링 (macOS 호환, 1초 간격)
- `setInterval()` 폴링 — 최후의 안전장치

**읽기 방식** (`readNewLines()`):
- `fileOffset`으로 마지막 읽은 위치를 추적
- 새로운 바이트만 `Buffer.alloc`으로 읽어 줄 단위 파싱
- 불완전한 줄은 `lineBuffer`에 보관하여 다음 읽기와 결합

### 2. 트랜스크립트 파싱 — 에이전트 상태 감지

`transcriptParser.ts`가 JSONL의 각 레코드를 파싱하여 에이전트 상태를 결정한다:

| JSONL 레코드 타입 | 감지 내용 | 결과 |
|---|---|---|
| `assistant` + `tool_use` 블록 | 도구 사용 시작 | `agentToolStart` → 캐릭터 typing/reading 애니메이션 |
| `user` + `tool_result` 블록 | 도구 사용 완료 | `agentToolDone` → 도구 완료 표시 |
| `system` + `turn_duration` | 턴 종료 | `agentStatus: waiting` → 캐릭터 idle + 말풍선 |
| `assistant` + `text` (도구 없음) | 텍스트 전용 응답 | 5초 무활동 시 waiting 상태 전환 |
| `progress` + `agent_progress` | 서브에이전트(Task tool) 활동 | 서브에이전트 캐릭터 생성/업데이트 |

**도구별 애니메이션 분류**:
- **Typing 애니메이션**: Edit, Write, Bash, Task, EnterPlanMode 등 (쓰기 계열)
- **Reading 애니메이션**: Read, Grep, Glob, WebFetch, WebSearch (읽기 계열)

**권한 대기 감지** (`timerManager.ts`):
- 도구 시작 후 7초(`PERMISSION_TIMER_DELAY_MS`) 내에 결과가 오지 않으면 → 권한 대기 상태로 판단
- `bash_progress`, `mcp_progress` 이벤트가 오면 타이머 리셋 (실행 중이므로)
- 권한 대기 시 `permission` 말풍선 표시

### 3. 에이전트 생명주기

```
[+ Agent 버튼 클릭]
    ↓
launchNewTerminal()
    ├── vscode.window.createTerminal() → "Claude Code #N"
    ├── terminal.sendText(`claude --session-id <uuid>`)
    ├── AgentState 생성 (id, terminalRef, jsonlFile 등)
    ├── webview.postMessage({ type: 'agentCreated' })
    └── setInterval()로 JSONL 파일 출현 대기 (1초 폴링)
            ↓ (파일 발견 시)
        startFileWatching() → readNewLines() → processTranscriptLine()
```

**복원 (세션 재시작 시)**:
- `workspaceState`에 `PersistedAgent[]` 저장
- 복원 시 기존 터미널 목록에서 이름으로 매칭
- JSONL 파일의 끝부터 감시 시작 (`fileOffset = stat.size`)

**`/clear` 감지** (프로젝트 스캔):
- 1초 간격으로 프로젝트 디렉토리의 `.jsonl` 파일 목록 스캔
- 새로운 JSONL 파일 발견 시 → 활성 에이전트에 재할당 또는 외부 터미널 채택

### 4. Extension ↔ Webview 통신

VS Code Webview API의 `postMessage` 기반 양방향 통신:

**Extension → Webview (상태 업데이트)**:
| 메시지 타입 | 용도 |
|---|---|
| `agentCreated` / `agentClosed` | 에이전트 생성/제거 |
| `agentToolStart` / `agentToolDone` | 도구 사용 시작/완료 |
| `agentStatus` | active/waiting 상태 전환 |
| `agentToolPermission` | 권한 대기 감지 |
| `subagentToolStart` / `subagentClear` | 서브에이전트 도구 활동 |
| `layoutLoaded` | 레이아웃 데이터 전송 |
| `characterSpritesLoaded` / `furnitureAssetsLoaded` | 에셋 전송 |

**Webview → Extension (사용자 액션)**:
| 메시지 타입 | 용도 |
|---|---|
| `openClaude` | 새 에이전트 생성 요청 |
| `focusAgent` | 에이전트 터미널 포커스 |
| `closeAgent` | 에이전트 종료 |
| `saveLayout` / `exportLayout` / `importLayout` | 레이아웃 관리 |
| `saveAgentSeats` | 좌석 배정 영속화 |
| `webviewReady` | 초기화 완료 신호 |

---

## 게임 엔진 (Webview)

### 캐릭터 상태머신 (FSM)

```
         [에이전트 활성화]
              ↓
    ┌─── TYPE (타이핑/읽기) ◄──────────────┐
    │         │                             │
    │   [에이전트 비활성화]               [좌석 도착 + 활성]
    │         ↓                             │
    │    IDLE (대기)                         │
    │    ├── wanderTimer 카운트다운          │
    │    ├── 랜덤 타일로 이동 결정          │
    │    └── wanderLimit 도달 → 좌석 복귀   │
    │         ↓                             │
    └──► WALK (이동) ──────────────────────┘
           ├── BFS 경로 따라 타일 간 이동
           ├── 이동 중 활성화 → 좌석으로 재경로
           └── 도착 → TYPE or IDLE
```

**이동 시스템**:
- 16x16 픽셀 타일 그리드 기반
- BFS (너비우선탐색) 경로탐색 — 4방향 연결 (대각선 없음)
- `WALK_SPEED_PX_PER_SEC` 속도로 타일 간 선형 보간 이동
- 가구 footprint에 의한 블로킹 타일 처리

**배회(Wander) 시스템**:
- 비활성 캐릭터는 랜덤 타일로 이동 후 일정 시간 대기 반복
- `wanderCount`가 `wanderLimit`에 도달하면 좌석으로 복귀하여 휴식
- 휴식 후 다시 배회 사이클 반복

### 렌더링

- `requestAnimationFrame` 기반 게임 루프 (`gameLoop.ts`)
- Canvas 2D 렌더링, `imageSmoothingEnabled = false` (픽셀 퍼펙트)
- **Z 정렬**: 가구와 캐릭터를 Y 좌표 기반으로 정렬하여 올바른 오클루전
- **스프라이트 캐싱**: 줌 레벨별로 캐시된 캔버스 이미지 재사용
- **색상화**: HSB 기반 바닥/벽/가구 색상 커스터마이징

### 시각적 피드백

| 시각 요소 | 트리거 |
|---|---|
| Typing 애니메이션 | 코드 작성, 편집, Bash 실행 |
| Reading 애니메이션 | 파일 읽기, 검색, 웹 페치 |
| Permission 말풍선 (!) | 도구 실행 7초 초과 (권한 대기 추정) |
| Waiting 말풍선 (?) | 턴 종료 후 사용자 입력 대기 |
| Matrix 스폰 이펙트 | 캐릭터 생성 시 |
| Matrix 디스폰 이펙트 | 캐릭터 제거 시 |
| 전자기기 ON 상태 | 활성 에이전트가 앉은 책상의 모니터/PC 자동 켜짐 |
| 알림 사운드 | 에이전트가 waiting 상태 전환 시 (선택 사항) |

### 서브에이전트 (Task Tool)

Claude Code의 Task tool로 생성된 서브에이전트는 별도 캐릭터로 시각화된다:
- 부모 에이전트와 동일한 팔레트 사용
- 부모에게 가장 가까운 빈 좌석에 배치
- `progress` 레코드의 `agent_progress` 데이터로 도구 활동 추적
- Task 완료 시 Matrix 디스폰 이펙트로 제거

---

## 레이아웃 시스템

### 데이터 구조

```typescript
interface OfficeLayout {
  version: 1;
  cols: number;           // 그리드 너비 (최대 64)
  rows: number;           // 그리드 높이 (최대 64)
  tiles: TileType[];      // 1D 배열 (row-major): WALL(0), FLOOR_1-7(1-7), VOID(8)
  furniture: PlacedFurniture[];  // 배치된 가구 목록
  tileColors?: FloorColor[];    // 타일별 HSB 색상 (tiles와 병렬)
}
```

### 좌석(Seat) 시스템

- 의자(chair) 카테고리 가구 배치 시 자동으로 좌석 생성
- 좌석 방향: 의자 orientation → 인접 책상 방향 → 기본 DOWN
- 에이전트 생성 시 빈 좌석에 자동 배정
- 클릭으로 좌석 재배정 가능 (캐릭터가 걸어서 이동)

### 영속화

- **레이아웃**: `~/.pixel-agents/layout.json` (모든 VS Code 윈도우에서 공유)
- **에이전트 정보**: VS Code `workspaceState` (워크스페이스별)
- **좌석 배정**: `workspaceState`의 별도 키 (`pixel-agents.agentSeats`)
- **사운드 설정**: VS Code `globalState`
- 다중 윈도우 동기화: 레이아웃 파일 변경 감지 (`watchLayoutFile`)

### 에디터

내장 레이아웃 에디터 제공:
- **도구**: 선택(Select), 바닥 페인트, 벽 페인트, 가구 배치, 지우개, 스포이드, 피커
- **Undo/Redo**: 50단계
- **그리드 확장**: 격자 외곽의 고스트 보더 클릭으로 최대 64x64까지 확장
- **가구 회전**: R 키로 회전 가능한 가구 회전
- **Import/Export**: JSON 파일로 레이아웃 내보내기/가져오기

---

## 캐릭터 시스템

- **6가지 다양한 캐릭터 팔레트** (0-5)
- 6개 이상의 에이전트 시 → 사용 횟수가 가장 적은 팔레트 재사용 + 랜덤 hue shift (45도 이상)
- **방향**: DOWN(0), LEFT(1), RIGHT(2), UP(3)
- **프레임**: 16x32 픽셀 스프라이트 시트에서 추출
- **스프라이트 종류**: walk(4프레임), typing(2프레임), reading(2프레임) × 방향별

---

## 주요 상수

| 상수 | 값 | 용도 |
|---|---|---|
| `JSONL_POLL_INTERVAL_MS` | 1000ms | JSONL 파일 출현 폴링 |
| `FILE_WATCHER_POLL_INTERVAL_MS` | 1000ms | 파일 변경 감시 폴링 |
| `PERMISSION_TIMER_DELAY_MS` | 7000ms | 권한 대기 감지 임계값 |
| `TEXT_IDLE_DELAY_MS` | 5000ms | 텍스트 전용 응답의 idle 감지 |
| `TILE_SIZE` | 16px | 타일 한 변 크기 |
| `CHAR_COUNT` | 6 | 캐릭터 팔레트 수 |
| `MAX_COLS` / `MAX_ROWS` | 64 | 그리드 최대 크기 |

---

## 알려진 제한사항

1. **에이전트-터미널 동기화** — 터미널을 빠르게 열고 닫거나 세션 복원 시 연결이 끊어질 수 있음
2. **휴리스틱 기반 상태 감지** — Claude Code의 JSONL에 명확한 "사용자 입력 대기" 신호가 없어 타이머 기반 추정 사용
3. **플랫폼 테스트** — 원래 Windows 11에서만 테스트됨 (macOS/Linux에서 파일 감시 이슈 가능)

---

## 빌드 및 실행

```bash
git clone https://github.com/pablodelucca/pixel-agents.git
cd pixel-agents
npm install
cd webview-ui && npm install && cd ..
npm run build
# F5로 Extension Development Host 실행
```

- Extension 빌드: `esbuild` → `dist/extension.js`
- Webview 빌드: `Vite` → `dist/webview/`
- 가구 타일셋(유료)은 별도 구매 후 `npm run import-tileset`으로 임포트
