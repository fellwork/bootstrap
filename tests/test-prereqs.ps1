. "$PSScriptRoot/../lib/prereqs.ps1"

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

# Test-CommandExists
Assert-True (Test-CommandExists -Name 'git') "git exists (assumed dev environment)"
Assert-Equal $false (Test-CommandExists -Name 'definitely-not-a-real-command-xyz123') "fake command does not exist"

# Get-PrereqResult: present command
$res = Get-PrereqResult -Name 'git' -VersionFlag '--version' -Required $true
Assert-Equal 'present' $res.Status "git status is present"
Assert-True ($res.Version -match '\d+\.\d+') "git version contains a dotted number"

# Get-PrereqResult: missing required command
$res = Get-PrereqResult -Name 'definitely-not-real-xyz' -VersionFlag '--version' -Required $true
Assert-Equal 'missing' $res.Status "missing required command status is missing"
Assert-Equal $true $res.IsHardFailure "missing required command is hard failure"

# Get-PrereqResult: missing optional command
$res = Get-PrereqResult -Name 'definitely-not-real-xyz' -VersionFlag '--version' -Required $false
Assert-Equal 'missing' $res.Status "missing optional command status is missing"
Assert-Equal $false $res.IsHardFailure "missing optional command is not hard failure"

# Test-DockerRunning: returns either $true or $false (no exception)
$dockerOk = Test-DockerRunning
Assert-True ($dockerOk -is [bool]) "Test-DockerRunning returns bool"

# === T3: Integration tests for Get-PrereqResult result shape ===
$res = Get-PrereqResult -Name 'git' -VersionFlag '--version' -Required $true -InstallUrl 'https://example.com'
Assert-True ($res -is [hashtable]) "Get-PrereqResult returns hashtable"
foreach ($k in @('Name','Status','Version','IsHardFailure','InstallUrl','Workaround')) {
    Assert-True $res.ContainsKey($k) "Get-PrereqResult result has key: $k"
}
Assert-Equal 'git' $res.Name "Name field populated"
Assert-Equal 'https://example.com' $res.InstallUrl "InstallUrl preserved on present command"

# Workaround field preserved on present command
$resWithWa = Get-PrereqResult -Name 'git' -Required $false -Workaround 'use workaround X'
Assert-Equal 'use workaround X' $resWithWa.Workaround "Workaround preserved on present command"

# Workaround preserved on missing command
$resMissingWa = Get-PrereqResult -Name 'totally-fake-xyz-789' -Required $false -Workaround 'fallback Y'
Assert-Equal 'fallback Y' $resMissingWa.Workaround "Workaround preserved on missing command"

# IsHardFailure logic — present commands never hard-fail regardless of Required
$presentRequired = Get-PrereqResult -Name 'git' -Required $true
Assert-Equal $false $presentRequired.IsHardFailure "present + Required does not hard-fail"
$presentOptional = Get-PrereqResult -Name 'git' -Required $false
Assert-Equal $false $presentOptional.IsHardFailure "present + Optional does not hard-fail"

# === T3: Get-CommandVersion extraction patterns ===
# Real git version: should be "2.x.y" or similar
$gitVer = Get-CommandVersion -Name 'git' -VersionFlag '--version'
Assert-True ($gitVer -match '^\d+\.\d+') "git version starts with N.N"
Assert-True ($gitVer.Length -lt 50) "version string is reasonably short (no full text dump)"

# Missing command returns empty string (not error)
$missing = Get-CommandVersion -Name 'totally-not-a-real-cmd-xyz' -VersionFlag '--version'
Assert-Equal "" $missing "missing command returns empty version string"

# === T3: Test-CommandExists edge cases ===
# Empty string parameter — PowerShell will reject mandatory empty, verify a name with whitespace
# (whitespace-only command name should not match anything)
$wsResult = Test-CommandExists -Name "   "
Assert-Equal $false $wsResult "whitespace-only command name does not exist"

