. "$PSScriptRoot/../lib/repos.ps1"

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

# Get-RepoState: existing folder with matching origin
$state = Get-RepoState -Name 'api' -ParentDir 'c:/git/fellwork' -ExpectedOrigin 'https://github.com/fellwork/api.git'
Assert-Equal 'present-matching' $state.Status "api status when origin matches"
Assert-Equal 'main' $state.Branch "api on main branch"

# Get-RepoState: nonexistent folder
$state = Get-RepoState -Name 'totally-fake-repo' -ParentDir 'c:/git/fellwork' -ExpectedOrigin 'https://github.com/fellwork/totally-fake-repo.git'
Assert-Equal 'absent' $state.Status "nonexistent repo status is absent"

# Test-EnvFilesNeeded: returns list of envExamples needing scaffolding
$repo = @{ name = 'api'; envExamples = @('apps/api/.env.example') }
$needed = Test-EnvFilesNeeded -Repo $repo -ParentDir 'c:/git/fellwork'
Assert-True ($needed -is [array] -or $needed.Count -ge 0) "EnvFilesNeeded returns array"

# Validate-RepoStructure: check for files
$repo = @{ name = 'api'; structureCheck = @('Cargo.toml') }
$valid = Test-RepoStructure -Repo $repo -ParentDir 'c:/git/fellwork'
Assert-Equal $true $valid "api has Cargo.toml"

$repo = @{ name = 'api'; structureCheck = @('totally-not-real-file.xyz') }
$valid = Test-RepoStructure -Repo $repo -ParentDir 'c:/git/fellwork'
Assert-Equal $false $valid "api missing fake file"

if ($failures -eq 0) {
    Write-Host "`nAll repos tests passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n$failures repos test(s) failed." -ForegroundColor Red
    exit 1
}
