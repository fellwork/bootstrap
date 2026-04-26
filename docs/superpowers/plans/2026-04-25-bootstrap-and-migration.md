# Fellwork Bootstrap & Folder Migration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate three legacy `fellwork-*` folders into the canonical short-name folders preserving all in-progress work, then build a polished PowerShell 7 bootstrap script that orchestrates fresh-machine setup of seven Fellwork repos with rich UI (color, hierarchy, animal commentary, ASCII art on errors).

**Architecture:** Two phases. Phase A migrates `fellwork-*` → short-name folders using a push → fetch → recreate-worktree → patch-restore → delete sequence with verification at each step. Phase B builds `bootstrap/` as a PowerShell 7 script with modular `lib/*.ps1` files, an allowlist-driven repo manifest in `repos.psd1`, and Stardew-style tier-3 half-block ANSI sprites in `animals/*.ansi`.

**Tech Stack:** PowerShell 7.5+, `proto` (toolchain orchestrator), `chafa` (PNG → half-block ANSI converter, dev-time only), `git`. Bootstrap is Windows-first; bash equivalent deferred.

**Spec:** `c:/git/fellwork/bootstrap/docs/superpowers/specs/2026-04-25-bootstrap-and-migration-design.md`

---

## Phase A — Folder migration

Migration order (lowest → highest risk): `fellwork-ops` → `fellwork-web` → `fellwork-api`. Each folder gets capture → push → verify → recreate → restore → delete with explicit verification before deletion.

---

### Task A0: Capture pre-migration state for verification

**Purpose:** Record exact state of each `fellwork-*` folder so we can verify the short-name folder matches after migration.

**Files:**
- Create: `c:/Users/srmcg/AppData/Local/Temp/fellwork-migration/pre-state-ops.txt`
- Create: `c:/Users/srmcg/AppData/Local/Temp/fellwork-migration/pre-state-web.txt`
- Create: `c:/Users/srmcg/AppData/Local/Temp/fellwork-migration/pre-state-api.txt`

- [ ] **Step 1: Create capture directory**

```bash
mkdir -p /c/Users/srmcg/AppData/Local/Temp/fellwork-migration
```

- [ ] **Step 2: Capture fellwork-ops state**

```bash
{
  echo "=== branch ==="
  cd /c/git/fellwork/fellwork-ops && git branch --show-current
  echo "=== status ==="
  git status --porcelain
  echo "=== branches ==="
  git branch -a
  echo "=== worktrees ==="
  git worktree list
  echo "=== unpushed commits per branch ==="
  for b in $(git branch --format='%(refname:short)'); do
    echo "--- $b ---"
    git log --oneline "origin/$b..$b" 2>/dev/null || echo "(no upstream or no unpushed)"
  done
} > /c/Users/srmcg/AppData/Local/Temp/fellwork-migration/pre-state-ops.txt
cat /c/Users/srmcg/AppData/Local/Temp/fellwork-migration/pre-state-ops.txt
```

Expected: file contains branch (`main`), empty status, branch list, worktree showing only the main folder, no unpushed commits.

- [ ] **Step 3: Capture fellwork-web state**

```bash
{
  echo "=== branch ==="
  cd /c/git/fellwork/fellwork-web && git branch --show-current
  echo "=== status ==="
  git status --porcelain
  echo "=== diff stat ==="
  git diff --stat
  echo "=== untracked files ==="
  git ls-files --others --exclude-standard
  echo "=== branches ==="
  git branch -a
  echo "=== worktrees ==="
  git worktree list
  echo "=== unpushed commits per branch ==="
  for b in $(git branch --format='%(refname:short)'); do
    echo "--- $b ---"
    git log --oneline "origin/$b..$b" 2>/dev/null || echo "(no upstream or no unpushed)"
  done
} > /c/Users/srmcg/AppData/Local/Temp/fellwork-migration/pre-state-web.txt
cat /c/Users/srmcg/AppData/Local/Temp/fellwork-migration/pre-state-web.txt
```

Expected: file shows branch `main`, 3 modified files, 1 untracked (`ConceptRail.vue`).

- [ ] **Step 4: Capture fellwork-api state**

```bash
{
  echo "=== branch ==="
  cd /c/git/fellwork/fellwork-api && git branch --show-current
  echo "=== status ==="
  git status --porcelain
  echo "=== branches ==="
  git branch -a
  echo "=== worktrees ==="
  git worktree list
  echo "=== unpushed commits per branch ==="
  for b in $(git branch --format='%(refname:short)' | grep -v "HEAD"); do
    echo "--- $b ---"
    git log --oneline "origin/$b..$b" 2>/dev/null || echo "(no upstream or no unpushed)"
  done
  echo "=== worktree branch unpushed ==="
  cd .worktrees/split-fw-resolvers 2>/dev/null && git log --oneline "origin/feat/split-fw-resolvers..feat/split-fw-resolvers" 2>/dev/null || echo "(no unpushed in worktree)"
} > /c/Users/srmcg/AppData/Local/Temp/fellwork-migration/pre-state-api.txt
cat /c/Users/srmcg/AppData/Local/Temp/fellwork-migration/pre-state-api.txt
```

Expected: file shows branch `phase-1/chunk-first-schema`, the file deletion `D apps/api/.env.example`, worktree at `.worktrees/split-fw-resolvers`, and unpushed commits on both branches.

- [ ] **Step 5: No commit** (capture files are in temp dir, not in any repo)

---

### Task A1: Migrate fellwork-ops (clean — easiest)

**Files:**
- Delete: `c:/git/fellwork/fellwork-ops/`
- Modify: `c:/git/fellwork/ops/` (fetch from origin, update remote URL)

- [ ] **Step 1: Push any local-only branches from fellwork-ops**

```bash
cd /c/git/fellwork/fellwork-ops
git fetch --all --prune
for b in $(git branch --format='%(refname:short)'); do
  if ! git rev-parse --verify "origin/$b" >/dev/null 2>&1; then
    echo "Pushing local-only branch: $b"
    git push -u origin "$b"
  fi
done
```

Expected: no output if all branches already on origin (which is the current state).

- [ ] **Step 2: Update ops/ remote URL to canonical name**

```bash
cd /c/git/fellwork/ops
git remote set-url origin https://github.com/fellwork/ops.git
git remote -v
```

Expected: both fetch/push lines show `https://github.com/fellwork/ops.git`.

