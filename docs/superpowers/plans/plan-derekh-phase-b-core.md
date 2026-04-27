# Derekh Phase B — Pure-Function Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build derekh's logic layer — state, plan execution, theme loading, layout math — all testable without a TUI.

**Architecture:** Each `lib/*.ps1` file owns ONE thing per spec §"Module boundaries". State is mutable hashtable + array operations. Plan dispatches user actions and writes events to state. Theme is JSON-loaded config with ASCII fallback. Layout is pure math returning rectangles.

**Tech Stack:** PowerShell 7.5+, JSON for theme files

**Spec:** `c:/git/fellwork/bootstrap/docs/superpowers/specs/2026-04-26-derekh-tui-design.md` (sections: Module boundaries, Data flow & plan schema, Theme schema, Region-redraw model)

**Prerequisites:** Phase A complete — `derekh.psd1` exists with all 9 exported function names, `derekh.psm1` dot-sources `lib/`, test runner works.

---

## Task B1 — `lib/state.ps1`: State Management

**What it owns:** The `$DerekhState` hashtable — phases, current phase, items per phase, issues, exit-code tracking. Zero knowledge of drawing, input, or themes.

**Functions to implement:**
- `New-DhState` — creates and returns a fresh state hashtable
- `Add-DhStatePhase` — appends a phase descriptor to state
- `Set-DhStatePhaseStatus` — sets a phase's `Status` field (`pending|running|ok|fail|warn`)
- `Add-DhStatePhaseItem` — appends an item result record under a named phase
- `Add-DhStateIssue` — appends an issue to the global issues list
- `Set-DhStateActive` — sets the currently-running item label (displayed by spinner)
- `Get-DhStateSummary` — returns a summary hashtable matching the headless JSON `summary` block

**State shape produced by `New-DhState`:**
```powershell
@{
    Title       = ""
    Subtitle    = ""
    StartedAt   = $null          # [datetime]
    CompletedAt = $null          # [datetime]
    ExitCode    = 0
    Phases      = @()            # ordered array of phase descriptors
    Issues      = @()            # ordered array of issue records
    ActiveLabel = ""             # label shown next to spinner
}
```

**Phase descriptor shape (appended by `Add-DhStatePhase`):**
```powershell
@{
    Name   = ""
    Type   = "loop|single"
    Status = "pending"           # pending|running|ok|fail|warn
    Items  = @()                 # loop phases only; array of item result records
}
```

**Item result record shape (appended by `Add-DhStatePhaseItem`):**
```powershell
@{
    Name     = ""
    Status   = "ok|fail|warn"
    Message  = ""
}
```

**Issue record shape (appended by `Add-DhStateIssue`):**
```powershell
@{
    Phase      = ""              # name of originating phase
    Severity   = "info|warning|fail"
    Message    = ""
    FixCommand = $null
    Animal     = $null
    LogTail    = $null
}
```

**Summary shape returned by `Get-DhStateSummary`:**
```powershell
@{
    PhasesTotal  = 0
    PhasesOk     = 0
    PhasesFailed = 0
    IssuesTotal  = 0
    Warnings     = 0
    Failures     = 0
}
```

---

### B1 Step 1 — Write failing test
- [ ] Create `derekh/tests/test-state.ps1` with the content below.
- [ ] The test file dot-sources `../lib/state.ps1` directly (no module import needed).

```powershell
# derekh/tests/test-state.ps1
. "$PSScriptRoot/../lib/state.ps1"

$failures = 0
function Assert-Equal($expected, $actual, $message) {
    if ($expected -ne $actual) {
        Write-Host "FAIL: $message — expected '$expected' got '$actual'" -ForegroundColor Red
        $script:failures++
    } else {
        Write-Host "PASS: $message" -ForegroundColor Green
    }
}
function Assert-True($condition, $message) {
    if (-not $condition) {
        Write-Host "FAIL: $message" -ForegroundColor Red
        $script:failures++
    } else {
        Write-Host "PASS: $message" -ForegroundColor Green
    }
}

# --- New-DhState ---
$state = New-DhState -Title "Test Plan" -Subtitle "12:00:00"
Assert-True ($state -is [hashtable]) "New-DhState returns hashtable"
Assert-Equal "Test Plan" $state.Title "Title is set"
Assert-Equal "12:00:00" $state.Subtitle "Subtitle is set"
Assert-Equal 0 $state.Phases.Count "Phases starts empty"
Assert-Equal 0 $state.Issues.Count "Issues starts empty"
Assert-Equal 0 $state.ExitCode "ExitCode starts 0"
Assert-Equal "" $state.ActiveLabel "ActiveLabel starts empty"

# --- Add-DhStatePhase ---
Add-DhStatePhase -State $state -Name "Clone repos" -Type "loop"
Assert-Equal 1 $state.Phases.Count "Add-DhStatePhase appends one phase"
Assert-Equal "Clone repos" $state.Phases[0].Name "Phase name set"
Assert-Equal "loop" $state.Phases[0].Type "Phase type set"
Assert-Equal "pending" $state.Phases[0].Status "Phase status starts pending"
Assert-Equal 0 $state.Phases[0].Items.Count "Phase items starts empty"

Add-DhStatePhase -State $state -Name "Check prereqs" -Type "single"
Assert-Equal 2 $state.Phases.Count "Second Add-DhStatePhase brings count to 2"
Assert-Equal "single" $state.Phases[1].Type "Second phase is single"

# --- Set-DhStatePhaseStatus ---
Set-DhStatePhaseStatus -State $state -PhaseName "Clone repos" -Status "running"
Assert-Equal "running" $state.Phases[0].Status "Set-DhStatePhaseStatus updates to running"

Set-DhStatePhaseStatus -State $state -PhaseName "Clone repos" -Status "ok"
Assert-Equal "ok" $state.Phases[0].Status "Set-DhStatePhaseStatus updates to ok"

Set-DhStatePhaseStatus -State $state -PhaseName "Check prereqs" -Status "fail"
Assert-Equal "fail" $state.Phases[1].Status "Set-DhStatePhaseStatus on second phase"

# --- Add-DhStatePhaseItem ---
Add-DhStatePhaseItem -State $state -PhaseName "Clone repos" -ItemName "api" -Status "ok" -Message "cloned"
Assert-Equal 1 $state.Phases[0].Items.Count "Add-DhStatePhaseItem appends item"
Assert-Equal "api" $state.Phases[0].Items[0].Name "Item name set"
Assert-Equal "ok" $state.Phases[0].Items[0].Status "Item status set"
Assert-Equal "cloned" $state.Phases[0].Items[0].Message "Item message set"

Add-DhStatePhaseItem -State $state -PhaseName "Clone repos" -ItemName "web" -Status "fail" -Message "timeout"
Assert-Equal 2 $state.Phases[0].Items.Count "Second item appended"
Assert-Equal "fail" $state.Phases[0].Items[1].Status "Second item status fail"

# --- Add-DhStateIssue ---
Add-DhStateIssue -State $state -Phase "Clone repos" -Severity "fail" -Message "web clone failed" -FixCommand "git clone web"
Assert-Equal 1 $state.Issues.Count "Add-DhStateIssue appends issue"
Assert-Equal "Clone repos" $state.Issues[0].Phase "Issue phase set"
Assert-Equal "fail" $state.Issues[0].Severity "Issue severity set"
Assert-Equal "web clone failed" $state.Issues[0].Message "Issue message set"
Assert-Equal "git clone web" $state.Issues[0].FixCommand "Issue FixCommand set"

Add-DhStateIssue -State $state -Phase "Check prereqs" -Severity "warning" -Message "wrangler missing"
Assert-Equal 2 $state.Issues.Count "Second issue appended"
Assert-Equal $null $state.Issues[1].FixCommand "FixCommand defaults to null"

# --- Set-DhStateActive ---
Set-DhStateActive -State $state -Label "cloning web..."
Assert-Equal "cloning web..." $state.ActiveLabel "Set-DhStateActive sets label"

Set-DhStateActive -State $state -Label ""
Assert-Equal "" $state.ActiveLabel "Set-DhStateActive can clear label"

# --- Get-DhStateSummary ---
$summary = Get-DhStateSummary -State $state
Assert-True ($summary -is [hashtable]) "Get-DhStateSummary returns hashtable"
Assert-Equal 2 $summary.PhasesTotal "PhasesTotal = 2"
Assert-Equal 1 $summary.PhasesOk "PhasesOk = 1 (Clone repos)"
Assert-Equal 1 $summary.PhasesFailed "PhasesFailed = 1 (Check prereqs)"
Assert-Equal 2 $summary.IssuesTotal "IssuesTotal = 2"
Assert-Equal 1 $summary.Warnings "Warnings = 1"
Assert-Equal 1 $summary.Failures "Failures = 1"

# ExitCode is updated by plan.ps1, not state.ps1; default is 0
Assert-Equal 0 $state.ExitCode "ExitCode still 0 (plan.ps1 owns this)"

if ($failures -eq 0) {
    Write-Host "`nAll state tests passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n$failures state test(s) failed." -ForegroundColor Red
    exit 1
}
```

### B1 Step 2 — Run test, expect failure
- [ ] Run: `pwsh derekh/tests/test-state.ps1`
- [ ] Confirm output contains `FAIL` lines (file doesn't exist yet).

### B1 Step 3 — Write implementation
- [ ] Create `derekh/lib/state.ps1` with the full implementation below.

```powershell
# derekh/lib/state.ps1
# Owns: $DerekhState hashtable — phases, items, issues, active label, exit code.
# Does NOT know about: drawing, input, themes.

