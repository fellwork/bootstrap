# Derekh — Reusable TUI Framework for Fellwork CLI Tools

**Date:** 2026-04-26
**Status:** Approved (pending user review of this written spec)
**Author:** Shane McGuirt + Claude
**Lives in:** `fellwork/tools/derekh/` (new repo, this becomes the 8th in `bootstrap/repos.psd1`)
**First consumer:** `c:/git/fellwork/bootstrap/bootstrap.ps1`
**Related:** `2026-04-25-bootstrap-and-migration-design.md` — bootstrap design that this framework will eventually power

---

## Problem

Bootstrap.ps1 today is a streaming CLI: it prints output top-to-bottom, scrolls, and on a run with multiple warnings the actionable items scroll off-screen before the user can see them. Even with the recent improvements (full ASCII art for warnings, consolidated next-steps section), the user still has to scroll back to read context and copy fix commands.

Beyond bootstrap, future Fellwork CLI tools (deployment scripts, lint runners, migration helpers) will face the same problem. Each tool reinventing its own polished output is wasted effort.

This spec defines **Derekh** — a reusable terminal-UI framework that:

- Provides a structured dashboard layout (phases, active task, issues, header progress) instead of raw streaming
- Stays interactive after work completes so users can read and act on results
- Lets users press number keys to copy fix commands to their clipboard
- Runs headlessly when invoked from CI or by an agent (Claude, etc.) and emits structured JSON results
- Falls back to a streaming renderer in non-TTY environments
- Ships a Stardew-Valley-themed default look ("twilight") with a JSON theme schema for swapping styles

Derekh is the *way* — the path Fellwork CLI tools take to communicate their journey to the user.

---

## Scope

**In scope (v1):**
- New repo `fellwork/tools` containing `derekh/` as a PowerShell module
- Declarative API: consumers describe a `Plan` of phases, framework runs them
- Two phase shapes: `loop` (iterate items, run action per item) and `single` (run one action that may emit multiple alerts)
- Structured action return contract with `Success`, `Message`, `Severity`, `FixCommand`, `Animal`, `LogTail`, `RetryHint`, `Alerts`
- Dashboard layout: header (title + overall progress) / phases pane / active+issues stacked pane / footer (key bindings)
- Twilight Stardew theme + JSON theme schema with auto-discovery of `themes/*.json`
- Three execution modes: TUI (default), headless (JSON to stdout), streaming (non-TTY fallback)
- Interactive after completion: `q` to quit, `1`-`9` to copy fix commands to clipboard
- Resize detection: full re-layout and redraw when terminal dimensions change
- Ctrl+C teardown: alternate buffer dismissed, cursor restored, exit 130
- Bootstrap.ps1 integration: detect `tools/derekh/` and use it on subsequent runs; first run keeps current streaming behavior

**Out of scope (deferred to v2+):**
- Per-issue retry (`-RetryHint` field exists in v1 contract for forward-compat, but no UI binding)
- Focus/navigation between issues (arrow keys, Tab, Enter to expand)
- Theme inheritance / theme composition
- Auto dark/light terminal detection
- Multiple concurrent phases (parallel execution)
- Audio cues / bell on errors
- Mouse support
- Pause/resume mid-run
- TUI snapshot regression tests (deemed not worth the test infrastructure cost)

