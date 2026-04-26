. "$PSScriptRoot/../lib/ui.ps1"

$failures = 0

function Assert-Equal($expected, $actual, $message) {
    if ($expected -ne $actual) {
        Write-Host "FAIL: $message — expected '$expected' got '$actual'" -ForegroundColor Red
        $script:failures++
    } else {
        Write-Host "PASS: $message" -ForegroundColor Green
    }
}

function Assert-True($condition, $message) {
    if (-not $condition) {
        Write-Host "FAIL: $message" -ForegroundColor Red
        $script:failures++
    } else {
        Write-Host "PASS: $message" -ForegroundColor Green
    }
}

# Capability detection
$caps = Get-TerminalCaps
Assert-Equal $true ($caps -is [hashtable]) "Get-TerminalCaps returns hashtable"
Assert-Equal $true $caps.ContainsKey('SupportsColor') "caps has SupportsColor"
Assert-Equal $true $caps.ContainsKey('SupportsUtf8') "caps has SupportsUtf8"
Assert-Equal $true $caps.ContainsKey('SupportsTrueColor') "caps has SupportsTrueColor"
Assert-Equal $true $caps.ContainsKey('Width') "caps has Width"

# Glyph selection: UTF-8 path
$glyphs = Get-Glyphs -Utf8 $true
Assert-Equal "✓" $glyphs.Ok "ok glyph utf8"
Assert-Equal "✗" $glyphs.Fail "fail glyph utf8"
Assert-Equal "⚠" $glyphs.Warn "warn glyph utf8"
Assert-Equal "├─" $glyphs.TreeMid "tree mid utf8"
Assert-Equal "└─" $glyphs.TreeEnd "tree end utf8"

# Glyph selection: ASCII path
$glyphsAscii = Get-Glyphs -Utf8 $false
Assert-Equal "[ok]" $glyphsAscii.Ok "ok glyph ascii"
Assert-Equal "[!!]" $glyphsAscii.Fail "fail glyph ascii"
Assert-Equal "[??]" $glyphsAscii.Warn "warn glyph ascii"
Assert-Equal "+-" $glyphsAscii.TreeMid "tree mid ascii"
Assert-Equal "'-" $glyphsAscii.TreeEnd "tree end ascii"

# Colorize: with color enabled, returns ANSI-wrapped string
$colored = Format-Color -Text "hello" -Color Green -Enabled $true
Assert-Equal $true ($colored -match "`e\[") "Format-Color emits ANSI when enabled"
Assert-Equal $true ($colored.Contains("hello")) "Format-Color preserves text when enabled"

# Colorize: with color disabled, returns plain string
$plain = Format-Color -Text "hello" -Color Green -Enabled $false
Assert-Equal "hello" $plain "Format-Color returns plain text when disabled"


# Section header
$section = Format-Section -Title "Cloning repositories" -Width 60 -Glyphs (Get-Glyphs -Utf8 $true) -Enabled $false
Assert-Equal $true ($section.Contains("Cloning repositories")) "section contains title"
Assert-Equal $true ($section.Contains("─")) "section uses light rule"

# Tree line: middle item
$treeMid = Format-TreeLine -Glyphs (Get-Glyphs -Utf8 $true) -IsLast $false -Indent 0 -Text "✓ done"
Assert-Equal "├─ ✓ done" $treeMid "tree middle line"

# Tree line: last item
$treeEnd = Format-TreeLine -Glyphs (Get-Glyphs -Utf8 $true) -IsLast $true -Indent 0 -Text "✓ done"
Assert-Equal "└─ ✓ done" $treeEnd "tree end line"

# Tree line: indented under bar
$treeIndent = Format-TreeLine -Glyphs (Get-Glyphs -Utf8 $true) -IsLast $false -Indent 1 -Text "child"
Assert-Equal "│  ├─ child" $treeIndent "tree indented middle"

# Side box: emoji + text wrapped in rounded box
$box = Format-SideBox -Emoji "🦊" -Text "this is the rust monorepo" -Glyphs (Get-Glyphs -Utf8 $true)
Assert-Equal $true ($box.Contains("🦊")) "side box contains emoji"
Assert-Equal $true ($box.Contains("rust monorepo")) "side box contains text"
Assert-Equal $true ($box.Contains("╭")) "side box uses rounded corner"
Assert-Equal $true ($box.Contains("╰")) "side box uses rounded bottom"


