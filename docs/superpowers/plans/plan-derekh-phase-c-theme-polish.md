# Derekh Phase C — Theme Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add theme override precedence (CLI flag → plan → default) and a second sample theme to prove the schema generalizes.

**Architecture:** Theme system already exists from Phase B (`Get-DhTheme`, `Get-DhThemeColor`, `Get-DhThemeGlyph`, `themes/twilight.json`). This phase adds (a) precedence resolution wired into the eventual `Invoke-DhPlan`, (b) a second theme as a regression check that swapping themes works, and (c) auto-discovery so consumers can list available themes without hardcoding names.

**Tech Stack:** PowerShell 7.5+, JSON

**Spec:** `c:/git/fellwork/bootstrap/docs/superpowers/specs/2026-04-26-derekh-tui-design.md` (sections: Theme schema, Theme override resolution order, Public API)

**Prerequisites:** Phase B complete — `lib/theme.ps1` written, `Get-DhTheme`/`Get-DhThemeColor`/`Get-DhThemeGlyph` exported, `themes/twilight.json` present, `tests/test-theme.ps1` exists.

---

## Task C1 — Theme override resolution

### What to build

Add `Resolve-DhTheme` to `lib/theme.ps1`. This helper encodes the three-level precedence chain defined in the spec so that every entry point that needs a theme name calls a single source of truth instead of scattering `if` logic.

Wire `Resolve-DhTheme` into the `Invoke-DhPlan` stub (in `lib/plan.ps1`), replacing any hardcoded `"twilight"` references.

Add tests to `tests/test-theme.ps1`.

### Precedence order (EXACT — do not deviate)

```
1. -Theme <CLI flag>        highest priority
2. $plan.Theme              plan field (set via New-DhPlan -Theme)
3. "twilight"               built-in default   lowest priority
```

Each level only applies when the level above it is absent or empty/null. An empty string counts as absent (same as null).

### Function signature

```powershell
function Resolve-DhTheme {
    [CmdletBinding()]
    param(
        [string]$CliFlag,   # value of -Theme passed to Invoke-DhPlan; may be $null or ""
        [string]$PlanField, # value of $plan.Theme; may be $null or ""
        [string]$Default = "twilight"
    )
    # Returns: string — the resolved theme name (never null, never empty)
}
```

The function must:

- Return `$CliFlag` when it is non-null and non-empty (trimmed).
- Return `$PlanField` when `$CliFlag` is absent and `$PlanField` is non-null and non-empty (trimmed).
- Return `$Default` (always `"twilight"` unless a future caller overrides it) when both are absent.
- Never return null or empty string — callers depend on this invariant.

### Wiring into Invoke-DhPlan

In `lib/plan.ps1`, the `Invoke-DhPlan` stub (or wherever the plan entry point resolves its theme) must call:

```powershell
$resolvedTheme = Resolve-DhTheme -CliFlag $Theme -PlanField $Plan.Theme
$theme = Get-DhTheme -Name $resolvedTheme
```

This replaces any `Get-DhTheme -Name "twilight"` or `Get-DhTheme -Name $Plan.Theme` calls that lack precedence logic.

### Implementation steps

- [ ] Open `lib/theme.ps1` and add `Resolve-DhTheme` after the existing `Get-DhTheme` family.
- [ ] Export `Resolve-DhTheme` from `derekh.psm1` (add to the `Export-ModuleMember` list or dot-source exports pattern used in Phase A/B).
- [ ] Open `lib/plan.ps1` and replace any direct theme resolution with a call to `Resolve-DhTheme`. Pass `$Theme` (the `-Theme` parameter of `Invoke-DhPlan`) and `$Plan.Theme`.
- [ ] Confirm `Invoke-DhPlan`'s parameter block has `[string]$Theme` (add it if Phase B stubbed it without this param).

### Tests for C1 (add to `tests/test-theme.ps1`)

All tests use the Pester `Describe`/`It` pattern established in Phase B.

