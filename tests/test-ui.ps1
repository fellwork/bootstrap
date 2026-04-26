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

if ($failures -eq 0) {
    Write-Host "`nAll UI tests passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n$failures UI test(s) failed." -ForegroundColor Red
    exit 1
}
