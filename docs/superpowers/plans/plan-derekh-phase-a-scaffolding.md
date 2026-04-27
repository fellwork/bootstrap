# Derekh Phase A — Scaffolding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create the `fellwork/tools` GitHub repo, scaffold the `derekh/` PowerShell module structure with a working manifest and dot-sourcing entry point, and deliver a passing auto-discovery test runner so that `Import-Module derekh.psd1` works and `pwsh tests/run-all.ps1` exits 0.

**Architecture:** A new public GitHub repo `fellwork/tools` hosts shared Fellwork CLI infrastructure; `derekh/` is its first subdirectory and contains a PowerShell module. The module manifest (`derekh.psd1`) declares the full public API surface; the root module (`derekh.psm1`) dot-sources every `*.ps1` file in `lib/` so future phases can drop files there without touching the entry point. The test runner mirrors the bootstrap pattern exactly: auto-discovers `test-*.ps1` files in `tests/`, spawns each in a fresh `pwsh` process, tallies `PASS:`/`FAIL:` lines, and exits 0 only when all suites pass.

**Tech Stack:** PowerShell 7.5+, GitHub CLI (gh)

**Spec:** `c:/git/fellwork/bootstrap/docs/superpowers/specs/2026-04-26-derekh-tui-design.md` (sections: Architecture, Repo structure, Module boundaries, Public API)

**Prerequisites:** `gh auth status` shows logged in with `repo` scope; `c:/git/fellwork/` exists as the parent directory for the local clone.

---

## Task A1: Create GitHub repo and local clone

**Files:**
- Create (local): `c:/git/fellwork/tools/.gitignore`
- Create (local): `c:/git/fellwork/tools/README.md`

- [ ] **Step 1: Verify auth and parent directory**

```bash
gh auth status
ls /c/git/fellwork/
```

Expected: `gh auth status` reports a logged-in account with `repo` scope. `ls` shows existing sibling repos (`api`, `web`, `bootstrap`, etc.).

- [ ] **Step 2: Create the GitHub repo (idempotent)**

```bash
gh repo view fellwork/tools --json name 2>/dev/null \
  || gh repo create fellwork/tools --public --description "Shared CLI tooling — Derekh TUI framework + future tools"
```

Expected: either "already exists" JSON output, or confirmation that the new repo was created at `https://github.com/fellwork/tools`.

- [ ] **Step 3: Clone into the workspace**

```bash
git clone https://github.com/fellwork/tools.git /c/git/fellwork/tools
```

Expected: repo cloned to `c:/git/fellwork/tools`; `git remote -v` shows `origin` pointing at `https://github.com/fellwork/tools.git`.

- [ ] **Step 4: Write `.gitignore`**

Create `c:/git/fellwork/tools/.gitignore` with the following contents:

```
# PowerShell test artifacts
*.log
*.tmp

# OS artifacts
.DS_Store
Thumbs.db
desktop.ini

# JetBrains / VS Code
.idea/
.vscode/
*.code-workspace

# Pester output (if adopted later)
TestResults.xml
coverage.xml
```

- [ ] **Step 5: Write top-level `README.md`**

Create `c:/git/fellwork/tools/README.md` with the following contents:

```markdown
# fellwork/tools

Shared CLI infrastructure for the Fellwork workspace.

## Tools

| Tool | Path | Purpose |
|---|---|---|
| Derekh | `derekh/` | Reusable TUI framework for Fellwork CLI tools |

## Setup

```powershell
# From any sibling repo:
Import-Module ../tools/derekh/derekh.psd1
```

See each tool's own `README.md` for usage details.

## Structure

```
tools/
├── README.md
├── .gitignore
└── derekh/          # PowerShell TUI framework
```

## Adding a new tool

Create a subdirectory under `tools/` and document it in the table above.
```

- [ ] **Step 6: Commit and push**

```bash
cd /c/git/fellwork/tools
git add .gitignore README.md
git commit -m "chore: init tools repo with .gitignore and README"
git push -u origin main
```

Expected: push succeeds; `git log --oneline` shows exactly one commit on `main`.

---

## Task A2: Derekh module skeleton

