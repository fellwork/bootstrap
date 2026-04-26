. "$PSScriptRoot/../lib/ui.ps1"
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

# Helper: strip ANSI escape codes for visible-width measurement
function Strip-Ansi($text) {
    return ($text -replace "`e\[[0-9;]*m", "")
}

# Helper: visible width of a single line (strip ANSI, count chars).
# Note: this is grapheme-naive — emoji/wide chars count as 1 char each, which matches
# how PowerShell .Length reports them. For terminal-cell-width specifically, this
# under-counts emoji (which are double-wide), but that's consistent with how the
# rendering code itself measures.
function Visible-Width($line) {
    return (Strip-Ansi $line).Length
}

# === T5: Tree alignment — all sibling lines at same indent share the same prefix length ===
$glyphs = Get-Glyphs -Utf8 $true

# Three sibling lines at indent 0 — all should have the same prefix length (the branch glyph)
$line1 = Format-TreeLine -Glyphs $glyphs -IsLast $false -Indent 0 -Text "first"
$line2 = Format-TreeLine -Glyphs $glyphs -IsLast $false -Indent 0 -Text "second"
$line3 = Format-TreeLine -Glyphs $glyphs -IsLast $true  -Indent 0 -Text "last"
$prefix1 = ($line1 -split " ")[0]
$prefix2 = ($line2 -split " ")[0]
$prefix3 = ($line3 -split " ")[0]
Assert-Equal $prefix1.Length $prefix2.Length "tree mid-mid: prefix lengths match"
Assert-Equal $prefix1.Length $prefix3.Length "tree mid-end: prefix lengths match"

# Indent 0 vs indent 1 — indent-1 prefix is longer
$flat = Format-TreeLine -Glyphs $glyphs -IsLast $false -Indent 0 -Text "x"
$nested = Format-TreeLine -Glyphs $glyphs -IsLast $false -Indent 1 -Text "x"
Assert-True ($nested.Length -gt $flat.Length) "indent 1 line is longer than indent 0 line"

# Indent 2 prefix is longer than indent 1
$nested2 = Format-TreeLine -Glyphs $glyphs -IsLast $false -Indent 2 -Text "x"
Assert-True ($nested2.Length -gt $nested.Length) "indent 2 line is longer than indent 1 line"

# Indent step is consistent: each level adds the same prefix increment
$delta01 = $nested.Length - $flat.Length
$delta12 = $nested2.Length - $nested.Length
Assert-Equal $delta01 $delta12 "tree indent step is uniform per level"

# === T5: Section header width — line never exceeds declared $Width by much ===
foreach ($w in @(20, 40, 60, 80, 100)) {
    $section = Format-Section -Title "Test" -Width $w -Glyphs $glyphs -Enabled $false
    $vw = Visible-Width $section
    # Section is centered — visible width should be approximately $Width (within +/- a few chars due to integer rounding)
    Assert-True ($vw -le ($w + 4)) "Format-Section width ${w}: visible width ($vw) within $w + 4 budget"
}

# === T5: Banner — title row is exactly $Width chars (PadRight pads to width) ===
foreach ($w in @(40, 60, 80)) {
    $banner = Format-Banner -Title "T" -Subtitle "S" -Width $w -Glyphs $glyphs -Enabled $false
    $lines = $banner -split "`n"
    foreach ($ln in $lines) {
        $vw = Visible-Width $ln
        # Each banner line should be exactly $Width chars (rule lines + padded title)
        Assert-Equal $w $vw "Format-Banner width ${w}: line is exactly $w chars (got $vw)"
    }
}

# === T5: Side-box — all rows have equal visible width ===
foreach ($maxW in @(20, 30, 40, 50)) {
    $sample = "a sample commentary that may need to wrap at narrow widths"
    $box = Format-SideBox -Emoji "🦊" -Text $sample -MaxWidth $maxW -Glyphs $glyphs
    $lines = $box -split "`n" | Where-Object { $_.Length -gt 0 }
    $widths = $lines | ForEach-Object { Visible-Width $_ }
    $first = $widths[0]
    $allSame = $true
    foreach ($w in $widths) {
        if ($w -ne $first) { $allSame = $false; break }
    }
    Assert-True $allSame "Format-SideBox MaxWidth ${maxW}: all rows have equal visible width"
}

# === T5: ASCII fallback — produces zero non-ASCII bytes ===
$asciiGlyphs = Get-Glyphs -Utf8 $false

# Section in ASCII mode
$asciiSection = Format-Section -Title "Test" -Width 60 -Glyphs $asciiGlyphs -Enabled $false
foreach ($ch in $asciiSection.ToCharArray()) {
    Assert-True ([int][char]$ch -lt 128) "ASCII Format-Section: char $([int][char]$ch) is ASCII"
}