# Command with .exe suffix on Windows — git.exe should resolve
if ($IsWindows -or $env:OS -eq 'Windows_NT') {
    $gitExe = Test-CommandExists -Name 'git.exe'
    Assert-Equal $true $gitExe "git.exe resolves on Windows"
}

# === T3: Test-DockerRunning behavior ===
# Always returns bool, never throws
$dockerBool1 = Test-DockerRunning
$dockerBool2 = Test-DockerRunning
Assert-True ($dockerBool1 -is [bool]) "Test-DockerRunning returns bool (call 1)"
Assert-True ($dockerBool2 -is [bool]) "Test-DockerRunning returns bool (call 2)"
# Both calls should agree (state shouldn't change between them)
Assert-Equal $dockerBool1 $dockerBool2 "Test-DockerRunning is consistent between calls"

# === T3: Get-AllPrereqs pipeline ===
$all = Get-AllPrereqs
Assert-True ($all -is [array] -or $all.Count -ge 1) "Get-AllPrereqs returns array-like result"

# Required tools must be in the list
$names = $all | ForEach-Object { $_.Name }
$expectedNames = @('git','proto','rustc','node','bun','docker','supabase','psql','wrangler','flyctl','gh')
foreach ($n in $expectedNames) {
    Assert-True ($names -contains $n) "Get-AllPrereqs includes: $n"
}

# All entries have valid result-shape
foreach ($entry in $all) {
    Assert-True ($entry -is [hashtable]) "all prereq entries are hashtables"
    Assert-True $entry.ContainsKey('Status') "entry $($entry.Name) has Status key"
    Assert-True ($entry.Status -in @('present','missing','present-but-not-running')) "entry $($entry.Name) Status is a known value"
}

# git and proto are marked as required in the registry (IsHardFailure = true if missing)
$gitEntry = $all | Where-Object { $_.Name -eq 'git' } | Select-Object -First 1
$protoEntry = $all | Where-Object { $_.Name -eq 'proto' } | Select-Object -First 1
if ($gitEntry.Status -eq 'missing') {
    Assert-Equal $true $gitEntry.IsHardFailure "missing git is hard failure (required)"
}
if ($protoEntry.Status -eq 'missing') {
    Assert-Equal $true $protoEntry.IsHardFailure "missing proto is hard failure (required)"
}

# Optional tools (flyctl, gh, wrangler) are NOT hard failures even if missing
foreach ($optName in @('flyctl','gh','wrangler')) {
    $entry = $all | Where-Object { $_.Name -eq $optName } | Select-Object -First 1
    if ($entry.Status -eq 'missing') {
        Assert-Equal $false $entry.IsHardFailure "missing optional '$optName' is NOT a hard failure"
    }
}

# psql has a documented workaround
$psqlEntry = $all | Where-Object { $_.Name -eq 'psql' } | Select-Object -First 1
Assert-True ($psqlEntry.Workaround.Length -gt 0) "psql entry has a workaround documented"

# docker entry — if installed but daemon not running, status reflects that
$dockerEntry = $all | Where-Object { $_.Name -eq 'docker' } | Select-Object -First 1
if (Test-CommandExists -Name 'docker') {
    if (Test-DockerRunning) {
        Assert-Equal 'present' $dockerEntry.Status "docker installed + running → Status = present"
    } else {
        Assert-Equal 'present-but-not-running' $dockerEntry.Status "docker installed + not running → Status = present-but-not-running"
    }
}

# === T3: Determinism — calling twice gives the same result ===
$call1 = Get-AllPrereqs
$call2 = Get-AllPrereqs
Assert-Equal $call1.Count $call2.Count "Get-AllPrereqs returns same number of entries on consecutive calls"
for ($i = 0; $i -lt $call1.Count; $i++) {
    Assert-Equal $call1[$i].Name $call2[$i].Name "entry $i Name stable across calls"
    Assert-Equal $call1[$i].Status $call2[$i].Status "entry $i Status stable across calls"
}

if ($failures -eq 0) {
    Write-Host "`nAll prereq tests passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n$failures prereq test(s) failed." -ForegroundColor Red
    exit 1
}
