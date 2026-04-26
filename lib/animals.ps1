# Animal registry: emoji, canned phrases, error-category mapping.
# Six "sprite" animals also have ASCII art (loaded separately from animals/*.ansi).
# Two emoji-only animals (bee, otter) appear in side-boxes only.

$script:Registry = @{
    fox = @{
        Emoji = "🦊"
        IsSprite = $true
        ErrorCategory = 'clever-fix'
        Phrases = @{
            'repo-note' = @(
                "this one's the rust monorepo — biggest clone",
                "30+ workspace crates live here",
                "GraphQL + REST under one roof"
            )
            'clever-fix' = @(
                "there's a one-line fix for this",
                "easy one — try the command above",
                "I've seen this before, the fix below works"
            )
        }
    }
    owl = @{
        Emoji = "🦉"
        IsSprite = $true
        ErrorCategory = 'should-know'
        Phrases = @{
            'pro-tip' = @(
                "rerun ./bootstrap.ps1 — it's safe to run repeatedly",
                "you can pass --no-color if you're piping output",
                "each repo's .prototools owns its versions; bootstrap just orchestrates"
            )
            'should-know' = @(
                "version mismatch worth knowing about",
                "deprecated — but still works for now",
                "heads up — this changed recently"
            )
        }
    }
    turtle = @{
        Emoji = "🐢"
        IsSprite = $true
        ErrorCategory = 'optional'
        Phrases = @{
            'no-rush' = @(
                "no rush — only needed for migrations & seeding",
                "optional — install when you actually need it",
                "deploy-only; skip if you're just developing"
            )
        }
    }
    octopus = @{
        Emoji = "🐙"
        IsSprite = $true
        ErrorCategory = 'dependency-tangle'
        Phrases = @{
            'tangle' = @(
                "this one blocks several others — install it first",
                "fix this and three other warnings probably go away"
            )
        }
    }
    hedgehog = @{
        Emoji = "🦔"
        IsSprite = $true
        ErrorCategory = 'security'
        Phrases = @{
            'security' = @(
                "don't commit this .env — it's gitignored for a reason",
                "fill in real secrets before running anything that talks to prod"
            )
        }
    }
    raccoon = @{
        Emoji = "🦝"
        IsSprite = $true
        ErrorCategory = 'config-mismatch'
        Phrases = @{
            'leftover' = @(
                "found leftover state — taking a look",
                "something's already here; not touching it"
            )
            'config-mismatch' = @(
                "this isn't pointing where I expected",
                "configuration drift — see the fix below"
            )
        }
    }
    bee = @{
        Emoji = "🐝"
        IsSprite = $false
        ErrorCategory = $null
        Phrases = @{
            'busy' = @(
                "this might take a minute",
                "fetching things in the background"
            )
        }
    }
    otter = @{
        Emoji = "🦦"
        IsSprite = $false
        ErrorCategory = $null
        Phrases = @{
            'celebrate' = @(
                "everything's swimming!",
                "all systems go.",
                "ready to build."
            )
        }
    }
}

function Get-AnimalRegistry {
    return $script:Registry
}

function Get-SpriteAnimals {
    return @($script:Registry.Keys | Where-Object { $script:Registry[$_].IsSprite })
}

function Get-AnimalPhrase {
    param(
        [Parameter(Mandatory)][string]$Animal,
        [Parameter(Mandatory)][string]$Situation
    )
    if (-not $script:Registry.ContainsKey($Animal)) { return "" }
    $phrases = $script:Registry[$Animal].Phrases[$Situation]
    if (-not $phrases -or $phrases.Count -eq 0) { return "" }
    return $phrases | Get-Random
}

function Get-AnimalForErrorCategory {
    param([Parameter(Mandatory)][string]$Category)
    foreach ($name in $script:Registry.Keys) {
        if ($script:Registry[$name].ErrorCategory -eq $Category) {
            return $name
        }
    }
    return 'raccoon'  # fallback
}