function New-DhState {
    param(
        [string]$Title    = "",
        [string]$Subtitle = ""
    )
    return @{
        Title       = $Title
        Subtitle    = $Subtitle
        StartedAt   = $null
        CompletedAt = $null
        ExitCode    = 0
        Phases      = [System.Collections.ArrayList]@()
        Issues      = [System.Collections.ArrayList]@()
        ActiveLabel = ""
    }
}

function Add-DhStatePhase {
    param(
        [hashtable]$State,
        [string]$Name,
        [ValidateSet("loop","single")]
        [string]$Type
    )
    $null = $State.Phases.Add(@{
        Name   = $Name
        Type   = $Type
        Status = "pending"
        Items  = [System.Collections.ArrayList]@()
    })
}

function Set-DhStatePhaseStatus {
    param(
        [hashtable]$State,
        [string]$PhaseName,
        [ValidateSet("pending","running","ok","fail","warn")]
        [string]$Status
    )
    $phase = $State.Phases | Where-Object { $_.Name -eq $PhaseName } | Select-Object -First 1
    if ($null -ne $phase) {
        $phase.Status = $Status
    }
}

function Add-DhStatePhaseItem {
    param(
        [hashtable]$State,
        [string]$PhaseName,
        [string]$ItemName,
        [ValidateSet("ok","fail","warn")]
        [string]$Status,
        [string]$Message = ""
    )
    $phase = $State.Phases | Where-Object { $_.Name -eq $PhaseName } | Select-Object -First 1
    if ($null -ne $phase) {
        $null = $phase.Items.Add(@{
            Name    = $ItemName
            Status  = $Status
            Message = $Message
        })
    }
}

function Add-DhStateIssue {
    param(
        [hashtable]$State,
        [string]$Phase,
        [ValidateSet("info","warning","fail")]
        [string]$Severity,
        [string]$Message,
        [string]$FixCommand = $null,
        [string]$Animal     = $null,
        [array]$LogTail     = $null
    )
    $null = $State.Issues.Add(@{
        Phase      = $Phase
        Severity   = $Severity
        Message    = $Message
        FixCommand = $FixCommand
        Animal     = $Animal
        LogTail    = $LogTail
    })
}

function Set-DhStateActive {
    param(
        [hashtable]$State,
        [string]$Label
    )
    $State.ActiveLabel = $Label
}

function Get-DhStateSummary {
    param(
        [hashtable]$State
    )
    $phasesOk     = ($State.Phases | Where-Object { $_.Status -eq "ok" }).Count
    $phasesFailed = ($State.Phases | Where-Object { $_.Status -eq "fail" }).Count
    $warnings     = ($State.Issues | Where-Object { $_.Severity -eq "warning" }).Count
    $failures     = ($State.Issues | Where-Object { $_.Severity -eq "fail" }).Count

    return @{
        PhasesTotal  = $State.Phases.Count
        PhasesOk     = $phasesOk
        PhasesFailed = $phasesFailed
        IssuesTotal  = $State.Issues.Count
        Warnings     = $warnings
        Failures     = $failures
    }
}
```

### B1 Step 4 — Run test, expect pass
- [ ] Run: `pwsh derekh/tests/test-state.ps1`
- [ ] Confirm all `PASS` lines, exit 0.

### B1 Step 5 — Commit
- [ ] Stage and commit:
  ```
  git add derekh/lib/state.ps1 derekh/tests/test-state.ps1
  git commit -m "feat(state): New-DhState, phase/item/issue tracking, summary"
  git push origin main
  ```

---

## Task B2 — `lib/plan.ps1`: Plan Execution & Dispatch

**What it owns:** Plan validation, dispatching `loop` vs `single` phases, calling user action scriptblocks, normalizing return values to the full action contract, writing results to state. Does NOT know how state is rendered.

**Functions to implement:**
- `New-DhPlan` — creates and returns a plan hashtable
- `Add-DhLoopPhase` — appends a loop-type phase descriptor to the plan
- `Add-DhSinglePhase` — appends a single-type phase descriptor to the plan
- `New-DhResult` — builds a normalized action return hashtable
- `New-DhAlert` — builds a single alert hashtable for embedding in `Alerts`
- `Test-DhPlan` — validates a plan hashtable, returns `@{ Valid; Errors }` (no side effects)
- `Invoke-DhPlanPhases` — executes all plan phases against a state object (mutates state); returns exit code int

**Private helpers (not exported):**
- `_Get-DhDefaultAnimal` — maps Severity → animal string per spec
- `_Normalize-DhResult` — fills missing fields in an action's raw return value

**Action contract (exactly per spec §"Action return contract"):**
```powershell
@{
    Success    = $true | $false
    Message    = "..."
    Severity   = "info|warning|fail"     # defaults: $true→"info", $false→"fail"
    FixCommand = $null
    Animal     = $null                   # filled by _Get-DhDefaultAnimal if absent
    LogTail    = $null
    RetryHint  = $null
    Alerts     = @()
}
```

**Severity → default animal mapping (per spec §"Action exception handling"):**
| Severity | Default animal |
|---|---|
| `fail` | `raccoon` |
| `warning` | `owl` |
| `info` | `turtle` |

**Exception handling (per spec §"Action exception handling"):**
Every user action runs inside `try { & $action $item } catch { ... }`. An uncaught exception becomes:
```powershell
@{ Success=$false; Message=$_.Exception.Message; Severity="fail"; Animal="raccoon"; LogTail=@($_.ScriptStackTrace) }
```
Plan continues to next phase — errors are collected, not fatal.

**Alerts from single-shot phases (per spec §"Sub-issues from single-shot phases"):**
After a single-type phase action returns `Success=$true`, any items in its `Alerts` array are each written as separate issues via `Add-DhStateIssue`. Alerts have their own `Severity`, `Message`, and optional `FixCommand`.

**Loop phase dispatch:**
For each item in `Phase.Items`:
1. `Set-DhStateActive -State $state -Label $item` (or `$item.ToString()`)
2. Call `& $phase.Action $item` inside `try/catch`
3. Normalize result via `_Normalize-DhResult`
4. `Add-DhStatePhaseItem` with derived status
5. If not Success: `Add-DhStateIssue`
6. If Alerts present: each alert → `Add-DhStateIssue`

**Exit code logic:**
- Any `fail` severity issue → exit code 1
- Any `warning` severity issue (no fails) → exit code 2
- All ok → exit code 0

---

### B2 Step 1 — Write failing test
- [ ] Create `derekh/tests/test-plan.ps1` with the content below.

```powershell
# derekh/tests/test-plan.ps1
. "$PSScriptRoot/../lib/state.ps1"
. "$PSScriptRoot/../lib/plan.ps1"

