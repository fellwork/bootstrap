#Requires -Version 7
# Run every test suite in tests/ and print a summary.
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

$results = @()
$totalPass = 0
$totalFail = 0
$totalSeconds = 0.0
$suiteFailed = $false

# Color helpers (use only standard PS host colors so we don't depend on lib/ui.ps1)
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
    Write-Host -NoNewline ("  {0,-22} " -f $name)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $output = & pwsh -NoProfile -File $suite.FullName 2>&1 | Out-String
    $exit = $LASTEXITCODE
    $sw.Stop()
    $totalSeconds += $sw.Elapsed.TotalSeconds

    $passCount = ([regex]::Matches($output, '^PASS:', 'Multiline')).Count
    $failCount = ([regex]::Matches($output, '^FAIL:', 'Multiline')).Count
    $totalPass += $passCount
    $totalFail += $failCount

    if ($VerbosePreference -eq 'Continue') {
        # In -Verbose, stream the full output after the suite runs
        Write-Host ""
        Write-Dim $output
    }

    if ($exit -eq 0 -and $failCount -eq 0) {
        Write-Ok ("{0,4} pass  ({1,5:F1}s)" -f $passCount, $sw.Elapsed.TotalSeconds)
    } else {
        Write-Fail ("{0,4} pass  {1} fail  (exit {2}, {3:F1}s)" -f $passCount, $failCount, $exit, $sw.Elapsed.TotalSeconds)
        $suiteFailed = $true

        # Show the failing assertions even without -Verbose (you almost always
        # want to see what failed without re-running)
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
