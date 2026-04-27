# Derekh Phase H — Bootstrap Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire bootstrap.ps1 to use derekh on subsequent runs. First run keeps existing streaming behavior; subsequent runs (after tools/ is cloned) use the derekh dashboard.

**Architecture:** Purely additive integration. New detection block at top of bootstrap.ps1; if derekh module loads, refactor existing phase logic into a `$plan` and call `Invoke-DhPlan`. Otherwise, fall through to existing 658-test-covered streaming code unchanged.

**Tech Stack:** PowerShell 7.5+, GitHub CLI (gh) for PR creation

**Spec:** `c:/git/fellwork/bootstrap/docs/superpowers/specs/2026-04-26-derekh-tui-design.md` (sections: Bootstrap.ps1 integration, Changes to repos.psd1, Changes to bootstrap.ps1)

**Prerequisites:** Phases A through F complete — derekh module is functional (Phases C, E, G optional but recommended). Bootstrap repo's existing 658-test suite all green at start.

**Branch / PR workflow**: All Phase H work happens on a `feat/derekh-integration` branch in `fellwork/bootstrap`, landing as a PR. Direct push to main is forbidden.

---

## Task H1: Add `tools` to `repos.psd1`

**Files modified:**
- `c:/git/fellwork/bootstrap/repos.psd1`

**What:** Append the 8th repo entry for `fellwork/tools`. Include `structureCheck = @('derekh/derekh.psd1')` so bootstrap validates the module manifest is in place after cloning. With this change, a fresh bootstrap run will clone `tools/` as a sibling of the other repos.

- [ ] **Step 0: Create the feature branch in the bootstrap repo**

```bash
cd /c/git/fellwork/bootstrap
git checkout main
git pull
git checkout -b feat/derekh-integration
```

Expected: branch `feat/derekh-integration` created from a clean, up-to-date `main`. `git status` shows no uncommitted changes.

- [ ] **Step 1: Verify the existing 658-test suite is green before touching anything**

```bash
pwsh /c/git/fellwork/bootstrap/tests/run-all.ps1
```

Expected: exit code 0, all suites pass. If any suite fails, do not proceed — fix the pre-existing failure first and note the concern.

- [ ] **Step 2: Add the `tools` repo entry to `repos.psd1`**

Edit `c:/git/fellwork/bootstrap/repos.psd1`. Append the following entry as the 8th item in the `repos` array, after the `tsconfig` entry and before the closing `)`  of the array:

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

The complete file after the edit should end:

```powershell
        @{
            name        = 'tsconfig'
            org         = 'fellwork'
            branch      = 'main'
            description = 'Shared TypeScript config'
            structureCheck = @()
            envExamples = @()
        }
        @{
            name        = 'tools'
            org         = 'fellwork'
            branch      = 'main'
            description = 'Shared CLI tooling — Derekh TUI framework + future tools'
            structureCheck = @('derekh/derekh.psd1')
            envExamples = @()
        }
    )
}
```

- [ ] **Step 3: Verify `repos.psd1` parses without error**

```powershell
pwsh -NoProfile -Command "
    \$data = Import-PowerShellDataFile 'c:/git/fellwork/bootstrap/repos.psd1'
    Write-Host ('Repos count: ' + \$data.repos.Count)
    Write-Host ('Last repo: ' + \$data.repos[-1].name)
    Write-Host ('structureCheck: ' + (\$data.repos[-1].structureCheck -join ', '))
"
```

Expected output:
```
Repos count: 8
Last repo: tools
structureCheck: derekh/derekh.psd1
```

- [ ] **Step 4: Verify the existing E2E test still passes after the repos.psd1 change**

The existing `test-e2e.ps1` asserts exactly 7 repos appear as "already cloned" (line `Assert-Equal 7 $alreadyClonedCount`). After adding `tools` as the 8th entry, the E2E test's hardcoded-7 assertion will start counting `tools` too and may pass (if tools/ is already cloned) or surface a new "absent" clone step (if it isn't). Investigate the actual result:

```bash
pwsh /c/git/fellwork/bootstrap/tests/run-all.ps1 -Verbose
```

**If `test-e2e.ps1` fails because `alreadyClonedCount` is now 8 (tools already cloned):**
Update the hardcoded assertion in `c:/git/fellwork/bootstrap/tests/test-e2e.ps1` — change the two occurrences:
- The `$expectedRepos` array: add `'tools'` to the list.
- The `Assert-Equal 7 $alreadyClonedCount` assertion: change to `Assert-Equal 8`.

**If `test-e2e.ps1` passes because tools/ is not yet cloned (bootstrap attempts clone and reports it absent or clones it):**
No change needed to the E2E test assertions, but verify the overall exit code is still in `{0, 1, 2}`.

Re-run until all suites pass (exit 0), or document any remaining difference as a known concern in the PR description.

