# Derekh Phase D — Headless Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the entire plan-execution path through `Invoke-DhPlan -Headless`, emitting structured JSON to stdout. After Phase D, derekh is fully usable from agents and CI even before any TUI exists.

**Architecture:** Headless mode bypasses all rendering. `Invoke-DhPlan -Headless` validates plan → runs phases → serializes the final state hashtable to JSON. JSON shape is part of the v1 public contract (per spec §"Stability guarantee").

**Tech Stack:** PowerShell 7.5+, ConvertTo-Json, JSON snapshot files

**Spec:** `c:/git/fellwork/bootstrap/docs/superpowers/specs/2026-04-26-derekh-tui-design.md` (sections: Headless mode, Output format, Public API)

**Prerequisites:** Phase B complete — state.ps1, plan.ps1, theme.ps1, layout.ps1 all exist and tests pass.

---

## Task D1 — `lib/headless.ps1`: ConvertTo-DhStateJson

**Purpose:** Serialize the `$DerekhState` hashtable into the exact JSON shape mandated by spec §"Output format". This is the single source of truth for headless output — every field, key name, and null convention is locked here.

**Files:**
- Create: `derekh/lib/headless.ps1`

**JSON output shape (exact per spec):**

```json
{
  "version": "1.0.0",
  "title": "...",
  "subtitle": "...",
  "started_at": "2026-04-26T12:34:56Z",
  "completed_at": "2026-04-26T12:35:42Z",
  "exit_code": 0,
  "phases": [
    {
      "name": "...",
      "type": "loop",
      "status": "ok",
      "items": [
        { "name": "...", "status": "ok", "message": "..." }
      ]
    }
  ],
  "issues": [
    {
      "phase": "...",
      "severity": "warning",
      "message": "...",
      "fix_command": "...",
      "animal": "owl",
      "log_tail": null
    }
  ],
  "summary": {
    "phases_total": 2,
    "phases_ok": 2,
    "phases_failed": 0,
    "issues_total": 0,
    "warnings": 0,
    "failures": 0
  }
}
```

**Key conventions:**
- All JSON keys are `snake_case`
- Timestamps are ISO 8601 UTC with `Z` suffix (e.g. `2026-04-26T12:34:56Z`)
- `log_tail` is `null` (not omitted) when the action returned no log tail — explicit null is required
- `fix_command` is `null` (not omitted) when no fix command exists
- `items` is an empty array `[]` for `single`-type phases (they have no per-item loop)
- `status` values are lowercase strings: `"ok"`, `"failed"`, `"warning"`, `"running"`, `"pending"`
- `exit_code` is an integer: `0` clean, `1` warnings only, `2` any hard fail
- `version` comes from the module's `.psd1` manifest via `Get-DhVersion`

**Implementation notes:**
- Accept an optional `-OverrideTimestamp` parameter (a fixed ISO string) so tests can produce byte-stable output
- Use `ConvertTo-Json -Depth 10 -Compress:$false` for pretty output
- Ensure no ANSI escape codes appear in any string field (strip if present)
- The function is pure: it reads state, returns a string, writes nothing to stdout itself (caller writes)

---

- [ ] **Step D1-1: Write the failing test**

Create `derekh/tests/test-headless.ps1` with an initial test block for `ConvertTo-DhStateJson` in isolation. At this point `headless.ps1` does not exist, so the test must fail with "function not found."