# Spinner frame: returns a single braille char from the cycle
$frame0 = Get-SpinnerFrame -Index 0
Assert-Equal "⠋" $frame0 "spinner frame 0"
$frame5 = Get-SpinnerFrame -Index 5
Assert-Equal "⠴" $frame5 "spinner frame 5"
# Wraps
$frame10 = Get-SpinnerFrame -Index 10
Assert-Equal "⠋" $frame10 "spinner frame wraps"

# A. Set-UiOverrides affects subsequent Get-TerminalCaps calls
Set-UiOverrides -NoColor $true -Ascii $false
$caps = Get-TerminalCaps
Assert-Equal $false $caps.SupportsColor "Set-UiOverrides -NoColor `$true makes SupportsColor false"

Set-UiOverrides -NoColor $false -Ascii $true
$caps = Get-TerminalCaps
Assert-Equal $false $caps.SupportsUtf8 "Set-UiOverrides -Ascii `$true makes SupportsUtf8 false"

# Reset
Set-UiOverrides -NoColor $false -Ascii $false

# B. NO_COLOR env var disables color (standard convention)
$savedNoColor = $env:NO_COLOR
$env:NO_COLOR = "1"
Set-UiOverrides -NoColor $false -Ascii $false
$caps = Get-TerminalCaps
Assert-Equal $false $caps.SupportsColor "NO_COLOR env var disables SupportsColor"
$env:NO_COLOR = $savedNoColor

# C. Format-Color edge cases
# Unknown color name returns plain text
$plain = Format-Color -Text "hi" -Color "NotARealColor" -Enabled $true
Assert-Equal "hi" $plain "Format-Color with unknown color returns plain text"

# Empty text - PowerShell rejects empty mandatory string params; verify it throws
$emptyThrew = $false
try { $null = Format-Color -Text "" -Color "Green" -Enabled $true } catch { $emptyThrew = $true }
Assert-True $emptyThrew "Format-Color with empty text raises parameter error (mandatory param)"

# Bold flag adds 1; prefix to escape
$bold = Format-Color -Text "x" -Color "Green" -Enabled $true -Bold $true
Assert-True ($bold -match "1;38;2;") "Format-Color -Bold emits 1; prefix"

$notBold = Format-Color -Text "x" -Color "Green" -Enabled $true -Bold $false
Assert-True (-not ($notBold -match "1;38;2;")) "Format-Color -Bold `$false omits 1; prefix"

# D. Format-RainbowText edge cases
# Empty string — mandatory param rejects empty strings; verify it throws
$rainbowEmptyThrew = $false
try { $null = Format-RainbowText -Text "" -Enabled $true } catch { $rainbowEmptyThrew = $true }
Assert-True $rainbowEmptyThrew "Format-RainbowText empty input raises parameter error (mandatory param)"

# Disabled returns plain text unchanged
$plain = Format-RainbowText -Text "rainbow" -Enabled $false
Assert-Equal "rainbow" $plain "Format-RainbowText disabled returns plain text"

# Frame offset shifts hue: same text different offsets produce different output
$frame0 = Format-RainbowText -Text "x" -FrameOffset 0 -Enabled $true
$frame180 = Format-RainbowText -Text "x" -FrameOffset 180 -Enabled $true
Assert-True ($frame0 -ne $frame180) "Format-RainbowText with different FrameOffsets produces different output"

# E. Format-Section width consistency
$section = Format-Section -Title "Test" -Width 60 -Glyphs (Get-Glyphs -Utf8 $true) -Enabled $false
Assert-True ($section.Length -ge 14) "section length is at least title+padding"
Assert-True ($section.Contains("Test")) "section contains title text"

# Section with ASCII glyphs uses dashes not unicode rules
$asciiSection = Format-Section -Title "Test" -Width 60 -Glyphs (Get-Glyphs -Utf8 $false) -Enabled $false
Assert-True ($asciiSection.Contains("-")) "ASCII section uses dashes"
Assert-True (-not $asciiSection.Contains("─")) "ASCII section does not use unicode rule"