- [ ] **Step 5: Commit the repos.psd1 change**

```bash
cd /c/git/fellwork/bootstrap
git add repos.psd1
# If test-e2e.ps1 was updated, also: git add tests/test-e2e.ps1
git commit -m "feat(bootstrap): add tools repo (derekh) to repos.psd1"
```

Expected: commit created on `feat/derekh-integration`; `git log --oneline -3` shows the new commit at HEAD.

---

## Task H2: Add derekh-detection block to `bootstrap.ps1`

**Files modified:**
- `c:/git/fellwork/bootstrap/bootstrap.ps1`

**What:** Add a short detection + early-exit block near the top of `bootstrap.ps1`. The block detects whether `../tools/derekh/derekh.psm1` exists, imports the module, and — if successful — builds a `$plan` and calls `Invoke-DhPlan`, then exits. Otherwise it falls through to the existing streaming renderer untouched. The existing code (lines 14-332 of the current file) is never deleted or moved in this task.

- [ ] **Step 1: Insert the derekh-detection block**

Open `c:/git/fellwork/bootstrap/bootstrap.ps1`. After the existing `$scriptRoot = $PSScriptRoot` assignment (line 11) and before the `if ($Help)` block (line 18), insert the following block:

```powershell
# ── Derekh integration (subsequent runs only) ─────────────────────────────
# On the first run, tools/ doesn't exist yet — bootstrap.ps1 uses its own
# streaming renderer below. On subsequent runs, tools/ is cloned and this
# block activates the Derekh TUI.
$derekhModule = Join-Path (Split-Path -Parent $scriptRoot) "tools/derekh/derekh.psm1"
$useDerekh = $false

if (Test-Path $derekhModule) {
    try {
        Import-Module $derekhModule -Force -ErrorAction Stop
        $useDerekh = $true
    } catch {
        Write-Warning "(Derekh module exists but failed to load: $_. Falling back to streaming renderer.)"
    }
}

if ($useDerekh) {
    # Build the $plan from existing phase logic and hand off to Invoke-DhPlan.
    # Build-BootstrapPlan is defined below (Task H3) — it wraps each phase
    # in the Derekh plan schema and returns a $plan hashtable.
    $plan = Build-BootstrapPlan -ScriptRoot $scriptRoot -ParentDir (Split-Path -Parent $scriptRoot) `
                                -NoColor $NoColor.IsPresent -Ascii $Ascii.IsPresent
    Invoke-DhPlan -Plan $plan
    exit $LASTEXITCODE
}
# ── End derekh integration ────────────────────────────────────────────────
```

The insertion point is after line 11 (`$scriptRoot = $PSScriptRoot`) and before line 13 (the blank line before `# Source library files`).

- [ ] **Step 2: Verify the streaming path still runs correctly when tools/ is not present**

Temporarily rename `c:/git/fellwork/tools/derekh/derekh.psm1` if it exists, or simply confirm it is absent. Then run bootstrap with `--ascii --no-color` and verify exit code and section headers are unchanged:

```bash
pwsh /c/git/fellwork/bootstrap/bootstrap.ps1 -NoColor -Ascii 2>&1 | head -20
echo "Exit: $?"
```

Expected: the banner and section headers appear; exit code is 0, 1, or 2. The derekh block should be invisible — it just passes through.

- [ ] **Step 3: Verify the derekh path activates (smoke) when tools/ IS present**

This requires Phase A–F of derekh to be complete. If the derekh module is in place:

```powershell
pwsh -NoProfile -File /c/git/fellwork/bootstrap/bootstrap.ps1 -NoColor -Ascii
```

Expected: `$useDerekh` becomes `$true`; `Build-BootstrapPlan` is called (will error on "not yet defined" until Task H3 is complete — that error is expected at this step). If the function doesn't exist yet, you will see `CommandNotFoundException: Build-BootstrapPlan`. That is the correct signal that Task H2 is done and Task H3 is next.

- [ ] **Step 4: Run the full test suite to confirm no regressions**

```bash
pwsh /c/git/fellwork/bootstrap/tests/run-all.ps1
```

Expected: all suites pass (exit 0). The detection block must not break any existing test. If any test fails, investigate before committing.

- [ ] **Step 5: Commit**

```bash
cd /c/git/fellwork/bootstrap
git add bootstrap.ps1
git commit -m "feat(bootstrap): add derekh-detection block (additive, falls through when tools/ absent)"
```

---

## Task H3: `Build-BootstrapPlan` function

**Files modified:**
- `c:/git/fellwork/bootstrap/bootstrap.ps1`

