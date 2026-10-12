#!/usr/bin/env bash
# Run all canonical gates + project-local stack-profile validators.
# Usage: run-all.sh [--range=<gitspec> | --base=<ref>] [--mode=push|merge]
# Output: a single verdict block as defined in SKILL.md.
#
# --mode (default merge) controls PR-shape downgrade (DL-P7-02): at push, a
# FAIL in the PR-shape gates (PR hygiene, Docs discipline, Analyze) is remapped
# to WARN so a WIP push is not blocked on shape. The always-hard gates
# (Secrets, Bypass markers, Tests, Security) NEVER downgrade at any mode. At
# merge the verdict is strict — no downgrade. A MISSING --mode resolves to merge
# (the fail-closed default); an UNKNOWN --mode VALUE is refused by the argument
# guard below rather than reinterpreted, so a typo is reported, not silently
# downgraded to the strict mode. Merge mode takes NO default range: without an
# explicit --range or --base it refuses with exit 1 before any check runs (a
# scratch clone with no local main/master would otherwise gate only
# HEAD~1..HEAD).
#
# Gate config (process-gate-local/local.config.sh, stack validators, the
# secrets allowlist) is read from the range BASE as data, never from the tree
# under review. A range that changes gate config is gated with the base config
# and prints a notice; at merge it is BLOCKED until the repo owner has posted
# `gate-config-approved: <head sha>` on the PR (read via gh; no override).
# A push that targets main/master (pre-push passes --target=main) is BLOCKED
# on a gate-config change even with an approved PR. Every BLOCKED exit renders
# an Overall line; callers treat a passing rc without one as a failure.

# Drop every function this shell already has — imported from the environment
# (exported BASH_FUNC_*) or planted by a startup file — before anything runs,
# so none can stand in for a command and none is passed on to a row. Every
# command name can be shadowed, `builtin`, `unset` and `set` included; a
# variable assignment cannot. POSIXLY_CORRECT turns on POSIX mode, where the
# special builtins (`unset`, `set`) are found before functions, so the first
# purge cannot be intercepted; the rest go once `builtin` is the real one.
# (Same prologue as security-gate/scripts/run-diff.sh.)
POSIXLY_CORRECT=y
unset -f builtin command type set unset compgen
set +o posix
builtin unset POSIXLY_CORRECT
while builtin read -r __pg_fn; do
  builtin unset -f "$__pg_fn"
done < <(builtin compgen -A function)
builtin unset __pg_fn
set -uo pipefail
# No startup file runs in anything this aggregator launches: rows start with
# `bash -p` (no imported functions, no BASH_ENV), and only validators get the
# trusted BASH_ENV guard set below. A startup file inherited by run-all itself
# has already run before this line, so direct callers launch it clean:
# bash -p run-all.sh (the pre-push carriers do).
unset BASH_ENV ENV

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$SKILL_DIR/scripts/lib/common.sh"
# A startup file may already have run in this shell: drop any functions it
# planted over the tools before the gate uses them.
pg_unshadow

# common.sh sets `set -euo pipefail`. The aggregator INTENTIONALLY runs
# child gates that may exit non-zero (warn=2, fail=1) — disable -e so those
# returns get captured into RESULTS rather than exiting the aggregator.
set +e

# --- argument guard -------------------------------------------------------
# Neither pg_parse_range nor pg_parse_mode has an unknown-argument arm: they
# scan for their own prefix and silently ignore everything else. That made
# `run-all.sh --help` — and any typo'd flag — start a FULL gate run against the
# defaulted range instead of reporting the mistake. Observed 2026-09-07: a
# `--help` invocation launched a complete four-shard suite. Validate here,
# before any gate work, and refuse rather than launch. Documented valid flags
# are --range=<gitspec>, --base=<ref> (spec 067), --mode=push|merge and
# --target=main.
pg_usage() {
  printf 'Usage: run-all.sh [--range=<gitspec> | --base=<ref>] [--mode=push|merge] [--target=main]\n'
  printf '\n'
  printf '  --range=<gitspec>  commit range to gate, used verbatim\n'
  printf '  --base=<ref>       gate merge-base(<ref>, HEAD)..HEAD. Merge mode needs\n'
  printf '                     --range or --base and takes no default; in push mode\n'
  printf '                     with neither flag the diff-base resolver\n'
  printf '                     (lib/diff-base.sh) picks the base; if it cannot,\n'
  printf '                     every commit not on local main (else master) is\n'
  printf '                     gated, else the run refuses (never HEAD~1..HEAD)\n'
  printf '  --mode=push|merge  verdict strictness (default merge when the flag is\n'
  printf '                     absent; any other value is refused, not remapped)\n'
  printf '  --target=main      the push targets main/master (set by pre-push): a\n'
  printf '                     gate-config change is BLOCKED, approved or not\n'
  printf '  -h, --help         print this and exit without running any gate\n'
}
_pg_range=""; _pg_base=""
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      pg_usage
      exit 0
      ;;
    --mode=*)
      # Validate the VALUE, not just the shape. pg_parse_mode resolves any
      # unknown value to `merge` silently; fail-closed is the right default but
      # a typo should be reported, not reinterpreted. Supported values are
      # exactly those documented in the usage line and the header comment.
      case "${arg#--mode=}" in
        push|merge) ;;
        *)
          printf 'run-all.sh: unknown --mode value: %s (supported: push, merge)\n' "${arg#--mode=}" >&2
          pg_usage >&2
          exit 2
          ;;
      esac
      ;;
    --target=main) ;;
    --target=*)
      printf 'run-all.sh: unknown --target value: %s (supported: main)\n' "${arg#--target=}" >&2
      pg_usage >&2
      exit 2
      ;;
    --range=*)
      if [ -z "${arg#--range=}" ]; then
        printf 'run-all.sh: --range= requires a gitspec\n' >&2
        pg_usage >&2
        exit 2
      fi
      _pg_range="${arg#--range=}"
      ;;
    --base=*)
      if [ -z "${arg#--base=}" ]; then
        printf 'run-all.sh: --base= requires a ref\n' >&2
        pg_usage >&2
        exit 2
      fi
      _pg_base="${arg#--base=}"
      ;;
    *)
      printf 'run-all.sh: unknown argument: %s\n' "$arg" >&2
      pg_usage >&2
      exit 2
      ;;
  esac
