#!/usr/bin/env bash
# disk-janitor-lib.sh — shared scanner + (drafted) deletion library for
# `trellis disk-janitor`.
#
# Single source of truth for "what is safe to reclaim." Sourced by
# scripts/disk-janitor.sh (the orchestrator) AFTER config-load.sh and
# sed-portable.sh, so the functions here run UNDER the orchestrator's
# `set -euo pipefail`. Like scripts/lib/health-checks.sh this file does NOT set
# its own shell options — it is a function-only library. Every function:
#
#   * takes EXPLICIT path arguments (no cwd assumptions),
#   * the PURE SCANNERS emit TSV to stdout and signal status via return code,
#   * makes its internal commands fault-tolerant (`2>/dev/null` / `|| fallback`)
#     so a failing `du`/`git`/`jq` never aborts the caller mid-run — the return
#     code is the ONLY status signal.
#
# Two predicates are INJECTABLE for tests (the running-build guard and the
# merge discriminator can't be exercised against live processes / network):
#   dj_build_active   honors $DJ_BUILD_ACTIVE_OVERRIDE
#   dj_branch_merged  honors $DJ_MERGED_OVERRIDE
#
# The two DELETION functions (dj_prune_cache_entry, dj_reap_worktree) are a
# guarded first pass, marked `# OWNED: integrator rewrites + reviews`.
#
# bash 3.2 compatible: no `[[ ]]`, no associative arrays, no `mapfile`, no
# `${x,,}` — `[ ]`/`case`, indexed arrays + `while read`, `tr` for case.

# ===========================================================================
# size + format
# ===========================================================================

# dj_mtime <path>
# Epoch modification time, portable across darwin (stat -f %m) and linux
# (stat -c %Y). Echoes 0 when the path is missing or stat fails. The single
# place stat-flavor differences live — every other helper reuses this.
dj_mtime() {
  local path="$1"
  [ -e "$path" ] || { echo 0; return 0; }
  stat -f %m "$path" 2>/dev/null || stat -c %Y "$path" 2>/dev/null || echo 0
}

# dj_dir_bytes <path>
# Apparent size of <path> in BYTES (du reports KiB blocks → *1024). Echoes 0
# for a missing/unreadable path so the caller's accounting never breaks.
dj_dir_bytes() {
  local path="$1" kb
  [ -e "$path" ] || { echo 0; return 0; }
  kb="$(du -sk "$path" 2>/dev/null | awk '{print $1}')"
  case "$kb" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$((kb * 1024))" ;;
  esac
}

# dj_human_bytes <bytes>
# Render a byte count as "12.6 GB" / "904 MB" / "1.0 KB" / "0 B". Integer math
# only (one decimal via the tenths trick); /1024 thresholds. Non-numeric input
# is treated as 0.
dj_human_bytes() {
  local bytes="$1"
  case "$bytes" in
    ''|*[!0-9]*) bytes=0 ;;
  esac
  if [ "$bytes" -eq 0 ]; then
    echo "0 B"
    return 0
  fi
  if [ "$bytes" -lt 1024 ]; then
    echo "$bytes B"
    return 0
  fi
  # Walk up the units until the value is under 1024 of the next tier. We track
  # the divisor so the one-decimal rendering uses integer tenths.
  local unit divisor tenths int frac
  if [ "$bytes" -lt 1048576 ]; then
    unit="KB"; divisor=1024
  elif [ "$bytes" -lt 1073741824 ]; then
    unit="MB"; divisor=1048576
  elif [ "$bytes" -lt 1099511627776 ]; then
    unit="GB"; divisor=1073741824
  else
    unit="TB"; divisor=1099511627776
  fi
  tenths=$(( (bytes * 10) / divisor ))
  int=$(( tenths / 10 ))
  frac=$(( tenths % 10 ))
  echo "${int}.${frac} ${unit}"
}

# ===========================================================================
# scope A: build caches
# ===========================================================================