```powershell
# derekh/tests/test-headless.ps1
#Requires -Version 7.5

[CmdletBinding()]
param(
    [switch]$UpdateGoldens
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$moduleRoot = Split-Path -Parent $PSScriptRoot
. "$moduleRoot/lib/state.ps1"
. "$moduleRoot/lib/plan.ps1"
. "$moduleRoot/lib/headless.ps1"   # will fail until D1-3

$failures = 0
$snapshotDir = "$PSScriptRoot/snapshots"

function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    if ($Expected -eq $Actual) {
        Write-Host "PASS: $Name" -ForegroundColor Green
    } else {
        Write-Host "FAIL: $Name" -ForegroundColor Red
        Write-Host "  Expected: $Expected" -ForegroundColor Yellow
        Write-Host "  Actual:   $Actual" -ForegroundColor Yellow
        $script:failures++
    }
}

function Assert-True {
    param([string]$Name, [bool]$Value)
    if ($Value) {
        Write-Host "PASS: $Name" -ForegroundColor Green
    } else {
        Write-Host "FAIL: $Name" -ForegroundColor Red
        $script:failures++
    }
}

# ── D1: ConvertTo-DhStateJson field correctness ──────────────────────────────

$fixedTs = "2026-04-26T12:00:00Z"
$fixedTsEnd = "2026-04-26T12:00:05Z"

$state = New-DhState -Plan @{
    Title    = "Test Plan"
    Subtitle = "12:00:00"
    Phases   = @(
        @{ Name = "Phase One"; Type = "loop"; Items = @("a","b"); Action = {} }
        @{ Name = "Phase Two"; Type = "single"; Action = {} }
    )
}
# Manually set timestamps (simulate completed run)
$state.StartedAt  = $fixedTs
$state.CompletedAt = $fixedTsEnd
$state.ExitCode    = 0

# Populate phases with synthetic completed data
$state.Phases[0].Status = "ok"
$state.Phases[0].Items  = @(
    @{ Name = "a"; Status = "ok";   Message = "done" }
    @{ Name = "b"; Status = "ok";   Message = "done" }
)
$state.Phases[1].Status = "ok"
$state.Phases[1].Items  = @()

$json = ConvertTo-DhStateJson -State $state -OverrideStartedAt $fixedTs -OverrideCompletedAt $fixedTsEnd
$parsed = $json | ConvertFrom-Json

Assert-Equal "D1: version field"    "1.0.0"       $parsed.version
Assert-Equal "D1: title field"      "Test Plan"   $parsed.title
Assert-Equal "D1: subtitle field"   "12:00:00"    $parsed.subtitle
Assert-Equal "D1: started_at"       $fixedTs      $parsed.started_at
Assert-Equal "D1: completed_at"     $fixedTsEnd   $parsed.completed_at
Assert-Equal "D1: exit_code"        0             $parsed.exit_code
Assert-Equal "D1: phases count"     2             $parsed.phases.Count
Assert-Equal "D1: phase[0].name"    "Phase One"   $parsed.phases[0].name
Assert-Equal "D1: phase[0].type"    "loop"        $parsed.phases[0].type
Assert-Equal "D1: phase[0].status"  "ok"          $parsed.phases[0].status
Assert-Equal "D1: phase[0].items count" 2         $parsed.phases[0].items.Count
Assert-Equal "D1: phase[1].type"    "single"      $parsed.phases[1].type
Assert-Equal "D1: phase[1].items"   0             $parsed.phases[1].items.Count
Assert-True  "D1: issues is array"  ($parsed.issues -is [array] -or $parsed.issues.Count -eq 0)
Assert-Equal "D1: summary.phases_total" 2         $parsed.summary.phases_total
Assert-Equal "D1: summary.phases_ok"    2         $parsed.summary.phases_ok
Assert-Equal "D1: summary.phases_failed" 0        $parsed.summary.phases_failed
Assert-Equal "D1: summary.issues_total" 0         $parsed.summary.issues_total
Assert-Equal "D1: summary.warnings"     0         $parsed.summary.warnings
Assert-Equal "D1: summary.failures"     0         $parsed.summary.failures

# D1: issues serialization with null fields
$state2 = New-DhState -Plan @{
    Title  = "Issue Plan"
    Phases = @(
        @{ Name = "Ph"; Type = "single"; Action = {} }
    )
}
$state2.StartedAt  = $fixedTs
$state2.CompletedAt = $fixedTsEnd
$state2.ExitCode    = 1
$state2.Issues     = @(
    @{
        Phase      = "Ph"
        Severity   = "warning"
        Message    = "wrangler not found"
        FixCommand = "npm install -g wrangler"
        Animal     = "owl"
        LogTail    = $null
    }
)
$state2.Phases[0].Status = "warning"
$state2.Phases[0].Items  = @()

$json2   = ConvertTo-DhStateJson -State $state2 -OverrideStartedAt $fixedTs -OverrideCompletedAt $fixedTsEnd
$parsed2 = $json2 | ConvertFrom-Json

Assert-Equal "D1: issue[0].phase"       "Ph"                   $parsed2.issues[0].phase
Assert-Equal "D1: issue[0].severity"    "warning"              $parsed2.issues[0].severity
Assert-Equal "D1: issue[0].message"     "wrangler not found"   $parsed2.issues[0].message
Assert-Equal "D1: issue[0].fix_command" "npm install -g wrangler" $parsed2.issues[0].fix_command
Assert-Equal "D1: issue[0].animal"      "owl"                  $parsed2.issues[0].animal
Assert-True  "D1: issue[0].log_tail is null" ($null -eq $parsed2.issues[0].log_tail)

# D1: No ANSI codes in output
Assert-True  "D1: no ANSI codes in json" (-not ($json -match '\x1b\['))
Assert-True  "D1: no ANSI codes in json2" (-not ($json2 -match '\x1b\['))

# D1: Valid JSON (parse roundtrip)
try {
    $null = $json | ConvertFrom-Json
    Write-Host "PASS: D1: json is valid JSON" -ForegroundColor Green
} catch {
    Write-Host "FAIL: D1: json is not valid JSON -- $_" -ForegroundColor Red
    $script:failures++
}

if ($failures -gt 0) {
    Write-Host "`n$failures test(s) failed." -ForegroundColor Red
    exit 1
} else {
    Write-Host "`nAll D1 unit tests passed." -ForegroundColor Green
}
```

- [ ] **Step D1-2: Run the test, confirm failure**

```powershell
pwsh -NoProfile -File derekh/tests/test-headless.ps1
# Expected: "Cannot find path ... headless.ps1" or "function not found" error
```

- [ ] **Step D1-3: Write the implementation**

Create `derekh/lib/headless.ps1`:

```powershell
# derekh/lib/headless.ps1
# Headless JSON serializer for Derekh state.
# Knows about: $DerekhState shape.
# Does NOT know about: drawing, ANSI, input, themes.
#
# Public:
#   ConvertTo-DhStateJson -State <hashtable> [-OverrideStartedAt <string>] [-OverrideCompletedAt <string>]
#     -> [string] JSON

Set-StrictMode -Version Latest

