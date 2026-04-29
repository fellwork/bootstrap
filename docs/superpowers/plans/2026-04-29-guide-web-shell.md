# Guide Web Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the PowerShell TUI in `tools/guide/` with a Bun-based web dashboard that hosts an embedded persistent shell (pwsh + bash via xterm.js) and persists history to SQLite.

**Architecture:** A long-lived Bun server bound to `127.0.0.1` serves a static HTML dashboard over WebSocket, accepts plan events from PowerShell emitters over a localhost TCP socket (one JSON object per line), manages `pwsh` and `bash` PTYs lazily, and persists command history + plan-run snapshots to SQLite. PowerShell's role shrinks to building and emitting plan events; all rendering happens in the browser.

**Tech Stack:** Bun (server runtime, `bun:sqlite`, TCP, WebSocket), TypeScript (server + tests), xterm.js (vendored, no npm), HTML + CSS Grid + vanilla JS (no bundler), PowerShell 7 (event emitter only), Playwright (e2e tests), `happy-dom` (browser unit tests).

**Spec:** [`2026-04-29-guide-web-shell-design.md`](../specs/2026-04-29-guide-web-shell-design.md)

---

## File structure summary

This plan creates these files in `tools/guide/`:

```
server.ts                 # Bun entry — Bun.serve + Bun.listen TCP + WS broker
package.json              # Bun deps (minimal); dev deps for tests
tsconfig.json
lib/
├── db.ts                 # bun:sqlite wrapper; schema + migrations
├── events.ts             # PS event types + JSONL parser
├── state.ts              # in-memory PlanState store
├── ws.ts                 # WS message types + broadcast helper
├── pty.ts                # PTY manager (pwsh + bash)
├── port.ts               # port allocator (try 7771, fall back upward)
└── cli.ts                # argv parsing
public/
├── index.html
├── style.css
├── app.js                # vanilla JS — WS client, sidebar, prompt, history
├── xterm.js              # vendored
└── xterm.css             # vendored
ps/
├── guide.psm1            # SHRUNK module entry
├── guide.psd1            # ~12 exports (was 50+)
└── lib/
    ├── plan.ps1          # KEEP (moved)
    ├── state.ps1         # KEEP (moved)
    ├── emit.ps1          # NEW — TCP client, JSONL writer
    └── streaming.ps1     # KEEP (slimmed)
tests/
├── ps/
│   ├── run-all.ps1
│   ├── test-plan.ps1     # KEEP (moved)
│   ├── test-state.ps1    # KEEP (moved)
│   ├── test-emit.ps1     # NEW
│   └── test-skeleton.ps1 # KEEP (slimmed)
├── server/
│   ├── port.test.ts
│   ├── db.test.ts
│   ├── events.test.ts
│   ├── state.test.ts
│   ├── ws.test.ts
│   ├── routing.test.ts
│   ├── pty.test.ts
│   └── headless.test.ts
├── browser/
│   ├── prefix-routing.test.ts
│   ├── multi-line.test.ts
│   ├── history-store.test.ts
│   ├── sidebar-render.test.ts
│   └── ws-client.test.ts
└── e2e/
    ├── server-up.test.ts
    ├── plan-flow.test.ts
    ├── shell-roundtrip.test.ts
    └── persistence.test.ts
```

Modifies these files outside `tools/guide/`:
- `bootstrap/bootstrap.ps1` (one-line path change; remove Headless branch)
- `bootstrap/tests/test-guide-integration.ps1` (rewrite scenarios)
- `bootstrap/tests/test-e2e.ps1` (path-only update for module hide/restore)

Deletes from `tools/guide/`:
- `lib/render.ps1`, `lib/input.ps1`, `lib/headless.ps1`, `lib/theme.ps1`, `lib/layout.ps1`, `lib/clipboard.ps1`, `lib/environment.ps1`
- `themes/twilight.json`, `themes/cozy.json`, `themes/` directory
- `tests/manual-smoke.ps1`, `tests/test-clipboard.ps1`, `tests/test-headless.ps1`, `tests/test-input.ps1`, `tests/test-layout.ps1`, `tests/test-render-primitives.ps1`, `tests/test-render-regions.ps1`, `tests/test-streaming-snapshot.ps1`, `tests/test-theme.ps1`, `tests/snapshots/`
- The old `derekh.psd1`/`derekh.psm1` are already renamed to `guide.psd1`/`guide.psm1` in earlier work; this plan moves them into `ps/`.

---

## Phase 0: Bootstrap the new layout

This phase reorganizes the existing repo so subsequent phases have stable target paths. No deletions yet — just moves and a `package.json`.

### Task 0.1: Create `tools/guide/package.json` and `tsconfig.json`

**Files:**
- Create: `tools/guide/package.json`
- Create: `tools/guide/tsconfig.json`

- [ ] **Step 1: Write `package.json`**

```json
{
  "name": "guide",
  "version": "0.2.0",
  "private": true,
  "type": "module",
  "scripts": {
    "test": "bun test tests/server tests/browser",
    "test:e2e": "bun test tests/e2e",
    "start": "bun server.ts"
  },
  "dependencies": {},
  "devDependencies": {
    "@types/bun": "latest",
    "happy-dom": "^15.0.0",
    "playwright": "^1.48.0"
  }
}
```

- [ ] **Step 2: Write `tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ESNext",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "skipLibCheck": true,
    "lib": ["ESNext", "DOM"],
    "types": ["bun"],
    "allowImportingTsExtensions": true,
    "noEmit": true
  },
  "include": ["server.ts", "lib/**/*.ts", "tests/**/*.ts", "public/app.js"]
}
```

- [ ] **Step 3: Run `bun install` to populate `bun.lock`**

```bash
cd tools/guide
bun install
```

Expected: creates `bun.lock` and `node_modules/` with the dev deps. No runtime deps yet (we'll add `bun:sqlite` as a built-in import — no install needed).

- [ ] **Step 4: Commit**

```bash
git add tools/guide/package.json tools/guide/tsconfig.json tools/guide/bun.lock
git commit -m "guide: add package.json and tsconfig for Bun server"
```

### Task 0.2: Move PS module files into `tools/guide/ps/`

**Files:**
- Move: `tools/guide/guide.psd1` → `tools/guide/ps/guide.psd1`
- Move: `tools/guide/guide.psm1` → `tools/guide/ps/guide.psm1`
- Move: `tools/guide/lib/plan.ps1` → `tools/guide/ps/lib/plan.ps1`
- Move: `tools/guide/lib/state.ps1` → `tools/guide/ps/lib/state.ps1`
- Move: `tools/guide/lib/streaming.ps1` → `tools/guide/ps/lib/streaming.ps1`

- [ ] **Step 1: Create the `ps/lib/` directory and move files**

```bash
cd tools/guide
mkdir -p ps/lib
git mv guide.psd1 ps/guide.psd1
git mv guide.psm1 ps/guide.psm1
git mv lib/plan.ps1 ps/lib/plan.ps1
git mv lib/state.ps1 ps/lib/state.ps1
git mv lib/streaming.ps1 ps/lib/streaming.ps1
```

- [ ] **Step 2: Update `ps/guide.psm1`'s lib-loading path**

Open `tools/guide/ps/guide.psm1` and change the `$_libDir` line:

```powershell
# Before:
$_libDir = Join-Path $PSScriptRoot 'lib'
# After (no change needed if it was already $PSScriptRoot/lib — verify):
$_libDir = Join-Path $PSScriptRoot 'lib'
```

The path is relative to the module file, so the move is transparent. Verify the manifest line too:

```powershell
# tools/guide/ps/guide.psd1
RootModule = 'guide.psm1'    # unchanged — relative to manifest
```

- [ ] **Step 3: Move and update test files**

```bash
git mv tests/test-plan.ps1 tests/ps/test-plan.ps1
git mv tests/test-state.ps1 tests/ps/test-state.ps1
git mv tests/test-skeleton.ps1 tests/ps/test-skeleton.ps1
git mv tests/run-all.ps1 tests/ps/run-all.ps1
mkdir -p tests/server tests/browser tests/e2e
```

In each moved test file, update the dot-source paths from `"$PSScriptRoot/../lib/plan.ps1"` to `"$PSScriptRoot/../../ps/lib/plan.ps1"`. Search-and-replace pattern:

```bash
# In each tests/ps/*.ps1, replace:
#   ../lib/    →   ../../ps/lib/
#   ../guide   →   ../../ps/guide
```

- [ ] **Step 4: Run the moved tests to confirm they still pass**

```bash
pwsh -NoProfile -File tests/ps/run-all.ps1
```

Expected: `test-plan` (~50 pass), `test-state` (~40 pass), `test-skeleton` (~14 pass). Render-related suites will fail because they reference deleted symbols — they're ignored at this stage and deleted in Phase 12.

If `run-all.ps1` discovers the render-related test files, temporarily rename them (`*.ps1` → `*.ps1.deprecated`) so they don't load:

```bash
cd tools/guide/tests
for f in test-clipboard.ps1 test-headless.ps1 test-input.ps1 test-layout.ps1 \
         test-render-primitives.ps1 test-render-regions.ps1 \
         test-streaming-snapshot.ps1 test-theme.ps1 manual-smoke.ps1; do
  [ -f "$f" ] && git mv "$f" "$f.deprecated"
done
```

These get fully deleted in Phase 12.

- [ ] **Step 5: Update `bootstrap/repos.psd1`**

`structureCheck` for the `tools` repo points at the old `guide/guide.psd1`. Update to `guide/ps/guide.psd1`:

```powershell
# bootstrap/repos.psd1
@{
    name        = 'tools'
    ...
    structureCheck = @('guide/ps/guide.psd1')   # was: 'guide/guide.psd1'
    ...
}
```

- [ ] **Step 6: Update `bootstrap/bootstrap.ps1`**

Single line change:

```powershell
# Before:
$guideModule = Join-Path (Split-Path -Parent $scriptRoot) "tools/guide/guide.psd1"
# After:
$guideModule = Join-Path (Split-Path -Parent $scriptRoot) "tools/guide/ps/guide.psd1"
```

- [ ] **Step 7: Update `bootstrap/tests/test-e2e.ps1` and `test-guide-integration.ps1` paths**

Search-and-replace across both files:

```
"tools/guide/guide.psm1"  →  "tools/guide/ps/guide.psm1"
"tools/guide/guide.psd1"  →  "tools/guide/ps/guide.psd1"
```

- [ ] **Step 8: Run end-to-end and integration tests**

```bash
pwsh -NoProfile -File bootstrap/tests/test-guide-integration.ps1
pwsh -NoProfile -File bootstrap/tests/test-e2e.ps1
```

Expected: both pass (the move was path-transparent).

- [ ] **Step 9: Commit**

```bash
git add tools/guide/ps tools/guide/tests bootstrap/bootstrap.ps1 bootstrap/repos.psd1 bootstrap/tests
git commit -m "guide: relocate PS module to tools/guide/ps/ before web rewrite"
```

---

## Phase 1: SQLite layer (`lib/db.ts`)

Establishes the persistence layer first because both the history feature and `plan_runs` archive depend on it. Tests use an in-memory SQLite instance for speed.

### Task 1.1: Write the schema and migration runner

**Files:**
- Create: `tools/guide/lib/db.ts`
- Test: `tools/guide/tests/server/db.test.ts`

- [ ] **Step 1: Write the failing test for schema initialization**

`tools/guide/tests/server/db.test.ts`:

```ts
import { describe, expect, test } from 'bun:test'
import { Database } from 'bun:sqlite'
import { applyMigrations, currentSchemaVersion } from '../../lib/db.ts'

describe('db migrations', () => {
  test('fresh DB applies migration v1', () => {
    const db = new Database(':memory:')
    applyMigrations(db)
    expect(currentSchemaVersion(db)).toBe(1)
  })

  test('idempotent — running twice keeps version at 1', () => {
    const db = new Database(':memory:')
    applyMigrations(db)
    applyMigrations(db)
    expect(currentSchemaVersion(db)).toBe(1)
  })

  test('history table exists with expected columns', () => {
    const db = new Database(':memory:')
    applyMigrations(db)
    const cols = db.query("PRAGMA table_info('history')").all() as { name: string }[]
    const names = cols.map(c => c.name).sort()
    expect(names).toEqual([
      'duration_ms', 'exit_code', 'id', 'prefix', 'redacted',
      'shell', 'text', 'ts', 'workspace',
    ])
  })

  test('plan_runs table exists', () => {
    const db = new Database(':memory:')
    applyMigrations(db)
    const cols = db.query("PRAGMA table_info('plan_runs')").all() as { name: string }[]
    expect(cols.length).toBeGreaterThan(0)
  })

  test('history_fts virtual table exists', () => {
    const db = new Database(':memory:')
    applyMigrations(db)
    const tables = db.query(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='history_fts'"
    ).all() as { name: string }[]
    expect(tables.length).toBe(1)
  })
})
```

- [ ] **Step 2: Run the test to confirm failure**

```bash
cd tools/guide
bun test tests/server/db.test.ts
```

Expected: FAIL — module `lib/db.ts` not found.

- [ ] **Step 3: Implement `lib/db.ts`**

```ts
import { Database } from 'bun:sqlite'

export const MIGRATIONS: string[] = [
  // index 0 = no migration; version 1 starts at index 1
  '',
  // v1 — initial schema
  `
  CREATE TABLE IF NOT EXISTS schema_version (
    version    INTEGER PRIMARY KEY,
    applied_at TEXT    NOT NULL
  );

  CREATE TABLE IF NOT EXISTS history (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    text        TEXT    NOT NULL,
    shell       TEXT    NOT NULL,
    prefix      TEXT,
    workspace   TEXT    NOT NULL,
    ts          TEXT    NOT NULL,
    exit_code   INTEGER,
    duration_ms INTEGER,
    redacted    INTEGER NOT NULL DEFAULT 0
  );
  CREATE INDEX IF NOT EXISTS history_ts        ON history(ts DESC);
  CREATE INDEX IF NOT EXISTS history_workspace ON history(workspace, ts DESC);
  CREATE VIRTUAL TABLE IF NOT EXISTS history_fts
    USING fts5(text, content='history', content_rowid='id');

  CREATE TABLE IF NOT EXISTS plan_runs (
    plan_id      TEXT PRIMARY KEY,
    workspace    TEXT    NOT NULL,
    title        TEXT,
    subtitle     TEXT,
    started_at   TEXT    NOT NULL,
    completed_at TEXT,
    exit_code    INTEGER,
    phase_json   TEXT    NOT NULL,
    issue_count  INTEGER NOT NULL DEFAULT 0
  );
  CREATE INDEX IF NOT EXISTS plan_runs_started ON plan_runs(started_at DESC);
  `,
]

export function currentSchemaVersion(db: Database): number {
  // schema_version table may not exist on a fresh DB — guard the query.
  const row = db.query(
    "SELECT name FROM sqlite_master WHERE type='table' AND name='schema_version'"
  ).get() as { name?: string } | null
  if (!row) return 0
  const v = db.query('SELECT MAX(version) AS v FROM schema_version').get() as { v: number | null }
  return v.v ?? 0
}

export function applyMigrations(db: Database): void {
  const target = MIGRATIONS.length - 1
  let current = currentSchemaVersion(db)
  while (current < target) {
    const next = current + 1
    db.transaction(() => {
      db.run(MIGRATIONS[next]!)
      db.run('INSERT OR REPLACE INTO schema_version(version, applied_at) VALUES (?, ?)',
             [next, new Date().toISOString()])
    })()
    current = next
  }
}

export function openDb(path: string): Database {
  const db = new Database(path)
  db.run('PRAGMA journal_mode = WAL')
  db.run('PRAGMA foreign_keys = ON')
  applyMigrations(db)
  return db
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
bun test tests/server/db.test.ts
```

Expected: 5 pass, 0 fail.

- [ ] **Step 5: Commit**

```bash
git add tools/guide/lib/db.ts tools/guide/tests/server/db.test.ts
git commit -m "guide(db): schema + migration runner; history, history_fts, plan_runs tables"
```

### Task 1.2: History insert / list / search

**Files:**
- Modify: `tools/guide/lib/db.ts`
- Modify: `tools/guide/tests/server/db.test.ts`

- [ ] **Step 1: Append failing tests for history operations**

Add to `tests/server/db.test.ts`:

```ts
import {
  insertHistory, updateHistoryExit, listHistory, searchHistory, deleteHistory,
} from '../../lib/db.ts'

describe('history ops', () => {
  test('insertHistory + listHistory roundtrip', () => {
    const db = new Database(':memory:')
    applyMigrations(db)
    const id = insertHistory(db, {
      text: 'ls -la', shell: 'bash', prefix: '!', workspace: '/repo', ts: '2026-04-29T00:00:00Z',
    })
    expect(id).toBeGreaterThan(0)
    const rows = listHistory(db, { workspace: '/repo', limit: 10 })
    expect(rows).toHaveLength(1)
    expect(rows[0]!.text).toBe('ls -la')
    expect(rows[0]!.shell).toBe('bash')
    expect(rows[0]!.exit_code).toBeNull()
  })

  test('updateHistoryExit sets code + duration', () => {
    const db = new Database(':memory:')
    applyMigrations(db)
    const id = insertHistory(db, {
      text: 'true', shell: 'bash', prefix: null, workspace: '/r', ts: '2026-04-29T00:00:00Z',
    })
    updateHistoryExit(db, id, 0, 42)
    const rows = listHistory(db, { workspace: '/r', limit: 10 })
    expect(rows[0]!.exit_code).toBe(0)
    expect(rows[0]!.duration_ms).toBe(42)
  })

  test('listHistory before-cursor returns older rows', () => {
    const db = new Database(':memory:')
    applyMigrations(db)
    insertHistory(db, { text:'a', shell:'bash', prefix:null, workspace:'/r', ts:'2026-04-29T00:00:01Z' })
    insertHistory(db, { text:'b', shell:'bash', prefix:null, workspace:'/r', ts:'2026-04-29T00:00:02Z' })
    insertHistory(db, { text:'c', shell:'bash', prefix:null, workspace:'/r', ts:'2026-04-29T00:00:03Z' })
    const page1 = listHistory(db, { workspace:'/r', limit: 2 })
    expect(page1.map(r => r.text)).toEqual(['c', 'b'])
    const page2 = listHistory(db, { workspace:'/r', limit: 2, before: page1[1]!.ts })
    expect(page2.map(r => r.text)).toEqual(['a'])
  })

  test('searchHistory matches FTS', () => {
    const db = new Database(':memory:')
    applyMigrations(db)
    insertHistory(db, { text:'git status', shell:'bash', prefix:null, workspace:'/r', ts:'2026-04-29T00:00:01Z' })
    insertHistory(db, { text:'git push', shell:'bash', prefix:null, workspace:'/r', ts:'2026-04-29T00:00:02Z' })
    insertHistory(db, { text:'ls -la', shell:'bash', prefix:null, workspace:'/r', ts:'2026-04-29T00:00:03Z' })
    const hits = searchHistory(db, 'git', 10)
    expect(hits.map(r => r.text).sort()).toEqual(['git push', 'git status'])
  })

  test('deleteHistory removes row', () => {
    const db = new Database(':memory:')
    applyMigrations(db)
    const id = insertHistory(db, { text:'x', shell:'bash', prefix:null, workspace:'/r', ts:'2026-04-29T00:00:01Z' })
    expect(deleteHistory(db, id)).toBe(true)
    expect(listHistory(db, { workspace:'/r', limit: 10 })).toHaveLength(0)
  })
})
```

- [ ] **Step 2: Run to confirm failure**

```bash
bun test tests/server/db.test.ts
```

Expected: FAIL — `insertHistory` etc. not exported.

- [ ] **Step 3: Implement history operations in `lib/db.ts`**

Append to `lib/db.ts`:

```ts
export type HistoryEntry = {
  id: number
  text: string
  shell: 'pwsh' | 'bash'
  prefix: string | null
  workspace: string
  ts: string
  exit_code: number | null
  duration_ms: number | null
  redacted: number
}

export type HistoryInsert = Omit<HistoryEntry, 'id' | 'exit_code' | 'duration_ms' | 'redacted'> & {
  redacted?: boolean
}

export function insertHistory(db: Database, e: HistoryInsert): number {
  const stmt = db.prepare(`
    INSERT INTO history(text, shell, prefix, workspace, ts, redacted)
    VALUES (?, ?, ?, ?, ?, ?)
  `)
  const result = stmt.run(e.text, e.shell, e.prefix, e.workspace, e.ts, e.redacted ? 1 : 0)
  const id = Number(result.lastInsertRowid)
  // Mirror into FTS
  db.run('INSERT INTO history_fts(rowid, text) VALUES (?, ?)', [id, e.text])
  return id
}

export function updateHistoryExit(db: Database, id: number, exit: number, durationMs: number): void {
  db.run('UPDATE history SET exit_code = ?, duration_ms = ? WHERE id = ?', [exit, durationMs, id])
}

export function listHistory(
  db: Database,
  opts: { workspace?: string; limit: number; before?: string }
): HistoryEntry[] {
  let sql = 'SELECT * FROM history WHERE 1=1'
  const params: (string | number)[] = []
  if (opts.workspace) { sql += ' AND workspace = ?'; params.push(opts.workspace) }
  if (opts.before)    { sql += ' AND ts < ?';        params.push(opts.before) }
  sql += ' ORDER BY ts DESC LIMIT ?'
  params.push(opts.limit)
  return db.query(sql).all(...params) as HistoryEntry[]
}

export function searchHistory(db: Database, query: string, limit: number): HistoryEntry[] {
  const sql = `
    SELECT history.* FROM history
    JOIN history_fts ON history_fts.rowid = history.id
    WHERE history_fts MATCH ?
    ORDER BY history.ts DESC
    LIMIT ?
  `
  return db.query(sql).all(query, limit) as HistoryEntry[]
}

export function deleteHistory(db: Database, id: number): boolean {
  const r = db.run('DELETE FROM history WHERE id = ?', [id])
  db.run('DELETE FROM history_fts WHERE rowid = ?', [id])
  return r.changes > 0
}
```

- [ ] **Step 4: Run tests**

```bash
bun test tests/server/db.test.ts
```

Expected: 10 pass, 0 fail.

- [ ] **Step 5: Commit**

```bash
git add tools/guide/lib/db.ts tools/guide/tests/server/db.test.ts
git commit -m "guide(db): history insert/list/search/delete with FTS5 mirror"
```

### Task 1.3: Plan-runs persistence

**Files:**
- Modify: `tools/guide/lib/db.ts`
- Modify: `tools/guide/tests/server/db.test.ts`

- [ ] **Step 1: Append failing test**

```ts
import { upsertPlanRun, listPlanRuns } from '../../lib/db.ts'

describe('plan_runs ops', () => {
  test('upsertPlanRun + listPlanRuns roundtrip', () => {
    const db = new Database(':memory:')
    applyMigrations(db)
    upsertPlanRun(db, {
      plan_id: 'abc-1', workspace: '/r', title: 'Test', subtitle: 'sub',
      started_at: '2026-04-29T00:00:00Z',
      completed_at: '2026-04-29T00:00:05Z',
      exit_code: 0,
      phase_json: '{"phases":[]}',
      issue_count: 0,
    })
    const rows = listPlanRuns(db, '/r', 10)
    expect(rows).toHaveLength(1)
    expect(rows[0]!.plan_id).toBe('abc-1')
    expect(rows[0]!.exit_code).toBe(0)
  })

  test('upsertPlanRun overwrites by plan_id', () => {
    const db = new Database(':memory:')
    applyMigrations(db)
    upsertPlanRun(db, {
      plan_id: 'abc-1', workspace: '/r', title: 'T1', subtitle: '',
      started_at: '2026-04-29T00:00:00Z', completed_at: null, exit_code: null,
      phase_json: '{}', issue_count: 0,
    })
    upsertPlanRun(db, {
      plan_id: 'abc-1', workspace: '/r', title: 'T1', subtitle: '',
      started_at: '2026-04-29T00:00:00Z', completed_at: '2026-04-29T00:00:10Z', exit_code: 1,
      phase_json: '{"done":true}', issue_count: 3,
    })
    const rows = listPlanRuns(db, '/r', 10)
    expect(rows).toHaveLength(1)
    expect(rows[0]!.exit_code).toBe(1)
    expect(rows[0]!.issue_count).toBe(3)
  })
})
```

- [ ] **Step 2: Run to confirm failure**

```bash
bun test tests/server/db.test.ts
```

Expected: FAIL — `upsertPlanRun` not exported.

- [ ] **Step 3: Implement plan-runs operations**

Append to `lib/db.ts`:

```ts
export type PlanRunRow = {
  plan_id: string
  workspace: string
  title: string | null
  subtitle: string | null
  started_at: string
  completed_at: string | null
  exit_code: number | null
  phase_json: string
  issue_count: number
}

export function upsertPlanRun(db: Database, r: PlanRunRow): void {
  db.run(`
    INSERT INTO plan_runs(plan_id, workspace, title, subtitle, started_at, completed_at,
                          exit_code, phase_json, issue_count)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(plan_id) DO UPDATE SET
      workspace=excluded.workspace,
      title=excluded.title,
      subtitle=excluded.subtitle,
      started_at=excluded.started_at,
      completed_at=excluded.completed_at,
      exit_code=excluded.exit_code,
      phase_json=excluded.phase_json,
      issue_count=excluded.issue_count
  `, [r.plan_id, r.workspace, r.title, r.subtitle, r.started_at, r.completed_at,
      r.exit_code, r.phase_json, r.issue_count])
}

export function listPlanRuns(db: Database, workspace: string | undefined, limit: number): PlanRunRow[] {
  if (workspace) {
    return db.query(
      'SELECT * FROM plan_runs WHERE workspace = ? ORDER BY started_at DESC LIMIT ?'
    ).all(workspace, limit) as PlanRunRow[]
  }
  return db.query('SELECT * FROM plan_runs ORDER BY started_at DESC LIMIT ?').all(limit) as PlanRunRow[]
}
```

- [ ] **Step 4: Run tests**

```bash
bun test tests/server/db.test.ts
```

Expected: 12 pass, 0 fail.

- [ ] **Step 5: Commit**

```bash
git add tools/guide/lib/db.ts tools/guide/tests/server/db.test.ts
git commit -m "guide(db): plan_runs upsert + list"
```

### Task 1.4: Default DB-path resolver

**Files:**
- Modify: `tools/guide/lib/db.ts`
- Modify: `tools/guide/tests/server/db.test.ts`

- [ ] **Step 1: Append failing test**

```ts
import { resolveDataDir } from '../../lib/db.ts'

describe('resolveDataDir', () => {
  test('--data-dir override wins', () => {
    expect(resolveDataDir({ dataDir: '/custom' })).toBe('/custom')
  })

  test('Linux respects $XDG_DATA_HOME', () => {
    expect(resolveDataDir({ env: { XDG_DATA_HOME: '/x' }, platform: 'linux' }))
      .toBe('/x/guide')
  })

  test('Linux falls back to ~/.local/share/guide', () => {
    expect(resolveDataDir({ env: { HOME: '/home/u' }, platform: 'linux' }))
      .toBe('/home/u/.local/share/guide')
  })

  test('Windows uses %LOCALAPPDATA%', () => {
    expect(resolveDataDir({ env: { LOCALAPPDATA: 'C:\\u\\AppData\\Local' }, platform: 'win32' }))
      .toBe('C:\\u\\AppData\\Local\\guide')
  })

  test('macOS uses ~/.guide for now', () => {
    expect(resolveDataDir({ env: { HOME: '/Users/u' }, platform: 'darwin' }))
      .toBe('/Users/u/.guide')
  })
})
```

- [ ] **Step 2: Run to confirm failure**

```bash
bun test tests/server/db.test.ts
```

Expected: FAIL — `resolveDataDir` not exported.

- [ ] **Step 3: Implement `resolveDataDir`**

Append to `lib/db.ts`:

```ts
export type ResolveOpts = {
  dataDir?: string
  env?: Record<string, string | undefined>
  platform?: NodeJS.Platform
}

export function resolveDataDir(opts: ResolveOpts = {}): string {
  if (opts.dataDir) return opts.dataDir
  const env = opts.env ?? (process.env as Record<string, string | undefined>)
  const platform = opts.platform ?? process.platform
  if (platform === 'win32') {
    const local = env.LOCALAPPDATA
    if (local) return `${local}\\guide`
    return `${env.USERPROFILE ?? 'C:\\Users\\Default'}\\AppData\\Local\\guide`
  }
  if (platform === 'linux') {
    if (env.XDG_DATA_HOME) return `${env.XDG_DATA_HOME}/guide`
    return `${env.HOME ?? '/root'}/.local/share/guide`
  }
  // macOS, others
  return `${env.HOME ?? '/root'}/.guide`
}
```

- [ ] **Step 4: Run tests**

```bash
bun test tests/server/db.test.ts
```

Expected: 17 pass, 0 fail.

- [ ] **Step 5: Commit**

```bash
git add tools/guide/lib/db.ts tools/guide/tests/server/db.test.ts
git commit -m "guide(db): resolveDataDir with platform-correct defaults"
```

---

## Phase 2: PowerShell event emitter (`ps/lib/emit.ps1`)

The PS module learns to talk TCP/JSONL to the Bun server. Tests use a server stub: a small PS function that opens a TCP listener on a free port, accepts one connection, captures bytes, and shuts down — entirely self-contained.

### Task 2.1: TCP-listener test stub

**Files:**
- Create: `tools/guide/tests/ps/test-helpers/tcp-stub.ps1`

- [ ] **Step 1: Write the test stub**

```powershell
# tools/guide/tests/ps/test-helpers/tcp-stub.ps1
# Tiny TCP server stub used by emit tests. Returns @{ Port; Wait; Close }.
# Wait() blocks until first client connects then returns all bytes received as
# a single string, after EOF/disconnect.

function New-GuideTcpStub {
    [CmdletBinding()]
    param([int]$Port = 0)

    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
    $listener.Start()
    $actualPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port

    $buffer = [System.Text.StringBuilder]::new()
    $client = $null

    $waitFn = {
        param($timeoutMs = 5000)
        $task = $listener.AcceptTcpClientAsync()
        if (-not $task.Wait($timeoutMs)) {
            throw "tcp-stub: no client within ${timeoutMs}ms"
        }
        $client = $task.Result
        $stream = $client.GetStream()
        $buf = New-Object byte[] 4096
        while ($true) {
            $read = 0
            try { $read = $stream.Read($buf, 0, $buf.Length) } catch { break }
            if ($read -le 0) { break }
            [void]$buffer.Append([System.Text.Encoding]::UTF8.GetString($buf, 0, $read))
        }
        return $buffer.ToString()
    }.GetNewClosure()

    $closeFn = {
        try { $listener.Stop() } catch {}
        try { if ($client) { $client.Close() } } catch {}
    }.GetNewClosure()

    return @{
        Port  = $actualPort
        Wait  = $waitFn
        Close = $closeFn
    }
}
```

- [ ] **Step 2: Smoke test**

Add to `tools/guide/tests/ps/test-tcp-stub.ps1`:

```powershell
. "$PSScriptRoot/test-helpers/tcp-stub.ps1"

$stub = New-GuideTcpStub
$client = [System.Net.Sockets.TcpClient]::new('127.0.0.1', $stub.Port)
$writer = New-Object System.IO.StreamWriter($client.GetStream())
$writer.WriteLine('hello')
$writer.WriteLine('world')
$writer.Flush()
$client.Close()

$received = & $stub.Wait
& $stub.Close

if ($received -eq "hello`r`nworld`r`n" -or $received -eq "hello`nworld`n") {
    Write-Host "PASS: tcp stub roundtrip"
} else {
    Write-Host "FAIL: tcp stub roundtrip — got [$received]"
    exit 1
}
```

- [ ] **Step 3: Run smoke test**

```bash
pwsh -NoProfile -File tools/guide/tests/ps/test-tcp-stub.ps1
```

Expected: `PASS: tcp stub roundtrip`.

- [ ] **Step 4: Commit**

```bash
git add tools/guide/tests/ps/test-helpers/tcp-stub.ps1 tools/guide/tests/ps/test-tcp-stub.ps1
git commit -m "guide(ps-tests): TCP listener stub for emit module tests"
```

### Task 2.2: `Connect-GuideServer` and `Send-GuideEvent`

**Files:**
- Create: `tools/guide/ps/lib/emit.ps1`
- Create: `tools/guide/tests/ps/test-emit.ps1`

- [ ] **Step 1: Write the failing emit test**

`tools/guide/tests/ps/test-emit.ps1`:

```powershell
. "$PSScriptRoot/test-helpers/tcp-stub.ps1"
. "$PSScriptRoot/../../ps/lib/emit.ps1"

$failures = 0
function Assert-True($cond, $msg) {
    if ($cond) { Write-Host "PASS: $msg" -ForegroundColor Green }
    else        { Write-Host "FAIL: $msg" -ForegroundColor Red; $script:failures++ }
}

# --- Test 1: Connect + send a single event + disconnect ---
$stub = New-GuideTcpStub
Connect-GuideServer -Host '127.0.0.1' -Port $stub.Port -TimeoutMs 2000
Send-GuideEvent @{ type = 'plan-started'; planId = 'p1'; title = 'T' }
Disconnect-GuideServer
$bytes = & $stub.Wait
& $stub.Close

$lines = $bytes -split "`n" | Where-Object { $_ }
Assert-True ($lines.Count -eq 1) "single event sent as one JSONL line"

$json = $lines[0] | ConvertFrom-Json
Assert-True ($json.type   -eq 'plan-started') "event.type preserved"
Assert-True ($json.planId -eq 'p1')           "event.planId preserved"
Assert-True ($null -ne $json.ts)              "ts auto-injected"

# --- Test 2: Multiple events come through in order ---
$stub2 = New-GuideTcpStub
Connect-GuideServer -Host '127.0.0.1' -Port $stub2.Port
1..3 | ForEach-Object { Send-GuideEvent @{ type = 'phase-started'; planId = 'p1'; phaseIndex = $_ } }
Disconnect-GuideServer
$bytes2 = & $stub2.Wait
& $stub2.Close
$lines2 = $bytes2 -split "`n" | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }
Assert-True ($lines2.Count -eq 3) "three events sent"
Assert-True ($lines2[0].phaseIndex -eq 1) "event 1 first"
Assert-True ($lines2[2].phaseIndex -eq 3) "event 3 last"