```
Describe "Resolve-DhTheme" {
    It "returns the CLI flag when all three levels are set" {
        Resolve-DhTheme -CliFlag "cozy" -PlanField "twilight" | Should -Be "cozy"
    }
    It "returns the plan field when CLI flag is absent" {
        Resolve-DhTheme -CliFlag "" -PlanField "cozy" | Should -Be "cozy"
    }
    It "returns the plan field when CLI flag is null" {
        Resolve-DhTheme -CliFlag $null -PlanField "cozy" | Should -Be "cozy"
    }
    It "returns the default when both CLI flag and plan field are absent" {
        Resolve-DhTheme -CliFlag "" -PlanField "" | Should -Be "twilight"
    }
    It "returns the default when both are null" {
        Resolve-DhTheme -CliFlag $null -PlanField $null | Should -Be "twilight"
    }
    It "trims whitespace before treating a value as present" {
        Resolve-DhTheme -CliFlag "  " -PlanField "cozy" | Should -Be "cozy"
    }
    It "never returns null or empty" {
        $result = Resolve-DhTheme -CliFlag $null -PlanField $null
        $result | Should -Not -BeNullOrEmpty
    }
}
```

Add a further integration test verifying the wiring:

```
Describe "Invoke-DhPlan theme resolution (integration)" {
    It "uses CLI -Theme over plan Theme field" {
        # Use a headless minimal plan; capture which theme was loaded via mock or state inspection.
        # This test may be a stub if Invoke-DhPlan is not yet headless-capable;
        # leave it as a pending It block with a comment: "Wire after Phase D headless mode".
        Set-ItResult -Pending -Because "Invoke-DhPlan headless path implemented in Phase D"
    }
}
```

---

## Task C2 — Second theme (cozy) + auto-discovery

### What to build

Two deliverables:

1. `themes/cozy.json` — Cozy Farmhouse palette (warm wood-brown background, parchment text, harvest-gold accents). This is the regression check that the theme schema is not hardcoded to twilight.
2. `Get-DhAvailableThemes` function in `lib/theme.ps1` — auto-discovers `*.json` files in the `themes/` directory adjacent to the module and returns their base names (without `.json` extension).

### Cozy theme palette (exact values from brainstorm visual companion)

Source: `c:/git/fellwork/bootstrap/.superpowers/brainstorm/1215822-1777236221/content/theme.html` — `.stage-cozy` CSS block.

```
bg:        #2b1f15   (warm wood-brown background)
fg:        #f0e5cc   (parchment text)
frame:     #b8884a   (wood-frame border color)
title:     #f8d97a   (harvest-yellow title)
accent:    #e8a248   (harvest-gold accent)
ok:        #b9d977   (lime green)
warn:      #f0b649   (harvest gold)
fail:      #d96552   (clay red)
running:   #8ec0e0   (clear-sky blue)
pending:   #7a6a4a   (muted wood)
dim:       #a08c64   (aged parchment dim)
chip_bg:   #3a2a1a   (dark wood chip background — from .chip-bg background in source)
```

Note: `bg_alt` is not in the CSS source. Derive it as a slightly lighter warm dark: `#3a2a1a` (same as `chip_bg` — the brainstorm uses this for chip backgrounds, which is the "alternate background surface" role in the schema).

### cozy.json full file