done

PG_MODE="$(pg_parse_mode "$@")"
export PG_MODE
PG_TARGET_MAIN=false
for arg in "$@"; do
  [ "$arg" != --target=main ] || PG_TARGET_MAIN=true
done
# Coordinator ruling 1.3.11 (fail-closed merge range): merge mode never
# defaults a range. Without an explicit --range or --base a scratch clone with
# no local main/master would gate only HEAD~1..HEAD while reporting a full
# merge verdict. Refuse here — one place, before any check runs — with the
# BLOCKED code (exit 1): the pre-push rc mapping lets exit 2 through as
# NEEDS-CHANGES warn, so only 1 fails the push closed. --base satisfies it
# (spec 067: pr-gate-shiftleft passes --base=<PR base>); any explicit --range
# is unaffected in either mode.
if [ "$PG_MODE" = merge ] && [ -z "$_pg_range" ] && [ -z "$_pg_base" ]; then
  printf 'merge mode requires --range/--base\n' >&2
  exit 1
fi
# Spec 067: resolve once in this shell, so every row and the receipt printed
# under the verdict header share one range. An explicit --range stays verbatim
# (R1) and is gated even when the resolver cannot verify it; --base must
# resolve, and no flag must resolve or take the D1 main/master fallback
# (pg_resolve_diff_base), or the run stops before any check. This block never
# refuses on mode; merge mode's own --range/--base requirement is 1.3.11's,
# ahead of it.
if [ -n "$_pg_range" ] && [ -n "$_pg_base" ]; then
  printf 'run-all.sh: pass --range or --base, not both\n' >&2
  pg_usage >&2
  exit 2
fi
pg_resolve_diff_base "$@"; _pg_db_rc=$?
DIFF_BASE_RECEIPT="$(db_receipt)"
RANGE="${_pg_range:-$DB_RANGE}"
if [ -z "$_pg_range" ] && [ "$_pg_db_rc" -ne 0 ]; then
  printf '%s\nrun-all.sh: %s\n' "$DIFF_BASE_RECEIPT" "$DB_REASON" >&2
  exit 1
fi
PROJECT_DIR="$(pg_project_dir)"

# A refusal that still renders a verdict: callers treat a passing rc without an
# Overall line as a failure, so every early BLOCKED carries one.
pg_blocked_verdict() {
  printf "## process-gate verdict (mode=%s)\n\n%s\n\nOverall: BLOCKED\n\n" "$PG_MODE" "$1"
  exit 1
}

# Config comes from the range BASE as data, never from the tree under review:
# a range cannot loosen the gate that judges it.
PG_CONFIG_ERROR=""
pg_load_config --range="$RANGE" >/dev/null ||
  pg_blocked_verdict "${PG_CONFIG_ERROR:-process-gate local config did not load}"

# pg_audit_dir_values: read a security-gate local config on stdin with the
# security gate's own data grammar (run-diff.sh parse_config_data): blank and
# comment lines, and SECURITY_GATE_*/LLM_* = a bare word, '...', "..." without
# $ ` \, or "${KEY:-literal}" naming its own key. Prints every value assigned
# to SECURITY_GATE_AUDIT_DIR; non-zero when any line is not data.
pg_audit_dir_values() {
  local LC_ALL=C line key val
  local re_assign='^(SECURITY_GATE_[A-Z0-9_]+|LLM_[A-Z0-9_]+)=(.*)$'
  local re_tail='([[:space:]]+(#.*)?)?$'
  local re_dq='^"([^"$`\\]*)"'"$re_tail"
  local re_sq="^'([^']*)'$re_tail"
  local re_bare='^([A-Za-z0-9_./:,@+%=-]*)'"$re_tail"
  local re_def='^"[$][{]([A-Z0-9_]+):-([^"$`\\}]*)[}]"'"$re_tail"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in ''|'#'*) continue ;; esac
    [[ "$line" =~ $re_assign ]] || return 1
    key="${BASH_REMATCH[1]}" val="${BASH_REMATCH[2]}"
    if [[ "$val" =~ $re_def ]]; then
      [ "${BASH_REMATCH[1]}" = "$key" ] || return 1
      val="${BASH_REMATCH[2]}"
    elif [[ "$val" =~ $re_dq ]] || [[ "$val" =~ $re_sq ]] || [[ "$val" =~ $re_bare ]]; then
      val="${BASH_REMATCH[1]}"
    else
      return 1
    fi
    [ "$key" != SECURITY_GATE_AUDIT_DIR ] || printf '%s\n' "$val"
  done
}

# pg_add_audit_dir <dir>: add a normalised audit dir to PG_AUDIT_DIRS.
pg_add_audit_dir() {
  local d="$1"
  while [ "${d#./}" != "$d" ]; do d="${d#./}"; done
  while [ "${d%/}" != "$d" ]; do d="${d%/}"; done
  [ -z "$d" ] || PG_AUDIT_DIRS+=("$d")
}