**What:** Refactor bootstrap.ps1's existing 6-phase streaming logic into a `Build-BootstrapPlan` function that returns a `$plan` hashtable consumable by `Invoke-DhPlan`. Each existing phase maps 1:1 to a `Add-DhLoopPhase` or `Add-DhSinglePhase` call. Each action's success/failure result is wrapped via `New-DhResult`. The original streaming code below the `if ($useDerekh)` guard is NOT modified — only the new function is added.

**Phase mapping:**

| Existing phase | Derekh type | Items |
|---|---|---|
| Phase 1 — Bootstrap prerequisites | `Add-DhSinglePhase` | n/a (single action that may emit multiple alerts) |
| Phase 2 — Clone repos | `Add-DhLoopPhase` | `$repoData.repos` array |
| Phase 3 — Proto install per repo | `Add-DhLoopPhase` | repos with status `ok` |
| Phase 4 — Other prerequisites | `Add-DhSinglePhase` | n/a (single action, multiple alerts) |
| Phase 5 — Env scaffolding | `Add-DhLoopPhase` | repos needing env files |
| Phase 6 — Structure validation | `Add-DhLoopPhase` | repos with status `ok` |

- [ ] **Step 1: Add `Build-BootstrapPlan` before the `if ($Help)` block**

Insert the function definition into `c:/git/fellwork/bootstrap/bootstrap.ps1` immediately after the derekh-detection block added in Task H2 and before the `if ($Help)` block. The function must:

1. Accept `-ScriptRoot`, `-ParentDir`, `-NoColor`, `-Ascii` parameters.
2. Load `$repoData` from `repos.psd1` via `Import-PowerShellDataFile`.
3. Build the plan via `New-DhPlan -Title "Fellwork Bootstrap" -Subtitle (Get-Date -Format HH:mm:ss) -Theme "twilight"`.
4. Add each phase via `Add-DhLoopPhase` or `Add-DhSinglePhase` as described in the mapping table above.
5. Return the completed `$plan`.

Full function body:

```powershell
function Build-BootstrapPlan {
    [CmdletBinding()]
    param(
        [string]$ScriptRoot,
        [string]$ParentDir,
        [bool]$NoColor,
        [bool]$Ascii
    )

    $repoData = Import-PowerShellDataFile (Join-Path $ScriptRoot 'repos.psd1')

    $plan = New-DhPlan -Title "Fellwork Bootstrap" -Subtitle (Get-Date -Format "HH:mm:ss") -Theme "twilight"

    # ── Phase 1: Bootstrap prerequisites ─────────────────────────────────────
    $plan = Add-DhSinglePhase -Plan $plan -Name "Bootstrap prerequisites" -Action {
        $bootstrapPrereqs = @('git', 'proto')
        $alerts = @()
        $allOk = $true

        foreach ($p in $bootstrapPrereqs) {
            $r = Get-PrereqResult -Name $p -Required $true
            if ($r.Status -eq 'present') {
                $alerts += New-DhAlert -Severity 'info' -Message "$p $($r.Version)"
            } else {
                $allOk = $false
                $alerts += New-DhAlert -Severity 'fail' `
                    -Message "$p is required and not installed" `
                    -FixCommand "Install: $($r.InstallUrl)"
            }
        }

        if (-not $allOk) {
            return New-DhResult -Success $false `
                -Message "Bootstrap-time prereqs missing — cannot proceed" `
                -Severity 'fail' `
                -Animal 'octopus' `
                -Alerts $alerts
        }
        return New-DhResult -Success $true -Message "Bootstrap prerequisites satisfied" -Alerts $alerts
    }

    # ── Phase 2: Clone repos ──────────────────────────────────────────────────
    $plan = Add-DhLoopPhase -Plan $plan -Name "Cloning repositories" -Items $repoData.repos -Action {
        param($repo)
        $expectedOrigin = "https://github.com/$($repo.org)/$($repo.name).git"
        $state = Get-RepoState -Name $repo.name -ParentDir $ParentDir -ExpectedOrigin $expectedOrigin

        switch ($state.Status) {
            'present-matching' {
                return New-DhResult -Success $true `
                    -Message "$($repo.name): already cloned, origin matches (branch: $($state.Branch))"
            }
            'present-mismatch' {
                return New-DhResult -Success $false `
                    -Message "$($repo.name): wrong origin — $($state.Origin)" `
                    -Severity 'fail' `
                    -FixCommand "cd $ParentDir/$($repo.name) && git remote set-url origin $expectedOrigin" `
                    -Animal 'raccoon'
            }
            'present-not-git' {
                return New-DhResult -Success $false `
                    -Message "$($repo.name): directory exists but is not a git repo" `
                    -Severity 'fail' `
                    -FixCommand "Inspect $($state.Path) and resolve manually (back up & remove if appropriate, then rerun)" `
                    -Animal 'raccoon'
            }
            'absent' {
                $clone = Invoke-RepoClone -Name $repo.name -Org $repo.org -ParentDir $ParentDir
                if ($clone.Success) {
                    return New-DhResult -Success $true -Message "$($repo.name): cloned"
                } else {
                    return New-DhResult -Success $false `
                        -Message "$($repo.name): git clone failed (exit $($clone.ExitCode))" `
                        -Severity 'fail' `
                        -FixCommand "Check network/auth, then rerun: git clone $expectedOrigin" `
                        -Animal 'octopus'
                }
            }
        }
    }

    # ── Phase 3: Proto install per repo ───────────────────────────────────────
    # Filter to repos that were successfully cloned/verified.
    # This requires state from Phase 2 — capture it via a closure variable
    # populated by scanning disk (same logic as the streaming path).
    $okRepos = $repoData.repos | Where-Object {
        $repoPath = Join-Path $ParentDir $_.name
        Test-Path $repoPath
    }

    $plan = Add-DhLoopPhase -Plan $plan -Name "Toolchain (proto install per repo)" -Items $okRepos -Action {
        param($repo)
        $repoPath = Join-Path $ParentDir $repo.name
        $result = Invoke-ProtoInstall -RepoPath $repoPath

        if ($result.Skipped) {
            return New-DhResult -Success $true -Message "$($repo.name): no .prototools — skipped" -Severity 'info'
        } elseif ($result.Success) {
            return New-DhResult -Success $true -Message "$($repo.name): tools installed"
        } else {
            return New-DhResult -Success $false `
                -Message "$($repo.name): proto install failed (exit $($result.ExitCode))" `
                -Severity 'fail' `
                -FixCommand "cd $repoPath && proto install" `
                -Animal 'octopus'
        }
    }

    # ── Phase 4: Other prerequisites ─────────────────────────────────────────
    $plan = Add-DhSinglePhase -Plan $plan -Name "Other prerequisites" -Action {
        $otherPrereqs = Get-AllPrereqs | Where-Object { $_.Name -notin @('git','proto','rustc','node','bun') }
        $alerts = @()
        $anyFail = $false

        foreach ($p in $otherPrereqs) {
            if ($p.Status -eq 'present') {
                $alerts += New-DhAlert -Severity 'info' -Message "$($p.Name) $($p.Version)"
            } elseif ($p.Status -eq 'present-but-not-running') {
                $alerts += New-DhAlert -Severity 'warning' `
                    -Message "$($p.Name) is installed but its daemon isn't running" `
                    -FixCommand (if ($p.Workaround) { $p.Workaround } else { "Start the $($p.Name) daemon (e.g. open Docker Desktop)" })
            } else {
                $animal = if ($p.Workaround) { 'turtle' } else { 'owl' }
                $fixCmd = if ($p.Workaround) { $p.Workaround } elseif ($p.InstallUrl) { $p.InstallUrl } else { "Install $($p.Name) from your platform's package manager" }
                $alerts += New-DhAlert -Severity 'warning' `
                    -Message "$($p.Name) is not installed" `
                    -FixCommand $fixCmd
            }
        }

        return New-DhResult -Success $true -Message "Other prerequisites checked" -Alerts $alerts
    }

    # ── Phase 5: Env scaffolding ──────────────────────────────────────────────
    $reposNeedingEnv = $repoData.repos | Where-Object {
        $repoPath = Join-Path $ParentDir $_.name
        (Test-Path $repoPath) -and ((Test-EnvFilesNeeded -Repo $_ -ParentDir $ParentDir).Count -gt 0)
    }

    if ($reposNeedingEnv.Count -gt 0) {
        $plan = Add-DhLoopPhase -Plan $plan -Name "Env files" -Items $reposNeedingEnv -Action {
            param($repo)
            $needed = Test-EnvFilesNeeded -Repo $repo -ParentDir $ParentDir
            $alerts = @()
            $anyFail = $false

            foreach ($env in $needed) {
                try {
                    Invoke-EnvScaffold -EnvFile $env
                    $alerts += New-DhAlert -Severity 'warning' `
                        -Message "Scaffolded $($env.Target) — fill in real secrets before using" `
                        -FixCommand "Edit $($env.Target) and replace placeholder values with real credentials (do not commit)"
                } catch {
                    $anyFail = $true
                    $alerts += New-DhAlert -Severity 'fail' `
                        -Message "Failed to scaffold $($env.Target): $_" `
                        -FixCommand "Manually copy $($env.Example) to $($env.Target)"
                }
            }

            if ($anyFail) {
                return New-DhResult -Success $false `
                    -Message "$($repo.name): env scaffolding had failures" `
                    -Severity 'fail' `
                    -Animal 'hedgehog' `
                    -Alerts $alerts
            }
            return New-DhResult -Success $true -Message "$($repo.name): env files scaffolded" -Alerts $alerts
        }
    }

    # ── Phase 6: Structure validation ─────────────────────────────────────────
    $plan = Add-DhLoopPhase -Plan $plan -Name "Repo structure validation" -Items $okRepos -Action {
        param($repo)
        $valid = Test-RepoStructure -Repo $repo -ParentDir $ParentDir

        if ($valid) {
            return New-DhResult -Success $true -Message "$($repo.name): structure OK"
        } else {
            $expected = if ($repo.structureCheck) { $repo.structureCheck -join ', ' } else { '(check repos.psd1)' }
            return New-DhResult -Success $false `
                -Message "$($repo.name): expected files missing" `
                -Severity 'warning' `
                -FixCommand "cd $ParentDir/$($repo.name) && check that these files exist: $expected" `
                -Animal 'raccoon'
        }
    }

    return $plan
}
```

- [ ] **Step 2: Verify the function definition parses cleanly**

```powershell
pwsh -NoProfile -Command "
    \$null = [System.Management.Automation.Language.Parser]::ParseFile(
        'c:/git/fellwork/bootstrap/bootstrap.ps1',
        [ref]\$null,
        [ref]\$errors
    )
    if (\$errors.Count -gt 0) {
        \$errors | ForEach-Object { Write-Host \$_.Message -ForegroundColor Red }
        exit 1
    }
    Write-Host 'Parse OK' -ForegroundColor Green
    exit 0