# --- Test 3: Connect timeout when nothing listening ---
$caught = $false
try {
    Connect-GuideServer -Host '127.0.0.1' -Port 1 -TimeoutMs 200
} catch { $caught = $true }
Assert-True $caught "Connect-GuideServer throws on unreachable host"

# --- Test 4: Send-GuideEvent without Connect throws ---
$caught2 = $false
try { Send-GuideEvent @{ type = 'plan-started' } } catch { $caught2 = $true }
Assert-True $caught2 "Send-GuideEvent throws when not connected"

if ($failures -eq 0) {
    Write-Host "`nAll emit tests passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n$failures emit test(s) failed." -ForegroundColor Red
    exit 1
}
```

- [ ] **Step 2: Run to confirm failure**

```bash
pwsh -NoProfile -File tools/guide/tests/ps/test-emit.ps1
```

Expected: FAIL — `Connect-GuideServer` not defined.

- [ ] **Step 3: Implement `emit.ps1`**

`tools/guide/ps/lib/emit.ps1`:

```powershell
#Requires -Version 7
# emit.ps1 — TCP/JSONL client to the Bun guide server.
#
# Public surface:
#   Connect-GuideServer   — opens TCP, throws on timeout
#   Send-GuideEvent       — writes one JSON object as a single line
#   Disconnect-GuideServer — closes the socket; idempotent
#   Test-GuideServerReachable — quick probe (HTTP /healthz on the dashboard port)

$ErrorActionPreference = 'Stop'

$script:_GuideClient = $null
$script:_GuideStream = $null
$script:_GuideWriter = $null

function Connect-GuideServer {
    [CmdletBinding()]
    param(
        [string]$Host = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMs = 2000
    )

    if ($null -ne $script:_GuideClient) { Disconnect-GuideServer }

    $client = [System.Net.Sockets.TcpClient]::new()
    $task   = $client.ConnectAsync($Host, $Port)
    if (-not $task.Wait($TimeoutMs)) {
        try { $client.Close() } catch {}
        throw "Connect-GuideServer: timeout after ${TimeoutMs}ms connecting to ${Host}:${Port}"
    }
    if (-not $client.Connected) {
        try { $client.Close() } catch {}
        throw "Connect-GuideServer: failed to connect to ${Host}:${Port}"
    }

    $stream = $client.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream, [System.Text.UTF8Encoding]::new($false))
    $writer.AutoFlush = $true
    $writer.NewLine = "`n"

    $script:_GuideClient = $client
    $script:_GuideStream = $stream
    $script:_GuideWriter = $writer
}

function Send-GuideEvent {
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)][hashtable]$Event)

    if ($null -eq $script:_GuideWriter) {
        throw 'Send-GuideEvent: not connected. Call Connect-GuideServer first.'
    }
    if (-not $Event.ContainsKey('ts')) {
        $Event['ts'] = (Get-Date).ToUniversalTime().ToString('o')
    }
    $json = $Event | ConvertTo-Json -Compress -Depth 10
    try {
        $script:_GuideWriter.WriteLine($json)
    } catch {
        Write-Verbose "Send-GuideEvent: write failed — $_"
        Disconnect-GuideServer
        throw
    }
}

function Disconnect-GuideServer {
    [CmdletBinding()]
    param()
    try { if ($script:_GuideWriter) { $script:_GuideWriter.Flush(); $script:_GuideWriter.Close() } } catch {}
    try { if ($script:_GuideStream) { $script:_GuideStream.Close() } } catch {}
    try { if ($script:_GuideClient) { $script:_GuideClient.Close() } } catch {}
    $script:_GuideClient = $null
    $script:_GuideStream = $null
    $script:_GuideWriter = $null
}

function Test-GuideServerReachable {
    [CmdletBinding()]
    param(
        [string]$Host = '127.0.0.1',
        [int]$DashboardPort = 7771,
        [int]$TimeoutMs = 1000
    )
    try {
        $req = [System.Net.HttpWebRequest]::Create("http://${Host}:${DashboardPort}/healthz")
        $req.Method = 'GET'
        $req.Timeout = $TimeoutMs
        $resp = $req.GetResponse()
        $body = (New-Object System.IO.StreamReader($resp.GetResponseStream())).ReadToEnd()
        $resp.Close()
        return ($body -match '"guide"\s*:\s*true')
    } catch {
        return $false
    }
}
```

- [ ] **Step 4: Run tests**

```bash
pwsh -NoProfile -File tools/guide/tests/ps/test-emit.ps1
```

Expected: 7 PASS lines, exit 0.

- [ ] **Step 5: Commit**

```bash
git add tools/guide/ps/lib/emit.ps1 tools/guide/tests/ps/test-emit.ps1
git commit -m "guide(ps-emit): TCP/JSONL client with connect/send/disconnect/reachable"
```

### Task 2.3: Wire emit into `guide.psm1` and update manifest

**Files:**
- Modify: `tools/guide/ps/guide.psm1`
- Modify: `tools/guide/ps/guide.psd1`

- [ ] **Step 1: Open `ps/guide.psm1` and verify lib auto-source picks up `emit.ps1`**

The existing module loader dot-sources every `*.ps1` in `lib/`. Confirm by running:

```bash
pwsh -NoProfile -Command "Import-Module tools/guide/ps/guide.psd1 -Force; Get-Command Connect-GuideServer, Send-GuideEvent, Disconnect-GuideServer, Test-GuideServerReachable"
```

Expected: all four functions listed.

- [ ] **Step 2: Update `ps/guide.psd1` exports to the v2 list**

Replace the `FunctionsToExport` list entirely:

```powershell
FunctionsToExport = @(
    'New-GuidePlan'
    'Add-GuideLoopPhase'
    'Add-GuideSinglePhase'
    'New-GuideResult'
    'New-GuideAlert'
    'Test-GuidePlan'
    'Invoke-GuidePlan'
    'Invoke-GuidePlanPhases'
    'Connect-GuideServer'
    'Send-GuideEvent'
    'Disconnect-GuideServer'
    'Test-GuideServerReachable'
    'Get-GuideVersion'
)
```

- [ ] **Step 3: Update `ps/guide.psd1` description**

```powershell
Description = 'Plan-event emitter for the Bun guide dashboard server.'
```

- [ ] **Step 4: Re-run import and verify emit + plan exports load cleanly**

```bash
pwsh -NoProfile -Command "Import-Module tools/guide/ps/guide.psd1 -Force *>&1"
```

Expected: empty output (no warnings, no errors).

- [ ] **Step 5: Commit**

```bash
git add tools/guide/ps/guide.psm1 tools/guide/ps/guide.psd1
git commit -m "guide(ps): expose emit functions; trim manifest exports to v2 surface"
```

### Task 2.4: Add `Invoke-GuidePlanPhases` orchestrator helper

**Files:**
- Modify: `tools/guide/ps/lib/plan.ps1`
- Create: `tools/guide/tests/ps/test-orchestrator.ps1`

- [ ] **Step 1: Write failing test**

`tools/guide/tests/ps/test-orchestrator.ps1`:

```powershell
. "$PSScriptRoot/../../ps/lib/plan.ps1"
. "$PSScriptRoot/../../ps/lib/state.ps1"

$failures = 0
function Assert-Equal($expected, $actual, $msg) {
    if ($expected -eq $actual) { Write-Host "PASS: $msg" -ForegroundColor Green }
    else { Write-Host "FAIL: $msg — expected $expected got $actual" -ForegroundColor Red; $script:failures++ }
}

# Build a plan with two single phases
$plan = New-GuidePlan -Title 'T' -Subtitle 's'
$plan = Add-GuideSinglePhase -Plan $plan -Name 'P1' -Action {
    return New-GuideResult -Success $true -Message 'p1 ok'
}
$plan = Add-GuideSinglePhase -Plan $plan -Name 'P2' -Action {
    return New-GuideResult -Success $false -Message 'p2 fail' -Severity 'fail'
}

$starts = @()
$results = @()
$ends = @()
Invoke-GuidePlanPhases -Plan $plan `
    -OnPhaseStart  { param($info) $script:starts  += $info.PhaseName } `
    -OnPhaseResult { param($info) $script:results += "$($info.PhaseName)=$($info.Success)" } `
    -OnPhaseEnd    { param($info) $script:ends    += "$($info.PhaseName)=$($info.Status)" }

Assert-Equal 2 $starts.Count  'two phase starts'
Assert-Equal 'P1' $starts[0]   'P1 first'
Assert-Equal 'P2' $starts[1]   'P2 second'
Assert-Equal 2 $results.Count  'two phase results'
Assert-Equal 'P1=True'  $results[0] 'P1 succeeded'
Assert-Equal 'P2=False' $results[1] 'P2 failed'
Assert-Equal 'P1=ok'    $ends[0]    'P1 status ok'
Assert-Equal 'P2=fail'  $ends[1]    'P2 status fail'

if ($failures -eq 0) { exit 0 } else { exit 1 }
```

- [ ] **Step 2: Run to confirm failure**

```bash
pwsh -NoProfile -File tools/guide/tests/ps/test-orchestrator.ps1
```

Expected: FAIL — `Invoke-GuidePlanPhases` not defined.

- [ ] **Step 3: Implement `Invoke-GuidePlanPhases`**

Append to `tools/guide/ps/lib/plan.ps1`:

```powershell
function Invoke-GuidePlanPhases {
    <#
    .SYNOPSIS
        Iterate plan phases, invoking three callbacks per phase. No rendering.
    .DESCRIPTION
        Used by Invoke-GuidePlan in v2 to drive phase execution while events
        are emitted to the Bun server. Pure orchestration: callers handle I/O.
    .PARAMETER OnPhaseStart
        Invoked once per phase before its action runs. Receives @{ PhaseName, PhaseIndex, PhaseTotal, Type }.
    .PARAMETER OnPhaseResult
        Invoked per phase action result. Receives @{ PhaseName, ItemLabel, Success, Message, Severity, FixCommand, Alerts }.
        Loop phases call this once per item; single phases call it once.
    .PARAMETER OnPhaseEnd
        Invoked once per phase after its action(s) complete. Receives @{ PhaseName, Status }.
        Status is 'ok' | 'warn' | 'fail' based on the worst result.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Plan,
        [Parameter(Mandatory)][scriptblock]$OnPhaseStart,
        [Parameter(Mandatory)][scriptblock]$OnPhaseResult,
        [Parameter(Mandatory)][scriptblock]$OnPhaseEnd
    )

    $phaseTotal = $Plan.Phases.Count
    for ($i = 0; $i -lt $phaseTotal; $i++) {
        $phase = $Plan.Phases[$i]
        $type  = if ($phase.ContainsKey('Type')) { $phase.Type } else { 'loop' }
        & $OnPhaseStart @{
            PhaseName  = $phase.Name
            PhaseIndex = $i + 1
            PhaseTotal = $phaseTotal
            Type       = $type
        }

        $worst = 'ok'
        $items = if ($type -eq 'loop') { $phase.Items } else { @($null) }

        foreach ($item in $items) {
            $itemLabel = if ($null -ne $item) { "$item" } else { '' }
            $result = if ($type -eq 'loop') {
                & $phase.Action $item
            } else {
                & $phase.Action
            }
            if ($null -eq $result) {
                $result = New-GuideResult -Success $true -Message ''
            }

            $sev = if ($result.ContainsKey('Severity')) { $result.Severity } else { $null }
            if (-not $result.Success) {
                $worst = if ($sev -eq 'warn') { if ($worst -eq 'ok') { 'warn' } else { $worst } } else { 'fail' }
            } elseif ($sev -eq 'warn' -and $worst -eq 'ok') {
                $worst = 'warn'
            }

            & $OnPhaseResult @{
                PhaseName  = $phase.Name
                ItemLabel  = $itemLabel
                Success    = $result.Success
                Message    = $result.Message
                Severity   = $sev
                FixCommand = if ($result.ContainsKey('FixCommand')) { $result.FixCommand } else { $null }
                Alerts     = if ($result.ContainsKey('Alerts'))     { $result.Alerts }     else { @() }
            }
        }

        & $OnPhaseEnd @{ PhaseName = $phase.Name; Status = $worst }
    }
}
```

- [ ] **Step 4: Run tests**

```bash
pwsh -NoProfile -File tools/guide/tests/ps/test-orchestrator.ps1
```

Expected: 8 PASS, exit 0.

- [ ] **Step 5: Commit**

```bash
git add tools/guide/ps/lib/plan.ps1 tools/guide/tests/ps/test-orchestrator.ps1
git commit -m "guide(ps-plan): Invoke-GuidePlanPhases orchestrator helper"
```

---

## Phase 3: Bun server skeleton

HTTP + static files + WebSocket upgrade + `/healthz` + port allocator. No plan event protocol or PTY yet — those land in Phase 4 and 6.

### Task 3.1: Port allocator (`lib/port.ts`)

**Files:**
- Create: `tools/guide/lib/port.ts`
- Test: `tools/guide/tests/server/port.test.ts`

- [ ] **Step 1: Write failing test**

```ts
import { describe, expect, test } from 'bun:test'
import { pickPort } from '../../lib/port.ts'

describe('pickPort', () => {
  test('returns the requested port when free', async () => {
    const p = await pickPort(54321)
    expect(p).toBe(54321)
  })

  test('falls back upward when port is taken', async () => {
    // Hold a TCP listener on port X to force pickPort to skip it.
    const taken = Bun.listen({ hostname: '127.0.0.1', port: 54322, socket: { data() {} } })
    try {
      const p = await pickPort(54322, { maxAttempts: 3 })
      expect(p).toBeGreaterThan(54322)
      expect(p).toBeLessThanOrEqual(54325)
    } finally {
      taken.stop(true)
    }
  })

  test('throws after maxAttempts when nothing free', async () => {
    const blocks = [
      Bun.listen({ hostname: '127.0.0.1', port: 54330, socket: { data() {} } }),
      Bun.listen({ hostname: '127.0.0.1', port: 54331, socket: { data() {} } }),
      Bun.listen({ hostname: '127.0.0.1', port: 54332, socket: { data() {} } }),
    ]
    try {
      await expect(pickPort(54330, { maxAttempts: 3 })).rejects.toThrow(/no free port/i)
    } finally {
      blocks.forEach(b => b.stop(true))
    }
  })
})
```

- [ ] **Step 2: Run to confirm failure**

```bash
cd tools/guide && bun test tests/server/port.test.ts
```

Expected: FAIL — `lib/port.ts` not found.

- [ ] **Step 3: Implement `lib/port.ts`**

```ts
// Probe whether a port is free on 127.0.0.1 by trying to bind a transient TCP
// listener. If bind succeeds, the port is free; close immediately and report.
export async function isPortFree(port: number): Promise<boolean> {
  try {
    const sock = Bun.listen({ hostname: '127.0.0.1', port, socket: { data() {} } })
    sock.stop(true)
    return true
  } catch {
    return false
  }
}

export async function pickPort(start: number, opts: { maxAttempts?: number } = {}): Promise<number> {
  const max = opts.maxAttempts ?? 10
  for (let i = 0; i < max; i++) {
    const p = start + i
    if (await isPortFree(p)) return p
  }
  throw new Error(`no free port in range ${start}..${start + max - 1}`)
}
```

- [ ] **Step 4: Run tests**

```bash
bun test tests/server/port.test.ts
```

Expected: 3 pass, 0 fail.

- [ ] **Step 5: Commit**

```bash
git add tools/guide/lib/port.ts tools/guide/tests/server/port.test.ts
git commit -m "guide(server): port allocator with fall-forward and max-attempts"
```

### Task 3.2: HTTP routing + `/healthz`

**Files:**
- Create: `tools/guide/server.ts`
- Create: `tools/guide/tests/server/routing.test.ts`

- [ ] **Step 1: Write failing routing test**

```ts
import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { startServer, type GuideServer } from '../../server.ts'

let server: GuideServer

beforeEach(async () => {
  server = await startServer({ httpPort: 0, eventsPort: 0, openBrowser: false, dataDir: ':memory:' })
})
afterEach(() => { server.stop() })

describe('routing', () => {
  test('GET / returns HTML', async () => {
    const r = await fetch(`http://127.0.0.1:${server.httpPort}/`)
    expect(r.status).toBe(200)
    expect(r.headers.get('content-type')).toMatch(/text\/html/)
    const body = await r.text()
    expect(body).toMatch(/<html/i)
  })

  test('GET /healthz returns guide JSON', async () => {
    const r = await fetch(`http://127.0.0.1:${server.httpPort}/healthz`)
    expect(r.status).toBe(200)
    const json = await r.json() as { guide: boolean; mode: string; version: string }
    expect(json.guide).toBe(true)
    expect(json.mode).toBe('plan')
    expect(typeof json.version).toBe('string')
  })

  test('GET unknown path returns 404', async () => {
    const r = await fetch(`http://127.0.0.1:${server.httpPort}/no-such-thing`)
    expect(r.status).toBe(404)
  })

  test('GET /static path-traversal is rejected', async () => {
    const r = await fetch(`http://127.0.0.1:${server.httpPort}/static/../../../etc/passwd`)
    expect([400, 403, 404]).toContain(r.status)
  })
})
```

- [ ] **Step 2: Run to confirm failure**

```bash
bun test tests/server/routing.test.ts
```

Expected: FAIL — `server.ts` not found.

- [ ] **Step 3: Implement `server.ts` skeleton**

```ts
// tools/guide/server.ts
import { resolve, normalize, sep } from 'node:path'
import { existsSync } from 'node:fs'
import { pickPort } from './lib/port.ts'
import { applyMigrations, openDb, resolveDataDir } from './lib/db.ts'
import type { Database } from 'bun:sqlite'

export type ServerMode = 'plan' | 'shell-only'

export type StartOpts = {
  httpPort?: number              // 0 = auto-allocate from 7771; otherwise force
  eventsPort?: number            // 0 = httpPort + 1
  openBrowser?: boolean          // default true; tests pass false
  dataDir?: string               // ':memory:' for tests
  defaultShell?: 'pwsh' | 'bash'
  mode?: ServerMode
  workspace?: string
}

export type GuideServer = {
  httpPort: number
  eventsPort: number
  mode: ServerMode
  db: Database
  stop: () => void
}

export const VERSION = '0.2.0'

const PUBLIC_DIR = resolve(import.meta.dir, 'public')

function detectDefaultShell(): 'pwsh' | 'bash' {
  return process.platform === 'win32' ? 'pwsh' : 'bash'
}

