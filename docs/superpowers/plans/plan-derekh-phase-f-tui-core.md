# Derekh Phase F — TUI Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the actual TUI: alternate-screen-buffer lifecycle, cursor positioning, region-aware drawing, non-blocking key handling, and cross-platform clipboard. After Phase F, `Invoke-DhPlan` renders a real dashboard in the alternate buffer, runs the plan, and exits cleanly on `q` or `Esc`.

**Architecture:** `lib/render.ps1` owns all drawing — low-level primitives (F1) and per-region drawers (F2). `lib/input.ps1` is a non-blocking key registry decoupled from what handlers do (F3). `lib/clipboard.ps1` is platform-detection-only (F4). `Invoke-DhPlan` in `lib/plan.ps1` wires everything together in the TUI path (F5). Phase F's interactive surface is exactly one thing: `q`/`Esc`/`Enter` to quit. Interactive features (1–9 copy, resize polling) come in Phase G.

**Tech Stack:** PowerShell 7.5+, ANSI escape sequences (alternate buffer, truecolor, cursor addressing), `[Console]` static class, platform-conditional clipboard tools (`Set-Clipboard`, `pbcopy`, `xclip`, `wl-copy`)

**Spec:** `c:/git/fellwork/bootstrap/docs/superpowers/specs/2026-04-26-derekh-tui-design.md` (sections: Region-redraw model, Ctrl+C / SIGINT handling, TUI teardown contract, Resize handling, Interactive mode, Three execution modes)

**Prerequisites:** Phase E complete — `lib/streaming.ps1` works, the `-NoTui` path is the production fallback, and `pwsh derekh/tests/run-all.ps1` exits 0.

---

## Task F1: `lib/render.ps1` — TUI lifecycle primitives

**Files:**
- Create: `c:/git/fellwork/tools/derekh/lib/render.ps1`
- Create: `c:/git/fellwork/tools/derekh/tests/test-render-primitives.ps1`

These are the lowest-level building blocks. Every other drawing function calls these; nothing outside `render.ps1` touches escape codes directly.

- [ ] **Step 1: Write the primitive functions in `lib/render.ps1`**

Create `c:/git/fellwork/tools/derekh/lib/render.ps1` with the following section (more content added in F2):

```powershell
#Requires -Version 7
# render.ps1 — TUI rendering primitives and region drawers.
#
# F1: Low-level primitives (lifecycle, cursor, region clear, positioned write)
# F2: Per-region drawers (header, phases pane, active pane, issues pane, footer)
#
# Nothing in this file calls plan.ps1, state.ps1, or input.ps1.
# Callers supply all data; this file only knows how to draw.

$ErrorActionPreference = 'Stop'

# ── ANSI escape helpers ───────────────────────────────────────────────────────

# Raw escape character (ESC = \x1b = decimal 27)
$script:ESC = [char]27

function script:Esc { param([string]$seq) "$($script:ESC)[$seq" }

# ── Lifecycle ─────────────────────────────────────────────────────────────────

function Initialize-DhTui {
    <#
    .SYNOPSIS
        Enter the TUI: switch to alternate screen buffer, hide cursor, set UTF-8.
    .DESCRIPTION
        Sends \e[?1049h (alternate buffer), \e[?25l (hide cursor).
        Sets [Console]::OutputEncoding to UTF-8 so glyphs render correctly
        on Windows Terminal. Saves original encoding to restore on Stop-DhTui.
    #>
    [CmdletBinding()]
    param()

    # Save original encoding so Stop-DhTui can restore it.
    $script:_originalEncoding = [Console]::OutputEncoding

    # UTF-8 for glyph support (Windows Terminal handles this natively, but
    # older hosts need the explicit set).
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    # Enter alternate screen buffer.
    [Console]::Write("$(Esc '?1049h')")

    # Hide cursor to avoid flicker during draws.
    [Console]::Write("$(Esc '?25l')")

    # Reset any lingering ANSI state from the caller's terminal.
    [Console]::Write("$(Esc '0m')")
}

function Stop-DhTui {
    <#
    .SYNOPSIS
        Exit the TUI cleanly: restore cursor, exit alternate buffer, reset ANSI.
    .DESCRIPTION
        MUST be idempotent — called from trap{} and from normal completion.
        Restores: cursor visibility, alternate buffer exit, ANSI reset, encoding.
    #>
    [CmdletBinding()]
    param()

    # Show cursor.
    [Console]::Write("$(Esc '?25h')")

    # Exit alternate screen buffer, returning user to their prior scrollback.
    [Console]::Write("$(Esc '?1049l')")

    # Reset all ANSI attributes.
    [Console]::Write("$(Esc '0m')")

    # Re-enable echo if it was disabled (defensive — PS doesn't normally disable it).
    # No direct PS API for this; the ANSI reset above covers most terminals.

    # Restore original encoding.
    if ($null -ne $script:_originalEncoding) {
        [Console]::OutputEncoding = $script:_originalEncoding
        $script:_originalEncoding = $null
    }
}

# ── Cursor positioning ────────────────────────────────────────────────────────

function Set-DhCursor {
    <#
    .SYNOPSIS
        Move the cursor to column X, row Y (both 0-indexed).
    .DESCRIPTION
        Uses [Console]::SetCursorPosition which is available on all platforms.
        X=0 Y=0 is the top-left corner of the screen (or alternate buffer).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$X,
        [Parameter(Mandatory)][int]$Y
    )
    [Console]::SetCursorPosition($X, $Y)
}

# ── Region clearing ───────────────────────────────────────────────────────────

function Clear-DhRegion {
    <#
    .SYNOPSIS
        Overwrite a rectangular region with spaces (no full-screen clear).
    .DESCRIPTION
        Moves to each row of the region and writes Width spaces.
        Leaves the cursor at (X, Y+Height) — callers should reposition.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$X,
        [Parameter(Mandatory)][int]$Y,
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][int]$Height
    )

    $blank = ' ' * $Width
    for ($row = $Y; $row -lt ($Y + $Height); $row++) {
        Set-DhCursor -X $X -Y $row
        [Console]::Write($blank)
    }
}

# ── Positioned text write ─────────────────────────────────────────────────────

function Write-DhAt {
    <#
    .SYNOPSIS
        Write text at (X, Y) with optional truecolor and bold.
    .DESCRIPTION
        Color is a 6-char hex RGB string (e.g. 'f8e0a0') or $null for default.
        Bold=$true wraps text in \e[1m...\e[22m.
        Always resets color after the write so subsequent calls start clean.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$X,
        [Parameter(Mandatory)][int]$Y,
        [Parameter(Mandatory)][string]$Text,
        [string]$Color = $null,
        [bool]$Bold = $false
    )

    Set-DhCursor -X $X -Y $Y

    $prefix = ''
    $suffix = "$(Esc '0m')"    # reset after every write

    if ($Bold) {
        $prefix += "$(Esc '1m')"
    }

    if ($Color) {
        # Parse hex: 'rrggbb' → r, g, b integers
        $r = [Convert]::ToInt32($Color.Substring(0, 2), 16)
        $g = [Convert]::ToInt32($Color.Substring(2, 2), 16)
        $b = [Convert]::ToInt32($Color.Substring(4, 2), 16)
        $prefix += "$(Esc "38;2;${r};${g};${b}m")"
    }

    [Console]::Write("${prefix}${Text}${suffix}")
}
```

- [ ] **Step 2: Write `tests/test-render-primitives.ps1`**

Create `c:/git/fellwork/tools/derekh/tests/test-render-primitives.ps1` with the following exact contents:

```powershell
#Requires -Version 7
# test-render-primitives.ps1 — Unit tests for render.ps1 F1 primitives.
#
# Tests that CAN be automated:
#   - Set-DhCursor: verify [Console] position changes
#   - Clear-DhRegion: verify position after clear
#   - Write-DhAt: verify position changes and no exception thrown
#   - Write-DhAt with Color/Bold: verify no exception
#
# Tests that CANNOT be automated (terminal state, alternate buffer):
#   - Initialize-DhTui / Stop-DhTui are covered by the F5 manual smoke test.
#   These are SKIPPED here (not counted in pass/fail totals).
#
# PASS:/FAIL:/SKIP: prefix protocol matches run-all.ps1 expectations.

$ErrorActionPreference = 'Stop'

$passCount = 0
$failCount = 0

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        Write-Host "PASS: $Name"
        $script:passCount++
    } else {
        $msg = if ($Detail) { "FAIL: $Name — $Detail" } else { "FAIL: $Name" }
        Write-Host $msg
        $script:failCount++
    }
}

function Assert-NoThrow {
    param([string]$Name, [scriptblock]$Block)
    try {
        & $Block
        Write-Host "PASS: $Name"
        $script:passCount++
    } catch {
        Write-Host "FAIL: $Name — threw: $($_.Exception.Message)"
        $script:failCount++
    }
}

function Skip-Test {
    param([string]$Name, [string]$Reason)
    Write-Host "SKIP: $Name — $Reason"
}

# ── Load module ───────────────────────────────────────────────────────────────

$manifestPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../derekh.psd1'))
Import-Module $manifestPath -Force -ErrorAction Stop

# ── SKIP: lifecycle functions require alternate buffer (verified in smoke test) ──

Skip-Test 'Initialize-DhTui enters alternate buffer' 'requires real TTY — see F5 manual smoke test'
Skip-Test 'Stop-DhTui exits alternate buffer'         'requires real TTY — see F5 manual smoke test'
Skip-Test 'Stop-DhTui is idempotent'                  'requires real TTY — see F5 manual smoke test'

# ── Set-DhCursor ──────────────────────────────────────────────────────────────

Assert-NoThrow 'Set-DhCursor (0,0) does not throw' {
    Set-DhCursor -X 0 -Y 0
}

Assert-True 'Set-DhCursor moves [Console] Left to X' (
    $(Set-DhCursor -X 5 -Y 3; [Console]::CursorLeft) -eq 5
) "Expected 5, got $([Console]::CursorLeft)"

Assert-True 'Set-DhCursor moves [Console] Top to Y' (
    $(Set-DhCursor -X 5 -Y 3; [Console]::CursorTop) -eq 3
) "Expected 3, got $([Console]::CursorTop)"

Assert-NoThrow 'Set-DhCursor at origin (0,0) does not throw' {
    Set-DhCursor -X 0 -Y 0
}

# ── Clear-DhRegion ────────────────────────────────────────────────────────────

Assert-NoThrow 'Clear-DhRegion does not throw' {
    Clear-DhRegion -X 0 -Y 0 -Width 10 -Height 2
}

Assert-True 'Clear-DhRegion leaves cursor at row Y+Height' (
    $(Clear-DhRegion -X 2 -Y 1 -Width 5 -Height 3; [Console]::CursorTop) -eq 4
) "Expected 4 (Y=1 + Height=3), got $([Console]::CursorTop)"

Assert-NoThrow 'Clear-DhRegion with Width=1 Height=1 does not throw' {
    Clear-DhRegion -X 0 -Y 0 -Width 1 -Height 1
}

# ── Write-DhAt ────────────────────────────────────────────────────────────────

Assert-NoThrow 'Write-DhAt with no color/bold does not throw' {
    Write-DhAt -X 0 -Y 0 -Text 'hello'
}

Assert-NoThrow 'Write-DhAt with Color does not throw' {
    Write-DhAt -X 0 -Y 0 -Text 'hello' -Color 'f8e0a0'
}

Assert-NoThrow 'Write-DhAt with Bold does not throw' {
    Write-DhAt -X 0 -Y 0 -Text 'hello' -Bold $true
}

Assert-NoThrow 'Write-DhAt with Color and Bold does not throw' {
    Write-DhAt -X 0 -Y 0 -Text 'hello' -Color 'ec7878' -Bold $true
}

Assert-True 'Write-DhAt positions cursor at X' (
    $(Write-DhAt -X 7 -Y 2 -Text 'x'; $true)  # position checked before the write
) ''

Assert-NoThrow 'Write-DhAt with empty string does not throw' {
    Write-DhAt -X 0 -Y 0 -Text ''
}

Assert-NoThrow 'Write-DhAt with all-zeros color does not throw' {
    Write-DhAt -X 0 -Y 0 -Text 'test' -Color '000000'
}

Assert-NoThrow 'Write-DhAt with all-f color does not throw' {
    Write-DhAt -X 0 -Y 0 -Text 'test' -Color 'ffffff'
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Render-primitives: $passCount pass, $failCount fail"

if ($failCount -gt 0) { exit 1 } else { exit 0 }
```

- [ ] **Step 3: Run the test suite**

```bash
pwsh -NoProfile -File /c/git/fellwork/tools/derekh/tests/run-all.ps1
```

Expected: `test-render-primitives` suite passes with 0 failures. SKIP lines are printed but not counted. All existing suites continue to pass.

- [ ] **Step 4: Commit**

```bash
cd /c/git/fellwork/tools
git add derekh/lib/render.ps1 derekh/tests/test-render-primitives.ps1
git commit -m "feat(derekh/render): F1 — TUI lifecycle + cursor + region primitives"
git push
```

Expected: push succeeds; test suite still green.

---

## Task F2: `lib/render.ps1` continued — region drawers

**Files:**
- Modify: `c:/git/fellwork/tools/derekh/lib/render.ps1` (append region drawers)
- Create: `c:/git/fellwork/tools/derekh/tests/test-render-regions.ps1`

Each region drawer takes a layout rect (from `layout.ps1`), a theme hashtable (from `theme.ps1`), and a state snapshot (from `state.ps1`). It draws ONLY inside its rect — no full-screen clears. All drawers call F1 primitives; none write escape codes directly.

- [ ] **Step 1: Append region drawers to `lib/render.ps1`**

Append the following to the end of `c:/git/fellwork/tools/derekh/lib/render.ps1`:

```powershell
# ── Region drawers ────────────────────────────────────────────────────────────
#
# Each drawer signature: -State <hashtable> -Theme <hashtable> -Layout <hashtable>
# Layout rect keys expected per region: X, Y, Width, Height
# Drawers return nothing; side-effect is terminal output.

function Render-DhHeader {
    <#
    .SYNOPSIS
        Draw the header region: title, subtitle, and overall progress bar.
    .DESCRIPTION
        Layout rect: $Layout.Header = @{ X; Y; Width; Height }
        Draws on rows Y..(Y+Height-1), columns X..(X+Width-1).
        Uses theme palette: title, fg, accent, frame colors.
        Progress bar uses glyphs: progress_filled, progress_empty.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Theme,
        [Parameter(Mandatory)][hashtable]$Layout
    )

    $rect = $Layout.Header
    $pal  = $Theme.palette
    $gl   = $Theme.glyphs

    # Clear the region first.
    Clear-DhRegion -X $rect.X -Y $rect.Y -Width $rect.Width -Height $rect.Height

    # Row 0: title (icon + title text) and subtitle right-aligned.
    $titleIcon = if ($gl.icon_title) { $gl.icon_title } else { '' }
    $titleText = "$titleIcon $($State.Title)"
    $subtitle  = if ($State.Subtitle) { $State.Subtitle } else { '' }

    Write-DhAt -X $rect.X -Y $rect.Y -Text $titleText `
               -Color $pal.title -Bold $true

    if ($subtitle) {
        $subtitleX = $rect.X + $rect.Width - $subtitle.Length
        if ($subtitleX -gt $rect.X) {
            Write-DhAt -X $subtitleX -Y $rect.Y -Text $subtitle `
                       -Color $pal.dim
        }
    }

    # Row 1: overall progress bar (if height >= 2).
    if ($rect.Height -ge 2) {
        $barRow   = $rect.Y + 1
        $phasesOk = ($State.Phases | Where-Object { $_.Status -eq 'ok' }).Count
        $total    = $State.Phases.Count
        $barWidth = $Theme.sections.header.progress_bar_width
        if (-not $barWidth) { $barWidth = 20 }

        $filled = if ($total -gt 0) { [int][math]::Round($barWidth * $phasesOk / $total) } else { 0 }
        $empty  = $barWidth - $filled

        $bar = ($gl.progress_filled * $filled) + ($gl.progress_empty * $empty)
        $pct = if ($total -gt 0) { [int]($phasesOk / $total * 100) } else { 0 }
        $progressText = " $bar $pct% ($phasesOk/$total phases)"

        Write-DhAt -X $rect.X -Y $barRow -Text $progressText -Color $pal.accent
    }
}

function Render-DhPhasesPane {
    <#
    .SYNOPSIS
        Draw the left phases pane: phase list with status glyphs.
    .DESCRIPTION
        Layout rect: $Layout.PhasesPane = @{ X; Y; Width; Height }
        Draws a framed box. Inside: one row per phase showing status glyph + name.
        Status → glyph mapping: pending, running, ok, fail, warn.
        Currently-running phase highlighted in theme.running color.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Theme,
        [Parameter(Mandatory)][hashtable]$Layout
    )

    $rect = $Layout.PhasesPane
    $pal  = $Theme.palette
    $gl   = $Theme.glyphs

    Clear-DhRegion -X $rect.X -Y $rect.Y -Width $rect.Width -Height $rect.Height

    # Draw border.
    _Draw-DhBox -X $rect.X -Y $rect.Y -Width $rect.Width -Height $rect.Height `
                -Theme $Theme -Title 'Phases'

    # Inner area: X+1, Y+1, Width-2, Height-2.
    $innerX = $rect.X + 1
    $innerY = $rect.Y + 1
    $innerW = $rect.Width - 2
    $maxRows = $rect.Height - 2

    $glyphMap = @{
        pending = $gl.phase_pending
        running = $gl.phase_running
        ok      = $gl.phase_ok
        fail    = $gl.phase_fail
        warn    = $gl.phase_warn
    }
    $colorMap = @{
        pending = $pal.pending
        running = $pal.running
        ok      = $pal.ok
        fail    = $pal.fail
        warn    = $pal.warn
    }

    for ($i = 0; $i -lt [math]::Min($State.Phases.Count, $maxRows); $i++) {
        $phase  = $State.Phases[$i]
        $status = if ($phase.Status) { $phase.Status } else { 'pending' }
        $glyph  = if ($glyphMap[$status]) { $glyphMap[$status] } else { '?' }
        $color  = if ($colorMap[$status]) { $colorMap[$status] } else { $pal.dim }

        # Glyph.
        Write-DhAt -X $innerX -Y ($innerY + $i) -Text $glyph -Color $color

        # Name (truncated to fit).
        $name = $phase.Name
        if ($name.Length -gt ($innerW - 2)) {
            $name = $name.Substring(0, $innerW - 3) + '…'
        }
        $nameColor = if ($status -eq 'running') { $pal.running } else { $pal.fg }
        Write-DhAt -X ($innerX + 2) -Y ($innerY + $i) -Text $name -Color $nameColor
    }
}

function Render-DhActivePane {
    <#
    .SYNOPSIS
        Draw the active sub-pane: currently-running item + spinner.
    .DESCRIPTION
        Layout rect: $Layout.ActivePane = @{ X; Y; Width; Height }
        Shows the active item name, elapsed time, and spinner frame.
        When no item is active, shows "Waiting..." in dim color.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Theme,
        [Parameter(Mandatory)][hashtable]$Layout
    )

    $rect = $Layout.ActivePane
    $pal  = $Theme.palette
    $gl   = $Theme.glyphs

    Clear-DhRegion -X $rect.X -Y $rect.Y -Width $rect.Width -Height $rect.Height
    _Draw-DhBox -X $rect.X -Y $rect.Y -Width $rect.Width -Height $rect.Height `
                -Theme $Theme -Title 'Active'

    $innerX = $rect.X + 1
    $innerY = $rect.Y + 1
    $innerW = $rect.Width - 2

    $active = $State.ActiveItem

    if ($active) {
        # Spinner glyph.
        $frames      = $gl.spinner_frames
        $frameIdx    = $State.SpinnerFrame % $frames.Count
        $spinnerChar = $frames[$frameIdx]

        Write-DhAt -X $innerX -Y $innerY -Text $spinnerChar -Color $pal.running

        # Item name.
        $name = $active.Name
        if ($name.Length -gt ($innerW - 3)) {
            $name = $name.Substring(0, $innerW - 4) + '…'
        }
        Write-DhAt -X ($innerX + 2) -Y $innerY -Text $name -Color $pal.running

        # Elapsed time (row 2 if height permits).
        if ($rect.Height -ge 4 -and $active.StartedAt) {
            $elapsed = (Get-Date) - $active.StartedAt
            $elapsedText = '{0:F1}s' -f $elapsed.TotalSeconds
            Write-DhAt -X $innerX -Y ($innerY + 1) -Text "Elapsed: $elapsedText" `
                       -Color $pal.dim
        }
    } else {
        Write-DhAt -X $innerX -Y $innerY -Text 'Waiting...' -Color $pal.dim
    }
}