"
```

Expected: `Parse OK` with exit code 0.

- [ ] **Step 3: Smoke-test the full derekh path end-to-end (if tools/ is available)**

If `c:/git/fellwork/tools/derekh/derekh.psm1` exists and Phases A–F are complete:

```powershell
pwsh -NoProfile -File /c/git/fellwork/bootstrap/bootstrap.ps1 -NoColor -Ascii
```

Expected: derekh path activates; `Build-BootstrapPlan` runs; `Invoke-DhPlan` processes all 6 phases; exit code matches the equivalent streaming run (0 if all clean, 1 if warnings, 2 if failures).

**If derekh module is not yet fully implemented (stubs only from Phase A):** `Invoke-DhPlan` will throw `NotImplementedException`. That is expected and confirms the wiring is correct. The streaming path remains unaffected.

- [ ] **Step 4: Run the full test suite**

```bash
pwsh /c/git/fellwork/bootstrap/tests/run-all.ps1
```

Expected: all suites pass (exit 0). The new function must not break any test that exercises the streaming path.

- [ ] **Step 5: Commit**

```bash
cd /c/git/fellwork/bootstrap
git add bootstrap.ps1
git commit -m "feat(bootstrap): Build-BootstrapPlan maps existing phases to derekh plan schema"
```

---

## Task H4: E2E tests for both code paths

**Files created:**
- `c:/git/fellwork/bootstrap/tests/test-derekh-integration.ps1`

**What:** Two test scenarios that exercise both code paths and are auto-discovered by `tests/run-all.ps1`. Tests use `Invoke-DhPlan -Headless` for the derekh path so assertions are deterministic (parse JSON output instead of TUI screen state). Both scenarios are gated: if tools/ is absent, the derekh-path tests are skipped with `PASS: SKIP (derekh module not present)` so the suite never fails on a developer machine that hasn't yet cloned tools/.

**Scenario 1 — Derekh path:** tools/ present, derekh module loads → `Invoke-DhPlan -Headless` emits JSON → parse and assert `exit_code`, `phases[*].name`, `summary.phases_total`.

**Scenario 2 — Fallback path:** Simulate tools/ absent by temporarily renaming `derekh.psm1` → run bootstrap with `--ascii --no-color` → assert streaming output contains expected section headers and exit code is in `{0, 1, 2}`.

- [ ] **Step 1: Create `tests/test-derekh-integration.ps1`**

Create `c:/git/fellwork/bootstrap/tests/test-derekh-integration.ps1` with the following contents:

```powershell
#Requires -Version 7
# test-derekh-integration.ps1
#
# E2E tests for the dual code path added by Phase H:
#   Scenario 1: tools/ present → derekh path runs (headless mode for determinism)
#   Scenario 2: tools/ absent  → fallback streaming renderer runs unchanged
#
# PASS:/FAIL: prefix protocol for run-all.ps1.

$ErrorActionPreference = 'Stop'

$failures = 0
$passes   = 0

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        Write-Host "PASS: $Name"
        $script:passes++
    } else {
        $msg = if ($Detail) { "FAIL: $Name — $Detail" } else { "FAIL: $Name" }
        Write-Host $msg
        $script:failures++
    }
}

function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    if ($Expected -eq $Actual) {
        Write-Host "PASS: $Name"
        $script:passes++
    } else {
        Write-Host "FAIL: $Name — expected '$Expected', got '$Actual'"
        $script:failures++
    }
}

function Skip-Pass {
    param([string]$Name)
    Write-Host "PASS: SKIP — $Name"
    $script:passes++
}