function safeStaticPath(urlPath: string): string | null {
  // urlPath comes in like '/static/app.js'. Strip prefix, normalize, ensure inside PUBLIC_DIR.
  const rel = urlPath.replace(/^\/static\//, '')
  const target = resolve(PUBLIC_DIR, rel)
  const norm = normalize(target)
  if (!norm.startsWith(PUBLIC_DIR + sep) && norm !== PUBLIC_DIR) return null
  if (!existsSync(norm)) return null
  return norm
}

function contentTypeFor(path: string): string {
  if (path.endsWith('.html')) return 'text/html; charset=utf-8'
  if (path.endsWith('.css'))  return 'text/css; charset=utf-8'
  if (path.endsWith('.js'))   return 'application/javascript; charset=utf-8'
  if (path.endsWith('.json')) return 'application/json; charset=utf-8'
  return 'application/octet-stream'
}

export async function startServer(opts: StartOpts = {}): Promise<GuideServer> {
  const mode = opts.mode ?? 'plan'
  const defaultShell = opts.defaultShell ?? detectDefaultShell()

  const httpPort = opts.httpPort && opts.httpPort > 0
    ? opts.httpPort
    : await pickPort(7771)

  // DB
  const dbPath = opts.dataDir === ':memory:'
    ? ':memory:'
    : `${resolveDataDir({ dataDir: opts.dataDir })}/guide.db`
  if (dbPath !== ':memory:') {
    const dir = resolveDataDir({ dataDir: opts.dataDir })
    await Bun.$`mkdir -p ${dir}`.quiet().nothrow()
  }
  const db = dbPath === ':memory:' ? (await import('bun:sqlite')).Database
    ? new ((await import('bun:sqlite')).Database)(':memory:') : null! : openDb(dbPath)
  if (dbPath === ':memory:') applyMigrations(db)

  const httpServer = Bun.serve({
    hostname: '127.0.0.1',
    port: httpPort,
    fetch(req, srv) {
      const url = new URL(req.url)

      if (url.pathname === '/healthz') {
        return new Response(JSON.stringify({
          guide: true, mode, version: VERSION, defaultShell,
        }), { headers: { 'content-type': 'application/json' } })
      }

      if (url.pathname === '/' || url.pathname === '/index.html') {
        const indexPath = resolve(PUBLIC_DIR, 'index.html')
        if (!existsSync(indexPath)) {
          return new Response(
            '<!doctype html><meta charset=utf-8><title>guide</title><h1>guide server up</h1>',
            { headers: { 'content-type': 'text/html; charset=utf-8' } }
          )
        }
        return new Response(Bun.file(indexPath), { headers: { 'content-type': 'text/html; charset=utf-8' } })
      }

      if (url.pathname.startsWith('/static/')) {
        const file = safeStaticPath(url.pathname)
        if (!file) return new Response('forbidden', { status: 403 })
        return new Response(Bun.file(file), { headers: { 'content-type': contentTypeFor(file) } })
      }

      if (url.pathname === '/ws' && srv.upgrade(req)) return
      return new Response('not found', { status: 404 })
    },
    websocket: {
      open(_ws)         { /* placeholder for Phase 4 */ },
      message(_ws, _m)  { /* placeholder for Phase 4 */ },
      close(_ws)        { /* placeholder for Phase 4 */ },
    },
  })

  const eventsPort = opts.eventsPort && opts.eventsPort > 0
    ? opts.eventsPort
    : httpPort + 1
  // TCP listener placeholder — actual handler lands in Phase 4
  const tcpServer = Bun.listen({
    hostname: '127.0.0.1',
    port: eventsPort,
    socket: {
      data(_socket, _data) { /* placeholder */ },
      open(_socket)        { /* placeholder */ },
      close(_socket)       { /* placeholder */ },
    },
  })

  return {
    httpPort: httpServer.port,
    eventsPort: tcpServer.port,
    mode,
    db,
    stop() {
      try { httpServer.stop(true) } catch {}
      try { tcpServer.stop(true)  } catch {}
      try { db.close() } catch {}
    },
  }
}
```

- [ ] **Step 4: Create a placeholder `public/index.html` so the GET `/` test has content**

```html
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Guide</title>
</head>
<body>
  <h1>Guide server</h1>
  <p>Dashboard placeholder — Phase 5 wires the real UI.</p>
</body>
</html>
```

- [ ] **Step 5: Run tests**

```bash
bun test tests/server/routing.test.ts
```

Expected: 4 pass, 0 fail.

- [ ] **Step 6: Commit**

```bash
git add tools/guide/server.ts tools/guide/public/index.html tools/guide/tests/server/routing.test.ts
git commit -m "guide(server): HTTP routing skeleton with /healthz and static-file safety"
```

### Task 3.3: WebSocket upgrade + broadcast helper

**Files:**
- Create: `tools/guide/lib/ws.ts`
- Modify: `tools/guide/server.ts`
- Create: `tools/guide/tests/server/ws.test.ts`

- [ ] **Step 1: Write failing test**

```ts
import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { startServer, type GuideServer } from '../../server.ts'

let server: GuideServer

beforeEach(async () => {
  server = await startServer({ httpPort: 0, eventsPort: 0, openBrowser: false, dataDir: ':memory:' })
})
afterEach(() => { server.stop() })

function connectWs(port: number): Promise<WebSocket> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws`)
    ws.addEventListener('open',  () => resolve(ws))
    ws.addEventListener('error', reject)
  })
}

describe('websocket', () => {
  test('client receives server-info on connect', async () => {
    const ws = await connectWs(server.httpPort)
    const msg = await new Promise<any>(resolve => {
      ws.addEventListener('message', e => resolve(JSON.parse(e.data)), { once: true })
    })
    ws.close()
    expect(msg.type).toBe('server-info')
    expect(msg.mode).toBe('plan')
    expect(['pwsh', 'bash']).toContain(msg.defaultShell)
    expect(typeof msg.port).toBe('number')
  })

  test('broadcast reaches multiple clients', async () => {
    const w1 = await connectWs(server.httpPort)
    const w2 = await connectWs(server.httpPort)
    // Skip the initial server-info
    await new Promise(r => w1.addEventListener('message', r, { once: true }))
    await new Promise(r => w2.addEventListener('message', r, { once: true }))

    const seen1 = new Promise<string>(r => w1.addEventListener('message', e => r(e.data), { once: true }))
    const seen2 = new Promise<string>(r => w2.addEventListener('message', e => r(e.data), { once: true }))

    server.broadcast({ type: 'plan-update', payload: { foo: 'bar' } })

    const [m1, m2] = await Promise.all([seen1, seen2])
    expect(JSON.parse(m1).type).toBe('plan-update')
    expect(JSON.parse(m2).type).toBe('plan-update')
    w1.close(); w2.close()
  })
})
```

- [ ] **Step 2: Run to confirm failure**

```bash
bun test tests/server/ws.test.ts
```

Expected: FAIL — `server.broadcast` does not exist.

- [ ] **Step 3: Implement `lib/ws.ts`**

```ts
// tools/guide/lib/ws.ts
import type { ServerWebSocket } from 'bun'

export type WsMsg =
  | { type: 'server-info'; mode: 'plan' | 'shell-only'; defaultShell: 'pwsh' | 'bash'; port: number }
  | { type: 'plan-snapshot'; plan: unknown }
  | { type: 'plan-update'; payload: unknown }
  | { type: 'shell-spawned'; shell: 'pwsh' | 'bash'; cwd: string; cols: number; rows: number }
  | { type: 'shell-spawned-error'; shell: 'pwsh' | 'bash'; error: string }
  | { type: 'shell-output'; shell: 'pwsh' | 'bash'; data: string }
  | { type: 'shell-exit'; shell: 'pwsh' | 'bash'; code: number | null }
  | { type: 'history-page'; entries: unknown[]; hasMore: boolean }
  | { type: 'history-appended'; entry: unknown }
  | { type: 'history-updated'; id: number; exit_code: number | null; duration_ms: number | null }
  | { type: 'plan-runs-page'; runs: unknown[] }

export class WsBroker {
  private clients = new Set<ServerWebSocket<unknown>>()

  add(ws: ServerWebSocket<unknown>): void { this.clients.add(ws) }
  remove(ws: ServerWebSocket<unknown>): void { this.clients.delete(ws) }
  count(): number { return this.clients.size }

  broadcast(msg: WsMsg): void {
    const text = JSON.stringify(msg)
    for (const ws of this.clients) {
      try { ws.send(text) } catch { /* drop, will be removed on close */ }
    }
  }
}
```

- [ ] **Step 4: Wire `WsBroker` into `server.ts`**

Replace the `websocket: { open, message, close }` placeholder block with:

```ts
import { WsBroker, type WsMsg } from './lib/ws.ts'
// (other imports unchanged)

// Inside startServer(), before the Bun.serve call:
const broker = new WsBroker()

// Replace the websocket handlers:
websocket: {
  open(ws) {
    broker.add(ws)
    const info: WsMsg = {
      type: 'server-info',
      mode,
      defaultShell,
      port: httpPort,
    }
    ws.send(JSON.stringify(info))
  },
  message(_ws, _m) { /* incoming client messages handled in Phase 6 (shell) and Phase 8 (history queries) */ },
  close(ws) { broker.remove(ws) },
},
```

And in the returned `GuideServer` object, add a `broadcast` method:

```ts
return {
  httpPort: httpServer.port,
  eventsPort: tcpServer.port,
  mode,
  db,
  broadcast(msg: WsMsg) { broker.broadcast(msg) },
  stop() { /* unchanged */ },
}
```

Also widen the `GuideServer` type:

```ts
export type GuideServer = {
  httpPort: number
  eventsPort: number
  mode: ServerMode
  db: Database
  broadcast: (msg: WsMsg) => void
  stop: () => void
}
```

- [ ] **Step 5: Run tests**

```bash
bun test tests/server/ws.test.ts
```

Expected: 2 pass, 0 fail.

- [ ] **Step 6: Run all server tests so far together**

```bash
bun test tests/server
```

Expected: db (12) + port (3) + routing (4) + ws (2) = 21 pass, 0 fail.

- [ ] **Step 7: Commit**

```bash
git add tools/guide/lib/ws.ts tools/guide/server.ts tools/guide/tests/server/ws.test.ts
git commit -m "guide(server): WsBroker with server-info on connect and broadcast helper"
```

---

## Phase 4: Plan-event protocol

PS emitter → TCP socket → `events.ts` parser → `state.ts` mutation → `WsBroker.broadcast(plan-update)`.

### Task 4.1: Event types and JSONL parser (`lib/events.ts`)

**Files:**
- Create: `tools/guide/lib/events.ts`
- Test: `tools/guide/tests/server/events.test.ts`

- [ ] **Step 1: Write failing test**

```ts
import { describe, expect, test } from 'bun:test'
import { JsonlBuffer, type GuideEvent } from '../../lib/events.ts'

describe('JsonlBuffer', () => {
  test('emits one event per complete line', () => {
    const buf = new JsonlBuffer()
    const out: GuideEvent[] = []
    buf.feed('{"type":"plan-started","planId":"p1","title":"T","subtitle":"s","phases":[]}\n', e => out.push(e))
    expect(out).toHaveLength(1)
    expect(out[0]!.type).toBe('plan-started')
  })

  test('handles split frames (line straddles two feeds)', () => {
    const buf = new JsonlBuffer()
    const out: GuideEvent[] = []
    buf.feed('{"type":"phase-started","planId":"p1","phaseName":"P', e => out.push(e))
    expect(out).toHaveLength(0)
    buf.feed('1","phaseIndex":1,"phaseTotal":2}\n', e => out.push(e))
    expect(out).toHaveLength(1)
    expect((out[0] as any).phaseName).toBe('P1')
  })

  test('handles multiple events in one feed', () => {
    const buf = new JsonlBuffer()
    const out: GuideEvent[] = []
    buf.feed(
      '{"type":"phase-completed","planId":"p","phaseName":"P","status":"ok"}\n' +
      '{"type":"plan-completed","planId":"p","exitCode":0}\n',
      e => out.push(e)
    )
    expect(out).toHaveLength(2)
    expect(out[0]!.type).toBe('phase-completed')
    expect(out[1]!.type).toBe('plan-completed')
  })

  test('skips blank lines silently', () => {
    const buf = new JsonlBuffer()
    const out: GuideEvent[] = []
    buf.feed('\n\n{"type":"heartbeat","planId":"p"}\n\n', e => out.push(e))
    expect(out).toHaveLength(1)
  })

  test('parse error reports without crashing buffer', () => {
    const buf = new JsonlBuffer()
    const out: GuideEvent[] = []
    const errs: string[] = []
    buf.feed('not json\n{"type":"heartbeat","planId":"p"}\n', e => out.push(e), s => errs.push(s))
    expect(out).toHaveLength(1)
    expect(errs.length).toBe(1)
  })
})
```

- [ ] **Step 2: Run to confirm failure**

```bash
bun test tests/server/events.test.ts
```

Expected: FAIL — `lib/events.ts` not found.

- [ ] **Step 3: Implement `lib/events.ts`**

```ts
// tools/guide/lib/events.ts

export type Severity = 'info' | 'ok' | 'warn' | 'fail'

export type Alert = { severity: Severity; message: string }

export type GuideEvent =
  | {
      type: 'plan-started'
      planId: string
      title: string
      subtitle: string
      phases: { name: string; type: 'loop' | 'single'; totalItems?: number }[]
      ts?: string
    }
  | { type: 'phase-started'; planId: string; phaseName: string; phaseIndex: number; phaseTotal: number; ts?: string }
  | { type: 'active-changed'; planId: string; label: string; ts?: string }
  | {
      type: 'phase-result'
      planId: string
      phaseName: string
      itemLabel: string
      success: boolean
      message: string
      severity?: Severity | null
      fixCommand?: string | null
      alerts?: Alert[] | null
      ts?: string
    }
  | { type: 'phase-completed'; planId: string; phaseName: string; status: 'ok' | 'warn' | 'fail'; ts?: string }
  | {
      type: 'issue-emitted'
      planId: string
      severity: Severity
      message: string
      fixCommand?: string | null
      sourcePhase?: string
      sourceItem?: string
      ts?: string
    }
  | { type: 'alert-emitted'; planId: string; severity: Severity; message: string; sourcePhase?: string; ts?: string }
  | { type: 'plan-completed'; planId: string; exitCode: number; ts?: string }
  | { type: 'heartbeat'; planId: string; ts?: string }

export class JsonlBuffer {
  private partial = ''

  feed(
    chunk: string,
    onEvent: (e: GuideEvent) => void,
    onError?: (s: string) => void
  ): void {
    this.partial += chunk
    let nl
    while ((nl = this.partial.indexOf('\n')) >= 0) {
      const line = this.partial.slice(0, nl).trim()
      this.partial = this.partial.slice(nl + 1)
      if (!line) continue
      try {
        const obj = JSON.parse(line) as GuideEvent
        onEvent(obj)
      } catch (e) {
        if (onError) onError(`JSON parse failed for line: ${line.slice(0, 120)}`)
      }
    }
  }
}
```

- [ ] **Step 4: Run tests**

```bash
bun test tests/server/events.test.ts
```

Expected: 5 pass, 0 fail.

- [ ] **Step 5: Commit**

```bash
git add tools/guide/lib/events.ts tools/guide/tests/server/events.test.ts
git commit -m "guide(server): GuideEvent union + JsonlBuffer with split-frame handling"
```

### Task 4.2: In-memory PlanState store (`lib/state.ts`)

**Files:**
- Create: `tools/guide/lib/state.ts`
- Test: `tools/guide/tests/server/state.test.ts`

- [ ] **Step 1: Write failing test**

```ts
import { describe, expect, test } from 'bun:test'
import { PlanStore } from '../../lib/state.ts'

describe('PlanStore', () => {
  test('plan-started creates a fresh plan', () => {
    const s = new PlanStore()
    s.apply({
      type: 'plan-started', planId: 'p1', title: 'T', subtitle: 's',
      phases: [{ name: 'A', type: 'single' }, { name: 'B', type: 'loop', totalItems: 3 }],
      ts: '2026-04-29T00:00:00Z',
    })
    const snap = s.snapshot('p1')!
    expect(snap.title).toBe('T')
    expect(snap.phases).toHaveLength(2)
    expect(snap.phases[0]!.status).toBe('pending')
  })

  test('phase-started flips status to running', () => {
    const s = new PlanStore()
    s.apply({ type:'plan-started', planId:'p1', title:'T', subtitle:'', phases:[{name:'A', type:'single'}] })
    s.apply({ type:'phase-started', planId:'p1', phaseName:'A', phaseIndex:1, phaseTotal:1 })
    expect(s.snapshot('p1')!.phases[0]!.status).toBe('running')
  })

  test('phase-completed sets status from event', () => {
    const s = new PlanStore()
    s.apply({ type:'plan-started', planId:'p1', title:'', subtitle:'', phases:[{name:'A', type:'single'}] })
    s.apply({ type:'phase-completed', planId:'p1', phaseName:'A', status:'fail' })
    expect(s.snapshot('p1')!.phases[0]!.status).toBe('fail')
  })

  test('issue-emitted appends to issues', () => {
    const s = new PlanStore()
    s.apply({ type:'plan-started', planId:'p1', title:'', subtitle:'', phases:[] })
    s.apply({ type:'issue-emitted', planId:'p1', severity:'fail', message:'oops', fixCommand:'fix me' })
    expect(s.snapshot('p1')!.issues).toHaveLength(1)
    expect(s.snapshot('p1')!.issues[0]!.message).toBe('oops')
    expect(s.snapshot('p1')!.issues[0]!.fixCommand).toBe('fix me')
  })

  test('active-changed sets active label', () => {
    const s = new PlanStore()
    s.apply({ type:'plan-started', planId:'p1', title:'', subtitle:'', phases:[{name:'A', type:'loop'}] })
    s.apply({ type:'active-changed', planId:'p1', label:'item-1' })
    expect(s.snapshot('p1')!.active).toEqual({ phaseName: '', itemLabel: 'item-1' })
  })

  test('plan-completed sets exitCode + completedAt', () => {
    const s = new PlanStore()
    s.apply({ type:'plan-started', planId:'p1', title:'', subtitle:'', phases:[] })
    s.apply({ type:'plan-completed', planId:'p1', exitCode: 0 })
    const snap = s.snapshot('p1')!
    expect(snap.exitCode).toBe(0)
    expect(snap.completedAt).not.toBeNull()
  })

  test('mostRecent returns last started plan', () => {
    const s = new PlanStore()
    s.apply({ type:'plan-started', planId:'p1', title:'T1', subtitle:'', phases:[] })
    s.apply({ type:'plan-started', planId:'p2', title:'T2', subtitle:'', phases:[] })
    expect(s.mostRecent()!.title).toBe('T2')
  })

  test('events for unknown planId are dropped silently', () => {
    const s = new PlanStore()
    expect(() =>
      s.apply({ type:'phase-started', planId:'nope', phaseName:'X', phaseIndex:1, phaseTotal:1 })
    ).not.toThrow()
    expect(s.snapshot('nope')).toBeNull()
  })
})
```

- [ ] **Step 2: Run to confirm failure**

```bash
bun test tests/server/state.test.ts
```

Expected: FAIL — `PlanStore` not exported.

- [ ] **Step 3: Implement `lib/state.ts`**

```ts
// tools/guide/lib/state.ts
import type { GuideEvent, Severity, Alert } from './events.ts'

export type PhaseStatus = 'pending' | 'running' | 'ok' | 'warn' | 'fail'

export type Phase = {
  name: string
  type: 'loop' | 'single'
  totalItems?: number
  completedItems: number
  status: PhaseStatus
}

export type Issue = {
  severity: Severity
  message: string
  fixCommand?: string | null
  sourcePhase?: string
  sourceItem?: string
}

export type PlanSnapshot = {
  planId: string
  title: string
  subtitle: string
  startedAt: string
  completedAt: string | null
  exitCode: number | null
  phases: Phase[]
  active: { phaseName: string; itemLabel: string } | null
  issues: Issue[]
  alerts: Alert[]
  lastHeartbeat: string
}

export class PlanStore {
  private plans = new Map<string, PlanSnapshot>()
  private order: string[] = []

  apply(e: GuideEvent): void {
    if (e.type === 'plan-started') {
      const plan: PlanSnapshot = {
        planId: e.planId,
        title: e.title,
        subtitle: e.subtitle,
        startedAt: e.ts ?? new Date().toISOString(),
        completedAt: null,
        exitCode: null,
        phases: e.phases.map(p => ({
          name: p.name,
          type: p.type,
          totalItems: p.totalItems,
          completedItems: 0,
          status: 'pending',
        })),
        active: null,
        issues: [],
        alerts: [],
        lastHeartbeat: e.ts ?? new Date().toISOString(),
      }
      this.plans.set(e.planId, plan)
      this.order.push(e.planId)
      return
    }

    const plan = this.plans.get(e.planId)
    if (!plan) return // unknown planId — drop

    plan.lastHeartbeat = e.ts ?? new Date().toISOString()

    switch (e.type) {
      case 'phase-started': {
        const ph = plan.phases.find(p => p.name === e.phaseName)
        if (ph) ph.status = 'running'
        plan.active = { phaseName: e.phaseName, itemLabel: '' }
        break
      }
      case 'active-changed': {
        const phaseName = plan.active?.phaseName ?? ''
        plan.active = { phaseName, itemLabel: e.label }
        break
      }
      case 'phase-result': {
        const ph = plan.phases.find(p => p.name === e.phaseName)
        if (ph) ph.completedItems += 1
        if (!e.success && e.severity !== 'warn') {
          plan.issues.push({
            severity: e.severity ?? 'fail',
            message: e.message,
            fixCommand: e.fixCommand ?? null,
            sourcePhase: e.phaseName,
            sourceItem: e.itemLabel,
          })
        }
        if (e.alerts?.length) {
          for (const a of e.alerts) plan.alerts.push(a)
        }
        break
      }
      case 'phase-completed': {
        const ph = plan.phases.find(p => p.name === e.phaseName)
        if (ph) ph.status = e.status
        break
      }
      case 'issue-emitted': {
        plan.issues.push({
          severity: e.severity, message: e.message,
          fixCommand: e.fixCommand ?? null,
          sourcePhase: e.sourcePhase, sourceItem: e.sourceItem,
        })
        break
      }
      case 'alert-emitted': {
        plan.alerts.push({ severity: e.severity, message: e.message })
        break
      }
      case 'plan-completed': {
        plan.completedAt = e.ts ?? new Date().toISOString()
        plan.exitCode = e.exitCode
        plan.active = null
        break
      }
      case 'heartbeat': /* lastHeartbeat already set */ break
    }
  }

  snapshot(planId: string): PlanSnapshot | null {
    return this.plans.get(planId) ?? null
  }

  mostRecent(): PlanSnapshot | null {
    for (let i = this.order.length - 1; i >= 0; i--) {
      const p = this.plans.get(this.order[i]!)
      if (p) return p
    }
    return null
  }

  all(): PlanSnapshot[] {
    return this.order.map(id => this.plans.get(id)).filter(Boolean) as PlanSnapshot[]
  }
}
```

- [ ] **Step 4: Run tests**

```bash
bun test tests/server/state.test.ts
```

Expected: 8 pass, 0 fail.

- [ ] **Step 5: Commit**

```bash
git add tools/guide/lib/state.ts tools/guide/tests/server/state.test.ts
git commit -m "guide(server): PlanStore in-memory state with event-driven mutations"
```

### Task 4.3: Wire TCP listener → JsonlBuffer → PlanStore → broadcast

**Files:**
- Modify: `tools/guide/server.ts`
- Modify: `tools/guide/tests/server/ws.test.ts` (add integration test)

- [ ] **Step 1: Append integration test to `tests/server/ws.test.ts`**

```ts
import { Socket } from 'node:net'
import { JsonlBuffer } from '../../lib/events.ts'

describe('plan event integration', () => {
  test('TCP JSONL → WS broadcast with snapshot', async () => {
    // 1. Connect a WS client and consume the initial server-info
    const ws = await connectWs(server.httpPort)
    await new Promise(r => ws.addEventListener('message', r, { once: true }))

    // 2. Connect a TCP client to the events port
    const sock = new Socket()
    await new Promise<void>((resolve, reject) => {
      sock.once('error', reject)
      sock.connect(server.eventsPort, '127.0.0.1', () => resolve())
    })

    // 3. Send plan-started over JSONL
    const planStarted = {
      type: 'plan-started',
      planId: 'pX',
      title: 'X',
      subtitle: 's',
      phases: [{ name: 'A', type: 'single' }],
    }
    sock.write(JSON.stringify(planStarted) + '\n')

    // 4. Expect plan-update on WS
    const got: any = await new Promise(r => ws.addEventListener('message', e => r(JSON.parse(e.data)), { once: true }))
    expect(got.type).toBe('plan-update')
    expect((got.payload as any).type).toBe('plan-started')

    sock.destroy()
    ws.close()
  })

  test('plan-snapshot replayed to a new client mid-run', async () => {
    // 1. Send plan-started before any client connects
    const sock = new Socket()
    await new Promise<void>(r => sock.connect(server.eventsPort, '127.0.0.1', () => r()))
    sock.write(JSON.stringify({
      type:'plan-started', planId:'pY', title:'Y', subtitle:'', phases:[],
    }) + '\n')
    // wait briefly for server to apply
    await new Promise(r => setTimeout(r, 50))

    // 2. Connect WS — first message is server-info, second should be plan-snapshot
    const ws = await connectWs(server.httpPort)
    const m1 = await new Promise<any>(r => ws.addEventListener('message', e => r(JSON.parse(e.data)), { once: true }))
    expect(m1.type).toBe('server-info')
    const m2 = await new Promise<any>(r => ws.addEventListener('message', e => r(JSON.parse(e.data)), { once: true }))
    expect(m2.type).toBe('plan-snapshot')
    expect((m2.plan as any).title).toBe('Y')

    sock.destroy()
    ws.close()
  })
})
```

- [ ] **Step 2: Run to confirm failure**

```bash
bun test tests/server/ws.test.ts
```

Expected: FAIL — TCP→WS path not wired; new client doesn't receive plan-snapshot.

- [ ] **Step 3: Update `server.ts` — wire TCP, broadcast on event, send snapshot on WS open**

Replace the placeholder TCP listener block and update the WS open handler. The file becomes:

```ts
// tools/guide/server.ts (full replacement)
import { resolve, normalize, sep } from 'node:path'
import { existsSync, mkdirSync } from 'node:fs'
import { pickPort } from './lib/port.ts'
import { applyMigrations, openDb, resolveDataDir } from './lib/db.ts'
import { JsonlBuffer, type GuideEvent } from './lib/events.ts'
import { PlanStore } from './lib/state.ts'
import { WsBroker, type WsMsg } from './lib/ws.ts'
import { Database } from 'bun:sqlite'

export type ServerMode = 'plan' | 'shell-only'

export type StartOpts = {
  httpPort?: number
  eventsPort?: number
  openBrowser?: boolean
  dataDir?: string
  defaultShell?: 'pwsh' | 'bash'
  mode?: ServerMode
  workspace?: string
}

export type GuideServer = {
  httpPort: number
  eventsPort: number
  mode: ServerMode
  db: Database
  store: PlanStore
  broadcast: (msg: WsMsg) => void
  stop: () => void
}

export const VERSION = '0.2.0'
const PUBLIC_DIR = resolve(import.meta.dir, 'public')

function detectDefaultShell(): 'pwsh' | 'bash' {
  return process.platform === 'win32' ? 'pwsh' : 'bash'
}

function safeStaticPath(urlPath: string): string | null {
  const rel = urlPath.replace(/^\/static\//, '')
  const target = resolve(PUBLIC_DIR, rel)
  const norm = normalize(target)
  if (!norm.startsWith(PUBLIC_DIR + sep) && norm !== PUBLIC_DIR) return null
  if (!existsSync(norm)) return null
  return norm
}

function contentTypeFor(path: string): string {
  if (path.endsWith('.html')) return 'text/html; charset=utf-8'
  if (path.endsWith('.css'))  return 'text/css; charset=utf-8'
  if (path.endsWith('.js'))   return 'application/javascript; charset=utf-8'
  if (path.endsWith('.json')) return 'application/json; charset=utf-8'
  return 'application/octet-stream'
}

export async function startServer(opts: StartOpts = {}): Promise<GuideServer> {
  const mode = opts.mode ?? 'plan'
  const defaultShell = opts.defaultShell ?? detectDefaultShell()

  const httpPort = opts.httpPort && opts.httpPort > 0 ? opts.httpPort : await pickPort(7771)

  // DB
  let db: Database
  if (opts.dataDir === ':memory:') {
    db = new Database(':memory:')
    applyMigrations(db)
  } else {
    const dir = resolveDataDir({ dataDir: opts.dataDir })
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true })
    db = openDb(`${dir}/guide.db`)
  }

  // State + broker
  const store  = new PlanStore()
  const broker = new WsBroker()

  // HTTP server
  const httpServer = Bun.serve({
    hostname: '127.0.0.1',
    port: httpPort,
    fetch(req, srv) {
      const url = new URL(req.url)
      if (url.pathname === '/healthz') {
        return new Response(JSON.stringify({
          guide: true, mode, version: VERSION, defaultShell,
        }), { headers: { 'content-type': 'application/json' } })
      }
      if (url.pathname === '/' || url.pathname === '/index.html') {
        const indexPath = resolve(PUBLIC_DIR, 'index.html')
        if (!existsSync(indexPath)) {
          return new Response(
            '<!doctype html><meta charset=utf-8><title>guide</title><h1>guide server up</h1>',
            { headers: { 'content-type': 'text/html; charset=utf-8' } }
          )
        }
        return new Response(Bun.file(indexPath), { headers: { 'content-type': 'text/html; charset=utf-8' } })
      }
      if (url.pathname.startsWith('/static/')) {
        const file = safeStaticPath(url.pathname)
        if (!file) return new Response('forbidden', { status: 403 })
        return new Response(Bun.file(file), { headers: { 'content-type': contentTypeFor(file) } })
      }
      if (url.pathname === '/ws' && srv.upgrade(req)) return
      return new Response('not found', { status: 404 })
    },
    websocket: {
      open(ws) {
        broker.add(ws)
        ws.send(JSON.stringify({ type:'server-info', mode, defaultShell, port: httpPort } satisfies WsMsg))
        const recent = store.mostRecent()
        if (recent) {
          ws.send(JSON.stringify({ type:'plan-snapshot', plan: recent } satisfies WsMsg))
        }
      },
      message(_ws, _m) { /* Phase 6 (shell) and Phase 8 (history queries) */ },
      close(ws) { broker.remove(ws) },
    },
  })

  // TCP plan-events listener
  type SockState = { buf: JsonlBuffer }
  const tcpServer = Bun.listen<SockState>({
    hostname: '127.0.0.1',
    port: opts.eventsPort && opts.eventsPort > 0 ? opts.eventsPort : (httpPort + 1),
    socket: {
      open(sock) { sock.data = { buf: new JsonlBuffer() } },
      data(sock, chunk) {
        const text = typeof chunk === 'string' ? chunk : new TextDecoder().decode(chunk)
        sock.data.buf.feed(text, (e: GuideEvent) => {
          store.apply(e)
          broker.broadcast({ type:'plan-update', payload: e })
        })
      },
      close(_sock) { /* nothing — the buffer is per-connection */ },
    },
  })

  return {
    httpPort: httpServer.port,
    eventsPort: tcpServer.port,
    mode, db, store,
    broadcast(msg) { broker.broadcast(msg) },
    stop() {
      try { httpServer.stop(true) } catch {}
      try { tcpServer.stop(true)  } catch {}
      try { db.close() } catch {}
    },
  }
}
```

- [ ] **Step 4: Run tests**

```bash
bun test tests/server
```

Expected: db (12) + port (3) + routing (4) + ws (2) + events (5) + state (8) + ws integration (2) = 36 pass, 0 fail.

- [ ] **Step 5: Commit**

```bash
git add tools/guide/server.ts tools/guide/tests/server/ws.test.ts
git commit -m "guide(server): TCP→JSONL→PlanStore→broadcast pipeline + snapshot replay on WS connect"
```

### Task 4.4: Cross-stack integration test — PS emit → server → WS

**Files:**
- Create: `tools/guide/tests/e2e/ps-to-ws.test.ts`

- [ ] **Step 1: Write the integration test**

```ts
import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { startServer, type GuideServer } from '../../server.ts'
import { spawnSync } from 'node:child_process'

let server: GuideServer

beforeEach(async () => {
  server = await startServer({ httpPort: 0, eventsPort: 0, openBrowser: false, dataDir: ':memory:' })
})
afterEach(() => server.stop())

describe('PS emit → server → WS', () => {
  test('plan-started lands as plan-update on the WS', async () => {
    const ws = new WebSocket(`ws://127.0.0.1:${server.httpPort}/ws`)
    await new Promise(r => ws.addEventListener('open', r, { once: true }))
    await new Promise(r => ws.addEventListener('message', r, { once: true })) // server-info

    const psScript = `
      Import-Module ${JSON.stringify(import.meta.dir + '/../../ps/guide.psd1')} -Force
      Connect-GuideServer -Port ${server.eventsPort} -TimeoutMs 2000
      Send-GuideEvent @{ type='plan-started'; planId='ps-emit-1'; title='PS emit'; subtitle=''; phases=@() }
      Disconnect-GuideServer
    `
    const r = spawnSync('pwsh', ['-NoProfile', '-Command', psScript], { encoding: 'utf8' })
    expect(r.status).toBe(0)

    const msg = await new Promise<any>(r => ws.addEventListener('message', e => r(JSON.parse(e.data)), { once: true }))
    expect(msg.type).toBe('plan-update')
    expect(msg.payload.type).toBe('plan-started')
    expect(msg.payload.title).toBe('PS emit')

    ws.close()
  })
})
```

- [ ] **Step 2: Run the test**

```bash
bun test tests/e2e/ps-to-ws.test.ts
```

Expected: 1 pass. (This is in `tests/e2e/` so it's excluded from the quick `bun test tests/server tests/browser` loop but runnable on demand.)

- [ ] **Step 3: Commit**

```bash
git add tools/guide/tests/e2e/ps-to-ws.test.ts
git commit -m "guide(e2e): cross-stack PS emit -> TCP -> server -> WS smoke test"
```

---

## Phase 5: Browser dashboard scaffolding (no shell yet)

HTML + CSS grid + vanilla JS. Sidebar renders phases / active / issues from plan-snapshot/plan-update. The shell pane and prompt are present but inert until Phase 6.

### Task 5.1: HTML structure (`public/index.html`)

**Files:**
- Modify: `tools/guide/public/index.html` (replace placeholder)

- [ ] **Step 1: Replace `public/index.html`**

```html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Guide</title>
  <link rel="stylesheet" href="/static/style.css">