# The security gate reads baselines from SECURITY_GATE_AUDIT_DIR (default
# audits), which the environment or its base-side local config may set. Every
# candidate dir is gate-config namespace (pg_is_gate_config_path): audits/,
# the environment's (which can only add one) and every value either config
# twin assigns. A config the security gate would not read as data makes every
# *-baseline-*.json at any depth gate config (PG_AUDIT_ANY).
PG_AUDIT_DIRS=(audits)
PG_AUDIT_ANY=false
pg_add_audit_dir "${SECURITY_GATE_AUDIT_DIR:-}"
for _rel in .claude/skills/security-gate-local/local.config.sh .agents/skills/security-gate-local/local.config.sh; do
  _rc=0
  pg_base_path "$PROJECT_DIR" "$PG_CONFIG_BASE" "$_rel" || _rc=$?
  case "$_rc" in
    0) ;;
    1) continue ;;
    *) pg_blocked_verdict "security-gate local config $_rel at range base $PG_CONFIG_BASE is not a regular file, or is reached through a symlink (or could not be read)" ;;
  esac
  _content="$(git -C "$PROJECT_DIR" show "$PG_CONFIG_BASE:./$_rel")" ||
    pg_blocked_verdict "process-gate cannot read $_rel at range base $PG_CONFIG_BASE"
  if _values="$(pg_audit_dir_values <<< "$_content")"; then
    while IFS= read -r _v; do
      pg_add_audit_dir "$_v"
    done <<< "$_values"
  else
    PG_AUDIT_ANY=true
  fi
done
unset _rel _rc _content _values _v

# Bash 3.2 compatibility: parallel arrays instead of associative arrays.
# idx: 0 PR hygiene, 1 Secrets, 2 Bypass markers, 3 Tests & coverage,
#      4 Docs discipline, 5 Stack profile, 6 Security (diff), 7 Analyze,
#      8 Anti-slop.
LABELS=("PR hygiene" "Secrets" "Bypass markers" "Tests & coverage" "Docs discipline" "Stack profile" "Security (diff)" "Analyze" "Anti-slop")
RESULTS=("" "" "" "" "" "" "" "" "")
FINDINGS=("" "" "" "" "" "" "" "" "")

set_result() {
  local idx="$1" status="$2" out="$3"
  RESULTS[$idx]="$status"
  FINDINGS[$idx]="$out"
}

# PR-shape downgrade set (DL-P7-02): a FAIL in these gates is remapped to WARN
# ONLY when PG_MODE=push. The always-hard gates (1 Secrets, 2 Bypass markers,
# 3 Tests, 6 Security) are deliberately absent and NEVER downgrade. Stack
# profile (5) is set inline (not via run_gate) and keeps its validator verdict.
pg_is_pr_shape_idx() {
  case "$1" in
    0|4|7) return 0 ;;
    *)     return 1 ;;
  esac
}

run_gate() {
  local idx="$1" script="$2"
  local out rc status
  shift 2
  out="$(env -u BASH_ENV -u ENV bash -p "$script" --range="$RANGE" "$@" 2>&1)"; rc=$?
  case "$rc" in
    0) status="pass" ;;
    2) status="warn" ;;
    *) status="fail" ;;
  esac
  # Mode-aware downgrade: at push, a PR-shape FAIL becomes WARN. Never at merge,
  # never for the always-hard gates. Keyed on idx membership + PG_MODE only.
  if [ "$status" = "fail" ] && [ "$PG_MODE" = "push" ] && pg_is_pr_shape_idx "$idx"; then
    status="warn"
    out="${out}"$'\n'"  [process-gate] mode=push: PR-shape FAIL downgraded to WARN (would BLOCK at merge)"
  fi
  set_result "$idx" "$status" "$out"
}

# pg_normalize_rel <path>: collapse `.`/`..` in a project-relative path. Prints
# nothing for a path that escapes the project.
pg_normalize_rel() {
  local parts part kept=() k=0 i out
  IFS=/ read -r -a parts <<< "$1"
  for part in ${parts[@]+"${parts[@]}"}; do
    case "$part" in
      ''|.) ;;
      ..) [ "$k" -gt 0 ] || return 0; k=$((k - 1)) ;;
      *) kept[k]="$part"; k=$((k + 1)) ;;
    esac
  done
  [ "$k" -gt 0 ] || return 0
  out="${kept[0]}"
  for ((i = 1; i < k; i++)); do out="$out/${kept[i]}"; done
  printf '%s\n' "$out"
}

# pg_normalize_abs <absolute path>: collapse `//`, `.` and `..` lexically.
pg_normalize_abs() {
  local parts part kept=() k=0 i out=""
  IFS=/ read -r -a parts <<< "$1"
  for part in ${parts[@]+"${parts[@]}"}; do
    case "$part" in
      ''|.) ;;
      ..) [ "$k" -eq 0 ] || k=$((k - 1)) ;;
      *) kept[k]="$part"; k=$((k + 1)) ;;
    esac
  done
  for ((i = 0; i < k; i++)); do out="$out/${kept[i]}"; done
  printf '%s\n' "${out:-/}"
}

