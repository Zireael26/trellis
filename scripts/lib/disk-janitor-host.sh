#!/usr/bin/env bash
# disk-janitor-host.sh — the janitor's host-global spec 069 scopes: D5 `logs`
# and `tmp`, the D7 `transcripts` histogram and coverage line, the D6
# per-store plan, C3 pi spill-log apply, A9 pi worktree TTL, D3 release staging
# through reap-tmp and the D4 Colima fstrim. Owned by lane L-DH.
#
# dj_host_scan, dj_host_render, dj_host_apply follow the janitor lane-library
# contract documented in disk-janitor-dehydrate.sh.
#
# bash 3.2 compatible: no [[ ]], no associative arrays, no mapfile.

# shellcheck source=release-store.sh
. "$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/release-store.sh"

# dj_host_release_version BASENAME — print VERSION for .tmp.<v>.exec.<s> and
# .tmp.<v>.verify.<s> names (spec 069 D3 covers both). Return 1 otherwise.
dj_host_release_version() {
  local name="${1:-}" rest version
  case "$name" in .tmp.*.exec.*|.tmp.*.verify.*) ;; *) return 1 ;; esac
  rest="${name#.tmp.}"
  [ "$rest" != "$name" ] || return 1
  case "$rest" in *.exec.*) version="${rest%%.exec.*}" ;; *.verify.*) version="${rest%%.verify.*}" ;; *) return 1 ;; esac
  [ -n "$version" ] || return 1
  trellis_home_is_valid_semver "$version" || return 1
  printf '%s\n' "$version"
}

# dj_host_is_uint TEXT — strict ^[0-9]+$ check for numeric plan fields.
# Bash arithmetic expands a[...] subscripts (code execution), so every byte
# count read from a TSV plan row or tool output is validated before any
# $((...)). Return 0 iff TEXT is one or more ASCII digits.
dj_host_is_uint() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# dj_host_has_ctrl PATH — return 0 iff PATH holds a TAB, NEWLINE or CR.
# A path with control characters shifts TSV fields, letting bytes become
# arbitrary text that arithmetic would then expand. Callers hold such rows
# (candidate/skip, never delete) instead of emitting them as plan targets.
# NOTE: $(printf '\n') strips to empty (command substitution), so newline is
# matched via $'\n' (bash; this library is bash-only like its caller).
dj_host_has_ctrl() {
  case "$1" in
    *$'\t'*|*$'\n'*|*$'\r'*) return 0 ;;
    *) return 1 ;;
  esac
}

# dj_host_release_scan — D3: delegate listing to `release_store_reap_tmp
# dry-run` (1.3.12). Only reapable rows become [delete]; keep/refused become
# [skip]/[candidate] so the report stays verbose like before. Emits plan rows
# with `plan_row releases VERDICT release-staging PATH BYTES VERSION DETAIL`.
# Reads TRELLIS_HOME, PLAN_TMP; sets RELEASE_STAGING_SCAN_REASON on failure.
dj_host_release_scan() {
  local releases="$TRELLIS_HOME/releases" out rc line label kind base age owner nbytes
  local path version bytes detail
  # shellcheck disable=SC2034  # read by scripts/disk-janitor.sh render_report.
  RELEASE_STAGING_SCAN_REASON=""
  scope_enabled releases || return 0
  if [ ! -d "$releases" ] || [ -L "$releases" ]; then
    RELEASE_STAGING_SCAN_REASON="releases directory unavailable or symlinked"
    return 0
  fi
  if ! out="$(release_store_reap_tmp dry-run 2>/dev/null)"; then
    rc=$?
    case "$out" in *"reapable "*|*"keep "*|*"total entries="*) ;;
      *)
        # shellcheck disable=SC2034  # read by scripts/disk-janitor.sh render_report.
        RELEASE_STAGING_SCAN_REASON="release staging scan failed (exit $rc)"
        # shellcheck disable=SC2034  # EXIT_STATUS is the orchestrator's accumulator.
        EXIT_STATUS=1
        return 0
        ;;
    esac
  fi
  while IFS= read -r line; do
    case "$line" in
      "reap-tmp: reapable "*|"reap-tmp: keep "*)
        label="${line#reap-tmp: }"; label="${label%% *}"
        line="${line#reap-tmp: $label }"
        kind="${line%% *}"; line="${line#"$kind" }"
        base="${line%% *}"
        age="${line#*age=}"; age="${age%%s*}"
        owner="${line#*owner=}"; owner="${owner%% *}"
        nbytes="${line#*bytes=}"; nbytes="${nbytes%%[^0-9]*}"
        case "$base" in .tmp.*) ;; *) continue ;; esac
        # Apex hardening: hold control-character names (field-shift) and
        # validate numerics before any arithmetic or plan_row. Hold rows use
        # a sanitized path (ctrl -> ?) so downstream TSV readers never shift.
        if dj_host_has_ctrl "$base"; then
          version="$(dj_host_release_version "$base" 2>/dev/null)" || version=""
          safe_base="$(printf '%s' "$base" | tr '\011\012\015' '???')"
          plan_row releases candidate release-staging "$releases/$safe_base" 0 "$version" "held: control characters in staging name; manual review"
          continue
        fi
        if ! dj_host_is_uint "$nbytes"; then nbytes=0; fi
        if ! dj_host_is_uint "$age"; then age=0; fi
        version="$(dj_host_release_version "$base" 2>/dev/null)" || version=""
        path="$releases/$base"
        if dj_host_has_ctrl "$path"; then
          safe_path="$(printf '%s' "$path" | tr '\011\012\015' '???')"
          plan_row releases candidate release-staging "$safe_path" 0 "$version" "held: control characters in staging path; manual review"
          continue
        fi
        bytes="$nbytes"
        if [ "$label" = "reapable" ]; then
          detail="orphaned aged staging via reap-tmp — age=${age}s owner=${owner}"
          plan_row releases delete release-staging "$path" "$bytes" "$version" "$detail"
        else
          case "$owner" in
            alive|indeterminate)
              detail="candidate (owner process is live) — owner=${owner} age=${age}s via reap-tmp"
              plan_row releases candidate release-staging "$path" "$bytes" "$version" "$detail"
              ;;
            *)
              if [ "$age" -gt 86400 ] 2>/dev/null; then
                detail="candidate (owner ${owner}) — age=${age}s via reap-tmp"
                plan_row releases candidate release-staging "$path" "$bytes" "$version" "$detail"
              else
                detail="fresh staging — younger via reap-tmp (age=${age}s owner=${owner}); left intact"
                plan_row releases skip release-staging "$path" "$bytes" "$version" "$detail"
              fi
              ;;
          esac
        fi
        ;;
      "reap-tmp: refused "*)
        base="${line#reap-tmp: refused }"; base="${base%% *}"
        case "$base" in .tmp.*) ;; *) continue ;; esac
        if dj_host_has_ctrl "$base"; then
          safe_base="$(printf '%s' "$base" | tr '\011\012\015' '???')"
          plan_row releases candidate release-staging "$releases/$safe_base" 0 "" "held: control characters in staging name; manual review"
          continue
        fi
        version="$(dj_host_release_version "$base" 2>/dev/null)" || version=""
        path="$releases/$base"
        if dj_host_has_ctrl "$path"; then
          safe_path="$(printf '%s' "$path" | tr '\011\012\015' '???')"
          plan_row releases candidate release-staging "$safe_path" 0 "$version" "held: control characters in staging path; manual review"
          continue
        fi
        detail="candidate (reap-tmp refused) — ${line#reap-tmp: refused }"
        plan_row releases candidate release-staging "$path" 0 "$version" "$detail"
        ;;
    esac
  done <<EOF