</head>
<body>
  <div id="app">
    <aside id="sidebar">
      <section id="phases-section">
        <h2>Phases</h2>
        <ul id="phases"></ul>
      </section>
      <section id="active-section">
        <h2>Active</h2>
        <div id="active">Waiting…</div>
      </section>
      <section id="issues-section">
        <h2>Issues <span id="issues-count" class="count"></span></h2>
        <ol id="issues"></ol>
      </section>
      <section id="history-section" class="collapsed">
        <h2>
          <button id="history-toggle" aria-expanded="false">▸</button>
          History
        </h2>
        <input id="history-filter" type="text" placeholder="Filter…" hidden>
        <ol id="history"></ol>
      </section>
    </aside>

    <main id="shell-pane">
      <div id="term"></div>
    </main>

    <footer id="prompt">
      <div id="prefix-hint">! bash · # pwsh</div>
      <textarea id="input" placeholder="Type a command…" rows="1" autofocus></textarea>
      <div id="status"></div>
    </footer>
  </div>

  <script type="module" src="/static/app.js"></script>
</body>
</html>
```

- [ ] **Step 2: Manual smoke check**

```bash
cd tools/guide && bun server.ts &
sleep 1
curl -s http://127.0.0.1:7771/ | head -20
kill %1
```

Expected: the new HTML body comes back. Real visual check happens after Task 5.2 lands the CSS.

- [ ] **Step 3: Commit**

```bash
git add tools/guide/public/index.html
git commit -m "guide(web): real index.html with sidebar + shell + prompt regions"
```

### Task 5.2: CSS Grid layout (`public/style.css`)

**Files:**
- Create: `tools/guide/public/style.css`

- [ ] **Step 1: Write `public/style.css`**

(Theme variables lifted from current `twilight.json`.)

```css
:root {
  --bg:        #1a1830;
  --bg-alt:    #2b2040;
  --fg:        #e0d4ec;
  --frame:     #b48fd4;
  --title:     #f8e0a0;
  --accent:    #f8b870;
  --ok:        #88e8a8;
  --warn:      #f8b870;
  --fail:      #ec7878;
  --running:   #88c8f8;
  --pending:   #6a5878;
  --dim:       #9888a8;
  --chip-bg:   #382850;
  --font-mono: 'Cascadia Mono', 'JetBrains Mono', 'Menlo', monospace;
}

* { box-sizing: border-box; margin: 0; padding: 0; }

html, body {
  height: 100%;
  background: var(--bg);
  color: var(--fg);
  font-family: var(--font-mono);
  font-size: 13px;
  overflow: hidden;
}

#app {
  display: grid;
  grid-template-columns: 240px 1fr;
  grid-template-rows:    1fr auto;
  grid-template-areas:
    "sidebar shell"
    "prompt  prompt";
  height: 100vh;
}

#sidebar {
  grid-area: sidebar;
  overflow-y: auto;
  border-right: 1px solid var(--frame);
  padding: 8px;
}
#sidebar section { margin-bottom: 12px; }
#sidebar h2 {
  font-size: 11px;
  text-transform: uppercase;
  color: var(--title);
  letter-spacing: 0.05em;
  margin-bottom: 4px;
  display: flex; align-items: center; gap: 4px;
}

#phases { list-style: none; }
#phases li { padding: 2px 0; color: var(--dim); }
#phases li.running { color: var(--running); }
#phases li.ok      { color: var(--ok); }
#phases li.warn    { color: var(--warn); }
#phases li.fail    { color: var(--fail); }
#phases li.pending { color: var(--pending); }

#active { color: var(--fg); padding: 4px 0; }

#issues-count {
  display: inline-block;
  background: var(--chip-bg);
  color: var(--fg);
  font-size: 10px;
  padding: 1px 6px;
  border-radius: 999px;
}
#issues { list-style: none; }
#issues li { display: flex; gap: 4px; padding: 2px 0; align-items: flex-start; }
#issues li button {
  background: none; border: 1px solid var(--frame);
  color: var(--accent); font-family: inherit; font-size: inherit;
  padding: 0 4px; cursor: pointer; flex-shrink: 0;
}
#issues li button:hover { background: var(--chip-bg); }

#history-section.collapsed #history,
#history-section.collapsed #history-filter { display: none; }
#history { list-style: none; max-height: 240px; overflow-y: auto; }
#history li {
  display: grid;
  grid-template-columns: 1em 1fr auto;
  gap: 4px; padding: 2px 0; cursor: pointer; font-size: 12px;
}
#history li:hover { background: var(--chip-bg); }
#history li.failed { color: var(--fail); }
#history li .pfx { color: var(--accent); }
#history li .age { color: var(--dim); }

#history-toggle {
  background: none; border: none; color: var(--accent);
  font-family: inherit; cursor: pointer; width: 1em; text-align: center;
}

#shell-pane {
  grid-area: shell;
  min-width: 0;
  background: var(--bg);
  position: relative;
}
#term { width: 100%; height: 100%; }

#prompt {
  grid-area: prompt;
  border-top: 1px solid var(--frame);
  display: grid;
  grid-template-columns: auto 1fr auto;
  gap: 8px;
  padding: 6px 8px;
  align-items: center;
  background: var(--bg-alt);
}
#prefix-hint { color: var(--dim); font-size: 11px; white-space: nowrap; }
#input {
  background: transparent; border: none; color: var(--fg);
  font-family: inherit; font-size: inherit;
  resize: none; outline: none; width: 100%;
  max-height: 168px; overflow-y: auto;
}
#status { color: var(--dim); font-size: 11px; white-space: nowrap; }
#status.running::before {
  content: "● ";
  color: var(--running);
  animation: blink 1s infinite;
}
@keyframes blink { 0%, 49% { opacity: 1; } 50%, 100% { opacity: 0.3; } }

.toast {
  position: fixed;
  bottom: 12px; left: 50%;
  transform: translateX(-50%);
  background: var(--chip-bg); color: var(--fg);
  padding: 4px 12px; border-radius: 4px; font-size: 12px;
  opacity: 0; transition: opacity 200ms; pointer-events: none;
}
.toast.show { opacity: 1; }
```

- [ ] **Step 2: Manual visual smoke**

```bash
cd tools/guide && bun server.ts
# Open http://127.0.0.1:7771/ in a browser; confirm sidebar 240px, dark theme,
# Phases / Active / Issues / History sections visible, prompt at bottom.
# Ctrl+C to stop.
```

The server will appear to "do nothing" because the WS client lands in Task 5.3.

- [ ] **Step 3: Commit**

```bash
git add tools/guide/public/style.css
git commit -m "guide(web): CSS grid layout, theme variables, sidebar + prompt styling"
```

### Task 5.3: Sidebar render — pure functions (testable)

**Files:**
- Create: `tools/guide/public/app.js`
- Test: `tools/guide/tests/browser/sidebar-render.test.ts`

Strategy: every DOM mutation is a pure function exported from `app.js` so tests run them against `happy-dom`. Tests build the DOM skeleton using `document.createElement` (no `innerHTML`) so XSS-safe by construction.

- [ ] **Step 1: Write a tiny `tests/browser/dom-skeleton.ts` helper**

```ts
// Builds the test-fixture DOM equivalent to what index.html provides.
import type { Window } from 'happy-dom'

export function mountSkeleton(win: Window): void {
  const d = win.document
  const append = (parent: Element, tag: string, opts: { id?: string } = {}): Element => {
    const el = d.createElement(tag)
    if (opts.id) el.id = opts.id
    parent.appendChild(el)
    return el
  }
  // Empty body first
  while (d.body.firstChild) d.body.removeChild(d.body.firstChild)
  append(d.body, 'ul',   { id: 'phases' })
  const active = append(d.body, 'div', { id: 'active' })
  active.textContent = 'Waiting…'
  append(d.body, 'ol',   { id: 'issues' })
  append(d.body, 'span', { id: 'issues-count' })
}
```

- [ ] **Step 2: Write failing test**

`tools/guide/tests/browser/sidebar-render.test.ts`:

```ts
import { describe, expect, test, beforeEach } from 'bun:test'
import { Window } from 'happy-dom'
import { mountSkeleton } from './dom-skeleton.ts'

let window: Window

beforeEach(() => {
  window = new Window()
  ;(globalThis as any).document = window.document
  ;(globalThis as any).window   = window
  mountSkeleton(window)
})

describe('sidebar render', () => {
  test('renderPhases adds li for each phase with status class', async () => {
    const { renderPhases } = await import('../../public/app.js')
    renderPhases([
      { name: 'A', status: 'ok' },
      { name: 'B', status: 'running' },
      { name: 'C', status: 'pending' },
    ])
    const lis = window.document.querySelectorAll('#phases li')
    expect(lis).toHaveLength(3)
    expect(lis[0]!.textContent).toContain('A')
    expect(lis[0]!.classList.contains('ok')).toBe(true)
    expect(lis[1]!.classList.contains('running')).toBe(true)
    expect(lis[2]!.classList.contains('pending')).toBe(true)
  })

  test('renderActive shows phase + item', async () => {
    const { renderActive } = await import('../../public/app.js')
    renderActive({ phaseName: 'P', itemLabel: 'item-1' })
    expect(window.document.getElementById('active')!.textContent).toBe('P → item-1')
  })

  test('renderActive(null) shows Waiting', async () => {
    const { renderActive } = await import('../../public/app.js')
    renderActive(null)
    expect(window.document.getElementById('active')!.textContent).toBe('Waiting…')
  })

  test('renderActive with empty itemLabel shows phase only', async () => {
    const { renderActive } = await import('../../public/app.js')
    renderActive({ phaseName: 'P', itemLabel: '' })
    expect(window.document.getElementById('active')!.textContent).toBe('P')
  })

  test('renderIssues numbers entries with [N] buttons', async () => {
    const { renderIssues } = await import('../../public/app.js')
    renderIssues([
      { message: 'oops 1', fixCommand: 'fix1' },
      { message: 'oops 2', fixCommand: null },
    ])
    const lis = window.document.querySelectorAll('#issues li')
    expect(lis).toHaveLength(2)
    expect(lis[0]!.querySelector('button')!.textContent).toBe('[1]')
    expect(lis[1]!.querySelector('button')!.textContent).toBe('[2]')
    expect(window.document.getElementById('issues-count')!.textContent).toBe('2')
  })

  test('renderIssues with empty list clears the count', async () => {
    const { renderIssues } = await import('../../public/app.js')
    renderIssues([])
    expect(window.document.getElementById('issues-count')!.textContent).toBe('')
  })

  test('issue text is escaped — no innerHTML injection', async () => {
    const { renderIssues } = await import('../../public/app.js')
    renderIssues([{ message: '<script>alert(1)</script>', fixCommand: null }])
    const li = window.document.querySelector('#issues li')!
    // textContent contains the literal string; no <script> element exists
    expect(li.textContent).toContain('<script>')
    expect(li.querySelector('script')).toBeNull()
  })
})
```

- [ ] **Step 3: Run to confirm failure**

```bash
bun test tests/browser/sidebar-render.test.ts
```

Expected: FAIL — `app.js` not found.

- [ ] **Step 4: Implement `public/app.js` (pure render functions)**

All DOM mutations use `document.createElement` + `textContent` — never `innerHTML`. Clearing children uses a `removeChild` loop.

```js
// tools/guide/public/app.js
const $ = (sel) => document.querySelector(sel)

function clearChildren(el) {
  while (el.firstChild) el.removeChild(el.firstChild)
}

const PHASE_GLYPH = {
  pending: '○', running: '◐', ok: '✓', warn: '⚠', fail: '✗',
}

export function renderPhases(phases) {
  const ul = $('#phases')
  clearChildren(ul)
  for (const p of phases) {
    const li = document.createElement('li')
    li.className = p.status
    li.textContent = `${PHASE_GLYPH[p.status] ?? '·'} ${p.name}`
    ul.appendChild(li)
  }
}

export function renderActive(active) {
  const el = $('#active')
  if (!active) { el.textContent = 'Waiting…'; return }
  el.textContent = active.itemLabel
    ? `${active.phaseName} → ${active.itemLabel}`
    : (active.phaseName || 'Waiting…')
}

export function renderIssues(issues) {
  const ol    = $('#issues')
  const count = $('#issues-count')
  clearChildren(ol)
  for (let i = 0; i < issues.length; i++) {
    const iss = issues[i]
    const li = document.createElement('li')
    const btn = document.createElement('button')
    btn.textContent = `[${i + 1}]`
    btn.dataset.fix = iss.fixCommand ?? ''
    li.appendChild(btn)
    const span = document.createElement('span')
    span.textContent = iss.message       // textContent escapes by spec
    li.appendChild(span)
    ol.appendChild(li)
  }
  count.textContent = issues.length === 0 ? '' : String(issues.length)
}

export function applySnapshot(plan) {
  if (!plan) return
  renderPhases(plan.phases ?? [])
  renderActive(plan.active ?? null)
  renderIssues(plan.issues ?? [])
}

let ws = null

export function connectWebSocket() {
  if (ws) return
  ws = new WebSocket(`ws://${location.host}/ws`)
  ws.addEventListener('message', e => {
    let msg
    try { msg = JSON.parse(e.data) } catch { return }
    switch (msg.type) {
      case 'server-info':    /* Phase 8 reads defaultShell */ break
      case 'plan-snapshot':  applySnapshot(msg.plan); break
      case 'plan-update':    applyPlanUpdate(msg.payload); break
    }
  })
  ws.addEventListener('close', () => {
    setTimeout(() => { ws = null; connectWebSocket() }, 1000)
  })
}

function applyPlanUpdate(ev) {
  const plan = window.__guidePlan ?? (window.__guidePlan = { phases: [], active: null, issues: [] })
  switch (ev.type) {
    case 'plan-started':
      window.__guidePlan = {
        phases: ev.phases.map(p => ({ name: p.name, status: 'pending' })),
        active: null, issues: [],
      }
      applySnapshot(window.__guidePlan)
      break
    case 'phase-started': {
      const p = plan.phases.find(p => p.name === ev.phaseName)
      if (p) p.status = 'running'
      plan.active = { phaseName: ev.phaseName, itemLabel: '' }
      renderPhases(plan.phases); renderActive(plan.active)
      break
    }
    case 'active-changed':
      plan.active = { phaseName: plan.active?.phaseName ?? '', itemLabel: ev.label }
      renderActive(plan.active)
      break
    case 'phase-completed': {
      const p = plan.phases.find(p => p.name === ev.phaseName)
      if (p) p.status = ev.status
      renderPhases(plan.phases)
      break
    }
    case 'phase-result':
      if (!ev.success && ev.severity !== 'warn') {
        plan.issues.push({ message: ev.message, fixCommand: ev.fixCommand })
        renderIssues(plan.issues)
      }
      break
    case 'issue-emitted':
      plan.issues.push({ message: ev.message, fixCommand: ev.fixCommand })
      renderIssues(plan.issues)
      break
    case 'plan-completed':
      plan.active = null
      renderActive(null)
      break
  }
}

if (typeof document !== 'undefined' && typeof location !== 'undefined') {
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', connectWebSocket)
  } else {
    connectWebSocket()
  }
}
```

- [ ] **Step 5: Run tests**

```bash
bun test tests/browser/sidebar-render.test.ts
```

Expected: 7 pass, 0 fail.

- [ ] **Step 6: Commit**

```bash
git add tools/guide/public/app.js \
        tools/guide/tests/browser/dom-skeleton.ts \
        tools/guide/tests/browser/sidebar-render.test.ts
git commit -m "guide(web): app.js render fns (XSS-safe via textContent) + happy-dom tests"
```

### Task 5.4: WS-client unit tests (mock WebSocket)

**Files:**
- Test: `tools/guide/tests/browser/ws-client.test.ts`

- [ ] **Step 1: Write the test**

```ts
import { describe, expect, test, beforeEach } from 'bun:test'
import { Window } from 'happy-dom'
import { mountSkeleton } from './dom-skeleton.ts'

let window: Window
let mockMessages: ((data: string) => void)[] = []

beforeEach(() => {
  window = new Window()
  ;(globalThis as any).document = window.document
  ;(globalThis as any).window   = window
  ;(globalThis as any).location = { host: '127.0.0.1:1' }
  mountSkeleton(window)

  mockMessages = []
  ;(globalThis as any).WebSocket = class {
    addEventListener(name: string, cb: any) {
      if (name === 'message') mockMessages.push((data) => cb({ data }))
    }
  } as any
})

describe('WS client message dispatch', () => {
  test('plan-snapshot triggers full sidebar render', async () => {
    const mod = await import('../../public/app.js')
    mod.connectWebSocket()
    mockMessages[0]!(JSON.stringify({
      type: 'plan-snapshot',
      plan: {
        phases: [{ name: 'A', status: 'ok' }],
        active: { phaseName: 'A', itemLabel: 'x' },
        issues: [{ message: 'm', fixCommand: 'f' }],
      },
    }))
    expect(window.document.querySelectorAll('#phases li')).toHaveLength(1)
    expect(window.document.getElementById('active')!.textContent).toBe('A → x')
    expect(window.document.querySelectorAll('#issues li')).toHaveLength(1)
  })

  test('plan-update phase-started flips status to running', async () => {
    const mod = await import('../../public/app.js')
    mod.connectWebSocket()
    mockMessages[0]!(JSON.stringify({
      type: 'plan-update',
      payload: { type: 'plan-started', planId: 'p', title: 'T', subtitle: '',
                 phases: [{ name: 'A' }, { name: 'B' }] },
    }))
    mockMessages[0]!(JSON.stringify({
      type: 'plan-update',
      payload: { type: 'phase-started', planId: 'p', phaseName: 'A', phaseIndex: 1, phaseTotal: 2 },
    }))
    const lis = window.document.querySelectorAll('#phases li')
    expect(lis[0]!.classList.contains('running')).toBe(true)
  })
})
```

- [ ] **Step 2: Run tests**

```bash
bun test tests/browser/ws-client.test.ts
```

Expected: 2 pass.

- [ ] **Step 3: Run all browser tests**

```bash
bun test tests/browser
```

Expected: sidebar-render (7) + ws-client (2) = 9 pass.

- [ ] **Step 4: Commit**

```bash
git add tools/guide/tests/browser/ws-client.test.ts
git commit -m "guide(web): WS dispatch tests with mock WebSocket"
```

### Task 5.5: Click-to-copy fix command

**Files:**
- Modify: `tools/guide/public/app.js`
- Modify: `tools/guide/tests/browser/sidebar-render.test.ts`

- [ ] **Step 1: Append failing test**

```ts
test('clicking [N] button copies fixCommand', async () => {
  const mod = await import('../../public/app.js')
  mod.renderIssues([{ message: 'm', fixCommand: 'fix-1' }])
  let copied = ''
  ;(globalThis as any).navigator = { clipboard: { writeText: async (s: string) => { copied = s } } }
  mod.wireIssueClickHandlers()
  const btn = window.document.querySelector('#issues button')! as any
  btn.click()
  await new Promise(r => setTimeout(r, 10))
  expect(copied).toBe('fix-1')
})
```

- [ ] **Step 2: Run to confirm failure**

```bash
bun test tests/browser/sidebar-render.test.ts
```

Expected: FAIL — `wireIssueClickHandlers` not exported.

- [ ] **Step 3: Implement `wireIssueClickHandlers` and `showToast`**

Append to `public/app.js`:

```js
export function wireIssueClickHandlers() {
  const ol = $('#issues')
  if (!ol) return
  ol.addEventListener('click', async (e) => {
    const btn = e.target.closest && e.target.closest('button[data-fix]')
    if (!btn) return
    const fix = btn.dataset.fix
    if (!fix) { showToast('No command'); return }
    try { await navigator.clipboard.writeText(fix); showToast('Copied') }
    catch { showToast('Copy failed') }
  })
}