# F. Format-TreeLine deep indents
# Indent 3 produces 3 levels of bar prefix
$deep = Format-TreeLine -Glyphs (Get-Glyphs -Utf8 $true) -IsLast $false -Indent 3 -Text "nested"
$strippedAnsi = $deep -replace "`e\[[0-9;]*m", ""
Assert-True ($strippedAnsi.IndexOf("│") -ge 0) "deep indent contains vertical bars"
Assert-True ($strippedAnsi.Contains("nested")) "deep indent contains text"

# Indent 0 has no bars
$flat = Format-TreeLine -Glyphs (Get-Glyphs -Utf8 $true) -IsLast $false -Indent 0 -Text "flat"
Assert-True (-not $flat.Contains("│")) "indent 0 has no vertical bar prefix"

# G. Format-SideBox — content rows all have the same width
# Note: the bottom line uses Append (no trailing newline) while content lines use AppendLine,
# so the bottom row is 1 char shorter than the rest. We test that content rows are uniform.
$box = Format-SideBox -Emoji "🦊" -Text "short" -MaxWidth 30 -Glyphs (Get-Glyphs -Utf8 $true)
$lines = $box -split "`n" | Where-Object { $_.Length -gt 0 }
# Top and content rows (all but the last) come from AppendLine and should share the same width
$innerLines = $lines | Select-Object -SkipLast 1
$innerWidths = $innerLines | ForEach-Object { $_.Length }
$firstInnerWidth = $innerWidths[0]
$innerAllSame = $true
foreach ($w in $innerWidths) {
    if ($w -ne $firstInnerWidth) { $innerAllSame = $false; break }
}
Assert-Equal $true $innerAllSame "Format-SideBox top+content rows all have equal width"

# H. Format-SideBox text wrapping
$longText = "This is a much longer commentary that should wrap to multiple lines inside the box"
$wrapped = Format-SideBox -Emoji "🦊" -Text $longText -MaxWidth 30 -Glyphs (Get-Glyphs -Utf8 $true)
$lines = $wrapped -split "`n" | Where-Object { $_.Length -gt 0 }
Assert-True ($lines.Count -gt 3) "long text wraps to multiple rows (top + bottom + at least 2 content lines)"

# I. Get-SpinnerFrame full cycle
$expectedFrames = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
for ($i = 0; $i -lt $expectedFrames.Count; $i++) {
    Assert-Equal $expectedFrames[$i] (Get-SpinnerFrame -Index $i) "spinner frame $i"
}
# Wraps at exactly 10
Assert-Equal $expectedFrames[0] (Get-SpinnerFrame -Index 10) "spinner wraps at 10"
Assert-Equal $expectedFrames[3] (Get-SpinnerFrame -Index 13) "spinner wraps at 13 → frame 3"

# J. ConvertFrom-Hsv produces RGB triplets in valid range
# Hue 0 (red), full saturation+value
$rgb = ConvertFrom-Hsv -Hue 0 -Saturation 1.0 -Value 1.0
Assert-Equal 3 $rgb.Count "ConvertFrom-Hsv returns 3 components"
Assert-True ($rgb[0] -ge 0 -and $rgb[0] -le 255) "R in 0-255"
Assert-True ($rgb[1] -ge 0 -and $rgb[1] -le 255) "G in 0-255"
Assert-True ($rgb[2] -ge 0 -and $rgb[2] -le 255) "B in 0-255"
# Hue 0 should be predominantly red
Assert-True ($rgb[0] -gt $rgb[1] -and $rgb[0] -gt $rgb[2]) "Hue 0 is red-dominant"

# Hue 120 should be predominantly green
$green = ConvertFrom-Hsv -Hue 120 -Saturation 1.0 -Value 1.0
Assert-True ($green[1] -gt $green[0] -and $green[1] -gt $green[2]) "Hue 120 is green-dominant"

# Hue 240 should be predominantly blue
$blue = ConvertFrom-Hsv -Hue 240 -Saturation 1.0 -Value 1.0
Assert-True ($blue[2] -gt $blue[0] -and $blue[2] -gt $blue[1]) "Hue 240 is blue-dominant"

if ($failures -eq 0) {
    Write-Host "`nAll UI tests passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n$failures UI test(s) failed." -ForegroundColor Red
    exit 1
}
