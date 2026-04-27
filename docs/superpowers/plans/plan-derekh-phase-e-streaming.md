# Derekh Phase E — Streaming Renderer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the streaming fallback renderer for non-TTY environments and explicit `-NoTui` mode. After Phase E, `Invoke-DhPlan -NoTui` (and any run in a non-TTY terminal) produces a fully themed, human-readable streaming output: banner, per-phase section headers, tree-line items for loop phases, and a consolidated summary with next steps. No cursor positioning — sequential `Write-Host` only.

**Architecture:** `lib/streaming.ps1` registers as the `OnEvent` callback supplied to `Invoke-DhPlanPhases`. It receives events (`phase-started`, `phase-progress`, `phase-completed`, `issue-emitted`, `plan-completed`) and writes themed output as they fire. `Invoke-DhPlan` auto-engages this path when `[Console]::IsOutputRedirected` is `$true` and `-Headless` was not passed, or when `-NoTui` is explicitly set. Colors use `Format-DhAnsi` (truecolor ANSI escapes) sourced from the resolved theme palette. `-NoColor` and `NO_COLOR` env var both suppress all ANSI codes.

**Intentional duplication note:** Derekh's streaming renderer is purposely separate from bootstrap's own streaming renderer (in `bootstrap.ps1` / `lib/ui.ps1`). Bootstrap keeps its renderer; Derekh has its own. ~100 lines of conceptual duplication is accepted per spec. Do NOT modify or reuse bootstrap's `Format-Color`, `Format-Section`, or `Format-TreeLine` functions.

**Tech Stack:** PowerShell 7.5+, ANSI 24-bit truecolor escapes via inline escape sequences

**Spec:** `c:/git/fellwork/bootstrap/docs/superpowers/specs/2026-04-26-derekh-tui-design.md` (sections: Execution modes, Bootstrap.ps1 integration, Three event streams)

**Prerequisites:** Phase D complete — `Invoke-DhPlan` exists in `lib/plan.ps1`, the `-Headless` path works end-to-end, and `Invoke-DhPlanPhases` emits `OnEvent` callbacks. Theme resolution (`Get-DhThemeColor`, `Get-DhThemeGlyph`) is functional from Phase B/C.

---

## Task E1: `lib/streaming.ps1` — `Invoke-DhStreamingRender`

**Files:**
- Create: `c:/git/fellwork/tools/derekh/lib/streaming.ps1`

The streaming renderer is a single public function `Invoke-DhStreamingRender`. It is called once per event emitted by `Invoke-DhPlanPhases`; it also renders the initial banner (on `plan-started`) and the final summary (on `plan-completed`).

### Design notes before implementation

**ANSI helper — `Format-DhAnsi`**

The file defines a private helper `Format-DhAnsi`:

```powershell
function Format-DhAnsi {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][array]$Rgb,   # @(R, G, B)
        [bool]$Bold = $false,
        [bool]$Enabled = $true
    )
    if (-not $Enabled) { return $Text }
    $boldCode = if ($Bold) { '1;' } else { '' }
    return "`e[${boldCode}38;2;$($Rgb[0]);$($Rgb[1]);$($Rgb[2])m$Text`e[0m"
}
```

`Get-DhThemeColor -Theme $theme -Name 'ok'` returns an `@(R, G, B)` array. Every themed `Write-Host` call goes through `Format-DhAnsi` — never raw `-ForegroundColor`.

**Color-suppression check — `$colorEnabled`**

At the top of `Invoke-DhStreamingRender`, compute once:

```powershell
$colorEnabled = $ColorEnabled -and [string]::IsNullOrEmpty($env:NO_COLOR)
```

Pass `$colorEnabled` to every `Format-DhAnsi` call. This handles both `-NoColor` (passed as `$ColorEnabled = $false`) and the `NO_COLOR` env var.

**Event types and rendering actions**

| Event | What to render |
|---|---|
| `plan-started` | Banner: heavy-rule line, title + subtitle, heavy-rule line. Uses `title` and `accent` theme colors. |
| `phase-started` | Section header: `── {PhaseName} ──` padded to width 60. Uses `frame` color. Emits a blank line before. |
| `phase-progress` | Tree-line item for a loop phase result. Format: `├─ {glyph} {ItemName}  {Message}` (mid) or `└─ {glyph} {ItemName}  {Message}` (last item). Glyph and color depend on `Success`: `phase_ok` / `ok` color for success, `phase_fail` / `fail` color for failure. |
| `phase-completed` | Status line for the completed phase: `  {glyph} {PhaseName}  {n}/{total}` with `ok` or `fail` color. Emits a blank line after. |
| `issue-emitted` | Do NOT render issues inline as they fire. Collect them into `$script:StreamingIssues`. Issues are rendered in full in the summary. |
| `plan-completed` | Render the full summary section (see below). |

**Banner format**

```
════════════════════════════════════════════════════════════
  {icon_title} {Title}                              {Subtitle}
════════════════════════════════════════════════════════════
```

- Top and bottom rules: `$theme.glyphs.frame_h * 60` in `accent` color, bold.
- Title line: title in `title` color, bold; subtitle in `dim` color.
- `icon_title` glyph from theme (e.g. `🌙`).

**Section header format**

```
[blank line]
── {PhaseName} ──────────────────────────────────────────
```

- Rule character: `$theme.glyphs.frame_h` from theme (e.g. `─`).
- Color: `frame` from palette.
- Padding rule fills to 60 chars total.

**Tree-line item format (loop phase)**

```
├─ ✓ api                  already cloned
└─ ✗ web                  clone failed (exit 128)
```

- Uses `phase_ok`/`phase_fail` glyphs from theme.
- Mid-items use `├─` (or `frame_l` + `frame_h` composite); last item uses `└─` (or `frame_bl` + `frame_h` composite). Source both from theme glyphs or construct from `─`/`├`/`└` directly per spec.
- Item name left-padded to a consistent column (16 chars, truncated if longer).
- Message text follows after two spaces.
- Color: `ok` palette for success, `fail` palette for failure, `warn` palette for warning severity.

**Summary section format**

```
[blank line]
── Summary ──────────────────────────────────────────────

  ✓  6 / 6 phases completed
  ⚠  2 warning(s)
  ✗  1 failure(s)

── Issues ───────────────────────────────────────────────

  [1] ⚠ wrangler is not installed  (warning)
      🦉  rerun bootstrap.ps1 - it is safe to run repeatedly
      Fix: npm install -g wrangler

  [2] ✗ git clone failed for web  (fail)
      🦝  user code did something unexpected
      Fix: git clone https://github.com/fellwork/web.git

── Suggested next steps ─────────────────────────────────

  Run these commands, then rerun to verify:

   1. ✗  git clone failed for web
      npm install -g wrangler

   2. ⚠  wrangler is not installed
      npm install -g wrangler

[closing animal phrase]
```

- Section headers use `frame` color.
- Phase counts line uses `ok`/`fail`/`warn` color as appropriate.
- Each issue's numeric label uses `dim` color; severity glyph uses `fail` or `warn` color.
- `FixCommand` is printed in `dim` color, prefixed with `Fix: `.
- Numbered next-steps list mirrors bootstrap's layout: number, severity marker, title, then fix command on the next line.
- Closing phrase: if all succeeded, pick `otter`/`celebrate` phrase. If any failures, pick `owl`/`pro-tip` phrase. Phrase is NOT colored (it may contain emoji). Animal selection uses `Get-DhAnimalPhrase` (Phase B helper) if available, or a hardcoded fallback string.

### Implementation steps

- [ ] **Step 1: Write `lib/streaming.ps1`**

Create `c:/git/fellwork/tools/derekh/lib/streaming.ps1`. The file exports one public function (`Invoke-DhStreamingRender`) and one private helper (`Format-DhAnsi`). Exact content:

```powershell
#Requires -Version 7
# streaming.ps1 — Derekh streaming fallback renderer.
#
# Renders plan execution events as sequential Write-Host output.
# No cursor positioning. Theme-driven ANSI truecolor colors.
# Called once per event from Invoke-DhPlanPhases -OnEvent.
#
# Public API: Invoke-DhStreamingRender
# Private:    Format-DhAnsi, Format-DhStreamBanner, Format-DhStreamSection,
#             Format-DhStreamTreeLine, Format-DhStreamSummary

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Private: ANSI helper
# ---------------------------------------------------------------------------

function Format-DhAnsi {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][array]$Rgb,
        [bool]$Bold = $false,
        [bool]$Enabled = $true
    )
    if (-not $Enabled -or $null -eq $Rgb -or $Rgb.Count -lt 3) { return $Text }
    $boldCode = if ($Bold) { '1;' } else { '' }
    return "`e[${boldCode}38;2;$($Rgb[0]);$($Rgb[1]);$($Rgb[2])m$Text`e[0m"
}

# ---------------------------------------------------------------------------
# Private: rendering sub-functions
# ---------------------------------------------------------------------------

function Format-DhStreamBanner {
    param(
        [hashtable]$Theme,
        [string]$Title,
        [string]$Subtitle,
        [bool]$ColorEnabled
    )
    $ruleChar = if ($Theme.glyphs.frame_h) { $Theme.glyphs.frame_h } else { '─' }
    $icon     = if ($Theme.glyphs.icon_title) { "$($Theme.glyphs.icon_title) " } else { '' }
    $rule     = $ruleChar * 60
    $titleStr = "  $icon$Title"
    # Right-align subtitle so total line is ≤ 60 chars
    $pad      = [Math]::Max(0, 60 - $titleStr.Length - $Subtitle.Length)
    $titleLine = "$titleStr$(' ' * $pad)$Subtitle"

    $accentRgb = Get-DhThemeColor -Theme $Theme -Name 'accent'
    $titleRgb  = Get-DhThemeColor -Theme $Theme -Name 'title'
    $dimRgb    = Get-DhThemeColor -Theme $Theme -Name 'dim'

    $ruleOut  = Format-DhAnsi -Text $rule -Rgb $accentRgb -Bold $true -Enabled $ColorEnabled
    # Split title and subtitle for separate coloring
    $titleOut = Format-DhAnsi -Text $titleStr -Rgb $titleRgb -Bold $true -Enabled $ColorEnabled
    $subOut   = Format-DhAnsi -Text $Subtitle -Rgb $dimRgb -Enabled $ColorEnabled
    $lineOut  = "$titleOut$(' ' * $pad)$subOut"

    return @($ruleOut, $lineOut, $ruleOut)
}

function Format-DhStreamSection {
    param(
        [hashtable]$Theme,
        [string]$Title,
        [int]$Width = 60,
        [bool]$ColorEnabled
    )
    $ruleChar  = if ($Theme.glyphs.frame_h) { $Theme.glyphs.frame_h } else { '─' }
    $padded    = "  $Title  "
    $remaining = $Width - $padded.Length
    $sideLen   = [Math]::Max(2, [int]($remaining / 2))
    $line      = ($ruleChar * $sideLen) + $padded + ($ruleChar * $sideLen)
    $frameRgb  = Get-DhThemeColor -Theme $Theme -Name 'frame'
    return Format-DhAnsi -Text $line -Rgb $frameRgb -Enabled $ColorEnabled
}

function Format-DhStreamTreeLine {
    param(
        [hashtable]$Theme,
        [string]$ItemName,
        [string]$Message,
        [string]$Severity,   # 'ok' | 'warning' | 'fail'
        [bool]$IsLast,
        [bool]$ColorEnabled
    )
    # Glyph selection
    $glyph    = switch ($Severity) {
        'ok'      { if ($Theme.glyphs.phase_ok)   { $Theme.glyphs.phase_ok }   else { '✓' } }
        'warning' { if ($Theme.glyphs.phase_warn)  { $Theme.glyphs.phase_warn } else { '⚠' } }
        default   { if ($Theme.glyphs.phase_fail)  { $Theme.glyphs.phase_fail } else { '✗' } }
    }
    $colorName = switch ($Severity) {
        'ok'      { 'ok' }
        'warning' { 'warn' }
        default   { 'fail' }
    }
    $rgb    = Get-DhThemeColor -Theme $Theme -Name $colorName
    $branch = if ($IsLast) { '└─' } else { '├─' }
    $nameCol = $ItemName.PadRight(16).Substring(0, [Math]::Min(16, $ItemName.Length)).PadRight(16)
    $text   = "$branch $glyph $nameCol  $Message"
    return Format-DhAnsi -Text $text -Rgb $rgb -Enabled $ColorEnabled
}

function Format-DhStreamSummary {
    param(
        [hashtable]$Theme,
        [hashtable]$State,
        [bool]$ColorEnabled
    )
    $lines = [System.Collections.Generic.List[string]]::new()

    # ── Counts ────────────────────────────────────────────────────────────────
    $totalPhases = $State.Phases.Count
    $okPhases    = ($State.Phases | Where-Object { $_.Status -eq 'ok' }).Count
    $warnCount   = ($State.Issues | Where-Object { $_.Severity -eq 'warning' }).Count
    $failCount   = ($State.Issues | Where-Object { $_.Severity -eq 'fail' }).Count

    $okRgb   = Get-DhThemeColor -Theme $Theme -Name 'ok'
    $warnRgb = Get-DhThemeColor -Theme $Theme -Name 'warn'
    $failRgb = Get-DhThemeColor -Theme $Theme -Name 'fail'
    $dimRgb  = Get-DhThemeColor -Theme $Theme -Name 'dim'

    $okGlyph   = if ($Theme.glyphs.phase_ok)   { $Theme.glyphs.phase_ok }   else { '✓' }
    $warnGlyph = if ($Theme.glyphs.phase_warn)  { $Theme.glyphs.phase_warn } else { '⚠' }
    $failGlyph = if ($Theme.glyphs.phase_fail)  { $Theme.glyphs.phase_fail } else { '✗' }

    $countColor = if ($failCount -gt 0) { $failRgb } elseif ($warnCount -gt 0) { $warnRgb } else { $okRgb }
    $countGlyph = if ($failCount -gt 0) { $failGlyph } elseif ($warnCount -gt 0) { $warnGlyph } else { $okGlyph }
    $lines.Add(Format-DhAnsi -Text "  $countGlyph  $okPhases / $totalPhases phases completed" -Rgb $countColor -Enabled $ColorEnabled)
    if ($warnCount -gt 0) {
        $lines.Add(Format-DhAnsi -Text "  $warnGlyph  $warnCount warning(s)" -Rgb $warnRgb -Enabled $ColorEnabled)
    }
    if ($failCount -gt 0) {
        $lines.Add(Format-DhAnsi -Text "  $failGlyph  $failCount failure(s)" -Rgb $failRgb -Enabled $ColorEnabled)
    }

    # ── Issues section ─────────────────────────────────────────────────────────
    if ($State.Issues.Count -gt 0) {
        $lines.Add('')
        $lines.Add(Format-DhStreamSection -Theme $Theme -Title 'Issues' -ColorEnabled $ColorEnabled)
        $lines.Add('')
        $idx = 1
        foreach ($issue in $State.Issues) {
            $iSev   = if ($issue.Severity) { $issue.Severity } else { 'fail' }
            $iGlyph = switch ($iSev) {
                'warning' { $warnGlyph }
                'info'    { $okGlyph }
                default   { $failGlyph }
            }
            $iRgb   = switch ($iSev) {
                'warning' { $warnRgb }
                'info'    { $okRgb }
                default   { $failRgb }
            }
            $label  = Format-DhAnsi -Text "  [$idx]" -Rgb $dimRgb -Enabled $ColorEnabled
            $header = Format-DhAnsi -Text " $iGlyph $($issue.Message)  ($iSev)" -Rgb $iRgb -Enabled $ColorEnabled
            $lines.Add("$label$header")
            if ($issue.Animal -and $issue.AnimalPhrase) {
                $lines.Add("      $($issue.Animal)  $($issue.AnimalPhrase)")
            }
            if ($issue.FixCommand) {
                $fixOut = Format-DhAnsi -Text "      Fix: $($issue.FixCommand)" -Rgb $dimRgb -Enabled $ColorEnabled
                $lines.Add($fixOut)
            }
            $lines.Add('')
            $idx++
        }
    }

    # ── Suggested next steps ───────────────────────────────────────────────────
    $actionable = $State.Issues | Where-Object { $_.FixCommand }
    if ($actionable.Count -gt 0) {
        $lines.Add(Format-DhStreamSection -Theme $Theme -Title 'Suggested next steps' -ColorEnabled $ColorEnabled)
        $lines.Add('')
        $lines.Add(Format-DhAnsi -Text '  Run these commands, then rerun to verify:' -Rgb $dimRgb -Enabled $ColorEnabled)
        $lines.Add('')
        $step = 1
        foreach ($item in $actionable) {
            $iSev   = if ($item.Severity) { $item.Severity } else { 'fail' }
            $iGlyph = switch ($iSev) { 'warning' { $warnGlyph } 'info' { $okGlyph } default { $failGlyph } }
            $iRgb   = switch ($iSev) { 'warning' { $warnRgb } 'info' { $okRgb } default { $failRgb } }
            $numOut = Format-DhAnsi -Text ("  {0,2}. $iGlyph  $($item.Message)" -f $step) -Rgb $iRgb -Enabled $ColorEnabled
            $fixOut = Format-DhAnsi -Text "      $($item.FixCommand)" -Rgb $dimRgb -Enabled $ColorEnabled
            $lines.Add($numOut)
            $lines.Add($fixOut)
            $lines.Add('')
            $step++
        }
    }

    # ── Closing phrase ─────────────────────────────────────────────────────────
    $animal  = if ($failCount -gt 0) { 'owl' } else { 'otter' }
    $situation = if ($failCount -gt 0) { 'pro-tip' } else { 'celebrate' }
    $phrase  = $null
    if (Get-Command 'Get-DhAnimalPhrase' -ErrorAction SilentlyContinue) {
        $phrase = Get-DhAnimalPhrase -Animal $animal -Situation $situation
    }
    if ($phrase) {
        $emoji = if ($failCount -gt 0) { '🦉' } else { '🦦' }
        $lines.Add("$emoji  $phrase")
    }

    return $lines
}

# ---------------------------------------------------------------------------
# Public: Invoke-DhStreamingRender
# ---------------------------------------------------------------------------

function Invoke-DhStreamingRender {
    <#
    .SYNOPSIS
        Handle one plan-execution event by writing themed streaming output.

    .DESCRIPTION
        Called once per event emitted by Invoke-DhPlanPhases -OnEvent.
        Maintains no internal state of its own beyond the running $State
        (which is passed by reference from plan.ps1). Renders:
          - Banner on plan-started
          - Section header on phase-started
          - Tree-line item on phase-progress
          - Phase summary line on phase-completed
          - Full summary section on plan-completed

        Issues are buffered (not rendered inline) and displayed in the
        summary section after the plan finishes.

    .PARAMETER Event
        Hashtable with at minimum a 'Type' key. Additional keys vary by type:
          plan-started    : Title, Subtitle, Theme (resolved hashtable)
          phase-started   : PhaseName, PhaseType, PhaseIndex, PhaseTotal
          phase-progress  : PhaseName, ItemName, Message, Success, Severity, IsLast
          phase-completed : PhaseName, OkCount, TotalCount, Status
          issue-emitted   : Issue (hashtable per action return contract)
          plan-completed  : State (full $DerekhState hashtable), ExitCode

    .PARAMETER ColorEnabled
        When $false, all ANSI codes are suppressed. Also suppressed when
        the NO_COLOR environment variable is set (regardless of this param).

    .EXAMPLE
        # Wire into Invoke-DhPlanPhases:
        Invoke-DhPlanPhases -State $state -OnEvent {
            param($evt)
            Invoke-DhStreamingRender -Event $evt -ColorEnabled $colorEnabled
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Event,
        [bool]$ColorEnabled = $true
    )

    # NO_COLOR env var overrides whatever the caller passed
    $colorEnabled = $ColorEnabled -and [string]::IsNullOrEmpty($env:NO_COLOR)

    switch ($Event.Type) {

        'plan-started' {
            $bannerLines = Format-DhStreamBanner `
                -Theme    $Event.Theme `
                -Title    $Event.Title `
                -Subtitle $Event.Subtitle `
                -ColorEnabled $colorEnabled
            Write-Host ''
            foreach ($line in $bannerLines) { Write-Host $line }
            Write-Host ''
        }

        'phase-started' {
            Write-Host ''
            $hdr = Format-DhStreamSection `
                -Theme        $Event.Theme `
                -Title        $Event.PhaseName `
                -ColorEnabled $colorEnabled
            Write-Host $hdr
        }

        'phase-progress' {
            $sev = if ($Event.Severity) {
                $Event.Severity
            } elseif ($Event.Success) {
                'ok'
            } else {
                'fail'
            }
            $line = Format-DhStreamTreeLine `
                -Theme        $Event.Theme `
                -ItemName     $Event.ItemName `
                -Message      $Event.Message `
                -Severity     $sev `
                -IsLast       $Event.IsLast `
                -ColorEnabled $colorEnabled
            Write-Host $line
        }

        'phase-completed' {
            # Single-phase status line (loop phases already showed tree lines)
            if ($Event.PhaseType -eq 'single') {
                $okGlyph   = if ($Event.Theme.glyphs.phase_ok)   { $Event.Theme.glyphs.phase_ok }   else { '✓' }
                $failGlyph = if ($Event.Theme.glyphs.phase_fail)  { $Event.Theme.glyphs.phase_fail } else { '✗' }
                $glyph  = if ($Event.Status -eq 'ok') { $okGlyph } else { $failGlyph }
                $color  = if ($Event.Status -eq 'ok') { 'ok' } else { 'fail' }
                $rgb    = Get-DhThemeColor -Theme $Event.Theme -Name $color
                $text   = "  $glyph $($Event.PhaseName)"
                if ($null -ne $Event.OkCount -and $null -ne $Event.TotalCount) {
                    $text += "  ($($Event.OkCount)/$($Event.TotalCount))"
                }
                Write-Host (Format-DhAnsi -Text $text -Rgb $rgb -Enabled $colorEnabled)
            }
            Write-Host ''
        }

        'issue-emitted' {
            # Issues are collected into state and rendered in the summary.
            # No inline rendering here — keeps output clean during execution.
        }

        'plan-completed' {
            $theme = $Event.Theme
            Write-Host ''
            Write-Host (Format-DhStreamSection -Theme $theme -Title 'Summary' -ColorEnabled $colorEnabled)
            Write-Host ''
            $summaryLines = Format-DhStreamSummary `
                -Theme        $theme `
                -State        $Event.State `
                -ColorEnabled $colorEnabled
            foreach ($line in $summaryLines) { Write-Host $line }
        }

    }
}
```

- [ ] **Step 2: Verify the file dot-sources cleanly into the module**

```powershell
pwsh -NoProfile -Command "
    Import-Module c:/git/fellwork/tools/derekh/derekh.psd1 -Force
    \$fn = Get-Command Invoke-DhStreamingRender -ErrorAction SilentlyContinue
    if (\$fn) { Write-Host 'PASS: Invoke-DhStreamingRender found' }
    else       { Write-Host 'FAIL: Invoke-DhStreamingRender not found'; exit 1 }
"
```

Expected: `PASS: Invoke-DhStreamingRender found`. The function is private to the module (not in `FunctionsToExport`) so this check uses `Get-Command` without `-Module derekh` filtering.

- [ ] **Step 3: Commit**

```bash
cd /c/git/fellwork/tools
git add derekh/lib/streaming.ps1
git commit -m "feat(derekh/streaming): Invoke-DhStreamingRender + Format-DhAnsi (Phase E1)"
git push
```

---

## Task E2: Wire `-NoTui` path in `Invoke-DhPlan`

**Files:**
- Edit: `c:/git/fellwork/tools/derekh/lib/plan.ps1`

Replace the Phase D stub for the `-NoTui` / non-TTY code path with a real implementation that:

1. Calls `Invoke-DhPlanPhases -State $state -OnEvent { ... Invoke-DhStreamingRender ... }`.
2. Auto-detects non-TTY: if `[Console]::IsOutputRedirected -eq $true` AND `-Headless` was not passed, treat as `-NoTui`.
3. Passes `$colorEnabled` into `Invoke-DhStreamingRender`.
4. Returns the same exit code contract as headless mode (0 / 1 / 2).

### Design: `Invoke-DhPlan` streaming branch

The key block inside `Invoke-DhPlan` (after the headless check and before the TUI block):

```powershell
# --- Non-TTY auto-detect ---
$isNonTty = [Console]::IsOutputRedirected
if ($isNonTty -and -not $Headless) {
    $NoTui = $true
}

# --- Streaming path ---
if ($NoTui) {
    # Color: disabled by -NoColor flag, NO_COLOR env var, or non-truecolor terminal
    $colorEnabled = -not $NoColor -and [string]::IsNullOrEmpty($env:NO_COLOR)

    $resolvedTheme = Get-DhTheme -Name ($Plan.Theme ?? 'twilight')

    # Emit plan-started banner
    Invoke-DhStreamingRender -Event @{
        Type     = 'plan-started'
        Theme    = $resolvedTheme
        Title    = $Plan.Title
        Subtitle = if ($Plan.Subtitle) { $Plan.Subtitle } else { (Get-Date -Format 'HH:mm:ss') }
    } -ColorEnabled $colorEnabled

    # Run all phases, routing each event through the streaming renderer
    Invoke-DhPlanPhases -State $state -Plan $Plan -OnEvent {
        param($evt)
        $evt.Theme = $resolvedTheme
        Invoke-DhStreamingRender -Event $evt -ColorEnabled $colorEnabled
    }

    # Emit plan-completed summary
    Invoke-DhStreamingRender -Event @{
        Type     = 'plan-completed'
        Theme    = $resolvedTheme
        State    = $state
        ExitCode = $state.ExitCode
    } -ColorEnabled $colorEnabled

    return $state.ExitCode
}
```

Note: the `$NoTui` variable must be declared as `[bool]` or a regular variable (not a `[switch]`) inside the function body so it can be reassigned by the auto-detect logic. In the function signature it remains `[switch]$NoTui`; convert with `$NoTui = $NoTui.IsPresent` at the top of the function body.

### Implementation steps

- [ ] **Step 1: Read the current `lib/plan.ps1` to locate the stub**

Read `c:/git/fellwork/tools/derekh/lib/plan.ps1` and identify the comment or `throw` that marks the Phase D streaming stub.

- [ ] **Step 2: Replace the stub with the real streaming branch**

Edit `c:/git/fellwork/tools/derekh/lib/plan.ps1` to replace the streaming stub with the implementation described above. Preserve the existing headless path and the TUI path stub unchanged.

- [ ] **Step 3: Smoke-test with a minimal plan**

```powershell
pwsh -NoProfile -Command "
    Import-Module c:/git/fellwork/tools/derekh/derekh.psd1 -Force

    \$plan = New-DhPlan -Title 'Smoke test' -Subtitle '00:00:00'
    \$plan = Add-DhLoopPhase -Plan \$plan -Name 'Items' -Items @('a','b','c') -Action {
        param(\$item)
        return New-DhResult -Success \$true -Message \"\$item done\"
    }

    \$exit = Invoke-DhPlan -Plan \$plan -NoTui -NoColor
    Write-Host \"Exit: \$exit\"
"
```

Expected: streaming output with banner, section header, three tree lines (`├─ ✓ a`, `├─ ✓ b`, `└─ ✓ c`), and a summary section showing `3 / 3 phases completed`. Exit code 0. No ANSI escape codes in output (because `-NoColor`).

- [ ] **Step 4: Smoke-test non-TTY auto-detect**

```powershell
pwsh -NoProfile -Command "
    Import-Module c:/git/fellwork/tools/derekh/derekh.psd1 -Force
    \$plan = New-DhPlan -Title 'Pipe test'
    \$plan = Add-DhSinglePhase -Plan \$plan -Name 'Check' -Action {
        return New-DhResult -Success \$true -Message 'ok'
    }
    Invoke-DhPlan -Plan \$plan
" | Out-String
```

Expected: because stdout is redirected (`| Out-String`), `[Console]::IsOutputRedirected` is `$true`, so the streaming renderer auto-engages without `-NoTui` being passed. Output contains the plan title and summary text.

- [ ] **Step 5: Commit**

```bash
cd /c/git/fellwork/tools
git add derekh/lib/plan.ps1
git commit -m "feat(derekh/plan): wire -NoTui streaming path + non-TTY auto-detect (Phase E2)"
git push
```

---

## Task E3: Streaming snapshot tests

**Files:**
- Create: `c:/git/fellwork/tools/derekh/tests/test-streaming-snapshot.ps1`
- Create: `c:/git/fellwork/tools/derekh/tests/snapshots/streaming-all-success.txt`
- Create: `c:/git/fellwork/tools/derekh/tests/snapshots/streaming-all-fail.txt`
- Create: `c:/git/fellwork/tools/derekh/tests/snapshots/streaming-mixed-alerts.txt`

### Snapshot test design

**Determinism strategy**

Two sources of non-determinism must be eliminated:

1. **Timestamps** — `$Plan.Subtitle` is user-supplied. Fix it: always pass `Subtitle = '00:00:00'` in test plans.
2. **Animal phrases** — `Get-DhAnimalPhrase` is non-deterministic by default. Strip them by running with `-NoColor` and then also patching: expose a `-FixedSeed` parameter on `Get-DhAnimalPhrase` OR — simpler — mock the function during tests by dot-sourcing a stub that returns a fixed string. The stub approach is preferred because it requires no changes to production code.

**Stub approach for animal phrases**

At the top of `test-streaming-snapshot.ps1`, after importing the module, redefine `Get-DhAnimalPhrase` in the test process's scope:

```powershell
function Get-DhAnimalPhrase {
    param([string]$Animal, [string]$Situation)
    return "[$Animal/$Situation]"   # deterministic; shows the params so snapshots are readable
}
```

Because `streaming.ps1` calls `Get-DhAnimalPhrase` via `Get-Command` + invocation (not dot-sourcing), the module-scope function is shadowed by the function defined in the calling scope in the same `pwsh` process. If the module caches the function reference, use `-Force` reimport or call the stub via `$env:DH_TEST_ANIMAL_PHRASE` env var instead — but the scope-shadowing approach is simpler and matches the bootstrap test pattern.

**No-color requirement**

All snapshot tests pass `-NoColor` (which maps to `$colorEnabled = $false`) so output contains zero ANSI escape codes. This makes golden files human-readable plain text and eliminates encoding differences across terminals.

**Three test cases**

| Case | Plan description | Expected exit code |
|---|---|---|
| `streaming-all-success` | Two loop phases, 3 items each, all succeed | 0 |
| `streaming-all-fail` | One loop phase, 2 items, both fail with `FixCommand` | 2 |
| `streaming-mixed-alerts` | Loop phase (2 ok, 1 fail) + single phase with one warning alert | 1 |

**Snapshot normalization**

Use the same `Normalize-Snapshot` function as `tests/test-snapshots.ps1` in bootstrap:
- CRLF → LF
- Strip trailing whitespace per line
- Single trailing newline

**Golden file generation**

On first run, if a golden file does not exist, the test writes the actual output as the new golden and prints `GOLDEN: {name} — created`. On subsequent runs it compares. This avoids a manual regen step while keeping the diff-on-mismatch behavior.

### Implementation steps

- [ ] **Step 1: Write the test file**

Create `c:/git/fellwork/tools/derekh/tests/test-streaming-snapshot.ps1` with the following structure:

```powershell
#Requires -Version 7
# test-streaming-snapshot.ps1 — Streaming renderer golden-file snapshot tests.
#
# Runs fixed plans through Invoke-DhPlan -NoTui -NoColor, captures stdout,
# normalizes whitespace, and compares to golden files in tests/snapshots/.
#
# Three cases: all-success, all-fail, mixed-alerts.
#
# Golden files are created automatically on first run (GOLDEN: prefix).
# On subsequent runs, mismatches are reported as FAIL:.

$ErrorActionPreference = 'Stop'

$passCount = 0
$failCount = 0
$snapshotDir = Join-Path $PSScriptRoot 'snapshots'
if (-not (Test-Path $snapshotDir)) {
    New-Item -ItemType Directory -Path $snapshotDir | Out-Null
}

# ── Helpers ───────────────────────────────────────────────────────────────────

function Normalize-Snapshot([string]$text) {
    $text  = $text -replace "`r`n", "`n"
    $lines = $text -split "`n" | ForEach-Object { $_.TrimEnd() }
    return ($lines -join "`n").TrimEnd() + "`n"
}

function Compare-Snapshot {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Actual
    )
    $goldenPath = Join-Path $snapshotDir "$Name.txt"
    $normalized = Normalize-Snapshot $Actual

    if (-not (Test-Path $goldenPath)) {
        # First run: create the golden file
        Set-Content -Path $goldenPath -Value $normalized -Encoding UTF8 -NoNewline
        Write-Host "GOLDEN: $Name -- created at $goldenPath"
        $script:passCount++
        return
    }

    $expected = Normalize-Snapshot (Get-Content -Path $goldenPath -Raw -Encoding UTF8)
    if ($expected -eq $normalized) {
        Write-Host "PASS: $Name"
        $script:passCount++
    } else {
        Write-Host "FAIL: $Name -- snapshot mismatch" -ForegroundColor Red
        Write-Host "--- Expected ---" -ForegroundColor Cyan
        Write-Host $expected
        Write-Host "--- Actual ---" -ForegroundColor Cyan
        Write-Host $normalized
        $script:failCount++
    }
}

