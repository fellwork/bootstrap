# fellwork-bootstrap

One-command setup for a fresh Fellwork dev workspace.

## Quick start

```powershell
git clone https://github.com/fellwork/bootstrap.git
cd bootstrap
./bootstrap.ps1
```

The script will clone the seven Fellwork repositories as siblings under the parent
directory, run `proto install` per repo to land pinned toolchain versions, validate
other prereqs, and scaffold env files.

## Prerequisites

You must have these installed before running bootstrap:

- **PowerShell 7+** — https://github.com/PowerShell/PowerShell
- **git** — any recent version
- **proto** — https://moonrepo.dev/proto

Bootstrap installs these automatically via proto (using each repo's `.prototools`):

- rust, node, bun, moon

Bootstrap validates these (does not install — install yourself if missing):

- docker (must have running daemon)
- supabase CLI
- psql (or use the docker-exec workaround documented in api/CLAUDE.md)
- wrangler
- flyctl (optional)
- gh (optional)

## What gets cloned

See `repos.psd1` for the canonical allowlist. Currently:

- `api` — Rust/Axum backend
- `web` — Nuxt frontend
- `ops` — dev tooling + wiki
- `lint` — shared linting config
- `scribe` — reactive DOM Vue/Nuxt with AI as first-class consumer
- `shared-configs` — shared config files
- `tsconfig` — shared TypeScript config

## Flags

- `--help` — show usage
- `--no-color` — disable color output (also respects `NO_COLOR` env var)
- `--ascii` — force ASCII fallback for glyphs and art

## Exit codes

- `0` — all clean
- `1` — warnings only (optional tools missing, env files need filling)
- `2` — hard failures

## Re-running

Bootstrap is idempotent. Running it twice produces the same output the second time
if nothing changed. If something fails, fix the issue and rerun — the script picks
up where it left off.

## Tests

The test suite lives in `tests/` — 658 assertions across 7 suites covering unit
behaviors, layout invariants, snapshot regressions, and end-to-end script runs.

### Run everything

```powershell
cd bootstrap
pwsh tests/run-all.ps1
```

Output prints a per-suite summary; failing tests are surfaced inline with their
`FAIL:` lines so you don't have to re-run to see what broke. Full suite runs in
~85s (most of it is `test-e2e` invoking the real `bootstrap.ps1` against your
sibling repos).

Useful flags:

- `-Bail` — stop on first failing suite (fast feedback during dev)
- `-Verbose` — stream every suite's full output (PASS lines included)

### Run a single suite

```powershell
pwsh -NoProfile -File tests/test-ui.ps1
```

Available suites: `test-ui`, `test-animals`, `test-prereqs`, `test-repos`,
`test-layout`, `test-snapshots`, `test-e2e`.

### Fast dev loop (skip the slow e2e)

```powershell
'test-ui','test-animals','test-prereqs','test-repos','test-layout','test-snapshots' |
    ForEach-Object { pwsh -NoProfile -File "tests/$_.ps1" }
```

Runs the first 6 suites in ~13s. Use this while iterating; run the full suite
(including `test-e2e`) before committing.

### What each suite covers

| Suite | Tests | Purpose |
|---|---:|---|
| `test-ui` | 71 | Color/glyph/spinner primitives, capability detection, HSV math |
| `test-animals` | 79 | Registry, phrase lookup, sprite loading, **3-tier width fallback at 80/100 boundaries** |
| `test-prereqs` | 101 | Tool detection, version extraction, docker daemon, full prereq pipeline |
| `test-repos` | 33 | All 4 `Get-RepoState` branches, env-scaffold idempotency, structure validation |
| `test-layout` | 330 | Tree alignment, banner exact-width, side-box equal-row-width, ASCII fallback (zero non-ASCII bytes), no-line-overflow at all 3 width tiers |
| `test-snapshots` | 9 | Visual regression via golden `.txt` files in `tests/snapshots/` |
| `test-e2e` | 35 | Real `bootstrap.ps1` invocation: --help, full run, idempotency, --no-color, --ascii, perf <60s |

### Updating snapshots

If you intentionally change a rendering function and the snapshot tests fail,
regenerate the goldens with:

```powershell
pwsh -NoProfile -Command @'
. ./lib/ui.ps1
. ./lib/animals.ps1
$utf8 = [System.Text.UTF8Encoding]::new($false)
$glyphs = Get-Glyphs -Utf8 $true
# ... regen logic — see commit 77f15f6 for the full block
'@
```

Or just delete the affected `tests/snapshots/<name>.txt` and run the suite once
to see the new output, then carefully review the diff before re-adding the file.

## Spec

See `docs/superpowers/specs/2026-04-25-bootstrap-and-migration-design.md` for the
full design rationale.