function showToast(text) {
  const el = document.createElement('div')
  el.className = 'toast'
  el.textContent = text
  document.body.appendChild(el)
  requestAnimationFrame(() => el.classList.add('show'))
  setTimeout(() => {
    el.classList.remove('show')
    setTimeout(() => el.remove(), 200)
  }, 1200)
}
```

In the bottom auto-bootstrap block of `app.js`, also call `wireIssueClickHandlers()`:

```js
if (typeof document !== 'undefined' && typeof location !== 'undefined') {
  const init = () => { wireIssueClickHandlers(); connectWebSocket() }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init)
  else init()
}
```

- [ ] **Step 4: Run tests**

```bash
bun test tests/browser/sidebar-render.test.ts
```

Expected: 8 pass.

- [ ] **Step 5: Commit**

```bash
git add tools/guide/public/app.js tools/guide/tests/browser/sidebar-render.test.ts
git commit -m "guide(web): click [N] copies fixCommand via navigator.clipboard + toast"
```

---

## Phase 6: PTY manager + xterm.js wiring

Spawns `pwsh` and `bash` lazily via a `spawnPty()` interface. v1 uses `Bun.spawn` with stdio pipes — non-TTY output, but ANSI escapes still pass through to xterm.js. Real `node-pty` integration is a follow-up; the interface is designed so the binding can be swapped without touching call sites.

### Task 6.1: `spawnPty()` interface + `Bun.spawn` implementation

**Files:**
- Create: `tools/guide/lib/pty.ts`
- Test: `tools/guide/tests/server/pty.test.ts`

- [ ] **Step 1: Write failing test**

```ts
import { describe, expect, test } from 'bun:test'
import { spawnPty, type Pty } from '../../lib/pty.ts'

const isWin = process.platform === 'win32'
const echoArgs = isWin
  ? ['pwsh', '-NoProfile', '-NoLogo', '-Command', 'Write-Host hello-pty']
  : ['bash', '-c', 'echo hello-pty']

describe('spawnPty', () => {
  test('captures stdout via onData', async () => {
    let collected = ''
    const pty = await spawnPty(echoArgs, { cwd: process.cwd() })
    pty.onData(chunk => { collected += chunk })
    const exitCode = await pty.exited
    expect(exitCode).toBe(0)
    expect(collected).toContain('hello-pty')
  })

  test('write sends to stdin', async () => {
    const args = isWin
      ? ['pwsh', '-NoProfile', '-NoLogo', '-Command', '$line = [Console]::In.ReadLine(); Write-Host "got:$line"']
      : ['bash', '-c', 'read line; echo "got:$line"']
    let out = ''
    const pty = await spawnPty(args, { cwd: process.cwd() })
    pty.onData(c => { out += c })
    pty.write('xyz\n')
    const code = await pty.exited
    expect(code).toBe(0)
    expect(out).toContain('got:xyz')
  })

  test('kill terminates the process', async () => {
    const args = isWin
      ? ['pwsh', '-NoProfile', '-NoLogo', '-Command', 'Start-Sleep -Seconds 30']
      : ['bash', '-c', 'sleep 30']
    const pty = await spawnPty(args, { cwd: process.cwd() })
    setTimeout(() => pty.kill('SIGTERM'), 50)
    const code = await pty.exited
    expect(code).not.toBe(0) // killed processes exit nonzero
  })
})
```

- [ ] **Step 2: Run to confirm failure**

```bash
bun test tests/server/pty.test.ts
```

Expected: FAIL — `spawnPty` not exported.

- [ ] **Step 3: Implement `lib/pty.ts`**

```ts
// tools/guide/lib/pty.ts
//
// Pseudo-terminal abstraction. v1 implementation uses Bun.spawn + pipes.
// node-pty / bun-pty can be swapped in later by replacing this module's
// internals; the public Pty interface stays stable.

export type SpawnOpts = {
  cwd?: string
  env?: Record<string, string>
  cols?: number
  rows?: number
}

export type Pty = {
  pid: number
  write(data: string): void
  resize(cols: number, rows: number): void
  kill(signal: 'SIGINT' | 'SIGTERM' | 'SIGKILL'): void
  onData(cb: (chunk: string) => void): void
  onExit(cb: (code: number | null) => void): void
  exited: Promise<number | null>
}

export async function spawnPty(argv: string[], opts: SpawnOpts = {}): Promise<Pty> {
  const env = { ...process.env, ...opts.env, FORCE_COLOR: '1', TERM: 'xterm-256color' }
  // Strip GUIDE_* env so server internals don't leak into the shell
  for (const k of Object.keys(env)) if (k.startsWith('GUIDE_')) delete env[k]

  const proc = Bun.spawn({
    cmd: argv,
    cwd: opts.cwd,
    env,
    stdin: 'pipe',
    stdout: 'pipe',
    stderr: 'pipe',
  })

  const dataCbs = new Set<(c: string) => void>()
  const exitCbs = new Set<(code: number | null) => void>()
  const decoder = new TextDecoder()

  const drain = async (stream: ReadableStream<Uint8Array> | null) => {
    if (!stream) return
    const reader = stream.getReader()
    while (true) {
      const { done, value } = await reader.read()
      if (done) return
      const text = decoder.decode(value, { stream: true })
      for (const cb of dataCbs) {
        try { cb(text) } catch { /* listener errors are not fatal */ }
      }
    }
  }
  drain(proc.stdout)
  drain(proc.stderr)

  const exitPromise = proc.exited.then(code => {
    for (const cb of exitCbs) {
      try { cb(code ?? null) } catch {}
    }
    return code ?? null
  })

  return {
    pid: proc.pid,
    write(data) {
      // Bun.spawn returns a writer for stdin
      const w = proc.stdin
      if (!w) return
      try { w.write(data); w.flush?.() } catch {}
    },
    resize(_cols, _rows) {
      // No-op in pipe-mode; real PTY backend will plumb winsize through.
    },
    kill(signal) {
      try { proc.kill(signal as any) } catch {}
    },
    onData(cb) { dataCbs.add(cb) },
    onExit(cb) { exitCbs.add(cb) },
    exited: exitPromise,
  }
}
```

- [ ] **Step 4: Run tests**

```bash
bun test tests/server/pty.test.ts
```

Expected: 3 pass.

- [ ] **Step 5: Commit**

```bash
git add tools/guide/lib/pty.ts tools/guide/tests/server/pty.test.ts
git commit -m "guide(server): spawnPty wrapper over Bun.spawn (PTY-shaped pipes for v1)"
```

### Task 6.2: PtyManager — lazy spawn + signal + kind tracking

**Files:**
- Modify: `tools/guide/lib/pty.ts`
- Modify: `tools/guide/tests/server/pty.test.ts`

- [ ] **Step 1: Append failing test**

```ts
import { PtyManager } from '../../lib/pty.ts'

describe('PtyManager', () => {
  test('ensure spawns once per kind', async () => {
    const m = new PtyManager()
    const a = await m.ensure(isWin ? 'pwsh' : 'bash')
    const b = await m.ensure(isWin ? 'pwsh' : 'bash')
    expect(a.pid).toBe(b.pid)
    m.killAll('SIGTERM')
    await Promise.all([a.exited, b.exited])
  })

  test('spawns separate kinds independently', async () => {
    if (isWin) return // bash unavailable on minimal Windows CI
    const m = new PtyManager()
    const bash = await m.ensure('bash')
    const pwsh = await m.ensureOrError('pwsh').catch(() => null)
    expect(bash.pid).toBeGreaterThan(0)
    m.killAll('SIGTERM')
    await bash.exited
    if (pwsh) await pwsh.exited
  })

  test('write routes to the right shell', async () => {
    const m = new PtyManager()
    const kind = isWin ? 'pwsh' : 'bash'
    const pty = await m.ensure(kind)
    let out = ''
    pty.onData(c => out += c)
    m.write(kind, isWin ? 'Write-Host hi-from-pwsh' : 'echo hi-from-bash')
    // Give the shell a beat to process
    await new Promise(r => setTimeout(r, 200))
    m.killAll('SIGTERM')
    await pty.exited
    expect(out).toContain(isWin ? 'hi-from-pwsh' : 'hi-from-bash')
  })
})
```

- [ ] **Step 2: Run to confirm failure**

```bash
bun test tests/server/pty.test.ts
```

Expected: FAIL — `PtyManager` not exported.

- [ ] **Step 3: Implement `PtyManager`**

Append to `lib/pty.ts`:

```ts
export type ShellKind = 'pwsh' | 'bash'

function detectShellArgv(kind: ShellKind): string[] {
  if (kind === 'pwsh') return ['pwsh', '-NoProfile', '-NoLogo']
  return [bashPath(), '--login']
}

export function bashPath(): string {
  if (process.env.GIT_BASH_PATH) return process.env.GIT_BASH_PATH
  if (process.platform === 'win32') {
    const candidates = [
      'C:\\Program Files\\Git\\bin\\bash.exe',
      'C:\\Program Files (x86)\\Git\\bin\\bash.exe',
    ]
    for (const c of candidates) {
      try {
        if (require('node:fs').existsSync(c)) return c
      } catch {}
    }
    return 'bash'
  }
  return 'bash'
}

export class PtyManager {
  private shells = new Map<ShellKind, Pty>()
  private cwd: string
  constructor(cwd: string = process.cwd()) { this.cwd = cwd }

  async ensure(kind: ShellKind): Promise<Pty> {
    const existing = this.shells.get(kind)
    if (existing) return existing
    const pty = await spawnPty(detectShellArgv(kind), { cwd: this.cwd })
    pty.onExit(() => { this.shells.delete(kind) })
    this.shells.set(kind, pty)
    return pty
  }

  // Same as ensure but rethrows on spawn failure (for tests that want to assert).
  async ensureOrError(kind: ShellKind): Promise<Pty> { return this.ensure(kind) }

  has(kind: ShellKind): boolean { return this.shells.has(kind) }
  get(kind: ShellKind): Pty | undefined { return this.shells.get(kind) }

  write(kind: ShellKind, text: string): void {
    this.ensure(kind).then(pty => pty.write(text + (text.endsWith('\n') ? '' : '\n')))
  }

  signal(kind: ShellKind, signal: 'SIGINT' | 'SIGTERM' | 'SIGKILL'): void {
    this.shells.get(kind)?.kill(signal)
  }

  resize(kind: ShellKind, cols: number, rows: number): void {
    this.shells.get(kind)?.resize(cols, rows)
  }

  killAll(signal: 'SIGINT' | 'SIGTERM' | 'SIGKILL' = 'SIGTERM'): void {
    for (const [, pty] of this.shells) pty.kill(signal)
  }
}
```

- [ ] **Step 4: Run tests**

```bash
bun test tests/server/pty.test.ts
```

Expected: 6 pass (3 from Task 6.1 + 3 new), 0 fail.

- [ ] **Step 5: Commit**

```bash
git add tools/guide/lib/pty.ts tools/guide/tests/server/pty.test.ts
git commit -m "guide(server): PtyManager with lazy spawn + kill + write routing"
```

### Task 6.3: Wire shell WS messages into `server.ts`

**Files:**
- Modify: `tools/guide/server.ts`
- Test: `tools/guide/tests/server/ws.test.ts` (append shell-roundtrip)

- [ ] **Step 1: Append failing shell-roundtrip test**

```ts
describe('shell roundtrip via WS', () => {
  test('shell-line writes to PTY and shell-output broadcasts back', async () => {
    const ws = await connectWs(server.httpPort)
    await new Promise(r => ws.addEventListener('message', r, { once: true })) // server-info

    const isWin = process.platform === 'win32'
    const kind  = isWin ? 'pwsh' : 'bash'
    const text  = isWin ? 'Write-Host hello-from-shell' : 'echo hello-from-shell'

    // Collect shell-output messages
    const collected: string[] = []
    ws.addEventListener('message', e => {
      const msg = JSON.parse(e.data)
      if (msg.type === 'shell-output') collected.push(msg.data)
    })

    ws.send(JSON.stringify({ type: 'shell-line', shell: kind, text }))

    // Wait up to 3s for output
    const deadline = Date.now() + 3000
    while (Date.now() < deadline && !collected.join('').includes('hello-from-shell')) {
      await new Promise(r => setTimeout(r, 50))
    }

    expect(collected.join('')).toContain('hello-from-shell')
    ws.send(JSON.stringify({ type: 'shell-signal', shell: kind, signal: 'SIGTERM' }))
    ws.close()
  })
})
```

- [ ] **Step 2: Run to confirm failure**

```bash
bun test tests/server/ws.test.ts
```

Expected: FAIL — server doesn't dispatch `shell-line` yet.

- [ ] **Step 3: Wire WS message dispatch in `server.ts`**

In `server.ts`, add a `PtyManager` instance and handle WS messages. The full updated section:

```ts
// Add to imports:
import { PtyManager, type ShellKind } from './lib/pty.ts'

// Inside startServer(), alongside store and broker:
const ptyMgr = new PtyManager(opts.workspace ?? process.cwd())

// Replace the websocket.message handler with:
websocket: {
  open(ws) {
    broker.add(ws)
    ws.send(JSON.stringify({ type:'server-info', mode, defaultShell, port: httpPort } satisfies WsMsg))
    const recent = store.mostRecent()
    if (recent) ws.send(JSON.stringify({ type:'plan-snapshot', plan: recent } satisfies WsMsg))
  },

  async message(ws, raw) {
    let msg: any
    try { msg = JSON.parse(typeof raw === 'string' ? raw : new TextDecoder().decode(raw)) } catch { return }
    if (!msg || typeof msg.type !== 'string') return

    switch (msg.type) {
      case 'shell-line': {
        const kind = msg.shell as ShellKind
        if (kind !== 'pwsh' && kind !== 'bash') return
        try {
          const pty = await ptyMgr.ensure(kind)
          if (!ptyMgr.has(kind) || pty.pid === 0) {
            broker.broadcast({ type:'shell-spawned-error', shell: kind, error: 'spawn failed' })
            return
          }
          // Forward output if not already wired
          if (!pty._wired) {
            pty._wired = true
            pty.onData(text => broker.broadcast({ type:'shell-output', shell: kind, data: text }))
            pty.onExit(code => broker.broadcast({ type:'shell-exit', shell: kind, code }))
            broker.broadcast({ type:'shell-spawned', shell: kind, cwd: opts.workspace ?? process.cwd(), cols: 100, rows: 30 })
          }
          ptyMgr.write(kind, msg.text ?? '')
        } catch (e) {
          broker.broadcast({ type:'shell-spawned-error', shell: kind, error: String(e) })
        }
        break
      }
      case 'shell-signal': {
        const kind = msg.shell as ShellKind
        if (kind === 'pwsh' || kind === 'bash') ptyMgr.signal(kind, msg.signal ?? 'SIGINT')
        break
      }
      case 'shell-resize': {
        const kind = msg.shell as ShellKind
        if (kind === 'pwsh' || kind === 'bash') ptyMgr.resize(kind, Number(msg.cols) || 100, Number(msg.rows) || 30)
        break
      }
      case 'shell-spawn': {
        const kind = msg.shell as ShellKind
        if (kind === 'pwsh' || kind === 'bash') await ptyMgr.ensure(kind)
        break
      }
      case 'quit':
        // Phase 9 implements graceful shutdown; for now ignore.
        break
    }
  },

  close(ws) { broker.remove(ws) },
},
```

The `pty._wired` flag is a transient marker; declare it on the Pty type:

In `lib/pty.ts`, add:

```ts
export type Pty = {
  pid: number
  write(data: string): void
  resize(cols: number, rows: number): void
  kill(signal: 'SIGINT' | 'SIGTERM' | 'SIGKILL'): void
  onData(cb: (chunk: string) => void): void
  onExit(cb: (code: number | null) => void): void
  exited: Promise<number | null>
  _wired?: boolean  // server-internal: marks that broker.broadcast wiring is set
}
```

Also update `stop()` in `server.ts` to kill PTYs:

```ts
stop() {
  try { ptyMgr.killAll('SIGTERM') } catch {}
  try { httpServer.stop(true) } catch {}
  try { tcpServer.stop(true)  } catch {}
  try { db.close() } catch {}
}
```

- [ ] **Step 4: Run tests**

```bash
bun test tests/server/ws.test.ts
```

Expected: 5 pass (server-info + broadcast + tcp-integration + snapshot + new shell-roundtrip).

- [ ] **Step 5: Run all server tests**

```bash
bun test tests/server
```

Expected: db (12) + port (3) + routing (4) + ws (5) + events (5) + state (8) + pty (6) = 43 pass.

- [ ] **Step 6: Commit**

```bash
git add tools/guide/server.ts tools/guide/lib/pty.ts tools/guide/tests/server/ws.test.ts
git commit -m "guide(server): WS shell-line/signal/resize/spawn dispatch with PtyManager"
```

### Task 6.4: Vendor xterm.js into `public/`

**Files:**
- Create: `tools/guide/public/xterm.js`
- Create: `tools/guide/public/xterm.css`
- Create: `tools/guide/public/xterm-addon-fit.js`

xterm.js ships ESM bundles via npm. The plan vendors the prebuilt files instead of pulling them at runtime so the dashboard works offline.

- [ ] **Step 1: Pull xterm.js into the public dir**

```bash
cd tools/guide
mkdir -p .vendor
cd .vendor
bun add @xterm/xterm @xterm/addon-fit
cp node_modules/@xterm/xterm/lib/xterm.js              ../public/xterm.js
cp node_modules/@xterm/xterm/css/xterm.css             ../public/xterm.css
cp node_modules/@xterm/addon-fit/lib/addon-fit.js      ../public/xterm-addon-fit.js
cd ..
rm -rf .vendor
```

The `.vendor/` step keeps these out of the main `package.json` — they're not runtime deps, they're shipped assets.

- [ ] **Step 2: Reference them from `index.html`**

Insert before the `app.js` script:

```html
<link rel="stylesheet" href="/static/xterm.css">
```

(The CSS link goes in `<head>` alongside `style.css`.)

`xterm.js` and `xterm-addon-fit.js` get loaded by `app.js` via `import` — covered in Task 6.5.

- [ ] **Step 3: Smoke check**

```bash
cd tools/guide && bun server.ts
curl -s http://127.0.0.1:7771/static/xterm.js | head -5
# Should print the xterm.js header comment, not "forbidden" or "not found"
```

- [ ] **Step 4: Commit**

```bash
git add tools/guide/public/xterm.js \
        tools/guide/public/xterm.css \
        tools/guide/public/xterm-addon-fit.js \
        tools/guide/public/index.html
git commit -m "guide(web): vendor xterm.js + fit addon as static assets"
```

### Task 6.5: Wire xterm.js + prompt → WS in `app.js`

**Files:**
- Modify: `tools/guide/public/app.js`
- Test: `tools/guide/tests/browser/prefix-routing.test.ts`

- [ ] **Step 1: Write failing prefix-routing test**

```ts
import { describe, expect, test } from 'bun:test'
import { routePrefix } from '../../public/app.js'

describe('routePrefix', () => {
  test('! routes to bash and strips prefix', () => {
    expect(routePrefix('!ls -la', 'pwsh')).toEqual({ shell:'bash', text:'ls -la' })
  })
  test('# routes to pwsh and strips prefix', () => {
    expect(routePrefix('#Get-ChildItem', 'bash')).toEqual({ shell:'pwsh', text:'Get-ChildItem' })
  })
  test('no prefix uses default shell', () => {
    expect(routePrefix('uname', 'bash')).toEqual({ shell:'bash', text:'uname' })
  })
  test('multi-line with leading ! routes whole blob to bash', () => {
    expect(routePrefix('!git add .\ngit commit -m hi\ngit push', 'pwsh'))
      .toEqual({ shell:'bash', text:'git add .\ngit commit -m hi\ngit push' })
  })
  test('whitespace-only is rejected (caller skips)', () => {
    expect(routePrefix('   \n  ', 'bash')).toBeNull()
  })
  test('empty string is rejected', () => {
    expect(routePrefix('', 'bash')).toBeNull()
  })
})
```

- [ ] **Step 2: Run to confirm failure**

```bash
bun test tests/browser/prefix-routing.test.ts
```

Expected: FAIL — `routePrefix` not exported.

- [ ] **Step 3: Implement `routePrefix` and the term wiring**

Append to `public/app.js`:

```js
// ── Prefix routing ──────────────────────────────────────────────────────────

export function routePrefix(text, defaultShell) {
  if (!text || !text.trim()) return null
  if (text.startsWith('!')) return { shell: 'bash', text: text.slice(1) }
  if (text.startsWith('#')) return { shell: 'pwsh', text: text.slice(1) }
  return { shell: defaultShell, text }
}

// ── xterm.js + prompt wiring ────────────────────────────────────────────────

let term = null
let _serverInfo = { defaultShell: 'pwsh', mode: 'plan' }

export async function initTerminal() {
  if (term || typeof window === 'undefined') return
  const { Terminal } = await import('/static/xterm.js')
  const { FitAddon } = await import('/static/xterm-addon-fit.js')
  term = new Terminal({
    fontFamily: getComputedStyle(document.documentElement).getPropertyValue('--font-mono').trim() || 'monospace',
    cursorBlink: false,
    scrollback: 5000,
    theme: {
      background: getComputedStyle(document.documentElement).getPropertyValue('--bg').trim(),
      foreground: getComputedStyle(document.documentElement).getPropertyValue('--fg').trim(),
    },
  })
  const fit = new FitAddon()
  term.loadAddon(fit)
  term.open(document.getElementById('term'))
  fit.fit()
  new ResizeObserver(() => {
    fit.fit()
    if (ws && ws.readyState === 1) {
      ws.send(JSON.stringify({ type:'shell-resize', shell: _serverInfo.defaultShell, cols: term.cols, rows: term.rows }))
    }
  }).observe(document.getElementById('term'))
}

export function termWrite(text) {
  if (term) term.write(text)
}

// ── Prompt wiring ───────────────────────────────────────────────────────────

let _running = false

export function setRunning(running) {
  _running = running
  const status = document.getElementById('status')
  const input  = document.getElementById('input')
  if (!status || !input) return
  if (running) {
    status.classList.add('running')
    status.textContent = 'Running… [Ctrl+C]'
    input.readOnly = true
  } else {
    status.classList.remove('running')
    status.textContent = ''
    input.readOnly = false
  }
}

export function wirePrompt() {
  const input = document.getElementById('input')
  if (!input) return
  input.addEventListener('input', () => {
    // auto-grow up to ~8 rows (max-height capped in CSS)
    input.style.height = 'auto'
    input.style.height = Math.min(input.scrollHeight, 168) + 'px'
  })
  input.addEventListener('keydown', e => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault()
      submitPrompt()
    }
    if (e.key === 'c' && e.ctrlKey && input.value === '' && _running) {
      e.preventDefault()
      if (ws && ws.readyState === 1) {
        ws.send(JSON.stringify({ type:'shell-signal', shell: _serverInfo.defaultShell, signal: 'SIGINT' }))
      }
    }
  })
}

function submitPrompt() {
  if (_running) return
  const input = document.getElementById('input')
  const route = routePrefix(input.value, _serverInfo.defaultShell)
  if (!route) return
  setRunning(true)
  const attribution = `\r\n\x1b[1;33m${route.shell === 'bash' ? 'bash$' : 'pwsh#'}\x1b[0m ${input.value.split('\n')[0]}\r\n`
  termWrite(attribution)
  ws.send(JSON.stringify({ type:'shell-line', shell: route.shell, text: route.text }))
  input.value = ''
  input.style.height = 'auto'
}

// Update message dispatch — replace the existing inner switch in connectWebSocket:
function dispatchMessage(msg) {
  switch (msg.type) {
    case 'server-info':    _serverInfo = msg; break
    case 'plan-snapshot':  applySnapshot(msg.plan); break
    case 'plan-update':    applyPlanUpdate(msg.payload); break
    case 'shell-output':   termWrite(msg.data); break
    case 'shell-exit':
      termWrite(`\r\n\x1b[1;31m[${msg.shell} exited ${msg.code ?? '?'}]\x1b[0m\r\n`)
      setRunning(false)
      break
    case 'shell-spawned-error':
      termWrite(`\r\n\x1b[1;31m[${msg.shell} not available: ${msg.error}]\x1b[0m\r\n`)
      setRunning(false)
      break
  }
}
```

Also replace the body of the existing `connectWebSocket` event listener so it calls `dispatchMessage`:

```js
ws.addEventListener('message', e => {
  let msg
  try { msg = JSON.parse(e.data) } catch { return }
  dispatchMessage(msg)
})
```

And update the bootstrap init block at the bottom:

```js
if (typeof document !== 'undefined' && typeof location !== 'undefined') {
  const init = async () => {
    wireIssueClickHandlers()
    wirePrompt()
    await initTerminal()
    connectWebSocket()
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init)
  else init()
}
```

- [ ] **Step 4: Run tests**

```bash
bun test tests/browser/prefix-routing.test.ts
```

Expected: 6 pass.

- [ ] **Step 5: Run all browser tests**

```bash
bun test tests/browser
```

Expected: prefix-routing (6) + sidebar-render (8) + ws-client (2) = 16 pass.

- [ ] **Step 6: Manual end-to-end smoke**

```bash
cd tools/guide && bun server.ts
# In a browser: visit http://127.0.0.1:7771/
# Type: !echo hello   (Linux/macOS) or  #Write-Host hello   (Windows)
# Press Enter. The shell pane should show:
#   bash$ echo hello
#   hello
# (or pwsh# Write-Host hello / hello)
# Confirm the "Running…" indicator appears briefly then clears.
```

- [ ] **Step 7: Commit**

```bash
git add tools/guide/public/app.js tools/guide/tests/browser/prefix-routing.test.ts
git commit -m "guide(web): xterm.js + prompt + prefix routing + shell roundtrip"
```

### Task 6.6: Multi-line paste textarea behavior

**Files:**
- Modify: `tools/guide/public/app.js`
- Test: `tools/guide/tests/browser/multi-line.test.ts`

- [ ] **Step 1: Write failing test**

```ts
import { describe, expect, test } from 'bun:test'
import { routePrefix } from '../../public/app.js'