function ConvertTo-DhStateJson {
    <#
    .SYNOPSIS
        Serializes a $DerekhState hashtable to the v1 headless JSON contract.

    .PARAMETER State
        The $DerekhState hashtable produced by New-DhState and populated by
        Invoke-DhPlanPhases.

    .PARAMETER OverrideStartedAt
        ISO 8601 UTC string (e.g. "2026-04-26T12:00:00Z"). When supplied,
        overrides state.StartedAt. Used by tests for deterministic output.

    .PARAMETER OverrideCompletedAt
        ISO 8601 UTC string. When supplied, overrides state.CompletedAt.
        Used by tests for deterministic output.

    .OUTPUTS
        [string] Pretty-printed JSON with snake_case keys, no ANSI codes.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter()]
        [string]$OverrideStartedAt = '',

        [Parameter()]
        [string]$OverrideCompletedAt = ''
    )

    # Resolve timestamps
    $startedAt    = if ($OverrideStartedAt)    { $OverrideStartedAt }    else { $State.StartedAt }
    $completedAt  = if ($OverrideCompletedAt)  { $OverrideCompletedAt }  else { $State.CompletedAt }

    # Ensure UTC-Z format if the values are [datetime] objects
    if ($startedAt -is [datetime]) {
        $startedAt = $startedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    if ($completedAt -is [datetime]) {
        $completedAt = $completedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }

    # Resolve module version from .psd1 (best-effort; fallback to "1.0.0")
    $version = '1.0.0'
    try {
        $psd1 = Join-Path (Split-Path -Parent $PSScriptRoot) 'derekh.psd1'
        if (Test-Path $psd1) {
            $manifest = Import-PowerShellDataFile $psd1
            if ($manifest.ModuleVersion) { $version = $manifest.ModuleVersion.ToString() }
        }
    } catch { <# non-fatal; keep default #> }

    # Helper: strip ANSI escape codes from a string
    function Remove-Ansi([string]$s) {
        if ([string]::IsNullOrEmpty($s)) { return $s }
        return $s -replace '\x1b\[[0-9;]*[mGKHF]', ''
    }

    # Build phases array
    $phases = @(
        foreach ($ph in $State.Phases) {
            # Items: empty array for single phases
            $items = @(
                foreach ($item in $ph.Items) {
                    [ordered]@{
                        name    = Remove-Ansi ($item.Name    ?? '')
                        status  = ($item.Status ?? 'pending').ToLower()
                        message = Remove-Ansi ($item.Message ?? '')
                    }
                }
            )

            [ordered]@{
                name   = Remove-Ansi ($ph.Name   ?? '')
                type   = ($ph.Type ?? 'loop').ToLower()
                status = ($ph.Status ?? 'pending').ToLower()
                items  = $items
            }
        }
    )

    # Build issues array
    $issues = @(
        foreach ($issue in $State.Issues) {
            # log_tail: must be explicit null, not omitted
            $logTail = $null
            if ($issue.ContainsKey('LogTail') -and $null -ne $issue.LogTail) {
                $logTail = @($issue.LogTail | ForEach-Object { Remove-Ansi $_ })
            }

            # fix_command: explicit null when absent
            $fixCommand = $null
            if ($issue.ContainsKey('FixCommand') -and $null -ne $issue.FixCommand) {
                $fixCommand = Remove-Ansi $issue.FixCommand
            }

            [ordered]@{
                phase       = Remove-Ansi ($issue.Phase    ?? '')
                severity    = ($issue.Severity ?? 'info').ToLower()
                message     = Remove-Ansi ($issue.Message  ?? '')
                fix_command = $fixCommand
                animal      = ($issue.Animal ?? 'owl').ToLower()
                log_tail    = $logTail
            }
        }
    )

    # Compute summary
    $phasesOk     = @($State.Phases | Where-Object { $_.Status -eq 'ok' }).Count
    $phasesFailed = @($State.Phases | Where-Object { $_.Status -eq 'failed' }).Count
    $warnings     = @($State.Issues | Where-Object { ($_.Severity ?? '') -eq 'warning' }).Count
    $failures     = @($State.Issues | Where-Object { ($_.Severity ?? '') -eq 'fail' }).Count

    $document = [ordered]@{
        version      = $version
        title        = Remove-Ansi ($State.Title    ?? '')
        subtitle     = Remove-Ansi ($State.Subtitle ?? '')
        started_at   = $startedAt
        completed_at = $completedAt
        exit_code    = [int]($State.ExitCode ?? 0)
        phases       = $phases
        issues       = $issues
        summary      = [ordered]@{
            phases_total  = $State.Phases.Count
            phases_ok     = $phasesOk
            phases_failed = $phasesFailed
            issues_total  = $State.Issues.Count
            warnings      = $warnings
            failures      = $failures
        }
    }

    return $document | ConvertTo-Json -Depth 10
}
```

- [ ] **Step D1-4: Run the test, confirm pass**

```powershell
pwsh -NoProfile -File derekh/tests/test-headless.ps1
# Expected: all PASS lines, exit 0
```

- [ ] **Step D1-5: Commit**

```
git add derekh/lib/headless.ps1 derekh/tests/test-headless.ps1
git commit -m "feat(derekh): add ConvertTo-DhStateJson + D1 unit tests"
```

---

## Task D2 — `Invoke-DhPlan -Headless` wiring

**Purpose:** Implement the public `Invoke-DhPlan` function in `derekh.psm1` (or a dedicated `lib/invoke.ps1`). The `-Headless` path runs the full plan and serializes to JSON on stdout. The `-NoTui` and default-TUI paths are stubs that throw "not yet implemented" so the function signature is complete for all callers now.

**Files:**
- Modify: `derekh/derekh.psm1` (add `Invoke-DhPlan` implementation and dot-source `headless.ps1`)

**Auto-detect headless:** Per spec §"Execution modes", if stdout is not a TTY and `-NoTui` was not explicitly passed, headless is engaged automatically. In PowerShell this is: `[Console]::IsOutputRedirected` is `$true` (covers pipe, file redirect, and agent invocation). Explicit `-Headless` always wins regardless of TTY state.

**Exit code contract:** After `Invoke-DhPlan` writes JSON and returns, the caller sees `$LASTEXITCODE`. The function itself must call `exit $state.ExitCode` at the end of the headless path to propagate the exit code to the shell.

---

- [ ] **Step D2-1: Write the failing test**

Append to `derekh/tests/test-headless.ps1` (or create a separate test block file and include it from `run-all.ps1`). Add a new section that invokes `Invoke-DhPlan -Headless` as a subprocess and checks stdout JSON.

```powershell
# ── D2: Invoke-DhPlan -Headless subprocess integration ───────────────────────
# Use a helper plan script to avoid needing a real module import in the test.
# The helper script dot-sources the lib files directly.

$helperScript = @'
param([switch]$Headless, [switch]$NoTui)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$lib = "$PSScriptRoot/../../lib"
. "$lib/state.ps1"
. "$lib/plan.ps1"
. "$lib/headless.ps1"

# Import the module entry point for Invoke-DhPlan
. "$PSScriptRoot/../../derekh.psm1"

$plan = @{
    Title    = "D2 Test Plan"
    Subtitle = "00:00:00"
    Phases   = @(
        @{
            Name   = "Clone repos"
            Type   = "loop"
            Items  = @("api", "web")
            Action = {
                param($item)
                return @{ Success = $true; Message = "$item ok" }
            }
        }
    )
}

Invoke-DhPlan -Plan $plan -Headless -FixedTimeForTests "2026-01-01T00:00:00Z"
'@

$helperPath = Join-Path $env:TEMP "dh-d2-helper-$(Get-Random).ps1"
Set-Content -Path $helperPath -Value $helperScript -Encoding UTF8

try {
    $output = pwsh -NoProfile -File $helperPath -Headless 2>&1
    $exitCode = $LASTEXITCODE

    Assert-Equal "D2: process exits 0"          0          $exitCode
    Assert-True  "D2: stdout is non-empty"       ($output.Length -gt 0)

    $parsed = $output | ConvertFrom-Json
    Assert-True  "D2: parsed is object"          ($null -ne $parsed)
    Assert-Equal "D2: title field"               "D2 Test Plan"  $parsed.title
    Assert-Equal "D2: phases count"              1               $parsed.phases.Count
    Assert-Equal "D2: phase[0].name"             "Clone repos"   $parsed.phases[0].name
    Assert-Equal "D2: phase[0].items count"      2               $parsed.phases[0].items.Count
    Assert-Equal "D2: phase[0].items[0].status"  "ok"            $parsed.phases[0].items[0].status
    Assert-Equal "D2: exit_code field"           0               $parsed.exit_code
    Assert-True  "D2: no ANSI in stdout"         (-not ($output -match '\x1b\['))
} finally {
    Remove-Item -Path $helperPath -ErrorAction SilentlyContinue
}
```

- [ ] **Step D2-2: Run the test, confirm failure**

```powershell
pwsh -NoProfile -File derekh/tests/test-headless.ps1
# Expected: D2 tests fail — Invoke-DhPlan does not exist yet
```

- [ ] **Step D2-3: Write the implementation**

Add `Invoke-DhPlan` to `derekh/derekh.psm1`. Also ensure `headless.ps1` is dot-sourced in the module entry point.

```powershell
# In derekh/derekh.psm1 — dot-source all lib files then define the public API

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Dot-source lib files in dependency order
. "$PSScriptRoot/lib/state.ps1"
. "$PSScriptRoot/lib/plan.ps1"
. "$PSScriptRoot/lib/theme.ps1"
. "$PSScriptRoot/lib/layout.ps1"
. "$PSScriptRoot/lib/headless.ps1"
# streaming.ps1, render.ps1, input.ps1, clipboard.ps1 — added in Phase E/F

function Invoke-DhPlan {
    <#
    .SYNOPSIS
        Run a Derekh plan. The primary public entry point for all consumers.

    .PARAMETER Plan
        A hashtable describing the plan: Title, Subtitle, Theme, Phases.

    .PARAMETER Theme
        Optional theme name override. Overrides plan's Theme field.

    .PARAMETER Headless
        Emit JSON to stdout. No TUI or streaming output. Auto-engaged when
        stdout is redirected and -NoTui was not explicitly passed.

    .PARAMETER NoTui
        Use the streaming (non-TUI) renderer. Auto-engaged when stdout is
        not a TTY. Overrides auto-headless detection.

    .PARAMETER Ascii
        Force ASCII glyph fallback (no Unicode glyphs). Passed through to
        the theme system.

    .PARAMETER FixedTimeForTests
        ISO 8601 UTC string. When supplied, overrides all timestamps in
        headless output. Used only in test scenarios.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Plan,

        [Parameter()]
        [string]$Theme = '',

        [Parameter()]
        [switch]$Headless,

        [Parameter()]
        [switch]$NoTui,

        [Parameter()]
        [switch]$Ascii,

        [Parameter()]
        [string]$FixedTimeForTests = ''
    )

    # ── Mode resolution ───────────────────────────────────────────────────────
    # Auto-detect headless: stdout redirected AND -NoTui not explicitly passed.
    $autoHeadless = ([Console]::IsOutputRedirected) -and (-not $NoTui)
    $useHeadless  = $Headless -or $autoHeadless

    # ── Validate plan ─────────────────────────────────────────────────────────
    $validationErrors = Test-DhPlan -Plan $Plan
    if ($validationErrors.Count -gt 0) {
        $msg = "Invoke-DhPlan: plan validation failed:`n" + ($validationErrors -join "`n")
        throw $msg
    }

    # ── Build initial state ───────────────────────────────────────────────────
    $state = New-DhState -Plan $Plan

    # ── Headless path ─────────────────────────────────────────────────────────
    if ($useHeadless) {
        # Run all phases; state.ps1 / plan.ps1 record everything
        Invoke-DhPlanPhases -State $state -Plan $Plan

        # Mark completion timestamp
        if ($FixedTimeForTests) {
            $state.CompletedAt = $FixedTimeForTests
            $state.StartedAt   = $FixedTimeForTests
        } else {
            $state.CompletedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        }

        # Serialize to JSON and write to stdout
        $overrideStart = if ($FixedTimeForTests) { $FixedTimeForTests } else { '' }
        $overrideEnd   = if ($FixedTimeForTests) { $FixedTimeForTests } else { '' }
        $json = ConvertTo-DhStateJson -State $state `
                    -OverrideStartedAt $overrideStart `
                    -OverrideCompletedAt $overrideEnd

        Write-Output $json
        exit $state.ExitCode
    }

    # ── NoTui (streaming) path — Phase E stub ─────────────────────────────────
    if ($NoTui) {
        throw "Invoke-DhPlan -NoTui: Phase E (streaming renderer) not yet implemented."
    }

    # ── Default TUI path — Phase F stub ──────────────────────────────────────
    throw "Invoke-DhPlan (TUI): Phase F (TUI renderer) not yet implemented."
}
```

- [ ] **Step D2-4: Run the test, confirm pass**

```powershell
pwsh -NoProfile -File derekh/tests/test-headless.ps1
# Expected: all D1 and D2 assertions PASS, exit 0
```

- [ ] **Step D2-5: Verify stub behavior**

```powershell
# Confirm -NoTui stub throws
$output = pwsh -NoProfile -Command ". 'derekh/derekh.psm1'; Invoke-DhPlan -Plan @{Title='T';Phases=@()} -NoTui" 2>&1
if ($output -match "Phase E") { Write-Host "PASS: -NoTui stub throws Phase E message" -ForegroundColor Green }
else { Write-Host "FAIL: -NoTui stub message unexpected: $output" -ForegroundColor Red }