# ── Module setup ──────────────────────────────────────────────────────────────

$manifestPath = Join-Path $PSScriptRoot '../derekh.psd1'
Import-Module ([System.IO.Path]::GetFullPath($manifestPath)) -Force

# Stub animal phrases for determinism
function Get-DhAnimalPhrase {
    param([string]$Animal, [string]$Situation)
    return "[$Animal/$Situation]"
}

# ── Helper: capture streaming output ──────────────────────────────────────────

function Invoke-CaptureStreaming {
    param([hashtable]$Plan)
    # Capture all Write-Host output by redirecting the information stream
    $output = & {
        Invoke-DhPlan -Plan $Plan -NoTui -NoColor
    } 6>&1 | Out-String
    # Write-Host goes to stream 6 (information stream) in PS7
    # Fall back: if stream 6 is empty, try capturing stdout directly
    if ([string]::IsNullOrWhiteSpace($output)) {
        $output = Invoke-DhPlan -Plan $Plan -NoTui -NoColor | Out-String
    }
    return $output
}

# ── Case 1: all-success ───────────────────────────────────────────────────────

$planSuccess = New-DhPlan -Title 'Test Plan' -Subtitle '00:00:00' -Theme 'twilight'
$planSuccess = Add-DhLoopPhase -Plan $planSuccess -Name 'Clone repos' -Items @('api','web','ops') -Action {
    param($item)
    return New-DhResult -Success $true -Message "$item cloned"
}
$planSuccess = Add-DhLoopPhase -Plan $planSuccess -Name 'Proto install' -Items @('api','web','ops') -Action {
    param($item)
    return New-DhResult -Success $true -Message "$item tools installed"
}