describe('multi-line paste routing', () => {
  test('three lines with leading ! all go to bash as one text blob', () => {
    const blob = '!git add foo.txt\ngit commit -m "fix"\ngit push'
    expect(routePrefix(blob, 'pwsh')).toEqual({
      shell: 'bash',
      text:  'git add foo.txt\ngit commit -m "fix"\ngit push',
    })
  })

  test('three lines with leading # all go to pwsh', () => {
    const blob = '#Get-Date\nGet-ChildItem\nGet-Process'
    expect(routePrefix(blob, 'bash')).toEqual({
      shell: 'pwsh',
      text:  'Get-Date\nGet-ChildItem\nGet-Process',
    })
  })

  test('subsequent lines starting with ! or # are literal text in target shell', () => {
    const blob = '!cat <<EOF\n#not a pwsh redirect\n!still bash\nEOF'
    expect(routePrefix(blob, 'pwsh')).toEqual({
      shell: 'bash',
      text:  'cat <<EOF\n#not a pwsh redirect\n!still bash\nEOF',
    })
  })

  test('blob with no leading prefix uses defaultShell', () => {
    const blob = 'echo a\necho b\necho c'
    expect(routePrefix(blob, 'bash')).toEqual({
      shell: 'bash',
      text:  'echo a\necho b\necho c',
    })
  })
})
```

- [ ] **Step 2: Run tests**

```bash
bun test tests/browser/multi-line.test.ts
```

Expected: 4 pass — `routePrefix` already supports this from Task 6.5.

- [ ] **Step 3: Manual smoke (optional)**

In the browser, paste a multi-line script into the prompt. Confirm Enter submits it as one command and the shell parses the newlines (e.g., a 3-line `!ls\necho hi\npwd` runs all three).

- [ ] **Step 4: Commit**

```bash
git add tools/guide/tests/browser/multi-line.test.ts
git commit -m "guide(web): multi-line paste routing tests covering heredocs + literal prefix lines"
```

---

## Phase 7: Sentinel injection + history persistence

Each `shell-line` gets a randomized sentinel appended to detect command completion. On detection, the history row's `exit_code` and `duration_ms` are filled in, and the sentinel echo is stripped from xterm output.

### Task 7.1: Sentinel utility (`lib/sentinel.ts`)

**Files:**
- Create: `tools/guide/lib/sentinel.ts`
- Test: `tools/guide/tests/server/sentinel.test.ts`

- [ ] **Step 1: Write failing test**

```ts
import { describe, expect, test } from 'bun:test'
import { newSentinelId, wrapForShell, sentinelMatcher } from '../../lib/sentinel.ts'

describe('sentinel', () => {
  test('newSentinelId is 8 hex chars', () => {
    const id = newSentinelId()
    expect(id).toMatch(/^[0-9a-f]{8}$/)
  })

  test('wrapForShell appends bash echo', () => {
    const wrapped = wrapForShell('bash', 'ls -la', 'abcd1234')
    expect(wrapped).toBe('ls -la\necho __GUIDE_DONE_abcd1234__:$?\n')
  })

  test('wrapForShell appends pwsh marker with $LASTEXITCODE', () => {
    const wrapped = wrapForShell('pwsh', 'Get-Date', 'abcd1234')
    expect(wrapped).toBe('Get-Date\nWrite-Host "__GUIDE_DONE_abcd1234__:$LASTEXITCODE"\n')
  })

  test('sentinelMatcher detects completion + extracts exit code', () => {
    const m = sentinelMatcher('abcd1234')
    expect(m.scan('some output\n')).toBeNull()
    const result = m.scan('more\n__GUIDE_DONE_abcd1234__:0\n')
    expect(result).toEqual({ exitCode: 0, before: 'more\n' })
  })

  test('sentinelMatcher handles split frames', () => {
    const m = sentinelMatcher('abcd1234')
    expect(m.scan('partial __GUIDE_DONE_abcd')).toBeNull()
    const r = m.scan('1234__:42\n')
    expect(r).toEqual({ exitCode: 42, before: 'partial ' })
  })

  test('sentinelMatcher handles non-zero exit codes', () => {
    const m = sentinelMatcher('aaaa1111')
    const r = m.scan('__GUIDE_DONE_aaaa1111__:137\nignored\n')
    expect(r).toEqual({ exitCode: 137, before: '' })
  })
})
```

- [ ] **Step 2: Run to confirm failure**

```bash
bun test tests/server/sentinel.test.ts
```

Expected: FAIL — `lib/sentinel.ts` not found.

- [ ] **Step 3: Implement `lib/sentinel.ts`**

```ts
// tools/guide/lib/sentinel.ts
import { randomBytes } from 'node:crypto'
import type { ShellKind } from './pty.ts'

export function newSentinelId(): string {
  return randomBytes(4).toString('hex')
}

export function wrapForShell(shell: ShellKind, userText: string, sentinelId: string): string {
  // Ensure user text ends with newline so the appended marker isn't on the same line.
  const text = userText.endsWith('\n') ? userText : userText + '\n'
  if (shell === 'bash') {
    return `${text}echo __GUIDE_DONE_${sentinelId}__:$?\n`
  }
  return `${text}Write-Host "__GUIDE_DONE_${sentinelId}__:$LASTEXITCODE"\n`
}

export type SentinelHit = { exitCode: number; before: string }

export type SentinelMatcher = {
  /**
   * Feed a chunk of PTY output. If the sentinel is completed in this chunk,
   * returns { exitCode, before } where `before` is the chunk content prior to
   * the sentinel start (safe to forward to xterm). Otherwise returns null and
   * caller should forward the chunk minus any partial-match tail.
   */
  scan(chunk: string): SentinelHit | null
  /**
   * Returns text that's safe to forward to xterm given the current buffer state.
   * Useful for callers who want to drain non-sentinel content without waiting
   * for completion. Pair with scan() for the full lifecycle.
   */
  drainSafe(): string
  /** Reset internal buffer (e.g., next command). */
  reset(): void
}

export function sentinelMatcher(id: string): SentinelMatcher {
  const marker = `__GUIDE_DONE_${id}__:`
  let buf = ''
  return {
    scan(chunk) {
      buf += chunk
      const idx = buf.indexOf(marker)
      if (idx < 0) return null
      const after = buf.slice(idx + marker.length)
      const nl = after.indexOf('\n')
      if (nl < 0) return null // exit-code line not yet complete
      const exitStr = after.slice(0, nl).trim()
      const exitCode = Number.parseInt(exitStr, 10)
      if (Number.isNaN(exitCode)) return null
      const before = buf.slice(0, idx)
      buf = ''
      return { exitCode, before }
    },
    drainSafe() {
      const idx = buf.indexOf(marker)
      if (idx >= 0) {
        // Hold everything from marker onward until we know the full line.
        const out = buf.slice(0, idx)
        buf = buf.slice(idx)
        return out
      }
      // Hold a trailing partial-match window to avoid splitting the marker mid-chunk.
      const tailLen = Math.min(marker.length - 1, buf.length)
      const out = buf.slice(0, buf.length - tailLen)
      buf = buf.slice(buf.length - tailLen)
      return out
    },
    reset() { buf = '' },
  }
}
```

- [ ] **Step 4: Run tests**

```bash
bun test tests/server/sentinel.test.ts
```

Expected: 6 pass.

- [ ] **Step 5: Commit**

```bash
git add tools/guide/lib/sentinel.ts tools/guide/tests/server/sentinel.test.ts
git commit -m "guide(server): sentinel id/wrap/matcher with split-frame support"
```

### Task 7.2: Wire sentinel + history into server's `shell-line` handler

**Files:**
- Modify: `tools/guide/server.ts`
- Modify: `tools/guide/tests/server/ws.test.ts`

- [ ] **Step 1: Append failing test**

```ts
describe('history persistence', () => {
  test('shell-line records history with exit_code after sentinel hit', async () => {
    const ws = await connectWs(server.httpPort)
    await new Promise(r => ws.addEventListener('message', r, { once: true })) // server-info

    const isWin = process.platform === 'win32'
    const kind = isWin ? 'pwsh' : 'bash'
    const text = isWin ? 'Write-Host marker' : 'echo marker'

    ws.send(JSON.stringify({ type:'shell-line', shell: kind, text }))

    // Wait for the sentinel to land, server should have updated DB.
    const deadline = Date.now() + 5000
    let row: any = null
    while (Date.now() < deadline) {
      const r = server.db.query('SELECT * FROM history ORDER BY id DESC LIMIT 1').get() as any
      if (r && r.exit_code !== null) { row = r; break }
      await new Promise(r => setTimeout(r, 50))
    }
    expect(row).not.toBeNull()
    expect(row.text).toBe(text)
    expect(row.shell).toBe(kind)
    expect(row.exit_code).toBe(0)

    ws.send(JSON.stringify({ type:'shell-signal', shell: kind, signal: 'SIGTERM' }))
    ws.close()
  })

  test('xterm output excludes the sentinel echo', async () => {
    const ws = await connectWs(server.httpPort)
    await new Promise(r => ws.addEventListener('message', r, { once: true }))

    const isWin = process.platform === 'win32'
    const kind = isWin ? 'pwsh' : 'bash'
    const text = isWin ? 'Write-Host visible' : 'echo visible'

    let collected = ''
    ws.addEventListener('message', e => {
      const msg = JSON.parse(e.data)
      if (msg.type === 'shell-output') collected += msg.data
    })

    ws.send(JSON.stringify({ type:'shell-line', shell: kind, text }))
    const deadline = Date.now() + 5000
    while (Date.now() < deadline && !collected.includes('visible')) {
      await new Promise(r => setTimeout(r, 50))
    }

    expect(collected).toContain('visible')
    expect(collected).not.toContain('__GUIDE_DONE_')
    ws.send(JSON.stringify({ type:'shell-signal', shell: kind, signal: 'SIGTERM' }))
    ws.close()
  })
})
```

- [ ] **Step 2: Run to confirm failure**

```bash
bun test tests/server/ws.test.ts
```

Expected: FAIL — server doesn't insert into history or strip sentinel.

- [ ] **Step 3: Update `shell-line` handler in `server.ts`**

Replace the `case 'shell-line':` block with the sentinel-aware version. Add helpers at the top-level of `startServer`:

```ts
import { newSentinelId, wrapForShell, sentinelMatcher, type SentinelMatcher } from './lib/sentinel.ts'
import { insertHistory, updateHistoryExit } from './lib/db.ts'

// Inside startServer(), alongside ptyMgr:
type PerShell = {
  matcher: SentinelMatcher | null
  pendingHistoryId: number | null
  startedAt: number
}
const perShell = new Map<ShellKind, PerShell>()

function getPerShell(kind: ShellKind): PerShell {
  let p = perShell.get(kind)
  if (!p) { p = { matcher: null, pendingHistoryId: null, startedAt: 0 }; perShell.set(kind, p) }
  return p
}
```

Update the `shell-line` case:

```ts
case 'shell-line': {
  const kind = msg.shell as ShellKind
  if (kind !== 'pwsh' && kind !== 'bash') return
  try {
    const pty = await ptyMgr.ensure(kind)
    const ps = getPerShell(kind)

    if (!pty._wired) {
      pty._wired = true
      pty.onData(text => {
        const ps2 = getPerShell(kind)
        if (!ps2.matcher) {
          broker.broadcast({ type:'shell-output', shell: kind, data: text })
          return
        }
        const hit = ps2.matcher.scan(text)
        if (hit) {
          const safe = hit.before
          if (safe) broker.broadcast({ type:'shell-output', shell: kind, data: safe })
          if (ps2.pendingHistoryId !== null) {
            const dur = Date.now() - ps2.startedAt
            updateHistoryExit(db, ps2.pendingHistoryId, hit.exitCode, dur)
            broker.broadcast({ type:'history-updated', id: ps2.pendingHistoryId, exit_code: hit.exitCode, duration_ms: dur })
          }
          ps2.matcher = null
          ps2.pendingHistoryId = null
        } else {
          const safe = ps2.matcher.drainSafe()
          if (safe) broker.broadcast({ type:'shell-output', shell: kind, data: safe })
        }
      })
      pty.onExit(code => broker.broadcast({ type:'shell-exit', shell: kind, code }))
      broker.broadcast({ type:'shell-spawned', shell: kind, cwd: opts.workspace ?? process.cwd(), cols: 100, rows: 30 })
    }

    const userText: string = msg.text ?? ''
    if (!userText.trim()) return
    // Privacy: a leading-space command is run but not recorded (bash HISTCONTROL=ignorespace style).
    const skipHistory = userText.startsWith(' ')
    const sentinelId = newSentinelId()
    ps.matcher = sentinelMatcher(sentinelId)
    ps.startedAt = Date.now()
    if (!skipHistory) {
      ps.pendingHistoryId = insertHistory(db, {
        text: userText,
        shell: kind,
        prefix: msg.prefix ?? null,
        workspace: opts.workspace ?? process.cwd(),
        ts: new Date().toISOString(),
      })
      broker.broadcast({
        type:'history-appended',
        entry: { id: ps.pendingHistoryId, text: userText, shell: kind, prefix: msg.prefix ?? null, ts: new Date().toISOString() },
      })
    } else {
      ps.pendingHistoryId = null
    }
    pty.write(wrapForShell(kind, userText, sentinelId))
  } catch (e) {
    broker.broadcast({ type:'shell-spawned-error', shell: kind, error: String(e) })
  }
  break
}
```

Also add `WsMsg` cases for `history-appended` and `history-updated`. Update `lib/ws.ts`:

```ts
| { type: 'history-appended'; entry: { id: number; text: string; shell: 'pwsh' | 'bash'; prefix: string | null; ts: string } }
| { type: 'history-updated'; id: number; exit_code: number | null; duration_ms: number | null }
```

(those were already typed in Task 3.3's `lib/ws.ts` but verify they match the broadcast call shapes)

- [ ] **Step 4: Run tests**

```bash
bun test tests/server/ws.test.ts
```

Expected: 7 pass (5 prior + 2 new history tests).

- [ ] **Step 5: Run all server tests**

```bash
bun test tests/server
```

Expected: db (12) + port (3) + routing (4) + ws (7) + events (5) + state (8) + pty (6) + sentinel (6) = 51 pass.

- [ ] **Step 6: Commit**

```bash
git add tools/guide/server.ts tools/guide/lib/ws.ts tools/guide/tests/server/ws.test.ts
git commit -m "guide(server): sentinel-driven completion + history insert/update + xterm strip"
```

---

## Phase 8: History sidebar UI + filter + recall

The sidebar's History section becomes interactive: list / search / click-recall / delete. SQLite is the source of truth; an in-memory cache mirrors it for ↑/↓ recall in the prompt.

### Task 8.1: WS `history-list`/`history-search` handlers

**Files:**
- Modify: `tools/guide/server.ts`
- Modify: `tools/guide/tests/server/ws.test.ts`

- [ ] **Step 1: Append failing test**

```ts
describe('history queries', () => {
  test('history-list returns recent rows for workspace', async () => {
    // Seed three rows directly in the DB
    const now = (s: number) => new Date(Date.now() - s*1000).toISOString()
    server.db.run("INSERT INTO history(text,shell,prefix,workspace,ts) VALUES ('a','bash',NULL,'/r',?)", [now(3)])
    server.db.run("INSERT INTO history(text,shell,prefix,workspace,ts) VALUES ('b','bash',NULL,'/r',?)", [now(2)])
    server.db.run("INSERT INTO history(text,shell,prefix,workspace,ts) VALUES ('c','bash',NULL,'/r',?)", [now(1)])

    const ws = await connectWs(server.httpPort)
    await new Promise(r => ws.addEventListener('message', r, { once: true }))

    ws.send(JSON.stringify({ type:'history-list', scope:'workspace', limit: 10, workspace: '/r' }))

    const msg = await new Promise<any>(r => {
      ws.addEventListener('message', e => {
        const m = JSON.parse(e.data)
        if (m.type === 'history-page') r(m)
      }, { once: true })
    })
    expect(msg.entries).toHaveLength(3)
    expect(msg.entries[0].text).toBe('c')
    ws.close()
  })

  test('history-search returns FTS hits', async () => {
    server.db.run("INSERT INTO history(text,shell,prefix,workspace,ts) VALUES ('git push','bash',NULL,'/r','2026-04-29T00:00:01Z')")
    server.db.run("INSERT INTO history(text,shell,prefix,workspace,ts) VALUES ('git fetch','bash',NULL,'/r','2026-04-29T00:00:02Z')")
    server.db.run("INSERT INTO history(text,shell,prefix,workspace,ts) VALUES ('ls -la','bash',NULL,'/r','2026-04-29T00:00:03Z')")
    server.db.run("INSERT INTO history_fts(rowid,text) SELECT id, text FROM history WHERE id IN (SELECT id FROM history)")

    const ws = await connectWs(server.httpPort)
    await new Promise(r => ws.addEventListener('message', r, { once: true }))
    ws.send(JSON.stringify({ type:'history-search', query: 'git', limit: 10 }))
    const msg = await new Promise<any>(r => {
      ws.addEventListener('message', e => {
        const m = JSON.parse(e.data)
        if (m.type === 'history-page') r(m)
      }, { once: true })
    })
    expect(msg.entries.map((r: any) => r.text).sort()).toEqual(['git fetch', 'git push'])
    ws.close()
  })
})
```

- [ ] **Step 2: Run to confirm failure**

```bash
bun test tests/server/ws.test.ts
```

Expected: FAIL — server doesn't dispatch `history-list`/`history-search`.

- [ ] **Step 3: Add WS dispatch cases in `server.ts`**

```ts
import { listHistory, searchHistory, deleteHistory } from './lib/db.ts'

// Add cases to the message switch:
case 'history-list': {
  const limit = Math.min(Number(msg.limit) || 100, 500)
  const before = typeof msg.before === 'string' ? msg.before : undefined
  const workspace = msg.scope === 'all' ? undefined : (typeof msg.workspace === 'string' ? msg.workspace : (opts.workspace ?? process.cwd()))
  const entries = listHistory(db, { workspace, limit, before })
  ws.send(JSON.stringify({ type:'history-page', entries, hasMore: entries.length === limit } satisfies WsMsg))
  break
}
case 'history-search': {
  const limit = Math.min(Number(msg.limit) || 50, 200)
  const query = String(msg.query ?? '')
  if (!query) {
    ws.send(JSON.stringify({ type:'history-page', entries: [], hasMore: false } satisfies WsMsg))
    break
  }
  let entries: unknown[] = []
  try { entries = searchHistory(db, query, limit) } catch { /* invalid FTS query */ }
  ws.send(JSON.stringify({ type:'history-page', entries, hasMore: false } satisfies WsMsg))
  break
}
case 'history-delete': {
  const id = Number(msg.id)
  if (Number.isFinite(id)) deleteHistory(db, id)
  break
}
```

- [ ] **Step 4: Run tests**

```bash
bun test tests/server/ws.test.ts
```

Expected: 9 pass.

- [ ] **Step 5: Commit**

```bash
git add tools/guide/server.ts tools/guide/tests/server/ws.test.ts
git commit -m "guide(server): history-list/search/delete WS dispatch"
```

### Task 8.2: History store in `app.js`

**Files:**
- Modify: `tools/guide/public/app.js`
- Test: `tools/guide/tests/browser/history-store.test.ts`

- [ ] **Step 1: Write failing test**

```ts
import { describe, expect, test, beforeEach } from 'bun:test'

beforeEach(async () => {
  // Reset module registry so each test gets fresh module-level state
  delete (globalThis as any).window
  delete (globalThis as any).document
})

describe('history in-memory cache', () => {
  test('insertEntry adds to head; cap at 500', async () => {
    const { __resetHistory, insertEntry, getCache } = await import('../../public/app.js')
    __resetHistory()
    for (let i = 0; i < 502; i++) insertEntry({ id: i, text: 't' + i, shell: 'bash', prefix: null, ts: 'x' })
    const cache = getCache()
    expect(cache).toHaveLength(500)
    expect(cache[0]!.text).toBe('t501')
    expect(cache[499]!.text).toBe('t2')
  })

  test('insertEntry dedupes by text and moves match to head', async () => {
    const { __resetHistory, insertEntry, getCache } = await import('../../public/app.js')
    __resetHistory()
    insertEntry({ id: 1, text: 'a', shell: 'bash', prefix: null, ts: '' })
    insertEntry({ id: 2, text: 'b', shell: 'bash', prefix: null, ts: '' })
    insertEntry({ id: 3, text: 'a', shell: 'bash', prefix: null, ts: '' })
    expect(getCache().map(e => e.text)).toEqual(['a', 'b'])
  })

  test('recallStep walks history with up/down', async () => {
    const { __resetHistory, insertEntry, recallStep } = await import('../../public/app.js')
    __resetHistory()
    insertEntry({ id: 1, text: 'first',  shell: 'bash', prefix: null, ts: '' })
    insertEntry({ id: 2, text: 'second', shell: 'bash', prefix: null, ts: '' })
    insertEntry({ id: 3, text: 'third',  shell: 'bash', prefix: null, ts: '' })
    expect(recallStep(-1)).toBe('third')
    expect(recallStep(-1)).toBe('second')
    expect(recallStep(-1)).toBe('first')
    expect(recallStep(-1)).toBe('first') // clamped
    expect(recallStep(+1)).toBe('second')
    expect(recallStep(+1)).toBe('third')
    expect(recallStep(+1)).toBeNull()    // back to "no recall"
  })
})
```

- [ ] **Step 2: Run to confirm failure**

```bash
bun test tests/browser/history-store.test.ts
```

Expected: FAIL — `insertEntry`, `getCache`, `recallStep`, `__resetHistory` not exported.

- [ ] **Step 3: Append history store to `public/app.js`**

```js
// ── History in-memory cache ─────────────────────────────────────────────────
const HISTORY_CAP = 500
let _history = []           // newest first
let _recallIdx = -1          // -1 = not recalling

export function __resetHistory() { _history = []; _recallIdx = -1 }
export function getCache()        { return _history.slice() }

export function insertEntry(entry) {
  // Dedup by text — move existing match to head.
  const idx = _history.findIndex(e => e.text === entry.text)
  if (idx >= 0) _history.splice(idx, 1)
  _history.unshift(entry)
  if (_history.length > HISTORY_CAP) _history.length = HISTORY_CAP
  _recallIdx = -1
}

export function loadHistoryPage(entries) {
  // Replace cache with server's authoritative list (newest first).
  _history = entries.slice(0, HISTORY_CAP)
  _recallIdx = -1
}

export function recallStep(direction) {
  if (_history.length === 0) return null
  if (direction < 0) {
    _recallIdx = Math.min(_recallIdx + 1, _history.length - 1)
    return _history[_recallIdx].text
  }
  if (_recallIdx <= 0) {
    _recallIdx = -1
    return null
  }
  _recallIdx -= 1
  return _history[_recallIdx].text
}
```

- [ ] **Step 4: Run tests**

```bash
bun test tests/browser/history-store.test.ts
```

Expected: 3 pass.

- [ ] **Step 5: Commit**

```bash
git add tools/guide/public/app.js tools/guide/tests/browser/history-store.test.ts
git commit -m "guide(web): in-memory history cache with dedup + recallStep"
```

### Task 8.3: History sidebar render + filter + click-recall

**Files:**
- Modify: `tools/guide/public/app.js`

- [ ] **Step 1: Append render + wiring code**

```js
export function renderHistory(entries) {
  const ol = document.getElementById('history')
  if (!ol) return
  clearChildren(ol)
  for (const e of entries) {
    const li = document.createElement('li')
    li.dataset.id = String(e.id)
    if (e.exit_code !== null && e.exit_code !== 0 && e.exit_code !== undefined) li.classList.add('failed')

    const pfx = document.createElement('span')
    pfx.className = 'pfx'
    pfx.textContent = e.prefix ?? ''
    li.appendChild(pfx)

    const txt = document.createElement('span')
    txt.className = 'text'
    const firstLine = (e.text ?? '').split('\n')[0]
    txt.textContent = firstLine.length > 60 ? firstLine.slice(0, 57) + '…' : firstLine
    li.appendChild(txt)

    const age = document.createElement('span')
    age.className = 'age'
    age.textContent = relativeTime(e.ts)
    li.appendChild(age)

    ol.appendChild(li)
  }
}

function relativeTime(iso) {
  if (!iso) return ''
  const ms = Date.now() - new Date(iso).getTime()
  if (ms < 60_000)        return Math.max(1, Math.floor(ms/1000)) + 's'
  if (ms < 3_600_000)     return Math.floor(ms/60_000) + 'm'
  if (ms < 86_400_000)    return Math.floor(ms/3_600_000) + 'h'
  return Math.floor(ms/86_400_000) + 'd'
}

export function wireHistory() {
  const toggle  = document.getElementById('history-toggle')
  const section = document.getElementById('history-section')
  const filter  = document.getElementById('history-filter')
  const ol      = document.getElementById('history')
  const input   = document.getElementById('input')
  if (!toggle || !section || !ol) return

  toggle.addEventListener('click', () => {
    section.classList.toggle('collapsed')
    const expanded = !section.classList.contains('collapsed')
    toggle.setAttribute('aria-expanded', String(expanded))
    toggle.textContent = expanded ? '▾' : '▸'
    if (filter) filter.hidden = !expanded
    if (expanded && ws && ws.readyState === 1) {
      ws.send(JSON.stringify({ type:'history-list', scope:'workspace', limit: 100 }))
    }
  })

  if (filter) {
    let timer = 0
    filter.addEventListener('input', () => {
      clearTimeout(timer)
      timer = setTimeout(() => {
        const q = filter.value.trim()
        if (!q) {
          ws?.send(JSON.stringify({ type:'history-list', scope:'workspace', limit: 100 }))
        } else {
          ws?.send(JSON.stringify({ type:'history-search', query: q, limit: 100 }))
        }
      }, 200) as unknown as number
    })
  }

  ol.addEventListener('click', (e) => {
    const li = e.target.closest && e.target.closest('li[data-id]')
    if (!li) return
    const id = Number(li.dataset.id)
    const entry = _history.find(h => h.id === id)
    if (!entry || !input) return
    input.value = entry.text
    input.focus()
  })

  ol.addEventListener('dblclick', (e) => {
    const li = e.target.closest && e.target.closest('li[data-id]')
    if (!li) return
    const id = Number(li.dataset.id)
    const entry = _history.find(h => h.id === id)
    if (!entry) return
    if (input) input.value = entry.text
    submitPrompt()
  })
}
```

- [ ] **Step 2: Hook up dispatch in `dispatchMessage`**

Add cases:

```js
case 'history-page':
  loadHistoryPage(msg.entries)
  renderHistory(_history)
  break
case 'history-appended':
  insertEntry(msg.entry)
  renderHistory(_history)
  break