# Confirm default TUI stub throws
$output = pwsh -NoProfile -Command ". 'derekh/derekh.psm1'; Invoke-DhPlan -Plan @{Title='T';Phases=@()}" 2>&1
if ($output -match "Phase F") { Write-Host "PASS: TUI stub throws Phase F message" -ForegroundColor Green }
else { Write-Host "FAIL: TUI stub message unexpected: $output" -ForegroundColor Red }
```

- [ ] **Step D2-6: Commit**

```
git add derekh/derekh.psm1
git commit -m "feat(derekh): implement Invoke-DhPlan -Headless + stub -NoTui/-TUI"
```

---

## Task D3 — Headless integration tests with golden snapshots

**Purpose:** Feed five known fixed plans through `Invoke-DhPlan -Headless`, capture stdout JSON, assert structural correctness, and maintain byte-stable snapshot golden files. Snapshots normalize timestamps so they are diff-stable across runs.

**Files:**
- Create: `derekh/tests/snapshots/headless-all-success.json`
- Create: `derekh/tests/snapshots/headless-all-fail.json`
- Create: `derekh/tests/snapshots/headless-mixed-alerts.json`
- Create: `derekh/tests/snapshots/headless-single-shot.json`
- Create: `derekh/tests/snapshots/headless-empty.json`
- Modify: `derekh/tests/test-headless.ps1` (append D3 snapshot test section)

**Test scenarios:**

| Scenario | Description | Expected exit_code |
|---|---|---|
| `headless-all-success` | Two loop phases, all items succeed | `0` |
| `headless-all-fail` | One loop phase, all items fail | `2` |
| `headless-mixed-alerts` | Loop phase + single phase with warning alert | `1` |
| `headless-single-shot` | Single-type phase only, returns one alert | `1` |
| `headless-empty` | Plan with zero phases | `0` |

**Snapshot normalization:** Before comparing actual vs golden JSON, replace the `started_at` and `completed_at` values with a fixed sentinel string `"__TIMESTAMP__"`. This makes snapshots byte-stable across runs and machines.

---

- [ ] **Step D3-1: Write the failing test (snapshot section)**

Append to `derekh/tests/test-headless.ps1`:

```powershell
# ── D3: Snapshot integration tests ───────────────────────────────────────────