$failures = 0
function Assert-Equal($expected, $actual, $message) {
    if ($expected -ne $actual) {
        Write-Host "FAIL: $message — expected '$expected' got '$actual'" -ForegroundColor Red
        $script:failures++
    } else {
        Write-Host "PASS: $message" -ForegroundColor Green
    }
}
function Assert-True($condition, $message) {
    if (-not $condition) {
        Write-Host "FAIL: $message" -ForegroundColor Red
        $script:failures++
    } else {
        Write-Host "PASS: $message" -ForegroundColor Green
    }
}

# --- New-DhPlan ---
$plan = New-DhPlan -Title "Test" -Subtitle "now" -Theme "twilight"
Assert-True ($plan -is [hashtable]) "New-DhPlan returns hashtable"
Assert-Equal "Test" $plan.Title "Title set"
Assert-Equal "now" $plan.Subtitle "Subtitle set"
Assert-Equal "twilight" $plan.Theme "Theme set"
Assert-Equal 0 $plan.Phases.Count "Phases starts empty"

# --- Add-DhLoopPhase ---
$items = @("api", "web")
$plan = Add-DhLoopPhase -Plan $plan -Name "Clone repos" -Items $items -Action { param($i) New-DhResult -Success $true -Message "$i ok" }
Assert-Equal 1 $plan.Phases.Count "Add-DhLoopPhase appends phase"
Assert-Equal "loop" $plan.Phases[0].Type "Phase type is loop"
Assert-Equal "Clone repos" $plan.Phases[0].Name "Phase name set"
Assert-Equal 2 $plan.Phases[0].Items.Count "Items array preserved"

# --- Add-DhSinglePhase ---
$plan = Add-DhSinglePhase -Plan $plan -Name "Check prereqs" -Action { New-DhResult -Success $true -Message "all good" }
Assert-Equal 2 $plan.Phases.Count "Add-DhSinglePhase appends second phase"
Assert-Equal "single" $plan.Phases[1].Type "Phase type is single"

# --- New-DhResult ---
$r = New-DhResult -Success $true -Message "done"
Assert-Equal $true $r.Success "Result Success=$true"
Assert-Equal "done" $r.Message "Result Message set"
Assert-Equal "info" $r.Severity "Success=true defaults Severity to info"
Assert-Equal $null $r.FixCommand "FixCommand defaults null"
Assert-Equal $null $r.Animal "Animal defaults null (filled at dispatch)"
Assert-True ($r.Alerts -is [array]) "Alerts is array"
Assert-Equal 0 $r.Alerts.Count "Alerts starts empty"

$rf = New-DhResult -Success $false -Message "boom" -FixCommand "fix it" -Severity "fail"
Assert-Equal $false $rf.Success "Result Success=$false"
Assert-Equal "fail" $rf.Severity "Explicit Severity preserved"
Assert-Equal "fix it" $rf.FixCommand "FixCommand set"

# --- New-DhAlert ---
$a = New-DhAlert -Severity "warning" -Message "watch out" -FixCommand "npm install"
Assert-Equal "warning" $a.Severity "Alert severity"
Assert-Equal "watch out" $a.Message "Alert message"
Assert-Equal "npm install" $a.FixCommand "Alert FixCommand"

$a2 = New-DhAlert -Severity "info" -Message "note"
Assert-Equal $null $a2.FixCommand "Alert FixCommand defaults null"

# --- Test-DhPlan ---
$valid = Test-DhPlan -Plan $plan
Assert-Equal $true $valid.Valid "Valid plan passes Test-DhPlan"
Assert-Equal 0 $valid.Errors.Count "No errors on valid plan"

$bad = @{ Title = "" }  # missing Phases key
$invalid = Test-DhPlan -Plan $bad
Assert-Equal $false $invalid.Valid "Plan missing Phases is invalid"
Assert-True ($invalid.Errors.Count -gt 0) "Invalid plan has Errors"

# --- Invoke-DhPlanPhases: loop phase, all success ---
$loopPlan = New-DhPlan -Title "Loop test"
$loopPlan = Add-DhLoopPhase -Plan $loopPlan -Name "Clone" -Items @("a","b") -Action {
    param($item) New-DhResult -Success $true -Message "$item cloned"
}
$state = New-DhState -Title "Loop test"
Add-DhStatePhase -State $state -Name "Clone" -Type "loop"
$exitCode = Invoke-DhPlanPhases -Plan $loopPlan -State $state
Assert-Equal 0 $exitCode "All-success loop → exit code 0"
Assert-Equal 0 $state.Issues.Count "No issues on all-success loop"
Assert-Equal "ok" $state.Phases[0].Status "Phase status ok after success"
Assert-Equal 2 $state.Phases[0].Items.Count "Two items recorded"

# --- Invoke-DhPlanPhases: loop phase, one failure ---
$loopFailPlan = New-DhPlan -Title "Loop fail"
$loopFailPlan = Add-DhLoopPhase -Plan $loopFailPlan -Name "Clone" -Items @("good","bad") -Action {
    param($item)
    if ($item -eq "bad") {
        return New-DhResult -Success $false -Message "$item failed" -FixCommand "retry $item" -Severity "fail"
    }
    return New-DhResult -Success $true -Message "$item ok"
}
$state2 = New-DhState -Title "Loop fail"
Add-DhStatePhase -State $state2 -Name "Clone" -Type "loop"
$exitCode2 = Invoke-DhPlanPhases -Plan $loopFailPlan -State $state2
Assert-Equal 1 $exitCode2 "One failure → exit code 1"
Assert-Equal 1 $state2.Issues.Count "One issue emitted"
Assert-Equal "fail" $state2.Issues[0].Severity "Issue severity is fail"
Assert-Equal "retry bad" $state2.Issues[0].FixCommand "FixCommand preserved on issue"
Assert-Equal "warn" $state2.Phases[0].Status "Phase status warn when partial failure"

# --- Invoke-DhPlanPhases: action throws → raccoon, plan continues ---
$throwPlan = New-DhPlan -Title "Throw test"
$throwPlan = Add-DhLoopPhase -Plan $throwPlan -Name "Risky" -Items @("explode") -Action {
    param($item) throw "something went wrong"
}
$state3 = New-DhState -Title "Throw test"
Add-DhStatePhase -State $state3 -Name "Risky" -Type "loop"
$exitCode3 = Invoke-DhPlanPhases -Plan $throwPlan -State $state3
Assert-Equal 1 $exitCode3 "Throw → exit code 1"
Assert-Equal 1 $state3.Issues.Count "Throw emits one issue"
Assert-Equal "fail" $state3.Issues[0].Severity "Thrown issue severity is fail"
Assert-Equal "raccoon" $state3.Issues[0].Animal "Thrown issue animal is raccoon"
Assert-True ($state3.Issues[0].Message -match "something went wrong") "Exception message captured"

# --- Invoke-DhPlanPhases: single phase with Alerts ---
$singlePlan = New-DhPlan -Title "Single test"
$singlePlan = Add-DhSinglePhase -Plan $singlePlan -Name "Prereqs" -Action {
    return New-DhResult -Success $true -Message "ok" -Alerts @(
        (New-DhAlert -Severity "warning" -Message "wrangler missing" -FixCommand "npm i -g wrangler"),
        (New-DhAlert -Severity "info"    -Message "optional dep absent")
    )
}
$state4 = New-DhState -Title "Single test"
Add-DhStatePhase -State $state4 -Name "Prereqs" -Type "single"
$exitCode4 = Invoke-DhPlanPhases -Plan $singlePlan -State $state4
Assert-Equal 2 $state4.Issues.Count "Two alerts become two issues"
Assert-Equal "warning" $state4.Issues[0].Severity "First alert severity warning"
Assert-Equal "info" $state4.Issues[1].Severity "Second alert severity info"
Assert-Equal "npm i -g wrangler" $state4.Issues[0].FixCommand "Alert FixCommand preserved"
Assert-Equal 2 $exitCode4 "Warning-only → exit code 2"