$out
EOF
}

# dj_host_release_apply — D3 apply: run `release_store_reap_tmp fix` once
# (it revalidates just before removing). Prints removed lines and updates
# RELEASE_STAGING_RECLAIMED_BYTES. Respects confirm_category and --yes via
# the caller's ASSUME_YES.
dj_host_release_apply() {
  local out rc line
  scope_enabled releases || return 0
  [ "${RELEASE_STAGING_DELETE_COUNT:-0}" -gt 0 ] || return 0
  if ! confirm_category "these orphaned release staging snapshots (via reap-tmp)"; then
    return 0
  fi
  if out="$(release_store_reap_tmp fix 2>&1)"; then rc=0; else rc=$?; fi
  printf '%s\n' "$out" | while IFS= read -r line; do
    case "$line" in
      "reap-tmp: removed "*)
        printf '  removed (reap-tmp): %s\n' "${line#reap-tmp: removed }"
        ;;
      "reap-tmp: kept "*"(changed since scan)"*)
        printf '  skipped (plan changed): %s\n' "${line#reap-tmp: }"
        ;;
    esac
  done
  # shellcheck disable=SC2034  # read by the orchestrator's reclaimed summary.
  RELEASE_STAGING_RECLAIMED_BYTES="${RELEASE_STAGING_DELETE_BYTES:-0}"
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 4 ]; then
    # shellcheck disable=SC2034  # EXIT_STATUS is the orchestrator's accumulator.
    EXIT_STATUS=1
  fi
}