$FIXED_TS = "2026-01-01T00:00:00Z"

function New-HeadlessPlanScript {
    param([hashtable]$PlanDef, [string]$FixedTs)

    # Encode the action scriptblocks as literals. Since we can't serialize
    # scriptblocks through the file boundary, test plans use a simple pattern:
    # each item result is determined by the item name (fail if it starts with "!").
    $planLines = @(
        '$lib = "$PSScriptRoot/../../lib"'
        '. "$lib/state.ps1"'
        '. "$lib/plan.ps1"'
        '. "$lib/headless.ps1"'
        '. "$PSScriptRoot/../../derekh.psm1"'
    )

    return $planLines -join "`n"
}

function Invoke-HeadlessScenario {
    param(
        [Parameter(Mandatory)][string]$ScriptContent,
        [Parameter(Mandatory)][string]$FixedTs
    )
    $tmpScript = Join-Path $env:TEMP "dh-d3-$(Get-Random).ps1"
    Set-Content -Path $tmpScript -Value $ScriptContent -Encoding UTF8
    try {
        $raw      = pwsh -NoProfile -File $tmpScript 2>&1
        $exitCode = $LASTEXITCODE
        return @{ Output = ($raw -join "`n"); ExitCode = $exitCode }
    } finally {
        Remove-Item -Path $tmpScript -ErrorAction SilentlyContinue
    }
}