# dj_find_caches <project_path>
# Deep, symlink-safe (-P) search for the build-cache dirs literally named
# `.turbo/cache`, `.next/cache`, `.next/dev` anywhere under the project
# (the `*/.next/...` globs already cover apps/*/.next). Descent into OTHER
# tools' node_modules is pruned, but the cache dirs themselves are still found.
#
# Emits TSV, one row per cache dir:
#   <kind>\t<abs_path>\t<bytes>\t<mtime_epoch>
# kind ∈ turbo-cache | next-cache | next-dev.
dj_find_caches() {
  local proj="$1"
  [ -d "$proj" ] || return 0
  local path kind bytes mtime
  # NOTE: -prune on node_modules removes the *node_modules tree* from the walk;
  # the cache dirs we want never live under node_modules, so this is safe and
  # keeps the scan fast on large monorepos.
  find -P "$proj" \
    \( -type d -name node_modules -prune \) -o \
    \( -type d \( \
        -path '*/.turbo/cache' -o \
        -path '*/.next/cache' -o \
        -path '*/.next/dev' \
      \) -print \) 2>/dev/null \
  | while IFS= read -r path; do
      [ -n "$path" ] || continue
      case "$path" in
        */.turbo/cache) kind="turbo-cache" ;;
        */.next/cache)  kind="next-cache" ;;
        */.next/dev)    kind="next-dev" ;;
        *) continue ;;
      esac
      bytes="$(dj_dir_bytes "$path")"
      mtime="$(dj_mtime "$path")"
      printf '%s\t%s\t%s\t%s\n' "$kind" "$path" "$bytes" "$mtime"
    done
}

# dj_cache_is_stale <mtime> <ttl_days> <now_epoch>
# return 0 (stale) iff (now - mtime) > ttl_days*86400. Non-numeric inputs are
# treated as 0 so a bad mtime never reports "fresh" by accident — a 0 mtime is
# the epoch and will read as very stale, which is the safe direction for a
# report (apply has independent guards).
dj_cache_is_stale() {
  local mtime="$1" ttl_days="$2" now="$3" age threshold
  case "$mtime" in ''|*[!0-9]*) mtime=0 ;; esac
  case "$ttl_days" in ''|*[!0-9]*) ttl_days=0 ;; esac
  case "$now" in ''|*[!0-9]*) now=0 ;; esac
  age=$(( now - mtime ))
  threshold=$(( ttl_days * 86400 ))
  [ "$age" -gt "$threshold" ]
}

# ===========================================================================
# scope A guard: build active (INJECTABLE for tests)
# ===========================================================================

# dj_build_active <project_path>
# return 0 (a build IS running for this project → do NOT prune its caches),
# return 1 (no active build).
#
# Test injection: if $DJ_BUILD_ACTIVE_OVERRIDE is set, "1"→active (return 0),
# "0"→inactive (return 1). This override is the ONLY way the running-build
# guard is testable — required. Any other value is treated as unset.
#
# Real check: pgrep -fl for a dev/build process whose command line mentions the
# absolute project path AND one of the known bundlers. We require the project
# path to appear so a build in an UNRELATED project never blocks this one.
dj_build_active() {
  local proj="$1"
  case "${DJ_BUILD_ACTIVE_OVERRIDE:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  command -v pgrep >/dev/null 2>&1 || return 1
  local procs
  procs="$(pgrep -fl . 2>/dev/null || true)"
  [ -n "$procs" ] || return 1
  # Lines mentioning this project that also name a known bundler in dev|build.
  printf '%s\n' "$procs" \
    | grep -F -- "$proj" 2>/dev/null \
    | grep -Eq '(next|vite|turbo|webpack|tsc)[^[:space:]]*[[:space:]].*(dev|build)|(dev|build).*(next|vite|turbo|webpack|tsc)'
}

# ===========================================================================
# scope B: worktrees
# ===========================================================================