# project_rel_of <absolute path>: the project-relative path of a validator
# named by absolute path. Only the PROJECT ROOT is resolved physically: the
# path is normalised lexically and matched against the root's logical or
# physical spelling, or against an outside directory whose physical path is
# exactly the root (a symlinked alias of the root). Nothing below the root is
# resolved in the working tree: pg_base_path walks the rest in the BASE tree,
# so a range cannot redirect a validator through its own directory symlinks.
# Prints nothing when the path is outside the project, or reaches into it
# through a symlink to a subdirectory.
project_rel_of() {
  local p prefix="" part rest phys
  p="$(pg_normalize_abs "$1")"
  case "$p" in
    "$PROJECT_LOG"/*) pg_normalize_rel "${p#"$PROJECT_LOG"/}"; return ;;
    "$PROJECT_PHYS"/*) pg_normalize_rel "${p#"$PROJECT_PHYS"/}"; return ;;
  esac
  rest="${p#/}"
  while :; do
    case "$rest" in
      */*) ;;
      *) return 0 ;;
    esac
    part="${rest%%/*}"; rest="${rest#*/}"
    prefix="$prefix/$part"
    [ -d "$prefix" ] || return 0
    phys="$(cd -P "$prefix" 2>/dev/null && pwd -P)" || return 0
    case "$phys" in
      "$PROJECT_PHYS") pg_normalize_rel "$rest"; return ;;
      "$PROJECT_PHYS"/*) return 0 ;;
    esac
  done
}

# stack_validator_rels <validator>: the project-relative paths a validator
# resolves to, in lookup order, spelled lexically. An absolute path maps
# through project_rel_of; one outside the project has none. Callers check each
# against the base tree with pg_base_path.
stack_validator_rels() {
  local v="$1" dir dirs=()
  case "$v" in
    /*) project_rel_of "$v"; return ;;
  esac
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -z "${CODEX_PROJECT_DIR:-}" ]; then
    dirs=(
      .claude/skills/process-gate-local
      .agents/skills/process-gate-local
      .claude/skills/process-gate
      .agents/skills/process-gate
    )
  else
    dirs=(
      .agents/skills/process-gate-local
      .claude/skills/process-gate-local
      .agents/skills/process-gate
      .claude/skills/process-gate
    )
  fi
  for dir in "${dirs[@]}"; do
    pg_normalize_rel "$dir/$v"
  done
}

# materialise_base <path>: copy every regular-file blob at <path> in the range
# base (one file, or a tree recursively) into PG_TRUSTED_ROOT under the same
# project-relative path, keeping the exec bit of 100755 blobs. Symlinks and
# submodules are never copied. Non-zero when git cannot list or read the base.
# Status framing as in lib/common.sh (an empty record ends the data).
materialise_base() {
  local rec rc="" ended=0 meta path dir
  while IFS= read -r -d '' rec; do
    if [ "$ended" -eq 1 ]; then rc="$rec"; continue; fi
    if [ -z "$rec" ]; then ended=1; continue; fi
    meta="${rec%%$'\t'*}"; path="${rec#*$'\t'}"
    case "$meta" in
      "100644 blob "*|"100755 blob "*) ;;
      *) continue ;;
    esac
    case "$path" in
      */*) dir="$PG_TRUSTED_ROOT/${path%/*}" ;;
      *) dir="$PG_TRUSTED_ROOT" ;;
    esac
    mkdir -p "$dir" || return 1
    git -C "$PROJECT_DIR" cat-file blob "${meta##* }" > "$PG_TRUSTED_ROOT/$path" || return 1
    case "$meta" in
      "100755 "*) chmod 755 "$PG_TRUSTED_ROOT/$path" || return 1 ;;
    esac
  done < <(git -C "$PROJECT_DIR" --literal-pathspecs ls-tree -r -z "$PG_CONFIG_BASE" -- "$1" 2>/dev/null; printf '\0%s\0' "$?")
  [ "$rc" = 0 ]
}

# resolve_stack_validator <validator>: print the path to run. Project
# validators run only as their range-BASE copy under PG_TRUSTED_ROOT; a
# relative name not in the project falls back to the canonical skill. On
# refusal prints the reason (never a path) and returns non-zero: a validator
# outside the project, or one that is not a regular file at the base.
resolve_stack_validator() {
  local v="$1" rel rc candidate

  if [ -z "$v" ]; then
    return 1
  fi

  while IFS= read -r rel; do
    rc=0
    pg_base_path "$PROJECT_DIR" "$PG_CONFIG_BASE" "$rel" || rc=$?
    case "$rc" in
      0)
        candidate="$PG_TRUSTED_ROOT/$rel"
        # -f (regular-file), NOT -x: the validator is run via `bash "$vpath"`
        # (idx-5 block), so the exec bit is irrelevant. The base copy keeps no
        # exec bit and must resolve, not be treated as missing (DL-P7-08).
        if [ -f "$candidate" ]; then
          printf "%s" "$candidate"
          return 0
        fi
        ;;
      1) ;;
      *)
        printf 'validator refused: %s at the range base is not a regular file, or is reached through a symlink' "$rel"
        return 1
        ;;
    esac
  done < <(stack_validator_rels "$v")

  case "$v" in
    /*)
      if [ -z "$(stack_validator_rels "$v")" ]; then
        printf 'validator refused: %s is outside the project (unsupported)' "$v"
        return 1
      fi
      ;;
    *)
      candidate="$SKILL_DIR/$v"
      # -f (regular-file), NOT -x — see the project arm above (DL-P7-08).
      if [ -f "$candidate" ]; then
        printf "%s" "$candidate"
        return 0
      fi
      ;;
  esac
  printf 'validator missing: %s' "$v"
  return 1
}

# validator_dep_rels: PROCESS_GATE_VALIDATOR_DEPS (project-relative helper
# files or directories validators execute or source), normalised. An absolute
# or escaping entry prints `!<entry>` so the caller refuses it.
validator_dep_rels() {
  local d rel
  for d in ${PROCESS_GATE_VALIDATOR_DEPS[@]+"${PROCESS_GATE_VALIDATOR_DEPS[@]}"}; do
    [ -n "$d" ] || continue
    case "$d" in
      /*) printf '!%s\n' "$d"; continue ;;
    esac
    rel="$(pg_normalize_rel "$d")"
    if [ -n "$rel" ]; then
      printf '%s\n' "$rel"
    else
      printf '!%s\n' "$d"
    fi
  done
}

# pg_is_gate_config_path <path>: the reserved gate-config namespace. The case
# arm is the security gate's is_security_config_path (run-diff.sh) verbatim:
# both gate-local twins, this gate's deprecated config, secrets-allowlist.txt,
# the scanners' root config, the B0-6 loader paths (.pi, .agents/agents,
# .agents/workflows and .agents/skills at any depth), .trellis/ and
# .trellis.json at any depth, and .envrc/.env* at any depth, matched by path
# only: their contents are never read. Its audit-dir arm is generalised here:
# baselines in every audit dir the security gate may read (PG_AUDIT_DIRS,
# folded with the paths), or at any depth when its config is not data.
# Callers pass the path already folded (gate_config_changes: NFKC + casefold;
# a path with any non-ASCII byte is gate config before it gets here), and the
# match is case-insensitive too: on a case-insensitive checkout `.PI/x` lands
# in `.pi/`.
pg_is_gate_config_path() {
  local rc=1 d
  shopt -s nocasematch
  if [ "$PG_AUDIT_ANY" = true ]; then
    case "$1" in *-baseline-*.json) rc=0 ;; esac
  fi
  for d in "${PG_AUDIT_DIRS_FOLDED[@]}"; do
    case "$1" in "$d"/*-baseline-*.json) rc=0 ;; esac
  done
  case "$1" in
    .claude/skills/security-gate-local|.claude/skills/security-gate-local/*|\
    .claude/skills/process-gate-local|.claude/skills/process-gate-local/*|\
    .agents/skills/process-gate-local|.agents/skills/process-gate-local/*|\
    .claude/skills/process-gate/local.config.sh|\
    secrets-allowlist.txt|*/secrets-allowlist.txt|\
    .agents/skills/security-gate-local|.agents/skills/security-gate-local/*|\
    .gitleaks.toml|.gitleaksignore|.semgrepignore|osv-scanner.toml|\
    .pi|.pi/*|*/.pi|*/.pi/*|\
    .agents/agents|.agents/agents/*|*/.agents/agents|*/.agents/agents/*|\
    .agents/workflows|.agents/workflows/*|*/.agents/workflows|*/.agents/workflows/*|\
    .agents/skills|.agents/skills/*|*/.agents/skills|*/.agents/skills/*|\
    .trellis|.trellis/*|*/.trellis|*/.trellis/*|\
    .envrc|*/.envrc|.env*|*/.env*|\
    .trellis.json|*/.trellis.json) rc=0 ;;
  esac
  shopt -u nocasematch
  return "$rc"
}