# dj_host_store_list — D6: print one TSV row per package store:
#   KIND<TAB>PATH<TAB>BYTES<TAB>MTIME
# Kinds: pnpm-store, uv-cache, bun-cache, go-build, playwright, npm-cache.
# Discovery is hermetic via fake HOME in tests; tools are resolved through
# PATH (which the orchestrator prepends with the tool-path file, since the
# launcher strips PATH). Never follows symlinks for sizing (dj_dir_bytes
# handles that); a symlinked store dir is listed with its link target bytes
# but never pruned via rm.
dj_host_store_list() {
  local store bytes mtime dir
  # pnpm: every ~/Library/pnpm/store/v* plus `pnpm store path`.
  # Apex hardening: skip control-character paths (field-shift) at source.
  for dir in "$HOME/Library/pnpm/store"/v* "$HOME/.local/share/pnpm/store"/v* "$HOME/.pnpm-store"/v*; do
    [ -d "$dir" ] && [ ! -L "$dir" ] || continue
    case "$dir" in *"*"*) continue ;; esac
    if dj_host_has_ctrl "$dir"; then continue; fi
    bytes="$(dj_dir_bytes "$dir")"
    if ! dj_host_is_uint "$bytes"; then bytes=0; fi
    mtime="$(dj_mtime "$dir")"
    if ! dj_host_is_uint "$mtime"; then mtime=0; fi
    printf 'pnpm-store\t%s\t%s\t%s\n' "$dir" "$bytes" "$mtime"
  done
  if command -v pnpm >/dev/null 2>&1; then
    store="$(pnpm store path 2>/dev/null || echo '')"
    if [ -n "$store" ] && [ -d "$store" ] && [ ! -L "$store" ]; then
      if dj_host_has_ctrl "$store"; then :; else
      case "$store" in "$HOME/Library/pnpm/store"/v*|"$HOME/.local/share/pnpm/store"/v*|"$HOME/.pnpm-store"/v*) ;;
        *)
          bytes="$(dj_dir_bytes "$store")"
          if ! dj_host_is_uint "$bytes"; then bytes=0; fi
          mtime="$(dj_mtime "$store")"
          if ! dj_host_is_uint "$mtime"; then mtime=0; fi
          printf 'pnpm-store\t%s\t%s\t%s\n' "$store" "$bytes" "$mtime"
          ;;
      esac
      fi
    fi
  fi
  # uv: `uv cache dir`.
  if command -v uv >/dev/null 2>&1; then
    store="$(uv cache dir 2>/dev/null || echo '')"
    if [ -n "$store" ] && [ -d "$store" ]; then
      if dj_host_has_ctrl "$store"; then :; else
      bytes="$(dj_dir_bytes "$store")"
      if ! dj_host_is_uint "$bytes"; then bytes=0; fi
      mtime="$(dj_mtime "$store")"
      if ! dj_host_is_uint "$mtime"; then mtime=0; fi
      printf 'uv-cache\t%s\t%s\t%s\n' "$store" "$bytes" "$mtime"
      fi
    fi
  fi
  # bun: conventional caches under fake HOME (report-only discovery; prune
  # runs `bun pm cache rm` via PATH).
  for dir in "$HOME/.bun/install/cache" "$HOME/Library/Caches/bun"; do
    [ -d "$dir" ] || continue
    if dj_host_has_ctrl "$dir"; then continue; fi
    bytes="$(dj_dir_bytes "$dir")"
    if ! dj_host_is_uint "$bytes"; then bytes=0; fi
    mtime="$(dj_mtime "$dir")"
    if ! dj_host_is_uint "$mtime"; then mtime=0; fi
    printf 'bun-cache\t%s\t%s\t%s\n' "$dir" "$bytes" "$mtime"
  done
  # go-build: `go env GOCACHE`.
  if command -v go >/dev/null 2>&1; then
    store="$(go env GOCACHE 2>/dev/null || echo '')"
    if [ -n "$store" ] && [ -d "$store" ]; then
      if dj_host_has_ctrl "$store"; then :; else
      bytes="$(dj_dir_bytes "$store")"
      if ! dj_host_is_uint "$bytes"; then bytes=0; fi
      mtime="$(dj_mtime "$store")"
      if ! dj_host_is_uint "$mtime"; then mtime=0; fi
      printf 'go-build\t%s\t%s\t%s\n' "$store" "$bytes" "$mtime"
      fi
    fi
  fi
  # Playwright browsers (report-only; no prune command).
  for dir in "$HOME/.cache/ms-playwright" "$HOME/Library/Caches/ms-playwright"; do
    [ -d "$dir" ] || continue
    if dj_host_has_ctrl "$dir"; then continue; fi
    bytes="$(dj_dir_bytes "$dir")"
    if ! dj_host_is_uint "$bytes"; then bytes=0; fi
    mtime="$(dj_mtime "$dir")"
    if ! dj_host_is_uint "$mtime"; then mtime=0; fi
    printf 'playwright\t%s\t%s\t%s\n' "$dir" "$bytes" "$mtime"
  done
  # npm cache (legacy; report-only).
  if command -v npm >/dev/null 2>&1; then
    store="$(npm config get cache 2>/dev/null || echo '')"
    case "$store" in ''|undefined|null) store="${USER_HOME:-$HOME}/.npm" ;; esac
    if [ -d "$store" ]; then
      if dj_host_has_ctrl "$store"; then :; else
      bytes="$(dj_dir_bytes "$store")"
      if ! dj_host_is_uint "$bytes"; then bytes=0; fi
      mtime="$(dj_mtime "$store")"
      if ! dj_host_is_uint "$mtime"; then mtime=0; fi
      printf 'npm-cache\t%s\t%s\t%s\n' "$store" "$bytes" "$mtime"
      fi
    fi
  fi
  return 0
}