function Read-AnimalSprite {
    param(
        [Parameter(Mandatory)][string]$Animal,
        [Parameter(Mandatory)][string]$RootDir
    )
    $path = Join-Path $RootDir "animals/$Animal.ansi"
    if (-not (Test-Path $path)) { return "" }
    $lines = Get-Content -Path $path -Encoding UTF8
    # Strip leading header comments
    $stripped = @()
    $headerDone = $false
    foreach ($line in $lines) {
        if (-not $headerDone -and $line -match "^\s*#") { continue }
        if (-not $headerDone -and $line.Trim() -eq "") { continue }
        $headerDone = $true
        $stripped += $line
    }
    return ($stripped -join "`n")
}

function Get-SpriteWidth {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Sprite)
    if ([string]::IsNullOrEmpty($Sprite)) { return 0 }
    $lines = $Sprite -split "`n"
    $maxWidth = 0
    foreach ($line in $lines) {
        # Strip ANSI escape codes for width measurement
        $stripped = $line -replace "`e\[[0-9;]*m", ""
        if ($stripped.Length -gt $maxWidth) { $maxWidth = $stripped.Length }
    }
    return $maxWidth
}

function Format-AnimalErrorMoment {
    # Renders the full ASCII art + speech-box failure presentation.
    # Width-aware: full art + side speech (>=100), art + below speech (80-99), emoji only (<80).
    param(
        [Parameter(Mandatory)][string]$Animal,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$FixCommand,
        [Parameter(Mandatory)][int]$TermWidth,
        [Parameter(Mandatory)][string]$RootDir,
        [hashtable]$Glyphs,
        [bool]$Enabled = $true
    )
    if (-not $Glyphs) { $Glyphs = Get-Glyphs -Utf8 $true }
    $emoji = $script:Registry[$Animal].Emoji
    $sprite = Read-AnimalSprite -Animal $Animal -RootDir $RootDir
    $spriteWidth = Get-SpriteWidth -Sprite $sprite

    # Speech-box content
    $speechLines = @()
    $speechLines += $Message
    $speechLines += ""
    $speechLines += "  $FixCommand"
    $speechLines += ""
    $speechLines += "Then rerun ./bootstrap.ps1 — I'll pick up where I left off."

    # Render the speech as a side-box-style frame (wider than commentary side-boxes)
    $speechBoxWidth = [Math]::Min(50, $TermWidth - $spriteWidth - 4)
    if ($speechBoxWidth -lt 20) { $speechBoxWidth = 20 }
    $boxTop    = $Glyphs.BoxTL + ($Glyphs.BoxH * ($speechBoxWidth - 2)) + $Glyphs.BoxTR
    $boxBottom = $Glyphs.BoxBL + ($Glyphs.BoxH * ($speechBoxWidth - 2)) + $Glyphs.BoxBR

    $speechBox = @()
    $speechBox += $boxTop
    foreach ($line in $speechLines) {
        $padded = $line.PadRight($speechBoxWidth - 4)
        $speechBox += "$($Glyphs.BoxV) $padded $($Glyphs.BoxV)"
    }
    $speechBox += $boxBottom
    $speechBox += "                                                       — $emoji"

    if ($TermWidth -lt 80 -or [string]::IsNullOrEmpty($sprite)) {
        # Emoji-only fallback
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine("$emoji  $Message")
        [void]$sb.AppendLine("    $FixCommand")
        [void]$sb.AppendLine("    Then rerun ./bootstrap.ps1.")
        return $sb.ToString()
    } elseif ($TermWidth -lt 100) {
        # Art on top, speech below
        return "$sprite`n`n" + ($speechBox -join "`n")
    } else {
        # Side-by-side: art on left, speech on right
        $spriteLines = $sprite -split "`n"
        $sb = [System.Text.StringBuilder]::new()
        $maxRows = [Math]::Max($spriteLines.Count, $speechBox.Count)
        for ($i = 0; $i -lt $maxRows; $i++) {
            $left  = if ($i -lt $spriteLines.Count) { $spriteLines[$i] } else { "" }
            $right = if ($i -lt $speechBox.Count)   { $speechBox[$i] }   else { "" }
            $strippedLeft = $left -replace "`e\[[0-9;]*m", ""
            $padding = " " * ($spriteWidth - $strippedLeft.Length + 4)
            [void]$sb.AppendLine("$left$padding$right")
        }
        return $sb.ToString()
    }
}
