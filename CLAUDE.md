# fellwork-bootstrap

One-command setup for a fresh Fellwork dev workspace. Clones the seven sibling
repos under a parent directory, runs `proto install` per repo, validates
prereqs, and scaffolds env files.

## Commands

```powershell
./bootstrap.ps1                  # Full bootstrap from a fresh machine
pwsh tests/run-all.ps1           # Run Pester tests
```

## Stack

- PowerShell 7+ (Pester for tests)
- `proto` for pinned toolchains (rust, node, bun, moon)
- `repos.psd1` is the source of truth for which repos get cloned

## Conventions

- Cross-platform PowerShell only — no `cmd.exe` or bash-only constructs.
- Validate, don't install, anything beyond what `proto` covers (PowerShell, git, proto itself).
- Every script must be re-runnable. Detect existing state, skip already-done steps, never destroy uncommitted work.

## gstack

AI dev tooling — headless browser, QA, design review, deploy workflows.

**Install (one-time per machine):**
```bash
git clone --single-branch --depth 1 https://github.com/garrytan/gstack.git ~/.claude/skills/gstack && cd ~/.claude/skills/gstack && ./setup
```

Use `/browse` for all web browsing. Never use `mcp__claude-in-chrome__*` tools directly.

Available skills:
`/office-hours`, `/plan-ceo-review`, `/plan-eng-review`, `/plan-design-review`, `/design-consultation`, `/design-shotgun`, `/design-html`, `/review`, `/ship`, `/land-and-deploy`, `/canary`, `/benchmark`, `/browse`, `/connect-chrome`, `/qa`, `/qa-only`, `/design-review`, `/setup-browser-cookies`, `/setup-deploy`, `/setup-gbrain`, `/retro`, `/investigate`, `/document-release`, `/codex`, `/cso`, `/autoplan`, `/plan-devex-review`, `/devex-review`, `/careful`, `/freeze`, `/guard`, `/unfreeze`, `/gstack-upgrade`, `/learn`

## Agent-Specific Notes

This repository includes a compiled documentation database/knowledgebase at `AGENTS.db`.
For context for any task, you MUST use MCP `agents_search` to look up context including architectural, API, and historical changes.
Treat `AGENTS.db` layers as immutable; avoid in-place mutation utilities unless required by the design.
