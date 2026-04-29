# Guide v2 — Web dashboard with embedded persistent shell

**Date:** 2026-04-29
**Status:** Draft (design approved by user; ready for implementation plan)
**Supersedes:** `2026-04-26-derekh-tui-design.md` (the PowerShell TUI is being retired)

## Summary

Replace the PowerShell TUI renderer in `tools/guide/` with a Bun-based web dashboard hosting an embedded persistent shell. The dashboard renders plan execution (phases, active item, issues) in a sidebar; the main canvas is an `xterm.js` output pane fed by long-lived `pwsh` and `bash` PTYs, multiplexed through prefix routing (`!` → bash, `#` → pwsh). A standalone `--shell` mode launches just the shell without a plan. Plan events flow from PowerShell to the Bun server over a localhost TCP/JSONL socket; browser↔server communication uses WebSocket. SQLite (via `bun:sqlite`) persists command history and plan-run snapshots.

## Goals

- One renderer to maintain (web), not three (TUI / streaming / headless).
- A shell that's always available — during plan execution and after — without leaving the dashboard.
- xterm.js handles the hard parts (ANSI, scrollback, copy/paste, search) so we don't reinvent them.
- Cross-platform with no per-OS rendering quirks (the PS-TUI's off-by-one and resize-watcher bugs are eliminated by construction).
- Headless / CI contract preserved (`bun guide --headless` consumes JSONL on stdin, emits final plan JSON on stdout).

## Non-goals (v1)

- HTTP/3 / QUIC (no benefit on localhost).
- Raw-mode interactive TUIs inside the shell pane (`vim`, `less`, `fzf` are excluded; line-based input only).
- Cross-machine sync of history.
- Plan replay from the `plan_runs` table (schema reserved; UI deferred).
- Plug-in shells beyond pwsh and bash (zsh, nu, fish are straightforward later additions).
- Multi-user authentication (server is loopback-only; same-user access is the trust boundary).

## Decisions log (from brainstorming)

| ID | Question | Decision |
|---|---|---|
| Q1 | When is the shell available? | Always during plan execution, plus standalone `--shell` mode |
| Q2 | Layout | Sidebar (phases / active / issues / history) + main `xterm.js` + bottom prompt |
| Q3 | Default shell | `--default-shell=pwsh\|bash` flag with OS-default fallback |
| Q4 | Lifecycle | Independent server; quit only on explicit user action, Ctrl+C, or 30s no-clients-and-no-plan |
| Q5 | PowerShell module's role | Event emitter only — all rendering moves to Bun |
| Q6 | Architectural approach | Approach 1: single Bun server, transient PS emitters |
| Q7 | Multi-line paste | Whole textarea blob sent as one `shell-line`; shell parses newlines |
| Q8 | History persistence | SQLite (`bun:sqlite`) at per-user path, not localStorage |

## Architecture

```
┌─ Bun server (long-lived, port 7771) ────────────────────────┐
│  HTTP+WS for browser  •  TCP socket (port+1) for events     │
│  Manages pwsh + bash PTYs lazily                            │
│  bun:sqlite for history + plan_runs                         │
└─────────────────────────────────────────────────────────────┘
        ▲                                    ▲
        │ WebSocket                          │ TCP/JSONL
        │                                    │
┌───────┴─────────┐                ┌─────────┴──────────────┐
│ Browser         │                │ bootstrap.ps1 (or any  │
│ xterm.js +      │                │ PS plan emitter)       │
│ sidebar dashboard│               │                        │
└─────────────────┘                └────────────────────────┘
```

One Bun process, started via `bun guide` or auto-spawned by `bun bootstrap.ts` if not already running on 7771. PS emitter connects to `localhost:<port+1>`, streams JSONL events: `plan-started`, `phase-started`, `phase-result`, `issue-emitted`, `plan-completed`. Pure emit; no bidirectional traffic. Multiple sequential plan runs all flow into the same dashboard.

## File layout

```
tools/guide/
├── server.ts                # Bun server entry — Bun.serve + WS + plan socket
├── package.json             # bun deps minimal (xterm.js vendored as static asset)
├── lib/
│   ├── pty.ts               # PTY manager: spawn pwsh/bash, route stdin/stdout
│   ├── events.ts            # plan-event types + JSONL parser/serializer
│   ├── state.ts             # in-memory plan state (phases, issues, active)
│   ├── ws.ts                # WebSocket wire protocol (client↔server)
│   ├── db.ts                # bun:sqlite wrapper, schema, migrations
│   └── port.ts              # port allocation (try 7771; fall back upward)
├── public/
│   ├── index.html           # single page
│   ├── style.css            # CSS grid: sidebar 240px / main 1fr; bottom prompt
│   ├── app.js               # vanilla JS: WS client, sidebar render, prefix routing
│   ├── xterm.js             # vendored (~250kb)
│   └── xterm.css
├── ps/
│   ├── guide.psm1           # SHRUNK: plan builders + Connect-/Send-GuideEvent
│   ├── guide.psd1           # exports ~12 functions (down from 50+)
│   └── lib/
│       ├── plan.ps1         # KEEP — pure plan/result/alert constructors
│       ├── state.ps1        # KEEP — in-memory state during phase execution
│       ├── emit.ps1         # NEW — TCP client, JSONL writer, reconnect
│       └── streaming.ps1    # KEEP (smaller) — stdout fallback when no Bun
└── tests/
    ├── ps/                  # ~115 PS tests (plan/state/emit/skeleton)
    ├── server/              # ~80 Bun unit tests (events/state/ws/pty/port/db/routing/headless)
    ├── browser/             # ~40 happy-dom tests (prefix-routing/history/sidebar/multi-line/ws)
    └── e2e/                 # ~10 Playwright tests (server-up/plan-flow/shell-roundtrip/persistence)
```

### Files deleted from current `tools/guide/`

`lib/render.ps1`, `lib/input.ps1`, `lib/headless.ps1`, `lib/theme.ps1`, `lib/layout.ps1`, `lib/clipboard.ps1`, `lib/environment.ps1`, `themes/twilight.json`, `themes/cozy.json`. All TUI-related tests (~350 cases) deleted; theming moves to CSS.

## Wire protocols

### PowerShell → Bun server (TCP, JSONL)

PS emitter connects once per plan run; sends one JSON object per line; closes when plan completes (or server detects EOF). All events carry `ts` (ISO-8601) and `planId` (UUID generated on `plan-started`).

```
plan-started      { type, planId, title, subtitle, phases:[{name,type,totalItems?}] }
phase-started     { type, planId, phaseName, phaseIndex, phaseTotal }
active-changed    { type, planId, label }
phase-result      { type, planId, phaseName, itemLabel, success, message,
                    severity, fixCommand?, alerts? }
phase-completed   { type, planId, phaseName, status:'ok'|'warn'|'fail' }
issue-emitted     { type, planId, severity, message, fixCommand?, sourcePhase, sourceItem? }
alert-emitted     { type, planId, severity, message, sourcePhase }
plan-completed    { type, planId, exitCode }
heartbeat         { type, planId }                  # every 5s
```

### Bun server → Browser (WebSocket, JSON)

Sent on connect: full snapshot for late-joiners. Then incremental.

`shell` is `'pwsh' | 'bash'` and uniquely identifies a PTY (one PTY per kind by construction).

```
server-info       { type, defaultShell, mode:'plan'|'shell-only', port }
plan-snapshot     { type, plan: { ...full reconstructed state... } }
plan-update       { type, ...PS event payload pass-through }
shell-spawned     { type, shell, cwd, cols, rows }
shell-spawned-error { type, shell, error }
shell-output      { type, shell, data: base64 }     # raw PTY bytes (ANSI intact)
shell-exit        { type, shell, code }
history-page      { type, entries:[…], hasMore:bool }
history-appended  { type, entry }
history-updated   { type, id, exit_code, duration_ms }
plan-runs-page    { type, runs:[…] }
```

### Browser → Bun server (WebSocket, JSON)

```
shell-line        { type, shell:'pwsh'|'bash', text:'...' }   # appends \n server-side
shell-signal      { type, shell, signal:'SIGINT'|'SIGTERM' }
shell-spawn       { type, shell }                             # lazy spawn on first use
shell-resize      { type, shell, cols, rows }
history-list      { type, scope:'workspace'|'all', limit, before? }
history-search    { type, query, limit }
history-delete    { type, id }
history-clear     { type, scope }
plan-runs-list    { type, workspace?, limit }
quit              { type }                                    # explicit shutdown
```

### Prefix routing (browser side, `app.js`)

```js
if      (line.startsWith('!')) send({ type:'shell-line', shell:'bash', text:line.slice(1) })
else if (line.startsWith('#')) send({ type:'shell-line', shell:'pwsh', text:line.slice(1) })
else                            send({ type:'shell-line', shell:defaultShell, text:line })
```

`defaultShell` comes from `server-info` on connect. Multi-line paste: prefix is detected from the first character of the whole textarea blob; subsequent lines are literal text routed to the same shell.

## Bun server internals

### Entry point (`server.ts`)

```ts
const server = Bun.serve({
  port: await pickPort(7771),
  hostname: '127.0.0.1',
  fetch(req, srv) {
    const url = new URL(req.url)
    if (url.pathname === '/')                    return staticFile('public/index.html')
    if (url.pathname === '/healthz')             return new Response(JSON.stringify({ guide:true, planId }))
    if (url.pathname.startsWith('/static/'))     return staticFile(url.pathname)
    if (url.pathname === '/ws' && srv.upgrade(req)) return
    return new Response('not found', { status: 404 })
  },
  websocket: { open, message, close }
})

Bun.listen({
  hostname: '127.0.0.1',
  port: server.port + 1,
  socket: { open: onPsConnect, data: onPsData, close: onPsClose }
})
```

### Plan state store (`lib/state.ts`)

Single in-memory object keyed by `planId`. Multiple sequential plans retained; most recent is "active." Each event mutates state and broadcasts a `plan-update` to all WS clients.

```ts
type PlanState = {
  planId: string
  title: string; subtitle: string
  startedAt: string; completedAt: string | null; exitCode: number | null
  phases: Phase[]
  active: { phaseName: string; itemLabel: string } | null
  issues: Issue[]; alerts: Alert[]
  lastHeartbeat: string
}
```

### PTY manager (`lib/pty.ts`)

Lazy spawn — no PTY exists until a `shell-spawn` or implicit `shell-line`. Once spawned, lives until process exit or server shutdown.

```ts
class PtyManager {
  shells = new Map<'pwsh'|'bash', Pty>()

  async ensure(kind): Promise<Pty> {
    if (this.shells.has(kind)) return this.shells.get(kind)!
    const cmd = kind === 'pwsh' ? ['pwsh', '-NoProfile', '-NoLogo']
                                : [bashPath(), '--login']
    const pty = await spawnPty(cmd, { cwd: process.cwd(), env, cols: 100, rows: 30 })
    pty.onData(chunk => broadcastWS({ type:'shell-output', shellId:kind, data:b64(chunk) }))
    pty.onExit(code => { this.shells.delete(kind); broadcastWS({ type:'shell-exit', shellId:kind, code }) })
    this.shells.set(kind, pty); return pty
  }

  write(kind, text)   { this.ensure(kind).then(p => p.write(text + '\n')) }
  signal(kind, sig)   { this.shells.get(kind)?.kill(sig) }
  resize(kind, c, r)  { this.shells.get(kind)?.resize(c, r) }
}
```

**PTY library:** `bun-pty` if its API is stable; `node-pty` via Bun's Node compat as fallback. Bound behind `spawnPty()` for swap-ability.

**Git Bash detection on Windows:** `bashPath()` returns first existing of: `$env:GIT_BASH_PATH`, `C:\Program Files\Git\bin\bash.exe`, `(Get-Command bash).Source`. Fails with a clear "install Git for Windows or set GIT_BASH_PATH" message.

### Sentinel injection for command completion

Server appends `\necho __GUIDE_DONE_<8-hex>__` (pwsh: `Write-Host`) after the user's text; watches PTY output for the random sentinel; on match, marks the history row's `exit_code` and `duration_ms`, strips the sentinel line from xterm forwarding. 30s no-output timer transitions UI to "Long-running…" without falsely marking complete. Random sentinel per command avoids collisions with user heredocs.

### Browser auto-launch

```ts
const url = `http://127.0.0.1:${server.port}/`
console.log(`Guide running at ${url}  (events on :${server.port+1})`)
if (!process.env.GUIDE_NO_OPEN && !args.headless) await openBrowser(url)
```

`openBrowser()` shells out to platform default: `start "" <url>` (Windows), `open <url>` (macOS), `xdg-open <url>` (Linux/WSL) with print-URL fallback.

If a guide server is already running on 7771, the new launch detects it via `/healthz` and skips spawning; the new PS emitter just connects. Same dashboard, sequential plans.

### Quit handling

Three converging paths:

1. Explicit `quit` WS message from browser.
2. Ctrl+C (SIGINT) in launching terminal.
3. All browser clients disconnected for >30s **and** no plan currently running.

`gracefulShutdown()` kills PTYs, closes WS clients with reason, releases ports, exits 0.

## Browser dashboard

### Layout (CSS grid)

```
┌──────────────┬────────────────────────────────────────────────┐
│ Phases       │  Shell output (xterm.js, scrollback 5000 lines)│
│ Active       │                                                │
│ Issues  [N]  │  pwsh# Get-ChildItem                           │
│ ▾ History    │  ...output...                                  │
│              │  bash$ ls -la                                  │
│              │  ...output...                                  │
├──────────────┴────────────────────────────────────────────────┤
│ ❯ <textarea, auto-grow up to 8 rows>                          │
│    ! bash · # pwsh                          Running… [Ctrl+C] │
└────────────────────────────────────────────────────────────────┘
```

```css
#app {
  display: grid;
  grid-template-columns: 240px 1fr;
  grid-template-rows:    1fr auto;
  grid-template-areas:
    "sidebar shell"
    "prompt  prompt";
  height: 100vh;
}
```

Theme colors as CSS variables on `:root`, lifted from current `twilight.json` palette.

### Sidebar render

Imperative DOM updates (no virtual DOM). Each WS message triggers a targeted patch:

- **Phases**: `<ul>` of items with status glyph (`✓` ok, `◐` running, `✗` fail, `○` pending).
- **Active**: phase name → item label, or "Waiting…" when nothing running.
- **Issues**: numbered `<ol>`; click `[N]` → `navigator.clipboard.writeText(fixCommand)` → flash "Copied" toast.
- **History**: collapsed by default during plan runs; auto-expands on prompt focus or `Ctrl+H`. Shows command text + shell glyph + relative timestamp + (red dot if non-zero exit). Click recalls; double-click re-runs; right-click context menu (Copy / Re-run / Delete).

### Prompt input

Bottom is a `<textarea>` (not `<input>`):

| Key | Action |
|---|---|
| `Enter` | submit |
| `Shift+Enter` | newline (multi-line typing) |
| Paste | preserved verbatim, multi-line OK |
| `↑` / `↓` (in empty prompt or while in history) | walk history |
| `Ctrl+L` | clear xterm scrollback |
| `Ctrl+C` (empty prompt) | send SIGINT to the running shell |
| `Ctrl+H` | focus / open History |
| `Ctrl+K` | focus prompt |
| `Esc` | blur prompt |

History stored in SQLite (browser hits `history-list` on connect); in-memory cache for ↑/↓ recall.

**Concurrency:** v1 runs **one command at a time across both shells** — the prompt is read-only with a "Running…" indicator from submit until the active shell's sentinel arrives. Submitting a `!bash` command while a `#pwsh` command is still running is rejected with a brief flash. This keeps xterm output unambiguously attributable and avoids race conditions in sentinel detection. Concurrent multi-shell execution is reserved for a follow-up.