function Normalize-HeadlessJson {
    param([string]$Json)
    # Replace timestamp values with a sentinel for stable comparison
    return $Json -replace '"started_at"\s*:\s*"[^"]*"',   '"started_at": "__TIMESTAMP__"' `
                 -replace '"completed_at"\s*:\s*"[^"]*"', '"completed_at": "__TIMESTAMP__"'
}

function Compare-HeadlessSnapshot {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ActualJson
    )
    $goldenPath = Join-Path $snapshotDir "headless-$Name.json"
    $normalized = Normalize-HeadlessJson $ActualJson

    if ($UpdateGoldens -or -not (Test-Path $goldenPath)) {
        Set-Content -Path $goldenPath -Value $normalized -Encoding UTF8 -NoNewline
        Write-Host "GOLDEN: $Name -- written to $goldenPath" -ForegroundColor Cyan
        return
    }

    $expected = Get-Content -Path $goldenPath -Raw -Encoding UTF8
    # Normalize line endings
    $expected   = $expected   -replace "`r`n", "`n"
    $normalized = $normalized -replace "`r`n", "`n"

    if ($expected.TrimEnd() -eq $normalized.TrimEnd()) {
        Write-Host "PASS: snapshot $Name" -ForegroundColor Green
    } else {
        Write-Host "FAIL: snapshot $Name -- mismatch" -ForegroundColor Red
        Write-Host "--- Expected ---" -ForegroundColor Cyan
        Write-Host $expected
        Write-Host "--- Actual ---" -ForegroundColor Cyan
        Write-Host $normalized
        $script:failures++
    }
}