$bootstrapRoot   = Resolve-Path "$PSScriptRoot/.."
$bootstrapScript = Join-Path $bootstrapRoot "bootstrap.ps1"
$parentDir       = Split-Path -Parent $bootstrapRoot
$derekhPsm1      = Join-Path $parentDir "tools/derekh/derekh.psm1"
$derekhPsd1      = Join-Path $parentDir "tools/derekh/derekh.psd1"

Assert-True 'bootstrap.ps1 exists' (Test-Path $bootstrapScript)

# ═══════════════════════════════════════════════════════════════════════════
# Scenario 1 — Derekh path (headless mode)
# Requires: tools/ cloned AND derekh Phases A–F complete (Invoke-DhPlan works)
# ═══════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "--- Scenario 1: derekh path (headless) ---" -ForegroundColor Cyan

$derekhAvailable = (Test-Path $derekhPsm1) -and (Test-Path $derekhPsd1)

if (-not $derekhAvailable) {
    # tools/ not cloned yet — skip gracefully without failing the suite
    Skip-Pass 'S1: derekh module present (skipped — tools/ not cloned)'
    Skip-Pass 'S1: headless JSON exit_code in {0,1,2} (skipped)'
    Skip-Pass 'S1: headless JSON phases_total is 6 (skipped)'
    Skip-Pass 'S1: headless JSON phase names match expected (skipped)'
    Skip-Pass 'S1: headless JSON summary.issues_total is integer (skipped)'
    Skip-Pass 'S1: headless exit code matches streaming exit code (skipped)'
} else {
    # Verify the module at least imports (confirms Phase A–B work)
    $importOk = $false
    $importError = ''
    try {
        Import-Module $derekhPsd1 -Force -ErrorAction Stop
        $importOk = $true
    } catch {
        $importError = $_.Exception.Message
    }
    Assert-True 'S1: derekh module loads without error' $importOk $importError

    # Check whether Invoke-DhPlan is fully implemented (not a NotImplementedException stub)
    $planImplemented = $false
    try {
        $testPlan = New-DhPlan -Title 'Test' -Subtitle 'test'
        $testPlan = Add-DhSinglePhase -Plan $testPlan -Name 'noop' -Action { return New-DhResult -Success $true -Message 'ok' }
        $null = Invoke-DhPlan -Plan $testPlan -Headless
        $planImplemented = ($LASTEXITCODE -in @(0, 1, 2))
    } catch [System.NotImplementedException] {
        # Stubs still in place — skip headless scenarios gracefully
        Skip-Pass 'S1: Invoke-DhPlan implemented (skipped — stubs still present)'
        $planImplemented = $false
    } catch {
        # Unexpected error — surface it
        Assert-True 'S1: Invoke-DhPlan implemented (unexpected error)' $false $_.Exception.Message
        $planImplemented = $false
    }

    if ($planImplemented) {
        # Run bootstrap in headless mode by directly calling Build-BootstrapPlan + Invoke-DhPlan -Headless
        # We do this in a subprocess to get clean stdout for JSON parsing.
        $headlessScript = @'
param([string]$BootstrapRoot, [string]$DerekhPsd1)
$ErrorActionPreference = 'Stop'
Import-Module $DerekhPsd1 -Force
. (Join-Path $BootstrapRoot 'lib/ui.ps1')
. (Join-Path $BootstrapRoot 'lib/animals.ps1')
. (Join-Path $BootstrapRoot 'lib/prereqs.ps1')
. (Join-Path $BootstrapRoot 'lib/repos.ps1')
. $BootstrapRoot/bootstrap.ps1   # dot-source to pull in Build-BootstrapPlan without running it
$parentDir = Split-Path -Parent $BootstrapRoot
$plan = Build-BootstrapPlan -ScriptRoot $BootstrapRoot -ParentDir $parentDir -NoColor $true -Ascii $true
Invoke-DhPlan -Plan $plan -Headless
exit $LASTEXITCODE
'@
        # Write the inline script to a temp file so pwsh -File can run it
        $tmpScript = Join-Path ([System.IO.Path]::GetTempPath()) "derekh-test-headless-$([System.Guid]::NewGuid().ToString('N')).ps1"
        try {
            Set-Content -Path $tmpScript -Value $headlessScript -Encoding UTF8
            $jsonOutput = & pwsh -NoProfile -File $tmpScript `
                -BootstrapRoot $bootstrapRoot `
                -DerekhPsd1 $derekhPsd1 `
                2>$null | Out-String
            $headlessExit = $LASTEXITCODE
        } finally {
            Remove-Item $tmpScript -ErrorAction SilentlyContinue
        }

        Assert-True 'S1: headless JSON exit_code in {0,1,2}' ($headlessExit -in @(0, 1, 2)) "got $headlessExit"

        $parsed = $null
        try { $parsed = $jsonOutput | ConvertFrom-Json } catch { }
        Assert-True 'S1: headless output is valid JSON' ($null -ne $parsed) "Raw: $($jsonOutput.Substring(0,[Math]::Min(200,$jsonOutput.Length)))"

        if ($null -ne $parsed) {
            Assert-True 'S1: headless JSON has exit_code field' ($null -ne $parsed.exit_code) ''
            Assert-Equal 'S1: headless JSON phases_total is 6' 6 $parsed.summary.phases_total
            Assert-True 'S1: headless JSON summary.issues_total is integer' ($null -ne $parsed.summary.issues_total) ''

            $expectedPhaseNames = @(
                'Bootstrap prerequisites'
                'Cloning repositories'
                'Toolchain (proto install per repo)'
                'Other prerequisites'
                'Repo structure validation'
            )
            foreach ($phaseName in $expectedPhaseNames) {
                $found = $parsed.phases | Where-Object { $_.name -eq $phaseName }
                Assert-True "S1: headless JSON contains phase '$phaseName'" ($null -ne $found) ''
            }

            # Exit code from headless must match a direct streaming run
            $envBackup = $env:NO_COLOR
            $env:NO_COLOR = '1'
            try {
                $null = & pwsh -NoProfile -File $bootstrapScript -Ascii 2>&1
                $streamingExit = $LASTEXITCODE
            } finally {
                if ($null -eq $envBackup) { Remove-Item env:NO_COLOR -ErrorAction SilentlyContinue }
                else { $env:NO_COLOR = $envBackup }
            }
            Assert-Equal 'S1: headless exit code matches streaming exit code' $streamingExit $headlessExit
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# Scenario 2 — Fallback streaming path
# Simulate tools/ absent by temporarily renaming derekh.psm1, then assert
# bootstrap streaming renderer runs unmodified.
# ═══════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "--- Scenario 2: fallback streaming path ---" -ForegroundColor Cyan

$renamedPsm1 = $derekhPsm1 + '.bak'

# Rename psm1 if it exists (so Test-Path $derekhPsm1 returns $false inside bootstrap)
$didRename = $false
if (Test-Path $derekhPsm1) {
    Rename-Item -Path $derekhPsm1 -NewName ($renamedPsm1 | Split-Path -Leaf) -ErrorAction Stop
    $didRename = $true
}

try {
    $envBackup = $env:NO_COLOR
    $env:NO_COLOR = '1'
    try {
        $streamingOutput = & pwsh -NoProfile -File $bootstrapScript -Ascii 2>&1 | Out-String
        $streamingExit = $LASTEXITCODE
    } finally {
        if ($null -eq $envBackup) { Remove-Item env:NO_COLOR -ErrorAction SilentlyContinue }
        else { $env:NO_COLOR = $envBackup }
    }

    Assert-True 'S2: fallback streaming exit code in {0,1,2}' ($streamingExit -in @(0, 1, 2)) "got $streamingExit"
    Assert-True 'S2: fallback streaming output contains banner header' ($streamingOutput.Contains('Fellwork Bootstrap')) ''

    $expectedSections = @(
        'Bootstrap prerequisites'
        'Cloning repositories'
        'Toolchain (proto install per repo)'
        'Other prerequisites'
        'Env files'
        'Repo structure validation'
        'Summary'
    )
    foreach ($section in $expectedSections) {
        Assert-True "S2: fallback streaming has section '$section'" ($streamingOutput.Contains($section)) ''
    }

    # Confirm no derekh-path markers leaked into streaming output
    Assert-True 'S2: derekh TUI NOT active (no JSON in stdout)' (-not ($streamingOutput.TrimStart().StartsWith('{'))) ''

} finally {
    # Always restore the renamed psm1 so we leave the workspace clean
    if ($didRename -and (Test-Path $renamedPsm1)) {
        Rename-Item -Path $renamedPsm1 -NewName ($derekhPsm1 | Split-Path -Leaf) -ErrorAction SilentlyContinue
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "Derekh integration: $passes pass, $failures fail"

if ($failures -gt 0) { exit 1 } else { exit 0 }
```

- [ ] **Step 2: Run the new test suite in isolation**

```bash
pwsh /c/git/fellwork/bootstrap/tests/test-derekh-integration.ps1
```

Expected outcomes:
- If tools/ is absent: all Scenario 1 tests show `PASS: SKIP ...`; all Scenario 2 tests pass. Exit code 0.
- If tools/ is present with stubs only (Phase A complete, D not): Scenario 1 module-load tests pass; `Invoke-DhPlan` stub tests show `PASS: SKIP ...`; Scenario 2 passes. Exit code 0.
- If tools/ is present with full implementation (Phases A–F+): all tests in both scenarios produce real assertions and all pass. Exit code 0.

- [ ] **Step 3: Run the full test suite to confirm auto-discovery picks up the new file**

```bash
pwsh /c/git/fellwork/bootstrap/tests/run-all.ps1
```

Expected: all suites pass (exit 0); `test-derekh-integration` appears in the runner's output table with nonzero pass count and zero fail count.

- [ ] **Step 4: Commit**

```bash
cd /c/git/fellwork/bootstrap
git add tests/test-derekh-integration.ps1
git commit -m "test(bootstrap): E2E tests for derekh integration — both code paths covered"
```

- [ ] **Step 5: Run the full suite one final time and capture the output as the green-baseline proof**

```bash
pwsh /c/git/fellwork/bootstrap/tests/run-all.ps1
```

Record the total pass count. The PR description will reference this as the post-Phase-H green baseline.

- [ ] **Step 6: Push the branch and open a PR**

```bash
cd /c/git/fellwork/bootstrap
git push -u origin feat/derekh-integration
```

```bash
gh pr create \
  --repo fellwork/bootstrap \
  --base main \
  --head feat/derekh-integration \
  --title "feat(bootstrap): Phase H — Derekh TUI integration" \
  --body "$(cat <<'EOF'
## Summary

- Adds `tools` as the 8th repo in `repos.psd1` with `structureCheck = @('derekh/derekh.psd1')` so bootstrap validates the module manifest after cloning.
- Adds a derekh-detection block at the top of `bootstrap.ps1`: detects `../tools/derekh/derekh.psm1`, imports the module in a `try/catch`, and activates the Derekh TUI path if import succeeds.
- Adds `Build-BootstrapPlan` function that maps all 6 existing bootstrap phases to the Derekh plan schema (`Add-DhLoopPhase` / `Add-DhSinglePhase`), wrapping each action result via `New-DhResult`.
- Adds `tests/test-derekh-integration.ps1` with two E2E scenarios: derekh path (headless mode, JSON-parsed assertions) and fallback streaming path (psm1 temporarily renamed, streaming output asserted).

## Dual code path

| Condition | Code path |
|---|---|
| `tools/derekh/derekh.psm1` absent (first run) | Existing streaming renderer — unchanged |
| `tools/derekh/derekh.psm1` present, `Import-Module` succeeds | `Build-BootstrapPlan` + `Invoke-DhPlan` |
| `tools/derekh/derekh.psm1` present, `Import-Module` fails | Warning to stderr, falls through to streaming renderer |

The existing streaming renderer code is **not modified** — the integration is purely additive. All 658 existing tests continue to pass.

## Test plan

- [ ] `pwsh tests/run-all.ps1` exits 0 — all suites pass (bootstrap pre-existing + new derekh-integration suite)
- [ ] `test-derekh-integration.ps1` Scenario 2 (fallback) asserts all 7 streaming section headers present
- [ ] `test-derekh-integration.ps1` Scenario 1 (derekh, if tools/ available) asserts JSON `phases_total = 6` and exit codes match
- [ ] After merging, a fresh developer who clones bootstrap but not tools/ still gets the existing streaming output with exit 0

🤖 Generated with [Claude Code](https://claude.ai/claude-code)
EOF
)"
```

Expected: PR URL printed. Verify it opens to a clean diff showing only the four changes: `repos.psd1`, `bootstrap.ps1` (detection block + `Build-BootstrapPlan`), `tests/test-derekh-integration.ps1`, and optionally `tests/test-e2e.ps1` if updated in Task H1.

---

## Phase H completion checklist

After all four tasks, verify each item before merging the PR:

- [ ] `git branch` shows `feat/derekh-integration` with 4 commits (H1, H2, H3, H4)
- [ ] `repos.psd1` has exactly 8 entries; last entry is `tools` with `structureCheck = @('derekh/derekh.psd1')`
- [ ] `bootstrap.ps1` contains the derekh-detection block with `Test-Path $derekhModule` + `try/catch` around `Import-Module`
- [ ] `bootstrap.ps1` contains `Build-BootstrapPlan` function with all 6 phases wired
- [ ] `tests/test-derekh-integration.ps1` exists and is auto-discovered by `run-all.ps1`
- [ ] `pwsh tests/run-all.ps1` exits 0 with the same or higher total pass count as the pre-Phase-H baseline
- [ ] Running bootstrap with tools/ absent produces identical streaming output to a pre-Phase-H run (same exit code, same section headers, same [ok]/[??]/[!!] count)
- [ ] PR is open on `fellwork/bootstrap` targeting `main`; no direct push to `main` occurred

**Post-merge:** On the first `git pull` of bootstrap after the merge, developers with tools/ already cloned will automatically get the derekh path on their next run. Developers without tools/ will see no change until they run bootstrap again (which will clone tools/ and unlock derekh for subsequent runs).