**Files:**
- Create: `c:/git/fellwork/tools/derekh/derekh.psd1`
- Create: `c:/git/fellwork/tools/derekh/derekh.psm1`
- Create: `c:/git/fellwork/tools/derekh/README.md`
- Create (empty dirs): `c:/git/fellwork/tools/derekh/lib/`
- Create (empty dirs): `c:/git/fellwork/tools/derekh/themes/`
- Create (empty dirs): `c:/git/fellwork/tools/derekh/tests/`
- Create (gitkeep): `c:/git/fellwork/tools/derekh/lib/.gitkeep`
- Create (gitkeep): `c:/git/fellwork/tools/derekh/themes/.gitkeep`

- [ ] **Step 1: Create directory structure**

```bash
mkdir -p /c/git/fellwork/tools/derekh/lib
mkdir -p /c/git/fellwork/tools/derekh/themes
mkdir -p /c/git/fellwork/tools/derekh/tests
touch /c/git/fellwork/tools/derekh/lib/.gitkeep
touch /c/git/fellwork/tools/derekh/themes/.gitkeep
```

Expected: all four directories exist under `c:/git/fellwork/tools/derekh/`.

- [ ] **Step 2: Write `derekh.psd1` (module manifest)**

Create `c:/git/fellwork/tools/derekh/derekh.psd1` with the following exact contents:

```powershell
@{
    # Module identity
    RootModule        = 'derekh.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'a4f7e231-3c8b-4d92-b015-6f9e2d47c130'
    Author            = 'Shane McGuirt'
    CompanyName       = 'Fellwork'
    Copyright         = '(c) 2026 Shane McGuirt. MIT License.'
    Description       = 'Derekh — reusable terminal-UI framework for Fellwork CLI tools'
    PowerShellVersion = '7.0'

    # Public API surface — all 9 exported functions
    FunctionsToExport = @(
        'Invoke-DhPlan'
        'New-DhPlan'
        'Add-DhLoopPhase'
        'Add-DhSinglePhase'
        'New-DhResult'
        'New-DhAlert'
        'Get-DhTheme'
        'Get-DhVersion'
        'Test-DhEnvironment'
    )

    # No variables, aliases, or cmdlets exported in v1
    VariablesToExport = @()
    AliasesToExport   = @()
    CmdletsToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('TUI', 'CLI', 'Fellwork', 'Dashboard')
            ProjectUri = 'https://github.com/fellwork/tools'
        }
    }
}
```

- [ ] **Step 3: Write `derekh.psm1` (module entry point)**

Create `c:/git/fellwork/tools/derekh/derekh.psm1` with the following exact contents:

```powershell
#Requires -Version 7
# derekh.psm1 — Module entry point.
#
# Dot-sources every *.ps1 in lib/ in alphabetical order.
# Add a new lib file and it is automatically available — no changes needed here.
# Implementation lives in lib/; this file is just the loader.

$ErrorActionPreference = 'Stop'

$libDir = Join-Path $PSScriptRoot 'lib'

if (Test-Path $libDir) {
    Get-ChildItem -Path $libDir -Filter '*.ps1' | Sort-Object Name | ForEach-Object {
        . $_.FullName
    }
}

# Phase A: lib/ is empty. The functions below are stubs so that
# Import-Module succeeds and FunctionsToExport is satisfied.
# Each stub will be replaced by its real implementation in Phase B–F.

function Invoke-DhPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Plan,
        [string]$Theme,
        [switch]$Headless,
        [switch]$NoTui,
        [switch]$Ascii
    )
    throw [System.NotImplementedException]::new('Invoke-DhPlan is not yet implemented (Phase F).')
}

function New-DhPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$Subtitle,
        [string]$Theme = 'twilight'
    )
    throw [System.NotImplementedException]::new('New-DhPlan is not yet implemented (Phase B).')
}

function Add-DhLoopPhase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Plan,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][array]$Items,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    throw [System.NotImplementedException]::new('Add-DhLoopPhase is not yet implemented (Phase B).')
}

function Add-DhSinglePhase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Plan,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    throw [System.NotImplementedException]::new('Add-DhSinglePhase is not yet implemented (Phase B).')
}

function New-DhResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$Success,
        [string]$Message,
        [string]$FixCommand,
        [string]$Severity,
        [array]$LogTail,
        [hashtable]$RetryHint,
        [string]$Animal
    )
    throw [System.NotImplementedException]::new('New-DhResult is not yet implemented (Phase B).')
}

function New-DhAlert {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Severity,
        [Parameter(Mandatory)][string]$Message,
        [string]$FixCommand
    )
    throw [System.NotImplementedException]::new('New-DhAlert is not yet implemented (Phase B).')
}

function Get-DhTheme {
    [CmdletBinding()]
    param(
        [string]$Name = 'twilight'
    )
    throw [System.NotImplementedException]::new('Get-DhTheme is not yet implemented (Phase C).')
}

function Get-DhVersion {
    [CmdletBinding()]
    param()
    $manifest = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'derekh.psd1')
    return $manifest.ModuleVersion
}

function Test-DhEnvironment {
    [CmdletBinding()]
    param()
    throw [System.NotImplementedException]::new('Test-DhEnvironment is not yet implemented (Phase F).')
}
```