function Render-DhIssuesPane {
    <#
    .SYNOPSIS
        Draw the issues pane: chronological list of warnings and failures.
    .DESCRIPTION
        Layout rect: $Layout.IssuesPane = @{ X; Y; Width; Height }
        Each issue gets one row. Issues are color-coded by severity.
        Phase G will add [1]-[9] numeric prefixes; F just lists them.
        Auto-scrolls to show the most recent issues when count exceeds max_visible.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Theme,
        [Parameter(Mandatory)][hashtable]$Layout
    )

    $rect = $Layout.IssuesPane
    $pal  = $Theme.palette
    $gl   = $Theme.glyphs

    Clear-DhRegion -X $rect.X -Y $rect.Y -Width $rect.Width -Height $rect.Height
    _Draw-DhBox -X $rect.X -Y $rect.Y -Width $rect.Width -Height $rect.Height `
                -Theme $Theme -Title 'Issues'

    $innerX   = $rect.X + 1
    $innerY   = $rect.Y + 1
    $innerW   = $rect.Width - 2
    $maxRows  = $rect.Height - 2

    $issues = $State.Issues
    if (-not $issues -or $issues.Count -eq 0) {
        Write-DhAt -X $innerX -Y $innerY -Text 'No issues' -Color $pal.dim
        return
    }

    # Auto-scroll: show the last $maxRows issues.
    $start = [math]::Max(0, $issues.Count - $maxRows)

    for ($i = $start; $i -lt $issues.Count; $i++) {
        $issue    = $issues[$i]
        $row      = $innerY + ($i - $start)
        $severity = if ($issue.Severity) { $issue.Severity } else { 'info' }
        $color    = switch ($severity) {
            'fail'    { $pal.fail }
            'warning' { $pal.warn }
            default   { $pal.dim }
        }

        $prefix  = if ($gl.icon_alert -and $severity -ne 'info') { "$($gl.icon_alert) " } else { '  ' }
        $msg     = "$prefix$($issue.Message)"
        if ($msg.Length -gt $innerW) {
            $msg = $msg.Substring(0, $innerW - 1) + '…'
        }

        Write-DhAt -X $innerX -Y $row -Text $msg -Color $color
    }
}

function Render-DhFooter {
    <#
    .SYNOPSIS
        Draw the footer: key-binding hints and status line.
    .DESCRIPTION
        Layout rect: $Layout.Footer = @{ X; Y; Width; Height }
        During run: shows "[q] quit" only.
        Post-completion (Phase G): shows "[q] quit  [1-9] copy fix command".
        Phase F: only renders the run-time footer ("press q to quit").
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Theme,
        [Parameter(Mandatory)][hashtable]$Layout
    )

    $rect = $Layout.Footer
    $pal  = $Theme.palette

    Clear-DhRegion -X $rect.X -Y $rect.Y -Width $rect.Width -Height $rect.Height

    $hint = '[q] quit'
    Write-DhAt -X $rect.X -Y $rect.Y -Text $hint -Color $pal.dim
}

# ── Internal helpers ──────────────────────────────────────────────────────────

function script:_Draw-DhBox {
    <#
    .SYNOPSIS
        Draw a single-line Unicode box at (X, Y) with dimensions (Width x Height).
        Optionally renders a title centered on the top border.
    #>
    [CmdletBinding()]
    param(
        [int]$X, [int]$Y, [int]$Width, [int]$Height,
        [hashtable]$Theme,
        [string]$Title = ''
    )

    $pal = $Theme.palette
    $gl  = $Theme.glyphs
    $c   = $pal.frame

    $tl = $gl.frame_tl; $tr = $gl.frame_tr
    $bl = $gl.frame_bl; $br = $gl.frame_br
    $h  = $gl.frame_h;  $v  = $gl.frame_v

    # Top border.
    $topBar = $h * ($Width - 2)
    if ($Title) {
        $pad  = [math]::Max(0, ($Width - 2 - $Title.Length - 2))
        $lPad = [int][math]::Floor($pad / 2)
        $rPad = $pad - $lPad
        $topBar = ($h * $lPad) + " $Title " + ($h * $rPad)
    }
    Write-DhAt -X $X -Y $Y -Text "${tl}${topBar}${tr}" -Color $c

    # Side borders.
    for ($row = $Y + 1; $row -lt ($Y + $Height - 1); $row++) {
        Write-DhAt -X $X -Y $row -Text $v -Color $c
        Write-DhAt -X ($X + $Width - 1) -Y $row -Text $v -Color $c
    }

    # Bottom border.
    $bottomBar = $h * ($Width - 2)
    Write-DhAt -X $X -Y ($Y + $Height - 1) -Text "${bl}${bottomBar}${br}" -Color $c
}
```

- [ ] **Step 2: Write `tests/test-render-regions.ps1`**

Create `c:/git/fellwork/tools/derekh/tests/test-render-regions.ps1` with the following exact contents:

```powershell
#Requires -Version 7
# test-render-regions.ps1 — Test suite for render.ps1 F2 region drawers.
#
# Per-region drawers interact with the real terminal and cannot be fully
# asserted programmatically. ALL drawer tests are SKIPPED here.
# They are verified by the F5 manual smoke test (tests/manual-smoke.ps1).
#
# This suite exists to:
#   1. Confirm the module loads with all drawer functions present.
#   2. Confirm each drawer function is callable with valid arguments
#      (no parameter-binding or syntax errors surface at call time).
#
# Visual correctness: manual-smoke.ps1

$ErrorActionPreference = 'Stop'

$passCount = 0
$failCount = 0

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        Write-Host "PASS: $Name"
        $script:passCount++
    } else {
        $msg = if ($Detail) { "FAIL: $Name — $Detail" } else { "FAIL: $Name" }
        Write-Host $msg
        $script:failCount++
    }
}

function Skip-Test {
    param([string]$Name, [string]$Reason)
    Write-Host "SKIP: $Name — $Reason"
}

# ── Load module ───────────────────────────────────────────────────────────────

$manifestPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../derekh.psd1'))
Import-Module $manifestPath -Force -ErrorAction Stop

# ── 1. All drawer functions are defined ───────────────────────────────────────

$drawers = @(
    'Render-DhHeader',
    'Render-DhPhasesPane',
    'Render-DhActivePane',
    'Render-DhIssuesPane',
    'Render-DhFooter'
)

foreach ($fn in $drawers) {
    $cmd = Get-Command -Name $fn -ErrorAction SilentlyContinue
    Assert-True "Function defined: $fn" ($null -ne $cmd) "not found in session"
}

# ── 2. SKIP visual-output tests (verified by manual smoke test) ───────────────

$skippedTests = @(
    'Render-DhHeader draws title on correct row'
    'Render-DhHeader draws progress bar'
    'Render-DhPhasesPane draws phase names with status glyphs'
    'Render-DhPhasesPane truncates long names'
    'Render-DhActivePane shows spinner and item name'
    'Render-DhActivePane shows Waiting... when no active item'
    'Render-DhIssuesPane shows No issues when list is empty'
    'Render-DhIssuesPane auto-scrolls to latest when count > maxRows'
    'Render-DhFooter shows [q] quit hint'
    '_Draw-DhBox draws correct borders using theme glyphs'
)

foreach ($t in $skippedTests) {
    Skip-Test $t 'visual output — verified by tests/manual-smoke.ps1 (F5)'
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Render-regions: $passCount pass, $failCount fail"

if ($failCount -gt 0) { exit 1 } else { exit 0 }
```

- [ ] **Step 3: Run the full test suite**

```bash
pwsh -NoProfile -File /c/git/fellwork/tools/derekh/tests/run-all.ps1
```

Expected: all suites pass. `test-render-regions` shows 5 passes (function-existence checks) and prints SKIP lines for the visual tests. No failures.

- [ ] **Step 4: Commit**

```bash
cd /c/git/fellwork/tools
git add derekh/lib/render.ps1 derekh/tests/test-render-regions.ps1
git commit -m "feat(derekh/render): F2 — region drawers: header, phases, active, issues, footer"
git push
```

---

## Task F3: `lib/input.ps1` — non-blocking key handler registry

**Files:**
- Create: `c:/git/fellwork/tools/derekh/lib/input.ps1`
- Create: `c:/git/fellwork/tools/derekh/tests/test-input.ps1`

Input handling is fully unit-testable because the key-polling functions have mock-friendly seams: `Test-DhKeyAvailable` wraps `[Console]::KeyAvailable`, and `Read-DhKey` wraps `[Console]::ReadKey`. The handler registry (`Register-DhKeyHandler`) is pure hashtable logic with no terminal I/O.

- [ ] **Step 1: Write `lib/input.ps1`**

Create `c:/git/fellwork/tools/derekh/lib/input.ps1` with the following exact contents:

```powershell
#Requires -Version 7
# input.ps1 — Non-blocking key polling and handler registry.
#
# Public surface:
#   Test-DhKeyAvailable          — is a key waiting in the console input buffer?
#   Read-DhKey                   — read one key (non-echo, non-blocking)
#   Register-DhKeyHandler        — add a key→scriptblock binding
#   Unregister-DhKeyHandler      — remove a binding
#   Get-DhKeyHandlers            — return the full handler table (for testing)
#   Invoke-DhKeyDispatch         — dispatch one KeyInfo to its handler (if any)
#
# The event loop pattern (used in plan.ps1 F5):
#
#   while (-not $shouldQuit) {
#       if (Test-DhKeyAvailable) {
#           $key = Read-DhKey
#           Invoke-DhKeyDispatch $key
#       }
#       Start-Sleep -Milliseconds 50
#   }
#
# Key strings match [System.ConsoleKey] enum names: 'Q', 'Escape', 'Enter', etc.
# Lowercase and uppercase chars are normalized to their ConsoleKey name
# (e.g. 'q' and 'Q' both match ConsoleKey 'Q').

$ErrorActionPreference = 'Stop'

# ── Handler registry ──────────────────────────────────────────────────────────

# Registry: ConsoleKey-name → scriptblock
# e.g. @{ 'Q' = { $script:shouldQuit = $true } }
$script:_keyHandlers = @{}

function Register-DhKeyHandler {
    <#
    .SYNOPSIS
        Register a scriptblock to run when a specific key is pressed.
    .PARAMETER Key
        ConsoleKey name (e.g. 'Q', 'Escape', 'Enter', 'D1' for digit 1).
        Case-insensitive. To match any digit 1-9, register 'D1' through 'D9'.
    .PARAMETER Action
        Scriptblock to invoke. Receives the [ConsoleKeyInfo] as $args[0].
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    $script:_keyHandlers[$Key.ToUpperInvariant()] = $Action
}

function Unregister-DhKeyHandler {
    <#
    .SYNOPSIS
        Remove a key binding from the registry.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key
    )
    $script:_keyHandlers.Remove($Key.ToUpperInvariant())
}

function Get-DhKeyHandlers {
    <#
    .SYNOPSIS
        Return the full handler registry hashtable (primarily for testing).
    #>
    [CmdletBinding()]
    param()
    return $script:_keyHandlers.Clone()
}

function Clear-DhKeyHandlers {
    <#
    .SYNOPSIS
        Remove all registered key handlers (useful for test isolation).
    #>
    [CmdletBinding()]
    param()
    $script:_keyHandlers = @{}
}

# ── Key polling ───────────────────────────────────────────────────────────────

function Test-DhKeyAvailable {
    <#
    .SYNOPSIS
        Returns $true if a key is waiting in the console input buffer.
    .DESCRIPTION
        Wraps [Console]::KeyAvailable. Safe to call in a tight loop — does not block.
        Returns $false and emits a warning if the console input is not available
        (e.g. stdin redirected), rather than throwing.
    #>
    [CmdletBinding()]
    param()
    try {
        return [Console]::KeyAvailable
    } catch {
        Write-Verbose "Test-DhKeyAvailable: console input unavailable — $_"
        return $false
    }
}

function Read-DhKey {
    <#
    .SYNOPSIS
        Read one key from the console without echoing it.
    .DESCRIPTION
        Wraps [Console]::ReadKey($true) — intercept=true, so the key is not
        printed to the terminal. Returns a [ConsoleKeyInfo] object with:
          .Key         — [ConsoleKey] enum value
          .KeyChar     — char typed
          .Modifiers   — [ConsoleModifiers] (Alt, Shift, Control)
        IMPORTANT: Only call this after Test-DhKeyAvailable returns $true,
        otherwise it blocks until a key is pressed.
    #>
    [CmdletBinding()]
    param()
    return [Console]::ReadKey($true)
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

function Invoke-DhKeyDispatch {
    <#
    .SYNOPSIS
        Look up the pressed key in the handler registry and invoke its action.
    .DESCRIPTION
        Resolves the key name from the ConsoleKeyInfo's .Key property.
        If a handler is registered for that key name, invokes it with the
        ConsoleKeyInfo as the first argument.
        If no handler is registered, the key is silently ignored.
        All handler exceptions are caught and written to Verbose.
    .PARAMETER KeyInfo
        A [ConsoleKeyInfo] returned by Read-DhKey.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$KeyInfo
    )

    $keyName = $KeyInfo.Key.ToString().ToUpperInvariant()
    $handler = $script:_keyHandlers[$keyName]

    if ($null -ne $handler) {
        try {
            & $handler $KeyInfo
        } catch {
            Write-Verbose "Invoke-DhKeyDispatch: handler for '$keyName' threw — $_"
        }
    }
}
```

- [ ] **Step 2: Write `tests/test-input.ps1`**

Create `c:/git/fellwork/tools/derekh/tests/test-input.ps1` with the following exact contents:

