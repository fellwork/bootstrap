. "$PSScriptRoot/../lib/animals.ps1"

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

# Registry has all 8 animals
$reg = Get-AnimalRegistry
Assert-True $reg.ContainsKey('fox')      "registry has fox"
Assert-True $reg.ContainsKey('owl')      "registry has owl"
Assert-True $reg.ContainsKey('turtle')   "registry has turtle"
Assert-True $reg.ContainsKey('octopus')  "registry has octopus"
Assert-True $reg.ContainsKey('hedgehog') "registry has hedgehog"
Assert-True $reg.ContainsKey('raccoon')  "registry has raccoon"
Assert-True $reg.ContainsKey('bee')      "registry has bee"
Assert-True $reg.ContainsKey('otter')    "registry has otter"

# Each animal has emoji + at least one phrase per situation it owns
foreach ($name in $reg.Keys) {
    Assert-True ($reg[$name].Emoji.Length -gt 0) "$name has emoji"
    Assert-True ($reg[$name].Phrases.Count -gt 0) "$name has phrases"
}

# Sprite animals are tagged
$sprites = Get-SpriteAnimals
Assert-Equal 6 $sprites.Count "exactly 6 sprite animals"
Assert-True ($sprites -contains 'raccoon') "sprite list includes raccoon"
Assert-True ($sprites -notcontains 'bee') "sprite list excludes bee"

# Get a random phrase
$phrase = Get-AnimalPhrase -Animal 'fox' -Situation 'repo-note'
Assert-True ($phrase.Length -gt 0) "fox returns a phrase"

# Error category mapping
$animal = Get-AnimalForErrorCategory -Category 'config-mismatch'
Assert-Equal 'raccoon' $animal "config-mismatch maps to raccoon"

$animal = Get-AnimalForErrorCategory -Category 'security'
Assert-Equal 'hedgehog' $animal "security maps to hedgehog"


# Sprite loading — write a synthetic sprite to a temp dir so the test doesn't
# depend on real PNGs being generated yet.
$tempRoot = Join-Path $env:TEMP "bootstrap-test-$(Get-Random)"
New-Item -ItemType Directory -Path "$tempRoot/animals" -Force | Out-Null
$spriteContent = @"
# Stardew-style raccoon sprite — tier-3 half-block ANSI.
# Test fixture
# Generated: 2026-04-26

