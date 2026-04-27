#Requires -Version 7
[CmdletBinding()]
param(
    [switch]$Help,
    [switch]$NoColor,
    [switch]$Ascii,
    # Passed through to Invoke-DhPlan when derekh is active: emit JSON to stdout
    # instead of TUI/streaming output. Used by test-derekh-integration.ps1 and CI.
    [switch]$Headless
)

$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot

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
# ── End derekh detection ──────────────────────────────────────────────────

# Source library files
. "$scriptRoot/lib/ui.ps1"
. "$scriptRoot/lib/animals.ps1"
. "$scriptRoot/lib/prereqs.ps1"
. "$scriptRoot/lib/repos.ps1"

# ── Build-BootstrapPlan — maps existing phases to Derekh plan schema ──────
# Called only when $useDerekh is $true. Defined here so lib functions are
# available (dot-sourced above). Placed before $if ($Help) so the derekh
# early-exit below can invoke it before any streaming output is produced.
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

        foreach ($p in $otherPrereqs) {
            if ($p.Status -eq 'present') {
                $alerts += New-DhAlert -Severity 'info' -Message "$($p.Name) $($p.Version)"
            } elseif ($p.Status -eq 'present-but-not-running') {
                $alerts += New-DhAlert -Severity 'warning' `
                    -Message "$($p.Name) is installed but its daemon isn't running" `
                    -FixCommand (if ($p.Workaround) { $p.Workaround } else { "Start the $($p.Name) daemon (e.g. open Docker Desktop)" })
            } else {
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
# ── End Build-BootstrapPlan ───────────────────────────────────────────────

if ($Help) {
    Write-Host @"
Fellwork Bootstrap

Usage: ./bootstrap.ps1 [--help] [--no-color] [--ascii]

Clones the seven Fellwork repositories as siblings of this bootstrap repo,
runs proto install per repo, validates other prereqs, and scaffolds env files.

Flags:
  --help       Show this message
  --no-color   Disable color output (also: NO_COLOR env var)
  --ascii      Use ASCII fallback for glyphs

Exit codes:
  0   All clean
  1   Warnings only
  2   Hard failures
"@
    exit 0
}

# ── Derekh early-exit (replaces streaming output for the entire run) ──────
# Runs after --help so that -Help always works regardless of tools/ state.
# Runs before streaming setup so no streaming output is emitted on the derekh path.
if ($useDerekh) {
    $parentDirForPlan = Split-Path -Parent $scriptRoot
    $plan = Build-BootstrapPlan -ScriptRoot $scriptRoot -ParentDir $parentDirForPlan `
                                -NoColor $NoColor.IsPresent -Ascii $Ascii.IsPresent
    if ($Headless.IsPresent) {
        Invoke-DhPlan -Plan $plan -Headless
    } else {
        Invoke-DhPlan -Plan $plan
    }
    exit $LASTEXITCODE
}
# ── End derekh early-exit ─────────────────────────────────────────────────

# Apply UI overrides
Set-UiOverrides -NoColor $NoColor.IsPresent -Ascii $Ascii.IsPresent
$caps = Get-TerminalCaps
$glyphs = Get-Glyphs -Utf8 $caps.SupportsUtf8
$colorOn = $caps.SupportsColor

# Self-check: confirm we're running from c:/git/fellwork/bootstrap (or sibling layout works)
$parentDir = Split-Path -Parent $scriptRoot
if (-not (Test-Path $parentDir)) {
    Write-Host "Cannot determine parent directory. Bootstrap must run from a folder with a writable parent." -ForegroundColor Red
    exit 2
}

# Banner
Write-Host ""
Write-Host (Format-Banner -Title "Fellwork Bootstrap" -Subtitle (Get-Date -Format "HH:mm:ss") -Width 60 -Glyphs $glyphs -Enabled $colorOn)
Write-Host ""

# Track status across phases
$summary = @{
    Repos     = @()
    Prereqs   = @()
    EnvFiles  = @()
    HardFails = @()
    Warnings  = @()
}

# --- Phase 1: Bootstrap-time prereq check ---
Write-Host (Format-Section -Title "Bootstrap prerequisites" -Glyphs $glyphs -Enabled $colorOn)
$bootstrapPrereqs = @('git', 'proto')
$bootstrapOk = $true
foreach ($p in $bootstrapPrereqs) {
    $r = Get-PrereqResult -Name $p -Required $true
    if ($r.Status -eq 'present') {
        $line = "$($glyphs.Ok) $($p.PadRight(12)) $($r.Version)"
        Write-Host (Format-Color -Text $line -Color Green -Enabled $colorOn)
    } else {
        $line = "$($glyphs.Fail) $($p.PadRight(12)) MISSING"
        Write-Host (Format-Color -Text $line -Color Red -Enabled $colorOn)
        $bootstrapOk = $false
        $summary.HardFails += @{
            Title       = "$p is required and not installed"
            FixCommand  = "Install: $($r.InstallUrl)"
            Animal      = 'octopus'
        }
    }
}
Write-Host ""

if (-not $bootstrapOk) {
    Write-Host "Bootstrap-time prereqs missing. Cannot proceed." -ForegroundColor Red
    foreach ($f in $summary.HardFails) {
        Write-Host (Format-AnimalErrorMoment -Animal $f.Animal -Message $f.Title -FixCommand $f.FixCommand -TermWidth $caps.Width -RootDir $scriptRoot -Glyphs $glyphs -Enabled $colorOn)
        Write-Host ""
    }
    exit 2
}

# --- Phase 2: Clone repos ---
$repoData = Import-PowerShellDataFile (Join-Path $scriptRoot 'repos.psd1')
Write-Host (Format-Section -Title "Cloning repositories" -Glyphs $glyphs -Enabled $colorOn)

foreach ($repo in $repoData.repos) {
    $expectedOrigin = "https://github.com/$($repo.org)/$($repo.name).git"
    $state = Get-RepoState -Name $repo.name -ParentDir $parentDir -ExpectedOrigin $expectedOrigin

    Write-Host (Format-Color -Text $repo.name -Color White -Enabled $colorOn -Bold $true)

    switch ($state.Status) {
        'present-matching' {
            Write-Host (Format-TreeLine -Glyphs $glyphs -IsLast $false -Indent 0 -Text (Format-Color -Text "$($glyphs.Ok) already cloned, origin matches" -Color Green -Enabled $colorOn))
            Write-Host (Format-TreeLine -Glyphs $glyphs -IsLast $true  -Indent 0 -Text (Format-Color -Text "$($glyphs.Ok) on branch $($state.Branch)" -Color Green -Enabled $colorOn))
            $summary.Repos += @{ Name = $repo.name; Status = 'ok'; Action = 'skipped' }
        }
        'present-mismatch' {
            Write-Host (Format-TreeLine -Glyphs $glyphs -IsLast $true -Indent 0 -Text (Format-Color -Text "$($glyphs.Fail) wrong origin: $($state.Origin)" -Color Red -Enabled $colorOn))
            $summary.HardFails += @{
                Title      = "Repo '$($repo.name)' exists but points to wrong origin: $($state.Origin)"
                FixCommand = "cd $parentDir/$($repo.name) && git remote set-url origin $expectedOrigin"
                Animal     = 'raccoon'
            }
            $summary.Repos += @{ Name = $repo.name; Status = 'fail'; Action = 'skipped-mismatch' }
        }
        'present-not-git' {
            Write-Host (Format-TreeLine -Glyphs $glyphs -IsLast $true -Indent 0 -Text (Format-Color -Text "$($glyphs.Fail) directory exists but is not a git repo" -Color Red -Enabled $colorOn))
            $summary.HardFails += @{
                Title      = "Path '$($state.Path)' exists but is not a git repo"
                FixCommand = "Inspect $($state.Path) and resolve manually (back up & remove if appropriate, then rerun)"
                Animal     = 'raccoon'
            }
            $summary.Repos += @{ Name = $repo.name; Status = 'fail'; Action = 'skipped-non-git' }
        }
        'absent' {
            Write-Host (Format-TreeLine -Glyphs $glyphs -IsLast $false -Indent 0 -Text "$($glyphs.Ellipsis) cloning…")
            $clone = Invoke-RepoClone -Name $repo.name -Org $repo.org -ParentDir $parentDir
            if ($clone.Success) {
                Write-Host (Format-TreeLine -Glyphs $glyphs -IsLast $true -Indent 0 -Text (Format-Color -Text "$($glyphs.Ok) cloned" -Color Green -Enabled $colorOn))
                $summary.Repos += @{ Name = $repo.name; Status = 'ok'; Action = 'cloned' }
            } else {
                Write-Host (Format-TreeLine -Glyphs $glyphs -IsLast $true -Indent 0 -Text (Format-Color -Text "$($glyphs.Fail) clone failed (exit $($clone.ExitCode))" -Color Red -Enabled $colorOn))
                $summary.HardFails += @{
                    Title      = "git clone failed for $($repo.name)"
                    FixCommand = "Check network/auth, then rerun: git clone $expectedOrigin"
                    Animal     = 'octopus'
                }
                $summary.Repos += @{ Name = $repo.name; Status = 'fail'; Action = 'clone-failed' }
            }
        }
    }
    Write-Host ""
}

# --- Phase 3: Proto install per repo ---
Write-Host (Format-Section -Title "Toolchain (proto install per repo)" -Glyphs $glyphs -Enabled $colorOn)
foreach ($repo in $repoData.repos) {
    $repoStatus = ($summary.Repos | Where-Object { $_.Name -eq $repo.name } | Select-Object -First 1)
    if (-not $repoStatus -or $repoStatus.Status -ne 'ok') { continue }
    $repoPath = Join-Path $parentDir $repo.name

    Write-Host (Format-Color -Text $repo.name -Color White -Enabled $colorOn -Bold $true)
    $result = Invoke-ProtoInstall -RepoPath $repoPath
    if ($result.Skipped) {
        Write-Host (Format-TreeLine -Glyphs $glyphs -IsLast $true -Indent 0 -Text (Format-Color -Text "$($glyphs.Ellipsis) no .prototools — skipping" -Color DimGray -Enabled $colorOn))
    } elseif ($result.Success) {
        Write-Host (Format-TreeLine -Glyphs $glyphs -IsLast $true -Indent 0 -Text (Format-Color -Text "$($glyphs.Ok) tools installed" -Color Green -Enabled $colorOn))
    } else {
        Write-Host (Format-TreeLine -Glyphs $glyphs -IsLast $true -Indent 0 -Text (Format-Color -Text "$($glyphs.Fail) proto install failed (exit $($result.ExitCode))" -Color Red -Enabled $colorOn))
        $summary.HardFails += @{
            Title      = "proto install failed for $($repo.name)"
            FixCommand = "cd $repoPath && proto install"
            Animal     = 'octopus'
        }
    }
    Write-Host ""
}

# --- Phase 4: Other prereqs ---
Write-Host (Format-Section -Title "Other prerequisites" -Glyphs $glyphs -Enabled $colorOn)
$otherPrereqs = Get-AllPrereqs | Where-Object { $_.Name -notin @('git','proto','rustc','node','bun') }
foreach ($p in $otherPrereqs) {
    if ($p.Status -eq 'present') {
        Write-Host (Format-Color -Text "$($glyphs.Ok) $($p.Name.PadRight(12)) $($p.Version)" -Color Green -Enabled $colorOn)
    } elseif ($p.Status -eq 'present-but-not-running') {
        Write-Host (Format-Color -Text "$($glyphs.Warn) $($p.Name.PadRight(12)) installed but daemon not running" -Color Yellow -Enabled $colorOn)
        $summary.Warnings += @{
            Name       = $p.Name
            Reason     = 'not running'
            Title      = "$($p.Name) is installed but its daemon isn't running"
            FixCommand = if ($p.Workaround) { $p.Workaround } else { "Start the $($p.Name) daemon (e.g. open Docker Desktop)" }
            Animal     = 'fox'
        }
    } else {
        Write-Host (Format-Color -Text "$($glyphs.Warn) $($p.Name.PadRight(12)) not found" -Color Yellow -Enabled $colorOn)
        if ($p.Workaround) {
            Write-Host (Format-Color -Text "  workaround: $($p.Workaround)" -Color DimGray -Enabled $colorOn)
        } elseif ($p.InstallUrl) {
            Write-Host (Format-Color -Text "  install: $($p.InstallUrl)" -Color DimGray -Enabled $colorOn)
        }
        # Optional tool with a workaround → turtle (no rush). Otherwise install URL → owl (you should know).
        $animal = if ($p.Workaround) { 'turtle' } else { 'owl' }
        $fixCmd = if ($p.Workaround) { $p.Workaround } elseif ($p.InstallUrl) { $p.InstallUrl } else { "Install $($p.Name) from your platform's package manager" }
        $summary.Warnings += @{
            Name       = $p.Name
            Reason     = 'missing'
            Title      = "$($p.Name) is not installed"
            FixCommand = $fixCmd
            Animal     = $animal
        }
    }
}
Write-Host ""

# --- Phase 5: Env scaffolding ---
Write-Host (Format-Section -Title "Env files" -Glyphs $glyphs -Enabled $colorOn)
foreach ($repo in $repoData.repos) {
    $repoStatus = ($summary.Repos | Where-Object { $_.Name -eq $repo.name } | Select-Object -First 1)
    if (-not $repoStatus -or $repoStatus.Status -ne 'ok') { continue }
    $needed = Test-EnvFilesNeeded -Repo $repo -ParentDir $parentDir
    if ($needed.Count -eq 0) { continue }
    foreach ($env in $needed) {
        try {
            Invoke-EnvScaffold -EnvFile $env
            Write-Host (Format-Color -Text "$($glyphs.Ok) scaffolded: $($env.Target)" -Color Green -Enabled $colorOn)
            Write-Host (Format-Color -Text "  fill in real secrets before using" -Color Yellow -Enabled $colorOn)
            $summary.EnvFiles += $env.Target
            $summary.Warnings += @{
                Name       = $env.Target
                Reason     = 'fill-secrets'
                Title      = "Fill in secrets in $($env.Target)"
                FixCommand = "Edit $($env.Target) and replace placeholder values with real credentials (do not commit)"
                Animal     = 'hedgehog'
            }
        } catch {
            Write-Host (Format-Color -Text "$($glyphs.Fail) failed to scaffold $($env.Target): $_" -Color Red -Enabled $colorOn)
            $summary.HardFails += @{
                Title      = "Failed to scaffold env file: $($env.Target)"
                FixCommand = "Manually copy $($env.Example) to $($env.Target)"
                Animal     = 'hedgehog'
            }
        }
    }
}
Write-Host ""

# --- Phase 6: Structure validation ---
Write-Host (Format-Section -Title "Repo structure validation" -Glyphs $glyphs -Enabled $colorOn)
foreach ($repo in $repoData.repos) {
    $repoStatus = ($summary.Repos | Where-Object { $_.Name -eq $repo.name } | Select-Object -First 1)
    if (-not $repoStatus -or $repoStatus.Status -ne 'ok') { continue }
    $valid = Test-RepoStructure -Repo $repo -ParentDir $parentDir
    if ($valid) {
        Write-Host (Format-Color -Text "$($glyphs.Ok) $($repo.name)" -Color Green -Enabled $colorOn)
    } else {
        Write-Host (Format-Color -Text "$($glyphs.Warn) $($repo.name) — expected files missing" -Color Yellow -Enabled $colorOn)
        $expected = if ($repo.structureCheck) { $repo.structureCheck -join ', ' } else { '(check repos.psd1)' }
        $summary.Warnings += @{
            Name       = $repo.name
            Reason     = 'structure-check'
            Title      = "$($repo.name) is missing expected files"
            FixCommand = "cd $parentDir/$($repo.name) && check that these files exist: $expected"
            Animal     = 'raccoon'
        }
    }
}
Write-Host ""

# --- Phase 7: Summary ---
$cleanRepos = ($summary.Repos | Where-Object { $_.Status -eq 'ok' }).Count
$totalRepos = $summary.Repos.Count
$warnCount = $summary.Warnings.Count
$failCount = $summary.HardFails.Count

Write-Host (Format-Section -Title "Summary" -Glyphs $glyphs -Enabled $colorOn)

if ($failCount -eq 0 -and $warnCount -eq 0) {
    $headline = "$($glyphs.Ok) $cleanRepos repos cloned and validated — ready to build."
    Write-Host (Format-RainbowText -Text $headline -Enabled $colorOn)
    $otterPhrase = Get-AnimalPhrase -Animal 'otter' -Situation 'celebrate'
    Write-Host ""
    Write-Host "🦦  $otterPhrase"
    exit 0
}

Write-Host (Format-Color -Text "$($glyphs.Ok) $cleanRepos / $totalRepos repos cloned and validated" -Color Green -Enabled $colorOn)
if ($warnCount -gt 0) {
    Write-Host (Format-Color -Text "$($glyphs.Warn) $warnCount warning(s)" -Color Yellow -Enabled $colorOn)
}
if ($failCount -gt 0) {
    Write-Host (Format-Color -Text "$($glyphs.Fail) $failCount hard failure(s)" -Color Red -Enabled $colorOn)
}
Write-Host ""

# Show ASCII art for each hard failure
foreach ($f in $summary.HardFails) {
    Write-Host (Format-AnimalErrorMoment -Animal $f.Animal -Message $f.Title -FixCommand $f.FixCommand -TermWidth $caps.Width -RootDir $scriptRoot -Glyphs $glyphs -Enabled $colorOn)
    Write-Host ""
}

# Show ASCII art for each warning (full sprite + speech-box treatment)
foreach ($w in $summary.Warnings) {
    if (-not $w.Title) { continue }   # legacy/incomplete warnings — skip rendering
    Write-Host (Format-AnimalErrorMoment -Animal $w.Animal -Message $w.Title -FixCommand $w.FixCommand -TermWidth $caps.Width -RootDir $scriptRoot -Glyphs $glyphs -Enabled $colorOn)
    Write-Host ""
}

# --- Suggested next steps — consolidated, copy-pasteable ---
$allActionable = @()
$allActionable += $summary.HardFails
$allActionable += ($summary.Warnings | Where-Object { $_.FixCommand })

if ($allActionable.Count -gt 0) {
    Write-Host (Format-Section -Title "Suggested next steps" -Glyphs $glyphs -Enabled $colorOn)
    Write-Host (Format-Color -Text "Run these in order, then rerun ./bootstrap.ps1 to verify:" -Color Cyan -Enabled $colorOn)
    Write-Host ""
    $stepNum = 1
    foreach ($item in $allActionable) {
        $marker = if ($item -in $summary.HardFails) { $glyphs.Fail } else { $glyphs.Warn }
        $color  = if ($item -in $summary.HardFails) { 'Red' } else { 'Yellow' }
        Write-Host (Format-Color -Text ("  {0,2}. $marker  $($item.Title)" -f $stepNum) -Color $color -Enabled $colorOn)
        Write-Host (Format-Color -Text "      $($item.FixCommand)" -Color DimGray -Enabled $colorOn)
        Write-Host ""
        $stepNum++
    }
}

# Closing nudge
$owlPhrase = Get-AnimalPhrase -Animal 'owl' -Situation 'pro-tip'
Write-Host "🦉  $owlPhrase"

# Exit code: 2 for any hard fail, 1 for warnings only
if ($failCount -gt 0) { exit 2 }
elseif ($warnCount -gt 0) { exit 1 }
else { exit 0 }