# dj_host_store_report — D6 report: bytes + last use per store; flag pnpm
# majors no registered project resolves to as "removable (operator)".
# Reads TARGETS_TMP for registered project roots when available.
dj_host_store_report() {
  local kind path bytes mtime majors major fresh
  scope_enabled stores || return 0
  echo "== Package stores (per-store via each tool's own prune; never rm) =="
  majors=""
  if [ -n "${TARGETS_TMP:-}" ] && [ -f "$TARGETS_TMP" ]; then
    majors="$(while IFS="$(printf '\t')" read -r _fleet _proj _co _wt _root _common; do
      [ -f "$_root/package.json" ] || continue
      jq -r '.packageManager // empty' "$_root/package.json" 2>/dev/null || true
    done <"$TARGETS_TMP" | grep -oE 'pnpm@[0-9]+' 2>/dev/null | grep -oE '[0-9]+' 2>/dev/null | sort -u 2>/dev/null | tr '\n' ' ' 2>/dev/null || true)"
  fi
  fresh=0
  while IFS="$(printf '\t')" read -r kind path bytes mtime; do
    [ -n "$path" ] || continue
    # Apex hardening: hold control-character paths (field-shift) and coerce
    # non-numeric bytes/mtime to 0 before any use.
    if dj_host_has_ctrl "$path" || dj_host_has_ctrl "$kind"; then
      printf '  [held] %s %s — control characters in path; manual review (never auto-pruned)\n' "$kind" "$path"
      fresh=1
      continue
    fi
    if ! dj_host_is_uint "$bytes"; then bytes=0; fi
    if ! dj_host_is_uint "$mtime"; then mtime=0; fi
    fresh=1
    case "$kind" in
      pnpm-store)
        major="${path##*/v}"; major="${major%%[^0-9]*}"
        if [ -z "${majors// /}" ]; then
          printf '  [keep] pnpm %s (%s, last use %s)\n' "$path" "$(dj_human_bytes "$bytes")" "$mtime"
        else
          case " $majors " in
            *" $major "*)
              printf '  [keep] pnpm %s (%s, last use %s)\n' "$path" "$(dj_human_bytes "$bytes")" "$mtime"
              ;;
            *)
              printf '  [removable (operator)] pnpm %s (%s, last use %s) — no registered project resolves to major %s; operator may remove by hand\n' "$path" "$(dj_human_bytes "$bytes")" "$mtime" "$major"
              ;;
          esac
        fi
        ;;
      *)
        printf '  [report] %s %s (%s, last use %s)\n' "$kind" "$path" "$(dj_human_bytes "$bytes")" "$mtime"
        ;;
    esac
  done <<EOF
$(dj_host_store_list 2>/dev/null || true)
EOF
  [ "$fresh" -eq 1 ] || echo "  (no package stores detected)"
  echo "  apply runs only each tool's own prune (pnpm store prune; uv cache prune; bun pm cache rm; go clean -cache), never rm."
  echo
  return 0
}

# dj_host_store_apply — D6 apply: run each tool's own prune, never rm.
# Tools resolve via PATH (tool-path file prepended by the orchestrator).
# shellcheck disable=SC2034  # EXIT_STATUS assignments below accumulate into the orchestrator's exit class.
dj_host_store_apply() {
  scope_enabled stores || return 0
  if ! confirm_category "package store caches (each tool's own prune, never rm)"; then
    return 0
  fi
  if command -v pnpm >/dev/null 2>&1; then
    if pnpm store prune >/dev/null 2>&1; then
      echo "  pruned: pnpm store prune"
    else
      echo "  pnpm store prune failed" >&2
      EXIT_STATUS=1
    fi
  fi
  if command -v uv >/dev/null 2>&1; then
    if uv cache prune --force >/dev/null 2>&1 || uv cache prune >/dev/null 2>&1; then
      echo "  pruned: uv cache prune"
    else
      echo "  uv cache prune failed" >&2
      EXIT_STATUS=1
    fi
  fi
  if command -v bun >/dev/null 2>&1; then
    if bun pm cache rm >/dev/null 2>&1; then
      echo "  pruned: bun pm cache rm"
    else
      echo "  bun pm cache rm failed" >&2
      EXIT_STATUS=1
    fi
  fi
  if command -v go >/dev/null 2>&1; then
    if go clean -cache >/dev/null 2>&1; then
      echo "  pruned: go clean -cache"
    else
      echo "  go clean -cache failed" >&2
      EXIT_STATUS=1
    fi
  fi
}

# dj_host_worktree_dirty WORKTREE — return 0 iff WORKTREE holds dirty or
# untracked files per `git status --porcelain --untracked-files=all`. Fail
# closed: any git error (unreadable worktree) counts as dirty (held).
# Return 1 iff the tree is clean.
dj_host_worktree_dirty() {
  local wt="${1:-}" status rc
  [ -n "$wt" ] || return 0
  status="$(git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || return 0
  [ -n "$status" ]
}