case 'history-updated': {
  const e = _history.find(h => h.id === msg.id)
  if (e) { e.exit_code = msg.exit_code; e.duration_ms = msg.duration_ms }
  renderHistory(_history)
  break
}
```

And update the prompt's keydown handler in `wirePrompt()` to call `recallStep`:

```js
input.addEventListener('keydown', e => {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault()
    submitPrompt()
  } else if (e.key === 'ArrowUp' && (input.value === '' || _recallIdx >= 0)) {
    const text = recallStep(-1)
    if (text !== null) { input.value = text; e.preventDefault() }
  } else if (e.key === 'ArrowDown' && _recallIdx >= 0) {
    const text = recallStep(+1)
    input.value = text ?? ''
    e.preventDefault()
  } else if (e.key === 'c' && e.ctrlKey && input.value === '' && _running) {
    e.preventDefault()
    if (ws && ws.readyState === 1) {
      ws.send(JSON.stringify({ type:'shell-signal', shell: _serverInfo.defaultShell, signal: 'SIGINT' }))
    }
  }
})
```

Update bootstrap init:

```js
const init = async () => {
  wireIssueClickHandlers()
  wirePrompt()
  wireHistory()
  await initTerminal()
  connectWebSocket()
}
```

- [ ] **Step 3: Manual smoke**

```bash
cd tools/guide && bun server.ts
# Browser: visit http://127.0.0.1:7771/
# - Type "echo hi" → press Enter → see attribution + output → entry appears in History
# - Click ▸ to expand History → entries listed
# - Click an entry → it populates the prompt (no auto-submit)
# - Double-click → it submits → re-runs
# - Type a filter query → list narrows
# - ↑ in empty prompt → recalls last command
```

- [ ] **Step 4: Commit**

```bash
git add tools/guide/public/app.js
git commit -m "guide(web): history sidebar render + filter + click-recall + ↑/↓ keyboard"
```

### Task 8.4: Concurrency lock — one command at a time across both shells

**Files:**
- Modify: `tools/guide/server.ts`
- Modify: `tools/guide/tests/server/ws.test.ts`

- [ ] **Step 1: Append failing test**

```ts
describe('concurrency lock', () => {
  test('second shell-line while first is running gets a busy reply', async () => {
    const ws = await connectWs(server.httpPort)
    await new Promise(r => ws.addEventListener('message', r, { once: true })) // server-info

    const isWin = process.platform === 'win32'
    const kind = isWin ? 'pwsh' : 'bash'
    const slow = isWin ? 'Start-Sleep -Milliseconds 800' : 'sleep 0.8'

    let busy = 0
    ws.addEventListener('message', e => {
      const msg = JSON.parse(e.data)
      if (msg.type === 'shell-busy') busy++
    })

    ws.send(JSON.stringify({ type:'shell-line', shell: kind, text: slow }))
    await new Promise(r => setTimeout(r, 50))
    ws.send(JSON.stringify({ type:'shell-line', shell: kind, text: 'echo nope' }))

    // Wait long enough for the slow command to complete + the busy notice
    await new Promise(r => setTimeout(r, 1500))
    expect(busy).toBe(1)

    ws.send(JSON.stringify({ type:'shell-signal', shell: kind, signal: 'SIGTERM' }))
    ws.close()
  })
})
```

Add the `shell-busy` type to `lib/ws.ts`:

```ts
| { type: 'shell-busy'; shell: 'pwsh' | 'bash' }
```

- [ ] **Step 2: Run to confirm failure**

```bash
bun test tests/server/ws.test.ts
```

Expected: FAIL — server runs both commands concurrently.

- [ ] **Step 3: Add a busy gate in the `shell-line` handler**

In `server.ts`, alongside `perShell`:

```ts
let busyShell: ShellKind | null = null
```

In the `shell-line` case, before any work:

```ts
if (busyShell !== null) {
  ws.send(JSON.stringify({ type:'shell-busy', shell: kind } satisfies WsMsg))
  break
}
busyShell = kind
```

When the sentinel hit fires (inside the per-shell `onData` wiring), clear it:

```ts
if (hit) {
  // ...existing logic...
  busyShell = null
}
```

Also clear on shell-exit:

```ts
pty.onExit(code => {
  busyShell = null
  broker.broadcast({ type:'shell-exit', shell: kind, code })
})
```

And on `shell-signal`:

```ts
case 'shell-signal': {
  // ...existing logic...
  busyShell = null   // user is asking to interrupt; release the lock
  break
}
```

- [ ] **Step 4: Run tests**

```bash
bun test tests/server/ws.test.ts
```

Expected: 10 pass.

- [ ] **Step 5: Surface busy state in browser**

Add to `dispatchMessage` in `app.js`:

```js
case 'shell-busy':
  showToast(`${msg.shell} is busy`)
  setRunning(false)  // re-enable the prompt; user can try again or send signal
  break
```

- [ ] **Step 6: Commit**

```bash
git add tools/guide/server.ts tools/guide/lib/ws.ts \
        tools/guide/tests/server/ws.test.ts tools/guide/public/app.js
git commit -m "guide(server,web): one-command-at-a-time lock across both shells"
```

---

## Phase 9: CLI flags + `--shell` standalone + headless + auto-launch

Wraps `startServer()` in a CLI entry. Adds standalone shell mode, headless JSON mode for CI, browser auto-launch, and graceful shutdown.

### Task 9.1: Argv parser (`lib/cli.ts`)

**Files:**
- Create: `tools/guide/lib/cli.ts`
- Test: `tools/guide/tests/server/cli.test.ts`

- [ ] **Step 1: Write failing test**

```ts
import { describe, expect, test } from 'bun:test'
import { parseArgs } from '../../lib/cli.ts'

describe('parseArgs', () => {
  test('defaults: plan mode, default shell, auto-open', () => {
    const a = parseArgs([])
    expect(a.mode).toBe('plan')
    expect(a.openBrowser).toBe(true)
    expect(a.headless).toBe(false)
  })

  test('--shell switches to shell-only', () => {
    expect(parseArgs(['--shell']).mode).toBe('shell-only')
  })

  test('--default-shell=bash sets defaultShell', () => {
    expect(parseArgs(['--default-shell=bash']).defaultShell).toBe('bash')
  })

  test('--workspace=<path> sets workspace', () => {
    expect(parseArgs(['--workspace=/proj']).workspace).toBe('/proj')
  })

  test('--port=<n> sets port', () => {
    expect(parseArgs(['--port=9000']).httpPort).toBe(9000)
  })

  test('--no-open disables auto-launch', () => {
    expect(parseArgs(['--no-open']).openBrowser).toBe(false)
  })

  test('--headless implies no-open', () => {
    const a = parseArgs(['--headless'])
    expect(a.headless).toBe(true)
    expect(a.openBrowser).toBe(false)
  })

  test('-h shows help and signals exit', () => {
    expect(parseArgs(['-h']).help).toBe(true)
    expect(parseArgs(['--help']).help).toBe(true)
  })

  test('unknown flag throws', () => {
    expect(() => parseArgs(['--bogus'])).toThrow(/unknown flag/i)
  })
})
```

- [ ] **Step 2: Run to confirm failure**

```bash
bun test tests/server/cli.test.ts
```

Expected: FAIL — `lib/cli.ts` not found.

- [ ] **Step 3: Implement `lib/cli.ts`**

```ts
// tools/guide/lib/cli.ts

export type ParsedArgs = {
  mode:         'plan' | 'shell-only'
  defaultShell: 'pwsh' | 'bash' | null      // null = let server pick OS default
  workspace:    string | null
  httpPort:     number | null
  eventsPort:   number | null
  openBrowser:  boolean
  headless:     boolean
  dataDir:      string | null
  noHistory:    boolean
  verbose:      boolean
  dev:          boolean
  help:         boolean
}

export function parseArgs(argv: string[]): ParsedArgs {
  const out: ParsedArgs = {
    mode: 'plan',
    defaultShell: null,
    workspace: null,
    httpPort: null,
    eventsPort: null,
    openBrowser: true,
    headless: false,
    dataDir: null,
    noHistory: false,
    verbose: false,
    dev: false,
    help: false,
  }

  for (const a of argv) {
    if (a === '--shell')     { out.mode = 'shell-only'; continue }
    if (a === '--plan')      { out.mode = 'plan'; continue }
    if (a === '--no-open')   { out.openBrowser = false; continue }
    if (a === '--headless')  { out.headless = true; out.openBrowser = false; continue }
    if (a === '--no-history'){ out.noHistory = true; continue }
    if (a === '--verbose')   { out.verbose = true; continue }
    if (a === '--dev')       { out.dev = true; continue }
    if (a === '-h' || a === '--help') { out.help = true; continue }

    const eq = a.indexOf('=')
    if (eq < 0) throw new Error(`unknown flag: ${a}`)
    const key = a.slice(0, eq)
    const val = a.slice(eq + 1)

    switch (key) {
      case '--default-shell':
        if (val !== 'pwsh' && val !== 'bash') throw new Error(`--default-shell must be pwsh|bash, got ${val}`)
        out.defaultShell = val; break
      case '--workspace':   out.workspace = val; break
      case '--port':        out.httpPort = Number(val); if (!Number.isFinite(out.httpPort)) throw new Error(`--port must be a number`); break
      case '--events-port': out.eventsPort = Number(val); break
      case '--data-dir':    out.dataDir = val; break
      default:              throw new Error(`unknown flag: ${a}`)
    }
  }
  return out
}

export const HELP_TEXT = `
Usage: bun guide [options]

Options:
  --shell                      Standalone mode (no plan events expected)
  --plan                       Plan mode (default)
  --default-shell=pwsh|bash    Default shell when no prefix (else OS default)
  --workspace=<path>           cwd for spawned PTYs and history filter
  --port=<n>                   Force HTTP port (default: 7771+)
  --events-port=<n>            Force plan-events TCP port (default: HTTP port + 1)
  --no-open                    Don't auto-launch browser
  --headless                   stdin JSONL → stdout final JSON; no HTTP/WS
  --data-dir=<path>            SQLite DB location override
  --no-history                 Don't write to history (still reads existing)
  --verbose                    Add debug to logs
  --dev                        Forward server logs to browser console
  -h, --help                   Show this help
`.trim()
```

- [ ] **Step 4: Run tests**

```bash
bun test tests/server/cli.test.ts
```

Expected: 9 pass.

- [ ] **Step 5: Commit**

```bash
git add tools/guide/lib/cli.ts tools/guide/tests/server/cli.test.ts
git commit -m "guide(server): CLI argv parser with --shell, --headless, --port, etc."
```

### Task 9.2: Server bootstrap script wiring (`server.ts` main)

**Files:**
- Modify: `tools/guide/server.ts`

- [ ] **Step 1: Add a `main()` to `server.ts`**

Append at the bottom of `server.ts`:

```ts
async function openBrowser(url: string): Promise<void> {
  try {
    if (process.platform === 'win32') {
      Bun.spawn({ cmd: ['cmd', '/c', 'start', '""', url] })
    } else if (process.platform === 'darwin') {
      Bun.spawn({ cmd: ['open', url] })
    } else {
      Bun.spawn({ cmd: ['xdg-open', url] })
    }
  } catch (e) {
    console.warn(`Could not auto-open browser: ${e}. Visit ${url} manually.`)
  }
}

if (import.meta.main) {
  const { parseArgs, HELP_TEXT } = await import('./lib/cli.ts')
  let args
  try { args = parseArgs(process.argv.slice(2)) }
  catch (e: any) { console.error(String(e.message)); process.exit(2) }

  if (args.help) { console.log(HELP_TEXT); process.exit(0) }

  if (args.headless) {
    const { runHeadless } = await import('./lib/headless.ts')
    process.exit(await runHeadless({ noHistory: args.noHistory }))
  }

  const server = await startServer({
    httpPort:   args.httpPort ?? 0,
    eventsPort: args.eventsPort ?? 0,
    mode:       args.mode,
    defaultShell: args.defaultShell ?? undefined,
    workspace:  args.workspace ?? undefined,
    dataDir:    args.dataDir ?? undefined,
  })

  const url = `http://127.0.0.1:${server.httpPort}/`
  console.log(`Guide running at ${url}  (events on :${server.eventsPort})`)

  if (args.openBrowser) await openBrowser(url)

  // Graceful shutdown on Ctrl+C / SIGTERM
  let shuttingDown = false
  const shutdown = () => {
    if (shuttingDown) return
    shuttingDown = true
    console.log('\nShutting down…')
    try { server.stop() } catch {}
    process.exit(0)
  }
  process.on('SIGINT',  shutdown)
  process.on('SIGTERM', shutdown)
}
```

- [ ] **Step 2: Smoke check**

```bash
cd tools/guide && bun server.ts --no-open --port=8765 &
sleep 1
curl -s http://127.0.0.1:8765/healthz | grep '"guide":true'
kill %1
```

Expected: `"guide":true,...` shows; server exits cleanly on SIGTERM.

- [ ] **Step 3: Commit**

```bash
git add tools/guide/server.ts
git commit -m "guide(server): main() entry — argv parsing, browser auto-launch, signal-driven shutdown"
```

### Task 9.3: Headless JSON mode (`lib/headless.ts`)

**Files:**
- Create: `tools/guide/lib/headless.ts`
- Test: `tools/guide/tests/server/headless.test.ts`

- [ ] **Step 1: Write failing test**

```ts
import { describe, expect, test } from 'bun:test'
import { runHeadlessFromInput } from '../../lib/headless.ts'

describe('headless mode', () => {
  test('reads JSONL plan events, emits final JSON snapshot', async () => {
    const input = [
      { type:'plan-started', planId:'h1', title:'CI', subtitle:'', phases:[{name:'A', type:'single'}] },
      { type:'phase-started', planId:'h1', phaseName:'A', phaseIndex:1, phaseTotal:1 },
      { type:'phase-result', planId:'h1', phaseName:'A', itemLabel:'', success:true, message:'ok' },
      { type:'phase-completed', planId:'h1', phaseName:'A', status:'ok' },
      { type:'plan-completed', planId:'h1', exitCode: 0 },
    ].map(e => JSON.stringify(e)).join('\n') + '\n'

    const { json, exitCode } = await runHeadlessFromInput(input)
    const obj = JSON.parse(json)
    expect(obj.title).toBe('CI')
    expect(obj.phases).toHaveLength(1)
    expect(obj.phases[0].status).toBe('ok')
    expect(obj.exitCode).toBe(0)
    expect(exitCode).toBe(0)
  })

  test('failed plan returns exit code 1', async () => {
    const input = [
      { type:'plan-started', planId:'h2', title:'CI', subtitle:'', phases:[] },
      { type:'plan-completed', planId:'h2', exitCode: 1 },
    ].map(e => JSON.stringify(e)).join('\n') + '\n'

    const { exitCode } = await runHeadlessFromInput(input)
    expect(exitCode).toBe(1)
  })

  test('malformed lines are skipped', async () => {
    const input = 'not json\n' +
      JSON.stringify({ type:'plan-started', planId:'h3', title:'X', subtitle:'', phases:[] }) + '\n' +
      JSON.stringify({ type:'plan-completed', planId:'h3', exitCode: 0 }) + '\n'
    const { json, exitCode } = await runHeadlessFromInput(input)
    expect(JSON.parse(json).title).toBe('X')
    expect(exitCode).toBe(0)
  })
})
```

- [ ] **Step 2: Run to confirm failure**

```bash
bun test tests/server/headless.test.ts
```

Expected: FAIL — `lib/headless.ts` not found.

- [ ] **Step 3: Implement `lib/headless.ts`**

```ts
// tools/guide/lib/headless.ts
import { JsonlBuffer } from './events.ts'
import { PlanStore, type PlanSnapshot } from './state.ts'

export async function runHeadlessFromInput(text: string): Promise<{ json: string; exitCode: number }> {
  const store = new PlanStore()
  const buf   = new JsonlBuffer()
  buf.feed(text, e => store.apply(e))
  const recent = store.mostRecent()
  return finish(recent)
}

function finish(snap: PlanSnapshot | null): { json: string; exitCode: number } {
  const json = JSON.stringify(snap ?? {}, null, 2)
  const exitCode = snap?.exitCode ?? 1
  return { json, exitCode }
}

export async function runHeadless(_opts: { noHistory?: boolean } = {}): Promise<number> {
  // Reads stdin JSONL, writes final snapshot JSON to stdout.
  const decoder = new TextDecoder()
  const store = new PlanStore()
  const buf   = new JsonlBuffer()

  for await (const chunk of Bun.stdin.stream()) {
    buf.feed(decoder.decode(chunk, { stream: true }), e => store.apply(e))
  }
  const snap = store.mostRecent()
  process.stdout.write(JSON.stringify(snap ?? {}, null, 2) + '\n')
  return snap?.exitCode ?? 1
}
```

- [ ] **Step 4: Run tests**

```bash
bun test tests/server/headless.test.ts
```

Expected: 3 pass.

- [ ] **Step 5: Smoke check end-to-end**

```bash
echo '{"type":"plan-started","planId":"x","title":"Smoke","subtitle":"","phases":[]}
{"type":"plan-completed","planId":"x","exitCode":0}' | bun tools/guide/server.ts --headless
```

Expected: JSON snapshot prints, exit 0.

- [ ] **Step 6: Commit**

```bash
git add tools/guide/lib/headless.ts tools/guide/tests/server/headless.test.ts
git commit -m "guide(server): --headless mode (stdin JSONL → stdout JSON snapshot)"
```

### Task 9.4: Shell-only sidebar adjustments

**Files:**
- Modify: `tools/guide/public/app.js`
- Modify: `tools/guide/public/style.css`

- [ ] **Step 1: Hide plan sections in shell-only mode**

Append CSS:

```css
body.shell-only #phases-section,
body.shell-only #active-section,
body.shell-only #issues-section { display: none; }
body.shell-only #history-section { /* full sidebar height for history */ }
```

In `app.js`'s `dispatchMessage`'s `server-info` case:

```js
case 'server-info':
  _serverInfo = msg
  if (msg.mode === 'shell-only') document.body.classList.add('shell-only')
  // Pre-fetch first history page so the sidebar is populated immediately.
  ws?.send(JSON.stringify({ type:'history-list', scope:'workspace', limit: 100 }))
  break
```

- [ ] **Step 2: Manual smoke**

```bash
cd tools/guide && bun server.ts --shell --no-open --port=8766 &
sleep 1
# Browser: http://127.0.0.1:8766/
# Confirm Phases / Active / Issues sections are hidden; History is visible.
kill %1
```

- [ ] **Step 3: Commit**

```bash
git add tools/guide/public/app.js tools/guide/public/style.css
git commit -m "guide(web): shell-only mode hides plan sections, preloads history"
```

---

## Phase 10: bootstrap.ps1 cutover + cross-stack tests rewritten

`Invoke-GuidePlan` becomes the orchestrator that decides between Bun server, headless, and streaming fallback. Bootstrap's call site shrinks.

### Task 10.1: Rewrite `Invoke-GuidePlan` in `ps/guide.psm1`

**Files:**
- Modify: `tools/guide/ps/guide.psm1`

- [ ] **Step 1: Replace `Invoke-GuidePlan` body**

Open `tools/guide/ps/guide.psm1` and replace the `Invoke-GuidePlan` function with:

```powershell
function Invoke-GuidePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Plan,
        [int]$DashboardPort = 7771,
        [int]$EventsPort    = 7772,
        [string]$ServerPath = $null,
        [int]$ConnectTimeoutMs = 2000
    )

    if ($null -eq $ServerPath) {
        $ServerPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'server.ts'
    }

    # 1. Probe dashboard server
    $serverUp = Test-GuideServerReachable -DashboardPort $DashboardPort -TimeoutMs 800

    # 2. Auto-spawn if Bun is installed and server isn't up
    if (-not $serverUp -and (Get-Command bun -ErrorAction SilentlyContinue)) {
        if (Test-Path $ServerPath) {
            Start-GuideServerDetached -ServerPath $ServerPath
            $deadline = (Get-Date).AddSeconds(8)
            while ((Get-Date) -lt $deadline) {
                if (Test-GuideServerReachable -DashboardPort $DashboardPort -TimeoutMs 200) {
                    $serverUp = $true; break
                }
                Start-Sleep -Milliseconds 200
            }
        }
    }

    if (-not $serverUp) {
        Invoke-GuideStreamingFallback -Plan $Plan
        return
    }

    # 3. Connect, emit events for the plan, disconnect.
    Connect-GuideServer -Port $EventsPort -TimeoutMs $ConnectTimeoutMs
    try {
        $planId = [guid]::NewGuid().ToString()
        Send-GuideEvent @{
            type='plan-started'; planId=$planId; title=$Plan.Title; subtitle=$Plan.Subtitle
            phases = $Plan.Phases | ForEach-Object {
                @{ name = $_.Name; type = (if ($_.ContainsKey('Type')) { $_.Type } else { 'loop' }) }
            }
        }

        Invoke-GuidePlanPhases -Plan $Plan `
            -OnPhaseStart  { param($info)
                Send-GuideEvent @{ type='phase-started'; planId=$planId; phaseName=$info.PhaseName; phaseIndex=$info.PhaseIndex; phaseTotal=$info.PhaseTotal }
            } `
            -OnPhaseResult { param($info)
                Send-GuideEvent @{
                    type='phase-result'; planId=$planId; phaseName=$info.PhaseName
                    itemLabel=$info.ItemLabel; success=$info.Success; message=$info.Message
                    severity=$info.Severity; fixCommand=$info.FixCommand; alerts=$info.Alerts
                }
            } `
            -OnPhaseEnd    { param($info)
                Send-GuideEvent @{ type='phase-completed'; planId=$planId; phaseName=$info.PhaseName; status=$info.Status }
            }

        $exitCode = if ($Plan.ContainsKey('ExitCode')) { $Plan.ExitCode } else { 0 }
        Send-GuideEvent @{ type='plan-completed'; planId=$planId; exitCode=$exitCode }
    } finally {
        Disconnect-GuideServer
    }
}

function Start-GuideServerDetached {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ServerPath)

    $bun = (Get-Command bun -ErrorAction Stop).Source
    if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        $args = @('/C', 'start', '""', '/B', $bun, $ServerPath)
        Start-Process -FilePath cmd.exe -ArgumentList $args -WindowStyle Hidden | Out-Null
    } else {
        Start-Process -FilePath $bun -ArgumentList $ServerPath -RedirectStandardOutput /dev/null -RedirectStandardError /dev/null | Out-Null
    }
}

function Invoke-GuideStreamingFallback {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Plan)

    Write-Host "─── $($Plan.Title) ───" -ForegroundColor Cyan
    if ($Plan.Subtitle) { Write-Host $Plan.Subtitle -ForegroundColor DarkGray }

    Invoke-GuidePlanPhases -Plan $Plan `
        -OnPhaseStart  { param($info) Write-Host ""; Write-Host "▸ $($info.PhaseName)" -ForegroundColor Yellow } `
        -OnPhaseResult { param($info)
            $glyph = if ($info.Success) { '✓' } else { '✗' }
            $color = if ($info.Success) { 'Green' } else { 'Red' }
            Write-Host "  $glyph $($info.Message)" -ForegroundColor $color
        } `
        -OnPhaseEnd    { param($info) }
}
```

- [ ] **Step 2: Update `ps/guide.psd1` exports**

Make sure these are exported (most already are):

```powershell
'Invoke-GuidePlan'
'Start-GuideServerDetached'
'Invoke-GuideStreamingFallback'
```

- [ ] **Step 3: Smoke check**

```bash
pwsh -NoProfile -Command "
Import-Module tools/guide/ps/guide.psd1 -Force
\$plan = New-GuidePlan -Title 'Smoke' -Subtitle 'manual'
\$plan = Add-GuideSinglePhase -Plan \$plan -Name 'Hello' -Action {
    return New-GuideResult -Success \$true -Message 'hello world'
}
Invoke-GuidePlan -Plan \$plan
"
```

Expected: with no server up, falls through to streaming and prints the phase line. With `bun tools/guide/server.ts` running in another terminal, the dashboard sidebar receives the plan.

- [ ] **Step 4: Commit**

```bash
git add tools/guide/ps/guide.psm1 tools/guide/ps/guide.psd1
git commit -m "guide(ps): Invoke-GuidePlan v2 — server-first, streaming fallback"
```

### Task 10.2: Rewrite `bootstrap/tests/test-guide-integration.ps1`

**Files:**
- Modify: `bootstrap/tests/test-guide-integration.ps1`

- [ ] **Step 1: Replace the test scenarios**

Replace the entire file body (keeping the prologue helpers) with:

```powershell
#Requires -Version 7
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$bootstrap = Join-Path $repoRoot 'bootstrap/bootstrap.ps1'
$guideDir  = Join-Path $repoRoot 'tools/guide'
$guidePsd1 = Join-Path $guideDir 'ps/guide.psd1'
$serverTs  = Join-Path $guideDir 'server.ts'

$pass = 0; $fail = 0
function Pass($m) { Write-Host "PASS: $m" -ForegroundColor Green; $script:pass++ }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red;   $script:fail++ }

# --- S0: Files exist ---
if (Test-Path $bootstrap) { Pass 'bootstrap.ps1 exists' } else { Fail "missing $bootstrap" }
if (Test-Path $guidePsd1) { Pass 'ps/guide.psd1 exists' } else { Fail "missing $guidePsd1" }
if (Test-Path $serverTs)  { Pass 'server.ts exists'      } else { Fail "missing $serverTs" }

# --- S1: Headless CI path (bootstrap | bun guide --headless) ---
$bun = (Get-Command bun -ErrorAction SilentlyContinue)
if ($bun) {
    $jsonl = @(
        '{"type":"plan-started","planId":"ci","title":"Bootstrap","subtitle":"","phases":[]}'
        '{"type":"plan-completed","planId":"ci","exitCode":0}'
    ) -join "`n"
    $jsonOut = $jsonl | & $bun.Source $serverTs --headless
    if ($LASTEXITCODE -eq 0) { Pass 'S1: headless exit 0' } else { Fail "S1: headless exit $LASTEXITCODE" }
    try {
        $obj = $jsonOut | ConvertFrom-Json
        if ($obj.title -eq 'Bootstrap') { Pass 'S1: headless JSON shape' }
        else { Fail "S1: unexpected title $($obj.title)" }
    } catch { Fail "S1: headless JSON parse: $_" }
} else {
    Write-Host "SKIP: S1 (bun not installed)" -ForegroundColor Yellow
}