# --- _Get-DhDefaultAnimal (via side effect on result normalization) ---
# Verify animal defaults are applied when Animal field is null in result
$animalPlan = New-DhPlan -Title "Animal test"
$animalPlan = Add-DhLoopPhase -Plan $animalPlan -Name "Phase" -Items @("x") -Action {
    param($item)
    return New-DhResult -Success $false -Message "fail" -Severity "fail"
    # Animal not set → should become raccoon
}
$state5 = New-DhState -Title "Animal test"
Add-DhStatePhase -State $state5 -Name "Phase" -Type "loop"
Invoke-DhPlanPhases -Plan $animalPlan -State $state5 | Out-Null
Assert-Equal "raccoon" $state5.Issues[0].Animal "fail severity → raccoon default animal"

$warnPlan = New-DhPlan -Title "Warn animal"
$warnPlan = Add-DhLoopPhase -Plan $warnPlan -Name "Phase" -Items @("x") -Action {
    param($item)
    return New-DhResult -Success $false -Message "warn" -Severity "warning"
}
$state6 = New-DhState -Title "Warn animal"
Add-DhStatePhase -State $state6 -Name "Phase" -Type "loop"
Invoke-DhPlanPhases -Plan $warnPlan -State $state6 | Out-Null
Assert-Equal "owl" $state6.Issues[0].Animal "warning severity → owl default animal"

if ($failures -eq 0) {
    Write-Host "`nAll plan tests passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n$failures plan test(s) failed." -ForegroundColor Red
    exit 1
}
```

### B2 Step 2 — Run test, expect failure
- [ ] Run: `pwsh derekh/tests/test-plan.ps1`
- [ ] Confirm output contains `FAIL` lines.

### B2 Step 3 — Write implementation
- [ ] Create `derekh/lib/plan.ps1` with the full implementation below.

```powershell
# derekh/lib/plan.ps1
# Owns: plan validation, loop/single dispatch, action invocation, result normalization.
# Does NOT know: how state is rendered.

# ── Private helpers ──────────────────────────────────────────────────────────

function _Get-DhDefaultAnimal {
    param([string]$Severity)
    switch ($Severity) {
        "fail"    { return "raccoon" }
        "warning" { return "owl"     }
        "info"    { return "turtle"  }
        default   { return "raccoon" }
    }
}

function _Normalize-DhResult {
    param([hashtable]$Result, [bool]$WasThrow = $false)

    # Ensure Success field
    if (-not $Result.ContainsKey('Success')) { $Result.Success = $false }

    # Default Severity from Success
    if (-not $Result.ContainsKey('Severity') -or [string]::IsNullOrEmpty($Result.Severity)) {
        $Result.Severity = if ($Result.Success) { "info" } else { "fail" }
    }

    # Default Animal from Severity
    if (-not $Result.ContainsKey('Animal') -or $null -eq $Result.Animal) {
        $Result.Animal = _Get-DhDefaultAnimal -Severity $Result.Severity
    }

    # Ensure optional fields exist
    if (-not $Result.ContainsKey('Message'))    { $Result.Message    = "" }
    if (-not $Result.ContainsKey('FixCommand')) { $Result.FixCommand = $null }
    if (-not $Result.ContainsKey('LogTail'))    { $Result.LogTail    = $null }
    if (-not $Result.ContainsKey('RetryHint'))  { $Result.RetryHint  = $null }
    if (-not $Result.ContainsKey('Alerts'))     { $Result.Alerts     = @() }

    return $Result
}

# ── Public API ───────────────────────────────────────────────────────────────

function New-DhPlan {
    param(
        [Parameter(Mandatory)]
        [string]$Title,
        [string]$Subtitle = "",
        [string]$Theme    = "twilight"
    )
    return @{
        Title    = $Title
        Subtitle = $Subtitle
        Theme    = $Theme
        Phases   = [System.Collections.ArrayList]@()
    }
}

function Add-DhLoopPhase {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Plan,
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [array]$Items,
        [Parameter(Mandatory)]
        [scriptblock]$Action
    )
    $null = $Plan.Phases.Add(@{
        Name   = $Name
        Type   = "loop"
        Items  = $Items
        Action = $Action
    })
    return $Plan
}

function Add-DhSinglePhase {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Plan,
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [scriptblock]$Action
    )
    $null = $Plan.Phases.Add(@{
        Name   = $Name
        Type   = "single"
        Action = $Action
    })
    return $Plan
}

function New-DhResult {
    param(
        [Parameter(Mandatory)]
        [bool]$Success,
        [string]$Message    = "",
        [string]$Severity   = "",
        [string]$FixCommand = $null,
        [string]$Animal     = $null,
        [array]$LogTail     = $null,
        [hashtable]$RetryHint = $null,
        [array]$Alerts      = @()
    )
    $r = @{
        Success    = $Success
        Message    = $Message
        FixCommand = $FixCommand
        Animal     = $Animal
        LogTail    = $LogTail
        RetryHint  = $RetryHint
        Alerts     = $Alerts
    }
    # Apply default Severity
    if ([string]::IsNullOrEmpty($Severity)) {
        $r.Severity = if ($Success) { "info" } else { "fail" }
    } else {
        $r.Severity = $Severity
    }
    return $r
}

function New-DhAlert {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("info","warning","fail")]
        [string]$Severity,
        [Parameter(Mandatory)]
        [string]$Message,
        [string]$FixCommand = $null
    )
    return @{
        Severity   = $Severity
        Message    = $Message
        FixCommand = $FixCommand
    }
}

function Test-DhPlan {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Plan
    )
    $errors = [System.Collections.ArrayList]@()

    if (-not $Plan.ContainsKey('Title') -or [string]::IsNullOrEmpty($Plan.Title)) {
        $null = $errors.Add("Plan.Title is required")
    }
    if (-not $Plan.ContainsKey('Phases')) {
        $null = $errors.Add("Plan.Phases is required")
    } else {
        $i = 0
        foreach ($phase in $Plan.Phases) {
            if (-not $phase.ContainsKey('Name') -or [string]::IsNullOrEmpty($phase.Name)) {
                $null = $errors.Add("Phase[$i] missing Name")
            }
            if (-not $phase.ContainsKey('Type') -or $phase.Type -notin @("loop","single")) {
                $null = $errors.Add("Phase[$i] Type must be loop or single")
            }
            if (-not $phase.ContainsKey('Action') -or $phase.Action -isnot [scriptblock]) {
                $null = $errors.Add("Phase[$i] Action must be a scriptblock")
            }
            if ($phase.Type -eq "loop" -and (-not $phase.ContainsKey('Items') -or $null -eq $phase.Items)) {
                $null = $errors.Add("Phase[$i] loop phase requires Items")
            }
            $i++
        }
    }

    return @{
        Valid  = ($errors.Count -eq 0)
        Errors = @($errors)
    }
}