### xterm.js wiring

```ts
const term = new Terminal({ fontFamily:'Cascadia Mono, Menlo, monospace', cursorBlink:false, scrollback:5000 })
const fit  = new FitAddon(); term.loadAddon(fit); term.open(termEl); fit.fit()
new ResizeObserver(() => { fit.fit(); send({ type:'shell-resize', shell:'pwsh', cols:term.cols, rows:term.rows }) }).observe(termEl)
```

Both shells share one xterm instance. Server prepends a per-command attribution line (`pwsh# <cmd>` or `bash$ <cmd>`) so the transcript stays attributable.

## Standalone `--shell` mode

Same server, no plan event source.

```bash
bun guide --shell
bun guide --shell --default-shell=bash
bun guide --shell --workspace=<dir>
```

| | Plan mode | Shell-only |
|---|---|---|
| TCP plan-events socket | Open | **Closed** |
| `mode` in `server-info` | `plan` | `shell-only` |
| Sidebar | All four sections | History-only; "Last plan" summary at top |
| SQLite `history` writes | Yes | Yes |
| SQLite `plan_runs` writes | Yes | N/A |

In shell-only mode, the sidebar collapses Phases/Active/Issues into a single "Last plan" summary line (sourced from the most recent `plan_runs` row). Click to expand for context.

