# Prereq detection: tool presence, version extraction, docker daemon check.

function Test-CommandExists {
    param([Parameter(Mandatory)][string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    return $null -ne $cmd
}

function Get-CommandVersion {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$VersionFlag = '--version'
    )
    if (-not (Test-CommandExists -Name $Name)) { return "" }
    try {
        $output = & $Name $VersionFlag 2>&1 | Select-Object -First 1
        # Pull out a x.y or x.y.z number
        if ($output -match '(\d+\.\d+(\.\d+)?)') {
            return $Matches[1]
        }
        return $output.ToString().Trim()
    } catch {
        return ""
    }
}

function Get-PrereqResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$VersionFlag = '--version',
        [bool]$Required = $true,
        [string]$InstallUrl = "",
        [string]$Workaround = ""
    )
    if (Test-CommandExists -Name $Name) {
        return @{
            Name           = $Name
            Status         = 'present'
            Version        = Get-CommandVersion -Name $Name -VersionFlag $VersionFlag
            IsHardFailure  = $false
            InstallUrl     = $InstallUrl
            Workaround     = $Workaround
        }
    } else {
        return @{
            Name           = $Name
            Status         = 'missing'
            Version        = ""
            IsHardFailure  = $Required
            InstallUrl     = $InstallUrl
            Workaround     = $Workaround
        }
    }
}

function Test-DockerRunning {
    if (-not (Test-CommandExists -Name 'docker')) { return $false }
    try {
        $null = & docker info 2>&1
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

function Get-AllPrereqs {
    # Returns ordered list of prereq results.
    # Bootstrap-time required: git, proto.
    # Toolchain (managed by proto, validated as installed): rust, node, bun, moon.
    # Other-prereqs validated, warn-only or required per type.
    $results = @()

    # Bootstrap-time
    $results += Get-PrereqResult -Name 'git'  -Required $true -InstallUrl 'https://git-scm.com/downloads'
    $results += Get-PrereqResult -Name 'proto' -Required $true -InstallUrl 'https://moonrepo.dev/proto'

    # Toolchain (proto installs, but we sanity-check after install)
    $results += Get-PrereqResult -Name 'rustc' -Required $false -InstallUrl 'auto-installed by proto'
    $results += Get-PrereqResult -Name 'node'  -Required $false -InstallUrl 'auto-installed by proto'
    $results += Get-PrereqResult -Name 'bun'   -Required $false -InstallUrl 'auto-installed by proto'

    # Other prereqs
    $dockerResult = Get-PrereqResult -Name 'docker' -Required $false -InstallUrl 'https://www.docker.com/products/docker-desktop'
    if ($dockerResult.Status -eq 'present' -and -not (Test-DockerRunning)) {
        $dockerResult.Status = 'present-but-not-running'
        $dockerResult.Workaround = 'Start Docker Desktop'
    }
    $results += $dockerResult

    $results += Get-PrereqResult -Name 'supabase' -Required $false -InstallUrl 'https://supabase.com/docs/guides/local-development/cli/getting-started'
    $results += Get-PrereqResult -Name 'psql'     -Required $false -InstallUrl 'https://www.postgresql.org/download/' -Workaround 'docker exec supabase_db_fellwork psql -U postgres'
    $results += Get-PrereqResult -Name 'wrangler' -Required $false -InstallUrl 'npm install -g wrangler'
    $results += Get-PrereqResult -Name 'flyctl'   -Required $false -InstallUrl 'https://fly.io/docs/hands-on/install-flyctl/'
    $results += Get-PrereqResult -Name 'gh'       -Required $false -InstallUrl 'https://cli.github.com/'

    return $results
}
