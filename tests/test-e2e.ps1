# End-to-end tests for bootstrap.ps1 — run the actual script and assert structural behavior.
# Uses the real sibling repos at c:/git/fellwork/* (which all exist by design from
# this session's setup work).

$failures = 0
function Assert-Equal($expected, $actual, $message) {
    if ($expected -ne $actual) {
        Write-Host "FAIL: $message — expected '$expected' got '$actual'" -ForegroundColor Red
        $script:failures++
    } else {
        Write-Host "PASS: $message" -ForegroundColor Green
    }
}
function Assert-True($cond, $message) {
    if ($cond) { Write-Host "PASS: $message" -ForegroundColor Green }
    else       { Write-Host "FAIL: $message" -ForegroundColor Red; $script:failures++ }
}

$bootstrapRoot = Resolve-Path "$PSScriptRoot/.."
$bootstrapScript = Join-Path $bootstrapRoot "bootstrap.ps1"

Assert-True (Test-Path $bootstrapScript) "bootstrap.ps1 exists at expected path"

# === T7-1: --help exits 0 with usage text ===
$helpOutput = & pwsh -NoProfile -File $bootstrapScript -Help 2>&1 | Out-String
$helpExit = $LASTEXITCODE
Assert-Equal 0 $helpExit "--help: exit code 0"
Assert-True ($helpOutput.Contains("Fellwork Bootstrap")) "--help: contains 'Fellwork Bootstrap' header"
Assert-True ($helpOutput.Contains("Usage:")) "--help: contains 'Usage:'"
Assert-True ($helpOutput.Contains("--no-color")) "--help: documents --no-color"
Assert-True ($helpOutput.Contains("--ascii")) "--help: documents --ascii"
Assert-True ($helpOutput.Contains("Exit codes")) "--help: documents exit codes"

# === T7-2: Full run with NO_COLOR — exit code 0 or 1, all sections present ===
# Use NO_COLOR env var to make output predictable for content-matching
$envBackup = $env:NO_COLOR
$env:NO_COLOR = "1"
try {
    $fullOutput = & pwsh -NoProfile -File $bootstrapScript -Ascii 2>&1 | Out-String
    $fullExit = $LASTEXITCODE
} finally {
    if ($null -eq $envBackup) {
        Remove-Item env:NO_COLOR -ErrorAction SilentlyContinue
    } else {
        $env:NO_COLOR = $envBackup
    }
}

# Exit code: 0 if all clean, 1 if warnings only, 2 if hard fails
Assert-True ($fullExit -in @(0, 1, 2)) "full run: exit code is in {0, 1, 2} (got $fullExit)"

# Banner present
Assert-True ($fullOutput.Contains("Fellwork Bootstrap")) "full run: banner header present"

# All major section headers appear
$expectedSections = @(
    "Bootstrap prerequisites"
    "Cloning repositories"
    "Toolchain (proto install per repo)"
    "Other prerequisites"
    "Env files"
    "Repo structure validation"
    "Summary"
)
foreach ($section in $expectedSections) {
    Assert-True ($fullOutput.Contains($section)) "full run: section header '$section' present"
}

# All 7 expected repos appear in output (cloning section)
$expectedRepos = @('api', 'web', 'ops', 'lint', 'scribe', 'shared-configs', 'tsconfig')
foreach ($r in $expectedRepos) {
    Assert-True ($fullOutput.Contains($r)) "full run: repo name '$r' appears in output"
}

# === T7-3: Idempotency — semantic stability across two runs ===
$envBackup2 = $env:NO_COLOR
$env:NO_COLOR = "1"
try {
    $run1 = & pwsh -NoProfile -File $bootstrapScript -Ascii 2>&1 | Out-String
    $exit1 = $LASTEXITCODE
    $run2 = & pwsh -NoProfile -File $bootstrapScript -Ascii 2>&1 | Out-String
    $exit2 = $LASTEXITCODE
} finally {
    if ($null -eq $envBackup2) {
        Remove-Item env:NO_COLOR -ErrorAction SilentlyContinue
    } else {
        $env:NO_COLOR = $envBackup2
    }
}