## CLI

```
bun guide [options]
  --shell                      Standalone mode
  --plan                       Plan mode (default)
  --default-shell=pwsh|bash    Default shell when no prefix
  --workspace=<path>           cwd for spawned PTYs and history filter
  --port=<n>                   Force HTTP port (default: 7771+)
  --no-open                    Don't auto-launch browser
  --headless                   stdin JSONL → stdout final JSON; no HTTP/WS
  --data-dir=<path>            SQLite DB location override
  --no-history                 Don't write to history (still reads)
  --verbose                    Add debug to log
  --dev                        Forward server logs to browser console
  -h, --help                   Show help
```

## SQLite schema (`lib/db.ts`)

**Default location:** `~/.guide/guide.db` (Linux: respects `$XDG_DATA_HOME`; Windows: `%LOCALAPPDATA%\guide\guide.db`). Override with `--data-dir`.

```sql
CREATE TABLE history (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  text         TEXT NOT NULL,
  shell        TEXT NOT NULL,
  prefix       TEXT,
  workspace    TEXT NOT NULL,
  ts           TEXT NOT NULL,
  exit_code    INTEGER,
  duration_ms  INTEGER,
  redacted     INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX history_ts        ON history(ts DESC);
CREATE INDEX history_workspace ON history(workspace, ts DESC);
CREATE VIRTUAL TABLE history_fts USING fts5(text, content='history', content_rowid='id');

CREATE TABLE plan_runs (
  plan_id      TEXT PRIMARY KEY,
  workspace    TEXT NOT NULL,
  title        TEXT, subtitle  TEXT,
  started_at   TEXT NOT NULL, completed_at TEXT,
  exit_code    INTEGER,
  phase_json   TEXT NOT NULL,
  issue_count  INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX plan_runs_started ON plan_runs(started_at DESC);

CREATE TABLE schema_version (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);
INSERT INTO schema_version VALUES (1, datetime('now'));
```