- [ ] **Step 4: Write `derekh/README.md`**

Create `c:/git/fellwork/tools/derekh/README.md` with the following contents:

```markdown
# Derekh

A reusable terminal-UI framework for Fellwork CLI tools.

**Status:** Phase A — scaffolding (stubs only, not yet functional)

## Overview

Derekh ("the way" in Hebrew) provides a structured dashboard layout for
PowerShell CLI tools instead of raw streaming output. Consumers describe a
`Plan` of phases; the framework runs them and displays results in a
header/phases/active/issues/footer layout.

## Usage (future — Phase F+)

```powershell
Import-Module c:/git/fellwork/tools/derekh/derekh.psd1

$plan = New-DhPlan -Title 'My Tool' -Subtitle (Get-Date -Format HH:mm:ss)
$plan = Add-DhLoopPhase -Plan $plan -Name 'Doing things' -Items $items -Action {
    param($item)
    # ... your logic ...
    return New-DhResult -Success $true -Message "$item done"
}
Invoke-DhPlan -Plan $plan
```

## Module structure

```
derekh/
├── derekh.psd1       # Manifest: version, exports
├── derekh.psm1       # Entry: dot-sources lib/, stubs for Phase A
├── lib/              # Implementation (populated in Phases B–F)
├── themes/           # JSON theme files (populated in Phase C)
└── tests/            # Test suites + runner
```

## Exported functions

| Function | Phase | Purpose |
|---|---|---|
| `Invoke-DhPlan` | F | Primary entry point — runs a plan |
| `New-DhPlan` | B | Plan builder |
| `Add-DhLoopPhase` | B | Add a loop phase to a plan |
| `Add-DhSinglePhase` | B | Add a single-action phase to a plan |
| `New-DhResult` | B | Build an action return value |
| `New-DhAlert` | B | Build an alert |
| `Get-DhTheme` | C | Load a resolved theme hashtable |
| `Get-DhVersion` | A | Returns the module version string |
| `Test-DhEnvironment` | F | TTY/UTF-8/color capability check |

## Spec

`c:/git/fellwork/bootstrap/docs/superpowers/specs/2026-04-26-derekh-tui-design.md`
```

- [ ] **Step 5: Verify module loads**

```powershell
pwsh -NoProfile -Command "
    Import-Module c:/git/fellwork/tools/derekh/derekh.psd1 -Force
    Write-Host 'Module loaded OK'
    Write-Host ('Version: ' + (Get-DhVersion))
    \$cmds = Get-Command -Module derekh | Select-Object -ExpandProperty Name | Sort-Object
    Write-Host ('Exports: ' + (\$cmds -join ', '))
"
```

Expected output:
```
Module loaded OK
Version: 0.1.0
Exports: Add-DhLoopPhase, Add-DhSinglePhase, Get-DhTheme, Get-DhVersion, Invoke-DhPlan, New-DhAlert, New-DhPlan, New-DhResult, Test-DhEnvironment
```

- [ ] **Step 6: Commit and push**

```bash
cd /c/git/fellwork/tools
git add derekh/
git commit -m "feat(derekh): module skeleton — manifest, psm1 stubs, README, empty lib/ themes/"
git push
```

Expected: push succeeds; `git log --oneline` shows two commits on `main`.

---

## Task A3: Test runner skeleton

**Files:**
- Create: `c:/git/fellwork/tools/derekh/tests/run-all.ps1`
- Create: `c:/git/fellwork/tools/derekh/tests/test-skeleton.ps1`

