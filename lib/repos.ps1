# Repo operations: state detection, clone, validate, env scaffold.
# All operations are read-only by default; mutating ones explicitly named (Invoke-*).

function Get-RepoState {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ParentDir,
        [Parameter(Mandatory)][string]$ExpectedOrigin
    )
    $path = Join-Path $ParentDir $Name
    if (-not (Test-Path $path)) {
        return @{ Status = 'absent'; Path = $path; Origin = ""; Branch = "" }
    }
    if (-not (Test-Path (Join-Path $path '.git'))) {
        return @{ Status = 'present-not-git'; Path = $path; Origin = ""; Branch = "" }
    }
    $origin = ""
    $branch = ""
    try {
        Push-Location $path
        $origin = (& git remote get-url origin 2>$null).Trim()
        $branch = (& git branch --show-current 2>$null).Trim()
    } catch {} finally {
        Pop-Location
    }
    $status = if ($origin -eq $ExpectedOrigin) { 'present-matching' } else { 'present-mismatch' }
    return @{ Status = $status; Path = $path; Origin = $origin; Branch = $branch }
}

function Invoke-RepoClone {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Org,
        [Parameter(Mandatory)][string]$ParentDir
    )
    $url = "https://github.com/$Org/$Name.git"
    $path = Join-Path $ParentDir $Name
    Push-Location $ParentDir
    try {
        $output = & git clone $url $Name 2>&1 | Out-String
        $exit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    return @{
        Success = ($exit -eq 0)
        Path    = $path
        ExitCode = $exit
    }
}

function Test-EnvFilesNeeded {
    param(
        [Parameter(Mandatory)][hashtable]$Repo,
        [Parameter(Mandatory)][string]$ParentDir
    )
    $needed = [System.Collections.Generic.List[object]]::new()
    if (-not $Repo.envExamples) { return , @($needed) }
    $repoPath = Join-Path $ParentDir $Repo.name
    foreach ($examplePath in $Repo.envExamples) {
        $examplFull = Join-Path $repoPath $examplePath
        $envFull = $examplFull -replace '\.env\.example$', '.env'
        if ((Test-Path $examplFull) -and -not (Test-Path $envFull)) {
            $needed.Add(@{
                Example = $examplFull
                Target  = $envFull
            })
        }
    }
    return , @($needed)
}

function Invoke-EnvScaffold {
    param(
        [Parameter(Mandatory)][hashtable]$EnvFile
    )
    Copy-Item -Path $EnvFile.Example -Destination $EnvFile.Target -ErrorAction Stop
}

function Test-RepoStructure {
    param(
        [Parameter(Mandatory)][hashtable]$Repo,
        [Parameter(Mandatory)][string]$ParentDir
    )
    $repoPath = Join-Path $ParentDir $Repo.name
    if (-not $Repo.structureCheck -or $Repo.structureCheck.Count -eq 0) { return $true }
    foreach ($file in $Repo.structureCheck) {
        if (-not (Test-Path (Join-Path $repoPath $file))) { return $false }
    }
    return $true
}

function Invoke-ProtoInstall {
    param(
        [Parameter(Mandatory)][string]$RepoPath
    )
    if (-not (Test-Path (Join-Path $RepoPath '.prototools'))) {
        return @{ Success = $true; Skipped = $true; Reason = 'no .prototools' }
    }
    Push-Location $RepoPath
    try {
        $output = & proto install 2>&1 | Out-String
        $exit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    return @{
        Success = ($exit -eq 0)
        Skipped = $false
        Output  = $output
        ExitCode = $exit
    }
}