```json
{
  "$schema": "../theme-schema.json",
  "name": "cozy",
  "description": "Cozy Farmhouse — warm wood-brown background, parchment text, harvest-gold accents",

  "palette": {
    "bg":        "#2b1f15",
    "bg_alt":    "#3a2a1a",
    "fg":        "#f0e5cc",
    "frame":     "#b8884a",
    "title":     "#f8d97a",
    "accent":    "#e8a248",
    "ok":        "#b9d977",
    "warn":      "#f0b649",
    "fail":      "#d96552",
    "running":   "#8ec0e0",
    "pending":   "#7a6a4a",
    "dim":       "#a08c64",
    "chip_bg":   "#3a2a1a"
  },

  "glyphs": {
    "phase_pending":   "○",
    "phase_running":   "◐",
    "phase_ok":        "✓",
    "phase_fail":      "✗",
    "phase_warn":      "⚠",
    "spinner_frames":  ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"],
    "progress_filled": "▰",
    "progress_empty":  "▱",
    "progress_partial": "▱",
    "frame_tl": "╭", "frame_tr": "╮",
    "frame_bl": "╰", "frame_br": "╯",
    "frame_h":  "─", "frame_v":  "│",
    "frame_t":  "┬", "frame_b":  "┴", "frame_l": "├", "frame_r": "┤",
    "icon_title":  "🌾",
    "icon_done":   "✨",
    "icon_alert":  "⚠"
  },

  "sections": {
    "header": {
      "title_format": "{icon_title} {title}",
      "show_subtitle": true,
      "show_progress_bar": true,
      "progress_bar_width": 20
    },
    "phases_pane": {
      "min_width": 24,
      "max_width": 32,
      "show_phase_progress": true
    },
    "active_pane": {
      "show_spinner": true,
      "show_elapsed": true
    },
    "issues_pane": {
      "max_visible": 8,
      "auto_scroll": true,
      "show_indices": true
    },
    "footer": {
      "show_keybinds": true,
      "keybind_format": "[{key}] {label}"
    }
  },

  "ascii_fallback": {
    "enabled": true,
    "phase_pending":   "[ ]",
    "phase_running":   "[~]",
    "phase_ok":        "[+]",
    "phase_fail":      "[!]",
    "phase_warn":      "[?]",
    "spinner_frames":  ["|","/","-","\\"],
    "progress_filled": "#",
    "progress_empty":  "-",
    "frame_tl": "+", "frame_tr": "+",
    "frame_bl": "+", "frame_br": "+",
    "frame_h":  "-", "frame_v":  "|",
    "frame_t":  "+", "frame_b":  "+", "frame_l": "+", "frame_r": "+"
  }
}
```

The only glyphs that differ from twilight are `progress_filled` (`▰` vs `█`) and `progress_empty`/`progress_partial` (`▱` vs `░`/`▒`), and `icon_title` (`🌾` vs `🌙`). This difference is intentional — cozy uses wheat/square progress indicators per the brainstorm visual, twilight uses block-fill. All other glyphs are shared to keep the ascii_fallback simple.

### Get-DhAvailableThemes function

```powershell
function Get-DhAvailableThemes {
    <#
    .SYNOPSIS
        Returns the names of all themes discoverable in the themes/ directory.
    .OUTPUTS
        [string[]] — sorted array of theme names (filename without .json extension)
    #>
    [CmdletBinding()]
    param()

    $themesDir = Join-Path $PSScriptRoot ".." "themes"
    if (-not (Test-Path $themesDir)) {
        return @()
    }
    Get-ChildItem -Path $themesDir -Filter "*.json" |
        Sort-Object Name |
        ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) }
}
```

Key implementation notes:

- `$PSScriptRoot` inside `lib/theme.ps1` is the `lib/` directory, so `..` steps up to `derekh/`, then `themes` is the subdirectory.
- Returns `@()` (empty array, not null) when the directory doesn't exist — callers can safely iterate with `foreach`.
- Sorted alphabetically so output is stable across file-system orderings.
- Export from `derekh.psm1`.

### Implementation steps

- [ ] Create `themes/cozy.json` with the exact content in the "cozy.json full file" block above.
- [ ] Open `lib/theme.ps1` and add `Get-DhAvailableThemes` after `Resolve-DhTheme`.
- [ ] Export `Get-DhAvailableThemes` from `derekh.psm1`.
- [ ] Open `tests/test-theme.ps1` and add the test blocks below.

### Tests for C2 (add to `tests/test-theme.ps1`)