# dj_list_worktrees <repo_path>
# Parse `git -C <repo> worktree list --porcelain` into TSV, one row per tree:
#   <wt_abs_path>\t<head_sha>\t<branch_or_detached>\t<is_main 0|1>\t<prunable 0|1>
# branch is the short name (refs/heads/foo → foo) or the literal "detached".
# is_main is 1 for the first porcelain entry (always the main checkout) and is
# corroborated by comparing the worktree's --git-common-dir to its --git-dir,
# both canonicalized, so a relative/absolute mismatch can't misclassify.
dj_list_worktrees() {
  local repo="$1"
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || return 0
  local porcelain
  porcelain="$(git -C "$repo" worktree list --porcelain 2>/dev/null || true)"
  [ -n "$porcelain" ] || return 0

  local wt="" head="" branch="" prunable=0 first=1 line
  # A trailing newline-only delimiter flushes the final block.
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        wt="${line#worktree }"
        head=""
        branch="detached"
        prunable=0
        ;;
      "HEAD "*)
        head="${line#HEAD }"
        ;;
      "branch "*)
        branch="${line#branch }"
        branch="${branch#refs/heads/}"
        ;;
      "detached")
        branch="detached"
        ;;
      "prunable "*|"prunable")
        prunable=1
        ;;
      "")
        # Blank line terminates a block → emit it.
        if [ -n "$wt" ]; then
          dj__emit_worktree "$repo" "$wt" "$head" "$branch" "$first" "$prunable"
          first=0
          wt=""
        fi
        ;;
    esac
  done <<EOF
$porcelain
EOF
  # Flush a final block with no trailing blank line.
  if [ -n "$wt" ]; then
    dj__emit_worktree "$repo" "$wt" "$head" "$branch" "$first" "$prunable"
  fi
}

# dj__emit_worktree <repo> <wt> <head> <branch> <is_first> <prunable>
# Internal: compute is_main and print one TSV row for dj_list_worktrees.
dj__emit_worktree() {
  local repo="$1" wt="$2" head="$3" branch="$4" is_first="$5" prunable="$6"
  local is_main=0
  if [ "$is_first" = "1" ]; then
    is_main=1
  else
    # Corroborate: a main checkout has --git-common-dir == --git-dir.
    local common gd
    common="$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null || echo '')"
    gd="$(git -C "$wt" rev-parse --git-dir 2>/dev/null || echo '')"
    common="$(dj__abspath "$common")"
    gd="$(dj__abspath "$gd")"
    if [ -n "$common" ] && [ "$common" = "$gd" ]; then
      is_main=1
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$wt" "$head" "$branch" "$is_main" "$prunable"
}

# dj__abspath <path>
# Best-effort canonical absolute path (cd+pwd -P for dirs; resolve a file's
# parent). Empty input → empty output. Used only for the is_main comparison.
dj__abspath() {
  local p="$1"
  [ -n "$p" ] || { printf ''; return 0; }
  if [ -d "$p" ]; then
    ( cd "$p" 2>/dev/null && pwd -P ) || printf '%s' "$p"
  else
    local dir base
    dir="$(dirname "$p")"
    base="$(basename "$p")"
    if [ -d "$dir" ]; then
      local rdir
      rdir="$( cd "$dir" 2>/dev/null && pwd -P )" || rdir="$dir"
      printf '%s/%s' "$rdir" "$base"
    else
      printf '%s' "$p"
    fi
  fi
}

# dj_worktree_mtime <wt_path>
# Epoch of the worktree's last commit (git log -1 --format=%ct). Falls back to
# the mtime of .git/logs/HEAD, then 0.
dj_worktree_mtime() {
  local wt="$1" ct
  ct="$(git -C "$wt" log -1 --format=%ct 2>/dev/null || echo '')"
  case "$ct" in
    ''|*[!0-9]*) ;;
    *) echo "$ct"; return 0 ;;
  esac
  # Fallback: the reflog head's mtime. .git may be a file (linked worktree) so
  # resolve the actual git dir.
  local gd
  gd="$(git -C "$wt" rev-parse --git-dir 2>/dev/null || echo '')"
  if [ -n "$gd" ] && [ -f "$gd/logs/HEAD" ]; then
    dj_mtime "$gd/logs/HEAD"
    return 0
  fi
  echo 0
}