# ── Scenario: all-success ──────────────────────────────────────────────────
$allSuccessScript = @"
Set-StrictMode -Version Latest; `$ErrorActionPreference = 'Stop'
`$lib = "`$PSScriptRoot/../../lib"
. "`$lib/state.ps1"; . "`$lib/plan.ps1"; . "`$lib/headless.ps1"
. "`$PSScriptRoot/../../derekh.psm1"
`$plan = @{
    Title    = "All Success"
    Subtitle = "00:00:00"
    Phases   = @(
        @{ Name="Clone repos"; Type="loop"; Items=@("api","web")
           Action={ param(`$item); @{ Success=`$true; Message="`$item cloned" } } }
        @{ Name="Check tools"; Type="loop"; Items=@("git","node")
           Action={ param(`$item); @{ Success=`$true; Message="`$item ok" } } }
    )
}
Invoke-DhPlan -Plan `$plan -Headless -FixedTimeForTests "$FIXED_TS"
"@

$result = Invoke-HeadlessScenario -ScriptContent $allSuccessScript -FixedTs $FIXED_TS
Assert-Equal "D3: all-success exit code" 0 $result.ExitCode
$parsedAs = $result.Output | ConvertFrom-Json
Assert-Equal "D3: all-success exit_code field" 0 $parsedAs.exit_code
Assert-Equal "D3: all-success phases count"    2 $parsedAs.phases.Count
Assert-Equal "D3: all-success issues count"    0 $parsedAs.issues.Count
Compare-HeadlessSnapshot -Name "all-success" -ActualJson $result.Output

# ── Scenario: all-fail ─────────────────────────────────────────────────────
$allFailScript = @"
Set-StrictMode -Version Latest; `$ErrorActionPreference = 'Stop'
`$lib = "`$PSScriptRoot/../../lib"
. "`$lib/state.ps1"; . "`$lib/plan.ps1"; . "`$lib/headless.ps1"
. "`$PSScriptRoot/../../derekh.psm1"
`$plan = @{
    Title  = "All Fail"
    Phases = @(
        @{ Name="Install deps"; Type="loop"; Items=@("pkg-a","pkg-b")
           Action={ param(`$item)
               @{ Success=`$false; Severity="fail"; Message="`$item failed"
                  FixCommand="npm install `$item" } } }
    )
}
Invoke-DhPlan -Plan `$plan -Headless -FixedTimeForTests "$FIXED_TS"
"@

$result = Invoke-HeadlessScenario -ScriptContent $allFailScript -FixedTs $FIXED_TS
Assert-Equal "D3: all-fail exit code" 2 $result.ExitCode
$parsedAf = $result.Output | ConvertFrom-Json
Assert-Equal "D3: all-fail exit_code field"       2 $parsedAf.exit_code
Assert-Equal "D3: all-fail issues count"          2 $parsedAf.issues.Count
Assert-Equal "D3: all-fail summary.failures"      2 $parsedAf.summary.failures
Assert-Equal "D3: all-fail summary.phases_failed" 1 $parsedAf.summary.phases_failed
Compare-HeadlessSnapshot -Name "all-fail" -ActualJson $result.Output

# ── Scenario: mixed-alerts ─────────────────────────────────────────────────
$mixedScript = @"
Set-StrictMode -Version Latest; `$ErrorActionPreference = 'Stop'
`$lib = "`$PSScriptRoot/../../lib"
. "`$lib/state.ps1"; . "`$lib/plan.ps1"; . "`$lib/headless.ps1"
. "`$PSScriptRoot/../../derekh.psm1"
`$plan = @{
    Title  = "Mixed Alerts"
    Phases = @(
        @{ Name="Clone repos"; Type="loop"; Items=@("api")
           Action={ param(`$item); @{ Success=`$true; Message="`$item ok" } } }
        @{ Name="Prereqs"; Type="single"
           Action={
               @{ Success=`$true
                  Alerts=@(
                      @{ Severity="warning"; Message="wrangler not installed"
                         FixCommand="npm install -g wrangler" }
                  ) }
           } }
    )
}
Invoke-DhPlan -Plan `$plan -Headless -FixedTimeForTests "$FIXED_TS"
"@

$result = Invoke-HeadlessScenario -ScriptContent $mixedScript -FixedTs $FIXED_TS
Assert-Equal "D3: mixed-alerts exit code"          1 $result.ExitCode
$parsedMx = $result.Output | ConvertFrom-Json
Assert-Equal "D3: mixed-alerts exit_code field"    1 $parsedMx.exit_code
Assert-Equal "D3: mixed-alerts issues count"       1 $parsedMx.issues.Count
Assert-Equal "D3: mixed-alerts issue[0].severity" "warning" $parsedMx.issues[0].severity
Assert-Equal "D3: mixed-alerts summary.warnings"  1 $parsedMx.summary.warnings
Assert-Equal "D3: mixed-alerts summary.failures"  0 $parsedMx.summary.failures
Compare-HeadlessSnapshot -Name "mixed-alerts" -ActualJson $result.Output

# ── Scenario: single-shot ─────────────────────────────────────────────────
$singleScript = @"
Set-StrictMode -Version Latest; `$ErrorActionPreference = 'Stop'
`$lib = "`$PSScriptRoot/../../lib"
. "`$lib/state.ps1"; . "`$lib/plan.ps1"; . "`$lib/headless.ps1"
. "`$PSScriptRoot/../../derekh.psm1"
`$plan = @{
    Title  = "Single Shot"
    Phases = @(
        @{ Name="System check"; Type="single"
           Action={
               @{ Success=`$false; Severity="warning"; Message="node version old"
                  FixCommand="proto install node" }
           } }
    )
}
Invoke-DhPlan -Plan `$plan -Headless -FixedTimeForTests "$FIXED_TS"
"@

$result = Invoke-HeadlessScenario -ScriptContent $singleScript -FixedTs $FIXED_TS
Assert-Equal "D3: single-shot exit code"          1 $result.ExitCode
$parsedSs = $result.Output | ConvertFrom-Json
Assert-Equal "D3: single-shot phases count"       1 $parsedSs.phases.Count
Assert-Equal "D3: single-shot phase[0].type"      "single" $parsedSs.phases[0].type
Assert-Equal "D3: single-shot phase[0].items"     0 $parsedSs.phases[0].items.Count
Assert-Equal "D3: single-shot issues count"       1 $parsedSs.issues.Count
Compare-HeadlessSnapshot -Name "single-shot" -ActualJson $result.Output

# ── Scenario: empty plan ─────────────────────────────────────────────────
$emptyScript = @"
Set-StrictMode -Version Latest; `$ErrorActionPreference = 'Stop'
`$lib = "`$PSScriptRoot/../../lib"
. "`$lib/state.ps1"; . "`$lib/plan.ps1"; . "`$lib/headless.ps1"
. "`$PSScriptRoot/../../derekh.psm1"
`$plan = @{ Title = "Empty"; Phases = @() }
Invoke-DhPlan -Plan `$plan -Headless -FixedTimeForTests "$FIXED_TS"
"@

$result = Invoke-HeadlessScenario -ScriptContent $emptyScript -FixedTs $FIXED_TS
Assert-Equal "D3: empty exit code"          0 $result.ExitCode
$parsedEm = $result.Output | ConvertFrom-Json
Assert-Equal "D3: empty exit_code field"    0 $parsedEm.exit_code
Assert-Equal "D3: empty phases count"       0 $parsedEm.phases.Count
Assert-Equal "D3: empty issues count"       0 $parsedEm.issues.Count
Assert-Equal "D3: empty summary.phases_total" 0 $parsedEm.summary.phases_total
Compare-HeadlessSnapshot -Name "empty" -ActualJson $result.Output

# ── ANSI guard: none of the snapshots contain escape codes ────────────────
$allScenarios = @("all-success", "all-fail", "mixed-alerts", "single-shot", "empty")
foreach ($s in $allScenarios) {
    $goldenPath = Join-Path $snapshotDir "headless-$s.json"
    if (Test-Path $goldenPath) {
        $content = Get-Content -Path $goldenPath -Raw
        Assert-True "D3: no ANSI in headless-$s.json" (-not ($content -match '\x1b\['))
    }
}