function Invoke-DhPlanPhases {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Plan,
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    foreach ($planPhase in $Plan.Phases) {
        # Find corresponding state phase by name
        $statePhase = $State.Phases | Where-Object { $_.Name -eq $planPhase.Name } | Select-Object -First 1
        Set-DhStatePhaseStatus -State $State -PhaseName $planPhase.Name -Status "running"

        $phaseHadFail = $false

        if ($planPhase.Type -eq "loop") {
            foreach ($item in $planPhase.Items) {
                Set-DhStateActive -State $State -Label $item.ToString()

                $result = $null
                try {
                    $result = & $planPhase.Action $item
                    if ($null -eq $result -or $result -isnot [hashtable]) {
                        $result = @{ Success = $true; Message = $item.ToString() }
                    }
                    $result = _Normalize-DhResult -Result $result
                } catch {
                    $result = _Normalize-DhResult -Result @{
                        Success  = $false
                        Message  = $_.Exception.Message
                        Severity = "fail"
                        Animal   = "raccoon"
                        LogTail  = @($_.ScriptStackTrace)
                    }
                }

                $itemStatus = if ($result.Success) { "ok" } else {
                    if ($result.Severity -eq "warning") { "warn" } else { "fail" }
                }
                Add-DhStatePhaseItem -State $State -PhaseName $planPhase.Name -ItemName $item.ToString() -Status $itemStatus -Message $result.Message

                if (-not $result.Success) {
                    $phaseHadFail = $true
                    Add-DhStateIssue -State $State -Phase $planPhase.Name -Severity $result.Severity `
                        -Message $result.Message -FixCommand $result.FixCommand `
                        -Animal $result.Animal -LogTail $result.LogTail
                }

                # Surface any alerts from loop items
                if ($result.Alerts -and $result.Alerts.Count -gt 0) {
                    foreach ($alert in $result.Alerts) {
                        Add-DhStateIssue -State $State -Phase $planPhase.Name -Severity $alert.Severity `
                            -Message $alert.Message -FixCommand $alert.FixCommand
                    }
                }
            }

            Set-DhStateActive -State $State -Label ""
            $phaseStatus = if ($phaseHadFail) {
                # Check if ALL items failed or just some
                $okCount = ($statePhase.Items | Where-Object { $_.Status -eq "ok" }).Count
                if ($okCount -gt 0) { "warn" } else { "fail" }
            } else { "ok" }
            Set-DhStatePhaseStatus -State $State -PhaseName $planPhase.Name -Status $phaseStatus

        } elseif ($planPhase.Type -eq "single") {
            Set-DhStateActive -State $State -Label $planPhase.Name

            $result = $null
            try {
                $result = & $planPhase.Action
                if ($null -eq $result -or $result -isnot [hashtable]) {
                    $result = @{ Success = $true; Message = $planPhase.Name }
                }
                $result = _Normalize-DhResult -Result $result
            } catch {
                $result = _Normalize-DhResult -Result @{
                    Success  = $false
                    Message  = $_.Exception.Message
                    Severity = "fail"
                    Animal   = "raccoon"
                    LogTail  = @($_.ScriptStackTrace)
                }
            }

            Set-DhStateActive -State $State -Label ""

            if (-not $result.Success) {
                $phaseHadFail = $true
                Add-DhStateIssue -State $State -Phase $planPhase.Name -Severity $result.Severity `
                    -Message $result.Message -FixCommand $result.FixCommand `
                    -Animal $result.Animal -LogTail $result.LogTail
            }

            # Surface alerts even on success
            if ($result.Alerts -and $result.Alerts.Count -gt 0) {
                foreach ($alert in $result.Alerts) {
                    Add-DhStateIssue -State $State -Phase $planPhase.Name -Severity $alert.Severity `
                        -Message $alert.Message -FixCommand $alert.FixCommand
                }
            }

            $phaseStatus = if ($phaseHadFail) { "fail" } else { "ok" }
            Set-DhStatePhaseStatus -State $State -PhaseName $planPhase.Name -Status $phaseStatus
        }
    }

    # Compute exit code from issues
    $hasFail    = ($State.Issues | Where-Object { $_.Severity -eq "fail" }).Count -gt 0
    $hasWarning = ($State.Issues | Where-Object { $_.Severity -eq "warning" }).Count -gt 0

    $exitCode = if ($hasFail) { 1 } elseif ($hasWarning) { 2 } else { 0 }
    $State.ExitCode = $exitCode
    return $exitCode
}
```

### B2 Step 4 — Run test, expect pass
- [ ] Run: `pwsh derekh/tests/test-plan.ps1`
- [ ] Confirm all `PASS` lines, exit 0.

### B2 Step 5 — Commit
- [ ] Stage and commit:
  ```
  git add derekh/lib/plan.ps1 derekh/tests/test-plan.ps1
  git commit -m "feat(plan): loop/single dispatch, action contract, throw→raccoon, alerts"
  git push origin main
  ```

---

## Task B3 — `lib/theme.ps1` + `themes/twilight.json`: Theme Loading

**What it owns:** JSON theme loading, theme cache, `Get-DhThemeColor` (hex → RGB), `Get-DhThemeGlyph` (with `-Ascii` switch routing to `ascii_fallback`), `Get-DhTheme`, `Test-DhTheme`. Does NOT know what anything is drawn.

**Functions to implement:**
- `Get-DhTheme` — loads a theme by name from `themes/` directory; caches in `$script:_DhThemeCache`; returns resolved theme hashtable
- `Get-DhThemeColor` — given a theme hashtable and a palette key (`"ok"`, `"fail"`, etc.), returns an `@{ R; G; B }` hashtable from hex
- `Get-DhThemeGlyph` — given a theme hashtable, a glyph key, and optional `-Ascii` switch, returns the correct string (from `glyphs` or `ascii_fallback`)
- `Test-DhTheme` — validates a loaded theme hashtable has all required keys; returns `@{ Valid; Errors }`

**Required palette keys:** `bg bg_alt fg frame title accent ok warn fail running pending dim chip_bg`

**Required glyph keys:** `phase_pending phase_running phase_ok phase_fail phase_warn spinner_frames progress_filled progress_empty frame_tl frame_tr frame_bl frame_br frame_h frame_v`

**Required section keys:** `header phases_pane active_pane issues_pane footer`

**Hex → RGB conversion:** Parse `#rrggbb` format, return `@{ R=[int]; G=[int]; B=[int] }`.

**Theme cache:** `$script:_DhThemeCache = @{}` — keyed by theme name. Invalidated by re-calling `Get-DhTheme -Force`.

**Theme file resolution:** `$PSScriptRoot/../themes/$Name.json` (relative to `theme.ps1`).

---

### B3 Step 1 — Write failing test
- [ ] Create `derekh/tests/test-theme.ps1` with the content below.

```powershell
# derekh/tests/test-theme.ps1
. "$PSScriptRoot/../lib/theme.ps1"

$failures = 0
function Assert-Equal($expected, $actual, $message) {
    if ($expected -ne $actual) {
        Write-Host "FAIL: $message — expected '$expected' got '$actual'" -ForegroundColor Red
        $script:failures++
    } else {
        Write-Host "PASS: $message" -ForegroundColor Green
    }
}
function Assert-True($condition, $message) {
    if (-not $condition) {
        Write-Host "FAIL: $message" -ForegroundColor Red
        $script:failures++
    } else {
        Write-Host "PASS: $message" -ForegroundColor Green
    }
}

# --- Get-DhTheme: loads twilight ---
$theme = Get-DhTheme -Name "twilight"
Assert-True ($theme -is [hashtable]) "Get-DhTheme returns hashtable"
Assert-Equal "twilight" $theme.name "Theme name field"
Assert-True ($theme.ContainsKey('palette')) "Theme has palette"
Assert-True ($theme.ContainsKey('glyphs')) "Theme has glyphs"
Assert-True ($theme.ContainsKey('sections')) "Theme has sections"
Assert-True ($theme.ContainsKey('ascii_fallback')) "Theme has ascii_fallback"

# --- Get-DhTheme: cache hit ---
$theme2 = Get-DhTheme -Name "twilight"
Assert-True ([object]::ReferenceEquals($theme, $theme2)) "Second call returns cached object"

# --- Get-DhTheme: -Force bypasses cache ---
$theme3 = Get-DhTheme -Name "twilight" -Force
Assert-True (-not [object]::ReferenceEquals($theme, $theme3)) "-Force returns fresh object"

# --- Get-DhTheme: unknown theme throws ---
$threw = $false
try { Get-DhTheme -Name "nonexistent_xyz" } catch { $threw = $true }
Assert-True $threw "Get-DhTheme with unknown theme throws"

# --- Test-DhTheme: valid theme ---
$v = Test-DhTheme -Theme $theme
Assert-Equal $true $v.Valid "twilight passes Test-DhTheme"
Assert-Equal 0 $v.Errors.Count "No errors on valid theme"

# --- Test-DhTheme: palette keys present ---
foreach ($key in @('bg','bg_alt','fg','frame','title','accent','ok','warn','fail','running','pending','dim','chip_bg')) {
    Assert-True $theme.palette.ContainsKey($key) "palette has key: $key"
}

# --- Test-DhTheme: glyph keys present ---
foreach ($key in @('phase_pending','phase_running','phase_ok','phase_fail','phase_warn','spinner_frames','progress_filled','progress_empty','frame_tl','frame_tr','frame_bl','frame_br','frame_h','frame_v')) {
    Assert-True ($theme.glyphs.PSObject.Properties.Name -contains $key -or $theme.glyphs.ContainsKey($key)) "glyphs has key: $key"
}

# --- Test-DhTheme: section keys present ---
foreach ($key in @('header','phases_pane','active_pane','issues_pane','footer')) {
    Assert-True ($theme.sections.PSObject.Properties.Name -contains $key -or $theme.sections.ContainsKey($key)) "sections has key: $key"
}

# --- Get-DhThemeColor: known key ---
$rgb = Get-DhThemeColor -Theme $theme -Key "ok"
Assert-True ($rgb -is [hashtable]) "Get-DhThemeColor returns hashtable"
Assert-True ($rgb.ContainsKey('R')) "RGB has R"
Assert-True ($rgb.ContainsKey('G')) "RGB has G"
Assert-True ($rgb.ContainsKey('B')) "RGB has B"
Assert-True ($rgb.R -ge 0 -and $rgb.R -le 255) "R in range"
Assert-True ($rgb.G -ge 0 -and $rgb.G -le 255) "G in range"
Assert-True ($rgb.B -ge 0 -and $rgb.B -le 255) "B in range"

# Twilight ok = #88e8a8 → R=136, G=232, B=168
Assert-Equal 136 $rgb.R "ok.R = 136 (#88e8a8)"
Assert-Equal 232 $rgb.G "ok.G = 232 (#88e8a8)"
Assert-Equal 168 $rgb.B "ok.B = 168 (#88e8a8)"

# --- Get-DhThemeColor: unknown key throws ---
$threw = $false
try { Get-DhThemeColor -Theme $theme -Key "not_a_key" } catch { $threw = $true }
Assert-True $threw "Get-DhThemeColor with unknown key throws"

# --- Get-DhThemeGlyph: unicode path ---
$glyph = Get-DhThemeGlyph -Theme $theme -Key "phase_ok"
Assert-Equal "✓" $glyph "phase_ok glyph is unicode checkmark"

$pendingGlyph = Get-DhThemeGlyph -Theme $theme -Key "phase_pending"
Assert-Equal "○" $pendingGlyph "phase_pending glyph is ○"

# --- Get-DhThemeGlyph: -Ascii switch routes to ascii_fallback ---
$asciiOk = Get-DhThemeGlyph -Theme $theme -Key "phase_ok" -Ascii
Assert-Equal "[+]" $asciiOk "phase_ok ascii fallback is [+]"

$asciiPending = Get-DhThemeGlyph -Theme $theme -Key "phase_pending" -Ascii
Assert-Equal "[ ]" $asciiPending "phase_pending ascii fallback is [ ]"

$asciiRunning = Get-DhThemeGlyph -Theme $theme -Key "phase_running" -Ascii
Assert-Equal "[~]" $asciiRunning "phase_running ascii fallback is [~]"

# --- Get-DhThemeGlyph: spinner_frames returns array ---
$frames = Get-DhThemeGlyph -Theme $theme -Key "spinner_frames"
Assert-True ($frames -is [array]) "spinner_frames returns array"
Assert-Equal 10 $frames.Count "spinner_frames has 10 unicode frames"

$asciiFrames = Get-DhThemeGlyph -Theme $theme -Key "spinner_frames" -Ascii
Assert-True ($asciiFrames -is [array]) "ascii spinner_frames returns array"
Assert-Equal 4 $asciiFrames.Count "ascii spinner_frames has 4 frames"

# --- phases_pane min/max widths from sections ---
$phasesSection = $theme.sections.phases_pane
Assert-True ($phasesSection.min_width -ge 1) "phases_pane.min_width is positive"
Assert-True ($phasesSection.max_width -ge $phasesSection.min_width) "phases_pane.max_width >= min_width"
Assert-Equal 24 $phasesSection.min_width "phases_pane min_width = 24"
Assert-Equal 32 $phasesSection.max_width "phases_pane max_width = 32"

if ($failures -eq 0) {
    Write-Host "`nAll theme tests passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n$failures theme test(s) failed." -ForegroundColor Red
    exit 1
}
```

### B3 Step 2 — Run test, expect failure
- [ ] Run: `pwsh derekh/tests/test-theme.ps1`
- [ ] Confirm output contains `FAIL` lines.

### B3 Step 3 — Write implementation

**3a.** Create `derekh/themes/twilight.json` (exact spec §"Schema structure"):

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
    "phase_pending":    "○",
    "phase_running":    "◐",
    "phase_ok":         "✓",
    "phase_fail":       "✗",
    "phase_warn":       "⚠",
    "spinner_frames":   ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"],
    "progress_filled":  "█",
    "progress_empty":   "░",
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
    "phase_pending":    "[ ]",
    "phase_running":    "[~]",
    "phase_ok":         "[+]",
    "phase_fail":       "[!]",
    "phase_warn":       "[?]",
    "spinner_frames":   ["|","/","-","\\"],
    "progress_filled":  "#",
    "progress_empty":   "-",
    "frame_tl": "+", "frame_tr": "+",
    "frame_bl": "+", "frame_br": "+",
    "frame_h":  "-", "frame_v":  "|",
    "frame_t":  "+", "frame_b":  "+", "frame_l": "+", "frame_r": "+"
  }
}
```