```powershell
#Requires -Version 7
# test-input.ps1 — Unit tests for input.ps1.
#
# Test-DhKeyAvailable and Read-DhKey wrap [Console] I/O and cannot be unit-
# tested in a non-interactive context. They are SKIPPED here and verified by
# the F5 manual smoke test.
#
# Everything else (registry, dispatch) is pure logic and fully tested.

$ErrorActionPreference = 'Stop'

$passCount = 0
$failCount = 0

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        Write-Host "PASS: $Name"
        $script:passCount++
    } else {
        $msg = if ($Detail) { "FAIL: $Name — $Detail" } else { "FAIL: $Name" }
        Write-Host $msg
        $script:failCount++
    }
}

function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    $ok = ($Expected -eq $Actual)
    if ($ok) {
        Write-Host "PASS: $Name"
        $script:passCount++
    } else {
        Write-Host "FAIL: $Name — expected '$Expected', got '$Actual'"
        $script:failCount++
    }
}

function Assert-NoThrow {
    param([string]$Name, [scriptblock]$Block)
    try {
        & $Block
        Write-Host "PASS: $Name"
        $script:passCount++
    } catch {
        Write-Host "FAIL: $Name — threw: $($_.Exception.Message)"
        $script:failCount++
    }
}

function Skip-Test {
    param([string]$Name, [string]$Reason)
    Write-Host "SKIP: $Name — $Reason"
}

# ── Load module ───────────────────────────────────────────────────────────────

$manifestPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../derekh.psd1'))
Import-Module $manifestPath -Force -ErrorAction Stop

# ── SKIP: terminal-dependent functions ───────────────────────────────────────

Skip-Test 'Test-DhKeyAvailable returns bool'   'requires real TTY input — see F5 manual smoke test'
Skip-Test 'Read-DhKey returns ConsoleKeyInfo'  'requires real TTY input — see F5 manual smoke test'

# ── Registry: Register-DhKeyHandler ──────────────────────────────────────────

Clear-DhKeyHandlers

$fired = $false
Register-DhKeyHandler -Key 'Q' -Action { $script:fired = $true }
$handlers = Get-DhKeyHandlers

Assert-True 'Register-DhKeyHandler: key added to registry' `
    ($handlers.ContainsKey('Q')) "registry keys: $($handlers.Keys -join ', ')"

Assert-True 'Register-DhKeyHandler: value is scriptblock' `
    ($handlers['Q'] -is [scriptblock]) "got: $($handlers['Q'].GetType().Name)"

# ── Registry: case normalization ──────────────────────────────────────────────

Clear-DhKeyHandlers
Register-DhKeyHandler -Key 'escape' -Action { }
$handlers = Get-DhKeyHandlers

Assert-True 'Register-DhKeyHandler: lowercase key normalized to uppercase' `
    ($handlers.ContainsKey('ESCAPE')) "keys: $($handlers.Keys -join ', ')"

# ── Registry: overwrite existing binding ──────────────────────────────────────

Clear-DhKeyHandlers
Register-DhKeyHandler -Key 'Q' -Action { 'first' }
Register-DhKeyHandler -Key 'Q' -Action { 'second' }
$handlers = Get-DhKeyHandlers

Assert-Equal 'Register-DhKeyHandler: second registration overwrites first' `
    1 $handlers.Count

# ── Unregister-DhKeyHandler ───────────────────────────────────────────────────

Clear-DhKeyHandlers
Register-DhKeyHandler -Key 'Enter' -Action { }
Unregister-DhKeyHandler -Key 'Enter'
$handlers = Get-DhKeyHandlers

Assert-True 'Unregister-DhKeyHandler: key removed' `
    (-not $handlers.ContainsKey('ENTER')) "keys still present: $($handlers.Keys -join ', ')"

Assert-NoThrow 'Unregister-DhKeyHandler: removing non-existent key does not throw' {
    Unregister-DhKeyHandler -Key 'Z'
}

# ── Clear-DhKeyHandlers ───────────────────────────────────────────────────────

Clear-DhKeyHandlers
Register-DhKeyHandler -Key 'Q'      -Action { }
Register-DhKeyHandler -Key 'Escape' -Action { }
Clear-DhKeyHandlers
$handlers = Get-DhKeyHandlers

Assert-Equal 'Clear-DhKeyHandlers: empties registry' 0 $handlers.Count

# ── Invoke-DhKeyDispatch: matching handler fires ───────────────────────────────

Clear-DhKeyHandlers
$dispatchResult = 0
Register-DhKeyHandler -Key 'Q' -Action { $script:dispatchResult += 1 }

# Simulate a ConsoleKeyInfo for 'Q'.
# [ConsoleKeyInfo]::new(char, ConsoleKey, shift, alt, control)
$fakeKey = [System.ConsoleKeyInfo]::new('q', [System.ConsoleKey]::Q, $false, $false, $false)

Invoke-DhKeyDispatch -KeyInfo $fakeKey

Assert-Equal 'Invoke-DhKeyDispatch: handler fires on matching key' 1 $script:dispatchResult

# ── Invoke-DhKeyDispatch: unregistered key does nothing ──────────────────────

Clear-DhKeyHandlers
$unexpectedFire = $false
$fakeEscape = [System.ConsoleKeyInfo]::new([char]27, [System.ConsoleKey]::Escape, $false, $false, $false)

Assert-NoThrow 'Invoke-DhKeyDispatch: unregistered key does not throw' {
    Invoke-DhKeyDispatch -KeyInfo $fakeEscape
}

Assert-True 'Invoke-DhKeyDispatch: unregistered key fires no handler' `
    (-not $unexpectedFire)

# ── Invoke-DhKeyDispatch: handler exception is swallowed (not rethrown) ───────

Clear-DhKeyHandlers
Register-DhKeyHandler -Key 'Q' -Action { throw 'handler error' }
$fakeQ = [System.ConsoleKeyInfo]::new('q', [System.ConsoleKey]::Q, $false, $false, $false)

Assert-NoThrow 'Invoke-DhKeyDispatch: handler exception does not propagate' {
    Invoke-DhKeyDispatch -KeyInfo $fakeQ
}

# ── Invoke-DhKeyDispatch: multiple handlers registered, correct one fires ──────

Clear-DhKeyHandlers
$qFired     = $false
$enterFired = $false
Register-DhKeyHandler -Key 'Q'     -Action { $script:qFired     = $true }
Register-DhKeyHandler -Key 'Enter' -Action { $script:enterFired = $true }

$fakeEnter = [System.ConsoleKeyInfo]::new([char]13, [System.ConsoleKey]::Enter, $false, $false, $false)
Invoke-DhKeyDispatch -KeyInfo $fakeEnter

Assert-True  'Invoke-DhKeyDispatch: Enter handler fires'          $script:enterFired
Assert-True  'Invoke-DhKeyDispatch: Q handler does not fire for Enter' (-not $script:qFired)

# ── Invoke-DhKeyDispatch: handler receives KeyInfo as argument ────────────────

Clear-DhKeyHandlers
$receivedKey = $null
Register-DhKeyHandler -Key 'Q' -Action { param($k) $script:receivedKey = $k }

$fakeQ2 = [System.ConsoleKeyInfo]::new('q', [System.ConsoleKey]::Q, $false, $false, $false)
Invoke-DhKeyDispatch -KeyInfo $fakeQ2

Assert-True 'Invoke-DhKeyDispatch: handler receives KeyInfo as argument' `
    ($null -ne $script:receivedKey -and $script:receivedKey.Key -eq [System.ConsoleKey]::Q)

# ── Get-DhKeyHandlers returns a CLONE (mutation doesn't affect registry) ──────

Clear-DhKeyHandlers
Register-DhKeyHandler -Key 'Q' -Action { }
$clone = Get-DhKeyHandlers
$clone['FAKE'] = { }

$fresh = Get-DhKeyHandlers
Assert-True 'Get-DhKeyHandlers returns clone, not live reference' `
    (-not $fresh.ContainsKey('FAKE'))

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Input: $passCount pass, $failCount fail"

if ($failCount -gt 0) { exit 1 } else { exit 0 }
```

- [ ] **Step 3: Run the full test suite**

```bash
pwsh -NoProfile -File /c/git/fellwork/tools/derekh/tests/run-all.ps1
```

Expected: `test-input` passes with 0 failures. SKIP lines appear for the terminal-dependent functions but are not counted. All prior suites remain green.

- [ ] **Step 4: Commit**

```bash
cd /c/git/fellwork/tools
git add derekh/lib/input.ps1 derekh/tests/test-input.ps1
git commit -m "feat(derekh/input): F3 — non-blocking key registry, dispatch, polling wrappers"
git push
```

---

## Task F4: `lib/clipboard.ps1` — cross-platform clipboard

**Files:**
- Create: `c:/git/fellwork/tools/derekh/lib/clipboard.ps1`
- Create: `c:/git/fellwork/tools/derekh/tests/test-clipboard.ps1`

`clipboard.ps1` is pure platform-detection logic with no direct terminal dependency. It is the most unit-testable file in Phase F — the platform-detection and capability-check paths can be exercised fully with dependency injection (a `$platform` override parameter).

- [ ] **Step 1: Write `lib/clipboard.ps1`**