# dj_host_pi_no_unique_commits WORKTREE — return 0 iff WORKTREE HEAD holds no
# commits unreachable from its parent repository's other branches/tags (A9: no
# work would be lost by removal). The worktree's own branch is excluded from
# the comparison set, so a branch tip is never mistaken for shared history;
# a branch worktree with no upstream is held (cannot prove pushed). Reads the
# parent gitdir from the worktree's .git file; fails closed (non-zero) on any
# query error.
dj_host_pi_no_unique_commits() {
  local wt="${1:-}" gitfile="" gitdir="" parent_gitdir="" own="" count=""
  [ -n "$wt" ] && [ -f "$wt/.git" ] && [ ! -L "$wt/.git" ] || return 1
  if ! IFS= read -r gitfile <"$wt/.git"; then return 1; fi
  case "$gitfile" in "gitdir: "/*/worktrees/*) gitdir="${gitfile#gitdir: }" ;; *) return 1 ;; esac
  parent_gitdir="${gitdir%/worktrees/*}"
  [ -d "$parent_gitdir" ] || return 1
  own="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
  [ -n "$own" ] || return 1
  if [ "$own" != HEAD ]; then
    # On a branch: hold when there is no upstream (unpushed branch ref).
    git -C "$wt" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 || return 1
    # shellcheck disable=SC2086  # own is a validated branch name, never a path.
    count="$(git -C "$wt" rev-list --count HEAD --not --remotes --exclude="$own" --branches 2>/dev/null || echo '')"
  else
    # Detached HEAD carries no branch ref: only the commit reachability matters.
    count="$(git -C "$wt" rev-list --count HEAD --not --remotes --branches 2>/dev/null || echo '')"
  fi
  case "$count" in 0) return 0 ;; *) return 1 ;; esac
}

# dj_host_docker_fstrim_apply — D4: run `colima ssh -- sudo fstrim -av`
# after the BuildKit prune (the orchestrator sets DOCKER_BUILDX_PRUNE_APPLIED=1
# when the prune ran). Skipped with a printed reason when colima is absent or
# not running, when the prune did not run, or when the docker scope is off.
# Never touches volumes/images/containers (spec 059 stands).
# shellcheck disable=SC2034  # EXIT_STATUS assignments below accumulate into the orchestrator's exit class.
dj_host_docker_fstrim_apply() {
  scope_enabled docker || return 0
  if [ "${DOCKER_BUILDX_PRUNE_APPLIED:-0}" -ne 1 ]; then
    echo "  colima fstrim: skipped (BuildKit prune did not run; nothing to follow)"
    return 0
  fi
  if ! command -v colima >/dev/null 2>&1; then
    echo "  colima fstrim: skipped (colima absent)"
    return 0
  fi
  if ! colima status >/dev/null 2>&1; then
    echo "  colima fstrim: skipped (colima not running)"
    return 0
  fi
  if colima ssh -- sudo fstrim -av; then
    echo "  fstrim: colima ssh -- sudo fstrim -av completed"
  else
    echo "  colima fstrim failed" >&2
    EXIT_STATUS=1
  fi
}

# dj_host_logs_scan — D5 logs (report-only): files over logs_min_mb (50)
# and older than logs_min_age_days (7), not open. Scans registered project
# roots (TARGETS_TMP), pruning node_modules/.git/.venv, never following
# symlinks. Emits candidate rows (manual review, never auto-deleted).
# shellcheck disable=SC2034  # EXIT_STATUS assignments below accumulate into the orchestrator's exit class.
dj_host_logs_scan() {
  local root fleet project_id checkout_id worktree_id common found f bytes mtime reason
  local logs_mb logs_age
  scope_enabled logs || return 0
  logs_mb="$(cfg_num '.disk_janitor.logs_min_mb' 50)"
  logs_age="$(cfg_num '.disk_janitor.logs_min_age_days' 7)"
  case "$logs_mb" in ''|*[!0-9]*) logs_mb=50 ;; esac
  case "$logs_age" in ''|*[!0-9]*) logs_age=7 ;; esac
  [ -n "${TARGETS_TMP:-}" ] && [ -f "$TARGETS_TMP" ] || return 0
  while IFS="$(printf '\t')" read -r fleet project_id checkout_id worktree_id root common; do
    [ -d "$root" ] && [ ! -L "$root" ] || continue
    if ! dj_registered_owner_identity "$TRELLIS_HOME" "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$common" "$root" >/dev/null 2>&1; then continue; fi
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if dj_host_has_ctrl "$f"; then
        plan_row logs candidate logfile "$f" 0 "$root" "held: control characters in path; manual review"
        continue
      fi
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      bytes="$(dj_dir_bytes "$f")"
      if ! dj_host_is_uint "$bytes"; then bytes=0; fi
      if [ "$bytes" -lt $(( logs_mb * 1024 * 1024 )) ] 2>/dev/null; then continue; fi
      mtime="$(dj_mtime "$f")"
      if ! dj_host_is_uint "$mtime"; then continue; fi
      if ! dj_cache_is_stale "$mtime" "$logs_age" "$NOW_EPOCH"; then continue; fi
      if reason="$(dj_worktree_in_use "$f" "$LSOF_SNAPSHOT_TMP")"; then
        plan_row logs candidate logfile "$f" "$bytes" "$root" "candidate (in use: $reason); report-only"
        continue
      fi
      plan_row logs candidate logfile "$f" "$bytes" "$root" "over ${logs_mb}MB and older than ${logs_age}d; report-only"
    done <<EOF
$(find -P "$root" \( -name node_modules -o -name .git -o -name .venv -o -name target \) -prune -o -type f -size "+${logs_mb}M" -print 2>/dev/null || true)
EOF
  done <"$TARGETS_TMP"
}

# dj_host_tmp_root — print the canonical D5 tmp scope root: the real per-user
# temp dir (`getconf DARWIN_USER_TEMP_DIR`, physical realpath so /tmp resolves
# to /private/tmp). DJ_DARWIN_TMPDIR_OVERRIDE names it in tests so the real
# per-user temp is never scanned. Never the launcher's per-run TMPDIR, never
# $HOME, never /, never a path with $HOME as a prefix. Return 1 when it
# cannot be resolved safely; the caller refuses the scope with a reason.
dj_host_tmp_root() {
  local base="" real="" home_real=""
  if [ -n "${DJ_DARWIN_TMPDIR_OVERRIDE:-}" ]; then
    base="${DJ_DARWIN_TMPDIR_OVERRIDE}"
  else
    base="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo '')"
  fi
  [ -n "$base" ] || return 1
  case "$base" in /*) ;; *) return 1 ;; esac
  real="$(CDPATH='' cd -P -- "$base" 2>/dev/null && pwd -P)" || return 1
  [ -n "$real" ] && [ -d "$real" ] || return 1
  [ "$real" != / ] || return 1
  home_real="$(CDPATH='' cd -P -- "${HOME:-/}" 2>/dev/null && pwd -P)" || home_real="/nonexistent-home"
  [ -n "$home_real" ] || home_real="/nonexistent-home"
  [ "$real" != "$home_real" ] || return 1
  case "$real/" in "$home_real/"*) return 1 ;; esac
  printf '%s\n' "$real"
}

# dj_host_tmp_scan — D5 tmp: direct children of the per-user temp dir named bats-run-* or rv-*
# older than tmp_ttl_days (2) with no open handle. Emits delete rows (apply)
# and skip rows (young/in-use). Never follows symlinks, maxdepth 1. Refuses
# with a skip reason when the root is unsafe.
dj_host_tmp_scan() {
  local tmpdir ttl entry bytes reason
  scope_enabled tmp || return 0
  if ! tmpdir="$(dj_host_tmp_root 2>/dev/null)"; then
    plan_row tmp skip tmp "-" 0 "-" "tmp scope refused: per-user temp dir unresolvable or unsafe (HOME, /, or under HOME); nothing scanned"
    return 0
  fi
  ttl="$(cfg_num '.disk_janitor.tmp_ttl_days' 2)"
  case "$ttl" in ''|*[!0-9]*) ttl=2 ;; esac
  for entry in "$tmpdir"/bats-run-* "$tmpdir"/rv-*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    if dj_host_has_ctrl "$entry"; then
      plan_row tmp candidate tmp "$entry" 0 "$tmpdir" "held: control characters in path; manual review"
      continue
    fi
    if [ -L "$entry" ]; then
      plan_row tmp skip tmp "$entry" 0 "$tmpdir" "symlink; never listed for deletion"
      continue
    fi
    if dj_pi_entry_fresh "$entry" "$ttl"; then
      plan_row tmp skip tmp "$entry" "$(dj_dir_bytes "$entry")" "$tmpdir" "younger than ${ttl}d; left intact"
      continue
    fi
    if reason="$(dj_worktree_in_use "$entry" "$LSOF_SNAPSHOT_TMP")"; then
      plan_row tmp candidate tmp "$entry" "$(dj_dir_bytes "$entry")" "$tmpdir" "candidate (in use: $reason)"
      continue
    fi
    bytes="$(dj_dir_bytes "$entry")"
    if ! dj_host_is_uint "$bytes"; then bytes=0; fi
    plan_row tmp delete tmp "$entry" "$bytes" "$tmpdir" "older than ${ttl}d with no open handle"
  done
}

# dj_host_tmp_apply — D5 tmp apply: remove delete rows after revalidation.
# The tmp root is re-resolved (never the launcher TMPDIR); each plan path must
# be a direct child of it (canonical parent equality + basename pattern).
# Removal is descriptor-relative: cd into the root, re-check the basename
# (exists, non-symlink, pattern, age, liveness) and rm the relative name —
# never rm -rf on a re-derived absolute string without re-validation.
# shellcheck disable=SC2034  # EXIT_STATUS assignments below accumulate into the orchestrator's exit class.
dj_host_tmp_apply() {
  local scope verdict kind path bytes repo detail reason tmpdir dir dir_real base ttl
  scope_enabled tmp || return 0
  [ "$(awk -F'\t' '$1=="tmp" && $2=="delete" {n++} END {print n+0}' "$PLAN_TMP")" -gt 0 ] || return 0
  if ! confirm_category "tmp scratch (bats-run-*, rv-* older than TTL with no open handle)"; then return 0; fi
  if dj_capture_lsof_snapshot "$LSOF_SNAPSHOT_TMP" 5; then :; else :; fi
  ttl="$(cfg_num '.disk_janitor.tmp_ttl_days' 2)"
  case "$ttl" in ''|*[!0-9]*) ttl=2 ;; esac
  if ! tmpdir="$(dj_host_tmp_root 2>/dev/null)"; then
    echo "  tmp scope refused: per-user temp dir unresolvable or unsafe; nothing removed"
    return 0
  fi
  while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail _a _b _c _d _e; do
    [ "$scope" = "tmp" ] && [ "$verdict" = "delete" ] || continue
    case "$path" in *"$(printf '\t')"*|*$'\n'*) echo "  skipped (plan changed): control characters"; continue ;; esac
    base="$(basename "$path")"
    case "$base" in bats-run-*|rv-*) ;; *) echo "  skipped (plan changed): $path is not tmp scratch"; continue ;; esac
    if [ -L "$path" ]; then echo "  skipped (plan changed): $path is a symlink"; continue; fi
    dir="$(dirname "$path")"
    dir_real="$(CDPATH='' cd -P -- "$dir" 2>/dev/null && pwd -P)" || { echo "  skipped (plan changed): $path parent unresolvable"; continue; }
    [ "$dir_real" = "$tmpdir" ] || { echo "  skipped (plan changed): $path outside tmp root"; continue; }
    if ! dj_host_is_uint "$bytes"; then echo "  skipped: malformed plan bytes for $path"; continue; fi
    if dj_pi_entry_fresh "$tmpdir/$base" "$ttl"; then echo "  skipped (plan changed): $path is fresh"; continue; fi
    if reason="$(dj_worktree_in_use "$tmpdir/$base" "$LSOF_SNAPSHOT_TMP")"; then echo "  skipped (plan changed): $path in use ($reason)"; continue; fi
    if (
      cd -P -- "$tmpdir" 2>/dev/null || exit 1
      [ -e "$base" ] || [ -L "$base" ] || exit 1
      [ ! -L "$base" ] || exit 1
      case "$base" in bats-run-*|rv-*) ;; *) exit 1 ;; esac
      rm -rf -- "$base" 2>/dev/null
    ); then echo "  removed: $path"; else echo "  REFUSED/failed: $path" >&2; EXIT_STATUS=1; fi
  done <"$PLAN_TMP"
}

dj_host_scan() {
  dj_host_logs_scan
  dj_host_tmp_scan
}

# dj_host_transcripts_report — D7: age histogram for codex/pi/claude session
# transcripts (never deleted). Buckets 0-7d, 7-30d, 30d+ with counts + bytes.
# Hermetic via fake HOME in tests; skips missing/symlinked roots; holds ctrl
# paths (never emits them as plan targets — transcripts have no plan rows).
dj_host_transcripts_report() {
  local dir f mtime bytes b0_7 b7_30 b30 n0_7 n7_30 n30_7 now
  scope_enabled transcripts || return 0
  echo "== Session transcripts (host-global, never deleted; age histogram) =="
  now="$(date +%s)"
  case "$now" in ''|*[!0-9]*) now=0 ;; esac
  for dir in "$HOME/.codex" "$HOME/.pi" "$HOME/.claude/projects"; do
    if [ ! -d "$dir" ] || [ -L "$dir" ]; then
      printf '  %s: missing or symlinked; not scanned\n' "$dir"
      continue
    fi
    b0_7=0; b7_30=0; b30=0; n0_7=0; n7_30=0; n30_7=0
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if dj_host_has_ctrl "$f"; then continue; fi
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      mtime="$(dj_mtime "$f")"
      bytes="$(dj_dir_bytes "$f")"
      if ! dj_host_is_uint "$mtime"; then continue; fi
      if ! dj_host_is_uint "$bytes"; then bytes=0; fi
      if [ "$(( now - mtime ))" -lt $(( 7 * 86400 )) ] 2>/dev/null; then
        n0_7=$(( n0_7 + 1 )); b0_7=$(( b0_7 + bytes ))
      elif [ "$(( now - mtime ))" -lt $(( 30 * 86400 )) ] 2>/dev/null; then
        n7_30=$(( n7_30 + 1 )); b7_30=$(( b7_30 + bytes ))
      else
        n30_7=$(( n30_7 + 1 )); b30=$(( b30 + bytes ))
      fi
    done <<EOF
$(find -P "$dir" -type f -print 2>/dev/null || true)
EOF
    printf '  %s: 0-7d %d files %s; 7-30d %d files %s; 30d+ %d files %s (never deleted)\n' \
      "$dir" "$n0_7" "$(dj_human_bytes "$b0_7")" "$n7_30" "$(dj_human_bytes "$b7_30")" "$n30_7" "$(dj_human_bytes "$b30")"
  done
  echo
  return 0
}

dj_host_render() {
  local scope verdict kind path bytes repo detail
  if scope_enabled stores; then
    dj_host_store_report
  fi
  if scope_enabled docker; then
    echo "== Docker fstrim (host-global, via colima; never volume/image/container removal) =="
    echo "  apply runs \`colima ssh -- sudo fstrim -av\` after the BuildKit prune; skipped when colima is absent or not running."
    echo
  fi
  if scope_enabled logs; then
    echo "== Logs (host-global, report-only) =="
    while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail; do
      [ "$scope" = "logs" ] || continue
      printf '  [%s] %s (%s) — %s\n' "$verdict" "$path" "$(dj_human_bytes "$bytes")" "$detail"
    done <"$PLAN_TMP"
    echo
  fi
  if scope_enabled tmp; then
    echo "== Tmp scratch (host-global) =="
    while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail; do
      [ "$scope" = "tmp" ] || continue
      printf '  [%s] %s (%s) — %s\n' "$verdict" "$path" "$(dj_human_bytes "$bytes")" "$detail"
    done <"$PLAN_TMP"
    echo
  fi
  if scope_enabled transcripts; then
    dj_host_transcripts_report
  fi
}

# dj_host_pi_spill_apply — C3: delete pi-bash-*.log plan rows verdict=delete,
# re-checking age/size (1d or 1 GiB), no open handle via a fresh lsof snapshot
# just before unlinking, never following symlinks, maxdepth-1 direct children
# only (the scan guarantees the set). Respects pi_apply:false (report-only).
# shellcheck disable=SC2034  # EXIT_STATUS assignments below accumulate into the orchestrator's exit class.
dj_host_pi_spill_apply() {
  local scope verdict kind path bytes repo detail reason size
  scope_enabled pi || return 0
  [ "${PI_APPLY:-true}" = "true" ] || return 0
  [ "$(awk -F'\t' '$1=="pi" && $2=="delete" {n++} END {print n+0}' "$PLAN_TMP")" -gt 0 ] || return 0
  if ! confirm_category "pi spill logs older than 1 day or over 1 GiB with no open handle"; then
    return 0
  fi
  if dj_capture_lsof_snapshot "$LSOF_SNAPSHOT_TMP" 5; then :; else :; fi
  while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail _a _b _c _d _e; do
    [ "$scope" = "pi" ] && [ "$verdict" = "delete" ] || continue
    [ "$kind" = "pi-spill-log" ] || continue
    case "$path" in *"$(printf '\t')"*|*$'\n'*) echo "  skipped (plan changed): control characters in path"; continue ;; esac
    if [ -L "$path" ] || [ ! -f "$path" ]; then
      echo "  skipped (plan changed): $path is no longer a regular non-symlink file"
      continue
    fi
    case "$(basename "$path")" in pi-bash-*.log) ;; *) echo "  skipped (plan changed): $path is not a spill log"; continue ;; esac
    if ! dj_host_is_uint "$bytes"; then echo "  skipped (plan changed): malformed plan bytes for $path"; continue; fi
    if size="$(dj_file_bytes "$path")"; then :; else echo "  skipped (plan changed): $path unreadable"; continue; fi
    if ! dj_host_is_uint "$size"; then echo "  skipped (plan changed): malformed size for $path"; continue; fi
    if [ "$size" -gt "$PI_SPILL_MAX_BYTES" ]; then :; else
      if dj_pi_entry_fresh "$path" "$PI_SPILL_TTL_DAYS"; then echo "  skipped (plan changed): $path is fresh"; continue; fi
    fi
    if reason="$(dj_worktree_in_use "$path" "$LSOF_SNAPSHOT_TMP")"; then
      echo "  skipped (plan changed): $path in use ($reason)"
      continue
    fi
    if rm -f "$path"; then
      echo "  removed: $path"
    else
      echo "  REFUSED/failed: $path" >&2
      EXIT_STATUS=1
    fi
  done <"$PLAN_TMP"
}

# dj_host_pi_worktree_apply — A9: remove orphan pi-agent-* worktrees verdict=delete
# via `git worktree remove` (no --force), revalidating age (TTL), cleanliness
# (no dirty/untracked), uniqueness (no unique commits) and liveness just
# before acting. Respects pi_apply:false.
# shellcheck disable=SC2034  # EXIT_STATUS assignments below accumulate into the orchestrator's exit class.
dj_host_pi_worktree_apply() {
  local scope verdict kind path bytes repo detail gitfile gitdir parent_gitdir parent_main reason
  scope_enabled pi || return 0
  [ "${PI_APPLY:-true}" = "true" ] || return 0
  [ "$(awk -F'\t' '$1=="pi" && $2=="delete" && $3=="pi-worktree" {n++} END {print n+0}' "$PLAN_TMP")" -gt 0 ] || return 0
  if ! confirm_category "orphan pi-agent worktrees older than ${PI_WORKTREE_TTL_DAYS:-7}d with no unique commits and no dirty files"; then
    return 0
  fi
  if dj_capture_lsof_snapshot "$LSOF_SNAPSHOT_TMP" 5; then :; else :; fi
  while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail _a _b _c _d _e; do
    [ "$scope" = "pi" ] && [ "$verdict" = "delete" ] && [ "$kind" = "pi-worktree" ] || continue
    case "$path" in *"$(printf '\t')"*|*$'\n'*) echo "  skipped (plan changed): control characters in path"; continue ;; esac
    if [ -L "$path" ] || [ ! -d "$path" ]; then echo "  skipped (plan changed): $path gone or symlinked"; continue; fi
    case "$(basename "$path")" in pi-agent-*) ;; *) echo "  skipped (plan changed): $path is not pi-agent-*"; continue ;; esac
    if ! dj_host_is_uint "$bytes"; then echo "  skipped (plan changed): malformed plan bytes for $path"; continue; fi
    if dj_pi_entry_fresh "$path" "${PI_WORKTREE_TTL_DAYS:-7}"; then echo "  skipped (plan changed): $path is fresh"; continue; fi
    if dj_host_worktree_dirty "$path"; then echo "  skipped (plan changed): $path dirty or untracked files"; continue; fi
    if ! dj_host_pi_no_unique_commits "$path"; then echo "  skipped (plan changed): $path holds unique commits"; continue; fi
    if reason="$(dj_worktree_in_use "$path" "$LSOF_SNAPSHOT_TMP")"; then echo "  skipped (plan changed): $path in use ($reason)"; continue; fi
    if [ ! -f "$path/.git" ] || [ -L "$path/.git" ]; then echo "  skipped (plan changed): $path .git unreadable"; continue; fi
    if ! IFS= read -r gitfile <"$path/.git"; then echo "  skipped (plan changed): $path .git unreadable"; continue; fi
    case "$gitfile" in "gitdir: "/*/worktrees/*) gitdir="${gitfile#gitdir: }" ;; *) echo "  skipped (plan changed): $path .git malformed"; continue ;; esac
    parent_gitdir="${gitdir%/worktrees/*}"
    parent_main="$(git --git-dir="$parent_gitdir" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')"
    [ -n "$parent_main" ] && [ -d "$parent_main" ] || { echo "  skipped (plan changed): parent of $path unavailable"; continue; }
    if git -C "$parent_main" worktree remove "$path" 2>/dev/null; then
      echo "  removed worktree: $path"
    else
      echo "  REFUSED/failed: $path (git worktree remove refused)" >&2
      EXIT_STATUS=1
    fi
  done <"$PLAN_TMP"
}

dj_host_apply() {
  if scope_enabled stores; then
    dj_host_store_apply
  fi
  dj_host_pi_spill_apply
  dj_host_pi_worktree_apply
  dj_host_tmp_apply
  dj_host_docker_fstrim_apply
  dj_host_render
}