**3b.** Create `derekh/lib/theme.ps1`:

```powershell
# derekh/lib/theme.ps1
# Owns: JSON theme loading, theme cache, color hex→RGB, glyph lookup with ASCII fallback.
# Does NOT know: what anything is drawn.

$script:_DhThemeCache = @{}

function Get-DhTheme {
    param(
        [string]$Name  = "twilight",
        [switch]$Force
    )

    if (-not $Force -and $script:_DhThemeCache.ContainsKey($Name)) {
        return $script:_DhThemeCache[$Name]
    }

    $themePath = Join-Path $PSScriptRoot "../themes/$Name.json"
    if (-not (Test-Path $themePath)) {
        throw "Derekh theme not found: '$Name' (looked at: $themePath)"
    }

    $json  = Get-Content -Path $themePath -Raw -Encoding UTF8
    $theme = $json | ConvertFrom-Json -AsHashtable

    $script:_DhThemeCache[$Name] = $theme
    return $theme
}

function Get-DhThemeColor {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Theme,
        [Parameter(Mandatory)]
        [string]$Key
    )

    if (-not $Theme.palette.ContainsKey($Key)) {
        throw "Derekh theme palette has no key '$Key'"
    }

    $hex = $Theme.palette[$Key] -replace '^#', ''
    if ($hex.Length -ne 6) {
        throw "Derekh theme palette '$Key' has invalid hex value: #$hex"
    }

    return @{
        R = [Convert]::ToInt32($hex.Substring(0, 2), 16)
        G = [Convert]::ToInt32($hex.Substring(2, 2), 16)
        B = [Convert]::ToInt32($hex.Substring(4, 2), 16)
    }
}

function Get-DhThemeGlyph {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Theme,
        [Parameter(Mandatory)]
        [string]$Key,
        [switch]$Ascii
    )

    if ($Ascii) {
        # Route to ascii_fallback table
        if ($Theme.ascii_fallback.ContainsKey($Key)) {
            $val = $Theme.ascii_fallback[$Key]
            # Arrays come back from ConvertFrom-Json -AsHashtable as arrays
            return $val
        }
        # Not in ascii_fallback — fall through to unicode glyphs
    }

    if ($Theme.glyphs.ContainsKey($Key)) {
        return $Theme.glyphs[$Key]
    }

    throw "Derekh theme has no glyph key '$Key'"
}

function Test-DhTheme {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Theme
    )

    $errors = [System.Collections.ArrayList]@()

    # Top-level keys
    foreach ($k in @('name','palette','glyphs','sections','ascii_fallback')) {
        if (-not $Theme.ContainsKey($k)) {
            $null = $errors.Add("Theme missing top-level key: $k")
        }
    }

    if ($Theme.ContainsKey('palette')) {
        foreach ($k in @('bg','bg_alt','fg','frame','title','accent','ok','warn','fail','running','pending','dim','chip_bg')) {
            if (-not $Theme.palette.ContainsKey($k)) {
                $null = $errors.Add("Theme palette missing key: $k")
            }
        }
    }

    if ($Theme.ContainsKey('glyphs')) {
        foreach ($k in @('phase_pending','phase_running','phase_ok','phase_fail','phase_warn','spinner_frames','progress_filled','progress_empty','frame_tl','frame_tr','frame_bl','frame_br','frame_h','frame_v')) {
            if (-not $Theme.glyphs.ContainsKey($k)) {
                $null = $errors.Add("Theme glyphs missing key: $k")
            }
        }
    }

    if ($Theme.ContainsKey('sections')) {
        foreach ($k in @('header','phases_pane','active_pane','issues_pane','footer')) {
            if (-not $Theme.sections.ContainsKey($k)) {
                $null = $errors.Add("Theme sections missing key: $k")
            }
        }
    }

    return @{
        Valid  = ($errors.Count -eq 0)
        Errors = @($errors)
    }
}
```