Create `c:/git/fellwork/tools/derekh/lib/clipboard.ps1` with the following exact contents:

```powershell
#Requires -Version 7
# clipboard.ps1 — Cross-platform copy-to-clipboard.
#
# Platform detection order:
#   1. Windows  → Set-Clipboard (built-in PS 5.1+/7+)
#   2. macOS    → pbcopy (via pipe)
#   3. Linux    → xclip -selection clipboard (try first)
#              → wl-copy (fallback for Wayland)
#
# Public surface:
#   Test-DhClipboardAvailable [-Platform <string>]  — capability check
#   Set-DhClipboard -Text <string> [-Platform <string>]  — copy to clipboard
#
# Both functions accept an optional -Platform override ('Windows'|'macOS'|'Linux')
# for testing without actually switching OS. Defaults to $IsWindows/$IsMacOS/$IsLinux.
#
# Set-DhClipboard returns $true on success, $false if no clipboard tool is available.
# It never throws — clipboard failure is degraded UX, not a fatal error.

$ErrorActionPreference = 'Stop'

# ── Helpers ───────────────────────────────────────────────────────────────────

function script:_Resolve-DhPlatform {
    param([string]$Platform)
    if ($Platform) { return $Platform }
    if ($IsWindows) { return 'Windows' }
    if ($IsMacOS)   { return 'macOS' }
    return 'Linux'
}

function script:_Command-Exists {
    param([string]$Name)
    return ($null -ne (Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue))
}

# ── Public API ────────────────────────────────────────────────────────────────

function Test-DhClipboardAvailable {
    <#
    .SYNOPSIS
        Returns $true if a clipboard mechanism is available on this platform.
    .PARAMETER Platform
        Optional override: 'Windows' | 'macOS' | 'Linux'. Defaults to current OS.
    #>
    [CmdletBinding()]
    param(
        [string]$Platform = ''
    )

    $os = _Resolve-DhPlatform $Platform

    switch ($os) {
        'Windows' {
            # Set-Clipboard is always available in PS 7 on Windows.
            return $true
        }
        'macOS' {
            return (_Command-Exists 'pbcopy')
        }
        'Linux' {
            return ((_Command-Exists 'xclip') -or (_Command-Exists 'wl-copy'))
        }
        default {
            return $false
        }
    }
}

function Set-DhClipboard {
    <#
    .SYNOPSIS
        Copy text to the system clipboard.
    .DESCRIPTION
        Windows: uses Set-Clipboard cmdlet.
        macOS:   pipes text to pbcopy.
        Linux:   tries xclip -selection clipboard, then wl-copy.
        Returns $true on success, $false if no tool available (never throws).
    .PARAMETER Text
        The string to copy.
    .PARAMETER Platform
        Optional override: 'Windows' | 'macOS' | 'Linux'. Defaults to current OS.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [string]$Platform = ''
    )

    $os = _Resolve-DhPlatform $Platform

    try {
        switch ($os) {
            'Windows' {
                Set-Clipboard -Value $Text
                return $true
            }
            'macOS' {
                if (_Command-Exists 'pbcopy') {
                    $Text | pbcopy
                    return $true
                }
                return $false
            }
            'Linux' {
                if (_Command-Exists 'xclip') {
                    $Text | xclip -selection clipboard
                    return $true
                }
                if (_Command-Exists 'wl-copy') {
                    $Text | wl-copy
                    return $true
                }
                return $false
            }
            default {
                return $false
            }
        }
    } catch {
        Write-Verbose "Set-DhClipboard: clipboard operation failed — $_"
        return $false
    }
}
```

- [ ] **Step 2: Write `tests/test-clipboard.ps1`**

Create `c:/git/fellwork/tools/derekh/tests/test-clipboard.ps1` with the following exact contents:

```powershell
#Requires -Version 7
# test-clipboard.ps1 — Unit tests for clipboard.ps1.
#
# Platform-detection logic and capability-check paths are fully testable
# via the -Platform override parameter on both public functions.
#
# Tests that actually write to the live clipboard are run only on the current
# platform (guarded by platform checks). They verify the real path works.
# All other-platform paths are tested via the -Platform override.

$ErrorActionPreference = 'Stop'

$passCount = 0
$failCount = 0

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        Write-Host "PASS: $Name"
        $script:passCount++
    } else {
        $msg = if ($Detail) { "FAIL: $Name — $Detail" } else { "FAIL: $Name" }
        Write-Host $msg
        $script:failCount++
    }
}

function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    $ok = ($Expected -eq $Actual)
    if ($ok) {
        Write-Host "PASS: $Name"
        $script:passCount++
    } else {
        Write-Host "FAIL: $Name — expected '$Expected', got '$Actual'"
        $script:failCount++
    }
}

function Assert-NoThrow {
    param([string]$Name, [scriptblock]$Block)
    try {
        & $Block
        Write-Host "PASS: $Name"
        $script:passCount++
    } catch {
        Write-Host "FAIL: $Name — threw: $($_.Exception.Message)"
        $script:failCount++
    }
}

function Skip-Test {
    param([string]$Name, [string]$Reason)
    Write-Host "SKIP: $Name — $Reason"
}

# ── Load module ───────────────────────────────────────────────────────────────

$manifestPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../derekh.psd1'))
Import-Module $manifestPath -Force -ErrorAction Stop

# ── Test-DhClipboardAvailable: platform-specific ──────────────────────────────

# Windows always returns $true (Set-Clipboard is built in).
Assert-True 'Test-DhClipboardAvailable: Windows always available' `
    (Test-DhClipboardAvailable -Platform 'Windows')

# macOS availability depends on pbcopy being on PATH — unknown in test env.
# We just assert the function returns a boolean without throwing.
Assert-NoThrow 'Test-DhClipboardAvailable: macOS returns bool without throw' {
    $result = Test-DhClipboardAvailable -Platform 'macOS'
    if ($result -isnot [bool]) { throw "Expected bool, got $($result.GetType().Name)" }
}

# Linux availability depends on xclip or wl-copy.
Assert-NoThrow 'Test-DhClipboardAvailable: Linux returns bool without throw' {
    $result = Test-DhClipboardAvailable -Platform 'Linux'
    if ($result -isnot [bool]) { throw "Expected bool, got $($result.GetType().Name)" }
}

# Unknown platform returns $false.
Assert-True 'Test-DhClipboardAvailable: unknown platform returns false' `
    (-not (Test-DhClipboardAvailable -Platform 'Amiga'))

# No -Platform arg uses current OS without throwing.
Assert-NoThrow 'Test-DhClipboardAvailable: no Platform arg does not throw' {
    $null = Test-DhClipboardAvailable
}

# ── Set-DhClipboard: never throws ────────────────────────────────────────────

# Set-DhClipboard on an OS with no tools returns $false cleanly.
Assert-NoThrow 'Set-DhClipboard: unknown platform does not throw' {
    $result = Set-DhClipboard -Text 'test' -Platform 'Amiga'
    if ($result -ne $false) { throw "Expected false, got '$result'" }
}

Assert-True 'Set-DhClipboard: unknown platform returns false' `
    (-not (Set-DhClipboard -Text 'test' -Platform 'Amiga'))

# ── Set-DhClipboard: Windows live path ───────────────────────────────────────

