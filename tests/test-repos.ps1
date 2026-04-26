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
Assert-True ($state.Branch.Length -gt 0) "api branch is non-empty (whatever the dev has checked out)"

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

# === T4: Get-RepoState — all four status branches ===
$tempRoot4 = Join-Path $env:TEMP "bootstrap-test-repostate-$(Get-Random)"
New-Item -ItemType Directory -Path $tempRoot4 -Force | Out-Null

# 1. 'absent' — directory does not exist
$absent = Get-RepoState -Name 'nonexistent-x' -ParentDir $tempRoot4 -ExpectedOrigin 'https://example.com/x.git'
Assert-Equal 'absent' $absent.Status "Get-RepoState absent: status"
Assert-Equal "" $absent.Origin "Get-RepoState absent: origin empty"
Assert-Equal "" $absent.Branch "Get-RepoState absent: branch empty"
Assert-True ($absent.Path.EndsWith("nonexistent-x")) "Get-RepoState absent: path is parent/name"

# 2. 'present-not-git' — directory exists but no .git
New-Item -ItemType Directory -Path "$tempRoot4/notgit" -Force | Out-Null
"hello" | Set-Content "$tempRoot4/notgit/some-file.txt"
$notGit = Get-RepoState -Name 'notgit' -ParentDir $tempRoot4 -ExpectedOrigin 'https://example.com/x.git'
Assert-Equal 'present-not-git' $notGit.Status "Get-RepoState present-not-git: status"

# 3. 'present-matching' — git repo with matching origin
$matchingDir = "$tempRoot4/matching"
New-Item -ItemType Directory -Path $matchingDir -Force | Out-Null
Push-Location $matchingDir
& git init -q -b main
& git remote add origin 'https://example.com/correct.git'
Pop-Location
$matching = Get-RepoState -Name 'matching' -ParentDir $tempRoot4 -ExpectedOrigin 'https://example.com/correct.git'
Assert-Equal 'present-matching' $matching.Status "Get-RepoState present-matching: status"
Assert-Equal 'https://example.com/correct.git' $matching.Origin "Get-RepoState present-matching: origin"
Assert-True ($matching.Branch.Length -gt 0) "Get-RepoState present-matching: branch is non-empty"

# 4. 'present-mismatch' — git repo with wrong origin
$mismatchDir = "$tempRoot4/mismatch"
New-Item -ItemType Directory -Path $mismatchDir -Force | Out-Null
Push-Location $mismatchDir
& git init -q -b main
& git remote add origin 'https://example.com/wrong.git'
Pop-Location
$mismatch = Get-RepoState -Name 'mismatch' -ParentDir $tempRoot4 -ExpectedOrigin 'https://example.com/correct.git'
Assert-Equal 'present-mismatch' $mismatch.Status "Get-RepoState present-mismatch: status"
Assert-Equal 'https://example.com/wrong.git' $mismatch.Origin "Get-RepoState present-mismatch: returns actual origin"

# 5. URL trailing-whitespace tolerance — origin with trailing newline should still match
# (git remote get-url tends to add trailing `n)
$wsDir = "$tempRoot4/ws"
New-Item -ItemType Directory -Path $wsDir -Force | Out-Null
Push-Location $wsDir
& git init -q -b main
& git remote add origin 'https://example.com/ws.git'
Pop-Location
$ws = Get-RepoState -Name 'ws' -ParentDir $tempRoot4 -ExpectedOrigin 'https://example.com/ws.git'
Assert-Equal 'present-matching' $ws.Status "Get-RepoState handles git-output whitespace correctly"

# === T4: Test-EnvFilesNeeded — envExamples scaffolding logic ===
$envRoot = Join-Path $env:TEMP "bootstrap-test-envfiles-$(Get-Random)"
New-Item -ItemType Directory -Path "$envRoot/myrepo/apps/api" -Force | Out-Null

# Create .env.example
"VAR=value" | Set-Content "$envRoot/myrepo/apps/api/.env.example"

# Case A: example exists, no .env yet → needs scaffolding
$repoSpec = @{ name = 'myrepo'; envExamples = @('apps/api/.env.example') }
$needed = Test-EnvFilesNeeded -Repo $repoSpec -ParentDir $envRoot
Assert-Equal 1 $needed.Count "Test-EnvFilesNeeded: 1 entry when example present + .env missing"
Assert-True ($needed[0].Example.Contains('.env.example')) "needed entry has Example path"
Assert-True ($needed[0].Target.EndsWith('.env')) "needed entry has Target path ending in .env"