# Tree line in ASCII mode
$asciiTree = Format-TreeLine -Glyphs $asciiGlyphs -IsLast $false -Indent 1 -Text "test"
foreach ($ch in $asciiTree.ToCharArray()) {
    Assert-True ([int][char]$ch -lt 128) "ASCII Format-TreeLine: char $([int][char]$ch) is ASCII"
}

# Banner in ASCII mode
$asciiBanner = Format-Banner -Title "Test" -Subtitle "1" -Width 40 -Glyphs $asciiGlyphs -Enabled $false
foreach ($ch in $asciiBanner.ToCharArray()) {
    if ($ch -eq "`n") { continue }
    Assert-True ([int][char]$ch -lt 128) "ASCII Format-Banner: char $([int][char]$ch) is ASCII"
}

# Side-box in ASCII mode (no emoji, since emoji are inherently non-ASCII)
$asciiBox = Format-SideBox -Emoji "*" -Text "test" -MaxWidth 30 -Glyphs $asciiGlyphs
foreach ($ch in $asciiBox.ToCharArray()) {
    if ($ch -eq "`n") { continue }
    Assert-True ([int][char]$ch -lt 128) "ASCII Format-SideBox: char $([int][char]$ch) is ASCII"
}

# === T5: NO_COLOR / -Enabled `$false produces zero ANSI escape sequences ===
$plainColor = Format-Color -Text "test" -Color "Green" -Enabled $false
Assert-True (-not ($plainColor -match "`e\[")) "Format-Color disabled: zero ANSI codes"

$plainRainbow = Format-RainbowText -Text "test" -Enabled $false
Assert-True (-not ($plainRainbow -match "`e\[")) "Format-RainbowText disabled: zero ANSI codes"

# === T5: Format-AnimalErrorMoment — at every width tier, no line exceeds the declared TermWidth ===
# Setup synthetic sprite for this test
$tempLayout = Join-Path $env:TEMP "bootstrap-test-layout-$(Get-Random)"
New-Item -ItemType Directory -Path "$tempLayout/animals" -Force | Out-Null
@"
# header
# header

`e[38;2;100;100;100m▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀`e[0m
`e[38;2;200;200;200m▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀`e[0m
"@ | Set-Content -Path "$tempLayout/animals/raccoon.ansi" -Encoding UTF8

# At width 120, side-by-side layout — overall row width should fit within TermWidth
$wide = Format-AnimalErrorMoment -Animal raccoon -Message "test" -FixCommand "fix" -TermWidth 120 -RootDir $tempLayout -Glyphs $glyphs -Enabled $true
$wideLines = $wide -split "`n"
foreach ($ln in $wideLines) {
    $vw = Visible-Width $ln
    Assert-True ($vw -le 120) "tier-1 (width 120): line visible width ($vw) <= 120"
}

# At width 90, tier-2 (sprite on top, speech below) — each line within 90
$mid = Format-AnimalErrorMoment -Animal raccoon -Message "test" -FixCommand "fix" -TermWidth 90 -RootDir $tempLayout -Glyphs $glyphs -Enabled $true
$midLines = $mid -split "`n"
foreach ($ln in $midLines) {
    $vw = Visible-Width $ln
    Assert-True ($vw -le 90) "tier-2 (width 90): line visible width ($vw) <= 90"
}

# At width 70, emoji-only — every line within 70
$narrow = Format-AnimalErrorMoment -Animal raccoon -Message "narrow message" -FixCommand "narrow fix" -TermWidth 70 -RootDir $tempLayout -Glyphs $glyphs -Enabled $true
$narrowLines = $narrow -split "`n"
foreach ($ln in $narrowLines) {
    $vw = Visible-Width $ln
    Assert-True ($vw -le 70) "tier-3 (width 70): line visible width ($vw) <= 70"
}

# === T5: Spinner cycle is exactly 10 frames ===
$frames = @()
for ($i = 0; $i -lt 10; $i++) {
    $frames += Get-SpinnerFrame -Index $i
}
$uniqueFrames = $frames | Select-Object -Unique
Assert-Equal 10 $uniqueFrames.Count "spinner has exactly 10 unique frames in one cycle"

# Cleanup
Remove-Item -Path $tempLayout -Recurse -Force -ErrorAction SilentlyContinue

if ($failures -eq 0) {
    Write-Host "`nAll layout-invariant tests passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n$failures layout test(s) failed." -ForegroundColor Red
    exit 1
}
