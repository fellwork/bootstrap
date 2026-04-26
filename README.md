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

## Spec

See `docs/superpowers/specs/2026-04-25-bootstrap-and-migration-design.md` for the
full design rationale.