# dj_worktree_clean <wt_path>
# return 0 iff the worktree is safe to remove. Two conditions:
#   1. `git status --porcelain` is EMPTY — no staged, unstaged, OR untracked
#      changes (NO -uno: untracked WIP is data we must never silently destroy).
#   2. EVERY gitignored entry is a known-recoverable build artifact. `git
#      worktree remove` deletes gitignored files (they are invisible to plain
#      `status`), and unlike tracked/untracked content they are NOT in git's
#      object store — losing one is unrecoverable.
#
#      This is an ALLOWLIST, not a denylist, and the direction is the whole
#      point. A denylist ("refuse only on .env / .key / …") fails OPEN: any
#      secret we forgot to enumerate — .npmrc (npm auth tokens, ubiquitous in
#      JS monorepos), .dev.vars, *.keystore/*.jks, *.p8 — would be silently
#      destroyed. An allowlist fails CLOSED: an ignored entry we don't
#      recognise over-refuses the reap (the worktree is left for manual
#      cleanup — the status quo, zero data loss) instead of deleting a secret.
#      Reaping node_modules/.next/.turbo/dist is the intended win, so those are
#      on the list; anything else stays the operator's call.
dj_worktree_clean() {
  local wt="$1" status entry base
  status="$(git -C "$wt" status --porcelain 2>/dev/null || echo 'ERR')"
  [ -z "$status" ] || return 1
  # `--ignored` lines look like "!! path/to/file[/]"; strip the "!! " marker,
  # drop any trailing slash (ignored dirs report one), and match on the
  # basename so a nested artifact (apps/web/.next/) is recognised by ".next".
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    entry="${entry%/}"
    base="${entry##*/}"
    case "$base" in
      node_modules|.next|.nuxt|.svelte-kit|.angular|.turbo|.cache|.parcel-cache|.vite|dist|build|out|coverage|.DS_Store|*.log|*.tsbuildinfo) ;;
      *) return 1 ;;
    esac
  done <<EOF
$(git -C "$wt" status --porcelain --ignored 2>/dev/null | sed -n 's/^!! //p')
EOF
  return 0
}

# dj_branch_merged <repo_path> <branch>
# return 0 (merged → reapable), 1 (NOT merged), 2 (UNVERIFIED → never reaped).
#
# Test injection: if $DJ_MERGED_OVERRIDE is set, "merged"→0, "unmerged"→1,
# "unverified"→2. Any other value is treated as unset.
#
# The ONLY auto-reap signal is a MERGED pull request whose head is <branch>, in
# THIS repo, as reported by `gh`. Notes on why it is exactly this and no more:
#
#   * `gh` resolves its target repo from the working directory, so we `cd`
#     into <repo> first. A bare `gh pr list` would query whatever repo the
#     operator's cwd happens to be (a different project, or trellis-instance
#     itself) — and a branch-name collision there could falsely read as merged.
#   * We do NOT treat a deleted remote branch ("[gone]") as merged. A
#     force-pushed-away / abandoned / admin-deleted branch shows "[gone]" too
#     and is NOT merged. `gh` still sees a squash-merged PR after its branch is
#     deleted (the PR record persists), so the fleet's squash-merge workflow is
#     caught by the PR check — without the [gone] false positives. (This also
#     means report/dry-run never run `git fetch --prune`: nothing is mutated.)
#   * NEVER `git branch --merged` — the fleet squash-merges, so the tip is never
#     an ancestor of main and it would skip exactly the worktrees we want gone.
#
#   gh present, merged PR for <branch>   → 0 (merged)
#   gh present, no merged PR             → 1 (not merged — conservative; a
#                                            non-PR merge reads as not-merged,
#                                            i.e. reported but not reaped)
#   gh absent / detached HEAD            → 2 (UNVERIFIED — reported, never reaped)
dj_branch_merged() {
  local repo="$1" branch="$2"
  case "${DJ_MERGED_OVERRIDE:-}" in
    merged) return 0 ;;
    unmerged) return 1 ;;
    unverified) return 2 ;;
  esac

  # A detached / branchless worktree has nothing to verify a merge against.
  case "$branch" in
    ''|detached|HEAD) return 2 ;;
  esac

  # gh absent → we cannot authoritatively verify → UNVERIFIED (never reaped).
  command -v gh >/dev/null 2>&1 || return 2

  # Scope gh to <repo> via a subshell cd; `|| echo ''` keeps the whole
  # substitution exit-0 under the caller's `set -e`.
  local merged_prs
  merged_prs="$( cd "$repo" 2>/dev/null && gh pr list --head "$branch" --state merged --json number 2>/dev/null || echo '' )"
  case "$merged_prs" in
    ''|'[]'|'null') return 1 ;;
    *) return 0 ;;
  esac
}