- [ ] **Step 1: Write `tests/run-all.ps1`**

Create `c:/git/fellwork/tools/derekh/tests/run-all.ps1` with the following exact contents (mirrors the bootstrap pattern from `c:/git/fellwork/bootstrap/tests/run-all.ps1`):

```powershell
#Requires -Version 7
# Run every test suite in derekh/tests/ and print a summary.
#
# Usage:
#   pwsh tests/run-all.ps1           # Run all, summary at end
#   pwsh tests/run-all.ps1 -Verbose  # Stream each suite's output as it runs
#   pwsh tests/run-all.ps1 -Bail     # Stop on first failing suite
#
# Exit codes: 0 = all pass, 1 = at least one suite failed.

[CmdletBinding()]
param(
    [switch]$Bail
)

$ErrorActionPreference = 'Stop'
$testsDir = $PSScriptRoot

# Auto-discover all test-*.ps1 files except this runner itself.
$suites = Get-ChildItem -Path $testsDir -Filter 'test-*.ps1' |
    Where-Object { $_.Name -ne 'run-all.ps1' } |
    Sort-Object Name

if ($suites.Count -eq 0) {
    Write-Host "No test-*.ps1 files found in $testsDir" -ForegroundColor Yellow
    exit 1
}

$results    = @()
$totalPass  = 0
$totalFail  = 0
$totalSeconds = 0.0
$suiteFailed  = $false

# Color helpers (no dependency on derekh lib — runner must work before lib exists)
function Write-Header($text) { Write-Host $text -ForegroundColor Cyan }
function Write-Ok($text)     { Write-Host $text -ForegroundColor Green }
function Write-Fail($text)   { Write-Host $text -ForegroundColor Red }
function Write-Dim($text)    { Write-Host $text -ForegroundColor DarkGray }

Write-Header ""
Write-Header "Running $($suites.Count) test suite(s) from $testsDir"
Write-Header ("=" * 60)
Write-Host ""

foreach ($suite in $suites) {
    $name = $suite.BaseName
    Write-Host -NoNewline ("  {0,-28} " -f $name)

    $sw     = [System.Diagnostics.Stopwatch]::StartNew()
    $output = & pwsh -NoProfile -File $suite.FullName 2>&1 | Out-String
    $exit   = $LASTEXITCODE
    $sw.Stop()
    $totalSeconds += $sw.Elapsed.TotalSeconds

    $passCount = ([regex]::Matches($output, '^PASS:', 'Multiline')).Count
    $failCount = ([regex]::Matches($output, '^FAIL:', 'Multiline')).Count
    $totalPass += $passCount
    $totalFail += $failCount

    if ($VerbosePreference -eq 'Continue') {
        Write-Host ""
        Write-Dim $output
    }

    if ($exit -eq 0 -and $failCount -eq 0) {
        Write-Ok ("{0,4} pass  ({1,5:F1}s)" -f $passCount, $sw.Elapsed.TotalSeconds)
    } else {
        Write-Fail ("{0,4} pass  {1} fail  (exit {2}, {3:F1}s)" -f $passCount, $failCount, $exit, $sw.Elapsed.TotalSeconds)
        $suiteFailed = $true

        # Show failing lines without requiring -Verbose
        $failingLines = ($output -split "`n") | Where-Object { $_ -match '^FAIL:' }
        foreach ($line in $failingLines) {
            Write-Dim ("      $line")
        }

        if ($Bail) {
            Write-Host ""
            Write-Fail "Bailing on first failed suite (-Bail flag)."
            break
        }
    }

    $results += [PSCustomObject]@{
        Suite   = $name
        Pass    = $passCount
        Fail    = $failCount
        Exit    = $exit
        Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    }
}

Write-Host ""
Write-Header ("=" * 60)
if ($suiteFailed) {
    Write-Fail ("TOTAL: {0} pass, {1} fail  ({2:F1}s)" -f $totalPass, $totalFail, $totalSeconds)
    exit 1
} else {
    Write-Ok ("TOTAL: {0} pass, 0 fail  ({1:F1}s)" -f $totalPass, $totalSeconds)
    exit 0
}
```

- [ ] **Step 2: Write `tests/test-skeleton.ps1`**

Create `c:/git/fellwork/tools/derekh/tests/test-skeleton.ps1` with the following exact contents:

```powershell
#Requires -Version 7
# test-skeleton.ps1 — Phase A placeholder test suite.
#
# Verifies that:
#   1. derekh.psd1 exists and is importable.
#   2. All 9 exported functions are present after import.
#   3. Get-DhVersion returns a semver-shaped string.
#
# PASS:/FAIL: prefix protocol matches run-all.ps1 expectations.

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

