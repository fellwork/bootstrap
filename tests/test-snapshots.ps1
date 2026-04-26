. "$PSScriptRoot/../lib/ui.ps1"
. "$PSScriptRoot/../lib/animals.ps1"

$failures = 0
$snapshotDir = "$PSScriptRoot/snapshots"

function Normalize-Snapshot([string]$text) {
    # Convert CRLF -> LF, strip trailing whitespace per line, ensure single trailing newline
    $text = $text -replace "`r`n", "`n"
    $lines = $text -split "`n" | ForEach-Object { $_.TrimEnd() }
    return ($lines -join "`n").TrimEnd() + "`n"
}

function Compare-Snapshot {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Actual
    )
    $goldenPath = Join-Path $snapshotDir "$Name.txt"
    if (-not (Test-Path $goldenPath)) {
        Write-Host "FAIL: $Name -- no golden file at $goldenPath" -ForegroundColor Red
        Write-Host "  Got:`n$Actual" -ForegroundColor Yellow
        $script:failures++
        return
    }
    $expected = Normalize-Snapshot (Get-Content -Path $goldenPath -Raw -Encoding UTF8)
    $normalizedActual = Normalize-Snapshot $Actual
    if ($expected -eq $normalizedActual) {
        Write-Host "PASS: $Name" -ForegroundColor Green
    } else {
        Write-Host "FAIL: $Name -- snapshot mismatch" -ForegroundColor Red
        Write-Host "--- Expected ---" -ForegroundColor Cyan
        Write-Host $expected
        Write-Host "--- Actual ---" -ForegroundColor Cyan
        Write-Host $normalizedActual
        $script:failures++
    }
}

# Use a fixed glyph set for reproducibility
$glyphs = Get-Glyphs -Utf8 $true
$glyphsAscii = Get-Glyphs -Utf8 $false

# === Snapshot: Format-Section, default width ===
$section = Format-Section -Title "Cloning repositories" -Width 60 -Glyphs $glyphs -Enabled $false
Compare-Snapshot -Name "section-utf8-default" -Actual $section

# === Snapshot: Format-Section, ASCII mode ===
$sectionAscii = Format-Section -Title "Cloning repositories" -Width 60 -Glyphs $glyphsAscii -Enabled $false
Compare-Snapshot -Name "section-ascii-default" -Actual $sectionAscii

# === Snapshot: Format-Banner, with subtitle, color disabled ===
$banner = Format-Banner -Title "Fellwork Bootstrap" -Subtitle "12:34:56" -Width 60 -Glyphs $glyphs -Enabled $false
Compare-Snapshot -Name "banner-utf8-default" -Actual $banner

# === Snapshot: Format-TreeLine variants ===
$tree1 = Format-TreeLine -Glyphs $glyphs -IsLast $false -Indent 0 -Text "✓ first item"
$tree2 = Format-TreeLine -Glyphs $glyphs -IsLast $true  -Indent 0 -Text "✓ last item"
$tree3 = Format-TreeLine -Glyphs $glyphs -IsLast $false -Indent 1 -Text "child item"
$treeBlock = "$tree1`n$tree2`n$tree3"
Compare-Snapshot -Name "tree-utf8-mixed" -Actual $treeBlock

# === Snapshot: Format-SideBox short text ===
$boxShort = Format-SideBox -Emoji "🦊" -Text "rust monorepo" -MaxWidth 30 -Glyphs $glyphs
Compare-Snapshot -Name "sidebox-short" -Actual $boxShort

# === Snapshot: Format-SideBox long wrapping text ===
$boxLong = Format-SideBox -Emoji "🦉" -Text "rerun bootstrap.ps1 - it is safe to run repeatedly" -MaxWidth 30 -Glyphs $glyphs
Compare-Snapshot -Name "sidebox-wrapped" -Actual $boxLong

# === Snapshot: Format-AnimalErrorMoment emoji-only fallback (width 70, no sprite) ===
$emojiOnly = Format-AnimalErrorMoment -Animal raccoon -Message "Repo points to wrong origin" -FixCommand "git remote set-url origin https://github.com/example/foo.git" -TermWidth 70 -RootDir "/nonexistent" -Glyphs $glyphs -Enabled $false
Compare-Snapshot -Name "errormoment-emoji-only" -Actual $emojiOnly

# === Snapshot: Format-AnimalErrorMoment tier-2 (synthetic sprite, width 90) ===
$tempSnap = Join-Path $env:TEMP "bootstrap-snapshot-$(Get-Random)"
New-Item -ItemType Directory -Path "$tempSnap/animals" -Force | Out-Null
$syntheticSprite = @"
# header
# header

XXXXXXX
YYYYYYY
ZZZZZZZ
"@
Set-Content -Path "$tempSnap/animals/raccoon.ansi" -Value $syntheticSprite -Encoding UTF8

$tier2 = Format-AnimalErrorMoment -Animal raccoon -Message "Test tier-2" -FixCommand "do thing" -TermWidth 90 -RootDir $tempSnap -Glyphs $glyphs -Enabled $false
Compare-Snapshot -Name "errormoment-tier2" -Actual $tier2

# === Snapshot: Format-AnimalErrorMoment tier-1 side-by-side (width 120) ===
$tier1 = Format-AnimalErrorMoment -Animal fox -Message "Test tier-1" -FixCommand "do thing" -TermWidth 120 -RootDir $tempSnap -Glyphs $glyphs -Enabled $false
# Note: fox lookup falls back to raccoon.ansi because RootDir only has raccoon.ansi
# But the registered emoji for fox is 🦊 not 🦝
Compare-Snapshot -Name "errormoment-tier1" -Actual $tier1

# Cleanup
Remove-Item -Path $tempSnap -Recurse -Force -ErrorAction SilentlyContinue

if ($failures -eq 0) {
    Write-Host "`nAll snapshot tests passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n$failures snapshot test(s) failed." -ForegroundColor Red
    Write-Host "If the change was intentional, regenerate goldens by running:" -ForegroundColor Yellow
    Write-Host "  pwsh -NoProfile -File tests/test-snapshots.ps1 -RegenGoldens" -ForegroundColor Yellow
    Write-Host "(though that flag isn't implemented -- currently you'd update goldens manually)" -ForegroundColor DimGray
    exit 1
}