# ===========================================================================
# scope C: package stores
# ===========================================================================

# dj_pkg_store_plan
# Echo a best-effort estimate (in bytes) of what `pnpm store prune` /
# `npm cache verify` could reclaim — REPORT ONLY, mutates nothing. We never run
# the prune itself here (only the OWNED functions delete). Estimating reclaim
# without mutating is not reliably possible across pnpm/npm versions, so this
# returns the on-disk store size as an upper bound, or 0 when nothing is found.
dj_pkg_store_plan() {
  local total=0 store

  if command -v pnpm >/dev/null 2>&1; then
    store="$(pnpm store path 2>/dev/null || echo '')"
    if [ -n "$store" ] && [ -d "$store" ]; then
      total=$(( total + $(dj_dir_bytes "$store") ))
    fi
  fi

  # npm cache: prefer the configured cache dir, else the conventional default
  # under the user home (resolved from config, never hardcoded).
  if command -v npm >/dev/null 2>&1; then
    local npm_cache
    npm_cache="$(npm config get cache 2>/dev/null || echo '')"
    case "$npm_cache" in
      ''|undefined|null) npm_cache="${USER_HOME:-$HOME}/.npm" ;;
    esac
    if [ -d "$npm_cache" ]; then
      total=$(( total + $(dj_dir_bytes "$npm_cache") ))
    fi
  fi

  echo "$total"
}

# ===========================================================================
# recurrence pre-pass / doctor guard (shared, pure jq)
# ===========================================================================