Assert-Equal $exit1 $exit2 "idempotency: same exit code across runs"

# Count of [ok] markers should match between runs
$okCount1 = ([regex]::Matches($run1, '\[ok\]')).Count
$okCount2 = ([regex]::Matches($run2, '\[ok\]')).Count
Assert-Equal $okCount1 $okCount2 "idempotency: same count of [ok] markers"

# Count of [??] (warning) markers should match
$warnCount1 = ([regex]::Matches($run1, '\[\?\?\]')).Count
$warnCount2 = ([regex]::Matches($run2, '\[\?\?\]')).Count
Assert-Equal $warnCount1 $warnCount2 "idempotency: same count of [??] markers"

# Count of [!!] (failure) markers should match
$failCount1 = ([regex]::Matches($run1, '\[!!\]')).Count
$failCount2 = ([regex]::Matches($run2, '\[!!\]')).Count
Assert-Equal $failCount1 $failCount2 "idempotency: same count of [!!] markers"

# === T7-4: All 7 repos detected as already cloned ===
Assert-True ($run1.Contains("already cloned, origin matches") -or $run1.Contains("already cloned")) "run1: at least one repo shown as already cloned"
$alreadyClonedCount = ([regex]::Matches($run1, "already cloned")).Count
Assert-Equal 7 $alreadyClonedCount "run1: all 7 repos shown as already cloned"

# === T7-5: --no-color flag strips ANSI escape codes ===
$noColorOutput = & pwsh -NoProfile -File $bootstrapScript -NoColor -Ascii 2>&1 | Out-String
$noColorExit = $LASTEXITCODE
Assert-True ($noColorExit -in @(0, 1, 2)) "--no-color: valid exit code"
# No raw escape sequences should appear
Assert-True (-not ($noColorOutput -match "`e\[")) "--no-color: zero ANSI escape sequences in output"

# === T7-6: --ascii flag forces ASCII glyphs ===
# With --ascii AND a UTF-8 console, the script must still use ASCII glyphs
$envBackup3 = $env:NO_COLOR
$env:NO_COLOR = "1"
try {
    $asciiOutput = & pwsh -NoProfile -File $bootstrapScript -Ascii 2>&1 | Out-String
} finally {
    if ($null -eq $envBackup3) {
        Remove-Item env:NO_COLOR -ErrorAction SilentlyContinue
    } else {
        $env:NO_COLOR = $envBackup3
    }
}
# Tree branches should be ASCII (+- not ├─, '- not └─)
Assert-True ($asciiOutput.Contains("+-") -or $asciiOutput.Contains("'-")) "--ascii: ASCII tree branches present"
Assert-True ($asciiOutput.Contains("[ok]") -or $asciiOutput.Contains("[??]")) "--ascii: ASCII status glyphs present"

# === T7-7: Summary section reports counts ===
Assert-True ($run1.Contains("repos cloned and validated")) "run1: summary mentions repo count"

# === T7-8: Performance — full run completes in reasonable time ===
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$envBackup4 = $env:NO_COLOR
$env:NO_COLOR = "1"
try {
    $null = & pwsh -NoProfile -File $bootstrapScript -Ascii 2>&1
} finally {
    if ($null -eq $envBackup4) {
        Remove-Item env:NO_COLOR -ErrorAction SilentlyContinue
    } else {
        $env:NO_COLOR = $envBackup4
    }
}
$sw.Stop()
# Reasonable bound: should complete in under 60s on the all-clean path
# (proto install per repo can take a few seconds each — 60s gives headroom)
Assert-True ($sw.Elapsed.TotalSeconds -lt 60) "performance: full run completes in <60s (took $($sw.Elapsed.TotalSeconds.ToString('F1'))s)"

if ($failures -eq 0) {
    Write-Host "`nAll E2E tests passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n$failures E2E test(s) failed." -ForegroundColor Red
    exit 1
}
