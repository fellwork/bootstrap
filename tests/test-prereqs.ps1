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

if ($failures -eq 0) {
    Write-Host "`nAll prereq tests passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n$failures prereq test(s) failed." -ForegroundColor Red
    exit 1
}