# dj_turbo_outputs_unscoped <turbo_json_path>
# return 0 (UNSCOPED — BAD: a task writes a `.next/**`-class output without a
# `!.next/cache/**` negation, so turbo caches the dev/cache dirs → unbounded
# growth). return 1 if the file is absent, has no turbo tasks, or every
# offending output is already negated. Prints NOTHING — status via return only.
#
# NOTE the inverted convention: 0 = problem found. Supports both the modern
# `.tasks` and legacy `.pipeline` turbo schemas. Pure jq.
dj_turbo_outputs_unscoped() {
  local turbo_json="$1"
  [ -f "$turbo_json" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  # For each task: does outputs[] contain a `.next/**`-class glob while LACKING
  # the `!.next/cache/**` negation? `any` over tasks → exit 0 from jq when true.
  # We feed jq's boolean back through the shell: jq prints "true"/"false".
  local verdict
  verdict="$(jq -r '
    (.tasks // .pipeline // {})
    | to_entries
    | map(.value.outputs // [])
    | any(
        . as $outs
        | (
            ($outs | any(test("(^|/)\\.next(/|$)|(^|/)\\.next/\\*\\*")))
            and
            ($outs | any(. == "!.next/cache/**") | not)
          )
      )
  ' "$turbo_json" 2>/dev/null || echo 'false')"

  [ "$verdict" = "true" ]
}

# dj_turbo_fix_hint
# THE canonical one-line fix string (single source of truth). Contains BOTH the
# !.next/cache/** and !.next/dev/** negations so authors paste a complete fix.
# Kept distinct from the detection predicate above (detection keys only on the
# absence of `!.next/cache/**`).
dj_turbo_fix_hint() {
  echo 'add cache-excluding negations to the task outputs, e.g. "outputs": [".next/**", "!.next/cache/**", "!.next/dev/**"]'
}

# ===========================================================================
# OWNED: deletion (integrator rewrites + reviews every line)
# ===========================================================================

# dj_prune_cache_entry <abs_cache_path>
# OWNED: integrator rewrites + reviews
# Delete a single build-cache dir, with hard guards before any rm -rf:
#   * path non-empty AND exists,
#   * canonical real path resolves UNDER $PROJECTS_ROOT (refuse if unset),
#   * basename path ends in one of: cache | .next/cache | .next/dev.
# Refuses (stderr + return 1) on any guard miss; never touches anything else.
dj_prune_cache_entry() {
  # OWNED: integrator rewrites + reviews
  local target="$1"
  [ -n "$target" ] || { echo "dj_prune_cache_entry: empty path refused" >&2; return 1; }
  [ -e "$target" ] || { echo "dj_prune_cache_entry: path does not exist: $target" >&2; return 1; }
  [ -d "$target" ] || { echo "dj_prune_cache_entry: not a directory (refusing to rm a file/symlink): $target" >&2; return 1; }

  local root real
  root="${PROJECTS_ROOT:-}"
  [ -n "$root" ] || { echo "dj_prune_cache_entry: PROJECTS_ROOT unset — refusing" >&2; return 1; }
  root="$(dj__abspath "$root")"
  real="$(dj__abspath "$target")"

  # Must resolve strictly under PROJECTS_ROOT (prefix + path separator so a
  # sibling like "<root>-evil" can't slip through).
  case "$real/" in
    "$root"/*) ;;
    *) echo "dj_prune_cache_entry: '$real' not under PROJECTS_ROOT ($root) — refusing" >&2; return 1 ;;
  esac

  # Suffix must be one of the EXACT cache dirs the finder emits — never a parent
  # like .next or the project, and not a bare */cache (that would match
  # .pnpm/cache, .yarn/cache, any dir named cache if another caller is ever added).
  case "$real" in
    */.turbo/cache|*/.next/cache|*/.next/dev) ;;
    *) echo "dj_prune_cache_entry: '$real' is not a recognized cache dir — refusing" >&2; return 1 ;;
  esac

  rm -rf "$real"
}

# dj_reap_worktree <repo_path> <wt_abs_path>
# OWNED: integrator rewrites + reviews
# Remove a linked worktree, with hard guards:
#   * wt_abs_path non-empty AND != the repo's git common-dir's parent (the main
#     checkout),
#   * resolves UNDER $PROJECTS_ROOT (refuse if unset),
#   * is NOT the main worktree (dj_list_worktrees is_main must be 0 — the caller
#     is responsible for passing only is_main==0 entries; we re-check here).
# Tries `git worktree remove`; if that fails AND the entry is prunable (dead
# .git pointer), falls back to rm -rf + `git worktree prune`.
dj_reap_worktree() {
  # OWNED: integrator rewrites + reviews
  local repo="$1" wt="$2"
  [ -n "$wt" ] || { echo "dj_reap_worktree: empty worktree path refused" >&2; return 1; }
  [ -n "$repo" ] || { echo "dj_reap_worktree: empty repo path refused" >&2; return 1; }

  local root real common common_parent
  root="${PROJECTS_ROOT:-}"
  [ -n "$root" ] || { echo "dj_reap_worktree: PROJECTS_ROOT unset — refusing" >&2; return 1; }
  root="$(dj__abspath "$root")"
  real="$(dj__abspath "$wt")"

  # Refuse the main checkout: its dir is the parent of the git common-dir. If we
  # cannot even determine the common-dir, refuse (fail closed) rather than skip
  # the guard.
  common="$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null || echo '')"
  [ -n "$common" ] || { echo "dj_reap_worktree: cannot determine git-common-dir for '$repo' — refusing" >&2; return 1; }
  common="$(dj__abspath "$common")"
  common_parent="$(dirname "$common")"
  common_parent="$(dj__abspath "$common_parent")"
  if [ "$real" = "$common_parent" ] || [ "$real" = "$common" ]; then
    echo "dj_reap_worktree: '$real' is the main checkout — refusing" >&2
    return 1
  fi

  # Must resolve under PROJECTS_ROOT (or a known worktree home beneath it; the
  # .claude/worktrees convention lives under each project, hence under root).
  case "$real/" in
    "$root"/*) ;;
    *) echo "dj_reap_worktree: '$real' not under PROJECTS_ROOT ($root) — refusing" >&2; return 1 ;;
  esac

  if git -C "$repo" worktree remove "$real" >/dev/null 2>&1; then
    return 0
  fi

  # Fallback only for a prunable (dead-pointer) entry: confirm git itself flags
  # this path as prunable before we rm anything by hand.
  local prunable_row
  prunable_row="$(dj_list_worktrees "$repo" | awk -F'\t' -v p="$real" '$1==p && $5=="1"{print}')"
  if [ -n "$prunable_row" ]; then
    rm -rf "$real"
    git -C "$repo" worktree prune >/dev/null 2>&1 || true
    return 0
  fi

  echo "dj_reap_worktree: 'git worktree remove' failed and entry is not prunable: $real" >&2
  return 1
}