### B3 Step 4 — Run test, expect pass
- [ ] Run: `pwsh derekh/tests/test-theme.ps1`
- [ ] Confirm all `PASS` lines, exit 0.

### B3 Step 5 — Commit
- [ ] Stage and commit:
  ```
  git add derekh/lib/theme.ps1 derekh/themes/twilight.json derekh/tests/test-theme.ps1
  git commit -m "feat(theme): JSON loader, hex→RGB, glyph lookup, ASCII fallback, twilight palette"
  git push origin main
  ```

---

## Task B4 — `lib/layout.ps1`: Layout Math

**What it owns:** Pure math computing 5 region rectangles from terminal dimensions, plan metadata, and theme section constraints. No cursor positioning, no escape codes.

**Functions to implement:**
- `Get-DhLayout` — given `Width`, `Height`, `Theme`; returns 5 named rectangles
- `Test-DhLayoutFits` — given `Width`, `Height`; returns `$true` if at least 60×15

**Rectangle shape:** `@{ X; Y; Width; Height }` (1-based, matching cursor positioning convention).

**5 regions (per spec §"Region-redraw model"):**

| Region | Description |
|---|---|
| `Header` | Top bar: row 1, full width |
| `PhasesPane` | Left column: rows 2..(H-1), width = clamped phases width |
| `ActivePane` | Right column upper: rows 2..mid, width = W - PhasesPane.Width |
| `IssuesPane` | Right column lower: rows mid+1..(H-1), width = W - PhasesPane.Width |
| `Footer` | Bottom bar: row H, full width |

**Phases pane width clamping (per spec §"Section widths are constraints"):**
- Preferred width = `theme.sections.phases_pane.max_width`
- Clamped to `[min_width .. max_width]` based on available terminal width
- If `W - min_width < 20` (not enough room for right pane), use `min_width`

**Right pane split:** `ActivePane` takes the top 40% of right-column rows (minimum 3 rows); `IssuesPane` takes the remaining rows.

**Minimum terminal size:** `Test-DhLayoutFits` returns `$false` for Width < 60 or Height < 15.

---

### B4 Step 1 — Write failing test
- [ ] Create `derekh/tests/test-layout.ps1` with the content below.