$out1 = Invoke-CaptureStreaming -Plan $planSuccess
Compare-Snapshot -Name 'streaming-all-success' -Actual $out1

# ── Case 2: all-fail ─────────────────────────────────────────────────────────

$planFail = New-DhPlan -Title 'Test Plan' -Subtitle '00:00:00' -Theme 'twilight'
$planFail = Add-DhLoopPhase -Plan $planFail -Name 'Clone repos' -Items @('api','web') -Action {
    param($item)
    return New-DhResult -Success $false -Message "clone failed (exit 128)" `
        -FixCommand "git clone https://github.com/fellwork/$item.git" `
        -Animal 'octopus'
}

$out2 = Invoke-CaptureStreaming -Plan $planFail
Compare-Snapshot -Name 'streaming-all-fail' -Actual $out2

# ── Case 3: mixed with alerts ─────────────────────────────────────────────────

$planMixed = New-DhPlan -Title 'Test Plan' -Subtitle '00:00:00' -Theme 'twilight'
$planMixed = Add-DhLoopPhase -Plan $planMixed -Name 'Clone repos' -Items @('api','web','ops') -Action {
    param($item)
    if ($item -eq 'ops') {
        return New-DhResult -Success $false -Message "clone failed" `
            -FixCommand "git clone https://github.com/fellwork/ops.git" `
            -Animal 'raccoon'
    }
    return New-DhResult -Success $true -Message "$item cloned"
}
$planMixed = Add-DhSinglePhase -Plan $planMixed -Name 'Other prereqs' -Action {
    $alerts = @(
        (New-DhAlert -Severity 'warning' -Message 'wrangler is not installed' `
            -FixCommand 'npm install -g wrangler')
    )
    return New-DhResult -Success $true -Alerts $alerts
}

$out3 = Invoke-CaptureStreaming -Plan $planMixed
Compare-Snapshot -Name 'streaming-mixed-alerts' -Actual $out3

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host "Streaming snapshots: $passCount pass, $failCount fail"

if ($failCount -gt 0) { exit 1 } else { exit 0 }
```

- [ ] **Step 2: Run the tests for the first time (creates golden files)**

```bash
pwsh -NoProfile -File /c/git/fellwork/tools/derekh/tests/test-streaming-snapshot.ps1
```

Expected: three `GOLDEN: streaming-* -- created` lines, `3 pass, 0 fail`, exit 0.

- [ ] **Step 3: Inspect each golden file**

Read `c:/git/fellwork/tools/derekh/tests/snapshots/streaming-all-success.txt`, `streaming-all-fail.txt`, and `streaming-mixed-alerts.txt`. Verify:

For `streaming-all-success.txt`:
- First 4 lines are the banner (blank, rule, title+subtitle, rule).
- Two section headers (`── Clone repos ──...` and `── Proto install ──...`).
- Three tree lines per section: `├─ ✓ api`, `├─ ✓ web`, `└─ ✓ ops`.
- Summary section: `✓  2 / 2 phases completed`. No issues or next-steps sections.
- Closing otter phrase: `🦦  [otter/celebrate]`.

For `streaming-all-fail.txt`:
- Two tree lines: `├─ ✗ api` and `└─ ✗ web`.
- Summary: `✗  0 / 1 phases completed`, `✗  2 failure(s)`.
- Issues section with `[1]` and `[2]` entries, each with a `Fix:` line.
- Next-steps section with numbered list.
- Closing owl phrase: `🦉  [owl/pro-tip]`.

For `streaming-mixed-alerts.txt`:
- Loop section: `├─ ✓ api`, `├─ ✓ web`, `└─ ✗ ops`.
- Single-phase section: `✓ Other prereqs` with `(1/1)` if applicable.
- Summary: `⚠  1 / 2 phases completed` (or similar), warning count 1, failure count 1.
- Issues section: `[1] ✗ clone failed` (from ops), `[2] ⚠ wrangler is not installed`.
- Next-steps section with both fix commands.

If any golden file is wrong, delete it and fix the renderer before regenerating.

- [ ] **Step 4: Run the tests a second time (compare mode)**

```bash
pwsh -NoProfile -File /c/git/fellwork/tools/derekh/tests/test-streaming-snapshot.ps1
```

Expected: three `PASS: streaming-*` lines, `3 pass, 0 fail`, exit 0. No `GOLDEN:` lines this time.

- [ ] **Step 5: Run the full test suite**

```bash
pwsh -NoProfile -File /c/git/fellwork/tools/derekh/tests/run-all.ps1
```

Expected: all test suites pass (Phase A skeleton + new streaming-snapshot), total pass count increases by 3.

- [ ] **Step 6: Commit**

```bash
cd /c/git/fellwork/tools
git add derekh/tests/test-streaming-snapshot.ps1 derekh/tests/snapshots/
git commit -m "test(derekh/streaming): snapshot tests + golden files for streaming renderer (Phase E3)"
git push
```

---

## Phase E completion checklist

After all three tasks, verify:

- [ ] `c:/git/fellwork/tools/derekh/lib/streaming.ps1` exists and contains `Invoke-DhStreamingRender` and `Format-DhAnsi`
- [ ] `Invoke-DhPlan -Plan $plan -NoTui -NoColor` produces themed streaming output (no ANSI) with banner, section headers, tree lines, and summary
- [ ] `Invoke-DhPlan -Plan $plan` (without `-NoTui`) auto-engages streaming when stdout is redirected (pipe test passes)
- [ ] `NO_COLOR=1 Invoke-DhPlan -Plan $plan -NoTui` produces plain text (no ANSI codes) even without `-NoColor`
- [ ] `pwsh -NoProfile -File c:/git/fellwork/tools/derekh/tests/test-streaming-snapshot.ps1` exits 0 with 3 PASS lines
- [ ] `pwsh -NoProfile -File c:/git/fellwork/tools/derekh/tests/run-all.ps1` exits 0 with all prior tests still passing
- [ ] Golden files in `tests/snapshots/` are committed and contain human-readable plain text (no ANSI escape codes)
- [ ] Bootstrap's existing `lib/ui.ps1` and `bootstrap.ps1` are unmodified (derekh streaming renderer is separate)

**Phase F entry condition:** all items above pass. Phase F adds `lib/render.ps1`, `lib/input.ps1`, and `lib/clipboard.ps1` — the actual TUI drawing layer that uses cursor positioning and alternate screen buffer. The streaming renderer remains the fallback for all non-TTY contexts.