# gate_config_changes: one display line per gate-config path the range adds,
# changes or deletes — the namespace in pg_is_gate_config_path — plus the
# base config's stack
# validators and declared validator dependencies. Reads NUL-delimited names so
# any filename is matched exactly; the status record follows an empty record,
# so no filename can be taken for it. Non-zero when the list cannot be read.
#
# Release-owner ruling: a changed path with ANY non-ASCII byte, anywhere, is
# gate config (a case-insensitive filesystem folds `.agents/ſkills/x` into
# `.agents/skills/x`, and no look-alike heuristic is complete). ASCII paths are
# matched in their NFKC + casefold form, so case variants of the protected set
# count too. One python3 -I call folds the whole list; the same helper as the
# security gate's (run-diff.sh).
PG_FOLD_PY='
import os, sys, unicodedata


def fold(text):
    return unicodedata.normalize("NFKC", unicodedata.normalize("NFKC", text).casefold())


out = sys.stdout.buffer
for item in sys.stdin.buffer.read().split(b"\0"):
    if not item:
        continue
    # Any non-ASCII byte anywhere in the raw path makes it gate config.
    flag = b"1" if any(byte > 0x7F for byte in item) else b"0"
    out.write(flag + os.fsencode(fold(os.fsdecode(item))) + b"\0")
