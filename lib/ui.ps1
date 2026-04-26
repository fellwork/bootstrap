# UI primitives: terminal capability detection, glyph selection, color formatting.
# Pure functions — no side effects, no global state.

$script:NoColorOverride = $false
$script:AsciiOverride = $false

function Set-UiOverrides {
    param(
        [bool]$NoColor = $false,
        [bool]$Ascii = $false
    )
    $script:NoColorOverride = $NoColor
    $script:AsciiOverride = $Ascii
}

function Get-TerminalCaps {
    $isTty = -not [Console]::IsOutputRedirected
    $noColorEnv = -not [string]::IsNullOrEmpty($env:NO_COLOR)
    $supportsColor = $isTty -and -not $noColorEnv -and -not $script:NoColorOverride

    # Truecolor: Windows Terminal sets WT_SESSION; modern terminals set COLORTERM
    $supportsTrueColor = $supportsColor -and (
        -not [string]::IsNullOrEmpty($env:WT_SESSION) -or
        $env:COLORTERM -eq 'truecolor' -or
        $env:COLORTERM -eq '24bit'
    )

    # UTF-8: PowerShell 7+ defaults to UTF-8 for output
    $supportsUtf8 = -not $script:AsciiOverride -and (
        [Console]::OutputEncoding.WebName -eq 'utf-8' -or
        $PSVersionTable.PSVersion.Major -ge 7
    )

    $width = if ($Host.UI.RawUI.WindowSize.Width -gt 0) { $Host.UI.RawUI.WindowSize.Width } else { 80 }

    return @{
        SupportsColor     = $supportsColor
        SupportsTrueColor = $supportsTrueColor
        SupportsUtf8      = $supportsUtf8
        Width             = $width
        IsTty             = $isTty
    }
}

function Get-Glyphs {
    param([bool]$Utf8 = $true)
    if ($Utf8) {
        return @{
            Ok       = "✓"
            Fail     = "✗"
            Warn     = "⚠"
            Arrow    = "→"
            Ellipsis = "…"
            Bullet   = "●"
            TreeMid  = "├─"
            TreeEnd  = "└─"
            TreeBar  = "│ "
            RuleHeavy = "═"
            RuleLight = "─"
            BoxTL = "╭"
            BoxTR = "╮"
            BoxBL = "╰"
            BoxBR = "╯"
            BoxV  = "│"
            BoxH  = "─"
        }
    } else {
        return @{
            Ok       = "[ok]"
            Fail     = "[!!]"
            Warn     = "[??]"
            Arrow    = "->"
            Ellipsis = "..."
            Bullet   = "*"
            TreeMid  = "+-"
            TreeEnd  = "'-"
            TreeBar  = "| "
            RuleHeavy = "="
            RuleLight = "-"
            BoxTL = "+"
            BoxTR = "+"
            BoxBL = "+"
            BoxBR = "+"
            BoxV  = "|"
            BoxH  = "-"
        }
    }
}

# Semantic palette (24-bit RGB)
$script:Colors = @{
    Green   = @(126, 184, 119)
    Yellow  = @(212, 168, 75)
    Red     = @(194, 91, 86)
    Cyan    = @(95, 175, 215)
    DimGray = @(108, 108, 108)
    White   = @(238, 238, 238)
}

function Format-Color {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Color,
        [bool]$Enabled = $true,
        [bool]$Bold = $false
    )
    if (-not $Enabled) { return $Text }
    if (-not $script:Colors.ContainsKey($Color)) { return $Text }
    $rgb = $script:Colors[$Color]
    $boldCode = if ($Bold) { "1;" } else { "" }
    return "`e[${boldCode}38;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m$Text`e[0m"
}

function Format-RainbowText {
    # Cycle hue across each character. For shimmer use, frame parameter offsets the start hue.
    param(
        [Parameter(Mandatory)][string]$Text,
        [int]$FrameOffset = 0,
        [bool]$Enabled = $true
    )
    if (-not $Enabled) { return $Text }
    $sb = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $hue = (($i * 25) + $FrameOffset) % 360
        $rgb = ConvertFrom-Hsv -Hue $hue -Saturation 0.65 -Value 0.95
        [void]$sb.Append("`e[38;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m$($Text[$i])")
    }
    [void]$sb.Append("`e[0m")
    return $sb.ToString()
}