`e[38;2;100;100;100m▀▀▀`e[0m
`e[38;2;200;200;200m▀▀▀`e[0m
"@
Set-Content -Path "$tempRoot/animals/raccoon.ansi" -Value $spriteContent -Encoding UTF8

$sprite = Read-AnimalSprite -Animal 'raccoon' -RootDir $tempRoot
Assert-True ($sprite.Length -gt 10) "raccoon sprite has content"
Assert-True (-not ($sprite -match "^#")) "sprite content has header stripped"

# Sprite width detection
$width = Get-SpriteWidth -Sprite $sprite
Assert-True ($width -ge 3) "sprite width is at least 3 cells"

# Failure for missing sprite
$missing = Read-AnimalSprite -Animal 'nonexistent' -RootDir $tempRoot
Assert-Equal "" $missing "missing sprite returns empty string"

# Cleanup
Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue


# === T2: Width-tier boundary tests for Format-AnimalErrorMoment ===
# The 3-tier fallback boundaries (80 and 100) are deliberate design decisions.
# Tests below LOCK IN these exact boundaries — if you change them, tests break
# and you must update both code and tests intentionally.

# Setup: create a synthetic sprite in a temp location so width-tier tests don't
# depend on the real animals/*.ansi being generated (some envs may not have them).
$tempRootW = Join-Path $env:TEMP "bootstrap-test-widthtiers-$(Get-Random)"
New-Item -ItemType Directory -Path "$tempRootW/animals" -Force | Out-Null
$syntheticSprite = @"
# Test fixture sprite
# (header)

`e[38;2;100;100;100m▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀`e[0m
`e[38;2;200;200;200m▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀`e[0m
`e[38;2;100;200;100m▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀`e[0m
"@
foreach ($name in @('raccoon','hedgehog','octopus','owl','fox','turtle')) {
    Set-Content -Path "$tempRootW/animals/$name.ansi" -Value $syntheticSprite -Encoding UTF8
}

# Source ui.ps1 because Format-AnimalErrorMoment depends on Get-Glyphs
. "$PSScriptRoot/../lib/ui.ps1"
$gtest = Get-Glyphs -Utf8 $true

# --- Tier 1: Width >= 100 → side-by-side (sprite + speech) ---
$wide = Format-AnimalErrorMoment -Animal raccoon -Message "test" -FixCommand "fix" -TermWidth 120 -RootDir $tempRootW -Glyphs $gtest -Enabled $true
Assert-True ($wide.Contains("▀")) "Width 120: includes sprite half-blocks"
Assert-True ($wide.Contains($gtest.BoxTL)) "Width 120: includes speech-box top-left corner"
Assert-True ($wide.Contains("test")) "Width 120: includes message"
Assert-True ($wide.Contains("fix")) "Width 120: includes fix command"

# At width 100 (boundary): also side-by-side
$boundary100 = Format-AnimalErrorMoment -Animal raccoon -Message "boundary100" -FixCommand "fx" -TermWidth 100 -RootDir $tempRootW -Glyphs $gtest -Enabled $true
Assert-True ($boundary100.Contains("▀")) "Width 100 (boundary): includes sprite (side-by-side)"
Assert-True ($boundary100.Contains($gtest.BoxTL)) "Width 100 (boundary): includes box"

# --- Tier 2: 80 <= Width < 100 → sprite on top, speech below ---
$mid = Format-AnimalErrorMoment -Animal raccoon -Message "midtest" -FixCommand "midfix" -TermWidth 90 -RootDir $tempRootW -Glyphs $gtest -Enabled $true
Assert-True ($mid.Contains("▀")) "Width 90: includes sprite"
Assert-True ($mid.Contains($gtest.BoxTL)) "Width 90: includes box"
# Tier 2 layout: sprite block appears BEFORE box characters in the string
$spritePos90 = $mid.IndexOf("▀")
$boxPos90 = $mid.IndexOf($gtest.BoxTL)
Assert-True ($spritePos90 -lt $boxPos90) "Width 90: sprite appears before box (top-then-below layout)"

# At width 80 (boundary): also tier-2 (sprite + below)
$boundary80 = Format-AnimalErrorMoment -Animal raccoon -Message "b80" -FixCommand "f" -TermWidth 80 -RootDir $tempRootW -Glyphs $gtest -Enabled $true
Assert-True ($boundary80.Contains("▀")) "Width 80 (boundary): includes sprite (tier-2)"
Assert-True ($boundary80.Contains($gtest.BoxTL)) "Width 80 (boundary): includes box"

# At width 99 (just below tier-1): still tier-2
$justBelow100 = Format-AnimalErrorMoment -Animal raccoon -Message "b99" -FixCommand "f" -TermWidth 99 -RootDir $tempRootW -Glyphs $gtest -Enabled $true
$spritePos99 = $justBelow100.IndexOf("▀")
$boxPos99 = $justBelow100.IndexOf($gtest.BoxTL)
Assert-True ($spritePos99 -lt $boxPos99) "Width 99 (just below tier-1): sprite appears before box (tier-2 layout)"

# --- Tier 3: Width < 80 → emoji-only fallback (no sprite, no box) ---
$narrow = Format-AnimalErrorMoment -Animal raccoon -Message "narrowmsg" -FixCommand "narrowfix" -TermWidth 70 -RootDir $tempRootW -Glyphs $gtest -Enabled $true
Assert-True (-not $narrow.Contains("▀")) "Width 70: no sprite (emoji-only)"
Assert-True (-not $narrow.Contains($gtest.BoxTL)) "Width 70: no box (emoji-only)"
Assert-True ($narrow.Contains("🦝")) "Width 70: includes raccoon emoji"
Assert-True ($narrow.Contains("narrowmsg")) "Width 70: includes message"
Assert-True ($narrow.Contains("narrowfix")) "Width 70: includes fix command"

# At width 79 (just below tier-2): also emoji-only
$justBelow80 = Format-AnimalErrorMoment -Animal raccoon -Message "b79" -FixCommand "f" -TermWidth 79 -RootDir $tempRootW -Glyphs $gtest -Enabled $true
Assert-True (-not $justBelow80.Contains("▀")) "Width 79 (just below tier-2): emoji-only (no sprite)"

# --- Sprite-missing path: any width with missing sprite → emoji-only ---
$wideButNoSprite = Format-AnimalErrorMoment -Animal raccoon -Message "noart" -FixCommand "f" -TermWidth 120 -RootDir "/nonexistent-dir" -Glyphs $gtest -Enabled $true
Assert-True (-not $wideButNoSprite.Contains("▀")) "Width 120 + missing sprite: no sprite chars"
Assert-True ($wideButNoSprite.Contains("🦝")) "Width 120 + missing sprite: emoji used"

# --- Each animal renders correct emoji ---
$animalEmojis = @{
    raccoon  = "🦝"
    hedgehog = "🦔"
    octopus  = "🐙"
    owl      = "🦉"
    fox      = "🦊"
    turtle   = "🐢"
}
foreach ($a in $animalEmojis.Keys) {
    $out = Format-AnimalErrorMoment -Animal $a -Message "msg" -FixCommand "fix" -TermWidth 70 -RootDir "/none" -Glyphs $gtest -Enabled $true
    Assert-True ($out.Contains($animalEmojis[$a])) "$a renders correct emoji"
}

# --- Long message wraps inside speech-box (tier-1) ---
$longMessage = "This is a long error message that should still render inside the speech-box without breaking layout"
$longOut = Format-AnimalErrorMoment -Animal raccoon -Message $longMessage -FixCommand "fix" -TermWidth 120 -RootDir $tempRootW -Glyphs $gtest -Enabled $true
Assert-True ($longOut.Contains("long")) "Long message: 'long' present in output"
Assert-True ($longOut.Contains("layout")) "Long message: 'layout' present in output"

# === T2: Read-AnimalSprite edge cases ===
# Header-only file (no actual sprite content) returns empty after stripping
$tempRoot2 = Join-Path $env:TEMP "bootstrap-test-headeronly-$(Get-Random)"
New-Item -ItemType Directory -Path "$tempRoot2/animals" -Force | Out-Null
@"
# Just headers
# Nothing else
"@ | Set-Content -Path "$tempRoot2/animals/raccoon.ansi" -Encoding UTF8
$headerOnly = Read-AnimalSprite -Animal 'raccoon' -RootDir $tempRoot2
Assert-Equal "" $headerOnly "header-only sprite returns empty string"

# File with content after header strips header correctly
@"
# Header line
# Another header
# Generated: today

real content line 1
real content line 2
"@ | Set-Content -Path "$tempRoot2/animals/raccoon.ansi" -Encoding UTF8
$content = Read-AnimalSprite -Animal 'raccoon' -RootDir $tempRoot2
Assert-True ($content.Contains("real content line 1")) "sprite content preserved after header strip"
Assert-True (-not $content.Contains("Header line")) "header lines fully stripped"

# === T2: Get-SpriteWidth edge cases ===
$emptySprite = Get-SpriteWidth -Sprite ""
Assert-Equal 0 $emptySprite "empty sprite has width 0"

# Single-line sprite
$single = Get-SpriteWidth -Sprite "abcdefgh"
Assert-Equal 8 $single "single-line sprite width is line length"

# ANSI codes are stripped before measurement
$withAnsi = "`e[38;2;100;100;100mabc`e[0m"
$ansiWidth = Get-SpriteWidth -Sprite $withAnsi
Assert-Equal 3 $ansiWidth "ANSI codes stripped before width measurement"

# Multi-line sprite returns max line width
$multi = "abc`nabcdefg`nab"
$multiWidth = Get-SpriteWidth -Sprite $multi
Assert-Equal 7 $multiWidth "multi-line sprite returns max line width"

# === T2: Get-AnimalPhrase edge cases ===
# Unknown animal returns empty
$unknown = Get-AnimalPhrase -Animal "unicorn" -Situation "any"
Assert-Equal "" $unknown "unknown animal returns empty phrase"

# Animal exists but situation doesn't
$badSituation = Get-AnimalPhrase -Animal "fox" -Situation "nonexistent-situation"
Assert-Equal "" $badSituation "fox + bad situation returns empty"

# Valid combos return non-empty
$goodFox = Get-AnimalPhrase -Animal "fox" -Situation "repo-note"
Assert-True ($goodFox.Length -gt 0) "fox/repo-note returns non-empty phrase"

# === T2: Get-AnimalForErrorCategory edge cases ===
# Unknown category returns raccoon (fallback per design)
$fallback = Get-AnimalForErrorCategory -Category "totally-not-a-category"
Assert-Equal 'raccoon' $fallback "unknown error category falls back to raccoon"

# Each known category maps to expected animal
Assert-Equal 'fox'      (Get-AnimalForErrorCategory -Category 'clever-fix')      "clever-fix → fox"
Assert-Equal 'owl'      (Get-AnimalForErrorCategory -Category 'should-know')    "should-know → owl"
Assert-Equal 'turtle'   (Get-AnimalForErrorCategory -Category 'optional')       "optional → turtle"
Assert-Equal 'octopus'  (Get-AnimalForErrorCategory -Category 'dependency-tangle') "dependency-tangle → octopus"
Assert-Equal 'hedgehog' (Get-AnimalForErrorCategory -Category 'security')       "security → hedgehog"
Assert-Equal 'raccoon'  (Get-AnimalForErrorCategory -Category 'config-mismatch') "config-mismatch → raccoon"

# Cleanup temp dirs
Remove-Item -Path $tempRootW -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path $tempRoot2 -Recurse -Force -ErrorAction SilentlyContinue

if ($failures -eq 0) {
    Write-Host "`nAll animal tests passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n$failures animal test(s) failed." -ForegroundColor Red
    exit 1
}