```
Describe "cozy theme file" {
    It "loads without error via Get-DhTheme" {
        { Get-DhTheme -Name "cozy" } | Should -Not -Throw
    }
    It "has the correct name field" {
        (Get-DhTheme -Name "cozy").name | Should -Be "cozy"
    }
    It "passes Test-DhTheme schema validation" {
        Test-DhTheme -Name "cozy" | Should -Be $true
    }
    It "has all required palette keys" {
        $required = @("bg","bg_alt","fg","frame","title","accent","ok","warn","fail","running","pending","dim","chip_bg")
        $palette = (Get-DhTheme -Name "cozy").palette
        foreach ($key in $required) {
            $palette.$key | Should -Not -BeNullOrEmpty -Because "palette.$key must be present in cozy theme"
        }
    }
    It "palette values are valid hex colors" {
        $palette = (Get-DhTheme -Name "cozy").palette
        $palette.PSObject.Properties | ForEach-Object {
            $_.Value | Should -Match "^#[0-9a-fA-F]{6}$" -Because "$($_.Name) must be a 6-digit hex color"
        }
    }
    It "has the correct bg color from the brainstorm palette" {
        (Get-DhTheme -Name "cozy").palette.bg | Should -Be "#2b1f15"
    }
    It "has the correct fg color from the brainstorm palette" {
        (Get-DhTheme -Name "cozy").palette.fg | Should -Be "#f0e5cc"
    }
}

Describe "twilight theme still valid after cozy added" {
    It "loads without error" {
        { Get-DhTheme -Name "twilight" } | Should -Not -Throw
    }
    It "passes Test-DhTheme schema validation" {
        Test-DhTheme -Name "twilight" | Should -Be $true
    }
    It "has all required palette keys" {
        $required = @("bg","bg_alt","fg","frame","title","accent","ok","warn","fail","running","pending","dim","chip_bg")
        $palette = (Get-DhTheme -Name "twilight").palette
        foreach ($key in $required) {
            $palette.$key | Should -Not -BeNullOrEmpty -Because "palette.$key must be present in twilight theme"
        }
    }
}

Describe "Get-DhAvailableThemes" {
    It "returns an array" {
        Get-DhAvailableThemes | Should -BeOfType [string]
    }
    It "includes 'twilight'" {
        Get-DhAvailableThemes | Should -Contain "twilight"
    }
    It "includes 'cozy'" {
        Get-DhAvailableThemes | Should -Contain "cozy"
    }
    It "returns at least two themes" {
        (Get-DhAvailableThemes).Count | Should -BeGreaterOrEqual 2
    }
    It "returns names without .json extension" {
        Get-DhAvailableThemes | ForEach-Object {
            $_ | Should -Not -Match "\.json$"
        }
    }
    It "returns results in sorted order" {
        $themes = Get-DhAvailableThemes
        $sorted = $themes | Sort-Object
        $themes | Should -Be $sorted
    }
}
```

---

## Acceptance criteria

The phase is complete when ALL of the following are true:

- [ ] `Resolve-DhTheme` exists in `lib/theme.ps1` and is exported.
- [ ] `Resolve-DhTheme` passes all 7 test cases listed in C1 (including the whitespace-trim case).
- [ ] `Invoke-DhPlan` calls `Resolve-DhTheme` instead of hardcoding theme resolution.
- [ ] `themes/cozy.json` exists with exact palette values from the brainstorm visual companion.
- [ ] `Get-DhTheme -Name "cozy"` returns the cozy theme without error.
- [ ] `Test-DhTheme -Name "cozy"` returns `$true`.
- [ ] Both themes have all 13 required palette keys (`bg`, `bg_alt`, `fg`, `frame`, `title`, `accent`, `ok`, `warn`, `fail`, `running`, `pending`, `dim`, `chip_bg`).
- [ ] Both theme palettes contain only valid 6-digit hex colors.
- [ ] `Get-DhAvailableThemes` exists in `lib/theme.ps1`, is exported, and returns at least `@("cozy", "twilight")` in sorted order.
- [ ] All new tests in `tests/test-theme.ps1` pass via `Invoke-Pester`.
- [ ] No existing Phase B tests are broken (run `tests/run-all.ps1` clean).

---

## Files changed in this phase

| File | Change |
|---|---|
| `lib/theme.ps1` | Add `Resolve-DhTheme` and `Get-DhAvailableThemes` |
| `lib/plan.ps1` | Replace hardcoded theme resolution with `Resolve-DhTheme` call |
| `derekh.psm1` | Export `Resolve-DhTheme` and `Get-DhAvailableThemes` |
| `themes/cozy.json` | New file — Cozy Farmhouse palette |
| `tests/test-theme.ps1` | Add C1 and C2 test blocks |

No new files are created except `themes/cozy.json`. All other changes are additive edits to files created in Phases A and B.