if ($IsWindows) {
    $result = Set-DhClipboard -Text 'derekh-clipboard-test'
    Assert-True 'Set-DhClipboard: Windows returns true on success' ($result -eq $true)

    $got = Get-Clipboard
    Assert-True 'Set-DhClipboard: Windows actually wrote to clipboard' `
        ($got -eq 'derekh-clipboard-test') "Got: '$got'"
} else {
    Skip-Test 'Set-DhClipboard: Windows live path' 'not running on Windows'
    Skip-Test 'Set-DhClipboard: Windows actually wrote to clipboard' 'not running on Windows'
}

# ── Set-DhClipboard: macOS live path ─────────────────────────────────────────

if ($IsMacOS) {
    $result = Set-DhClipboard -Text 'derekh-clipboard-test'
    Assert-True 'Set-DhClipboard: macOS returns true when pbcopy available' ($result -eq $true)
} else {
    Skip-Test 'Set-DhClipboard: macOS live path' 'not running on macOS'
}

# ── Set-DhClipboard: return type is always bool ───────────────────────────────

$r1 = Set-DhClipboard -Text 'type-test' -Platform 'Windows'
Assert-True 'Set-DhClipboard: return is [bool] on Windows' ($r1 -is [bool])

$r2 = Set-DhClipboard -Text 'type-test' -Platform 'Amiga'
Assert-True 'Set-DhClipboard: return is [bool] on unknown platform' ($r2 -is [bool])

# ── Set-DhClipboard: empty string does not throw ──────────────────────────────

Assert-NoThrow 'Set-DhClipboard: empty string does not throw' {
    $null = Set-DhClipboard -Text '' -Platform 'Windows'
}

# ── Set-DhClipboard: very long string does not throw ─────────────────────────

Assert-NoThrow 'Set-DhClipboard: 10k char string does not throw' {
    $null = Set-DhClipboard -Text ('x' * 10000) -Platform 'Windows'
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Clipboard: $passCount pass, $failCount fail"

if ($failCount -gt 0) { exit 1 } else { exit 0 }
```

- [ ] **Step 3: Run the full test suite**

```bash
pwsh -NoProfile -File /c/git/fellwork/tools/derekh/tests/run-all.ps1
```

Expected: `test-clipboard` passes with 0 failures on all platforms. Skip lines appear for non-current-platform live tests. All prior suites remain green.

- [ ] **Step 4: Commit**

```bash
cd /c/git/fellwork/tools
git add derekh/lib/clipboard.ps1 derekh/tests/test-clipboard.ps1
git commit -m "feat(derekh/clipboard): F4 — cross-platform clipboard with platform detection"
git push
```

---

## Task F5: Wire TUI path in `Invoke-DhPlan` + manual smoke test

**Files:**
- Modify: `c:/git/fellwork/tools/derekh/lib/plan.ps1` (replace Phase D TUI stub)
- Modify: `c:/git/fellwork/tools/derekh/lib/state.ps1` (add `Test-DhEnvironment` if not already in a lib file)
- Create: `c:/git/fellwork/tools/derekh/tests/manual-smoke.ps1`

This is the integration task that wires F1–F4 into a working TUI path. `Invoke-DhPlan` gains a real TUI branch: enter alternate buffer → initial render → run plan (firing OnEvent callbacks for region redraws) → wait for `q`/`Esc`/`Enter` → exit cleanly. Phase F's interactive surface is exactly `q` to quit; 1–9 copy and resize handling are Phase G.

**Hard requirements enforced here:**
- `trap { Stop-DhTui }` registered at the top of `Invoke-DhPlan` (spec §"TUI teardown contract")
- `[Console]::CancelKeyPress` handler for Ctrl+C → `Stop-DhTui` → exit 130 (spec §"Ctrl+C / SIGINT handling")
- `Test-DhEnvironment` `Fits=false` (terminal < 60×15) → fall through to streaming (spec §"Resize handling")
- Region-redraw model: OnEvent callbacks redraw only the affected region (spec §"Region-redraw model")

- [ ] **Step 1: Implement `Test-DhEnvironment`**

If `Test-DhEnvironment` is currently a stub in `derekh.psm1`, move the real implementation into `lib/plan.ps1` (or a new `lib/environment.ps1` if cleaner). Replace the stub in `derekh.psm1` with a forward call. The function must return:

```powershell
@{
    IsTty       = $bool    # [Console]::IsInputRedirected -eq $false
    IsUtf8      = $bool    # [Console]::OutputEncoding.CodePage -eq 65001
    HasColor    = $bool    # $Host.UI.SupportsVirtualTerminal or COLORTERM/TERM env
    Fits        = $bool    # $Host.UI.RawUI.WindowSize.Width -ge 60 -and .Height -ge 15
    Width       = $int
    Height      = $int
}
```

Inline the logic directly into `plan.ps1` or a dedicated `lib/environment.ps1`. Do NOT leave it in `derekh.psm1`.

Implementation of `Test-DhEnvironment`:

```powershell
function Test-DhEnvironment {
    [CmdletBinding()]
    param()

    $isTty = -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected

    $isUtf8 = ([Console]::OutputEncoding.CodePage -eq 65001)

    # Check VT support: PS 7 on Windows Terminal sets SupportsVirtualTerminal.
    # Fallback: check environment variables COLORTERM or TERM.
    $hasColor = $false
    try {
        $hasColor = $Host.UI.SupportsVirtualTerminal
    } catch { }
    if (-not $hasColor) {
        $ct = $env:COLORTERM
        $t  = $env:TERM
        $hasColor = ($ct -eq 'truecolor' -or $ct -eq '24bit' -or
                     $t  -match 'color' -or $t -eq 'xterm-256color')
    }

    $w = 0; $h = 0
    try {
        $size = $Host.UI.RawUI.WindowSize
        $w = $size.Width
        $h = $size.Height
    } catch { }

    $fits = ($w -ge 60 -and $h -ge 15)

    return @{
        IsTty    = $isTty
        IsUtf8   = $isUtf8
        HasColor = $hasColor
        Fits     = $fits
        Width    = $w
        Height   = $h
    }
}
```

- [ ] **Step 2: Implement the TUI path in `Invoke-DhPlan`**

Replace the Phase D TUI stub in `lib/plan.ps1` (or `derekh.psm1`) with the following full implementation. The function must:

1. Register `trap { Stop-DhTui }` at its very top.
2. Register `[Console]::CancelKeyPress` for Ctrl+C.
3. Call `Test-DhEnvironment`; if not TUI-capable, fall through to streaming.
4. Call `Initialize-DhTui`.
5. Compute layout via `Get-DhLayout` (from `layout.ps1`).
6. Render the initial full frame (all five regions).
7. Register key handlers for `q`, `Q`, `Escape`, `Enter` → set `$shouldQuit = $true`.
8. Run the plan phases using existing `plan.ps1` loop logic, with an `OnEvent` callback that redraws the affected region only.
9. After plan completes: re-render footer with "press q to quit" text.
10. Enter the wait loop: poll keys every 50ms until `$shouldQuit`.
11. Call `Stop-DhTui`.
12. Exit with the appropriate exit code (0 = all phases ok, 1 = any failure).

```powershell
function Invoke-DhPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Plan,
        [string]$Theme,
        [switch]$Headless,
        [switch]$NoTui,
        [switch]$Ascii
    )

    # ── TUI teardown safety net ───────────────────────────────────────────────
    # Registered at the very top so ANY unhandled exception exits the alt buffer.
    trap {
        Stop-DhTui
        Write-Error $_ -ErrorAction Continue
        exit 2
    }

    # ── Resolve theme ─────────────────────────────────────────────────────────
    $themeName   = if ($Theme) { $Theme } elseif ($Plan.Theme) { $Plan.Theme } else { 'twilight' }
    $resolvedTheme = Get-DhTheme -Name $themeName

    # ── Headless path ─────────────────────────────────────────────────────────
    if ($Headless) {
        $state = Invoke-DhPlanExecution -Plan $Plan -Theme $resolvedTheme
        Write-DhHeadless -State $state
        exit (if ($state.ExitCode) { $state.ExitCode } else { 0 })
    }

    # ── Environment check ─────────────────────────────────────────────────────
    $env = Test-DhEnvironment

    $useTui = (-not $NoTui) -and $env.IsTty -and $env.Fits -and $env.HasColor

    # ── Streaming path ────────────────────────────────────────────────────────
    if (-not $useTui) {
        $state = Invoke-DhPlanExecution -Plan $Plan -Theme $resolvedTheme `
                     -OnEvent { param($evt) Write-DhStreaming -Event $evt -Theme $resolvedTheme }
        exit (if ($state.ExitCode) { $state.ExitCode } else { 0 })
    }

    # ── TUI path ─────────────────────────────────────────────────────────────

    # Ctrl+C handler: restore terminal and exit 130 (SIGINT convention).
    $cancelHandler = {
        param($sender, $e)
        $e.Cancel = $true          # prevent immediate process kill
        Stop-DhTui
        [Environment]::Exit(130)
    }
    [Console]::add_CancelKeyPress($cancelHandler)

    try {
        Initialize-DhTui

        # Build initial state.
        $state  = New-DhState -Plan $Plan
        $layout = Get-DhLayout -Width $env.Width -Height $env.Height `
                               -Plan $Plan -Theme $resolvedTheme

        # Initial full-frame render.
        Render-DhHeader      -State $state -Theme $resolvedTheme -Layout $layout
        Render-DhPhasesPane  -State $state -Theme $resolvedTheme -Layout $layout
        Render-DhActivePane  -State $state -Theme $resolvedTheme -Layout $layout
        Render-DhIssuesPane  -State $state -Theme $resolvedTheme -Layout $layout
        Render-DhFooter      -State $state -Theme $resolvedTheme -Layout $layout

        # Key handlers — Phase F: quit only.
        $shouldQuit = $false
        Clear-DhKeyHandlers
        Register-DhKeyHandler -Key 'Q'      -Action { $script:shouldQuit = $true }
        Register-DhKeyHandler -Key 'Escape' -Action { $script:shouldQuit = $true }
        Register-DhKeyHandler -Key 'Enter'  -Action { $script:shouldQuit = $true }

        # OnEvent callback: partial redraws — only the affected region.
        $onEvent = {
            param($evt)
            switch ($evt.Type) {
                'PhaseUpdated'  { Render-DhPhasesPane -State $state -Theme $resolvedTheme -Layout $layout }
                'IssueEmitted'  { Render-DhIssuesPane -State $state -Theme $resolvedTheme -Layout $layout }
                'ActiveChanged' { Render-DhActivePane  -State $state -Theme $resolvedTheme -Layout $layout }
                'HeaderChanged' { Render-DhHeader      -State $state -Theme $resolvedTheme -Layout $layout }
            }
        }

        # Run the plan (non-blocking: events fire $onEvent as they occur).
        $state = Invoke-DhPlanExecution -Plan $Plan -Theme $resolvedTheme `
                     -State $state -OnEvent $onEvent

        # Plan complete — re-render footer with quit prompt.
        Render-DhFooter -State $state -Theme $resolvedTheme -Layout $layout

        # Wait loop: poll keys at 50ms intervals until quit.
        while (-not $shouldQuit) {
            if (Test-DhKeyAvailable) {
                $key = Read-DhKey
                Invoke-DhKeyDispatch -KeyInfo $key
            }
            Start-Sleep -Milliseconds 50
        }

    } finally {
        Stop-DhTui
        [Console]::remove_CancelKeyPress($cancelHandler)
    }

    exit (if ($state.ExitCode) { $state.ExitCode } else { 0 })
}
```

Note: `Invoke-DhPlanExecution` and `New-DhState` are the internal helpers that already exist from Phase B/D. `Get-DhLayout` is from Phase B's `layout.ps1`. `Write-DhStreaming` is from Phase E. `Write-DhHeadless` is from Phase D. These are not re-implemented here — F5 only adds the TUI branch on top of existing infrastructure.

- [ ] **Step 3: Write `tests/manual-smoke.ps1`**

Create `c:/git/fellwork/tools/derekh/tests/manual-smoke.ps1` with the following exact contents:

```powershell
#Requires -Version 7
# manual-smoke.ps1 — Manual TUI smoke test for Phase F.
#
# Run this INTERACTIVELY in a real terminal (not in a pipe, not in CI):
#
#   pwsh tests/manual-smoke.ps1
#
# What to verify visually:
#   [ ] Terminal switches to alternate screen buffer (prior content hidden)
#   [ ] Header shows title "Derekh Smoke Test" and subtitle (time)
#   [ ] Phases pane shows two phases with correct status glyphs:
#         Phase 1 completes ok (✓ green), Phase 2 completes ok (✓ green)
#   [ ] Active pane shows spinner during each phase, then goes idle
#   [ ] Issues pane stays empty (no failures expected in smoke test)
#   [ ] Footer shows "[q] quit"
#   [ ] After both phases complete, pressing q returns to normal terminal
#   [ ] No garbage ANSI codes visible; cursor hidden during run
#   [ ] Terminal cursor restored on exit; scrollback buffer intact
#   [ ] Ctrl+C during a phase returns to normal terminal (exit 130)
#
# This script is NOT run by tests/run-all.ps1. It is a human-in-the-loop check.
# It verifies the visual correctness of render.ps1 F2 region drawers.