# --- S2: Server path (bootstrap.ps1 emits to running Bun server) ---
if ($bun) {
    # Spawn server detached on free ports
    $http = 18771; $events = 18772
    $proc = Start-Process -FilePath $bun.Source -ArgumentList @($serverTs, '--no-open', "--port=$http", "--events-port=$events") -PassThru -WindowStyle Hidden
    try {
        # Wait for ready
        $deadline = (Get-Date).AddSeconds(8); $ready = $false
        while ((Get-Date) -lt $deadline) {
            try {
                $r = Invoke-WebRequest -Uri "http://127.0.0.1:$http/healthz" -TimeoutSec 1 -UseBasicParsing
                if ($r.Content -match '"guide":\s*true') { $ready = $true; break }
            } catch {}
            Start-Sleep -Milliseconds 200
        }
        if ($ready) { Pass 'S2: server reachable' } else { Fail 'S2: server did not start in 8s' }

        # Run a tiny plan via the PS module
        Import-Module $guidePsd1 -Force
        $plan = New-GuidePlan -Title 'S2 plan' -Subtitle 'integration'
        $plan = Add-GuideSinglePhase -Plan $plan -Name 'Hello' -Action {
            return New-GuideResult -Success $true -Message 'hello'
        }
        Invoke-GuidePlan -Plan $plan -DashboardPort $http -EventsPort $events
        Pass 'S2: Invoke-GuidePlan completed without throwing'
    } finally {
        try { Stop-Process -Id $proc.Id -Force } catch {}
    }
} else {
    Write-Host "SKIP: S2 (bun not installed)" -ForegroundColor Yellow
}

# --- S3: Streaming fallback (no Bun in PATH) ---
Import-Module $guidePsd1 -Force
$plan = New-GuidePlan -Title 'S3 fallback' -Subtitle ''
$plan = Add-GuideSinglePhase -Plan $plan -Name 'X' -Action {
    return New-GuideResult -Success $true -Message 'x ok'
}
$out = Invoke-GuideStreamingFallback -Plan $plan 6>&1 | Out-String
if ($out -match 'S3 fallback' -and $out -match 'X') { Pass 'S3: streaming fallback prints' }
else { Fail "S3: unexpected fallback output: $out" }

Write-Host ""
Write-Host "Guide integration: $pass pass, $fail fail" -ForegroundColor (if ($fail -eq 0) { 'Green' } else { 'Red' })
exit ([int]($fail -gt 0))
```

- [ ] **Step 2: Run the rewritten integration test**

```bash
pwsh -NoProfile -File bootstrap/tests/test-guide-integration.ps1
```

Expected: all PASS lines (S1/S2 skipped if bun unavailable; S3 always runs).

- [ ] **Step 3: Update `bootstrap/tests/test-e2e.ps1` paths**

Search for `tools/guide/guide.psm1` and `tools/guide/guide.psd1` and replace with `tools/guide/ps/guide.psm1` / `tools/guide/ps/guide.psd1` if any leftovers from Phase 0.

- [ ] **Step 4: Commit**

```bash
git add bootstrap/tests/test-guide-integration.ps1 bootstrap/tests/test-e2e.ps1
git commit -m "bootstrap-tests: rewrite guide-integration for v2 (S1 headless / S2 server / S3 fallback)"
```

### Task 10.3: Verify `bootstrap.ps1` end-to-end

**Files:** none (smoke check only)

- [ ] **Step 1: Run bootstrap with the server up**

```bash
cd tools/guide && bun server.ts --no-open --port=7771 &
sleep 1
pwsh -NoProfile -File bootstrap/bootstrap.ps1
# Watch the dashboard at http://127.0.0.1:7771/ — phases populate as bootstrap runs
kill %1
```

- [ ] **Step 2: Run bootstrap with no server**

```bash
pwsh -NoProfile -File bootstrap/bootstrap.ps1
# With Bun installed, server auto-spawns. Without Bun, streaming fallback prints in the terminal.
```

- [ ] **Step 3: Commit any incidental fixes that surfaced** (no expected diffs)

```bash
git status
# If clean, no commit needed.
```

---

## Phase 11: Playwright e2e tests

Real headless Chromium drives the dashboard end-to-end: server starts → browser visits → plan events flow → shell roundtrip → history persists across restart.

### Task 11.1: Install Playwright and write `e2e/server-up.test.ts`

**Files:**
- Modify: `tools/guide/package.json` (already has playwright in devDeps from Task 0.1)
- Create: `tools/guide/tests/e2e/_helpers.ts`
- Create: `tools/guide/tests/e2e/server-up.test.ts`

- [ ] **Step 1: Install Chromium**

```bash
cd tools/guide
bun x playwright install chromium
```

- [ ] **Step 2: Write the helper**

`tests/e2e/_helpers.ts`:

```ts
import { startServer, type GuideServer } from '../../server.ts'
import { chromium, type Browser, type Page } from 'playwright'

export async function startTestServer(): Promise<GuideServer> {
  return startServer({ httpPort: 0, eventsPort: 0, openBrowser: false, dataDir: ':memory:' })
}

export async function newBrowser(): Promise<{ browser: Browser; page: Page }> {
  const browser = await chromium.launch({ headless: true })
  const ctx     = await browser.newContext()
  const page    = await ctx.newPage()
  return { browser, page }
}
```

- [ ] **Step 3: Write `server-up.test.ts`**

```ts
import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import type { GuideServer } from '../../server.ts'
import { startTestServer, newBrowser } from './_helpers.ts'

let server: GuideServer

beforeEach(async () => { server = await startTestServer() })
afterEach(() => { server.stop() })

describe('e2e server-up', () => {
  test('GET /healthz responds with guide JSON', async () => {
    const r = await fetch(`http://127.0.0.1:${server.httpPort}/healthz`)
    const json = await r.json()
    expect(json.guide).toBe(true)
  })

  test('Browser loads dashboard with sidebar regions present', async () => {
    const { browser, page } = await newBrowser()
    try {
      await page.goto(`http://127.0.0.1:${server.httpPort}/`)
      await page.waitForSelector('#phases')
      await page.waitForSelector('#issues')
      await page.waitForSelector('#prompt')
      const titleText = await page.title()
      expect(titleText).toBe('Guide')
    } finally {
      await browser.close()
    }
  })
})
```

- [ ] **Step 4: Run the test**

```bash
bun test tests/e2e/server-up.test.ts
```

Expected: 2 pass.

- [ ] **Step 5: Commit**

```bash
git add tools/guide/tests/e2e/_helpers.ts tools/guide/tests/e2e/server-up.test.ts
git commit -m "guide(e2e): server-up smoke — healthz + dashboard load"
```

### Task 11.2: `e2e/plan-flow.test.ts`

**Files:**
- Create: `tools/guide/tests/e2e/plan-flow.test.ts`

- [ ] **Step 1: Write the test**

```ts
import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import type { GuideServer } from '../../server.ts'
import { startTestServer, newBrowser } from './_helpers.ts'
import { Socket } from 'node:net'

let server: GuideServer
beforeEach(async () => { server = await startTestServer() })
afterEach(() => server.stop())

function emit(events: object[], port: number): Promise<void> {
  return new Promise((resolve, reject) => {
    const s = new Socket()
    s.once('error', reject)
    s.connect(port, '127.0.0.1', () => {
      const text = events.map(e => JSON.stringify(e)).join('\n') + '\n'
      s.write(text, () => { s.end(); resolve() })
    })
  })
}

describe('e2e plan flow', () => {
  test('plan events render in sidebar', async () => {
    const { browser, page } = await newBrowser()
    try {
      await page.goto(`http://127.0.0.1:${server.httpPort}/`)
      await page.waitForSelector('#phases')

      await emit([
        { type:'plan-started', planId:'pe', title:'E2E', subtitle:'',
          phases:[{name:'A', type:'single'}, {name:'B', type:'single'}] },
        { type:'phase-started', planId:'pe', phaseName:'A', phaseIndex:1, phaseTotal:2 },
        { type:'phase-result', planId:'pe', phaseName:'A', itemLabel:'',
          success:true, message:'a ok' },
        { type:'phase-completed', planId:'pe', phaseName:'A', status:'ok' },
        { type:'phase-started', planId:'pe', phaseName:'B', phaseIndex:2, phaseTotal:2 },
        { type:'phase-result', planId:'pe', phaseName:'B', itemLabel:'',
          success:false, message:'b broken', severity:'fail', fixCommand:'fix B' },
        { type:'phase-completed', planId:'pe', phaseName:'B', status:'fail' },
        { type:'plan-completed', planId:'pe', exitCode:1 },
      ], server.eventsPort)

      // Sidebar should reflect: 2 phases (one ok, one fail), 1 issue
      await page.waitForFunction(() => {
        const lis = document.querySelectorAll('#phases li')
        return lis.length === 2 &&
               lis[0].classList.contains('ok') &&
               lis[1].classList.contains('fail')
      }, { timeout: 3000 })
      const issueCount = await page.textContent('#issues-count')
      expect(issueCount).toBe('1')
      const issueText = await page.textContent('#issues li span')
      expect(issueText).toContain('b broken')
    } finally {
      await browser.close()
    }
  })
})
```

- [ ] **Step 2: Run**

```bash
bun test tests/e2e/plan-flow.test.ts
```

Expected: 1 pass.

- [ ] **Step 3: Commit**

```bash
git add tools/guide/tests/e2e/plan-flow.test.ts
git commit -m "guide(e2e): plan-flow — TCP events render to sidebar phases + issues"
```

### Task 11.3: `e2e/shell-roundtrip.test.ts`

**Files:**
- Create: `tools/guide/tests/e2e/shell-roundtrip.test.ts`

- [ ] **Step 1: Write the test**

```ts
import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import type { GuideServer } from '../../server.ts'
import { startTestServer, newBrowser } from './_helpers.ts'

let server: GuideServer
beforeEach(async () => { server = await startTestServer() })
afterEach(() => server.stop())

describe('e2e shell roundtrip', () => {
  test('typing a command lands output in xterm', async () => {
    const { browser, page } = await newBrowser()
    try {
      await page.goto(`http://127.0.0.1:${server.httpPort}/`)
      await page.waitForSelector('#term .xterm')

      const isWin = process.platform === 'win32'
      const cmd   = isWin ? '#Write-Host hello-shell' : '!echo hello-shell'

      await page.fill('#input', cmd)
      await page.press('#input', 'Enter')

      await page.waitForFunction(
        () => document.querySelector('#term')!.textContent!.includes('hello-shell'),
        { timeout: 5000 }
      )

      const text = await page.textContent('#term')
      expect(text).toContain('hello-shell')
    } finally {
      await browser.close()
    }
  })
})
```

- [ ] **Step 2: Run**

```bash
bun test tests/e2e/shell-roundtrip.test.ts
```

Expected: 1 pass.

- [ ] **Step 3: Commit**

```bash
git add tools/guide/tests/e2e/shell-roundtrip.test.ts
git commit -m "guide(e2e): shell roundtrip — type command, see output in xterm"
```

### Task 11.4: `e2e/persistence.test.ts`

**Files:**
- Create: `tools/guide/tests/e2e/persistence.test.ts`

- [ ] **Step 1: Write the test**

```ts
import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { startServer, type GuideServer } from '../../server.ts'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

describe('persistence', () => {
  let dataDir: string
  let server: GuideServer

  beforeEach(async () => {
    dataDir = await mkdtemp(join(tmpdir(), 'guide-pers-'))
  })

  afterEach(async () => {
    server?.stop()
    await rm(dataDir, { recursive: true, force: true })
  })

  test('history persists across server restart', async () => {
    server = await startServer({ httpPort: 0, eventsPort: 0, openBrowser: false, dataDir })

    // Insert via direct DB call (round-tripping through PTY would slow this test)
    server.db.run(
      "INSERT INTO history(text,shell,prefix,workspace,ts,exit_code,duration_ms) " +
      "VALUES ('persisted-cmd','bash',NULL,?,?,0,42)",
      [process.cwd(), new Date().toISOString()]
    )

    server.stop()

    // Restart with same dataDir
    server = await startServer({ httpPort: 0, eventsPort: 0, openBrowser: false, dataDir })

    const rows = server.db.query("SELECT * FROM history WHERE text='persisted-cmd'").all() as any[]
    expect(rows).toHaveLength(1)
    expect(rows[0].duration_ms).toBe(42)
  })
})
```

- [ ] **Step 2: Run**

```bash
bun test tests/e2e/persistence.test.ts
```

Expected: 1 pass.

- [ ] **Step 3: Commit**

```bash
git add tools/guide/tests/e2e/persistence.test.ts
git commit -m "guide(e2e): persistence — history survives server restart"
```

### Task 11.5: CI workflow

**Files:**
- Create: `tools/guide/.github/workflows/test.yml` (or modify the repo's existing CI to add a guide job)

- [ ] **Step 1: Write or extend CI**

If `tools/guide` is its own repo, add `.github/workflows/test.yml`:

```yaml
name: guide tests
on: [push, pull_request]
jobs:
  test:
    runs-on: ${{ matrix.os }}
    strategy:
      matrix:
        os: [ubuntu-latest, windows-latest]
    steps:
      - uses: actions/checkout@v4
      - uses: oven-sh/setup-bun@v1
        with: { bun-version: latest }
      - name: PowerShell present (Linux/macOS)
        if: runner.os != 'Windows'
        run: pwsh -v
      - name: Install deps
        run: bun install
      - name: Install Playwright Chromium
        run: bun x playwright install --with-deps chromium
      - name: PS unit tests
        run: pwsh -NoProfile -File tests/ps/run-all.ps1
      - name: Bun server tests
        run: bun test tests/server tests/browser
      - name: e2e tests
        run: bun test tests/e2e
        env:
          # PTY tests need a TTY-ish environment; CI is fine with pipes for v1.
          GUIDE_NO_OPEN: '1'
```

- [ ] **Step 2: Local CI dry run**

```bash
cd tools/guide
pwsh -NoProfile -File tests/ps/run-all.ps1
bun test tests/server tests/browser
bun test tests/e2e
```

Expected: all green.

- [ ] **Step 3: Commit**

```bash
git add tools/guide/.github/workflows/test.yml
git commit -m "guide(ci): GH Actions workflow for PS + Bun + e2e on Linux + Windows"
```

---

## Phase 12: Cleanup — delete the dead PS-TUI

The new architecture is fully wired and tested; now reclaim the disk and the test count.

### Task 12.1: Delete render / input / theme / layout / clipboard / environment / headless

**Files:**
- Delete: `tools/guide/lib/render.ps1`
- Delete: `tools/guide/lib/input.ps1`
- Delete: `tools/guide/lib/headless.ps1`
- Delete: `tools/guide/lib/theme.ps1`
- Delete: `tools/guide/lib/layout.ps1`
- Delete: `tools/guide/lib/clipboard.ps1`
- Delete: `tools/guide/lib/environment.ps1`
- Delete: `tools/guide/themes/` (recursively)

- [ ] **Step 1: Confirm nothing references them**

```bash
cd tools/guide
grep -RIn "lib/render.ps1\|lib/input.ps1\|lib/headless.ps1\|lib/theme.ps1\|lib/layout.ps1\|lib/clipboard.ps1\|lib/environment.ps1" \
  --include='*.ps1' --include='*.psd1' --include='*.psm1' . || echo 'no references'
```

Expected: `no references` or only references inside the to-be-deleted files themselves.

- [ ] **Step 2: Confirm `ps/guide.psd1` exports don't include any deleted symbols**

```bash
grep -E "Show-|Render-|Initialize-GuideTui|Stop-GuideTui|Clear-GuideRegion|Write-GuideAt|Write-GuideCentered|Set-GuideCursor|Set-GuideFooter|Test-GuideKey|Read-GuideKey|Register-GuideKey|Unregister-GuideKey|Get-GuideKey|Clear-GuideKey|Invoke-GuideKey|Enter-GuideInteractive|Test-GuideClipboard|Set-GuideClipboard|Test-GuideEnvironment|Test-GuideLayout|Get-GuideLayout|Get-GuideTheme|Resolve-GuideTheme|Get-GuideAvailableThemes|Get-GuideThemeColor|Get-GuideThemeGlyph|Test-GuideTheme|Start-GuideResizeWatcher|Stop-GuideResizeWatcher|Invoke-GuideResize|Invoke-GuideFooterFlash|Resize-GuideWindow" ps/guide.psd1
```

Expected: empty output.

- [ ] **Step 3: Delete files**

```bash
git rm lib/render.ps1 lib/input.ps1 lib/headless.ps1 lib/theme.ps1 lib/layout.ps1 lib/clipboard.ps1 lib/environment.ps1
git rm -r themes
rmdir lib 2>/dev/null || true
```

- [ ] **Step 4: Run unit tests**

```bash
pwsh -NoProfile -File tests/ps/run-all.ps1
bun test tests/server tests/browser
```

Expected: still all green.

- [ ] **Step 5: Commit**

```bash
git commit -m "guide(cleanup): delete dead PS-TUI lib and themes (replaced by Bun web)"
```

### Task 12.2: Delete deprecated test files

**Files:**
- Delete: `tools/guide/tests/test-clipboard.ps1.deprecated`
- Delete: `tools/guide/tests/test-headless.ps1.deprecated`
- Delete: `tools/guide/tests/test-input.ps1.deprecated`
- Delete: `tools/guide/tests/test-layout.ps1.deprecated`
- Delete: `tools/guide/tests/test-render-primitives.ps1.deprecated`
- Delete: `tools/guide/tests/test-render-regions.ps1.deprecated`
- Delete: `tools/guide/tests/test-streaming-snapshot.ps1.deprecated`
- Delete: `tools/guide/tests/test-theme.ps1.deprecated`
- Delete: `tools/guide/tests/manual-smoke.ps1.deprecated`
- Delete: `tools/guide/tests/snapshots/` (recursively)

- [ ] **Step 1: Delete**

```bash
cd tools/guide/tests
git rm test-clipboard.ps1.deprecated test-headless.ps1.deprecated \
       test-input.ps1.deprecated test-layout.ps1.deprecated \
       test-render-primitives.ps1.deprecated test-render-regions.ps1.deprecated \
       test-streaming-snapshot.ps1.deprecated test-theme.ps1.deprecated \
       manual-smoke.ps1.deprecated
git rm -r snapshots
```

- [ ] **Step 2: Verify run-all.ps1 still works**

```bash
pwsh -NoProfile -File tests/ps/run-all.ps1
```

Expected: only the v2 PS suites discovered (~115 cases), all pass.

- [ ] **Step 3: Commit**

```bash
git commit -m "guide(cleanup): remove deprecated TUI test files + snapshots"
```

### Task 12.3: Update README files

**Files:**
- Modify: `tools/guide/README.md`
- Modify: `tools/README.md`

- [ ] **Step 1: Rewrite `tools/guide/README.md`**

```markdown
# guide

Web dashboard + embedded shell for Fellwork CLI tools. A long-lived Bun server
serves a localhost dashboard and brokers `pwsh` and `bash` PTYs over WebSocket.
PowerShell scripts emit plan events to the server over a TCP socket.

## Quick start

\`\`\`bash
# As a plan renderer (auto-spawned by bootstrap.ps1):
bun guide

# Standalone shell mode (no plan):
bun guide --shell

# Headless / CI:
some-emitter | bun guide --headless > result.json
\`\`\`

## CLI

\`\`\`
bun guide [options]
  --shell                      Standalone mode (no plan events expected)
  --plan                       Plan mode (default)
  --default-shell=pwsh|bash    Default shell when no prefix (else OS default)
  --workspace=<path>           cwd for spawned PTYs and history filter
  --port=<n>                   Force HTTP port (default: 7771+)
  --no-open                    Don't auto-launch browser
  --headless                   stdin JSONL → stdout JSON snapshot
  --data-dir=<path>            SQLite DB location override
  --no-history                 Don't write to history (still reads existing)
  -h, --help                   Show help
\`\`\`

## Tests

\`\`\`bash
bun test tests/server tests/browser   # ~165 cases
bun test tests/e2e                     # ~10 cases (Playwright)
pwsh -NoProfile -File tests/ps/run-all.ps1   # ~115 cases
\`\`\`

## Design

See [the v2 design spec](https://github.com/fellwork/bootstrap/blob/main/docs/superpowers/specs/2026-04-29-guide-web-shell-design.md).
```

- [ ] **Step 2: Update `tools/README.md`**

Replace the `derekh/` / `guide/` description with:

```markdown
- **[guide/](guide/)** — Web dashboard + embedded shell. Bun server, xterm.js,
  WebSocket. PowerShell event emitter, SQLite-persisted history. First consumer:
  `fellwork/bootstrap`.
```

- [ ] **Step 3: Commit**

```bash
git add tools/guide/README.md tools/README.md
git commit -m "guide(docs): README rewrite for v2 architecture"
```

### Task 12.4: Final test pass

- [ ] **Step 1: Run everything**

```bash
cd tools/guide
pwsh -NoProfile -File tests/ps/run-all.ps1
bun test tests/server tests/browser
bun test tests/e2e
pwsh -NoProfile -File ../../bootstrap/tests/test-guide-integration.ps1
pwsh -NoProfile -File ../../bootstrap/tests/test-e2e.ps1
```

- [ ] **Step 2: Confirm counts roughly match the design**

| Layer | Target | Actual |
|---|---|---|
| PS unit (tests/ps) | ~115 | _measure_ |
| Bun unit (tests/server) | ~80 | _measure_ |
| Browser (tests/browser) | ~40 | _measure_ |
| e2e (tests/e2e) | ~10 | _measure_ |
| Bootstrap cross-stack | ~30 | _measure_ |

- [ ] **Step 3: One final commit (if any cleanup surfaced)**

```bash
git status
# If clean, no commit.
```

---

## Self-review

After writing the full plan, re-checking against the spec:

**1. Spec coverage** — every spec section maps to at least one task:

| Spec section | Plan tasks |
|---|---|
| File layout | Task 0.1 (package), 0.2 (move PS) |
| Wire protocols (PS→server JSONL) | Task 4.1 (events), 4.3 (TCP wire) |
| Wire protocols (server→browser WS) | Task 3.3 (WsBroker), 4.3 (snapshot), 6.3 (shell-output), 7.2 (history broadcast), 8.1 (history-page) |
| Wire protocols (browser→server WS) | Task 6.3 (shell-line), 8.1 (history-list/search/delete), 8.4 (busy) |
| Multi-line input + prefix | Task 6.5 (routePrefix), 6.6 (paste tests) |
| Concurrency lock | Task 8.4 |
| Bun server internals | Task 3.1 (port), 3.2 (HTTP), 3.3 (WS), 4.3 (state+broadcast), 6.3 (shell), 9.2 (main) |
| PTY manager | Task 6.1 (spawnPty), 6.2 (PtyManager) |
| Sentinel injection | Task 7.1 (lib), 7.2 (wire) |
| Browser auto-launch | Task 9.2 (openBrowser) |
| Quit handling | Task 9.2 (signal handlers); 30s no-clients shutdown deferred (logged below) |
| Browser dashboard layout | Task 5.1 (HTML), 5.2 (CSS) |
| Sidebar render | Task 5.3 (renderPhases/Active/Issues) |
| xterm.js wiring | Task 6.4 (vendor), 6.5 (init) |
| Prompt input | Task 6.5 (wirePrompt), 8.3 (history recall) |
| Click-to-copy | Task 5.5 |
| History sidebar | Task 8.2 (cache), 8.3 (render + filter + recall) |
| `--shell` standalone | Task 9.1 (CLI), 9.4 (sidebar adjust) |
| CLI flags | Task 9.1 |
| SQLite schema | Task 1.1 (schema), 1.2 (history ops), 1.3 (plan_runs), 1.4 (data dir) |
| Privacy / redaction | Task 7.2 (leading-space skip); regex-based redact + `~/.guide/redact.json` deferred (logged below) |
| bootstrap.ps1 + PS module changes | Task 0.2 (move), 2.4 (orchestrator), 10.1 (Invoke-GuidePlan) |
| Testing strategy (5 layers) | Phase 1–8 unit + Phase 11 e2e + Task 10.2 cross-stack |
| Error handling — port fallback | Task 3.1 |
| Error handling — emit failure | Task 10.1 (auto-fall-through to streaming) |
| Error handling — shell crash | Task 6.3 (shell-spawned-error broadcast) |
| Error handling — DB corruption | _deferred_ (logged below) |
| Security (loopback only, CORS, env scrub) | Task 3.2 (127.0.0.1), 6.1 (env scrub); CORS allowlist deferred (logged below) |
| Logging | _deferred_ (logged below) |

**Deferred from v1 (intentional, see "Open follow-ups" in spec):**
- Plan replay UI — schema is ready (`plan_runs.phase_json`), no UI hookup.
- Cross-machine sync — out of scope.
- Raw-mode passthrough for vim/less/fzf — out of scope (see Task 6.1 design choice).
- Plug-in shells (zsh, nu, fish) — only pwsh + bash spawned.
- HTTP/3 — irrelevant for localhost.

**Deferred but not yet planned (gaps to address before v1 ships):**
- 30s no-clients auto-shutdown timer — add as a follow-up task before merge.
- Regex-based redact (`~/.guide/redact.json`) — leading-space skip is in; full pattern engine deferred.
- DB corruption recovery (rename to `.corrupt-<ts>`, fresh DB) — add as a follow-up.
- CORS allowlist (`Access-Control-Allow-Origin: http://127.0.0.1:<port>`) — add to `lib/ws.ts` upgrade path.
- Rolling log file (`<data-dir>/guide.log`) — add a `lib/log.ts` helper.

These gaps are documented and can be filled by adding tasks under a "Phase 13: Hardening" section before merge, or addressed as follow-up PRs after the core ships.

**2. Placeholder scan** — no `TBD`/`TODO`/`fill in` strings in the plan. All steps include either runnable commands or concrete code blocks.

**3. Type consistency check** — verified:
- `ShellKind = 'pwsh' | 'bash'` is consistent across `lib/pty.ts`, `lib/ws.ts`, `server.ts`.
- `PlanSnapshot` shape in `lib/state.ts` matches what the browser's `applySnapshot` consumes.
- WS message `shell` field is uniformly `'pwsh' | 'bash'` (not `shellId` or `kind`); spec self-review caught this divergence and the plan reflects the unified naming.
- `HistoryEntry` columns match between SQL schema (Task 1.1) and TS type (Task 1.2).
- `routePrefix` returns `{ shell, text }` consistently in tests (Tasks 6.5, 6.6) and consumers (`submitPrompt`).

---

## Counts (rough)

- **Tasks:** 49
- **Steps (atomic, ~2-5 min each):** ~245
- **Files created:** ~30 (TS + JS + CSS + HTML + PS + tests + config)
- **Files modified:** ~6 (bootstrap, repos.psd1, integration tests, README, package.json)
- **Files deleted:** ~16 (TUI lib + themes + deprecated tests + snapshots)
- **Tests at end:** ~275 across PS + Bun + browser + e2e + cross-stack

---

## Execution

Plan complete and saved to `bootstrap/docs/superpowers/plans/2026-04-29-guide-web-shell.md`.

**Two execution options:**

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Good for plans this size; keeps each subagent's context focused on one task's files and tests.

2. **Inline Execution** — Execute tasks in this session using executing-plans, batched with checkpoints for review. Better if you want to watch each step land.

Which approach?