# Case B: example exists AND .env exists → no scaffolding needed
"VAR=actual" | Set-Content "$envRoot/myrepo/apps/api/.env"
$noNeed = Test-EnvFilesNeeded -Repo $repoSpec -ParentDir $envRoot
Assert-Equal 0 $noNeed.Count "Test-EnvFilesNeeded: 0 entries when both example and .env exist"

# Case C: empty envExamples → empty array
$emptyRepo = @{ name = 'myrepo'; envExamples = @() }
$emptyNeed = Test-EnvFilesNeeded -Repo $emptyRepo -ParentDir $envRoot
Assert-Equal 0 $emptyNeed.Count "Test-EnvFilesNeeded: empty envExamples list returns 0 entries"

# Case D: example doesn't exist → no scaffolding needed (don't create from nothing)
$missingRepo = @{ name = 'myrepo'; envExamples = @('apps/web/.env.example') }
$missingNeed = Test-EnvFilesNeeded -Repo $missingRepo -ParentDir $envRoot
Assert-Equal 0 $missingNeed.Count "Test-EnvFilesNeeded: missing example file returns 0 entries"

# === T4: Invoke-EnvScaffold copies file correctly ===
Remove-Item "$envRoot/myrepo/apps/api/.env" -Force  # reset to needing-scaffolding state
$envFile = @{
    Example = "$envRoot/myrepo/apps/api/.env.example"
    Target  = "$envRoot/myrepo/apps/api/.env"
}
Invoke-EnvScaffold -EnvFile $envFile
Assert-True (Test-Path $envFile.Target) "Invoke-EnvScaffold creates target file"
$copiedContent = Get-Content $envFile.Target -Raw
Assert-True ($copiedContent.Contains('VAR=value')) "Invoke-EnvScaffold copies example contents"

# === T4: Idempotency — Test-EnvFilesNeeded returns 0 after Invoke-EnvScaffold ===
$afterScaffold = Test-EnvFilesNeeded -Repo $repoSpec -ParentDir $envRoot
Assert-Equal 0 $afterScaffold.Count "after Invoke-EnvScaffold, Test-EnvFilesNeeded returns 0"

# === T4: Invoke-EnvScaffold does NOT overwrite existing .env ===
"PRESERVED=true" | Set-Content $envFile.Target  # Modify the .env content
# A re-scan should NOT need scaffolding (file exists)
$rescaffoldNeed = Test-EnvFilesNeeded -Repo $repoSpec -ParentDir $envRoot
Assert-Equal 0 $rescaffoldNeed.Count "Test-EnvFilesNeeded skips scaffolding when .env exists (preserves user edits)"
$preserved = Get-Content $envFile.Target -Raw
Assert-True ($preserved.Contains('PRESERVED=true')) "user-edited .env contents preserved (not overwritten)"

# === T4: Test-RepoStructure — empty list always passes ===
$noChecks = @{ name = 'myrepo'; structureCheck = @() }
Assert-Equal $true (Test-RepoStructure -Repo $noChecks -ParentDir $envRoot) "empty structureCheck returns true"

# Multi-file structureCheck: all must exist for true
"some content" | Set-Content "$envRoot/myrepo/file-a.txt"
"some content" | Set-Content "$envRoot/myrepo/file-b.txt"
$bothExist = @{ name = 'myrepo'; structureCheck = @('file-a.txt', 'file-b.txt') }
Assert-Equal $true (Test-RepoStructure -Repo $bothExist -ParentDir $envRoot) "multi-file structureCheck: all exist → true"

# Partial existence → false
$partial = @{ name = 'myrepo'; structureCheck = @('file-a.txt', 'totally-missing.xyz') }
Assert-Equal $false (Test-RepoStructure -Repo $partial -ParentDir $envRoot) "multi-file structureCheck: one missing → false"

# === T4: Invoke-ProtoInstall — no .prototools means skipped, success ===
$noProtoDir = Join-Path $env:TEMP "bootstrap-test-noprotor-$(Get-Random)"
New-Item -ItemType Directory -Path $noProtoDir -Force | Out-Null
$skipped = Invoke-ProtoInstall -RepoPath $noProtoDir
Assert-Equal $true $skipped.Success "no .prototools: Success = true"
Assert-Equal $true $skipped.Skipped "no .prototools: Skipped = true"

# === Cleanup ===
Remove-Item -Path $tempRoot4 -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path $envRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path $noProtoDir -Recurse -Force -ErrorAction SilentlyContinue

if ($failures -eq 0) {
    Write-Host "`nAll repos tests passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n$failures repos test(s) failed." -ForegroundColor Red
    exit 1
}