Migrations are a numbered array of SQL strings in `lib/db.ts`; on startup, runs each with version > current.

### Privacy / redaction

- `--no-history`: skip writes for the session.
- Leading-space prefix on a command: skip the insert (matches bash `HISTCONTROL=ignorespace`).
- `~/.guide/redact.json`: regex patterns; matches store with `redacted=1` and replace text with `[redacted]` in UI.

## bootstrap.ps1 + PS module changes

### `tools/guide/ps/guide.psd1` exports (down from 50+)

```powershell
'New-GuidePlan', 'Add-GuideLoopPhase', 'Add-GuideSinglePhase',
'New-GuideResult', 'New-GuideAlert', 'Test-GuidePlan',
'Invoke-GuidePlan', 'Connect-GuideServer', 'Send-GuideEvent',
'Disconnect-GuideServer', 'Get-GuideVersion', 'Test-GuideEnvironment'
```

### `Invoke-GuidePlan` flow

```powershell
function Invoke-GuidePlan {
    param([Parameter(Mandatory)][hashtable]$Plan)

    $serverUp = Test-GuideServerReachable
    if (-not $serverUp -and (Get-Command bun -ErrorAction SilentlyContinue)) {
        Start-GuideServerDetached
        $serverUp = Wait-GuideServerReady -TimeoutSec 5
    }
    if (-not $serverUp) { Invoke-GuideStreamingFallback -Plan $Plan; return }

    Connect-GuideServer
    try {
        $planId = [guid]::NewGuid().ToString()
        Send-GuideEvent @{ type='plan-started'; planId=$planId; ... }
        Invoke-GuidePlanPhases -Plan $Plan `
            -OnPhaseStart  { Send-GuideEvent @{ type='phase-started';  ... } } `
            -OnPhaseResult { Send-GuideEvent @{ type='phase-result';   ... } } `
            -OnPhaseEnd    { Send-GuideEvent @{ type='phase-completed';... } }
        Send-GuideEvent @{ type='plan-completed'; planId=$planId; exitCode=$Plan.ExitCode }
    } finally { Disconnect-GuideServer }
}
```

`Invoke-GuidePlanPhases` is a new helper in `plan.ps1` — strips today's TUI-path inline orchestrator down to phase iteration with three callbacks. No rendering.

### `bootstrap.ps1` change

Path update only:

```powershell
$guideModule = Join-Path … 'tools/guide/ps/guide.psd1'   # was 'tools/guide/guide.psd1'
```

Headless detection becomes implicit (`Invoke-GuidePlan` decides). The bootstrap call site shrinks.

## Testing strategy

### Layer 1 — PowerShell unit (`tests/ps/`, ~115 cases)

`test-plan.ps1` (~50, KEEP), `test-state.ps1` (~40, KEEP), `test-emit.ps1` (~20 NEW: JSONL serialization + TCP-stub), `test-skeleton.ps1` (~5).

### Layer 2 — Bun unit (`tests/server/`, ~80 cases)

`events.test.ts`, `state.test.ts`, `ws.test.ts`, `pty.test.ts`, `port.test.ts`, `db.test.ts`, `routing.test.ts`, `headless.test.ts`. PTY tests use cross-platform stubs (`pwsh -c "Write-Host hi"`, `bash -c "echo hi"`).

### Layer 3 — Browser unit (`tests/browser/`, ~40 cases)

`bun test` + `happy-dom`. Pure functions/reducers in `app.js`: `prefix-routing`, `history-store`, `sidebar-render`, `multi-line`, `ws-client`.

### Layer 4 — End-to-end (`tests/e2e/`, ~10 cases)

Playwright + headless Chromium. `server-up`, `plan-flow`, `shell-roundtrip`, `persistence`. Excluded from the quick `bun test` loop; run on CI and `bun test --e2e`.

### Layer 5 — Cross-stack (`bootstrap/tests/`)

`test-guide-integration.ps1` rewritten with three scenarios: Bun server path, headless CI path, no-Bun fallback. `test-e2e.ps1`: existing scenarios remain; only `.psm1` path changes.

### Migration of current 466 tests

| File | Action |
|---|---|
| `test-clipboard.ps1` (13) | Delete |
| `test-headless.ps1` (74) | Port to `tests/server/headless.test.ts` |
| `test-input.ps1` (19) | Delete |
| `test-layout.ps1` (110) | Delete |
| `test-plan.ps1` (50) | Keep |
| `test-render-primitives.ps1` (2) | Delete |
| `test-render-regions.ps1` (11) | Delete |
| `test-skeleton.ps1` (14) | Slim — drop render assertions |
| `test-state.ps1` (40) | Keep |
| `test-streaming-snapshot.ps1` (3) | Slim — only no-server path |
| `test-theme.ps1` (130) | Delete |

PS retained: ~115 cases. New Bun: ~130. Cross-stack: ~30. **Total ~275** with strictly higher coverage-per-LOC than today.

### Quick-loop runner

```bash
# tools/guide/tests/run-all.sh
pwsh -NoProfile -File tests/ps/run-all.ps1
bun test tests/server tests/browser
# e2e excluded from quick loop; CI runs bun test tests/e2e
```

## Error handling

### Server lifecycle

| Failure | Behavior |
|---|---|
| Port 7771 taken by another guide | `/healthz` probes; reuse if `{guide:true}`, else increment up to 7780, then fail |
| Port 7771 taken by non-guide | Try next port; log message |
| Plan-events port (7772) taken | Same fallback ladder; print both ports on stdout |
| Bun killed mid-plan (SIGKILL) | PS emitter logs warning; routes remaining events to stdout streaming |
| Bun killed by user (SIGINT) | Graceful shutdown: close WS clients with reason, kill PTYs, release ports |
| PTY spawn crash | `shell-spawned-error { kind, error }` → browser toast. Other shell still works |

### PS emitter

| Failure | Behavior |
|---|---|
| Server not running, Bun installed | Auto-spawn detached server with 5s readiness timeout |
| Server not running, no Bun | Skip server; route events through `Invoke-GuideStreamingFallback` |
| TCP write throws mid-stream | Log once; subsequent calls no-op; phase loop continues; final summary via streaming |
| Server connect timeout (2s) | Skip; streaming fallback |

### Browser disconnect / reconnect

- Tab close → server detects WS close → 30s shutdown timer if no other clients **and** no plan running. New WS within 30s cancels.
- Multiple tabs → each gets `plan-snapshot` on connect; subsequent updates broadcast to all. xterm scrollback is per-tab (not synced); SQLite history covers cross-tab continuity.
- Localhost reconnect → exponential backoff 1s/2s/4s/8s; on reconnect, fresh `plan-snapshot`.
- `shell-line` for unspawned shell → server lazy-spawns; queues line for after `shell-spawned`.

### Shell process

| Case | Behavior |
|---|---|
| pwsh not on PATH | `shell-spawned-error` → xterm prints "[pwsh not found — install PowerShell 7+]". Other shell works |
| bash not on PATH (Win without Git Bash) | Same pattern; install hint with link to Git for Windows |
| Shell crashes mid-command | `pty.onExit` → `shell-exit { code }`; xterm prints "[bash exited 137]". Next `shell-line` respawns |
| Shell hangs | "Running… Ctrl+C" status; click sends SIGINT; after 5s of repeated SIGINT, "Force kill" button appears (SIGKILL → respawn) |
| Sentinel never appears | 30s no-output timer transitions UI to "Long-running…"; `exit_code` stays NULL |
| Heredoc collision with sentinel | Sentinel randomized per command (`__GUIDE_DONE_<8hexchars>__`) |

### SQLite

| Case | Behavior |
|---|---|
| Cannot create `~/.guide/` | Fall through to in-memory SQLite (`:memory:`); session-only persistence |
| DB corrupt at startup | Rename to `guide.db.corrupt-<ts>`; create fresh; print pointer to renamed file |
| Migration failure | Open read-only; skip writes for session; UI still shows existing data |
| Disk full mid-run | Insert throws; switch session to in-memory |

### Concurrency

- Two PS emitters connect simultaneously: separate `planId`s; server keeps separate states; browser shows most recent with "1 other plan running" indicator.
- Race between WS broadcast and SQLite write on `shell-line`: order is `INSERT history` → `broadcast history-appended` → `pty.write`. INSERT failure does **not** block the PTY write (running the command takes priority over recording it).
- Browser submits while previous command still running: prompt is read-only with "Running…" indicator; submit is no-op.

### Security

- **Loopback only** — `127.0.0.1` bind verified at server start; no `--bind` flag exists.
- **No auth** — same-user trust boundary.
- **CORS** — `Access-Control-Allow-Origin: http://127.0.0.1:<port>` only.
- **No remote shell** — TCP plan-events socket accepts only the documented event vocabulary.
- **PTY env scrub** — `GUIDE_*` vars stripped from spawned shell envs.
- **Static path traversal** — normalize-and-prefix-check against `tools/guide/public/`.