# ── Locate the manifest relative to this test file ───────────────────────────
$manifestPath = Join-Path $PSScriptRoot '../derekh.psd1'
$manifestPath = [System.IO.Path]::GetFullPath($manifestPath)

# 1. Manifest file exists
Assert-True 'derekh.psd1 exists' (Test-Path $manifestPath) "Path: $manifestPath"

# 2. Module imports without error
$importError = $null
try {
    Import-Module $manifestPath -Force -ErrorAction Stop
} catch {
    $importError = $_.Exception.Message
}
Assert-True 'Import-Module derekh.psd1 succeeds' ($null -eq $importError) $importError

# 3–11. All 9 exported functions are present
$expectedExports = @(
    'Invoke-DhPlan'
    'New-DhPlan'
    'Add-DhLoopPhase'
    'Add-DhSinglePhase'
    'New-DhResult'
    'New-DhAlert'
    'Get-DhTheme'
    'Get-DhVersion'
    'Test-DhEnvironment'
)

foreach ($fn in $expectedExports) {
    $cmd = Get-Command -Module derekh -Name $fn -ErrorAction SilentlyContinue
    Assert-True "Export: $fn" ($null -ne $cmd) "function not found in module exports"
}

# 12. Get-DhVersion returns a semver-shaped string (X.Y.Z)
$version = $null
try { $version = Get-DhVersion } catch { }
Assert-True 'Get-DhVersion returns semver string' (
    $null -ne $version -and $version -match '^\d+\.\d+\.\d+$'
) "Got: '$version'"

# ── Summary ──────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Skeleton: $passCount pass, $failCount fail"

if ($failCount -gt 0) { exit 1 } else { exit 0 }
```

- [ ] **Step 3: Run the test suite to confirm exit 0**

```bash
pwsh -NoProfile -File /c/git/fellwork/tools/derekh/tests/run-all.ps1
```

Expected output (exact pass count may vary):
```
Running 1 test suite(s) from C:\git\fellwork\tools\derekh\tests
============================================================

  test-skeleton                   12 pass  (  0.Xs)

============================================================
TOTAL: 12 pass, 0 fail  (0.Xs)
```

Exit code must be 0.

- [ ] **Step 4: Confirm `Import-Module derekh.psd1` works standalone**

```powershell
pwsh -NoProfile -Command "Import-Module c:/git/fellwork/tools/derekh/derekh.psd1 -Force; Write-Host 'OK'"
```

Expected: prints `OK` with exit code 0.

- [ ] **Step 5: Commit and push**

```bash
cd /c/git/fellwork/tools
git add derekh/tests/
git commit -m "feat(derekh): test runner skeleton + test-skeleton.ps1 (Phase A)"
git push
```

Expected: push succeeds; `git log --oneline` shows three commits on `main`; `gh repo view fellwork/tools` reflects the pushed state.

---

## Phase A completion checklist

After all three tasks, verify:

- [ ] `gh repo view fellwork/tools` returns the repo with 3 commits on `main`
- [ ] `Import-Module c:/git/fellwork/tools/derekh/derekh.psd1` exits 0
- [ ] `Get-DhVersion` returns `0.1.0`
- [ ] `Get-Command -Module derekh | Measure-Object` shows 9 commands
- [ ] `pwsh -NoProfile -File c:/git/fellwork/tools/derekh/tests/run-all.ps1` exits 0 with 12 passes
- [ ] `c:/git/fellwork/tools/derekh/lib/` and `themes/` directories exist (with `.gitkeep`)
- [ ] No `*.psd1` GUID collisions with other modules in the workspace

**Phase B entry condition:** all items above pass. Phase B will populate `lib/state.ps1`, `lib/plan.ps1`, `lib/theme.ps1`, `lib/layout.ps1` and replace the stubs in `derekh.psm1` for `New-DhPlan`, `Add-DhLoopPhase`, `Add-DhSinglePhase`, `New-DhResult`, and `New-DhAlert`.
