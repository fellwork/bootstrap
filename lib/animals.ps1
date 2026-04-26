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