### Logging

`<data-dir>/guide.log`, last 1MB, rotated to `.1`. Levels `error`/`warn`/`info`. Structured JSON lines. `--verbose` adds `debug`. `--dev` mirrors lines to browser console via `ws-log`.

## Bootstrap chicken-and-egg

First run from clean checkout: `tools/` doesn't exist yet → bootstrap.ps1 falls through to its own minimal streaming output (already in there today). After tools/ clones, every subsequent run uses Bun.

## Open follow-ups (deferred)

- Replay button on plan-runs — schema is ready, UI deferred.
- Cross-machine history sync.
- Raw-mode passthrough (vim/less/fzf in the shell pane).
- Plug-in shells (zsh, nu, fish).
- HTTP/3 over loopback (no benefit; reserved if remote-access mode ever ships).

## Implementation order (rough; the plan skill will refine)

1. SQLite schema + `lib/db.ts` + migrations.
2. PS emit module (`emit.ps1`) + `test-emit.ps1` (no server yet — use TCP stub).
3. Bun server skeleton: HTTP, static files, WS, port allocation, `/healthz`.
4. Plan event protocol: TCP listener, JSONL parser, state mutations, WS broadcast.
5. Browser dashboard: HTML + CSS grid + `app.js` (sidebar render only, no shell yet).
6. PTY manager + `shell-line`/`shell-output` round-trip; xterm.js wired.
7. Sentinel injection for command completion + `history` table integration.
8. Multi-line paste, prefix routing, history sidebar (recall/re-run/delete/search).
9. `--shell` standalone mode + CLI flags.
10. `bootstrap.ps1` switch + cross-stack tests rewritten.
11. e2e Playwright suite + CI integration.
12. Cull deleted PS files + tests; final cleanup pass.