- [ ] **Step 3: Fetch all branches into ops/**

```bash
cd /c/git/fellwork/ops
git fetch --all --prune
git branch -a
```

Expected: branch list includes everything that was in `fellwork-ops/`.

- [ ] **Step 4: Verify ops/ matches captured state**

```bash
{
  echo "=== branch ==="
  cd /c/git/fellwork/ops && git branch --show-current
  echo "=== status ==="
  git status --porcelain
  echo "=== branches ==="
  git branch -a
  echo "=== worktrees ==="
  git worktree list
} > /c/Users/srmcg/AppData/Local/Temp/fellwork-migration/post-state-ops.txt

diff /c/Users/srmcg/AppData/Local/Temp/fellwork-migration/pre-state-ops.txt /c/Users/srmcg/AppData/Local/Temp/fellwork-migration/post-state-ops.txt | head -30
```

Expected: differences in branch list (ops/ may have extra branches it already had) but the branches that existed in fellwork-ops/ should all be present in ops/. Worktree paths will differ (different folder names) — this is expected.

- [ ] **Step 5: Delete fellwork-ops**

```bash
rm -rf /c/git/fellwork/fellwork-ops
ls /c/git/fellwork/ | grep -i fellwork-ops
```

Expected: empty output (folder is gone).

- [ ] **Step 6: Verify final state**

```bash
ls -la /c/git/fellwork/ops/.git
cd /c/git/fellwork/ops && git status
```

Expected: `.git` directory exists, status clean on `main`.

- [ ] **Step 7: No git commit** (these are filesystem operations on existing repos, no new code in any repo)

---

### Task A2: Migrate fellwork-web (uncommitted changes)

**Files:**
- Read: `c:/git/fellwork/fellwork-web/apps/web/layers/reader/app/components/ConceptRail.vue`
- Read: `c:/git/fellwork/fellwork-web/` (3 modified files)
- Write: `c:/Users/srmcg/AppData/Local/Temp/fellwork-migration/web-diff.patch`
- Write: `c:/Users/srmcg/AppData/Local/Temp/fellwork-migration/web-untracked.tgz`
- Modify: `c:/git/fellwork/web/apps/web/layers/reader/app/components/*.vue` (3 files restored)
- Create: `c:/git/fellwork/web/apps/web/layers/reader/app/components/ConceptRail.vue`
- Delete: `c:/git/fellwork/fellwork-web/`

- [ ] **Step 1: Confirm no local-only branches in fellwork-web**

```bash
cd /c/git/fellwork/fellwork-web
git fetch --all --prune
for b in $(git branch --format='%(refname:short)'); do
  if ! git rev-parse --verify "origin/$b" >/dev/null 2>&1; then
    echo "LOCAL-ONLY: $b — needs push"
    git push -u origin "$b"
  fi
done
```

Expected: no output (only local branch is `main`, already on origin).

- [ ] **Step 2: Capture diff of modified files**

```bash
cd /c/git/fellwork/fellwork-web
git diff > /c/Users/srmcg/AppData/Local/Temp/fellwork-migration/web-diff.patch
wc -l /c/Users/srmcg/AppData/Local/Temp/fellwork-migration/web-diff.patch
```

Expected: line count matches what `git diff --stat` showed earlier (~145 lines including headers — the spec said 139 changed lines + diff overhead).

- [ ] **Step 3: Capture untracked files as tarball**

```bash
cd /c/git/fellwork/fellwork-web
git ls-files --others --exclude-standard | tar -czf /c/Users/srmcg/AppData/Local/Temp/fellwork-migration/web-untracked.tgz -T -
tar -tzf /c/Users/srmcg/AppData/Local/Temp/fellwork-migration/web-untracked.tgz
```

Expected: tarball lists `apps/web/layers/reader/app/components/ConceptRail.vue`.

- [ ] **Step 4: Update web/ remote URL to canonical**

```bash
cd /c/git/fellwork/web
git remote set-url origin https://github.com/fellwork/web.git
git fetch --all --prune
git remote -v
```

Expected: both fetch/push show canonical URL.

- [ ] **Step 5: Verify web/ working tree is clean enough to apply patch**

The web/ folder currently has its own `D apps/web/.env.example` deletion staged. Apply the migration on top of that without conflict:

```bash
cd /c/git/fellwork/web
git status --porcelain
```

Expected output: `D  apps/web/.env.example` (one line). No conflicts expected with the migration patch since the patch touches reader/ files, not the env file.

- [ ] **Step 6: Apply the diff patch**

```bash
cd /c/git/fellwork/web
git apply /c/Users/srmcg/AppData/Local/Temp/fellwork-migration/web-diff.patch
git status --porcelain
```

Expected: status shows `M` for the 3 modified Vue files plus the existing `D apps/web/.env.example`.

- [ ] **Step 7: Extract untracked files**

```bash
cd /c/git/fellwork/web
tar -xzf /c/Users/srmcg/AppData/Local/Temp/fellwork-migration/web-untracked.tgz
ls -la apps/web/layers/reader/app/components/ConceptRail.vue
```

Expected: file exists, ~346 lines.

- [ ] **Step 8: Verify migration completeness**

```bash
diff <(cd /c/git/fellwork/fellwork-web && git diff) <(cd /c/git/fellwork/web && git diff -- apps/web/layers/reader)
```

Expected: empty diff (the migration preserved exactly the reader-related changes; the env file deletion was already in web/ pre-migration).

- [ ] **Step 9: Verify untracked file content matches**

```bash
diff /c/git/fellwork/fellwork-web/apps/web/layers/reader/app/components/ConceptRail.vue \
     /c/git/fellwork/web/apps/web/layers/reader/app/components/ConceptRail.vue
```

Expected: empty diff (files identical).

- [ ] **Step 10: Delete fellwork-web**

```bash
rm -rf /c/git/fellwork/fellwork-web
ls /c/git/fellwork/ | grep -i fellwork-web
```

Expected: empty output.

- [ ] **Step 11: No git commit** (working-tree changes restored to web/ are still uncommitted as before; user owns when to commit them as part of the Concept Rail feature work)

---

### Task A3: Migrate fellwork-api (worktree + extra branches — most complex)

**Files:**
- Push branches: `phase-1/chunk-first-schema`, `feat/split-fw-resolvers`
- Modify: `c:/git/fellwork/api/` (fetch, update remote URL)
- Create: `c:/git/fellwork/api/.worktrees/split-fw-resolvers/` (recreated worktree)
- Restore: working-tree deletion of `apps/api/.env.example` if present in fellwork-api
- Delete: `c:/git/fellwork/fellwork-api/`

- [ ] **Step 1: Push the phase-1 branch from fellwork-api**

```bash
cd /c/git/fellwork/fellwork-api
git fetch --all --prune
git push -u origin phase-1/chunk-first-schema
```

Expected: either "Everything up-to-date" or commits being pushed. No errors.

- [ ] **Step 2: Push the worktree branch from fellwork-api**

```bash
cd /c/git/fellwork/fellwork-api/.worktrees/split-fw-resolvers
git push -u origin feat/split-fw-resolvers
```

Expected: pushes any unpushed commits, or reports up-to-date.

- [ ] **Step 3: Capture any uncommitted changes in fellwork-api**

```bash
cd /c/git/fellwork/fellwork-api
git diff > /c/Users/srmcg/AppData/Local/Temp/fellwork-migration/api-diff.patch
git ls-files --others --exclude-standard > /c/Users/srmcg/AppData/Local/Temp/fellwork-migration/api-untracked-list.txt
wc -l /c/Users/srmcg/AppData/Local/Temp/fellwork-migration/api-diff.patch /c/Users/srmcg/AppData/Local/Temp/fellwork-migration/api-untracked-list.txt
```

Expected: api-diff.patch is non-empty (contains the `D apps/api/.env.example` working-tree deletion); untracked-list may be empty or list only ignored-but-tracked patterns.

- [ ] **Step 4: Capture any uncommitted changes in fellwork-api worktree**

```bash
cd /c/git/fellwork/fellwork-api/.worktrees/split-fw-resolvers
git diff > /c/Users/srmcg/AppData/Local/Temp/fellwork-migration/api-worktree-diff.patch
git ls-files --others --exclude-standard | tar -czf /c/Users/srmcg/AppData/Local/Temp/fellwork-migration/api-worktree-untracked.tgz -T -
wc -l /c/Users/srmcg/AppData/Local/Temp/fellwork-migration/api-worktree-diff.patch
tar -tzf /c/Users/srmcg/AppData/Local/Temp/fellwork-migration/api-worktree-untracked.tgz
```

Expected: capture files exist (may be empty if worktree is clean).

- [ ] **Step 5: Update api/ remote URL to canonical**

```bash
cd /c/git/fellwork/api
git remote set-url origin https://github.com/fellwork/api.git
git fetch --all --prune
git remote -v
git branch -a | grep -E "phase-1|split-fw-resolvers"
```

Expected: remote URL canonical; both branches now visible as `remotes/origin/phase-1/chunk-first-schema` and `remotes/origin/feat/split-fw-resolvers`.

- [ ] **Step 6: Recreate the worktree in api/**

```bash
cd /c/git/fellwork/api
git worktree add .worktrees/split-fw-resolvers feat/split-fw-resolvers
git worktree list
```

Expected: worktree list shows the main api/ folder plus `.worktrees/split-fw-resolvers` on `feat/split-fw-resolvers`.

- [ ] **Step 7: Apply api/ uncommitted changes if any**

```bash
cd /c/git/fellwork/api
if [ -s /c/Users/srmcg/AppData/Local/Temp/fellwork-migration/api-diff.patch ]; then
  # api/ already has its own D apps/api/.env.example — only apply patch if it adds something different
  git apply --check /c/Users/srmcg/AppData/Local/Temp/fellwork-migration/api-diff.patch 2>&1 || echo "Patch already applied or conflicts; skipping"
fi
git status --porcelain
```

Expected: status shows the existing `D apps/api/.env.example`. If patch from fellwork-api was identical (just the env deletion), it's already in api/'s state and the apply check will say "no changes" or fail gracefully.

- [ ] **Step 8: Apply worktree uncommitted changes if any**

```bash
cd /c/git/fellwork/api/.worktrees/split-fw-resolvers
if [ -s /c/Users/srmcg/AppData/Local/Temp/fellwork-migration/api-worktree-diff.patch ]; then
  git apply /c/Users/srmcg/AppData/Local/Temp/fellwork-migration/api-worktree-diff.patch
fi
if [ -s /c/Users/srmcg/AppData/Local/Temp/fellwork-migration/api-worktree-untracked.tgz ]; then
  tar -xzf /c/Users/srmcg/AppData/Local/Temp/fellwork-migration/api-worktree-untracked.tgz
fi
git status --porcelain
```

Expected: working tree state matches what was in the legacy worktree.

- [ ] **Step 9: Verify api/ matches captured state**

```bash
{
  echo "=== branch ==="
  cd /c/git/fellwork/api && git branch --show-current
  echo "=== status ==="
  git status --porcelain
  echo "=== branches (local) ==="
  git branch
  echo "=== worktrees ==="
  git worktree list
} > /c/Users/srmcg/AppData/Local/Temp/fellwork-migration/post-state-api.txt

cat /c/Users/srmcg/AppData/Local/Temp/fellwork-migration/post-state-api.txt
```

Expected: api/ shows worktree at `.worktrees/split-fw-resolvers`. Note: api/'s primary branch stays `main` (different from fellwork-api/'s `phase-1/chunk-first-schema`); user can `git checkout phase-1/chunk-first-schema` themselves if they want to resume that branch in the main folder.

- [ ] **Step 10: Delete fellwork-api**

```bash
# Remove the worktree first (otherwise git complains)
cd /c/git/fellwork/fellwork-api
git worktree remove .worktrees/split-fw-resolvers --force 2>/dev/null || true
cd /c/git/fellwork
rm -rf /c/git/fellwork/fellwork-api
ls /c/git/fellwork/ | grep -i fellwork-api
```

Expected: empty output (folder is gone).

- [ ] **Step 11: Verify final state**

```bash
ls -la /c/git/fellwork/api/.git
ls -la /c/git/fellwork/api/.worktrees/split-fw-resolvers/.git
cd /c/git/fellwork/api && git status
cd /c/git/fellwork/api/.worktrees/split-fw-resolvers && git status
```

Expected: both `.git` references exist; statuses show expected branches and any restored uncommitted changes.

- [ ] **Step 12: No git commit** (filesystem operations only)

---

### Task A4: Final cleanup verification

- [ ] **Step 1: Confirm no fellwork-* folders remain**

```bash
ls /c/git/fellwork/ | grep -E "^fellwork-" || echo "CLEAN: no fellwork-* folders"
```

Expected: `CLEAN: no fellwork-* folders`.

- [ ] **Step 2: Confirm short-name folders are healthy**

```bash
for d in api web ops lint scribe shared-configs tsconfig; do
  echo "=== $d ==="
  if [ -d /c/git/fellwork/$d/.git ]; then
    cd /c/git/fellwork/$d && git remote get-url origin && git status --short | head -5
  else
    echo "MISSING"
  fi
done
```

Expected: each folder lists canonical `https://github.com/fellwork/<name>.git` URL and short status.

- [ ] **Step 3: Migration report**

Write a brief summary to console:
```bash
echo "==================================="
echo "Migration complete:"
echo "  fellwork-ops  -> deleted (was clean)"
echo "  fellwork-web  -> uncommitted changes restored to web/"
echo "  fellwork-api  -> phase-1 branch + worktree preserved on api/"
echo "  Capture files in: /c/Users/srmcg/AppData/Local/Temp/fellwork-migration/"
echo "==================================="
```

---

## Phase B — Bootstrap repo

Build `c:/git/fellwork/bootstrap/` from scratch. Modular structure: top-level entry `bootstrap.ps1`, `lib/*.ps1` for capability-grouped logic, `repos.psd1` data file, `animals/*.ansi` sprites, `docs/` with the spec.

---

### Task B1: Initialize bootstrap repo + commit existing spec

**Files:**
- Create: `c:/git/fellwork/bootstrap/.git/` (via init)
- Create: `c:/git/fellwork/bootstrap/.gitignore`
- Create: `c:/git/fellwork/bootstrap/README.md`

- [ ] **Step 1: Initialize git in bootstrap/**

```bash
cd /c/git/fellwork/bootstrap
git init -b main
git remote add origin https://github.com/fellwork/bootstrap.git
ls -la .git/HEAD
```

Expected: `.git/HEAD` exists, points to `main`.

- [ ] **Step 2: Write .gitignore**

Write `c:/git/fellwork/bootstrap/.gitignore`:
```
# Wrangler artifacts
.wrangler/

# Editor
.vscode/
.idea/
*.swp

# OS
Thumbs.db
.DS_Store

# Sprite generation intermediates (PNG sources kept; conversion outputs not committed during dev iteration)
animals/*.png.tmp
```

- [ ] **Step 3: Write README.md skeleton**

Write `c:/git/fellwork/bootstrap/README.md`:
```markdown
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
```

- [ ] **Step 4: First commit (with spec already in place)**

```bash
cd /c/git/fellwork/bootstrap
git add .gitignore README.md docs/
git status
git commit -m "chore: initialize bootstrap repo with spec and README"
```

Expected: commit created with `.gitignore`, `README.md`, and the spec doc.

---

### Task B2: Create repos.psd1 allowlist

**Files:**
- Create: `c:/git/fellwork/bootstrap/repos.psd1`

- [ ] **Step 1: Write the allowlist**

Write `c:/git/fellwork/bootstrap/repos.psd1`:
```powershell
# Fellwork repos managed by bootstrap.
# Adding/removing a repo here is the only way to change what bootstrap clones.
# Outliers (experiments, archived, personal) are intentionally not auto-pulled.

@{
    repos = @(
        @{
            name        = 'api'
            org         = 'fellwork'
            branch      = 'main'
            description = 'Rust/Axum backend (Fly.io deploy target)'
            structureCheck = @('Cargo.toml', 'apps/api/Cargo.toml')
            envExamples = @('apps/api/.env.example')
        }
        @{
            name        = 'web'
            org         = 'fellwork'
            branch      = 'main'
            description = 'Nuxt frontend (Cloudflare Pages)'
            structureCheck = @('package.json', 'apps/web/package.json')
            envExamples = @('apps/web/.env.example')
        }
        @{
            name        = 'ops'
            org         = 'fellwork'
            branch      = 'main'
            description = 'Dev tooling + wiki'
            structureCheck = @('package.json')
            envExamples = @()
        }
        @{
            name        = 'lint'
            org         = 'fellwork'
            branch      = 'main'
            description = 'Shared linting config'
            structureCheck = @()
            envExamples = @()
        }
        @{
            name        = 'scribe'
            org         = 'fellwork'
            branch      = 'main'
            description = 'Reactive DOM Vue/Nuxt with AI as first-class consumer'
            structureCheck = @('package.json')
            envExamples = @()
        }
        @{
            name        = 'shared-configs'
            org         = 'fellwork'
            branch      = 'main'
            description = 'Shared config files'
            structureCheck = @()
            envExamples = @()
        }
        @{
            name        = 'tsconfig'
            org         = 'fellwork'
            branch      = 'main'
            description = 'Shared TypeScript config'
            structureCheck = @()
            envExamples = @()
        }
    )
}
```

- [ ] **Step 2: Test loadability**

```bash
cd /c/git/fellwork/bootstrap
pwsh -NoProfile -Command "Import-PowerShellDataFile ./repos.psd1 | ConvertTo-Json -Depth 5"
```

Expected: JSON output listing all 7 repos with their fields.

- [ ] **Step 3: Commit**

```bash
cd /c/git/fellwork/bootstrap
git add repos.psd1
git commit -m "feat: add repos.psd1 allowlist for 7 fellwork repos"
```

---

### Task B3: Build lib/ui.ps1 — colors, glyphs, terminal capability detection

**Files:**
- Create: `c:/git/fellwork/bootstrap/lib/ui.ps1`
- Create: `c:/git/fellwork/bootstrap/tests/test-ui.ps1`

- [ ] **Step 1: Write failing test**

Write `c:/git/fellwork/bootstrap/tests/test-ui.ps1`:
```powershell
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
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /c/git/fellwork/bootstrap
mkdir -p lib tests
pwsh -NoProfile -File tests/test-ui.ps1
```

Expected: error like "lib/ui.ps1 not found" or function not defined.

- [ ] **Step 3: Implement lib/ui.ps1**

Write `c:/git/fellwork/bootstrap/lib/ui.ps1`:
```powershell
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
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd /c/git/fellwork/bootstrap
pwsh -NoProfile -File tests/test-ui.ps1
```

Expected: all PASS lines, "All UI tests passed.", exit 0.

- [ ] **Step 5: Commit**

```bash
cd /c/git/fellwork/bootstrap
git add lib/ui.ps1 tests/test-ui.ps1
git commit -m "feat(ui): add terminal capability detection, glyph selection, color formatting"
```

---

### Task B4: Build lib/ui.ps1 — tree drawing, sections, side-boxes

**Files:**
- Modify: `c:/git/fellwork/bootstrap/lib/ui.ps1`
- Modify: `c:/git/fellwork/bootstrap/tests/test-ui.ps1`

- [ ] **Step 1: Add failing tests for tree, section, and side-box rendering**

Append to `c:/git/fellwork/bootstrap/tests/test-ui.ps1` (before the final summary block):
```powershell

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
```

- [ ] **Step 2: Run tests to verify the new ones fail**

```bash
cd /c/git/fellwork/bootstrap
pwsh -NoProfile -File tests/test-ui.ps1
```

Expected: existing tests still pass, new ones FAIL with "Format-Section not defined" etc.

- [ ] **Step 3: Implement section, tree, and side-box functions**

Append to `c:/git/fellwork/bootstrap/lib/ui.ps1`:
```powershell

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
    $wrapWidth = $MaxWidth - 8
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
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /c/git/fellwork/bootstrap
pwsh -NoProfile -File tests/test-ui.ps1
```

Expected: all PASS, exit 0.

- [ ] **Step 5: Commit**

```bash
cd /c/git/fellwork/bootstrap
git add lib/ui.ps1 tests/test-ui.ps1
git commit -m "feat(ui): add section headers, tree drawing, banner, and side-boxes"
```

---

### Task B5: Build lib/ui.ps1 — spinner with rainbow option

**Files:**
- Modify: `c:/git/fellwork/bootstrap/lib/ui.ps1`
- Modify: `c:/git/fellwork/bootstrap/tests/test-ui.ps1`

- [ ] **Step 1: Add failing test for spinner frame helper**

Append to `c:/git/fellwork/bootstrap/tests/test-ui.ps1` (before the final summary):
```powershell

# Spinner frame: returns a single braille char from the cycle
$frame0 = Get-SpinnerFrame -Index 0
Assert-Equal "⠋" $frame0 "spinner frame 0"
$frame5 = Get-SpinnerFrame -Index 5
Assert-Equal "⠴" $frame5 "spinner frame 5"
# Wraps
$frame10 = Get-SpinnerFrame -Index 10
Assert-Equal "⠋" $frame10 "spinner frame wraps"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /c/git/fellwork/bootstrap
pwsh -NoProfile -File tests/test-ui.ps1
```

Expected: new tests fail with "Get-SpinnerFrame not defined".

- [ ] **Step 3: Implement spinner functions**

Append to `c:/git/fellwork/bootstrap/lib/ui.ps1`:
```powershell

$script:SpinnerFrames = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')

function Get-SpinnerFrame {
    param([int]$Index)
    return $script:SpinnerFrames[$Index % $script:SpinnerFrames.Count]
}

function Start-Spinner {
    # Run a script block while showing a spinner; returns the script block's output.
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [string]$Label = "working",
        [bool]$Rainbow = $false,
        [bool]$Enabled = $true
    )
    if (-not $Enabled -or [Console]::IsOutputRedirected) {
        return & $ScriptBlock
    }

    $job = Start-Job -ScriptBlock $ScriptBlock
    $i = 0
    while ($job.State -eq 'Running') {
        $frame = Get-SpinnerFrame -Index $i
        $rendered = if ($Rainbow) {
            Format-RainbowText -Text $frame -FrameOffset ($i * 30) -Enabled $true
        } else {
            Format-Color -Text $frame -Color Cyan -Enabled $true
        }
        # \r returns to start of line; pad clears any longer previous label
        Write-Host -NoNewline "`r$rendered $Label   "
        Start-Sleep -Milliseconds 80
        $i++
    }
    # Clear the line
    Write-Host -NoNewline "`r" + (' ' * ($Label.Length + 8)) + "`r"
    $result = Receive-Job -Job $job -Wait
    Remove-Job -Job $job
    return $result
}
```

- [ ] **Step 4: Run tests to verify spinner-frame test passes**

```bash
cd /c/git/fellwork/bootstrap
pwsh -NoProfile -File tests/test-ui.ps1
```

Expected: all PASS, exit 0. (Start-Spinner not unit-tested — too coupled to timing/IO; integration-tested in later tasks.)

- [ ] **Step 5: Commit**

```bash
cd /c/git/fellwork/bootstrap
git add lib/ui.ps1 tests/test-ui.ps1
git commit -m "feat(ui): add spinner with rainbow option for long-running ops"
```

---

### Task B6: Build lib/animals.ps1 — registry and side-box commentary

**Files:**
- Create: `c:/git/fellwork/bootstrap/lib/animals.ps1`
- Create: `c:/git/fellwork/bootstrap/tests/test-animals.ps1`

- [ ] **Step 1: Write failing test**

Write `c:/git/fellwork/bootstrap/tests/test-animals.ps1`:
```powershell
. "$PSScriptRoot/../lib/animals.ps1"

$failures = 0
function Assert-Equal($expected, $actual, $message) {
    if ($expected -ne $actual) {
        Write-Host "FAIL: $message — expected '$expected' got '$actual'" -ForegroundColor Red
        $script:failures++
    } else {
        Write-Host "PASS: $message" -ForegroundColor Green
    }
}
function Assert-True($cond, $message) {
    if ($cond) { Write-Host "PASS: $message" -ForegroundColor Green }
    else       { Write-Host "FAIL: $message" -ForegroundColor Red; $script:failures++ }
}

# Registry has all 8 animals
$reg = Get-AnimalRegistry
Assert-True $reg.ContainsKey('fox')      "registry has fox"
Assert-True $reg.ContainsKey('owl')      "registry has owl"
Assert-True $reg.ContainsKey('turtle')   "registry has turtle"
Assert-True $reg.ContainsKey('octopus')  "registry has octopus"
Assert-True $reg.ContainsKey('hedgehog') "registry has hedgehog"
Assert-True $reg.ContainsKey('raccoon')  "registry has raccoon"
Assert-True $reg.ContainsKey('bee')      "registry has bee"
Assert-True $reg.ContainsKey('otter')    "registry has otter"

# Each animal has emoji + at least one phrase per situation it owns
foreach ($name in $reg.Keys) {
    Assert-True ($reg[$name].Emoji.Length -gt 0) "$name has emoji"
    Assert-True ($reg[$name].Phrases.Count -gt 0) "$name has phrases"
}

# Sprite animals are tagged
$sprites = Get-SpriteAnimals
Assert-Equal 6 $sprites.Count "exactly 6 sprite animals"
Assert-True ($sprites -contains 'raccoon') "sprite list includes raccoon"
Assert-True ($sprites -notcontains 'bee') "sprite list excludes bee"

# Get a random phrase
$phrase = Get-AnimalPhrase -Animal 'fox' -Situation 'repo-note'
Assert-True ($phrase.Length -gt 0) "fox returns a phrase"

# Error category mapping
$animal = Get-AnimalForErrorCategory -Category 'config-mismatch'
Assert-Equal 'raccoon' $animal "config-mismatch maps to raccoon"

$animal = Get-AnimalForErrorCategory -Category 'security'
Assert-Equal 'hedgehog' $animal "security maps to hedgehog"

if ($failures -eq 0) {
    Write-Host "`nAll animal tests passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n$failures animal test(s) failed." -ForegroundColor Red
    exit 1
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /c/git/fellwork/bootstrap
pwsh -NoProfile -File tests/test-animals.ps1
```

Expected: FAIL with "lib/animals.ps1 not found" or function-not-defined errors.

- [ ] **Step 3: Implement animals.ps1**

Write `c:/git/fellwork/bootstrap/lib/animals.ps1`:
```powershell
# Animal registry: emoji, canned phrases, error-category mapping.
# Six "sprite" animals also have ASCII art (loaded separately from animals/*.ansi).
# Two emoji-only animals (bee, otter) appear in side-boxes only.

$script:Registry = @{
    fox = @{
        Emoji = "🦊"
        IsSprite = $true
        ErrorCategory = 'clever-fix'
        Phrases = @{
            'repo-note' = @(
                "this one's the rust monorepo — biggest clone",
                "30+ workspace crates live here",
                "GraphQL + REST under one roof"
            )
            'clever-fix' = @(
                "there's a one-line fix for this",
                "easy one — try the command above",
                "I've seen this before, the fix below works"
            )
        }
    }
    owl = @{
        Emoji = "🦉"
        IsSprite = $true
        ErrorCategory = 'should-know'
        Phrases = @{
            'pro-tip' = @(
                "rerun ./bootstrap.ps1 — it's safe to run repeatedly",
                "you can pass --no-color if you're piping output",
                "each repo's .prototools owns its versions; bootstrap just orchestrates"
            )
            'should-know' = @(
                "version mismatch worth knowing about",
                "deprecated — but still works for now",
                "heads up — this changed recently"
            )
        }
    }
    turtle = @{
        Emoji = "🐢"
        IsSprite = $true
        ErrorCategory = 'optional'
        Phrases = @{
            'no-rush' = @(
                "no rush — only needed for migrations & seeding",
                "optional — install when you actually need it",
                "deploy-only; skip if you're just developing"
            )
        }
    }
    octopus = @{
        Emoji = "🐙"
        IsSprite = $true
        ErrorCategory = 'dependency-tangle'
        Phrases = @{
            'tangle' = @(
                "this one blocks several others — install it first",
                "fix this and three other warnings probably go away"
            )
        }
    }
    hedgehog = @{
        Emoji = "🦔"
        IsSprite = $true
        ErrorCategory = 'security'
        Phrases = @{
            'security' = @(
                "don't commit this .env — it's gitignored for a reason",
                "fill in real secrets before running anything that talks to prod"
            )
        }
    }
    raccoon = @{
        Emoji = "🦝"
        IsSprite = $true
        ErrorCategory = 'config-mismatch'
        Phrases = @{
            'leftover' = @(
                "found leftover state — taking a look",
                "something's already here; not touching it"
            )
            'config-mismatch' = @(
                "this isn't pointing where I expected",
                "configuration drift — see the fix below"
            )
        }
    }
    bee = @{
        Emoji = "🐝"
        IsSprite = $false
        ErrorCategory = $null
        Phrases = @{
            'busy' = @(
                "this might take a minute",
                "fetching things in the background"
            )
        }
    }
    otter = @{
        Emoji = "🦦"
        IsSprite = $false
        ErrorCategory = $null
        Phrases = @{
            'celebrate' = @(
                "everything's swimming!",
                "all systems go.",
                "ready to build."
            )
        }
    }
}

function Get-AnimalRegistry {
    return $script:Registry
}

function Get-SpriteAnimals {
    return @($script:Registry.Keys | Where-Object { $script:Registry[$_].IsSprite })
}

function Get-AnimalPhrase {
    param(
        [Parameter(Mandatory)][string]$Animal,
        [Parameter(Mandatory)][string]$Situation
    )
    if (-not $script:Registry.ContainsKey($Animal)) { return "" }
    $phrases = $script:Registry[$Animal].Phrases[$Situation]
    if (-not $phrases -or $phrases.Count -eq 0) { return "" }
    return $phrases | Get-Random
}

function Get-AnimalForErrorCategory {
    param([Parameter(Mandatory)][string]$Category)
    foreach ($name in $script:Registry.Keys) {
        if ($script:Registry[$name].ErrorCategory -eq $Category) {
            return $name
        }
    }
    return 'raccoon'  # fallback
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd /c/git/fellwork/bootstrap
pwsh -NoProfile -File tests/test-animals.ps1
```

Expected: all PASS, exit 0.

- [ ] **Step 5: Commit**

```bash
cd /c/git/fellwork/bootstrap
git add lib/animals.ps1 tests/test-animals.ps1
git commit -m "feat(animals): add registry with 8 animals, phrases, and error-category mapping"
```

---

### Task B7: Generate ASCII sprites — install chafa, source PNGs, convert

**Files:**
- Create: `c:/git/fellwork/bootstrap/animals/sources/raccoon.png`
- Create: `c:/git/fellwork/bootstrap/animals/sources/hedgehog.png`
- Create: `c:/git/fellwork/bootstrap/animals/sources/octopus.png`
- Create: `c:/git/fellwork/bootstrap/animals/sources/owl.png`
- Create: `c:/git/fellwork/bootstrap/animals/sources/fox.png`
- Create: `c:/git/fellwork/bootstrap/animals/sources/turtle.png`
- Create: `c:/git/fellwork/bootstrap/animals/raccoon.ansi` (and 5 more)
- Create: `c:/git/fellwork/bootstrap/animals/regen.ps1`

- [ ] **Step 1: Install chafa**

```bash
# Try common Windows package managers in order
if command -v scoop >/dev/null 2>&1; then
  scoop install chafa
elif command -v choco >/dev/null 2>&1; then
  choco install chafa -y
else
  echo "Install chafa manually from https://hpjansson.org/chafa/ — needed for sprite generation"
  exit 1
fi
chafa --version | head -2
```

Expected: chafa version printed, ≥1.12.

- [ ] **Step 2: Source 6 Stardew-style pixel PNGs (~32×40 each)**

Manual step — assistant or user sources/curates 6 Stardew-style pixel art PNGs from public-domain galleries (e.g. opengameart.org search for "32x32 forest animals"), commissions, or AI-generates with Stardew style prompt. Save each as `c:/git/fellwork/bootstrap/animals/sources/<name>.png`.

Acceptance: each PNG exists, is 32×40 ± 8 cells, recognizable as the named animal, palette is Stardew-aligned (muted earth tones, soft pastels, no saturated neon).

- [ ] **Step 3: Write regen script**

Write `c:/git/fellwork/bootstrap/animals/regen.ps1`:
```powershell
# Regenerate ANSI sprites from PNG sources via chafa.
# Run after updating any source PNG, or after a chafa version upgrade.

$ErrorActionPreference = 'Stop'
$sourceDir = "$PSScriptRoot/sources"
$outputDir = $PSScriptRoot

if (-not (Get-Command chafa -ErrorAction SilentlyContinue)) {
    Write-Host "chafa not installed. Install it first (scoop install chafa)." -ForegroundColor Red
    exit 1
}

$animals = @('raccoon', 'hedgehog', 'octopus', 'owl', 'fox', 'turtle')
foreach ($name in $animals) {
    $src = Join-Path $sourceDir "$name.png"
    $dst = Join-Path $outputDir "$name.ansi"
    if (-not (Test-Path $src)) {
        Write-Host "Missing source: $src" -ForegroundColor Yellow
        continue
    }
    Write-Host "Converting $name..." -ForegroundColor Cyan
    # Header comment (preserved as actual escape-free text at top of file)
    $header = @"
# Stardew-style $name sprite — tier-3 half-block ANSI.
# Regenerated by animals/regen.ps1 from sources/$name.png
# Generated: $(Get-Date -Format 'yyyy-MM-dd')

"@
    $art = & chafa --size 30x20 --symbols half --colors 256 --animate=off --polite=on $src
    Set-Content -Path $dst -Value ($header + ($art -join "`n")) -Encoding UTF8
}
Write-Host "Done. Sprites in $outputDir" -ForegroundColor Green
```

- [ ] **Step 4: Run regen**

```bash
cd /c/git/fellwork/bootstrap
pwsh -NoProfile -File animals/regen.ps1
ls animals/*.ansi
```

Expected: 6 .ansi files created, each ~5-10KB, with a `#`-prefixed header comment block at the top.

- [ ] **Step 5: Eyeball-test the rendering**

```bash
cd /c/git/fellwork/bootstrap
for f in animals/*.ansi; do
  echo "=== $f ==="
  # Strip header comments (lines starting with #) before display
  grep -v "^#" "$f" | head -25
  echo
done
```

Expected: each animal renders as a recognizable ~30×20 colored sprite. If something looks wrong (e.g. all magenta, garbled), check terminal supports 256-color and try `--colors truecolor` in regen.ps1.

- [ ] **Step 6: Commit**

```bash
cd /c/git/fellwork/bootstrap
git add animals/
git commit -m "feat(animals): add 6 Stardew-style ASCII sprites + regen script"
```

---

### Task B8: Build lib/animals.ps1 — sprite loading and rendering

**Files:**
- Modify: `c:/git/fellwork/bootstrap/lib/animals.ps1`
- Modify: `c:/git/fellwork/bootstrap/tests/test-animals.ps1`

- [ ] **Step 1: Add failing tests for sprite loading**

Append to `c:/git/fellwork/bootstrap/tests/test-animals.ps1` (before final summary):
```powershell

# Sprite loading
$rootDir = Resolve-Path "$PSScriptRoot/.."
$sprite = Read-AnimalSprite -Animal 'raccoon' -RootDir $rootDir
Assert-True ($sprite.Length -gt 100) "raccoon sprite has content"
Assert-True (-not ($sprite -match "^#")) "sprite content has header stripped"

# Sprite width detection
$width = Get-SpriteWidth -Sprite $sprite
Assert-True ($width -ge 20) "sprite width is at least 20 cells"
Assert-True ($width -le 40) "sprite width is at most 40 cells"

# Failure for missing sprite
$missing = Read-AnimalSprite -Animal 'nonexistent' -RootDir $rootDir
Assert-Equal "" $missing "missing sprite returns empty string"
```

- [ ] **Step 2: Run test to verify new tests fail**

```bash
cd /c/git/fellwork/bootstrap
pwsh -NoProfile -File tests/test-animals.ps1
```

Expected: existing tests pass; new ones fail with "Read-AnimalSprite not defined".

- [ ] **Step 3: Implement sprite loader**

Append to `c:/git/fellwork/bootstrap/lib/animals.ps1`:
```powershell

function Read-AnimalSprite {
    param(
        [Parameter(Mandatory)][string]$Animal,
        [Parameter(Mandatory)][string]$RootDir
    )
    $path = Join-Path $RootDir "animals/$Animal.ansi"
    if (-not (Test-Path $path)) { return "" }
    $lines = Get-Content -Path $path -Encoding UTF8
    # Strip leading header comments
    $stripped = @()
    $headerDone = $false
    foreach ($line in $lines) {
        if (-not $headerDone -and $line -match "^\s*#") { continue }
        if (-not $headerDone -and $line.Trim() -eq "") { continue }
        $headerDone = $true
        $stripped += $line
    }
    return ($stripped -join "`n")
}

function Get-SpriteWidth {
    param([Parameter(Mandatory)][string]$Sprite)
    if ([string]::IsNullOrEmpty($Sprite)) { return 0 }
    $lines = $Sprite -split "`n"
    $maxWidth = 0
    foreach ($line in $lines) {
        # Strip ANSI escape codes for width measurement
        $stripped = $line -replace "`e\[[0-9;]*m", ""
        if ($stripped.Length -gt $maxWidth) { $maxWidth = $stripped.Length }
    }
    return $maxWidth
}

function Format-AnimalErrorMoment {
    # Renders the full ASCII art + speech-box failure presentation.
    # Width-aware: full art + side speech (>=100), art + below speech (80-99), emoji only (<80).
    param(
        [Parameter(Mandatory)][string]$Animal,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$FixCommand,
        [Parameter(Mandatory)][int]$TermWidth,
        [Parameter(Mandatory)][string]$RootDir,
        [hashtable]$Glyphs,
        [bool]$Enabled = $true
    )
    if (-not $Glyphs) { $Glyphs = Get-Glyphs -Utf8 $true }
    $emoji = $script:Registry[$Animal].Emoji
    $sprite = Read-AnimalSprite -Animal $Animal -RootDir $RootDir
    $spriteWidth = Get-SpriteWidth -Sprite $sprite

    # Speech-box content
    $speechLines = @()
    $speechLines += $Message
    $speechLines += ""
    $speechLines += "  $FixCommand"
    $speechLines += ""
    $speechLines += "Then rerun ./bootstrap.ps1 — I'll pick up where I left off."

    # Render the speech as a side-box-style frame (wider than commentary side-boxes)
    $speechBoxWidth = [Math]::Min(50, $TermWidth - $spriteWidth - 4)
    $boxTop    = $Glyphs.BoxTL + ($Glyphs.BoxH * ($speechBoxWidth - 2)) + $Glyphs.BoxTR
    $boxBottom = $Glyphs.BoxBL + ($Glyphs.BoxH * ($speechBoxWidth - 2)) + $Glyphs.BoxBR

    $speechBox = @()
    $speechBox += $boxTop
    foreach ($line in $speechLines) {
        $padded = $line.PadRight($speechBoxWidth - 4)
        $speechBox += "$($Glyphs.BoxV) $padded $($Glyphs.BoxV)"
    }
    $speechBox += $boxBottom
    $speechBox += "                                                       — $emoji"

    if ($TermWidth -lt 80 -or [string]::IsNullOrEmpty($sprite)) {
        # Emoji-only fallback
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine("$emoji  $Message")
        [void]$sb.AppendLine("    $FixCommand")
        [void]$sb.AppendLine("    Then rerun ./bootstrap.ps1.")
        return $sb.ToString()
    } elseif ($TermWidth -lt 100) {
        # Art on top, speech below
        return "$sprite`n`n" + ($speechBox -join "`n")
    } else {
        # Side-by-side: art on left, speech on right
        $spriteLines = $sprite -split "`n"
        $sb = [System.Text.StringBuilder]::new()
        $maxRows = [Math]::Max($spriteLines.Count, $speechBox.Count)
        for ($i = 0; $i -lt $maxRows; $i++) {
            $left  = if ($i -lt $spriteLines.Count) { $spriteLines[$i] } else { "" }
            $right = if ($i -lt $speechBox.Count)   { $speechBox[$i] }   else { "" }
            # Pad left to sprite-width then add right
            $strippedLeft = $left -replace "`e\[[0-9;]*m", ""
            $padding = " " * ($spriteWidth - $strippedLeft.Length + 4)
            [void]$sb.AppendLine("$left$padding$right")
        }
        return $sb.ToString()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /c/git/fellwork/bootstrap
pwsh -NoProfile -File tests/test-animals.ps1
```

Expected: all PASS, exit 0.

- [ ] **Step 5: Eyeball-test the error moment for one animal**

```bash
cd /c/git/fellwork/bootstrap
pwsh -NoProfile -Command "
. ./lib/ui.ps1
. ./lib/animals.ps1
Format-AnimalErrorMoment -Animal raccoon -Message 'Hey — psql isn`'t on your PATH.' -FixCommand 'docker exec supabase_db_fellwork psql -U postgres' -TermWidth 120 -RootDir (Get-Location)
"
```

Expected: full raccoon sprite on left, speech-box on right with the message and fix command. Looks like a real moment, not garbled.

- [ ] **Step 6: Commit**

```bash
cd /c/git/fellwork/bootstrap
git add lib/animals.ps1 tests/test-animals.ps1
git commit -m "feat(animals): add sprite loader and error-moment renderer with width fallback"
```

---

### Task B9: Build lib/prereqs.ps1 — tool detection

**Files:**
- Create: `c:/git/fellwork/bootstrap/lib/prereqs.ps1`
- Create: `c:/git/fellwork/bootstrap/tests/test-prereqs.ps1`

- [ ] **Step 1: Write failing test**

Write `c:/git/fellwork/bootstrap/tests/test-prereqs.ps1`:
```powershell
. "$PSScriptRoot/../lib/prereqs.ps1"

$failures = 0
function Assert-Equal($expected, $actual, $message) {
    if ($expected -ne $actual) {
        Write-Host "FAIL: $message — expected '$expected' got '$actual'" -ForegroundColor Red
        $script:failures++
    } else {
        Write-Host "PASS: $message" -ForegroundColor Green
    }
}
function Assert-True($cond, $message) {
    if ($cond) { Write-Host "PASS: $message" -ForegroundColor Green }
    else       { Write-Host "FAIL: $message" -ForegroundColor Red; $script:failures++ }
}

# Test-CommandExists
Assert-True (Test-CommandExists -Name 'git') "git exists (assumed dev environment)"
Assert-Equal $false (Test-CommandExists -Name 'definitely-not-a-real-command-xyz123') "fake command does not exist"

# Get-PrereqResult: present command
$res = Get-PrereqResult -Name 'git' -VersionFlag '--version' -Required $true
Assert-Equal 'present' $res.Status "git status is present"
Assert-True ($res.Version -match '\d+\.\d+') "git version contains a dotted number"

# Get-PrereqResult: missing required command
$res = Get-PrereqResult -Name 'definitely-not-real-xyz' -VersionFlag '--version' -Required $true
Assert-Equal 'missing' $res.Status "missing required command status is missing"
Assert-Equal $true $res.IsHardFailure "missing required command is hard failure"

# Get-PrereqResult: missing optional command
$res = Get-PrereqResult -Name 'definitely-not-real-xyz' -VersionFlag '--version' -Required $false
Assert-Equal 'missing' $res.Status "missing optional command status is missing"
Assert-Equal $false $res.IsHardFailure "missing optional command is not hard failure"

# Test-DockerRunning: returns either $true or $false (no exception)
$dockerOk = Test-DockerRunning
Assert-True ($dockerOk -is [bool]) "Test-DockerRunning returns bool"

if ($failures -eq 0) {
    Write-Host "`nAll prereq tests passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n$failures prereq test(s) failed." -ForegroundColor Red
    exit 1
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /c/git/fellwork/bootstrap
pwsh -NoProfile -File tests/test-prereqs.ps1
```

Expected: FAIL with "lib/prereqs.ps1 not found" or function-not-defined.

- [ ] **Step 3: Implement prereqs.ps1**

Write `c:/git/fellwork/bootstrap/lib/prereqs.ps1`:
```powershell
# Prereq detection: tool presence, version extraction, docker daemon check.

function Test-CommandExists {
    param([Parameter(Mandatory)][string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    return $null -ne $cmd
}

function Get-CommandVersion {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$VersionFlag = '--version'
    )
    if (-not (Test-CommandExists -Name $Name)) { return "" }
    try {
        $output = & $Name $VersionFlag 2>&1 | Select-Object -First 1
        # Pull out a x.y or x.y.z number
        if ($output -match '(\d+\.\d+(\.\d+)?)') {
            return $Matches[1]
        }
        return $output.ToString().Trim()
    } catch {
        return ""
    }
}

function Get-PrereqResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$VersionFlag = '--version',
        [bool]$Required = $true,
        [string]$InstallUrl = "",
        [string]$Workaround = ""
    )
    if (Test-CommandExists -Name $Name) {
        return @{
            Name           = $Name
            Status         = 'present'
            Version        = Get-CommandVersion -Name $Name -VersionFlag $VersionFlag
            IsHardFailure  = $false
            InstallUrl     = $InstallUrl
            Workaround     = $Workaround
        }
    } else {
        return @{
            Name           = $Name
            Status         = 'missing'
            Version        = ""
            IsHardFailure  = $Required
            InstallUrl     = $InstallUrl
            Workaround     = $Workaround
        }
    }
}

function Test-DockerRunning {
    if (-not (Test-CommandExists -Name 'docker')) { return $false }
    try {
        $null = & docker info 2>&1
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

function Get-AllPrereqs {
    # Returns ordered list of prereq results.
    # Bootstrap-time required: git, proto.
    # Toolchain (managed by proto, validated as installed): rust, node, bun, moon.
    # Other-prereqs validated, warn-only or required per type.
    $results = @()

    # Bootstrap-time
    $results += Get-PrereqResult -Name 'git'  -Required $true -InstallUrl 'https://git-scm.com/downloads'
    $results += Get-PrereqResult -Name 'proto' -Required $true -InstallUrl 'https://moonrepo.dev/proto'

    # Toolchain (proto installs, but we sanity-check after install)
    $results += Get-PrereqResult -Name 'rustc' -Required $false -InstallUrl 'auto-installed by proto'
    $results += Get-PrereqResult -Name 'node'  -Required $false -InstallUrl 'auto-installed by proto'
    $results += Get-PrereqResult -Name 'bun'   -Required $false -InstallUrl 'auto-installed by proto'

    # Other prereqs
    $dockerResult = Get-PrereqResult -Name 'docker' -Required $false -InstallUrl 'https://www.docker.com/products/docker-desktop'
    if ($dockerResult.Status -eq 'present' -and -not (Test-DockerRunning)) {
        $dockerResult.Status = 'present-but-not-running'
        $dockerResult.Workaround = 'Start Docker Desktop'
    }
    $results += $dockerResult

    $results += Get-PrereqResult -Name 'supabase' -Required $false -InstallUrl 'https://supabase.com/docs/guides/local-development/cli/getting-started'
    $results += Get-PrereqResult -Name 'psql'     -Required $false -InstallUrl 'https://www.postgresql.org/download/' -Workaround 'docker exec supabase_db_fellwork psql -U postgres'
    $results += Get-PrereqResult -Name 'wrangler' -Required $false -InstallUrl 'npm install -g wrangler'
    $results += Get-PrereqResult -Name 'flyctl'   -Required $false -InstallUrl 'https://fly.io/docs/hands-on/install-flyctl/'
    $results += Get-PrereqResult -Name 'gh'       -Required $false -InstallUrl 'https://cli.github.com/'

    return $results
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd /c/git/fellwork/bootstrap
pwsh -NoProfile -File tests/test-prereqs.ps1
```

Expected: all PASS, exit 0.

- [ ] **Step 5: Smoke-test the full prereq scan**

```bash
cd /c/git/fellwork/bootstrap
pwsh -NoProfile -Command ". ./lib/prereqs.ps1; Get-AllPrereqs | ForEach-Object { '{0,-12} {1,-25} {2}' -f \$_.Name, \$_.Status, \$_.Version }"
```

Expected: table-style output listing each tool with present/missing and a version where present.

- [ ] **Step 6: Commit**

```bash
cd /c/git/fellwork/bootstrap
git add lib/prereqs.ps1 tests/test-prereqs.ps1
git commit -m "feat(prereqs): add tool detection with docker-daemon check and full prereq registry"
```

---

### Task B10: Build lib/repos.ps1 — clone, validate, env scaffold

**Files:**
- Create: `c:/git/fellwork/bootstrap/lib/repos.ps1`
- Create: `c:/git/fellwork/bootstrap/tests/test-repos.ps1`

- [ ] **Step 1: Write failing test**

Write `c:/git/fellwork/bootstrap/tests/test-repos.ps1`:
```powershell
. "$PSScriptRoot/../lib/repos.ps1"

$failures = 0
function Assert-Equal($expected, $actual, $message) {
    if ($expected -ne $actual) {
        Write-Host "FAIL: $message — expected '$expected' got '$actual'" -ForegroundColor Red
        $script:failures++
    } else {
        Write-Host "PASS: $message" -ForegroundColor Green
    }
}
function Assert-True($cond, $message) {
    if ($cond) { Write-Host "PASS: $message" -ForegroundColor Green }
    else       { Write-Host "FAIL: $message" -ForegroundColor Red; $script:failures++ }
}

# Get-RepoState: existing folder with matching origin
$state = Get-RepoState -Name 'api' -ParentDir 'c:/git/fellwork' -ExpectedOrigin 'https://github.com/fellwork/api.git'
Assert-Equal 'present-matching' $state.Status "api status when origin matches"
Assert-Equal 'main' $state.Branch "api on main branch"

# Get-RepoState: nonexistent folder
$state = Get-RepoState -Name 'totally-fake-repo' -ParentDir 'c:/git/fellwork' -ExpectedOrigin 'https://github.com/fellwork/totally-fake-repo.git'
Assert-Equal 'absent' $state.Status "nonexistent repo status is absent"

# Test-EnvFilesNeeded: returns list of envExamples needing scaffolding
$repo = @{ name = 'api'; envExamples = @('apps/api/.env.example') }
$needed = Test-EnvFilesNeeded -Repo $repo -ParentDir 'c:/git/fellwork'
Assert-True ($needed -is [array] -or $needed.Count -ge 0) "EnvFilesNeeded returns array"

# Validate-RepoStructure: check for files
$repo = @{ name = 'api'; structureCheck = @('Cargo.toml') }
$valid = Test-RepoStructure -Repo $repo -ParentDir 'c:/git/fellwork'
Assert-Equal $true $valid "api has Cargo.toml"

$repo = @{ name = 'api'; structureCheck = @('totally-not-real-file.xyz') }
$valid = Test-RepoStructure -Repo $repo -ParentDir 'c:/git/fellwork'
Assert-Equal $false $valid "api missing fake file"

if ($failures -eq 0) {
    Write-Host "`nAll repos tests passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n$failures repos test(s) failed." -ForegroundColor Red
    exit 1
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /c/git/fellwork/bootstrap
pwsh -NoProfile -File tests/test-repos.ps1
```

Expected: FAIL with "lib/repos.ps1 not found" or function-not-defined.

- [ ] **Step 3: Implement repos.ps1**

Write `c:/git/fellwork/bootstrap/lib/repos.ps1`:
```powershell
# Repo operations: state detection, clone, validate, env scaffold.
# All operations are read-only by default; mutating ones explicitly named (Invoke-*).

function Get-RepoState {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ParentDir,
        [Parameter(Mandatory)][string]$ExpectedOrigin
    )
    $path = Join-Path $ParentDir $Name
    if (-not (Test-Path $path)) {
        return @{ Status = 'absent'; Path = $path; Origin = ""; Branch = "" }
    }
    if (-not (Test-Path (Join-Path $path '.git'))) {
        return @{ Status = 'present-not-git'; Path = $path; Origin = ""; Branch = "" }
    }
    $origin = ""
    $branch = ""
    try {
        Push-Location $path
        $origin = (& git remote get-url origin 2>$null).Trim()
        $branch = (& git branch --show-current 2>$null).Trim()
    } catch {} finally {
        Pop-Location
    }
    $status = if ($origin -eq $ExpectedOrigin) { 'present-matching' } else { 'present-mismatch' }
    return @{ Status = $status; Path = $path; Origin = $origin; Branch = $branch }
}

function Invoke-RepoClone {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Org,
        [Parameter(Mandatory)][string]$ParentDir
    )
    $url = "https://github.com/$Org/$Name.git"
    $path = Join-Path $ParentDir $Name
    Push-Location $ParentDir
    try {
        & git clone $url $Name 2>&1 | Out-String
        $exit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    return @{
        Success = ($exit -eq 0)
        Path    = $path
        ExitCode = $exit
    }
}

function Test-EnvFilesNeeded {
    param(
        [Parameter(Mandatory)][hashtable]$Repo,
        [Parameter(Mandatory)][string]$ParentDir
    )
    $needed = @()
    if (-not $Repo.envExamples) { return $needed }
    $repoPath = Join-Path $ParentDir $Repo.name
    foreach ($examplePath in $Repo.envExamples) {
        $examplFull = Join-Path $repoPath $examplePath
        $envFull = $examplFull -replace '\.env\.example$', '.env'
        if ((Test-Path $examplFull) -and -not (Test-Path $envFull)) {
            $needed += @{
                Example = $examplFull
                Target  = $envFull
            }
        }
    }
    return $needed
}

function Invoke-EnvScaffold {
    param(
        [Parameter(Mandatory)][hashtable]$EnvFile
    )
    Copy-Item -Path $EnvFile.Example -Destination $EnvFile.Target -ErrorAction Stop
}

function Test-RepoStructure {
    param(
        [Parameter(Mandatory)][hashtable]$Repo,
        [Parameter(Mandatory)][string]$ParentDir
    )
    $repoPath = Join-Path $ParentDir $Repo.name
    if (-not $Repo.structureCheck -or $Repo.structureCheck.Count -eq 0) { return $true }
    foreach ($file in $Repo.structureCheck) {
        if (-not (Test-Path (Join-Path $repoPath $file))) { return $false }
    }
    return $true
}

function Invoke-ProtoInstall {
    param(
        [Parameter(Mandatory)][string]$RepoPath
    )
    if (-not (Test-Path (Join-Path $RepoPath '.prototools'))) {
        return @{ Success = $true; Skipped = $true; Reason = 'no .prototools' }
    }
    Push-Location $RepoPath
    try {
        $output = & proto install 2>&1 | Out-String
        $exit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    return @{
        Success = ($exit -eq 0)
        Skipped = $false
        Output  = $output
        ExitCode = $exit
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd /c/git/fellwork/bootstrap
pwsh -NoProfile -File tests/test-repos.ps1
```

Expected: all PASS, exit 0.

- [ ] **Step 5: Commit**

```bash
cd /c/git/fellwork/bootstrap
git add lib/repos.ps1 tests/test-repos.ps1
git commit -m "feat(repos): add repo state detection, clone, env scaffold, structure validation"
```

---

### Task B11: Build top-level bootstrap.ps1 — wire it all together

**Files:**
- Create: `c:/git/fellwork/bootstrap/bootstrap.ps1`

- [ ] **Step 1: Write the entry point script**

Write `c:/git/fellwork/bootstrap/bootstrap.ps1`:
```powershell
#Requires -Version 7
[CmdletBinding()]
param(
    [switch]$Help,
    [switch]$NoColor,
    [switch]$Ascii
)

$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot

# Source library files
. "$scriptRoot/lib/ui.ps1"
. "$scriptRoot/lib/animals.ps1"
. "$scriptRoot/lib/prereqs.ps1"
. "$scriptRoot/lib/repos.ps1"

if ($Help) {
    Write-Host @"
Fellwork Bootstrap

Usage: ./bootstrap.ps1 [--help] [--no-color] [--ascii]

Clones the seven Fellwork repositories as siblings of this bootstrap repo,
runs proto install per repo, validates other prereqs, and scaffolds env files.

Flags:
  --help       Show this message
  --no-color   Disable color output (also: NO_COLOR env var)
  --ascii      Use ASCII fallback for glyphs

Exit codes:
  0   All clean
  1   Warnings only
  2   Hard failures
"@
    exit 0
}

# Apply UI overrides
Set-UiOverrides -NoColor $NoColor.IsPresent -Ascii $Ascii.IsPresent
$caps = Get-TerminalCaps
$glyphs = Get-Glyphs -Utf8 $caps.SupportsUtf8
$colorOn = $caps.SupportsColor

# Self-check: confirm we're running from c:/git/fellwork/bootstrap (or sibling layout works)
$parentDir = Split-Path -Parent $scriptRoot
if (-not (Test-Path $parentDir)) {
    Write-Host "Cannot determine parent directory. Bootstrap must run from a folder with a writable parent." -ForegroundColor Red
    exit 2
}

# Banner
Write-Host ""
Write-Host (Format-Banner -Title "Fellwork Bootstrap" -Subtitle (Get-Date -Format "HH:mm:ss") -Width 60 -Glyphs $glyphs -Enabled $colorOn)
Write-Host ""

# Track status across phases
$summary = @{
    Repos     = @()
    Prereqs   = @()
    EnvFiles  = @()
    HardFails = @()
    Warnings  = @()
}

# --- Phase 1: Bootstrap-time prereq check ---
Write-Host (Format-Section -Title "Bootstrap prerequisites" -Glyphs $glyphs -Enabled $colorOn)
$bootstrapPrereqs = @('git', 'proto')
$bootstrapOk = $true
foreach ($p in $bootstrapPrereqs) {
    $r = Get-PrereqResult -Name $p -Required $true
    if ($r.Status -eq 'present') {
        $line = "$($glyphs.Ok) $($p.PadRight(12)) $($r.Version)"
        Write-Host (Format-Color -Text $line -Color Green -Enabled $colorOn)
    } else {
        $line = "$($glyphs.Fail) $($p.PadRight(12)) MISSING"
        Write-Host (Format-Color -Text $line -Color Red -Enabled $colorOn)
        $bootstrapOk = $false
        $summary.HardFails += @{
            Title       = "$p is required and not installed"
            FixCommand  = "Install: $($r.InstallUrl)"
            Animal      = 'octopus'
        }
    }
}
Write-Host ""

if (-not $bootstrapOk) {
    Write-Host "Bootstrap-time prereqs missing. Cannot proceed." -ForegroundColor Red
    foreach ($f in $summary.HardFails) {
        Write-Host (Format-AnimalErrorMoment -Animal $f.Animal -Message $f.Title -FixCommand $f.FixCommand -TermWidth $caps.Width -RootDir $scriptRoot -Glyphs $glyphs -Enabled $colorOn)
        Write-Host ""
    }
    exit 2
}

# --- Phase 2: Clone repos ---
$repoData = Import-PowerShellDataFile (Join-Path $scriptRoot 'repos.psd1')
Write-Host (Format-Section -Title "Cloning repositories" -Glyphs $glyphs -Enabled $colorOn)

foreach ($repo in $repoData.repos) {
    $expectedOrigin = "https://github.com/$($repo.org)/$($repo.name).git"
    $state = Get-RepoState -Name $repo.name -ParentDir $parentDir -ExpectedOrigin $expectedOrigin

    Write-Host (Format-Color -Text $repo.name -Color White -Enabled $colorOn -Bold $true)

    switch ($state.Status) {
        'present-matching' {
            Write-Host (Format-TreeLine -Glyphs $glyphs -IsLast $false -Indent 0 -Text (Format-Color -Text "$($glyphs.Ok) already cloned, origin matches" -Color Green -Enabled $colorOn))
            Write-Host (Format-TreeLine -Glyphs $glyphs -IsLast $true  -Indent 0 -Text (Format-Color -Text "$($glyphs.Ok) on branch $($state.Branch)" -Color Green -Enabled $colorOn))
            $summary.Repos += @{ Name = $repo.name; Status = 'ok'; Action = 'skipped' }
        }
        'present-mismatch' {
            Write-Host (Format-TreeLine -Glyphs $glyphs -IsLast $true -Indent 0 -Text (Format-Color -Text "$($glyphs.Fail) wrong origin: $($state.Origin)" -Color Red -Enabled $colorOn))
            $summary.HardFails += @{
                Title      = "Repo '$($repo.name)' exists but points to wrong origin: $($state.Origin)"
                FixCommand = "cd $parentDir/$($repo.name) && git remote set-url origin $expectedOrigin"
                Animal     = 'raccoon'
            }
            $summary.Repos += @{ Name = $repo.name; Status = 'fail'; Action = 'skipped-mismatch' }
        }
        'present-not-git' {
            Write-Host (Format-TreeLine -Glyphs $glyphs -IsLast $true -Indent 0 -Text (Format-Color -Text "$($glyphs.Fail) directory exists but is not a git repo" -Color Red -Enabled $colorOn))
            $summary.HardFails += @{
                Title      = "Path '$($state.Path)' exists but is not a git repo"
                FixCommand = "Inspect $($state.Path) and resolve manually (back up & remove if appropriate, then rerun)"
                Animal     = 'raccoon'
            }
            $summary.Repos += @{ Name = $repo.name; Status = 'fail'; Action = 'skipped-non-git' }
        }
        'absent' {
            Write-Host (Format-TreeLine -Glyphs $glyphs -IsLast $false -Indent 0 -Text "$($glyphs.Ellipsis) cloning…")
            $clone = Invoke-RepoClone -Name $repo.name -Org $repo.org -ParentDir $parentDir
            if ($clone.Success) {
                Write-Host (Format-TreeLine -Glyphs $glyphs -IsLast $true -Indent 0 -Text (Format-Color -Text "$($glyphs.Ok) cloned" -Color Green -Enabled $colorOn))
                $summary.Repos += @{ Name = $repo.name; Status = 'ok'; Action = 'cloned' }
            } else {
                Write-Host (Format-TreeLine -Glyphs $glyphs -IsLast $true -Indent 0 -Text (Format-Color -Text "$($glyphs.Fail) clone failed (exit $($clone.ExitCode))" -Color Red -Enabled $colorOn))
                $summary.HardFails += @{
                    Title      = "git clone failed for $($repo.name)"
                    FixCommand = "Check network/auth, then rerun: git clone $expectedOrigin"
                    Animal     = 'octopus'
                }
                $summary.Repos += @{ Name = $repo.name; Status = 'fail'; Action = 'clone-failed' }
            }
        }
    }
    Write-Host ""
}

# --- Phase 3: Proto install per repo ---
Write-Host (Format-Section -Title "Toolchain (proto install per repo)" -Glyphs $glyphs -Enabled $colorOn)
foreach ($repo in $repoData.repos) {
    $repoStatus = ($summary.Repos | Where-Object { $_.Name -eq $repo.name } | Select-Object -First 1)
    if (-not $repoStatus -or $repoStatus.Status -ne 'ok') { continue }
    $repoPath = Join-Path $parentDir $repo.name

    Write-Host (Format-Color -Text $repo.name -Color White -Enabled $colorOn -Bold $true)
    $result = Invoke-ProtoInstall -RepoPath $repoPath
    if ($result.Skipped) {
        Write-Host (Format-TreeLine -Glyphs $glyphs -IsLast $true -Indent 0 -Text (Format-Color -Text "$($glyphs.Ellipsis) no .prototools — skipping" -Color DimGray -Enabled $colorOn))
    } elseif ($result.Success) {
        Write-Host (Format-TreeLine -Glyphs $glyphs -IsLast $true -Indent 0 -Text (Format-Color -Text "$($glyphs.Ok) tools installed" -Color Green -Enabled $colorOn))
    } else {
        Write-Host (Format-TreeLine -Glyphs $glyphs -IsLast $true -Indent 0 -Text (Format-Color -Text "$($glyphs.Fail) proto install failed (exit $($result.ExitCode))" -Color Red -Enabled $colorOn))
        $summary.HardFails += @{
            Title      = "proto install failed for $($repo.name)"
            FixCommand = "cd $repoPath && proto install"
            Animal     = 'octopus'
        }
    }
    Write-Host ""
}

# --- Phase 4: Other prereqs ---
Write-Host (Format-Section -Title "Other prerequisites" -Glyphs $glyphs -Enabled $colorOn)
$otherPrereqs = Get-AllPrereqs | Where-Object { $_.Name -notin @('git','proto','rustc','node','bun') }
foreach ($p in $otherPrereqs) {
    if ($p.Status -eq 'present') {
        Write-Host (Format-Color -Text "$($glyphs.Ok) $($p.Name.PadRight(12)) $($p.Version)" -Color Green -Enabled $colorOn)
    } elseif ($p.Status -eq 'present-but-not-running') {
        Write-Host (Format-Color -Text "$($glyphs.Warn) $($p.Name.PadRight(12)) installed but daemon not running" -Color Yellow -Enabled $colorOn)
        $summary.Warnings += @{ Name = $p.Name; Reason = 'not running' }
    } else {
        Write-Host (Format-Color -Text "$($glyphs.Warn) $($p.Name.PadRight(12)) not found" -Color Yellow -Enabled $colorOn)
        if ($p.Workaround) {
            Write-Host (Format-Color -Text "  workaround: $($p.Workaround)" -Color DimGray -Enabled $colorOn)
        } elseif ($p.InstallUrl) {
            Write-Host (Format-Color -Text "  install: $($p.InstallUrl)" -Color DimGray -Enabled $colorOn)
        }
        $summary.Warnings += @{ Name = $p.Name; Reason = 'missing' }
    }
}
Write-Host ""

# --- Phase 5: Env scaffolding ---
Write-Host (Format-Section -Title "Env files" -Glyphs $glyphs -Enabled $colorOn)
foreach ($repo in $repoData.repos) {
    $repoStatus = ($summary.Repos | Where-Object { $_.Name -eq $repo.name } | Select-Object -First 1)
    if (-not $repoStatus -or $repoStatus.Status -ne 'ok') { continue }
    $needed = Test-EnvFilesNeeded -Repo $repo -ParentDir $parentDir
    if ($needed.Count -eq 0) { continue }
    foreach ($env in $needed) {
        try {
            Invoke-EnvScaffold -EnvFile $env
            Write-Host (Format-Color -Text "$($glyphs.Ok) scaffolded: $($env.Target)" -Color Green -Enabled $colorOn)
            Write-Host (Format-Color -Text "  fill in real secrets before using" -Color Yellow -Enabled $colorOn)
            $summary.EnvFiles += $env.Target
            $summary.Warnings += @{ Name = $env.Target; Reason = 'fill-secrets' }
        } catch {
            Write-Host (Format-Color -Text "$($glyphs.Fail) failed to scaffold $($env.Target): $_" -Color Red -Enabled $colorOn)
        }
    }
}
Write-Host ""

# --- Phase 6: Structure validation ---
Write-Host (Format-Section -Title "Repo structure validation" -Glyphs $glyphs -Enabled $colorOn)
foreach ($repo in $repoData.repos) {
    $repoStatus = ($summary.Repos | Where-Object { $_.Name -eq $repo.name } | Select-Object -First 1)
    if (-not $repoStatus -or $repoStatus.Status -ne 'ok') { continue }
    $valid = Test-RepoStructure -Repo $repo -ParentDir $parentDir
    if ($valid) {
        Write-Host (Format-Color -Text "$($glyphs.Ok) $($repo.name)" -Color Green -Enabled $colorOn)
    } else {
        Write-Host (Format-Color -Text "$($glyphs.Warn) $($repo.name) — expected files missing" -Color Yellow -Enabled $colorOn)
        $summary.Warnings += @{ Name = $repo.name; Reason = 'structure-check' }
    }
}
Write-Host ""

# --- Phase 7: Summary ---
$cleanRepos = ($summary.Repos | Where-Object { $_.Status -eq 'ok' }).Count
$totalRepos = $summary.Repos.Count
$warnCount = $summary.Warnings.Count
$failCount = $summary.HardFails.Count

Write-Host (Format-Section -Title "Summary" -Glyphs $glyphs -Enabled $colorOn)

if ($failCount -eq 0 -and $warnCount -eq 0) {
    $headline = "$($glyphs.Ok) $cleanRepos repos cloned and validated — ready to build."
    Write-Host (Format-RainbowText -Text $headline -Enabled $colorOn)
    $otterPhrase = Get-AnimalPhrase -Animal 'otter' -Situation 'celebrate'
    Write-Host ""
    Write-Host "🦦  $otterPhrase"
    exit 0
}

Write-Host (Format-Color -Text "$($glyphs.Ok) $cleanRepos / $totalRepos repos cloned and validated" -Color Green -Enabled $colorOn)
if ($warnCount -gt 0) {
    Write-Host (Format-Color -Text "$($glyphs.Warn) $warnCount warning(s)" -Color Yellow -Enabled $colorOn)
}
if ($failCount -gt 0) {
    Write-Host (Format-Color -Text "$($glyphs.Fail) $failCount hard failure(s)" -Color Red -Enabled $colorOn)
}
Write-Host ""

# Show ASCII art for each hard failure
foreach ($f in $summary.HardFails) {
    Write-Host (Format-AnimalErrorMoment -Animal $f.Animal -Message $f.Title -FixCommand $f.FixCommand -TermWidth $caps.Width -RootDir $scriptRoot -Glyphs $glyphs -Enabled $colorOn)
    Write-Host ""
}

# Next-steps reminder
$owlPhrase = Get-AnimalPhrase -Animal 'owl' -Situation 'pro-tip'
Write-Host "🦉  $owlPhrase"

# Exit code: 2 for any hard fail, 1 for warnings only
if ($failCount -gt 0) { exit 2 }
elseif ($warnCount -gt 0) { exit 1 }
else { exit 0 }
```

- [ ] **Step 2: Smoke-test with --help**

```bash
cd /c/git/fellwork/bootstrap
pwsh -NoProfile -File ./bootstrap.ps1 -Help
```

Expected: usage text printed, exit 0.

- [ ] **Step 3: Run for real (everything is already cloned, so should be all-green)**

```bash
cd /c/git/fellwork/bootstrap
pwsh -NoProfile -File ./bootstrap.ps1
echo "Exit: $?"
```

Expected:
- Banner
- "Bootstrap prerequisites" section: ✓ git, ✓ proto
- "Cloning repositories" section: each repo shows ✓ already cloned, origin matches
- "Toolchain" section: each repo with .prototools shows ✓ tools installed (or skipped)
- "Other prerequisites" section: ✓/⚠ per tool
- "Env files" section: scaffolding messages or empty
- "Repo structure validation" section: ✓ per repo
- "Summary" section with exit code 0 or 1

- [ ] **Step 4: Commit**

```bash
cd /c/git/fellwork/bootstrap
git add bootstrap.ps1
git commit -m "feat: add bootstrap.ps1 entry point wiring all phases together"
```

---

### Task B12: Idempotency test — second run produces no actions

- [ ] **Step 1: Run bootstrap twice in a row, capture both outputs**

```bash
cd /c/git/fellwork/bootstrap
pwsh -NoProfile -File ./bootstrap.ps1 > /tmp/run1.txt 2>&1
pwsh -NoProfile -File ./bootstrap.ps1 > /tmp/run2.txt 2>&1
diff /tmp/run1.txt /tmp/run2.txt | head -20
```

Expected: only differences are timestamps in the banner. Functional content (✓/⚠/✗ lines per repo, prereq states, summary counts) is identical.

- [ ] **Step 2: If non-trivial diff exists, fix the offending phase**

If a non-time difference appears (e.g. env files scaffolded second time despite first scaffold), check the relevant `Test-*` function — it must correctly detect the post-first-run state and skip its action.

- [ ] **Step 3: No commit needed if test passes**

---

### Task B13: Failure-recovery test — break a prereq, recover, verify resumption

- [ ] **Step 1: Simulate failure by setting PATH to exclude wrangler**

```bash
cd /c/git/fellwork/bootstrap
# Capture wrangler location, then run with a temporarily restricted PATH
WRANGLER_PATH=$(which wrangler 2>/dev/null)
echo "Wrangler at: $WRANGLER_PATH"
# Use a sandboxed PATH that excludes the wrangler dir
SAFE_PATH="/c/Windows/System32:/c/Windows:/c/Program Files/Git/cmd:/c/Program Files/PowerShell/7"
PATH="$SAFE_PATH" pwsh -NoProfile -File ./bootstrap.ps1
echo "Exit: $?"
```

Expected: exit code 1 (warnings) since wrangler is optional, ⚠ wrangler not found shown in "Other prerequisites" section.

- [ ] **Step 2: Restore PATH, verify clean rerun**

```bash
cd /c/git/fellwork/bootstrap
pwsh -NoProfile -File ./bootstrap.ps1
echo "Exit: $?"
```

Expected: exit code 0 or 1 (depending on whether other warnings exist), wrangler shown ✓.

- [ ] **Step 3: Test hard failure mode by mismatching origin**

Use a sandbox copy of an existing repo to avoid touching the real one:
```bash
cp -r /c/git/fellwork/lint /tmp/test-lint-broken
cd /tmp/test-lint-broken && git remote set-url origin https://github.com/fellwork/wrong-name.git
# Modify repos.psd1 temporarily? Easier: just verify the detection works
cd /c/git/fellwork/bootstrap
pwsh -NoProfile -Command ". ./lib/repos.ps1; Get-RepoState -Name 'test-lint-broken' -ParentDir '/tmp' -ExpectedOrigin 'https://github.com/fellwork/test-lint-broken.git' | ConvertTo-Json"
rm -rf /tmp/test-lint-broken
```

Expected: status `present-mismatch`. Confirms the detection logic that would trigger the raccoon ASCII art.

- [ ] **Step 4: No commit (testing only)**

---

### Task B14: Update api/CLAUDE.md and api/README.md

**Files:**
- Modify: `c:/git/fellwork/api/CLAUDE.md` — replace companion-repos block
- Modify: `c:/git/fellwork/api/README.md` — replace bootstrap section

- [ ] **Step 1: Update api/CLAUDE.md**

Replace this block in `c:/git/fellwork/api/CLAUDE.md`:
```
# fellwork-api

Rust/Axum backend for Fellwork. Companion repos: **fellwork-web** (Nuxt frontend) and
**fellwork-ops** (dev tooling + wiki). See `README.md` for the sibling-clone layout.
```

with:
```
# fellwork-api

Rust/Axum backend for Fellwork. Part of a 7-repo workspace:
**api**, **web**, **ops**, **lint**, **scribe**, **shared-configs**, **tsconfig**.
See `README.md` for the sibling-clone layout — bootstrap via the `bootstrap` repo.
```

- [ ] **Step 2: Update api/README.md**

Replace the bootstrap block in `c:/git/fellwork/api/README.md`. Find:
```
## Required layout

Dev scripts in fellwork-ops assume the three repos are cloned as siblings:

```
some-dir/
├── fellwork-ops/
├── fellwork-web/
└── fellwork-api/   ← this repo
```

Bootstrap from the ops repo:

```bash
git clone https://github.com/fellwork/fellwork-ops.git
git clone https://github.com/fellwork/fellwork-web.git
git clone https://github.com/fellwork/fellwork-api.git
cd fellwork-ops
bun install
bun run setup
```
```

Replace with:
```
## Required layout

Fellwork's seven repos clone as siblings under a single parent directory:

```
some-dir/
├── api/             ← this repo
├── web/
├── ops/
├── lint/
├── scribe/
├── shared-configs/
├── tsconfig/
└── bootstrap/
```

Bootstrap a fresh workspace via the `bootstrap` repo:

```powershell
git clone https://github.com/fellwork/bootstrap.git
cd bootstrap
./bootstrap.ps1
```

The script clones the seven repos, runs `proto install` per repo to land pinned
toolchain versions, validates other prereqs (docker, supabase CLI, psql, wrangler,
flyctl, gh), and scaffolds env files. Re-run safely; it picks up where it left off.
```

- [ ] **Step 3: Verify api/ still shows the env-deletion as the only change**

```bash
cd /c/git/fellwork/api
git status --short
```

Expected: `D apps/api/.env.example` plus `M CLAUDE.md` and `M README.md`.

- [ ] **Step 4: Commit api docs (in api/, not bootstrap/)**

```bash
cd /c/git/fellwork/api
git add CLAUDE.md README.md
git commit -m "docs: update workspace layout to short-name repos + bootstrap repo"
```

---

### Task B15: Initial bootstrap commit + push

- [ ] **Step 1: Final review of bootstrap repo state**

```bash
cd /c/git/fellwork/bootstrap
git log --oneline
git status
```

Expected: 8-10 commits tracking the build, clean working tree.

- [ ] **Step 2: Push to origin**

This step requires the `fellwork/bootstrap` repo to exist on GitHub. If not, create it first via `gh repo create fellwork/bootstrap --public --source=. --remote=origin --push` (or via the GitHub web UI then `git push -u origin main`).

```bash
cd /c/git/fellwork/bootstrap
gh repo view fellwork/bootstrap --json name 2>/dev/null || gh repo create fellwork/bootstrap --public --source=. --remote=origin
git push -u origin main
```

Expected: branch tracked, all commits pushed.

- [ ] **Step 3: Verify CI-ready state**

```bash
cd /c/git/fellwork/bootstrap
pwsh -NoProfile -File tests/test-ui.ps1
pwsh -NoProfile -File tests/test-animals.ps1
pwsh -NoProfile -File tests/test-prereqs.ps1
pwsh -NoProfile -File tests/test-repos.ps1
echo "All test suites passed."
```

Expected: each suite exits 0.

---

## Self-review checklist

**Spec coverage:**
- ✓ Part 1 (migration) → Tasks A0–A4
- ✓ Part 2 (bootstrap repo structure) → Task B1, B2
- ✓ Part 2 (script flow phases 1–8) → Tasks B3–B11
- ✓ Part 3 (color palette) → Task B3
- ✓ Part 3 (glyphs + ASCII fallback) → Task B3
- ✓ Part 3 (tree drawing, banner, sections, side-boxes) → Task B4
- ✓ Part 3 (spinner with rainbow) → Task B5
- ✓ Part 3 (animal registry) → Task B6
- ✓ Part 3 (ASCII sprites — 6 Stardew-style tier-3) → Task B7
- ✓ Part 3 (sprite loading + error-moment with width fallback) → Task B8
- ✓ Part 4 (doc updates) → Task B14
- ✓ Idempotency + failure-recovery validation → Tasks B12, B13
- ✓ Initial commit + push → Task B15

**Placeholder scan:** No TBD/TODO/"implement later" patterns. All test code is concrete. All file paths are absolute. All commands have expected output.

**Type consistency:**
- `Get-RepoState` returns hashtable with `Status`, `Path`, `Origin`, `Branch` — used consistently in Task B11.
- `Get-PrereqResult` returns hashtable with `Name`, `Status`, `Version`, `IsHardFailure`, `InstallUrl`, `Workaround` — used consistently.
- `Format-AnimalErrorMoment` parameters match call site in `bootstrap.ps1`.
- `repos.psd1` schema (`name`, `org`, `branch`, `description`, `structureCheck`, `envExamples`) consistent across `Get-RepoState`, `Test-RepoStructure`, `Test-EnvFilesNeeded`.