# ── Final result ──────────────────────────────────────────────────────────
if ($failures -eq 0) {
    Write-Host "`nAll headless tests passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n$failures test(s) failed." -ForegroundColor Red
    Write-Host "To regenerate goldens: pwsh -NoProfile -File tests/test-headless.ps1 -UpdateGoldens" -ForegroundColor Yellow
    exit 1
}
```

- [ ] **Step D3-2: Run the test, confirm failure**

```powershell
pwsh -NoProfile -File derekh/tests/test-headless.ps1
# Expected: snapshot tests fail — golden files don't exist yet (unless -UpdateGoldens was passed)
```

- [ ] **Step D3-3: Generate initial golden snapshots**

Run with `-UpdateGoldens` to write the canonical JSON for each scenario. Review each golden file by hand before committing to confirm the JSON shape matches spec §"Output format" exactly.

```powershell
pwsh -NoProfile -File derekh/tests/test-headless.ps1 -UpdateGoldens
# Expected: "GOLDEN: all-success -- written to ..." x5
```

Verify each golden file manually:

```powershell
# Spot-check: all-success should have exit_code:0, 2 phases, 0 issues
Get-Content derekh/tests/snapshots/headless-all-success.json | ConvertFrom-Json | Select-Object exit_code, @{n='phases';e={$_.phases.Count}}, @{n='issues';e={$_.issues.Count}}

# all-fail should have exit_code:2, 1 phase, 2 issues, 2 failures
Get-Content derekh/tests/snapshots/headless-all-fail.json | ConvertFrom-Json | Select-Object exit_code, @{n='phases';e={$_.phases.Count}}, @{n='issues';e={$_.issues.Count}}, @{n='failures';e={$_.summary.failures}}

# timestamps replaced with __TIMESTAMP__ sentinel
Get-Content derekh/tests/snapshots/headless-all-success.json | Select-String "__TIMESTAMP__"
```

- [ ] **Step D3-4: Run the test, confirm pass**

```powershell
pwsh -NoProfile -File derekh/tests/test-headless.ps1
# Expected: all PASS, exit 0
```

- [ ] **Step D3-5: Wire into run-all.ps1**

Ensure `derekh/tests/run-all.ps1` includes the headless test:

```powershell
# In derekh/tests/run-all.ps1 — add after existing test invocations:
& pwsh -NoProfile -File "$PSScriptRoot/test-headless.ps1"
if ($LASTEXITCODE -ne 0) { $script:totalFailures++ }
```

- [ ] **Step D3-6: Run the full suite**

```powershell
pwsh -NoProfile -File derekh/tests/run-all.ps1
# Expected: all test files pass, exit 0
```

- [ ] **Step D3-7: Commit**

```
git add derekh/tests/test-headless.ps1 derekh/tests/snapshots/ derekh/tests/run-all.ps1
git commit -m "feat(derekh): add headless snapshot integration tests + golden files (Phase D complete)"
git push
```

---

## Phase D completion checklist

- [ ] `lib/headless.ps1` exists with `ConvertTo-DhStateJson` (accepts `$State`, `-OverrideStartedAt`, `-OverrideCompletedAt`)
- [ ] `ConvertTo-DhStateJson` emits snake_case keys, ISO 8601 UTC timestamps, explicit `null` for absent optional fields
- [ ] `Invoke-DhPlan -Headless` runs the plan, writes JSON to stdout, exits with `state.ExitCode`
- [ ] Auto-headless engages when `[Console]::IsOutputRedirected` is `$true` and `-NoTui` was not passed
- [ ] `-NoTui` stub throws "Phase E not yet implemented"
- [ ] Default TUI stub throws "Phase F not yet implemented"
- [ ] `FixedTimeForTests` parameter enables byte-stable timestamps in tests
- [ ] All five scenario tests pass: all-success, all-fail, mixed-alerts, single-shot, empty
- [ ] Golden snapshot files exist for all five scenarios with `__TIMESTAMP__` sentinel
- [ ] ANSI guard test verifies no `\x1b[` in any golden or output
- [ ] Exit code tests: exit 0 for clean, 1 for warnings, 2 for failures
- [ ] `run-all.ps1` includes headless tests
- [ ] Phase D changes are committed and pushed

---

## Appendix: Exit code logic reference

`$state.ExitCode` is computed by `plan.ps1` / `state.ps1` as each item result is recorded. The contract:

| Condition | ExitCode |
|---|---|
| No issues at all | `0` |
| Issues exist, all are severity `"warning"` | `1` |
| Any issue has severity `"fail"` | `2` |

This mirrors bootstrap's existing convention (0/1/2) and the spec's public API documentation.

---

## Appendix: `-FixedTimeForTests` flow

The `-FixedTimeForTests` parameter on `Invoke-DhPlan` threads through to `ConvertTo-DhStateJson`'s `-OverrideStartedAt` and `-OverrideCompletedAt` parameters. The state's actual timestamps are NOT replaced in `$state` itself — only in the JSON serialization step. This means:

1. Timestamps in `$state.StartedAt` / `$state.CompletedAt` still reflect real wall-clock time
2. Headless JSON output has the fixed test value
3. TUI / streaming renderers (Phase E/F) are unaffected by this parameter

This isolation keeps the test fixture clean without polluting the real state object.
