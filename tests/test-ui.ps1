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

if ($failures -eq 0) {
    Write-Host "`nAll UI tests passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n$failures UI test(s) failed." -ForegroundColor Red
    exit 1
}
