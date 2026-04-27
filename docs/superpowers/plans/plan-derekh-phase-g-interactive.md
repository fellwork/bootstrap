# Derekh Phase G — Resize + Interactive Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the TUI useful as a debug surface — graceful terminal resize, post-completion freeze with `[q]` to quit and `[1-9]` to copy fix commands.

**Architecture:** Resize is a background runspace that polls `$Host.UI.RawUI.WindowSize` every 200ms and signals the main thread via a shared `[System.Collections.Concurrent.ConcurrentQueue]` of resize events. Post-completion interactive mode is an extension of the existing key loop (`lib/input.ps1`) with new handlers registered for digit keys `1`-`9` and updated footer keybind rendering. Manual smoke test stands in for programmatic TUI assertions (per spec §"Manual TUI smoke test instead of programmatic assertions").

**Tech Stack:** PowerShell 7.5+ runspaces (`[powershell]::Create()` + `[runspacefactory]::CreateRunspace()`), `[System.Collections.Concurrent.ConcurrentQueue[object]]`, `Set-Clipboard` / pbcopy / xclip chain (already in `lib/clipboard.ps1`).

**Spec:** `c:/git/fellwork/bootstrap/docs/superpowers/specs/2026-04-26-derekh-tui-design.md` (sections: Resize handling, Interactive mode (post-completion), Manual TUI smoke test instead of programmatic assertions)

**Prerequisites:** Phase F complete — `lib/render.ps1`, `lib/input.ps1`, `lib/clipboard.ps1` exist and pass smoke test; `Invoke-DhPlan` enters TUI mode; `q` quits cleanly; `Stop-DhTui` is the single teardown path; `Get-DhLayout` returns a layout hashtable; `$DerekhState` tracks issues with `FixCommand` fields.

---

## Task G1: Resize handling (`Invoke-DhResize` in `lib/render.ps1`)

**Files modified:**
- `c:/git/fellwork/tools/derekh/lib/render.ps1` — add `Invoke-DhResize`, `Start-DhResizeWatcher`, `Stop-DhResizeWatcher`

### Background

Resize polling in PowerShell TUIs has two viable approaches:

1. **Background runspace** (primary): a `[powershell]` instance running in a thread pool runspace polls the console size and enqueues a resize token into a shared `ConcurrentQueue`. The main event loop drains this queue on each tick and calls `Invoke-DhResize` when a token is found. This is the cleanest design — the main loop is always in control, the background thread only writes to the queue, and there is no cross-thread state mutation.

2. **Per-iteration polling** (fallback, documented inline): if the runspace approach proves unreliable (e.g., certain Windows Terminal versions where `$Host.UI.RawUI` is not thread-safe), the watcher is removed and the main loop calls `Test-DhResizeNeeded` on every iteration. Slightly less responsive (size detection lags one loop tick, typically <50ms) but simpler and guaranteed safe.

Implement the runspace approach. If it fails during smoke testing, the fallback path is to remove `Start-DhResizeWatcher` and add a single `Test-DhResizeNeeded` call at the top of the main event loop body.

### Functions to add

**`Start-DhResizeWatcher`** — launches the background runspace and returns a handle object:

```powershell
function Start-DhResizeWatcher {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Concurrent.ConcurrentQueue[object]]$Queue
    )
    # Returns: [PSCustomObject]@{ Runspace; PowerShell; AsyncResult }
}
```

The runspace script polls every 200ms:

```powershell
param($Queue, $InitialW, $InitialH)
$w = $InitialW
$h = $InitialH
while ($true) {
    Start-Sleep -Milliseconds 200
    $sz = $Host.UI.RawUI.WindowSize
    if ($sz.Width -ne $w -or $sz.Height -ne $h) {
        $w = $sz.Width
        $h = $sz.Height
        $null = $Queue.Enqueue([PSCustomObject]@{ Width = $w; Height = $h })
    }
}
```

**`Stop-DhResizeWatcher`** — stops the runspace cleanly:

```powershell
function Stop-DhResizeWatcher {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Handle)
    # Stops the PowerShell instance and disposes the runspace
}
```

**`Invoke-DhResize`** — called by the main loop when a resize event is dequeued:

```powershell
function Invoke-DhResize {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$NewWidth,
        [Parameter(Mandatory)][int]$NewHeight
    )
    # 1. Update $DerekhState.TerminalWidth / $DerekhState.TerminalHeight
    # 2. If below minimum (60w x 15h): show "Terminal too small" message, set
    #    $DerekhState.Paused = $true, return
    # 3. If previously paused (was too-small) and now large enough:
    #    set $DerekhState.Paused = $false, fall through to full re-render
    # 4. Recompute layout via Get-DhLayout
    # 5. Full re-render: clear screen, redraw all regions
}
```

### "Terminal too small" message

When `$NewWidth -lt 60 -or $NewHeight -lt 15`, clear the screen and write a centered message. Use `Write-DhCentered` (a private helper in `render.ps1`) to position the text:

```
╭──────────────────────────────────────╮
│  Terminal too small                  │
│  Resize to at least 60×15 to resume  │
╰──────────────────────────────────────╯
```

The frame is drawn using the theme's frame glyphs. The message stays visible until the next resize event arrives with a size that meets the minimum.

Ctrl+C still exits cleanly from the too-small state — `Stop-DhTui` is registered as a `trap` so it fires regardless.

### Integration points

`Invoke-DhResize` and the watcher are called from `Invoke-DhPlan`'s main event loop in `lib/plan.ps1` (or wherever the loop lives after Phase F). The loop gains two new responsibilities:

1. **Before** `Start-DhLoop` (Phase F's main loop entry): call `Start-DhResizeWatcher`, passing in a new `ConcurrentQueue` and the current `$Host.UI.RawUI.WindowSize`.
2. **Inside** the loop body (once per tick, before key polling): drain the queue and call `Invoke-DhResize` for each event. In practice at most one event per 200ms.
3. **After** the loop exits (normal completion or Ctrl+C): call `Stop-DhResizeWatcher`.

The `$DerekhState.Paused` flag must be respected by the plan-execution dispatcher: when `$true`, no new phase actions start until the terminal is large enough again.

### Steps

- [ ] **Step 1: Add `$DerekhState` fields for resize**

  In `lib/state.ps1`, ensure the state hashtable includes:

  ```powershell
  TerminalWidth  = 0
  TerminalHeight = 0
  Paused         = $false
  ```

  If `Reset-DhState` or `Initialize-DhState` exists (Phase B), add these fields there. Otherwise patch the inline hashtable.

  Expected: `$DerekhState.Paused`, `$DerekhState.TerminalWidth`, and `$DerekhState.TerminalHeight` are accessible from any lib file.

- [ ] **Step 2: Implement `Start-DhResizeWatcher`**

  Add to `lib/render.ps1`:

  ```powershell
  function Start-DhResizeWatcher {
      [CmdletBinding()]
      param(
          [Parameter(Mandatory)]
          [System.Collections.Concurrent.ConcurrentQueue[object]]$Queue
      )

      $sz = $Host.UI.RawUI.WindowSize
      $initW = $sz.Width
      $initH = $sz.Height

      $rs = [runspacefactory]::CreateRunspace()
      $rs.ApartmentState = 'STA'
      $rs.ThreadOptions   = 'ReuseThread'
      $rs.Open()

      $ps = [powershell]::Create()
      $ps.Runspace = $rs

      $null = $ps.AddScript({
          param($Queue, $InitialW, $InitialH)
          $w = $InitialW
          $h = $InitialH
          while ($true) {
              Start-Sleep -Milliseconds 200
              try {
                  $sz = $Host.UI.RawUI.WindowSize
                  if ($sz.Width -ne $w -or $sz.Height -ne $h) {
                      $w = $sz.Width
                      $h = $sz.Height
                      $null = $Queue.Enqueue([PSCustomObject]@{ Width = $w; Height = $h })
                  }
              } catch {
                  # Host.UI.RawUI may throw on some platforms; silently continue
              }
          }
      }).AddParameter('Queue', $Queue).AddParameter('InitialW', $initW).AddParameter('InitialH', $initH)

      $asyncResult = $ps.BeginInvoke()

      return [PSCustomObject]@{
          Runspace    = $rs
          PowerShell  = $ps
          AsyncResult = $asyncResult
      }
  }
  ```

  Expected: function defined; no errors on module import.

- [ ] **Step 3: Implement `Stop-DhResizeWatcher`**

  Add to `lib/render.ps1`:

  ```powershell
  function Stop-DhResizeWatcher {
      [CmdletBinding()]
      param(
          [Parameter(Mandatory)][PSCustomObject]$Handle
      )
      try {
          $Handle.PowerShell.Stop()
          $Handle.PowerShell.Dispose()
          $Handle.Runspace.Close()
          $Handle.Runspace.Dispose()
      } catch {
          # Best-effort; teardown is happening anyway
      }
  }
  ```

  Expected: function defined; calling it on a live handle kills the polling loop within ~200ms.

- [ ] **Step 4: Implement `Write-DhCentered` (private helper)**

  Add to `lib/render.ps1`:

  ```powershell
  function Write-DhCentered {
      [CmdletBinding()]
      param(
          [Parameter(Mandatory)][string[]]$Lines,
          [int]$Width  = $DerekhState.TerminalWidth,
          [int]$Height = $DerekhState.TerminalHeight
      )
      # Clears the screen then writes each line centered both horizontally and vertically.
      # Uses $DerekhState's current theme glyphs for any box-drawing.
      [Console]::Clear()
      $startRow = [Math]::Max(1, [int](($Height - $Lines.Count) / 2))
      for ($i = 0; $i -lt $Lines.Count; $i++) {
          $row = $startRow + $i
          $col = [Math]::Max(1, [int](($Width - $Lines[$i].Length) / 2))
          [Console]::SetCursorPosition($col - 1, $row - 1)
          Write-Host $Lines[$i] -NoNewline
      }
  }
  ```

  Expected: function defined; can be called with arbitrary string arrays.

- [ ] **Step 5: Implement `Invoke-DhResize`**

  Add to `lib/render.ps1`:

  ```powershell
  function Invoke-DhResize {
      [CmdletBinding()]
      param(
          [Parameter(Mandatory)][int]$NewWidth,
          [Parameter(Mandatory)][int]$NewHeight
      )

      $DerekhState.TerminalWidth  = $NewWidth
      $DerekhState.TerminalHeight = $NewHeight

      $minW = 60
      $minH = 15

      if ($NewWidth -lt $minW -or $NewHeight -lt $minH) {
          $DerekhState.Paused = $true
          $theme = Get-DhColor -Key 'fail'    # or use Get-DhTheme to pull warn color

          $msgLines = @(
              (Get-DhGlyph 'frame_tl') + ('─' * 38) + (Get-DhGlyph 'frame_tr'),
              (Get-DhGlyph 'frame_v') + '  Terminal too small                   ' + (Get-DhGlyph 'frame_v'),
              (Get-DhGlyph 'frame_v') + "  Resize to at least ${minW}x${minH} to resume  " + (Get-DhGlyph 'frame_v'),
              (Get-DhGlyph 'frame_bl') + ('─' * 38) + (Get-DhGlyph 'frame_br')
          )
          Write-DhCentered -Lines $msgLines
          return
      }

      # If we were paused (too small) and are now large enough, unpause
      if ($DerekhState.Paused) {
          $DerekhState.Paused = $false
      }

      # Recompute layout and do a full re-render
      $layout = Get-DhLayout -Width $NewWidth -Height $NewHeight -Plan $DerekhState.Plan -Theme (Get-DhTheme)
      Invoke-DhFullRender -Layout $layout
  }
  ```

  Note: `Get-DhLayout` and `Invoke-DhFullRender` must already exist from Phase F. If `Invoke-DhFullRender` is named differently, use that name.

  Expected: calling `Invoke-DhResize -NewWidth 40 -NewHeight 10` shows the "too small" message; calling with `80 24` triggers a full re-render.

- [ ] **Step 6: Wire resize watcher into the main event loop**

  In the file that contains `Invoke-DhPlan`'s main TUI event loop (likely `lib/plan.ps1` or `lib/render.ps1`), add:

  **Before the loop starts:**
  ```powershell
  $resizeQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
  $resizeHandle = Start-DhResizeWatcher -Queue $resizeQueue

  # Seed state with current terminal dimensions
  $sz = $Host.UI.RawUI.WindowSize
  $DerekhState.TerminalWidth  = $sz.Width
  $DerekhState.TerminalHeight = $sz.Height
  ```

  **Inside the loop body (before key polling):**
  ```powershell
  # Drain resize events (at most one per tick in practice)
  $resizeEvent = $null
  while ($resizeQueue.TryDequeue([ref]$resizeEvent)) {
      Invoke-DhResize -NewWidth $resizeEvent.Width -NewHeight $resizeEvent.Height
  }
  ```

  **After the loop exits (before `Stop-DhTui`):**
  ```powershell
  Stop-DhResizeWatcher -Handle $resizeHandle
  ```

  Expected: resizing the terminal window while a plan runs triggers a full re-render within ~200ms; shrinking below 60×15 shows the "too small" message.

- [ ] **Step 7: Guard plan execution on `$DerekhState.Paused`**

  In the plan-execution dispatcher (the code that calls user actions and advances phases), wrap the "advance to next action" logic:

  ```powershell
  if (-not $DerekhState.Paused) {
      # ... invoke next action, update phase progress, emit events ...
  }
  ```

  Expected: while the "too small" message is showing, no new actions start. Resizing back up immediately resumes from where the plan left off.

- [ ] **Step 8: Verify teardown path**

  Confirm that `Stop-DhTui` (registered as a `trap` at the top of `Invoke-DhPlan`) calls `Stop-DhResizeWatcher` if the handle is set. The handle must be stored in a variable accessible to the `trap` block — typically a script-level variable or a variable captured in the closure:

  ```powershell
  trap {
      if ($null -ne $script:resizeHandle) {
          Stop-DhResizeWatcher -Handle $script:resizeHandle
      }
      Stop-DhTui
      break
  }
  ```

  Expected: Ctrl+C while resized-too-small still exits cleanly, restoring the terminal.

---

## Task G2: Post-completion interactive mode

**Files modified:**
- `c:/git/fellwork/tools/derekh/lib/input.ps1` — new key handlers for `1`-`9`, updated footer keybind string
- `c:/git/fellwork/tools/derekh/lib/render.ps1` — `Set-DhFooter`, `Invoke-DhFooterFlash` (timer-based flash)
- `c:/git/fellwork/tools/derekh/lib/plan.ps1` — call `Enter-DhInteractiveMode` after plan completes

### Background

Phase F ends with the plan executing and `q` quitting. Phase G adds the interactive freeze: after `Invoke-DhPlanPhases` returns, the plan does NOT exit. Instead:

1. Issues in the right pane gain numeric prefixes `[1]` through `[9]` (rendered in the issues pane redraw).
2. The footer changes from `[q] quit` to `[q] quit  [1-9] copy fix command`.
3. A new key loop waits for user input.
4. `q`, `Esc`, or `Enter` → `Stop-DhTui` + exit.
5. `1`-`9` → look up `$DerekhState.Issues[$n - 1].FixCommand`, call `Set-DhClipboard`, flash footer.

The key loop is the same non-blocking polling loop from Phase F (`input.ps1`) but with the plan-execution side idle. No new infrastructure is needed; only new handlers registered.

### Functions to add/modify

**`Set-DhFooter`** — writes a new string to the footer region without a full re-render:

```powershell
function Set-DhFooter {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    # Positions cursor at footer row, clears line, writes $Text with theme colors
}
```

**`Invoke-DhFooterFlash`** — schedules a footer message for ~1 second, then reverts. Does NOT use `Start-Sleep` (which would block input). Uses a `[System.Diagnostics.Stopwatch]` checked on each loop tick:

```powershell
function Invoke-DhFooterFlash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$RevertTo = '[q] quit  [1-9] copy fix command',
        [int]$DurationMs = 1000
    )
    # Sets $DerekhState.FooterFlash = @{ Message = $Message; RevertTo = $RevertTo; SW = [Stopwatch]::StartNew(); DurationMs = $DurationMs }
    Set-DhFooter -Text $Message
}
```

The main key loop checks `$DerekhState.FooterFlash` on each tick:

```powershell
if ($null -ne $DerekhState.FooterFlash) {
    if ($DerekhState.FooterFlash.SW.ElapsedMilliseconds -ge $DerekhState.FooterFlash.DurationMs) {
        Set-DhFooter -Text $DerekhState.FooterFlash.RevertTo
        $DerekhState.FooterFlash = $null
    }
}
```

**`Enter-DhInteractiveMode`** — called after the plan completes:

```powershell
function Enter-DhInteractiveMode {
    [CmdletBinding()]
    param()

    # 1. Re-render the issues pane with numeric prefixes [1]-[9]
    Invoke-DhIssuesPaneRender -ShowIndices $true

    # 2. Update the footer keybind string
    Set-DhFooter -Text '[q] quit  [1-9] copy fix command'

    # 3. Register digit key handlers
    for ($n = 1; $n -le 9; $n++) {
        $digit = $n   # capture for closure
        Register-DhKeyHandler -Key "$digit" -Handler {
            $issue = $DerekhState.Issues[$digit - 1]
            if ($null -eq $issue) { return }   # fewer than $digit issues

            if ($issue.FixCommand) {
                Set-DhClipboard -Text $issue.FixCommand
                Invoke-DhFooterFlash -Message "Copied to clipboard"
            } else {
                Invoke-DhFooterFlash -Message "No command to copy"
            }
        }
    }

    # 4. Enter the idle key loop (plan execution side is finished)
    Start-DhKeyLoop -UntilQuit
}
```

Note: `Register-DhKeyHandler` and `Start-DhKeyLoop` are Phase F infrastructure from `lib/input.ps1`. The `-UntilQuit` variant (or equivalent) exits the loop when `q`/`Esc`/`Enter` is pressed, then calls `Stop-DhTui`.

**`Invoke-DhIssuesPaneRender` (modification)** — add a `-ShowIndices` switch. When `$true`, prefix each issue line with `[N] ` for issues 1-9; issues 10+ are shown without a prefix. This keeps the issues list visually clean even when there are more than 9.

```powershell
# Issue line with index (issues 1-9)
"[{0}] {1}" -f $i, $issue.Message

# Issue line without index (issues 10+)
"    {0}" -f $issue.Message
```

The `[N]` prefix is styled using the `accent` theme color to make it visually distinct from the issue message text.

### Steps

- [ ] **Step 1: Add `FooterFlash` field to `$DerekhState`**

  In `lib/state.ps1`, add to the state hashtable:

  ```powershell
  FooterFlash = $null   # [PSCustomObject]@{ Message; RevertTo; SW; DurationMs } | $null
  ```

  Expected: `$DerekhState.FooterFlash` is accessible from `render.ps1` and `input.ps1`.

- [ ] **Step 2: Implement `Set-DhFooter`**

  Add to `lib/render.ps1`. The footer row is `$layout.Footer.Top` (or equivalent field from Phase F's layout). The function must:

  1. Move cursor to the footer row.
  2. Clear the line (`\e[2K` or equivalent).
  3. Write the text in the theme's `dim` color (footer is de-emphasized).
  4. Move cursor back to a safe position (top-left or hidden).

  ```powershell
  function Set-DhFooter {
      [CmdletBinding()]
      param([Parameter(Mandatory)][string]$Text)

      $layout = $DerekhState.CurrentLayout   # cached from last Get-DhLayout call
      if ($null -eq $layout) { return }

      $row = $layout.Footer.Top
      $col = $layout.Footer.Left

      [Console]::SetCursorPosition($col, $row - 1)   # 0-indexed
      Write-Host ("`e[2K") -NoNewline                  # clear line
      $color = Get-DhColor -Key 'dim'
      Write-Host ("{0}{1}{2}" -f $color, $Text, "`e[0m") -NoNewline
  }
  ```

  Expected: calling `Set-DhFooter -Text "[q] quit"` updates only the footer row, no flicker elsewhere.

- [ ] **Step 3: Implement `Invoke-DhFooterFlash`**

  Add to `lib/render.ps1`:

  ```powershell
  function Invoke-DhFooterFlash {
      [CmdletBinding()]
      param(
          [Parameter(Mandatory)][string]$Message,
          [string]$RevertTo  = '[q] quit  [1-9] copy fix command',
          [int]$DurationMs   = 1000
      )

      $DerekhState.FooterFlash = [PSCustomObject]@{
          Message    = $Message
          RevertTo   = $RevertTo
          SW         = [System.Diagnostics.Stopwatch]::StartNew()
          DurationMs = $DurationMs
      }

      Set-DhFooter -Text $Message
  }
  ```

  Expected: after calling `Invoke-DhFooterFlash -Message "Copied to clipboard"`, the footer shows that text immediately, and after ~1 second the loop reverts it.

- [ ] **Step 4: Add footer-flash check to the key loop**

  In `lib/input.ps1`, inside the main polling loop body, add (after key polling, before `Start-Sleep`):

  ```powershell
  # Expire footer flash if duration elapsed
  if ($null -ne $DerekhState.FooterFlash) {
      if ($DerekhState.FooterFlash.SW.ElapsedMilliseconds -ge $DerekhState.FooterFlash.DurationMs) {
          Set-DhFooter -Text $DerekhState.FooterFlash.RevertTo
          $DerekhState.FooterFlash = $null
      }
  }
  ```

  Expected: footer reverts without any `Start-Sleep` blocking input.

- [ ] **Step 5: Modify `Invoke-DhIssuesPaneRender` to support `-ShowIndices`**

  In `lib/render.ps1`, find the function that renders the issues pane. Add a `[switch]$ShowIndices` parameter. When set, prepend `[N] ` (styled) to issues 1-9, and `    ` (4 spaces, no index) to issues 10+.

  The index display is only cosmetic — the underlying `$DerekhState.Issues` array ordering is unchanged.

  ```powershell
  for ($i = 0; $i -lt $DerekhState.Issues.Count; $i++) {
      $issue  = $DerekhState.Issues[$i]
      $n      = $i + 1

      if ($ShowIndices -and $n -le 9) {
          $prefix = Get-DhColor -Key 'accent'
          $prefix += "[{0}] " -f $n
          $prefix += "`e[0m"
      } elseif ($ShowIndices) {
          $prefix = "    "   # no hotkey for issue 10+
      } else {
          $prefix = ""
      }

      # ... render $prefix + $issue.Message with severity color ...
  }
  ```

  Expected: in interactive mode, issues 1-9 show `[1]`, `[2]`, … prefixes in accent color; issue 10 and beyond show no prefix.

- [ ] **Step 6: Implement `Enter-DhInteractiveMode`**

  Add to `lib/input.ps1` (or `lib/plan.ps1` — wherever `Invoke-DhPlan`'s main logic lives):

  ```powershell
  function Enter-DhInteractiveMode {
      [CmdletBinding()]
      param()

      # Re-render issues pane with numeric indices
      Invoke-DhIssuesPaneRender -ShowIndices

      # Update footer
      Set-DhFooter -Text '[q] quit  [1-9] copy fix command'

      # Register digit key handlers (closure captures $n at each iteration)
      foreach ($n in 1..9) {
          $captured = $n
          Register-DhKeyHandler -Key ([string]$captured) -Handler ([scriptblock]::Create("
              `$issue = `$DerekhState.Issues[$($captured - 1)]
              if (`$null -eq `$issue) { return }
              if (`$issue.FixCommand) {
                  Set-DhClipboard -Text `$issue.FixCommand
                  Invoke-DhFooterFlash -Message 'Copied to clipboard'
              } else {
                  Invoke-DhFooterFlash -Message 'No command to copy'
              }
          "))
      }

      # Enter the idle key loop
      Start-DhKeyLoop -UntilQuit
  }
  ```

  Note on closures: PowerShell `foreach` closures capture the variable by reference. Use `[scriptblock]::Create(...)` with string interpolation (as above) or a helper function to force capture-by-value. The `$captured = $n` line is the standard workaround but does NOT work inside `foreach` (only `for`). Use `for ($n = 1; $n -le 9; $n++)` if using `$captured` + a standard scriptblock literal.

  Expected: entering interactive mode registers all 9 handlers; pressing `3` with 3+ issues copies `$DerekhState.Issues[2].FixCommand` or flashes "No command to copy".

- [ ] **Step 7: Call `Enter-DhInteractiveMode` from `Invoke-DhPlan`**

  In `lib/plan.ps1` (or wherever `Invoke-DhPlan` is defined), after the plan-execution loop finishes:

  ```powershell
  # Phase execution complete
  Invoke-DhPlanPhases   # (or however Phase F named this)

  # Enter post-completion interactive mode — user presses q/Esc/Enter to exit
  Enter-DhInteractiveMode

  # Control returns here when the user quits; Stop-DhTui is called by Start-DhKeyLoop
  ```

  Expected: after all phases finish, the TUI freezes with results visible; footer shows `[q] quit  [1-9] copy fix command`; pressing `q` exits cleanly.

- [ ] **Step 8: Verify `q`/`Esc`/`Enter` exit cleanly**

  Confirm that the `q`, `Esc`, and `Enter` handlers registered in Phase F (or in `Enter-DhInteractiveMode`) call `Stop-DhTui` and then exit or return from the key loop. The `Stop-DhTui` contract (from Phase F) must be:

  1. Restore cursor visibility (`\e[?25h`)
  2. Exit alternate screen buffer (`\e[?1049l`)
  3. Reset ANSI state (`\e[0m`)

  Expected: after quitting, the terminal is clean and the cursor is visible.

---

## Task G3: Manual smoke test (`tests/manual-smoke.ps1`)

**Files created:**
- `c:/git/fellwork/tools/derekh/tests/manual-smoke.ps1`

### Background

TUI rendering cannot be meaningfully asserted programmatically in a CI environment. The spec (§"Manual TUI smoke test instead of programmatic assertions") explicitly calls for a human-run smoke test with documented verification steps. This file is the fixture: a fixed plan with known inputs, expected visual outputs described in comments, and a "what to check" block at the top.

The smoke test is NOT added to `tests/run-all.ps1`. It is run by hand only.

### File contents

```powershell
#Requires -Version 7
# tests/manual-smoke.ps1 — Derekh Phase G manual TUI smoke test.
#
# ══════════════════════════════════════════════════════════════════════════════
# MANUAL RUN ONLY — do NOT add to run-all.ps1 or CI.
# This script launches the full TUI and requires a human to visually verify.
#
# Usage:
#   pwsh tests/manual-smoke.ps1
#
# Requirements:
#   - Terminal at least 80×24 (wider is fine; resize testing starts bigger)
#   - UTF-8 capable terminal (Windows Terminal, iTerm2, Ghostty, etc.)
#   - Module imported from ../derekh.psd1 (script does this automatically)
#
# ══════════════════════════════════════════════════════════════════════════════
#
# WHAT TO CHECK (go through each item in order):
#
#   [ ] 1. INITIAL RENDER
#         The TUI opens in an alternate screen buffer.
#         Header shows: "Derekh Smoke Test" + timestamp subtitle.
#         Left pane shows 4 phases: all start in pending (○) state.
#         Right pane (issues) is empty.
#         Footer shows: "[q] quit"
#         Spinner is visible and animating in the active pane.
#
#   [ ] 2. LOOP PHASE — "Clone repos" (phase 1)
#         Items appear one by one: "api", "web", "ops".
#         "api" and "web" complete with ✓ (ok).
#         "ops" completes with ⚠ (warning) and appears in the issues pane
#         as issue [1] with the message "ops clone slow — retried once".
#         Phase 1 finishes with a ⚠ glyph (has warning).
#
#   [ ] 3. SINGLE PHASE — "Check prerequisites" (phase 2)
#         Active pane shows "Checking..." for ~0.5s.
#         Phase completes with ⚠; two alerts land in the issues pane:
#         Issue [2]: "wrangler not installed" (FixCommand present)
#         Issue [3]: "node version is 18, recommend 20" (no FixCommand)
#         Issues pane auto-scrolls to show all 3 issues.
#
#   [ ] 4. SINGLE PHASE — "Run migrations" (phase 3)
#         Completes with ✓ (success). No new issues.
#
#   [ ] 5. SINGLE PHASE — "Verify env" (phase 4)
#         Completes with ✗ (failure). Issue [4] appears:
#         "DATABASE_URL missing" with FixCommand "cp .env.example .env".
#         The overall plan header progress bar reaches 100%.
#
#   [ ] 6. POST-COMPLETION INTERACTIVE MODE
#         After all phases finish, TUI freezes.
#         Issues pane now shows [1] through [4] numeric prefixes in accent color.
#         Issue 3 ("node version") shows NO prefix because it has no FixCommand...
#         WAIT — re-check: ALL issues get a prefix [1]-[9] (prefix is for
#         navigation, not FixCommand presence). Only the flash message
#         "No command to copy" reveals which ones lack a FixCommand.
#         Footer changes to: "[q] quit  [1-9] copy fix command"
#
#   [ ] 7. COPY WITH FIX COMMAND — press "2"
#         Issue [2] has FixCommand "npm install -g wrangler".
#         Footer flashes "Copied to clipboard" for ~1 second.
#         Footer then reverts to "[q] quit  [1-9] copy fix command".
#         Open a new terminal and paste — should see: npm install -g wrangler
#
#   [ ] 8. COPY WITHOUT FIX COMMAND — press "3"
#         Issue [3] has NO FixCommand.
#         Footer flashes "No command to copy" for ~1 second, then reverts.
#
#   [ ] 9. OUT-OF-RANGE KEY — press "9"
#         Only 4 issues exist; pressing "9" should flash "No command to copy"
#         (issue 9 does not exist, treated same as no FixCommand).
#         ALTERNATIVELY: if fewer than 9 issues exist, pressing that digit
#         is silently ignored. Either behavior is acceptable; verify it
#         does NOT crash or leave the footer in a broken state.
#
#   [ ] 10. RESIZE — make terminal SMALLER (below 60×15)
#         Drag terminal window edge to shrink it.
#         Within ~200ms, screen should clear and show centered box:
#         "Terminal too small / Resize to at least 60×15 to resume"
#         The TUI pauses — footer key input still works (press q to exit
#         even from the too-small state).
#
#   [ ] 11. RESIZE — restore terminal size
#         Drag terminal back to ≥80×24.
#         Within ~200ms, full TUI redraws with correct layout.
#         All 4 issues still visible with [1]-[4] prefixes.
#         Footer shows "[q] quit  [1-9] copy fix command".
#
#   [ ] 12. QUIT — press "q"
#         Alternate buffer dismissed; normal terminal restored.
#         Cursor is visible. No garbage characters on screen.
#         Script exits with code 1 (plan had failures).
#
# ══════════════════════════════════════════════════════════════════════════════

$ErrorActionPreference = 'Stop'

# ── Import the module ─────────────────────────────────────────────────────────
$moduleRoot = Join-Path $PSScriptRoot '..'
$manifest   = Join-Path $moduleRoot 'derekh.psd1'

if (-not (Test-Path $manifest)) {
    Write-Error "Cannot find derekh.psd1 at '$manifest'. Run from derekh/tests/."
    exit 1
}

Import-Module $manifest -Force

# ── Build the fixed smoke-test plan ──────────────────────────────────────────
#
# This plan is deterministic — no real I/O, no external tools.
# All actions use Start-Sleep to simulate work and return known results.
# The exact issues, severities, and FixCommands are part of the fixture.

$plan = New-DhPlan -Title 'Derekh Smoke Test' -Subtitle (Get-Date -Format 'HH:mm:ss')

# ── Phase 1: Loop — "Clone repos" ─────────────────────────────────────────────
# api → success
# web → success
# ops → warning with FixCommand (becomes issue [1])

$plan = Add-DhLoopPhase -Plan $plan -Name 'Clone repos' -Items @('api', 'web', 'ops') -Action {
    param($repo)
    Start-Sleep -Milliseconds 400   # simulate clone time

    switch ($repo) {
        'api' {
            return New-DhResult -Success $true -Message 'api: already cloned'
        }
        'web' {
            return New-DhResult -Success $true -Message 'web: already cloned'
        }
        'ops' {
            return New-DhResult -Success $true `
                -Severity 'warning' `
                -Message 'ops clone slow — retried once' `
                -FixCommand 'git clone https://github.com/fellwork/ops.git --depth 1'
        }
    }
}

# ── Phase 2: Single — "Check prerequisites" ───────────────────────────────────
# Returns two alerts (warnings).
# Alert 1: wrangler not installed (FixCommand present) → issue [2]
# Alert 2: node version too old (no FixCommand)       → issue [3]

$plan = Add-DhSinglePhase -Plan $plan -Name 'Check prerequisites' -Action {
    Start-Sleep -Milliseconds 500   # simulate prerequisite check
    return New-DhResult -Success $true -Alerts @(
        New-DhAlert -Severity 'warning' `
            -Message 'wrangler not installed' `
            -FixCommand 'npm install -g wrangler'
        New-DhAlert -Severity 'warning' `
            -Message 'node version is 18, recommend 20'
            # intentionally NO -FixCommand to exercise "No command to copy" path
    )
}

# ── Phase 3: Single — "Run migrations" ────────────────────────────────────────
# Succeeds with no issues.

$plan = Add-DhSinglePhase -Plan $plan -Name 'Run migrations' -Action {
    Start-Sleep -Milliseconds 300
    return New-DhResult -Success $true -Message 'All migrations applied'
}

# ── Phase 4: Single — "Verify env" ────────────────────────────────────────────
# Fails with a FixCommand. → issue [4]
# This causes plan exit code 1.

$plan = Add-DhSinglePhase -Plan $plan -Name 'Verify env' -Action {
    Start-Sleep -Milliseconds 200
    return New-DhResult -Success $false `
        -Message 'DATABASE_URL missing' `
        -FixCommand 'cp .env.example .env' `
        -Animal 'owl'
}

# ── Run it ────────────────────────────────────────────────────────────────────
Write-Host "Starting Derekh smoke test TUI..." -ForegroundColor Cyan
Write-Host "(Make sure your terminal is at least 80x24 before continuing)" -ForegroundColor DarkGray
Write-Host ""

Invoke-DhPlan -Plan $plan

# The TUI blocks until the user presses q/Esc/Enter.
# $LASTEXITCODE reflects the plan result (1 = had failures).
exit $LASTEXITCODE
```

### Steps

- [ ] **Step 1: Create the file**

  Write the above content verbatim to `c:/git/fellwork/tools/derekh/tests/manual-smoke.ps1`.

  Expected: file created; `$Error` is empty; PowerShell syntax check passes:
  ```powershell
  pwsh -NoProfile -Command "
      \$null = [System.Management.Automation.Language.Parser]::ParseFile(
          'c:/git/fellwork/tools/derekh/tests/manual-smoke.ps1',
          [ref]\$null, [ref]\$errors
      )
      if (\$errors.Count -gt 0) { \$errors | ForEach-Object { Write-Error \$_.Message } }
      else { Write-Host 'PASS: syntax OK' }
  "
  ```

- [ ] **Step 2: Confirm NOT discoverable by run-all.ps1**

  The file is named `manual-smoke.ps1`, not `test-*.ps1`, so `run-all.ps1`'s `Get-ChildItem -Filter 'test-*.ps1'` will not pick it up. Verify:

  ```powershell
  pwsh -NoProfile -File c:/git/fellwork/tools/derekh/tests/run-all.ps1
  ```

  Expected: only the existing `test-*.ps1` suites run; `manual-smoke.ps1` is NOT listed.

- [ ] **Step 3: Verify the fixture plan structure manually (dry-run)**

  Without launching the TUI, verify the plan builds correctly:

  ```powershell
  pwsh -NoProfile -Command "
      Import-Module c:/git/fellwork/tools/derekh/derekh.psd1 -Force
      \$plan = New-DhPlan -Title 'Derekh Smoke Test' -Subtitle '00:00:00'
      \$plan = Add-DhLoopPhase -Plan \$plan -Name 'Clone repos' -Items @('api','web','ops') -Action {}
      \$plan = Add-DhSinglePhase -Plan \$plan -Name 'Check prerequisites' -Action {}
      \$plan = Add-DhSinglePhase -Plan \$plan -Name 'Run migrations' -Action {}
      \$plan = Add-DhSinglePhase -Plan \$plan -Name 'Verify env' -Action {}
      Write-Host ('PASS: plan has ' + \$plan.Phases.Count + ' phases')
      Write-Host ('Phase 1 items: ' + (\$plan.Phases[0].Items -join ', '))
  "
  ```

  Expected output:
  ```
  PASS: plan has 4 phases
  Phase 1 items: api, web, ops
  ```

- [ ] **Step 4: Full manual TUI run**

  Run the smoke test by hand in an 80×24+ terminal:

  ```powershell
  pwsh tests/manual-smoke.ps1
  ```

  Work through the "WHAT TO CHECK" checklist at the top of the file. All 12 items must pass.

- [ ] **Step 5: Commit**

  ```bash
  cd /c/git/fellwork/tools
  git add derekh/tests/manual-smoke.ps1 derekh/lib/render.ps1 derekh/lib/input.ps1 derekh/lib/plan.ps1 derekh/lib/state.ps1
  git commit -m "feat(derekh): Phase G — resize handling + post-completion interactive mode"
  git push
  ```

  Expected: push succeeds; `git log --oneline` shows the new commit; `gh repo view fellwork/tools` reflects the update.

---

## Phase G completion checklist

After all three tasks, verify:

- [ ] Resizing terminal to 40×10 while a plan runs shows the "Terminal too small" message within ~200ms
- [ ] Resizing back to ≥80×24 restores the full TUI without corruption
- [ ] `$DerekhState.Paused` is `$true` while terminal is too small; no new actions start during that window
- [ ] Ctrl+C from the "too small" state exits cleanly (terminal restored, exit code 130)
- [ ] After plan completes, footer reads `[q] quit  [1-9] copy fix command`
- [ ] Issues 1-9 show `[N]` accent-colored prefix in the issues pane
- [ ] Issues 10+ (if any) show no prefix, just a 4-space indent
- [ ] Pressing `2` with a FixCommand-bearing issue copies to clipboard and flashes "Copied to clipboard" for ~1 second
- [ ] Pressing `3` on an issue with no FixCommand flashes "No command to copy" for ~1 second
- [ ] Footer reverts correctly after each flash WITHOUT blocking input
- [ ] Pressing `q` (or `Esc` or `Enter`) exits cleanly: alternate buffer dismissed, cursor visible, correct exit code
- [ ] `pwsh tests/run-all.ps1` still exits 0 — `manual-smoke.ps1` is NOT picked up by the runner
- [ ] `manual-smoke.ps1` syntax check passes (parser error count = 0)
- [ ] The "WHAT TO CHECK" block in `manual-smoke.ps1` has been walked through by hand by a human engineer

**Phase H entry condition:** all checklist items above pass. Phase H adds `tools` to `bootstrap/repos.psd1` and the derekh-detection block to `bootstrap.ps1`.