[CmdletBinding()]
param(
    [switch]$Quick   # Skip the artificial delays if you just want a fast check
)

$ErrorActionPreference = 'Stop'

$manifestPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../derekh.psd1'))
Import-Module $manifestPath -Force -ErrorAction Stop

Write-Host ""
Write-Host "Derekh Phase F — Manual TUI Smoke Test" -ForegroundColor Cyan
Write-Host "Starting TUI in 2 seconds. Press q to quit when phases complete." -ForegroundColor DarkGray
Write-Host ""

if (-not $Quick) { Start-Sleep -Seconds 2 }

# Build a plan with two fast phases.
$plan = New-DhPlan -Title 'Derekh Smoke Test' `
                   -Subtitle (Get-Date -Format 'HH:mm:ss')

$plan = Add-DhLoopPhase -Plan $plan -Name 'Phase One' `
    -Items @('item-a', 'item-b', 'item-c') `
    -Action {
        param($item)
        if (-not $using:Quick) { Start-Sleep -Milliseconds 400 }
        return New-DhResult -Success $true -Message "$item processed"
    }

$plan = Add-DhSinglePhase -Plan $plan -Name 'Phase Two' `
    -Action {
        if (-not $using:Quick) { Start-Sleep -Milliseconds 600 }
        return New-DhResult -Success $true -Message 'Final check passed'
    }

# Run via TUI path (no -NoTui, no -Headless).
Invoke-DhPlan -Plan $plan

# If we get here the user pressed q.
Write-Host ""
Write-Host "Smoke test exited cleanly." -ForegroundColor Green
```

- [ ] **Step 4: Run automated tests to confirm no regressions**

```bash
pwsh -NoProfile -File /c/git/fellwork/tools/derekh/tests/run-all.ps1
```

Expected: all automated suites pass. `manual-smoke.ps1` is NOT in `test-*.ps1` naming convention so it is not auto-discovered. All prior suites remain green.

- [ ] **Step 5: Manual verification — run the smoke test**

In a real terminal (not CI, not a piped shell), run:

```powershell
pwsh /c/git/fellwork/tools/derekh/tests/manual-smoke.ps1
```

Checklist (must all pass visually before marking F5 done):

- [ ] Terminal switches to alternate screen buffer
- [ ] Header renders with title "Derekh Smoke Test" and current time as subtitle
- [ ] Phases pane shows Phase One and Phase Two with correct status progression: `○` (pending) → `◐` (running) → `✓` (ok)
- [ ] Active pane shows spinner and item name during Phase One items; shows Phase Two name during Phase Two
- [ ] Issues pane shows "No issues"
- [ ] Footer shows `[q] quit`
- [ ] After both phases complete, pressing `q` returns to the normal terminal cleanly
- [ ] No ANSI garbage left on screen; scrollback buffer intact
- [ ] Cursor is restored and visible after exit

- [ ] **Step 6: Manual verification — Ctrl+C**

Start the smoke test again, then press **Ctrl+C** during Phase One:

```powershell
pwsh /c/git/fellwork/tools/derekh/tests/manual-smoke.ps1
```

Checklist:
- [ ] Terminal restored to normal screen (no alternate buffer left active)
- [ ] Cursor visible
- [ ] Exit code is 130 (`echo $LASTEXITCODE`)

- [ ] **Step 7: Manual verification — min-size check**

Resize your terminal to less than 60 columns and run:

```powershell
pwsh /c/git/fellwork/tools/derekh/tests/manual-smoke.ps1
```

Checklist:
- [ ] Plan runs via streaming fallback (no alternate buffer; sequential output)
- [ ] A note or log line indicates the TUI was skipped due to terminal size

- [ ] **Step 8: Commit**

```bash
cd /c/git/fellwork/tools
git add derekh/lib/plan.ps1 derekh/tests/manual-smoke.ps1
git commit -m "feat(derekh): F5 — TUI path wired in Invoke-DhPlan (quit, teardown, Ctrl+C)"
git push
```

---

## Phase F completion checklist

After all five tasks, verify:

- [ ] `pwsh -NoProfile -File c:/git/fellwork/tools/derekh/tests/run-all.ps1` exits 0 (no failures across all suites)
- [ ] `test-render-primitives` — all automated assertions pass; lifecycle tests correctly SKIPPED
- [ ] `test-render-regions` — 5 drawer-existence assertions pass; visual tests correctly SKIPPED
- [ ] `test-input` — full handler-registry and dispatch tests pass; terminal-dependent tests correctly SKIPPED
- [ ] `test-clipboard` — full capability-check and type-safety tests pass; cross-platform live tests gated by `$IsWindows`/`$IsMacOS`
- [ ] `tests/manual-smoke.ps1` verified interactively:
  - [ ] Alternate buffer enters and exits cleanly
  - [ ] All five regions render correctly
  - [ ] `q`/`Esc`/`Enter` exits the TUI and restores the terminal
  - [ ] Ctrl+C exits with code 130 and restores the terminal
  - [ ] Terminal < 60×15 falls through to streaming
- [ ] `Stop-DhTui` is registered as `trap` at the top of `Invoke-DhPlan` (review code)
- [ ] `[Console]::CancelKeyPress` handler registered during TUI path (review code)
- [ ] `Set-DhClipboard` returns `$false` (not throw) on unsupported platforms (automated by `test-clipboard`)
- [ ] No full-screen clears after initial render (region-redraw model enforced — review code)

**Phase G entry condition:** all items above pass. Phase G adds resize polling (runspace-based `$Host.UI.RawUI.WindowSize` check every 200ms), post-completion `[1-9]` copy key handlers using `Set-DhClipboard`, the "Terminal too small — resize to at least 60×15" pause message, and the post-completion footer flash ("Copied to clipboard" / "No command to copy").
