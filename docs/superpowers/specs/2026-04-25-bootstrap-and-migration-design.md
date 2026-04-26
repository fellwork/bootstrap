# Fellwork Bootstrap & Folder Migration — Design Spec

**Date:** 2026-04-25
**Status:** Approved (pending user review of this written spec)
**Author:** Shane McGuirt + Claude
**Related:** `c:/git/fellwork/bootstrap/` (target implementation), `c:/git/fellwork/api/CLAUDE.md` (mentions outdated `bun run setup` flow)

---

## Problem

Fellwork's seven active short-name repositories (`api`, `web`, `ops`, `lint`, `scribe`, `shared-configs`, `tsconfig`) live as siblings under `c:/git/fellwork/`. Today there is no orchestrated way to set up a fresh dev workspace. The `api/README.md` and `api/CLAUDE.md` reference an obsolete `fellwork-ops` bootstrap flow (`bun run setup`) that no longer exists in the active repos.

Compounding the problem, three legacy folders (`fellwork-api`, `fellwork-web`, `fellwork-ops`) sit alongside the short-name repos. They hold real in-progress work — feature branches, an active git worktree, and uncommitted UI changes — that has not yet been pushed to origin. They must be reconciled before they can be deleted.

This spec covers two tightly coupled deliverables:
1. **Folder migration** — safely consolidate `fellwork-*` folders into the short-name folders, preserving in-progress work, then delete the legacy folders.
2. **Bootstrap repo** — a new `bootstrap` repo at `c:/git/fellwork/bootstrap/` that orchestrates fresh-machine setup of the seven repos with thorough validation, suggested-fix output, and high-quality terminal UI.

The two are coupled because the bootstrap repo's allowlist and tested end-state both depend on the post-migration layout being canonical.

---

## Scope

**In scope:**
- Migration plan for the three `fellwork-*` folders (push branches, refresh remotes, recreate worktrees, restore uncommitted changes, delete legacy folders).
- Bootstrap PowerShell 7 script that clones the seven repos, validates prereqs, runs `proto install` per repo, scaffolds env files, and reports status with a polished UI (color, hierarchy, animal commentary, ASCII art on errors).
- Updates to `api/CLAUDE.md` and `api/README.md` to reflect the new bootstrap flow.

**Out of scope (deferred to v2+):**
- Bash equivalent of the bootstrap script (Windows-first; bash version can come if other platforms are needed).
- Per-repo first-build automation (`cargo check`, `bun install`, etc.) — script prints suggested commands but does not execute them.
- Self-update of the bootstrap repo before running.
- Interactive `[y/N] apply this fix?` prompts — v1 prints suggested commands; user runs them; reruns bootstrap.
- Tier-4 ASCII art (quadrant/braille). v1 ships tier-3 half-block sprites.
- Auto-generation of bootstrap-aggregated `.prototools` (bootstrap orchestrates per-repo `.prototools`; never owns versions itself).

**Explicit non-goals:**
- Bootstrap is **not** a source of truth for tool versions. Per-repo `.prototools` files own pins. Bootstrap orchestrates; it does not centralize.
- Bootstrap never auto-installs OS packages (psql, docker, supabase CLI). It validates and links install pages. Proto-managed tools (rust, node, bun, moon) are the only auto-installed ones.
- Bootstrap never auto-fixes destructive divergences (wrong origin URL, non-git folder where a repo should be). It reports and exits.

---

## Part 1 — Folder migration

### Current state

| Folder | Remote | Branch | In-flight work |
|---|---|---|---|
| `c:/git/fellwork/fellwork-api` | `github.com/fellwork/fellwork-api.git` (redirects to `fellwork/api`) | `phase-1/chunk-first-schema` | + worktree at `.worktrees/split-fw-resolvers` on `feat/split-fw-resolvers` |
| `c:/git/fellwork/fellwork-web` | `github.com/fellwork/fellwork-web.git` (redirects to `fellwork/web`) | `main` | 485 lines uncommitted: 3 modified Vue files + new `ConceptRail.vue` |
| `c:/git/fellwork/fellwork-ops` | `github.com/fellwork/fellwork-ops.git` (redirects to `fellwork/ops`) | `main` | clean — no migration needed beyond delete |

The `fellwork-*` folders point at *renamed* GitHub repos. The remote URLs still show the old names because GitHub repo renames don't update local clone URLs (GitHub serves redirects but `git remote -v` is unchanged). The short-name folders point at the post-rename URLs directly. **Both folders for each repo talk to the same GitHub repository**.