'
gate_config_changes() {
  local f v rel rc="" ended=0 hit i n k
  local paths=() folded=()
  PG_AUDIT_DIRS_FOLDED=()
  while IFS= read -r -d '' f; do
    if [ "$ended" -eq 1 ]; then rc="$f"; continue; fi
    if [ -z "$f" ]; then ended=1; continue; fi
    paths+=("$f")
  done < <(git -C "$PROJECT_DIR" diff --name-only --no-renames -z "$RANGE" 2>/dev/null; printf '\0%s\0' "$?")
  [ "$rc" = 0 ] || return 1
  n="${#paths[@]}"
  [ "$n" -gt 0 ] || return 0
  # The audit dirs go through the same fold, ahead of the paths.
  k="${#PG_AUDIT_DIRS[@]}"
  rc="" ended=0
  while IFS= read -r -d '' f; do
    if [ "$ended" -eq 1 ]; then rc="$f"; continue; fi
    if [ -z "$f" ]; then ended=1; continue; fi
    if [ "${#PG_AUDIT_DIRS_FOLDED[@]}" -lt "$k" ]; then
      PG_AUDIT_DIRS_FOLDED+=("${f:1}")
    else
      folded+=("$f")
    fi
  done < <(printf '%s\0' "${PG_AUDIT_DIRS[@]}" "${paths[@]}" | python3 -I -c "$PG_FOLD_PY" 2>/dev/null
    printf '\0%s\0' "$?")
  [ "$rc" = 0 ] && [ "${#PG_AUDIT_DIRS_FOLDED[@]}" -eq "$k" ] && [ "${#folded[@]}" -eq "$n" ] || return 1
  for ((i = 0; i < n; i++)); do
    f="${paths[i]}"
    hit=false
    if [ "${folded[i]:0:1}" = 1 ] || pg_is_gate_config_path "${folded[i]:1}"; then
      hit=true
    else
      while IFS= read -r rel; do
        case "$f" in
          "${rel#!}"|"${rel#!}"/*) hit=true; break ;;
        esac
      done < <(validator_dep_rels
        for v in ${PROCESS_GATE_STACK_VALIDATORS[@]+"${PROCESS_GATE_STACK_VALIDATORS[@]}"}; do
          [ -n "$v" ] && stack_validator_rels "$v"
        done)
    fi
    [ "$hit" = true ] || continue
    case "$f" in
      *[[:cntrl:]]*) printf '  changed: %q\n' "$f" ;;
      *) printf '  changed: %s\n' "$f" ;;
    esac
  done
}

# gate_config_approval <head-sha>: the merge-mode approval for a range that
# changes gate config — a line `gate-config-approved: <head-sha>` in a comment
# or non-dismissed review on the one open PR whose head is <head-sha>,
# authored by the repository OWNER, all read via gh. For an ORGANIZATION-owned
# repo the owner login can never author a comment, so an approval line from an
# author whose repo permission is admin is accepted instead (looked up live
# via gh; any lookup failure fails closed). User-owned repos keep the exact
# owner-login rule. The open-PR search is
# complete or refused (a full page may be truncated), and the chosen PR's
# state and head are re-checked when its bodies are read. Only the owner (or
# an org admin) may post the line; no agent posts or scripts it. Sets
# APPROVAL_PR, APPROVAL_AUTHOR, APPROVAL_PERMISSION and APPROVAL_LINE, or
# APPROVAL_REASON on failure. There is
# no override.
# approval_repo_permission <nameWithOwner> <login>: print the login's repo
# permission as reported by gh (empty on any lookup failure); succeed iff
# the lookup itself worked. Callers compare against admin and fail closed.
approval_repo_permission() {
  local perm
  perm="$(cd "$PROJECT_DIR" && gh api "repos/$1/collaborators/$2/permission" --jq '.permission // empty' 2>/dev/null)" || return 1
  printf '%s' "$perm"
}

gate_config_approval() {
  local head="$1" owner otype nwo oinfo rest listing total prs view first lines author line other="" limit=1000 perm
  local re='^[[:space:]]*gate-config-approved:[[:space:]]*([0-9a-f]+)[[:space:]]*$'
  local need="gate config changed in range: merge requires gate-config-approved: $head from the repo owner on the PR"
  if ! command -v gh >/dev/null 2>&1; then
    APPROVAL_REASON="$need; gh is unavailable"
    return 1
  fi
  # jq -r prints a missing login as "null", which would let an unreadable
  # owner match a deleted (null) comment author: missing fields default to
  # "" (never the literal string "null"), and an empty owner refuses
  # below; the author read keeps a sentinel no login can spell.
  owner=""; otype="User"; nwo=""
  if oinfo="$(cd "$PROJECT_DIR" && gh repo view --json owner,nameWithOwner \
    --jq '"\(.owner.login // "")\t\(.owner.type // "")\t\(.nameWithOwner // "")"' 2>/dev/null)"; then
    owner="${oinfo%%$'\t'*}"; rest="${oinfo#*$'\t'}"
    [ -n "${rest%%$'\t'*}" ] && otype="${rest%%$'\t'*}"
    nwo="${rest#*$'\t'}"
  fi
  if [ -z "$owner" ]; then
    APPROVAL_REASON="$need; gh could not read the repo owner"
    return 1
  fi
  case "$otype" in
    User) ;;
    Organization) ;;
    *) APPROVAL_REASON="$need; unknown repo owner type $otype"
       return 1 ;;
  esac
  listing="$(cd "$PROJECT_DIR" && gh pr list --state open --search "$head" --limit "$limit" \
    --json number,headRefOid,state \
    --jq "\"\(length)\t\" + ([.[] | select(.headRefOid == \"$head\" and .state == \"OPEN\") | .number | tostring] | join(\" \"))" \
    2>/dev/null)" || listing=""
  total="${listing%%$'\t'*}"
  prs="${listing#*$'\t'}"
  case "$total" in
    ''|*[!0-9]*)
      APPROVAL_REASON="$need; gh could not list open PRs"
      return 1
      ;;
  esac
  if [ "$total" -ge "$limit" ]; then
    APPROVAL_REASON="$need; the open-PR search returned $total results and may be truncated"
    return 1
  fi
  case "$prs" in
    ''|*[!0-9]*)
      APPROVAL_REASON="$need; no single open PR has head $head"
      return 1
      ;;
  esac
  APPROVAL_PR="$prs"
  # First row "<state>\t<head>", then one "<author>\t<line>" row per body line
  # of every comment and non-dismissed review.
  if ! view="$(cd "$PROJECT_DIR" && gh pr view "$prs" --json state,headRefOid,comments,reviews \
    --jq '"\(.state)\t\(.headRefOid)", ((.comments[], (.reviews[] | select(.state != "DISMISSED"))) | (.author.login // "(deleted)") as $a | (.body // "") | split("\n")[] | "\($a)\t\(.)")' 2>/dev/null)"; then
    APPROVAL_REASON="$need; gh could not read PR #$prs"
    return 1
  fi
  first="${view%%$'\n'*}"
  lines=""
  case "$view" in
    *$'\n'*) lines="${view#*$'\n'}" ;;
  esac
  if [ "$first" != "OPEN"$'\t'"$head" ]; then
    APPROVAL_REASON="$need; PR #$prs is no longer open at head $head"
    return 1
  fi
  while IFS=$'\t' read -r author line; do
    line="${line%$'\r'}"
    [[ "$line" =~ $re ]] || continue
    line="${line#"${line%%[![:space:]]*}"}"
    if [ "${BASH_REMATCH[1]}" = "$head" ]; then
      if [ "$author" = "$owner" ]; then
        APPROVAL_AUTHOR="$author"
        APPROVAL_PERMISSION="owner"
        APPROVAL_LINE="$line"
        return 0
      fi
      if [ "$otype" = Organization ]; then
        if [ -n "$nwo" ] && perm="$(approval_repo_permission "$nwo" "$author")" && [ "$perm" = admin ]; then
          APPROVAL_AUTHOR="$author"
          APPROVAL_PERMISSION="$perm"
          APPROVAL_LINE="$line"
          return 0
        elif [ -n "${perm:-}" ]; then
          other="$author (permission $perm, need admin): \"$line\""
        else
          other="$author (permission lookup failed): \"$line\""
        fi
      else
        other="$author (not the repo owner $owner): \"$line\""
      fi
    else
      other="$author for another SHA: \"$line\""
    fi
  done <<< "$lines"
  if [ -n "$other" ]; then
    APPROVAL_REASON="$need; PR #$prs has an approval by $other"
  else
    APPROVAL_REASON="$need; PR #$prs carries no approval line"
  fi
  return 1
}

PROJECT_PHYS="$(cd -P "$PROJECT_DIR" 2>/dev/null && pwd -P)" ||
  pg_blocked_verdict "process-gate cannot resolve the physical project directory $PROJECT_DIR"
case "$PROJECT_DIR" in
  /*) PROJECT_LOG="$(pg_normalize_abs "$PROJECT_DIR")" ;;
  *) PROJECT_LOG="$PROJECT_PHYS" ;;
esac
# The checkout under test, absolute: validators' cwd and PROCESS_GATE_PROJECT_DIR.
PG_CHECKOUT="$PROJECT_LOG"

# The trusted code root: the range base's process-gate-local trees (both
# twins), project validators and declared validator dependencies, copied out of
# the base commit. Set here, never taken from the caller's environment.
PG_TRUSTED_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t process-gate-base)" ||
  pg_blocked_verdict "process-gate cannot create a private directory for base validators"
trap 'rm -rf "$PG_TRUSTED_ROOT"' EXIT
PG_TRUSTED_ROOT="$(cd -P "$PG_TRUSTED_ROOT" && pwd -P)" ||
  pg_blocked_verdict "process-gate cannot resolve its private validator directory"

pg_unshadow
for _tree in .agents/skills/process-gate-local .claude/skills/process-gate-local; do
  materialise_base "$_tree" ||
    pg_blocked_verdict "process-gate cannot copy $_tree from range base $PG_CONFIG_BASE"
done
while IFS= read -r _dep; do
  case "$_dep" in
    '!'*) pg_blocked_verdict "process-gate validator dependency ${_dep#!} is not a project-relative path" ;;
  esac
  _rc=0
  pg_base_path "$PROJECT_DIR" "$PG_CONFIG_BASE" "$_dep" || _rc=$?
  case "$_rc" in
    0|3) materialise_base "$_dep" ||
      pg_blocked_verdict "process-gate cannot copy validator dependency $_dep from range base $PG_CONFIG_BASE" ;;
    1) pg_blocked_verdict "process-gate validator dependency $_dep is missing at range base $PG_CONFIG_BASE" ;;
    *) pg_blocked_verdict "process-gate validator dependency $_dep at range base $PG_CONFIG_BASE is not a regular file or directory, or is reached through a symlink" ;;
  esac
done < <(validator_dep_rels)
for _v in ${PROCESS_GATE_STACK_VALIDATORS[@]+"${PROCESS_GATE_STACK_VALIDATORS[@]}"}; do
  [ -n "$_v" ] || continue
  while IFS= read -r _rel; do
    _rc=0
    pg_base_path "$PROJECT_DIR" "$PG_CONFIG_BASE" "$_rel" || _rc=$?
    [ "$_rc" -eq 0 ] || continue
    materialise_base "$_rel" ||
      pg_blocked_verdict "process-gate cannot copy validator $_rel from range base $PG_CONFIG_BASE"
  done < <(stack_validator_rels "$_v")
done
unset _tree _dep _rc _v _rel

pg_unshadow
CONFIG_CHANGES="$(gate_config_changes)" ||
  pg_blocked_verdict "process-gate cannot list (or, with python3, fold) the files changed in $RANGE"
if [ -n "$CONFIG_CHANGES" ]; then
  HEAD_SHA="$(pg_range_head "$PROJECT_DIR" "$RANGE")" ||
    pg_blocked_verdict "process-gate cannot resolve the head of $RANGE"
  printf '## gate config changed in range\n\n'
  printf 'gate config changed in range: gated with BASE config; merge requires gate-config-approved: %s\n' "$HEAD_SHA"
  printf '%s\n' "$CONFIG_CHANGES"
  printf '\n'
  if [ "$PG_TARGET_MAIN" = true ]; then
    pg_blocked_verdict "gate config changed in range: a push that targets main/master cannot change gate config, approved or not; merge it through its PR"
  fi
  if [ "$PG_MODE" = merge ]; then
    APPROVAL_PR="" APPROVAL_AUTHOR="" APPROVAL_PERMISSION="" APPROVAL_LINE="" APPROVAL_REASON=""
    pg_unshadow
    gate_config_approval "$HEAD_SHA" || pg_blocked_verdict "$APPROVAL_REASON"
    printf 'gate config approved on PR #%s by %s (%s permission): "%s"\n\n' "$APPROVAL_PR" "$APPROVAL_AUTHOR" "$APPROVAL_PERMISSION" "$APPROVAL_LINE"
  fi
fi

run_gate 0 "$SKILL_DIR/scripts/check-pr.sh"
run_gate 1 "$SKILL_DIR/scripts/check-secrets.sh"
run_gate 2 "$SKILL_DIR/scripts/check-bypass.sh"
run_gate 3 "$SKILL_DIR/scripts/check-tests.sh"
run_gate 4 "$SKILL_DIR/scripts/check-docs.sh"

# Stack profile (idx 5). Validators run as their base copies (materialised
# above) under the validator-env.sh source guard.
pg_unshadow
profile="${PROCESS_GATE_STACK_PROFILE:-}"
if [ -z "$profile" ] || [ "$profile" = "n-a" ]; then
  set_result 5 "n/a" "profile=${profile:-<unset>} (no validators run)"
elif [ -z "${PROCESS_GATE_STACK_VALIDATORS+set}" ]; then
  set_result 5 "warn" "profile=$profile but PROCESS_GATE_STACK_VALIDATORS unset (no validators run)"
else
  validators=("${PROCESS_GATE_STACK_VALIDATORS[@]:-}")
  nonblank=0
  for v in "${validators[@]}"; do
    [ -n "$v" ] && nonblank=$((nonblank + 1))
  done
  if [ "$nonblank" -eq 0 ]; then
    set_result 5 "warn" "profile=$profile but PROCESS_GATE_STACK_VALIDATORS empty (no validators run)"
  elif [ ! -s "$SKILL_DIR/scripts/lib/validator-env.sh" ]; then
    set_result 5 "fail" "validator source guard missing: scripts/lib/validator-env.sh — re-run the skill rollout"
  else
    worst="pass"; combined=""
    for v in "${validators[@]}"; do
      [ -z "$v" ] && continue
      if ! vpath="$(resolve_stack_validator "$v")"; then
        combined="${combined}${vpath:-validator missing: $v}"$'\n'
        worst="fail"; continue
      fi
      # The trusted roots and the source guard are set here, never inherited.
      # The validator's bytes come from the base copy; it runs against the
      # checkout under test: PROCESS_GATE_PROJECT_DIR names it and is the cwd.
      # No `-p` here: it would skip the BASH_ENV guard. The purge above
      # already left no function to import.
      vout="$(cd "$PG_CHECKOUT" &&
        PROCESS_GATE_PROJECT_DIR="$PG_CHECKOUT" PG_TRUSTED_ROOT="$PG_TRUSTED_ROOT" \
        PG_SKILL_ROOT="$SKILL_DIR" PG_GATE_RANGE="$RANGE" \
        BASH_ENV="$SKILL_DIR/scripts/lib/validator-env.sh" bash "$vpath" --range="$RANGE" 2>&1)"; vrc=$?
      combined="${combined}${vout}"$'\n'
      case "$vrc" in
        0) ;;
        2) [ "$worst" = "pass" ] && worst="warn" ;;
        *) worst="fail" ;;
      esac
    done
    set_result 5 "$worst" "$combined"
  fi
fi

# Security (diff) (idx 6) — always-hard. Adapter wraps security-gate run-diff.sh.
# A push that targets main/master is passed on: run-diff refuses a change to
# its own gate config there, approved or not.
if [ "$PG_TARGET_MAIN" = true ]; then
  run_gate 6 "$SKILL_DIR/scripts/check-security-diff.sh" --target=main
else
  run_gate 6 "$SKILL_DIR/scripts/check-security-diff.sh"
fi

# Analyze (idx 7) — PR-shape (downgrades at push). Adapter never exits 1.
run_gate 7 "$SKILL_DIR/scripts/check-analyze.sh"

# Anti-slop (idx 8) — posture-driven from the project's
# `gate_profiles.anti_slop.posture`. Set inline rather than via run_gate because
# the row needs an `n/a` state and no exit code carries one: check-slop.sh's rc
# says only whether it blocks (1 = posture `enforced` with findings), while its
# first printed token carries the level. So an `advisory` project's findings
# surface as ⚠️ warn — NEEDS CHANGES, never BLOCKED — and an undeclared or `off`
# project renders ➖ n/a. Deliberately absent from the PR-shape downgrade set:
# the only posture that can fail is one the project opted into.
#
# Existence is checked FIRST, and a missing script is a FAIL. The row reads the
# level off check-slop.sh's exit code first and its first printed token second:
# a nonzero rc fails the row even with no contract token, and past the contract
# tokens (pass/warn/fail/info) the `*)` arm fails rather than rendering n/a —
# historically this arm rendered n/a, the only gate in this aggregator that
# failed open. Every run_gate gate lands a missing script in its
# `*) status="fail"` arm; this one says so explicitly.
if [ ! -f "$SKILL_DIR/scripts/check-slop.sh" ]; then
  set_result 8 "fail" "fail Anti-slop: validator not found at scripts/check-slop.sh — this process-gate leaf predates gate row 9; re-run the skill rollout"
else
  slop_out="$(env -u BASH_ENV -u ENV bash -p "$SKILL_DIR/scripts/check-slop.sh" --range="$RANGE" 2>&1)"; slop_rc=$?
  slop_token="$(printf "%s\n" "$slop_out" | head -1 | awk '{print $1}')"
  if [ "$slop_rc" -ne 0 ]; then
    set_result 8 "fail" "$slop_out"
  else
    case "$slop_token" in
      pass) set_result 8 "pass" "$slop_out" ;;
      warn) set_result 8 "warn" "$slop_out" ;;
      fail) set_result 8 "fail" "$slop_out" ;;
      info) set_result 8 "n/a"  "$slop_out" ;;
      *)    set_result 8 "fail" "$slop_out" ;;
    esac
  fi
fi

# --- Render verdict --------------------------------------------------------
glyph() {
  case "$1" in
    pass) printf "✅ pass" ;;
    warn) printf "⚠️  warn" ;;
    fail) printf "❌ fail" ;;
    n/a)  printf "➖ n/a"  ;;
    *)    printf "%s" "$1" ;;
  esac
}

overall="MERGEABLE"
for r in "${RESULTS[@]}"; do
  case "$r" in
    fail) overall="BLOCKED"; break ;;
    warn) [ "$overall" = "MERGEABLE" ] && overall="NEEDS CHANGES" ;;
  esac
done

printf "## process-gate verdict (mode=%s)\n\n" "$PG_MODE"
printf "%s\n\n" "$DIFF_BASE_RECEIPT"
for i in 0 1 2 3 4 5 6 7 8; do
  printf "%-18s %s\n" "${LABELS[$i]}:" "$(glyph "${RESULTS[$i]}")"
done
printf "\nOverall: %s\n\n" "$overall"

# C08: a narrowed Tests row is not a full-battery pass. Carry check-tests.sh's
# own receipt line (two-space finding indent; command output is indented four)
# into the verdict so the narrowing is visible at every overall level.
tests_receipt="$(printf '%s\n' "${FINDINGS[3]}" | sed -n 's/^  \(Tests: narrowed (docs-only: [0-9][0-9]* files)\)$/\1/p' | head -n 1)"
if [ -n "$tests_receipt" ]; then
  printf "%s\n\n" "$tests_receipt"
fi

if [ "$overall" != "MERGEABLE" ]; then
  printf "## Findings\n\n"
  for i in 0 1 2 3 4 5 6 7 8; do
    case "${RESULTS[$i]}" in
      pass|n/a) ;;
      *) printf "### %s\n%s\n\n" "${LABELS[$i]}" "${FINDINGS[$i]}" ;;
    esac
  done
fi

case "$overall" in
  MERGEABLE) exit 0 ;;
  "NEEDS CHANGES") exit 2 ;;
  BLOCKED) exit 1 ;;
esac