**Explicit non-goals:**
- Derekh is **not** a general-purpose TUI library (it's not ratatui, not textual). It's a structured-output framework for one specific dashboard layout. Building widgets/composing custom layouts is out of scope.
- Derekh's streaming fallback is **not** a port of bootstrap's existing renderer. Bootstrap keeps its current renderer; derekh has its own. The duplication is intentional (~100 lines, decoupled).
- Bootstrap's existing 658-test suite is **not** affected by this work. Derekh is a separate module with its own test suite.

---

## Architecture

### Repository structure

A new GitHub repo `fellwork/tools` is created as the first home for shared Fellwork CLI infrastructure. Future tools (deploy scripts, lint runners, etc.) will live as siblings of `derekh/`.

```
fellwork/tools/
├── README.md                    # Repo overview, lists each tool
├── .gitignore
└── derekh/
    ├── derekh.psd1              # PowerShell module manifest (version, exports)
    ├── derekh.psm1              # Main module: dot-sources lib/ files, exports public API
    ├── lib/
    │   ├── state.ps1            # The $DerekhState hashtable; phase/issue tracking
    │   ├── plan.ps1             # Plan validation, dispatching loop vs single, action invocation
    │   ├── theme.ps1            # JSON theme loader, Get-DhColor, Get-DhGlyph
    │   ├── layout.ps1           # Pure layout math: (W, H, plan, theme) → rectangles
    │   ├── render.ps1           # Cursor positioning, region clearing, ANSI drawing, resize
    │   ├── input.ps1            # Non-blocking key polling, key→handler dispatch
    │   ├── clipboard.ps1        # Cross-platform copy-to-clipboard
    │   ├── streaming.ps1        # Streaming fallback renderer (no cursor positioning)
    │   └── headless.ps1         # JSON emission for -Headless mode
    ├── themes/
    │   ├── twilight.json        # Default Stardew theme (RGB palette below)
    │   └── README.md            # Theme schema docs
    └── tests/
        ├── test-state.ps1
        ├── test-plan.ps1
        ├── test-theme.ps1
        ├── test-layout.ps1
        ├── test-headless.ps1
        ├── test-streaming-snapshot.ps1
        ├── tests/snapshots/     # Golden files for streaming + headless
        └── run-all.ps1
```

### Module boundaries

Each `lib/*.ps1` file owns ONE thing:

| File | Owns | Doesn't know about |
|---|---|---|
| `derekh.psm1` | Module entry, function exports, dot-sources lib/ | Implementation details |
| `state.ps1` | `$DerekhState` hashtable: phases, current phase, items, issues, alerts, exit code | Drawing, input, themes |
| `plan.ps1` | Plan validation, dispatching `loop` vs `single`, calling user actions, normalizing return values | How state is rendered |
| `theme.ps1` | JSON loading, `Get-DhColor`, `Get-DhGlyph`, ASCII fallback routing | What anything is drawn |
| `layout.ps1` | Pure math: `(W, H, plan, theme) → rectangles` for header/phases/active/issues/footer | Cursor positioning, escape codes |
| `render.ps1` | Cursor positioning, region clearing, applying theme via ANSI, drawing borders, resize handling | Layout decisions, plan logic |
| `input.ps1` | Non-blocking key polling loop, key→handler dispatch, key registration API | What handlers do |
| `clipboard.ps1` | Cross-platform copy-to-clipboard (Win: `Set-Clipboard`, Mac: `pbcopy`, Linux: `xclip`/`wl-copy`) | Anything else |
| `streaming.ps1` | Fallback streaming renderer: sequential `Write-Host` with theme colors | TUI rendering |
| `headless.ps1` | JSON emission for `-Headless` mode | Drawing |

Each file is small (~100-300 lines), testable in isolation, and changeable without ripple effects.

### Bootstrap.ps1 integration

Bootstrap cannot depend on `tools/derekh/` being already cloned (chicken-and-egg: derekh is what bootstrap will install via the repos.psd1 allowlist). Therefore:

1. **First run** — `tools/` doesn't exist; bootstrap uses its existing streaming renderer (the one shipped in commits `0c783f0` through `601006c`). Prints a one-liner at end: `🦉 Future runs will use the Derekh TUI now that tools/ is cloned.`

2. **Subsequent runs** — bootstrap detects `Test-Path ../tools/derekh/derekh.psm1`, imports the module, builds a `$Plan` from its existing phase logic, calls `Invoke-DhPlan -Plan $plan`. Same logical output via richer renderer.

3. **Hostile environment OR derekh broken** — bootstrap wraps `Import-Module` and `Invoke-DhPlan` in `try/catch`. Any failure falls back to bootstrap's own streaming renderer with an error logged to stderr. Bootstrap completes normally.

The streaming-renderer fallback in bootstrap is the **universal safety net**. Derekh has its own separate streaming renderer for its other future consumers.

---

## Data flow & plan schema

### The plan

```powershell
$plan = @{
    Title    = "Fellwork Bootstrap"
    Subtitle = "12:34:56"
    Theme    = "twilight"
    Phases   = @(
        @{
            Name   = "Cloning repositories"
            Type   = "loop"
            Items  = $reposArray
            Action = {
                param($item)
                # User code; returns @{ Success; Message; FixCommand?; ... }
                # Throw is treated as failure with exception info captured
            }
        }
        @{
            Name   = "Bootstrap prerequisites"
            Type   = "single"
            Action = {
                # Returns @{ Success; Alerts = @(...) } — single-shot phases can
                # return multiple alerts even if Success = $true
            }
        }
    )
}

Invoke-DhPlan -Plan $plan
```

### Action return contract

The shape every action returns (most fields optional):

```powershell
@{
    Success    = $true | $false           # Did the action complete?
    Message    = "..."                    # One-liner for display
    Severity   = "info|warning|fail"      # Optional; defaults from Success
    FixCommand = "..."                    # Optional; copy-pasteable
    Animal     = "owl"                    # Optional; framework picks default by Severity
    LogTail    = @("line 1", "line 2")    # Optional; last N lines of relevant output
    RetryHint  = @{                       # Optional; v1 stores but doesn't bind UI
        Action = $scriptblock
        Args   = $hashtable
    }
    Alerts     = @(                       # Optional; even on Success, surface concerns
        @{
            Severity   = "warning|info"
            Message    = "..."
            FixCommand = "..."
        }
    )
}
```

The `New-DhResult` and `New-DhAlert` helpers build these without typo'ing field names.

### State flow

```
PlanStarted
  ├─ Phase 1 (loop, N items)
  │    ├─ Item 1: Pending → Running → Ok
  │    ├─ Item 2: Pending → Running → Ok
  │    └─ Item N: Pending → Running → Failed → emits Issue
  ├─ Phase 2 (single)
  │    └─ Running → Ok (Alerts emitted as Issues if present)
  └─ ... etc
PlanFinished
  └─ enters interactive mode; user navigates issues, presses keys, eventually quits
```

### Three event streams

The renderer subscribes to three event streams from `state.ps1`, each driving one region of the dashboard:

1. **Phase events** — `phase-started`, `phase-progress`, `phase-completed` → drive the **left phases pane**
2. **Issue events** — `issue-emitted` → drive the **right issues pane** (appended chronologically)
3. **Active events** — `active-changed` → drive the **active sub-pane** (currently-running item + spinner)

Clean separation: each region of the dashboard has exactly one input source.

---

## Theme schema

**File location:** `derekh/themes/twilight.json` (default) plus auto-discovery for any `*.json` in the same directory.

**Theme override resolution order:** `-Theme` CLI flag → plan's `Theme` field → built-in default (`twilight`).

### Schema structure

```json
{
  "$schema": "../theme-schema.json",
  "name": "twilight",
  "description": "Stardew Valley dusk palette — purple sky, lantern gold, mint accents",

  "palette": {
    "bg":        "#1a1830",
    "bg_alt":    "#2b2040",
    "fg":        "#e0d4ec",
    "frame":     "#b48fd4",
    "title":     "#f8e0a0",
    "accent":    "#f8b870",
    "ok":        "#88e8a8",
    "warn":      "#f8b870",
    "fail":      "#ec7878",
    "running":   "#88c8f8",
    "pending":   "#6a5878",
    "dim":       "#9888a8",
    "chip_bg":   "#382850"
  },

  "glyphs": {
    "phase_pending":   "○",
    "phase_running":   "◐",
    "phase_ok":        "✓",
    "phase_fail":      "✗",
    "phase_warn":      "⚠",
    "spinner_frames":  ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"],
    "progress_filled": "█",
    "progress_empty":  "░",
    "progress_partial": "▒",
    "frame_tl": "╭", "frame_tr": "╮",
    "frame_bl": "╰", "frame_br": "╯",
    "frame_h":  "─", "frame_v":  "│",
    "frame_t":  "┬", "frame_b":  "┴", "frame_l": "├", "frame_r": "┤",
    "icon_title":  "🌙",
    "icon_done":   "✨",
    "icon_alert":  "⚠"
  },

  "sections": {
    "header": {
      "title_format": "{icon_title} {title}",
      "show_subtitle": true,
      "show_progress_bar": true,
      "progress_bar_width": 20
    },
    "phases_pane": {
      "min_width": 24,
      "max_width": 32,
      "show_phase_progress": true
    },
    "active_pane": {
      "show_spinner": true,
      "show_elapsed": true
    },
    "issues_pane": {
      "max_visible": 8,
      "auto_scroll": true,
      "show_indices": true
    },
    "footer": {
      "show_keybinds": true,
      "keybind_format": "[{key}] {label}"
    }
  },

  "ascii_fallback": {
    "enabled": true,
    "phase_pending":   "[ ]",
    "phase_running":   "[~]",
    "phase_ok":        "[+]",
    "phase_fail":      "[!]",
    "phase_warn":      "[?]",
    "spinner_frames":  ["|","/","-","\\"],
    "progress_filled": "#",
    "progress_empty":  "-",
    "frame_tl": "+", "frame_tr": "+",
    "frame_bl": "+", "frame_br": "+",
    "frame_h":  "-", "frame_v":  "|",
    "frame_t":  "+", "frame_b":  "+", "frame_l": "+", "frame_r": "+"
  }
}
```

### Why this shape

- **Three top-level concerns separated**: palette (just colors), glyphs (just characters), sections (structural choices like widths/visibility).
- **Glyph fallbacks built-in**: `ascii_fallback` mirrors the structure so `--ascii` mode just routes lookups to the fallback table.
- **Section widths are constraints**: `min_width` / `max_width` lets the layout engine adapt to terminal size. The `layout.ps1` module picks the largest valid width that fits.
- **No segments/templates** (departure from Oh-My-Posh): OMP's segment system is for prompts where you compose left-to-right segments dynamically. Derekh's UI is structurally fixed (header / phases / active / issues / footer), so segments don't add value.

---

## Public API

All functions follow PowerShell verb-noun convention with `Dh` embedded in the noun.

### Primary entry point

```powershell
Invoke-DhPlan
    -Plan       <hashtable>          # required
    [-Theme     <string>]            # optional, override plan's Theme
    [-Headless]                      # emit JSON to stdout, no TUI
    [-NoTui]                         # streaming-renderer fallback (also auto if non-TTY)
    [-Ascii]                         # force ASCII fallback glyphs
    -> exit code 0/1/2 (matches bootstrap conventions)
```

### Plan builders

```powershell
New-DhPlan        -Title <string> [-Subtitle <string>] [-Theme <string>]
Add-DhLoopPhase   -Plan <hashtable> -Name <string> -Items <array> -Action <scriptblock>
Add-DhSinglePhase -Plan <hashtable> -Name <string> -Action <scriptblock>
```

These return the modified plan so they can be chained or used imperatively.

### Result/alert builders

```powershell
New-DhResult     -Success <bool> [-Message <string>] [-FixCommand <string>] [-Severity <string>] [-LogTail <array>] [-RetryHint <hashtable>] [-Animal <string>]
New-DhAlert      -Severity <string> -Message <string> [-FixCommand <string>]
```

### Diagnostics

```powershell
Get-DhTheme       [-Name <string>]      # returns resolved theme hashtable
Get-DhVersion                            # returns version string from .psd1
Test-DhEnvironment                       # returns capability check: TTY/UTF-8/Truecolor/MinSize
```

### Reading flow (illustrative)

```powershell
$plan = New-DhPlan -Title "My Tool" -Subtitle (Get-Date -Format HH:mm:ss)
$plan = Add-DhLoopPhase -Plan $plan -Name "Cloning repos" -Items $repos -Action {
    param($r)
    $result = git clone "https://github.com/fellwork/$r.git" 2>&1
    if ($LASTEXITCODE -ne 0) {
        return New-DhResult -Success $false -Message "$r failed" -FixCommand "git clone https://github.com/fellwork/$r.git" -LogTail @($result | Select-Object -Last 5)
    }
    return New-DhResult -Success $true -Message "$r cloned"
}
Invoke-DhPlan -Plan $plan
```

Reads as English: "I create a new Dh plan, add a Dh loop phase, invoke the plan, and Derekh shows me the way."

---

## Execution modes

`Test-DhEnvironment` is called at the start of `Invoke-DhPlan` to decide which mode to run.

```
Consumer script
    │ builds $plan (declarative)
    ▼
Invoke-DhPlan
    │
    ├─ Test-DhEnvironment → decides: tui | streaming | headless
    │
    ├─ Headless path (-Headless flag):
    │   ├─ plan.ps1 runs phases → state.ps1 records everything
    │   └─ headless.ps1 serializes state to JSON → stdout → exit
    │
    ├─ Streaming path (-NoTui or non-TTY auto-detect):
    │   └─ plan.ps1 runs phases, streaming.ps1 prints as events fire → exit
    │
    └─ TUI path (default, requires TTY + min size + color):
        ├─ render.ps1 enters alternate buffer, draws initial frame
        ├─ event loop:
        │   ├─ input.ps1 polls keys (non-blocking)
        │   ├─ plan.ps1 advances next action → emits state events
        │   ├─ render.ps1 redraws affected regions only
        │   └─ resize check (every 200ms via runspace) → full re-layout if changed
        ├─ plan completes → render footer "press q to quit, 1-9 to copy"
        └─ wait for q/Esc → tear down → exit
```

### Region-redraw model

The TUI uses partial redraws to avoid flicker:
- **Initial render** fills the whole screen
- **Subsequent updates** only touch their region: phase status changes → redraw the phases pane only; new issue → redraw the issues pane only; spinner tick → redraw just the spinner glyph
- Cursor moves to the changed cell, writes the new char, moves on — no full screen clears

---

## Error handling, resize, and cleanup

### Resize handling

- A background polling thread (PowerShell runspace) checks `$Host.UI.RawUI.WindowSize` every 200ms during the event loop.
- If width or height changed: pause the spinner, recompute layout via `layout.ps1`, full re-render, resume.
- Implementation in `lib/render.ps1` — single `Invoke-DhResize` function called on demand.
- If new size is below minimum (60 cols × 15 rows): pause, show centered message "Terminal too small — resize to at least 60×15", wait for resize back up. Pressing Ctrl+C exits gracefully.

### Ctrl+C / SIGINT handling

- Register `[Console]::CancelKeyPress` handler at TUI startup.
- On Ctrl+C: cancel any in-flight action, restore alternate screen buffer (`\e[?1049l`), restore cursor visibility (`\e[?25h`), exit with code 130 (standard SIGINT exit code).
- Graceful: user gets their normal terminal back, no garbage left on screen.

### Action exception handling

- Every user action runs inside `try { & $action } catch { ... }` in `lib/plan.ps1`.
- An uncaught exception becomes an automatic failure result:
  ```powershell
  @{ Success=$false; Message=$_.Exception.Message; LogTail=@($_.ScriptStackTrace) }
  ```
- Plan continues to the next phase (errors are collected, not fatal — same behavior as bootstrap's "continue and report").
- Action exceptions are reported with **🦝 raccoon** by default (config-mismatch animal — fits "user code did something unexpected").

### TUI teardown contract

Every code path that exits the TUI (normal completion, Ctrl+C, fatal error, unrecoverable terminal-too-small) MUST call `Stop-DhTui` which:

1. Restores cursor visibility
2. Exits alternate screen buffer
3. Resets all ANSI state (`\e[0m`)
4. Re-enables echo if disabled

`Stop-DhTui` is registered as a `trap` at the top of `Invoke-DhPlan` so even unexpected exceptions clean up.

---

## Interactive mode (post-completion)

After the plan finishes (success or failure), the TUI does NOT auto-exit. Instead:

- The screen freezes with full results visible
- The footer changes to show key bindings: `[q] quit  [1-9] copy fix command`
- Issues in the right pane each get a numeric prefix (`[1]`, `[2]`, ...) up to issue 9. Issues 10+ are still listed but without a hotkey; the user must rerun and address one of the first 9 before later ones become reachable. (This is intentional: 9 is the natural keyboard limit, and a real run with 10+ issues should usually be partially fixed and rerun anyway.)
- User presses `q` (or `Esc` or `Enter`) to exit cleanly with the appropriate exit code
- User presses a digit `1`-`9` to copy that issue's `FixCommand` to the system clipboard via `clipboard.ps1`
  - Footer flashes "Copied to clipboard" for ~1 second after a successful copy
  - If issue N has no `FixCommand`, footer flashes "No command to copy" instead

This is the **debug cycle** improvement: the user reads issues, presses 1, 2, 3 to grab fix commands, alt-tabs to a terminal to run them.

---

## Headless mode

Invoked via `Invoke-DhPlan -Headless` or detected automatically when stdout is not a TTY and the consumer didn't pass `-NoTui`.

### Output format

JSON to stdout, structured exactly like the internal state:

```json
{
  "version": "1.0.0",
  "title": "Fellwork Bootstrap",
  "subtitle": "12:34:56",
  "started_at": "2026-04-26T12:34:56Z",
  "completed_at": "2026-04-26T12:35:42Z",
  "exit_code": 1,
  "phases": [
    {
      "name": "Cloning repositories",
      "type": "loop",
      "status": "ok",
      "items": [
        {"name": "api", "status": "ok", "message": "already cloned"},
        {"name": "web", "status": "ok", "message": "already cloned"}
      ]
    }
  ],
  "issues": [
    {
      "phase": "Other prerequisites",
      "severity": "warning",
      "message": "wrangler is not installed",
      "fix_command": "npm install -g wrangler",
      "animal": "owl",
      "log_tail": null
    }
  ],
  "summary": {
    "phases_total": 6,
    "phases_ok": 6,
    "phases_failed": 0,
    "issues_total": 1,
    "warnings": 1,
    "failures": 0
  }
}
```

### Use cases

- **Claude / agents driving bootstrap** — pipe `Invoke-DhPlan -Headless | ConvertFrom-Json` and inspect structured results
- **CI integration** — capture results to a file for archival/reporting
- **Test automation** — derekh's own E2E tests use headless mode for deterministic assertions
- **Bootstrap E2E migration** — bootstrap's existing test-e2e suite can migrate from stdout parsing to headless JSON parsing

### Stability guarantee

The JSON shape is part of the v1 public contract. Field renames or removals require a major-version bump.

---

## Testing strategy

Mirrors bootstrap's existing 658-test suite pattern.

### Test layers

- **Unit tests** — `state.ps1`, `theme.ps1`, `layout.ps1`, `plan.ps1` — pure functions, deterministic, no TUI
- **Headless integration tests** — feed fixed plans to `Invoke-DhPlan -Headless`, parse stdout JSON, assert structure. Catches plan-execution bugs without TUI infrastructure.
- **Streaming snapshot tests** — golden files for the streaming-renderer output (deterministic with frozen inputs)
- **Headless snapshot tests** — golden files for known plan→JSON outputs
- **Layout invariants** — pure-math tests on `layout.ps1`: any (W, H, plan) → all rectangles fit, no overlap, sums match
- **Theme tests** — load each theme JSON, verify all required keys present, validate color hex format
- **Manual TUI smoke test** — a `tests/manual-smoke.ps1` script run by hand to eyeball actual rendering. The TUI itself is hard to assert programmatically; we accept this and test everything around it instead.

### Coverage target

~600-800 tests total, matching bootstrap's per-module density.

---

## Bootstrap.ps1 integration plan

### Changes to `repos.psd1`

Add `tools` as the 8th repo:

```powershell
@{
    name        = 'tools'
    org         = 'fellwork'
    branch      = 'main'
    description = 'Shared CLI tooling — Derekh TUI framework + future tools'
    structureCheck = @('derekh/derekh.psd1')
    envExamples = @()
}
```

### Changes to `bootstrap.ps1`

Add a derekh-detection block at the top of the script:

```powershell
$derekhModule = Join-Path (Split-Path -Parent $scriptRoot) "tools/derekh/derekh.psm1"
$useDerekh = $false

if (Test-Path $derekhModule) {
    try {
        Import-Module $derekhModule -Force -ErrorAction Stop
        $useDerekh = $true
    } catch {
        Write-Host "(Derekh module exists but failed to load: $_. Falling back to streaming renderer.)" -ForegroundColor DarkYellow
    }
}

if ($useDerekh) {
    # Build $plan from the existing phase logic and call Invoke-DhPlan
    Invoke-DhPlan -Plan $plan
    exit $LASTEXITCODE
} else {
    # Existing streaming-renderer code (no changes)
}
```

### Refactoring boundary

Bootstrap's existing renderer code stays untouched. The integration is **additive**: a new code path that activates when derekh is available, falling through to the existing path when it isn't.

This means the derekh integration can ship as a single small PR that adds the detection block + plan-building, without disturbing the 658 existing tests.

---

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| TUI rendering is fragile and hard to test | Pure-function decomposition (state/layout/theme are testable in isolation); manual smoke test for the actual TUI; headless mode exercises the same plan-execution path with full assertion coverage |
| Resize handling is genuinely tricky in PowerShell | Prototype early in plan; if runspace-based polling proves unreliable, fall back to checking on every event loop iteration (slightly less responsive but simpler) |
| Cross-platform clipboard varies | `Set-Clipboard` works on Windows; mac/Linux fall back to `pbcopy`/`xclip`/`wl-copy` with detection. Worst case: clipboard fails silently with "press to copy" still flashed (degraded but not broken). |
| Theme schema evolves and old themes break | Theme version field at top of JSON; loader rejects mismatched versions with clear error message. Document upgrade path in `themes/README.md`. |
| Bootstrap's first run can't show the new UI | Accepted: first run uses existing streaming renderer. Subsequent runs auto-upgrade. The owl pro-tip mentions this. |
| Derekh module breaks for some users (PS version, encoding, etc.) | `try/catch` around Import-Module + Invoke-DhPlan in bootstrap. Any failure logs to stderr and falls through to the old renderer. Bootstrap completes normally. |
| Adding a new public repo (`fellwork/tools`) is overhead | Accepted: the framework is meant to be reusable, an internal-only repo is the right place for it. README in `tools/` clearly states the scope. |

---

## Open questions

None at spec time. All design decisions resolved during brainstorming.

---

## Implementation order

The plan that follows this spec will sequence implementation like this:

1. **Phase A — Repo scaffolding**: create `fellwork/tools` repo, derekh module manifest, empty lib/ files, README, .gitignore
2. **Phase B — Pure-function core**: `state.ps1`, `theme.ps1`, `layout.ps1`, `plan.ps1` + their unit tests (most of the framework's logic, all testable without a TUI)
3. **Phase C — Theme system**: write `themes/twilight.json`, theme loader tests
4. **Phase D — Headless mode**: `headless.ps1` + integration tests (headless mode exercises the entire plan-execution path with deterministic JSON output)
5. **Phase E — Streaming fallback**: `streaming.ps1` + snapshot tests
6. **Phase F — TUI core**: `render.ps1` + `input.ps1` + `clipboard.ps1` (the actual TUI; manual smoke testing)
7. **Phase G — Resize + interactive mode**: resize polling, post-completion key bindings
8. **Phase H — Bootstrap integration**: add `tools` to `repos.psd1`, add derekh detection block to `bootstrap.ps1`, add E2E tests that exercise both paths

Each phase produces working, testable software on its own. Phases B-E can produce a fully headless-functional Derekh before the TUI exists. Phase F adds the visual layer; phases G-H polish and integrate.
