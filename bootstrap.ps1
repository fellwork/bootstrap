#Requires -Version 7
[CmdletBinding()]
param(
    [switch]$Help,
    [switch]$NoColor,
    [switch]$Ascii
)

$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot

# Source library files
. "$scriptRoot/lib/ui.ps1"
. "$scriptRoot/lib/animals.ps1"
. "$scriptRoot/lib/prereqs.ps1"
. "$scriptRoot/lib/repos.ps1"

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
        $summary.Warnings += @{ Name = $p.Name; Reason = 'not running' }
    } else {
        Write-Host (Format-Color -Text "$($glyphs.Warn) $($p.Name.PadRight(12)) not found" -Color Yellow -Enabled $colorOn)
        if ($p.Workaround) {
            Write-Host (Format-Color -Text "  workaround: $($p.Workaround)" -Color DimGray -Enabled $colorOn)
        } elseif ($p.InstallUrl) {
            Write-Host (Format-Color -Text "  install: $($p.InstallUrl)" -Color DimGray -Enabled $colorOn)
        }
        $summary.Warnings += @{ Name = $p.Name; Reason = 'missing' }
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
            $summary.Warnings += @{ Name = $env.Target; Reason = 'fill-secrets' }
        } catch {
            Write-Host (Format-Color -Text "$($glyphs.Fail) failed to scaffold $($env.Target): $_" -Color Red -Enabled $colorOn)
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
        $summary.Warnings += @{ Name = $repo.name; Reason = 'structure-check' }
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

# Next-steps reminder
$owlPhrase = Get-AnimalPhrase -Animal 'owl' -Situation 'pro-tip'
Write-Host "🦉  $owlPhrase"

# Exit code: 2 for any hard fail, 1 for warnings only
if ($failCount -gt 0) { exit 2 }
elseif ($warnCount -gt 0) { exit 1 }
else { exit 0 }