function ConvertFrom-Hsv {
    param([int]$Hue, [double]$Saturation, [double]$Value)
    $c = $Value * $Saturation
    $hp = $Hue / 60.0
    $x = $c * (1 - [Math]::Abs(($hp % 2) - 1))
    $m = $Value - $c
    switch ([Math]::Floor($hp)) {
        0 { $r = $c; $g = $x; $b = 0 }
        1 { $r = $x; $g = $c; $b = 0 }
        2 { $r = 0; $g = $c; $b = $x }
        3 { $r = 0; $g = $x; $b = $c }
        4 { $r = $x; $g = 0; $b = $c }
        default { $r = $c; $g = 0; $b = $x }
    }
    return @(
        [int](($r + $m) * 255),
        [int](($g + $m) * 255),
        [int](($b + $m) * 255)
    )
}

function Format-Section {
    param(
        [Parameter(Mandatory)][string]$Title,
        [int]$Width = 60,
        [hashtable]$Glyphs,
        [bool]$Enabled = $true
    )
    if (-not $Glyphs) { $Glyphs = Get-Glyphs -Utf8 $true }
    $rule = $Glyphs.RuleLight
    $padded = "  $Title  "
    $sideRule = $rule * 5
    $line = "$sideRule$padded$sideRule"
    if ($Enabled) {
        return Format-Color -Text $line -Color Cyan -Enabled $true
    }
    return $line
}

function Format-TreeLine {
    param(
        [Parameter(Mandatory)][hashtable]$Glyphs,
        [bool]$IsLast = $false,
        [int]$Indent = 0,
        [Parameter(Mandatory)][string]$Text
    )
    $prefix = ""
    for ($i = 0; $i -lt $Indent; $i++) {
        $prefix += "$($Glyphs.TreeBar) "
    }
    $branch = if ($IsLast) { $Glyphs.TreeEnd } else { $Glyphs.TreeMid }
    return "$prefix$branch $Text"
}

function Format-Banner {
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$Subtitle = "",
        [int]$Width = 60,
        [hashtable]$Glyphs,
        [bool]$Enabled = $true
    )
    if (-not $Glyphs) { $Glyphs = Get-Glyphs -Utf8 $true }
    $rule = $Glyphs.RuleHeavy * $Width
    $titleLine = "  $Title".PadRight($Width - $Subtitle.Length) + $Subtitle
    $colored = if ($Enabled) {
        $rule = Format-Color -Text $rule -Color Cyan -Enabled $true
        $titleLine = Format-Color -Text $titleLine -Color White -Enabled $true -Bold $true
        @($rule, $titleLine, $rule) -join "`n"
    } else {
        @($rule, $titleLine, $rule) -join "`n"
    }
    return $colored
}

function Format-SideBox {
    param(
        [Parameter(Mandatory)][string]$Emoji,
        [Parameter(Mandatory)][string]$Text,
        [int]$MaxWidth = 32,
        [hashtable]$Glyphs
    )
    if (-not $Glyphs) { $Glyphs = Get-Glyphs -Utf8 $true }

    # Wrap text to fit MaxWidth - 6 (for emoji + padding + borders)
    $wrapWidth = $MaxWidth - 6
    $words = $Text -split '\s+'
    $lines = @()
    $current = ""
    foreach ($w in $words) {
        if (($current.Length + $w.Length + 1) -le $wrapWidth) {
            $current = if ($current) { "$current $w" } else { $w }
        } else {
            $lines += $current
            $current = $w
        }
    }
    if ($current) { $lines += $current }

    # Build the box
    $boxWidth = $MaxWidth
    $top    = $Glyphs.BoxTL + ($Glyphs.BoxH * ($boxWidth - 2)) + $Glyphs.BoxTR
    $bottom = $Glyphs.BoxBL + ($Glyphs.BoxH * ($boxWidth - 2)) + $Glyphs.BoxBR

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine($top)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $prefix = if ($i -eq 0) { "$Emoji  " } else { "    " }
        $content = "$prefix$($lines[$i])".PadRight($boxWidth - 4)
        [void]$sb.AppendLine("$($Glyphs.BoxV) $content $($Glyphs.BoxV)")
    }
    [void]$sb.Append($bottom)
    return $sb.ToString()
}