```powershell
# derekh/tests/test-layout.ps1
. "$PSScriptRoot/../lib/theme.ps1"
. "$PSScriptRoot/../lib/layout.ps1"

$failures = 0
function Assert-Equal($expected, $actual, $message) {
    if ($expected -ne $actual) {
        Write-Host "FAIL: $message — expected '$expected' got '$actual'" -ForegroundColor Red
        $script:failures++
    } else {
        Write-Host "PASS: $message" -ForegroundColor Green
    }
}
function Assert-True($condition, $message) {
    if (-not $condition) {
        Write-Host "FAIL: $message" -ForegroundColor Red
        $script:failures++
    } else {
        Write-Host "PASS: $message" -ForegroundColor Green
    }
}

$theme = Get-DhTheme -Name "twilight"

# --- Test-DhLayoutFits ---
Assert-Equal $true  (Test-DhLayoutFits -Width 60  -Height 15) "60x15 fits (minimum)"
Assert-Equal $true  (Test-DhLayoutFits -Width 120 -Height 30) "120x30 fits"
Assert-Equal $false (Test-DhLayoutFits -Width 59  -Height 15) "59x15 too narrow"
Assert-Equal $false (Test-DhLayoutFits -Width 60  -Height 14) "60x14 too short"
Assert-Equal $false (Test-DhLayoutFits -Width 40  -Height 10) "40x10 too small"
Assert-Equal $false (Test-DhLayoutFits -Width 0   -Height 0 ) "0x0 does not fit"

# --- Get-DhLayout: returns hashtable with 5 keys ---
$layout = Get-DhLayout -Width 120 -Height 40 -Theme $theme
Assert-True ($layout -is [hashtable]) "Get-DhLayout returns hashtable"
foreach ($region in @('Header','PhasesPane','ActivePane','IssuesPane','Footer')) {
    Assert-True ($layout.ContainsKey($region)) "Layout has key: $region"
}

# --- Each rectangle has X, Y, Width, Height ---
foreach ($region in @('Header','PhasesPane','ActivePane','IssuesPane','Footer')) {
    $r = $layout[$region]
    Assert-True ($r -is [hashtable]) "$region is hashtable"
    foreach ($k in @('X','Y','Width','Height')) {
        Assert-True ($r.ContainsKey($k)) "$region has key $k"
        Assert-True ($r[$k] -is [int]) "$region.$k is int"
        Assert-True ($r[$k] -ge 0) "$region.$k is non-negative"
    }
}

# --- Header occupies row 1, full width ---
$h = $layout.Header
Assert-Equal 1 $h.X "Header.X = 1"
Assert-Equal 1 $h.Y "Header.Y = 1"
Assert-Equal 120 $h.Width "Header.Width = terminal width"
Assert-Equal 1 $h.Height "Header.Height = 1"

# --- Footer occupies last row, full width ---
$f = $layout.Footer
Assert-Equal 1 $f.X "Footer.X = 1"
Assert-Equal 40 $f.Y "Footer.Y = terminal height"
Assert-Equal 120 $f.Width "Footer.Width = terminal width"
Assert-Equal 1 $f.Height "Footer.Height = 1"

# --- PhasesPane is in left column, rows 2..(H-1) ---
$pp = $layout.PhasesPane
Assert-Equal 1 $pp.X "PhasesPane.X = 1"
Assert-Equal 2 $pp.Y "PhasesPane.Y = 2"
Assert-Equal 38 $pp.Height "PhasesPane.Height = H - 2 (rows 2..39)"
Assert-True ($pp.Width -ge 24) "PhasesPane.Width >= min_width 24"
Assert-True ($pp.Width -le 32) "PhasesPane.Width <= max_width 32"

# --- ActivePane and IssuesPane are in right column ---
$ap = $layout.ActivePane
$ip = $layout.IssuesPane
$rightX = $pp.Width + 1
Assert-Equal $rightX $ap.X "ActivePane.X = PhasesPane.Width + 1"
Assert-Equal $rightX $ip.X "IssuesPane.X = PhasesPane.Width + 1"
Assert-Equal 2 $ap.Y "ActivePane.Y = 2"

$rightWidth = 120 - $pp.Width
Assert-Equal $rightWidth $ap.Width "ActivePane.Width = W - PhasesPane.Width"
Assert-Equal $rightWidth $ip.Width "IssuesPane.Width = W - PhasesPane.Width"

# ActivePane bottom row + 1 = IssuesPane top row
Assert-Equal ($ap.Y + $ap.Height) $ip.Y "IssuesPane starts immediately after ActivePane"

# IssuesPane bottom row = H - 1 (row 39 for 40-tall)
Assert-Equal 39 ($ip.Y + $ip.Height - 1) "IssuesPane bottom = H-1"

# ActivePane height is at least 3
Assert-True ($ap.Height -ge 3) "ActivePane.Height >= 3"

# Total right column height = ActivePane.Height + IssuesPane.Height
$totalRight = $ap.Height + $ip.Height
Assert-Equal 38 $totalRight "ActivePane + IssuesPane = H - 2 rows"

# --- Minimum terminal (60x15) — layout still valid ---
$minLayout = Get-DhLayout -Width 60 -Height 15 -Theme $theme
Assert-True ($minLayout -is [hashtable]) "60x15 layout returns hashtable"
Assert-Equal 60 $minLayout.Header.Width "60x15 Header.Width = 60"
Assert-Equal 15 $minLayout.Footer.Y "60x15 Footer.Y = 15"

$minPP = $minLayout.PhasesPane
Assert-True ($minPP.Width -ge 24) "60x15 PhasesPane.Width >= min_width"
Assert-True ($minPP.Width -le 32) "60x15 PhasesPane.Width <= max_width"

# Right pane is at least 1 column wide
$minRightWidth = 60 - $minPP.Width
Assert-True ($minRightWidth -ge 1) "60x15 right pane has at least 1 column"

# ActivePane height at minimum
Assert-True ($minLayout.ActivePane.Height -ge 3) "60x15 ActivePane.Height >= 3"

# --- PhasesPane width clamping: very wide terminal uses max_width ---
$wideLayout = Get-DhLayout -Width 200 -Height 50 -Theme $theme
Assert-Equal 32 $wideLayout.PhasesPane.Width "200-wide terminal uses max_width = 32"

# --- PhasesPane width clamping: narrow terminal uses min_width ---
$narrowLayout = Get-DhLayout -Width 60 -Height 20 -Theme $theme
Assert-Equal 24 $narrowLayout.PhasesPane.Width "60-wide terminal uses min_width = 24"

# --- No overlapping regions ---
# All regions are non-overlapping by construction: header=row1, panes=rows2..(H-1), footer=rowH
# Verify by checking Y ranges don't conflict between phases and active panes
Assert-True ($layout.PhasesPane.Y -eq $layout.ActivePane.Y) "PhasesPane and ActivePane start at same row"
Assert-True ($layout.PhasesPane.X -ne $layout.ActivePane.X) "PhasesPane and ActivePane are in different columns"

if ($failures -eq 0) {
    Write-Host "`nAll layout tests passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n$failures layout test(s) failed." -ForegroundColor Red
    exit 1
}
```

### B4 Step 2 — Run test, expect failure
- [ ] Run: `pwsh derekh/tests/test-layout.ps1`
- [ ] Confirm output contains `FAIL` lines.

### B4 Step 3 — Write implementation
- [ ] Create `derekh/lib/layout.ps1` with the full implementation below.

```powershell
# derekh/lib/layout.ps1
# Owns: pure layout math — (W, H, theme) → 5 region rectangles.
# Does NOT know: cursor positioning, escape codes.

function Test-DhLayoutFits {
    param(
        [Parameter(Mandatory)]
        [int]$Width,
        [Parameter(Mandatory)]
        [int]$Height
    )
    return ($Width -ge 60 -and $Height -ge 15)
}

function Get-DhLayout {
    param(
        [Parameter(Mandatory)]
        [int]$Width,
        [Parameter(Mandatory)]
        [int]$Height,
        [Parameter(Mandatory)]
        [hashtable]$Theme
    )

    # Phases pane width clamping per spec §"Section widths are constraints"
    $minW = [int]$Theme.sections.phases_pane.min_width
    $maxW = [int]$Theme.sections.phases_pane.max_width

    # Use max_width if there's room; otherwise clamp to min_width
    $phasesWidth = if (($Width - $maxW) -ge 20) {
        $maxW
    } else {
        $minW
    }

    # Clamp to [minW .. maxW] in all cases
    if ($phasesWidth -lt $minW) { $phasesWidth = $minW }
    if ($phasesWidth -gt $maxW) { $phasesWidth = $maxW }

    $rightX     = $phasesWidth + 1
    $rightWidth = $Width - $phasesWidth

    # Inner rows: rows 2..(H-1), count = H - 2
    $innerRows = $Height - 2

    # ActivePane takes top 40% of inner rows, minimum 3
    $activeHeight = [Math]::Max(3, [int]([Math]::Floor($innerRows * 0.4)))
    # Cap so IssuesPane gets at least 1 row
    if ($activeHeight -ge $innerRows) { $activeHeight = $innerRows - 1 }
    $issuesHeight = $innerRows - $activeHeight

    $issuesY = 2 + $activeHeight   # starts immediately after ActivePane

    return @{
        Header = @{
            X      = 1
            Y      = 1
            Width  = $Width
            Height = 1
        }
        PhasesPane = @{
            X      = 1
            Y      = 2
            Width  = $phasesWidth
            Height = $innerRows
        }
        ActivePane = @{
            X      = $rightX
            Y      = 2
            Width  = $rightWidth
            Height = $activeHeight
        }
        IssuesPane = @{
            X      = $rightX
            Y      = $issuesY
            Width  = $rightWidth
            Height = $issuesHeight
        }
        Footer = @{
            X      = 1
            Y      = $Height
            Width  = $Width
            Height = 1
        }
    }
}
```

### B4 Step 4 — Run test, expect pass
- [ ] Run: `pwsh derekh/tests/test-layout.ps1`
- [ ] Confirm all `PASS` lines, exit 0.

### B4 Step 5 — Commit
- [ ] Stage and commit:
  ```
  git add derekh/lib/layout.ps1 derekh/tests/test-layout.ps1
  git commit -m "feat(layout): Get-DhLayout 5 regions, Test-DhLayoutFits 60x15 minimum"
  git push origin main
  ```

---

## Phase B Completion Checklist

- [ ] All 4 test files pass with 0 failures
- [ ] `derekh/lib/state.ps1` — 7 exported functions
- [ ] `derekh/lib/plan.ps1` — 7 exported functions + 2 private helpers
- [ ] `derekh/lib/theme.ps1` — 4 exported functions + theme cache
- [ ] `derekh/themes/twilight.json` — full spec-conformant palette + glyphs + sections + ascii_fallback
- [ ] `derekh/lib/layout.ps1` — 2 exported functions, pure math
- [ ] `derekh/tests/test-state.ps1`, `test-plan.ps1`, `test-theme.ps1`, `test-layout.ps1` — all present
- [ ] 4 commits pushed to `fellwork/tools` origin

## Phase B → Phase C handoff

Phase C (Theme system) expands on what B3 started — it adds `Test-DhEnvironment` for true-color / UTF-8 / TTY detection, multiple theme files, `Get-DhVersion` reading from `derekh.psd1`, and the `themes/README.md` schema documentation. It builds on the B3 theme loader without changing its interface.