The in-flight work represents three real efforts:
- Open-source split of the API (translation engine refactor)
- Phase 1 chunk-first schema work
- Concept Rail UI design work in web

### Migration procedure (per `fellwork-*` folder)

For each of the three folders, in this order:

**1. Safety push.** From inside the folder:
   - If branch has unpushed commits → `git push -u origin <branch>`.
   - If working tree has uncommitted changes → stash with `git stash push -m "fellwork-* folder migration WIP"` (we'll unstash later in the new location).
   - If git worktrees exist → push their branches too: `cd .worktrees/<name> && git push -u origin <branch>`.

**2. Refresh short-name folder remote.** From the corresponding short-name folder:
   - `git remote set-url origin https://github.com/fellwork/<short>.git` (cosmetic; replaces the redirect-served old URL with the canonical new one).
   - `git fetch --all --prune` so the short-name folder sees all the just-pushed branches.

**3. Recreate worktrees.** For each worktree that existed in the legacy folder:
   - `cd c:/git/fellwork/<short> && git worktree add .worktrees/<name> <branch>` — recreates the same branch in the same relative path.

**4. Restore uncommitted changes.** Use the patch + tar approach (not `git stash pop` — stashes are local to a clone's reflog and don't transfer between folders even with shared origin).

   **Procedure** (only `fellwork-web` needs this in the current state, but the procedure generalizes):
   ```
   # In the legacy folder:
   cd c:/git/fellwork/fellwork-web
   git diff > /tmp/web-migration.patch
   git ls-files --others --exclude-standard | tar -czf /tmp/web-migration-untracked.tgz -T -

   # In the new short-name folder:
   cd c:/git/fellwork/web
   git apply /tmp/web-migration.patch
   tar -xzf /tmp/web-migration-untracked.tgz
   ```
   This preserves both modified files (the diff) and untracked files like the new `ConceptRail.vue` (the tar).

**5. Verify.** From inside the short-name folder:
   - `git status` matches what was in the legacy folder.
   - `git branch -a` shows all branches that existed.
   - `git worktree list` shows recreated worktrees.

**6. Delete legacy folder.** Only after verification:
   - `rm -rf c:/git/fellwork/fellwork-<name>`.

### Migration ordering

Migrate in this order (lowest risk → highest):
1. `fellwork-ops` (clean, just delete after fetch verifies short-name folder is current)
2. `fellwork-web` (uncommitted changes; medium complexity)
3. `fellwork-api` (worktree + extra branches; highest complexity)

### Migration safety guarantees

- No `rm -rf` runs until after the corresponding short-name folder has been verified to contain everything that was in the legacy folder.
- Every commit pushed in step 1 is recoverable from origin even if the local folder is later destroyed.
- Stashes/patches are stored in `/tmp/` so they survive the legacy folder being deleted.
- Each step prints what it's about to do *before* doing it; user can abort at any point.

---

## Part 2 — Bootstrap repo

### Repo structure

```
c:/git/fellwork/bootstrap/
├── README.md
├── bootstrap.ps1
├── repos.psd1                    # Allowlist of repos to clone
├── lib/
│   ├── ui.ps1                    # Color, glyphs, boxes, tree-drawing
│   ├── animals.ps1               # Animal registry + ASCII art loader
│   ├── prereqs.ps1               # Prereq validation logic
│   └── repos.ps1                 # Clone/validate per-repo logic
├── animals/
│   ├── raccoon.ansi              # Tier-3 half-block sprite, ~30×20
│   ├── hedgehog.ansi
│   ├── octopus.ansi
│   ├── owl.ansi
│   ├── fox.ansi
│   └── turtle.ansi
├── docs/
│   └── superpowers/specs/
│       └── 2026-04-25-bootstrap-and-migration-design.md  # this file
└── .gitignore
```

### Bootstrap-time prerequisites

The user must have these installed *before* running `bootstrap.ps1`:
- `git` (any recent version)
- `proto` (≥0.40) — installs from https://moonrepo.dev/proto

Everything else (`rust`, `node`, `bun`, `moon`) is installed by `proto install` reading per-repo `.prototools` files.

### Other prereqs (validated, never auto-installed)

These are checked and warned about; bootstrap does not install them:
- `docker` (must have running daemon — actively check via `docker info`)
- `supabase` CLI (`supabase --version`)
- `psql` (or document the `docker exec supabase_db_fellwork psql ...` workaround per existing CLAUDE.md guidance)
- `wrangler` (Cloudflare Workers CLI)
- `flyctl` (optional — deploy-only; warn but don't fail)
- `gh` (optional — convenience; warn but don't fail)

### Repo allowlist (`repos.psd1`)

```powershell
@{
    repos = @(
        @{ name = 'api';            org = 'fellwork'; branch = 'main'; description = 'Rust/Axum backend' }
        @{ name = 'web';            org = 'fellwork'; branch = 'main'; description = 'Nuxt frontend' }
        @{ name = 'ops';            org = 'fellwork'; branch = 'main'; description = 'Dev tooling + wiki' }
        @{ name = 'lint';           org = 'fellwork'; branch = 'main'; description = 'Shared linting config' }
        @{ name = 'scribe';         org = 'fellwork'; branch = 'main'; description = 'Reactive DOM Vue/Nuxt with AI as first-class consumer' }
        @{ name = 'shared-configs'; org = 'fellwork'; branch = 'main'; description = 'Shared config files' }
        @{ name = 'tsconfig';       org = 'fellwork'; branch = 'main'; description = 'Shared TypeScript config' }
    )
}
```

Adding/removing a repo is a one-line edit. Outliers never auto-pulled.

### Script flow

```
1. Self-check
   ├─ Confirm running from c:/git/fellwork/bootstrap
   ├─ Handle --help, --no-color, --ascii flags
   └─ Detect terminal width and capabilities (truecolor, UTF-8)

2. Bootstrap-time prereq check
   ├─ git present? → ✓ or hard fail with install URL
   └─ proto present? → ✓ or hard fail with install URL

3. Clone phase (per repo in repos.psd1)
   ├─ Sibling exists + is git repo + origin matches → ✓ skip
   ├─ Sibling exists + is git repo + origin DOES NOT match → ✗ ASCII raccoon "wrong origin"
   ├─ Sibling exists + NOT a git repo → ✗ ASCII raccoon "non-git folder in the way"
   └─ Sibling absent → git clone → validate landed on expected branch

4. Toolchain phase (per successfully-cloned repo)
   └─ cd <repo> && proto install (uses repo's own .prototools)

5. Other-prereq validation
   ├─ docker daemon running? → ✓/⚠
   ├─ supabase CLI present? → ✓/⚠
   ├─ psql present? → ✓/⚠ (workaround documented)
   ├─ wrangler present? → ✓/⚠
   ├─ flyctl present? → ✓ or skip-noted
   └─ gh present? → ✓ or skip-noted

6. Env scaffolding (per cloned repo)
   ├─ Find apps/*/.env.example files
   └─ For each: if no .env beside it → cp + warn "fill in secrets"

7. Post-clone structural validation
   ├─ api/Cargo.toml present?
   ├─ web/package.json present?
   └─ etc.

8. Summary report
   ├─ ✓ N repos cloned and validated
   ├─ ⚠ N optional concerns
   ├─ ✗ N hard failures (with ASCII art per failure)
   └─ Next-steps printed (which .env files to fill, what to run next)
```

### Idempotency

Every step checks current state first. Running the script twice produces identical output the second run if nothing changed in between. Resumability is implicit: after fixing an error and rerunning, the script picks up where it left off because completed steps detect their own completion.

### Failure → fix → resume loop

Each ✗ failure prints:
1. ASCII art animal (chosen by error category)
2. A speech-box explaining what's wrong in plain language
3. A copy-pasteable suggested fix command
4. The reminder: "Fix the issue above and rerun `./bootstrap.ps1` — I'll pick up where I left off."

Bootstrap continues processing remaining steps after a failure (does not fail-fast). All errors collected and shown together at the end so the user can fix multiple in one pass.

### Exit codes

- `0` — all clean
- `1` — warnings only (optional tools missing, env files need filling)
- `2` — hard failures (any ✗)

---

## Part 3 — UI design

### Color (PowerShell 7 truecolor)

Semantic palette:
- **Green** (`#7eb877`) — success, ✓
- **Yellow** (`#d4a84b`) — warning, ⚠
- **Red** (`#c25b56`) — failure, ✗
- **Cyan** (`#5fafd7`) — info, headings, →
- **Dim gray** (`#6c6c6c`) — secondary text, timestamps
- **Bold white** — section titles
- **Rainbow** — see "Rainbow motion" below

Auto-disabled when:
- `NO_COLOR` env var is set (standard convention)
- `--no-color` flag passed
- stdout is redirected (not a TTY)

Falls back to 256-color mode on terminals without truecolor.

### Glyphs

Status icons (UTF-8): `✓ ✗ ⚠ → … ●`
Tree drawing: `├─ └─ │ ─ ╭ ╮ ╰ ╯`
Section rules: `═══` (heavy double) for top/bottom of run; `───` (light) for sub-sections.

ASCII fallback (auto on non-UTF-8 terminals or `--ascii` flag):
- Status: `[ok] [!!] [??] -> ...`
- Tree: `+- '- |`
- Rules: `=== ---`

### Layout

**Top banner** (one-time, run start):
```
═══════════════════════════════════════════════════════════
  Fellwork Bootstrap                            12:34:01
═══════════════════════════════════════════════════════════
```

**Section header** (between major phases):
```
─────  Cloning repositories  ─────
```

**Per-step lines** with tree hierarchy:
```
api
├─ ✓ already cloned, origin matches
└─ ✓ on branch main

web
├─ ⠹ cloning from github.com/fellwork/web…
│  └─ Receiving objects: 67% (2104/3140)
└─ (pending)
```

**Summary box** (one-time, run end):
```
─────  Summary  ─────
✓ 6 repos cloned and validated
⚠ 1 optional tool missing
✗ 1 hard failure
```

### Hierarchy rules ("collapse on success, expand on detail")

- Successful sub-steps collapse: section line shows `✓ Toolchain installed (12.4s)` rather than expanding all sub-tools.
- Failures auto-expand to show full sub-output.
- Pending steps grouped: `ops, lint, scribe, shared-configs, tsconfig (pending)` rather than 5 separate lines.

### Motion

**Spinner** (braille frames `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`):
- Used during long ops only: `git clone`, `proto install`.
- Auto-suppressed when stdout is non-TTY.
- One spinner at a time (no nested concurrent spinners).

**Rainbow motion** (truecolor hue cycle):
- Active long-op spinner glyph cycles hue per frame.
- Final summary headline shimmers rainbow **only on clean exit**. Warnings/failures keep semantic colors.
- Used nowhere else. Restraint preserves impact.

### Side-box commentary (moderate density)

Right-aligned rounded boxes with emoji animal + one-liner. ~one per major section if there's something worth saying. Examples:

```
api
├─ ✓ already cloned, origin matches      ╭──────────────────────────────╮
└─ ✓ on branch main                      │ 🦊  this one's the rust       │
                                          │     monorepo — biggest clone │
                                          ╰──────────────────────────────╯
```

Falls back to inline below the line on terminals < 100 cols:
```
└─ ✓ on branch main
🦊  this one's the rust monorepo — biggest clone
```

Animal voices (canned phrases written by Claude during implementation). The first six match the ASCII-art roster in Part 3 (errors). Bee and otter are emoji-only additions for non-error side-commentary:

**Sprite animals (also used for ✗ ASCII art):**
- 🦊 fox — clever observations, repo-specific notes, "clever fix available"
- 🦉 owl — pro tips, post-summary advice, "you should know"
- 🐢 turtle — "no rush" notes for optional/deferred things
- 🐙 octopus — dependency-tangle warnings
- 🦔 hedgehog — security/secrets reminders
- 🦝 raccoon — "found leftover state" / config mismatch notes

**Emoji-only animals (side-boxes only, never as ASCII art):**
- 🐝 bee — "busy / running" notes near long ops
- 🦦 otter — celebration on full success at end

### ASCII art animals (tier-3 half-block sprites)

**Tier:** Half-block (`▀`) truecolor sprites at ~30 cells × 20 rows = effective 30×40 pixel resolution.
**Style:** Stardew Valley pixel art aesthetic — muted earth tones, soft pastel highlights, slight golden warmth.
**Source:** Curated by Claude during implementation. Each sprite ships as `bootstrap/animals/<name>.ansi` — a plain-text ANSI escape-code file, ~5-10KB each. File header comment includes source attribution, dimensions, and regen command.

**Six animals, mapped 1:1 to error categories:**
- 🦝 raccoon — "found leftover state / configuration mismatch" (wrong origin, existing folder issues)
- 🦔 hedgehog — "security/secrets" (missing .env, would-be secret leak)
- 🐙 octopus — "dependency tangle" (missing tool that other tools need)
- 🦉 owl — "you should know" (deprecation, version mismatch)
- 🦊 fox — "clever fix available" (one-line workaround exists)
- 🐢 turtle — "no rush, but…" (optional/deferred)

**Display rules:**
- ASCII art only appears for ✗ hard failures (not for ⚠ warnings, which use side-boxes).
- Animal is chosen by error category, not random. User learns the mapping.
- Speech box contains: plain-language explanation + suggested fix command + "rerun bootstrap" reminder.

**Width fallback:**
- ≥ 100 cols: full art + side speech-box
- 80–99 cols: full art, speech box below it
- < 80 cols: emoji only + inline speech (no art)

**Generation pipeline:**
- Source: 6 PNG sprites (~32×40 each) sourced from public-domain pixel-art galleries or commissioned/AI-generated in Stardew style.
- Convert each via `chafa --size 30x20 --symbols half --colors truecolor <input>.png > animals/<name>.ansi`.
- Commit the `.ansi` files. PNG sources stored under `animals/sources/` for regen.

---

## Part 4 — Doc updates

After bootstrap is built and migration is complete:

**`api/CLAUDE.md`** — replace this block:
```
Companion repos: **fellwork-web** (Nuxt frontend) and **fellwork-ops** (dev tooling + wiki).
See `README.md` for the sibling-clone layout.
```
with a reference to the new bootstrap flow and the seven-repo layout.

**`api/README.md`** — replace this block:
```
git clone https://github.com/fellwork/fellwork-ops.git
git clone https://github.com/fellwork/fellwork-web.git
git clone https://github.com/fellwork/fellwork-api.git
cd fellwork-ops
bun install
bun run setup
```
with:
```
git clone https://github.com/fellwork/bootstrap.git
cd bootstrap
./bootstrap.ps1
```

Same updates may apply to `web/README.md` and `ops/README.md` if they reference the old flow — check during implementation.

---

## Test/validation plan

**Migration validation:**
- After each `fellwork-*` folder migration, run `git status`, `git branch -a`, and `git worktree list` in the corresponding short-name folder. Compare against pre-migration capture.
- Specifically for web: `diff <(cd fellwork-web && git diff) <(cd web && git diff)` should be empty after migration.
- Specifically for api: confirm `c:/git/fellwork/api/.worktrees/split-fw-resolvers` exists and is on `feat/split-fw-resolvers`.

**Bootstrap validation:**
- **Fresh-clone simulation** — move the seven repos to a sandbox dir, run `bootstrap.ps1` from a fresh `bootstrap/` clone, confirm all seven repos clone, proto installs, prereqs validate.
- **Idempotency test** — run `bootstrap.ps1` twice in a row, confirm second run is fully ✓ with no actions taken.
- **Failure-recovery test** — manually break one prereq (e.g., uninstall `wrangler`), run, confirm ✗ with raccoon art and suggested fix; reinstall; rerun; confirm ✓.
- **Terminal-width test** — run in 120-col, 90-col, and 70-col terminals; confirm graceful fallback at each tier.
- **NO_COLOR test** — `NO_COLOR=1 ./bootstrap.ps1` produces clean text output suitable for log capture.

---

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Migration loses the 485 lines of uncommitted web work | Patch + tar approach (Part 1, step 4) preserves both modified files and untracked files; verified with `git diff` comparison |
| Bootstrap script breaks on a future Cascadia/Windows Terminal version | Sprite files have regen commands in their headers; chafa pipeline can re-run |
| Per-repo `.prototools` versions drift across repos and create incompatible toolchains | Out of scope for bootstrap to resolve; each repo's tests catch its own version issues. Could add a `--check-versions` flag in v2 to surface inter-repo mismatches |
| User has none of the prereqs and bootstrap can't get them past step 2 | Hard-fail with install URLs is the right answer; bootstrap can't install proto for them |
| ASCII art looks bad on smaller fonts / unusual terminal configs | Three-tier width fallback (full → no-side-box → emoji-only) covers most cases; `--ascii` flag is the ultimate fallback |

---

## Open questions

None at spec time. All design decisions resolved in brainstorming session.

---

## Implementation order

1. Migration of `fellwork-*` folders (Part 1) — must complete before bootstrap can be tested against canonical state.
2. Bootstrap repo scaffolding (`bootstrap.ps1` skeleton, `repos.psd1`, README).
3. UI library (`lib/ui.ps1`) — color, glyphs, tree drawing, spinner, side-boxes.
4. Animal sprites — source PNGs, run chafa pipeline, commit `.ansi` files + animal registry.
5. Prereq validation (`lib/prereqs.ps1`).
6. Clone phase (`lib/repos.ps1`).
7. Proto install integration.
8. Env scaffolding + structural validation.
9. Summary + failure-fix output with ASCII art rendering.
10. Doc updates in `api/`, `web/`, `ops/`.
11. End-to-end testing per "Test/validation plan."
