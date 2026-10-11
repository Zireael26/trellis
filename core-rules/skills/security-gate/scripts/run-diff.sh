#!/usr/bin/env bash
# Mode 2 — diff scan against the latest baseline.
# Scoped to files changed in the push range. Findings already known to the
# baseline JSON are skipped. Emits a verdict block in the same shape as
# process-gate. Exit codes:
#   0  MERGEABLE          — no new Critical/High findings
#   2  NEEDS CHANGES      — only new Medium/Low findings
#   1  BLOCKED            — new Critical/High finding or required scan incomplete
#
# Usage: run-diff.sh [<project-dir>] [--range=<gitspec>] [--no-llm]
#                    [--baseline=<path-to-json>] [--mode=push|merge]
#
# Husky pre-push wiring (added to core-rules/husky/pre-push) passes the
# computed range derived from the stdin refs. process-gate's adapter passes
# --mode; run directly, the gate defaults to push.
#
# The range never configures its own scan. Project-local config, the gitleaks
# config/ignore files, the OSV config and the dedupe baseline are read from the
# range BASE; local.config.sh is parsed as data; engines are absolute PATH
# binaries outside the project. A range that changes any of them is scanned
# under the base copies: push mode prints a notice, merge mode BLOCKS until the
# repo owner's `gate-config-approved: <head>` line is on the one open PR.

# A function named after a tool or builtin this gate runs would answer for it,
# and an exported one (`BASH_FUNC_semgrep%%`) arrives with the environment.
# Every command name can be shadowed, `builtin` included; a variable assignment
# cannot. Setting POSIXLY_CORRECT turns on POSIX mode, where special builtins
# (`unset`, `set`) are found before functions, so the first purge cannot be
# intercepted. The rest go once `builtin` is the real one again. Callers that
# launch this script use `bash -p`, which imports no functions and reads no
# BASH_ENV at all; this prologue covers a direct launch.
POSIXLY_CORRECT=y
unset -f builtin command type set unset compgen
set +o posix
builtin unset POSIXLY_CORRECT
for _sg_fn in $(builtin compgen -A function 2>/dev/null); do builtin unset -f "$_sg_fn"; done
builtin unset -f semgrep gitleaks osv-scanner shellcheck python3 git jq gh
builtin unset _sg_fn

set -uo pipefail

case "$0" in */*) _sg_self_dir="${0%/*}" ;; *) _sg_self_dir=. ;; esac
SKILL_DIR="$(builtin cd "$_sg_self_dir/.." && builtin pwd)"
builtin source "$SKILL_DIR/scripts/lib/engine.sh"
# Relative and empty PATH entries resolve against the cwd; drop them before the
# first external command. Entries inside the project go once it is known.
sg_path_sanitize

# --- arg parse -------------------------------------------------------------
PROJECT_DIR=""
RANGE=""
BASELINE=""
MODE="push"
TARGET_MAIN=false
# NO_LLM is set by --no-llm; consumption pending — flag accepted for CLI parity
# with run-baseline.sh / run-redteam.sh.
# shellcheck disable=SC2034
NO_LLM=0
# shellcheck disable=SC2034
for arg in "$@"; do
  case "$arg" in
    --range=*)    RANGE="${arg#--range=}" ;;
    --baseline=*) BASELINE="${arg#--baseline=}" ;;
    --no-llm)     NO_LLM=1 ;;
    --mode=push|--mode=merge) MODE="${arg#--mode=}" ;;
    --target=main) TARGET_MAIN=true ;;
    --*)        echo "unknown flag: $arg" >&2; exit 64 ;;
    *)            PROJECT_DIR="$arg" ;;
  esac
done

print_verdict() {
  local sast="$1" deps="$2" secrets="$3" overall="$4"
  printf "## security-gate verdict (diff)\n\n"
  # A refusal before the diff base resolves has no receipt to print.
  [ -z "${DIFF_BASE_RECEIPT:-}" ] || printf "%s\n\n" "$DIFF_BASE_RECEIPT"
  printf "%-18s %s\n" "SAST:"            "$sast"
  printf "%-18s %s\n" "Deps:"            "$deps"
  printf "%-18s %s\n" "Secrets:"         "$secrets"
  printf "%-18s ➖ n/a\n" "Stack-specific:"
  printf "\nOverall: %s\n\n" "$overall"
}

# A refusal before any scan: the gate cannot name whose config to trust.
config_refuse() {
  printf 'security-gate: %s\n' "$1" >&2
  print_verdict "❌ fail" "❌ fail" "❌ fail" "BLOCKED"
  exit 1
}

# --- resolve project dir --------------------------------------------------
if [ -z "$PROJECT_DIR" ]; then
  if [ -n "${CODEX_PROJECT_DIR:-}" ] && [ -d "$CODEX_PROJECT_DIR" ]; then
    PROJECT_DIR="$CODEX_PROJECT_DIR"
  elif [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
    PROJECT_DIR="$CLAUDE_PROJECT_DIR"
  else
    # git finds the project here, so vet it against the cwd before it runs.
    sg_resolve_engine git "$PWD" >/dev/null || [ "$?" -ne 3 ] \
      || config_refuse "git resolves inside the scanned project; refusing to run it"
    PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  fi
fi
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
if ! sg_path_sanitize "$PROJECT_DIR"; then
  echo "security-gate: cannot resolve project dir $PROJECT_DIR" >&2
  exit 1
fi
# git runs from here on, so it is vetted before its first use, not after.
sg_resolve_engine git "$PROJECT_DIR" >/dev/null || [ "$?" -ne 3 ] \
  || config_refuse "git resolves inside the scanned project; refusing to run it"
# The project key names the REPOSITORY, not the directory the run happened in.
# `basename $PROJECT_DIR` is the worktree name inside a linked worktree, so a
# worktree could never match its own repo's baseline and every diff scan there
# was skipped as "no baseline found". Derive from the common git dir instead,
# which is shared by every worktree of one repository.
PROJECT_NAME="$(basename "$PROJECT_DIR")"
if _sg_common="$(git -C "$PROJECT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
   && [ -n "$_sg_common" ]; then
  _sg_repo="$(cd "$_sg_common/.." 2>/dev/null && pwd)" || _sg_repo=""
  [ -n "$_sg_repo" ] && PROJECT_NAME="$(basename "$_sg_repo")"
fi
PROJECT_NAME="${SECURITY_GATE_PROJECT_NAME:-$PROJECT_NAME}"

# Merge mode never derives a range: a guessed `HEAD~1..HEAD` would make an
# earlier candidate commit the trusted base.
[ "$MODE" != merge ] || [ -n "$RANGE" ] || config_refuse "merge mode requires --range/--base"

# --- diff base ------------------------------------------------------------
# Spec 067: the process-gate resolver picks the base (an explicit --range stays
# verbatim) and print_verdict prints its receipt. Nothing resolvable leaves
# RANGE empty, and the failed diff below BLOCKs. The old default, minus its
# HEAD~1..HEAD last resort (D1), survives only for an install without the
# process-gate skill beside this one.
DIFF_BASE_LIB="$SKILL_DIR/../process-gate/scripts/lib/diff-base.sh"
if [ -f "$DIFF_BASE_LIB" ]; then
  # shellcheck source=../../process-gate/scripts/lib/diff-base.sh
  . "$DIFF_BASE_LIB"
  _sg_cwd="$PWD"
  cd "$PROJECT_DIR" || exit 1
  if [ -n "$RANGE" ]; then db_resolve --range="$RANGE"; else db_resolve; fi
  _sg_db_rc=$?
  DIFF_BASE_RECEIPT="$(db_receipt)"
  cd "$_sg_cwd" || exit 1
  if [ -z "$RANGE" ] && [ "$_sg_db_rc" -ne 0 ]; then
    printf 'security-gate: %s\n' "$DB_REASON" >&2
  fi
  RANGE="${RANGE:-$DB_RANGE}"
else
  _sg_source=explicit
  if [ -z "$RANGE" ]; then
    _sg_source=default
    if git -C "$PROJECT_DIR" rev-parse --verify origin/main >/dev/null 2>&1; then
      RANGE="origin/main..HEAD"
    elif git -C "$PROJECT_DIR" rev-parse --verify main >/dev/null 2>&1; then
      RANGE="main..HEAD"
    elif git -C "$PROJECT_DIR" rev-parse --verify master >/dev/null 2>&1; then
      RANGE="master..HEAD"
    fi
  fi
  _sg_head="$(git -C "$PROJECT_DIR" symbolic-ref -q --short HEAD 2>/dev/null)" || _sg_head=detached
  if [ -z "$RANGE" ]; then
    printf 'security-gate: no diff base resolvable; pass --range\n' >&2
    DIFF_BASE_RECEIPT="diff-base: - - via refused (no diff base resolvable; pass --range) range=- head=$_sg_head"
  else
    DIFF_BASE_RECEIPT="diff-base: - ${RANGE%%..*} via $_sg_source (resolver absent) range=$RANGE head=$_sg_head"
  fi
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- range base and head --------------------------------------------------
# Security config is read from the range BASE, so the base must be one commit.
# `A..B` diffs A against B and `A...B` diffs merge-base(A, B) against B; an
# empty side means HEAD, as in git. Any other spec (a single rev, `^A B`) has no
# single base, and guessing one would be choosing whose config to trust.
case "$RANGE" in
  *...*) RANGE_BASE_SPEC="${RANGE%%...*}"; RANGE_HEAD_SPEC="${RANGE#*...}"; RANGE_SYMMETRIC=1 ;;
  *..*)  RANGE_BASE_SPEC="${RANGE%%..*}";  RANGE_HEAD_SPEC="${RANGE#*..}";  RANGE_SYMMETRIC=0 ;;
  *)     config_refuse "cannot derive the range base from '$RANGE' (expected <base>..<head> or <base>...<head>)" ;;
esac
resolve_commit() {
  case "$1" in -*) return 1 ;; esac
  git -C "$PROJECT_DIR" rev-parse --verify --quiet "${1:-HEAD}^{commit}" 2>/dev/null
}
if ! RANGE_BASE="$(resolve_commit "$RANGE_BASE_SPEC")" \
   || ! RANGE_HEAD="$(resolve_commit "$RANGE_HEAD_SPEC")"; then
  config_refuse "cannot resolve the range base and head of '$RANGE'"
fi
if [ "$RANGE_SYMMETRIC" -eq 1 ]; then
  RANGE_BASE="$(git -C "$PROJECT_DIR" merge-base "$RANGE_BASE" "$RANGE_HEAD" 2>/dev/null)" \
    || config_refuse "no merge base for the range base of '$RANGE'"
fi

# --- load project-local config from the range base -------------------------
# The file used to be sourced from the worktree being scanned, so the range
# under review could define semgrep()/gitleaks(), prepend PATH or switch
# ShellCheck off, and then be judged MERGEABLE by the scanner it had replaced.
# It is now read from the base commit and parsed as data. Accepted lines are
# blanks, comments and NAME=value, where NAME is SECURITY_GATE_* (applied) or
# LLM_* (documented, consumed by baseline/redteam, ignored here), and value is a
# literal: a bare word, '...', "..." without $ ` \, or the default-preserving
# "${NAME:-literal}" naming its own key. Anything else BLOCKS. A plain
# assignment overrides the environment, as sourcing did.
CONFIG_BAD_LINE=0
parse_config_data() {
  # Byte semantics: `[A-Z]` is ASCII only, and a non-ASCII key never matches.
  local LC_ALL=C
  local line key val n=0
  local re_assign='^(SECURITY_GATE_[A-Z0-9_]+|LLM_[A-Z0-9_]+)=(.*)$'
  # [[:space:]] includes CR, so a CRLF file parses the same as an LF one.
  local re_tail='([[:space:]]+(#.*)?)?$'
  local re_dq='^"([^"$`\\]*)"'"$re_tail"
  local re_sq="^'([^']*)'$re_tail"
  local re_bare='^([A-Za-z0-9_./:,@+%=-]*)'"$re_tail"
  local re_def='^"[$][{]([A-Z0-9_]+):-([^"$`\\}]*)[}]"'"$re_tail"
  while IFS= builtin read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in ''|'#'*) continue ;; esac
    CONFIG_BAD_LINE="$n"
    [[ "$line" =~ $re_assign ]] || return 1
    key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
    # A repeated key is last-wins, as it was when the file was sourced.
    if [[ "$val" =~ $re_def ]]; then
      [ "${BASH_REMATCH[1]}" = "$key" ] || return 1
      case "$key" in SECURITY_GATE_*) [ -n "${!key:-}" ] || builtin printf -v "$key" '%s' "${BASH_REMATCH[2]}" ;; esac
    elif [[ "$val" =~ $re_dq ]] || [[ "$val" =~ $re_sq ]] || [[ "$val" =~ $re_bare ]]; then
      case "$key" in SECURITY_GATE_*) builtin printf -v "$key" '%s' "${BASH_REMATCH[1]}" ;; esac
    else
      return 1
    fi
  done < "$1"
  CONFIG_BAD_LINE=0
}
base_has() {
  git -C "$PROJECT_DIR" cat-file -e "$RANGE_BASE:$1" 2>/dev/null
}
base_copy() {
  git -C "$PROJECT_DIR" show "$RANGE_BASE:$1" >"$2" 2>/dev/null \
    || config_refuse "could not read $1 from range base $RANGE_BASE"
}
# A worktree-only file is not loaded. Say so, so a fallback to defaults is
# never mistaken for the project's own settings.
note_worktree_only() {
  [ ! -e "$PROJECT_DIR/$1" ] \
    || printf 'security-gate: note: %s is not in range base %s; the worktree copy is not loaded\n' "$1" "$RANGE_BASE"
}
cfg_n=0
for cfg in \
  .claude/skills/security-gate-local/local.config.sh \
  .agents/skills/security-gate-local/local.config.sh; do
  cfg_n=$((cfg_n + 1))
  if base_has "$cfg"; then
    base_copy "$cfg" "$WORK/local.config.$cfg_n"
    parse_config_data "$WORK/local.config.$cfg_n" \
      || config_refuse "security-gate local config is not data: $cfg line $CONFIG_BAD_LINE at $RANGE_BASE"
  else
    note_worktree_only "$cfg"
  fi
done

# PROJECT_NAME was resolved before the config load, so a pin set in that file
# never took effect and a clone or detached export fell back to its directory
# basename, found no baseline and skipped the whole diff scan (2026-09-07: the
# clone reported "no baseline JSON found for project
# 'spec047-gate-clone.XXXXXX'" while the tracked config pinned
# trellis-instance). Re-apply after the load so the file's own intent holds; an
# inherited environment value still wins when the file uses the
# default-preserving form.
PROJECT_NAME="${SECURITY_GATE_PROJECT_NAME:-$PROJECT_NAME}"

PROFILE="${SECURITY_GATE_STACK_PROFILE:-web-next}"
AUDIT_DIR_REL="${SECURITY_GATE_AUDIT_DIR:-audits}"
AUDIT_DIR_REL="${AUDIT_DIR_REL#./}"
AUDIT_DIR_REL="${AUDIT_DIR_REL%/}"

# --- engines --------------------------------------------------------------
# Absolute PATH binaries outside the project (lib/engine.sh): no function,
# alias or builtin, no relative PATH entry, nothing whose real path is in the
# scanned tree. The config above is data, so it cannot have moved PATH. An
# engine that resolves into the project BLOCKS; a missing one is reported by
# its stage. osv-scanner is resolved the same way inside lib/osv.sh.
resolve_engine() {
  local path rc=0
  path="$(sg_resolve_engine "$2" "$PROJECT_DIR")" || rc=$?
  [ "$rc" -ne 3 ] || config_refuse "$2 resolves inside the scanned project; refusing to run it"
  builtin printf -v "$1" '%s' "$path"
}
resolve_engine SEMGREP_BIN semgrep
resolve_engine SHELLCHECK_BIN shellcheck
resolve_engine GITLEAKS_BIN gitleaks
resolve_engine GH_BIN gh
resolve_engine PYTHON3_BIN python3
[ -n "$PYTHON3_BIN" ] || config_refuse "python3 not found on PATH; scanner output cannot be parsed"

# --- scanner config from the range base -------------------------------------
# gitleaks loads .gitleaks.toml from --source and .gitleaksignore from --source
# and the working directory unless told otherwise. Hand it the base copies, or
# the built-in rules and an empty ignore set when the base has none, and point
# --source at the git dir, which holds no tracked file.
GL_CONFIG_FILE="$WORK/gitleaks.toml"
GL_IGNORE_DIR="$WORK/gitleaks-ignore"
mkdir -p "$GL_IGNORE_DIR"
if base_has .gitleaks.toml; then
  base_copy .gitleaks.toml "$GL_CONFIG_FILE"
  # `[extend] path` is resolved against the invocation directory, not the
  # config file, so a base config that extends a file would read the range's
  # copy of it. Diff mode refuses external extensions; `useDefault` is fine.
  # gitleaks reads its config through Viper, which case-folds keys, so the
  # match is case-insensitive over a real TOML parse (quoted and dotted keys
  # included). Without tomllib the config cannot be verified and BLOCKS.
  "$PYTHON3_BIN" -I - "$GL_CONFIG_FILE" <<'PY'
import sys
try:
    import tomllib
except ImportError:
    sys.exit(3)
try:
    with open(sys.argv[1], "rb") as fh:
        data = tomllib.load(fh)
except (OSError, ValueError):
    sys.exit(2)
for key, value in data.items():
    if key.lower() == "extend" and isinstance(value, dict) and any(k.lower() == "path" for k in value):
        sys.exit(1)
sys.exit(0)
PY
  case "$?" in
    0) ;;
    1) config_refuse "base .gitleaks.toml uses [extend] path; diff mode does not load external gitleaks config" ;;
    3) config_refuse "cannot verify base .gitleaks.toml: python3 has no tomllib" ;;
    *) config_refuse "base .gitleaks.toml is not valid TOML" ;;
  esac
else
  note_worktree_only .gitleaks.toml
  printf '[extend]\nuseDefault = true\n' > "$GL_CONFIG_FILE"
fi
if base_has .gitleaksignore; then
  base_copy .gitleaksignore "$GL_IGNORE_DIR/.gitleaksignore"
else
  note_worktree_only .gitleaksignore
fi
GL_SOURCE="$(git -C "$PROJECT_DIR" rev-parse --absolute-git-dir 2>/dev/null)" \
  || config_refuse "could not resolve the git dir of $PROJECT_DIR"

# osv-scanner auto-loads osv-scanner.toml beside every scanned manifest; its
# ignores would let the range waive its own advisories. lib/osv.sh passes this
# file as --config, which replaces discovery: the base root copy, else empty.
OSV_CONFIG_FILE="$WORK/osv-scanner.toml"
if base_has osv-scanner.toml; then
  base_copy osv-scanner.toml "$OSV_CONFIG_FILE"
else
  note_worktree_only osv-scanner.toml
  : > "$OSV_CONFIG_FILE"
fi

# --- dedupe baseline from the range base -------------------------------------
# A baseline the range adds or edits would mark its own findings as known.
# An explicit --baseline names a repository file (relative to the repo root,
# or absolute inside it); it is read from the BASE like the default, and a
# change to it is a gate-config change. Anything outside the repo is refused.
# Default to the newest baseline in the BASE commit's audit dir; tree entries
# are byte-sorted, so the last match is the newest date-prefixed file.
BASELINE_REL=""
if [ -n "$BASELINE" ]; then
  _sg_b="$BASELINE"
  case "$_sg_b" in
    /*)
      _sg_root="$(sg_physical_dir "$PROJECT_DIR")" || _sg_root=""
      _sg_dir="$(sg_physical_dir "${_sg_b%/*}/")" || _sg_dir=""
      [ -n "$_sg_root" ] && [ -n "$_sg_dir" ] \
        || config_refuse "--baseline must name a file in the repository: $BASELINE"
      sg_inside "$_sg_dir" "$_sg_root" \
        || config_refuse "--baseline must name a file in the repository: $BASELINE"
      _sg_b="${_sg_dir#"$_sg_root"}/${_sg_b##*/}"
      _sg_b="${_sg_b#/}" ;;
  esac
  _sg_b="${_sg_b#./}"
  case "/$_sg_b/" in
    //|*/../*|*/./*|*//*) config_refuse "--baseline must name a file in the repository: $BASELINE" ;;
  esac
  BASELINE_REL="$_sg_b"
  BASELINE=""
  if [ "$(git -C "$PROJECT_DIR" cat-file -t "$RANGE_BASE:$BASELINE_REL" 2>/dev/null)" = blob ]; then
    mkdir -p "$WORK/baseline"
    BASELINE="$WORK/baseline/${BASELINE_REL##*/}"
    base_copy "$BASELINE_REL" "$BASELINE"
  fi
elif [ -z "$BASELINE" ]; then
  _sg_base_baseline=""
  while IFS= builtin read -r -d '' _sg_path; do
    case "${_sg_path##*/}" in *-baseline-"$PROJECT_NAME".json) _sg_base_baseline="$_sg_path" ;; esac
  done < <(git -C "$PROJECT_DIR" ls-tree -z --name-only "$RANGE_BASE" -- "$AUDIT_DIR_REL/" 2>/dev/null)
  if [ -n "$_sg_base_baseline" ]; then
    mkdir -p "$WORK/baseline"
    BASELINE="$WORK/baseline/${_sg_base_baseline##*/}"
    base_copy "$_sg_base_baseline" "$BASELINE"
  fi
fi

# --- security config changed in range -------------------------------------
# The scan always runs under the base config. A range that changes it is a
# change to the gate itself: push mode says so and keeps the normal verdict;
# merge mode BLOCKS until the repo owner's `gate-config-approved: <head SHA>`
# line is on the one open PR for that head. There is no environment override.
# The scanner inputs are root-only: diff mode loads only these root paths (and
# the base audit dir's baselines and an explicit --baseline), so a nested copy
# of any of them is inert. The agent-loader paths of ruling B0-6 match at ANY
# depth, because pi can start in a subdirectory: **/.pi/**,
# **/.agents/{agents,workflows,skills}/**, and **/.trellis/**; and env files,
# **/.envrc and **/.env*, matched on the path only: this gate never reads an
# .env* file's contents. process-gate's own inputs count too: both
# process-gate-local trees, the deprecated .claude/skills/process-gate/
# local.config.sh and any secrets-allowlist.txt. Matching is case-insensitive
# across the whole set.
# This gate does not load the agent or env paths; process-gate (B0-4) keeps
# the identical list. **/.trellis.json counts too, at any depth: its
# template.branch can steer a default diff base, and a subproject's copy or a
# checkout started below the root steers resolution as well.
is_security_config_path() {
  local rc=1
  shopt -s nocasematch
  if [ -n "$FOLD_BASELINE_REL" ]; then
    case "$1" in "$FOLD_BASELINE_REL") shopt -u nocasematch; return 0 ;; esac
  fi
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
    .trellis.json|*/.trellis.json|\
    "$FOLD_AUDIT_DIR_REL"/*-baseline-*.json) rc=0 ;;
  esac
  shopt -u nocasematch
  return "$rc"
}
git -C "$PROJECT_DIR" -c core.quotePath=false diff -z --name-only --no-renames \
  "$RANGE_BASE" "$RANGE_HEAD" -- >"$WORK/range-paths.z" 2>/dev/null \
  || config_refuse "could not list the paths changed in '$RANGE'"
# Gate-config paths are matched after NFKC + full case folding, and the audit
# dir and --baseline are folded the same way, so ASCII case variants (`.PI/x`)
# and compatibility forms match the protected set. Beyond that, ONE rule ends
# the Unicode look-alike chase: a changed path containing ANY non-ASCII byte,
# anywhere, is gate config (owner approval at merge, refused under
# --target=main). A case-insensitive filesystem can check such a name out as a
# protected path (`.agents/ſkills` as `.agents/skills`), and no list of
# look-alikes, format characters or fillers is complete. Non-ASCII names are
# rare in this fleet; the cost is an occasional owner approval. Only path
# names are read here.
FOLDED="$("$PYTHON3_BIN" -I - "$WORK/range-paths.z" "$WORK/range-paths.folded.z" \
  "$AUDIT_DIR_REL" "$BASELINE_REL" <<'PY'
import os, sys, unicodedata


def fold(text):
    return unicodedata.normalize("NFKC", unicodedata.normalize("NFKC", text).casefold())


src, dst, audit, baseline = sys.argv[1:5]
with open(src, "rb") as fh:
    raw = fh.read()
with open(dst, "wb") as out:
    for item in raw.split(b"\0"):
        if not item:
            continue
        path = os.fsdecode(item)
        folded = fold(path)
        # Any non-ASCII byte anywhere in the raw path makes it gate config.
        flag = b"1" if any(byte > 0x7F for byte in item) else b"0"
        out.write(item + b"\0" + os.fsencode(folded) + b"\0" + flag + b"\0")
print(fold(audit))
print(fold(baseline))
print("end")
PY
)" || config_refuse "could not normalise the paths changed in '$RANGE'"
# Three lines: folded audit dir, folded --baseline (possibly empty), "end".
FOLD_AUDIT_DIR_REL="${FOLDED%%$'\n'*}"
FOLDED="${FOLDED#*$'\n'}"
FOLD_BASELINE_REL="${FOLDED%%$'\n'*}"
[ "${FOLDED#*$'\n'}" = end ] || config_refuse "could not normalise the gate-config paths"
CONFIG_CHANGED=""
while IFS= builtin read -r -d '' p && IFS= builtin read -r -d '' folded \
    && IFS= builtin read -r -d '' nonascii; do
  if [ "$nonascii" = 1 ] || is_security_config_path "$folded"; then
    CONFIG_CHANGED="${CONFIG_CHANGED:+$CONFIG_CHANGED, }$p"
  fi
done < "$WORK/range-paths.folded.z"

cat > "$WORK/approval.py" <<'PY'
import json, re, sys


def load(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


mode, path = sys.argv[1], sys.argv[2]
data = load(path)
if mode == "repo":
    owner = (data.get("owner") or {}).get("login") if isinstance(data, dict) else None
    nwo = data.get("nameWithOwner") if isinstance(data, dict) else None
    if not isinstance(owner, str) or not owner or not isinstance(nwo, str) or not nwo:
        print("gh returned no repository owner")
        sys.exit(2)
    print(owner)
    print(nwo)
    sys.exit(0)

head = sys.argv[3].lower()
if mode == "select":
    if not isinstance(data, list):
        print("gh returned no PR list")
        sys.exit(2)
    # A full page may hide a second PR with this head; refuse rather than guess.
    if len(data) >= 1000:
        print("the open-PR search returned a full page (1000) and may be truncated")
        sys.exit(3)
    hits = [p for p in data if isinstance(p, dict) and isinstance(p.get("number"), int)
            and p.get("state") == "OPEN" and str(p.get("headRefOid") or "").lower() == head]
    if len(hits) != 1:
        found = ", ".join(f"#{p['number']} into {p.get('baseRefName') or '?'}" for p in hits)
        print(f"{len(hits)} open PRs have head {head}" + (f" ({found})" if found else "")
              + "; exactly one is required")
        sys.exit(3)
    print(hits[0]["number"])
    sys.exit(0)

owner, number = sys.argv[4], sys.argv[5]
if not isinstance(data, dict) or str(data.get("number")) != number:
    print(f"gh returned no PR #{number}")
    sys.exit(2)
if data.get("state") != "OPEN" or str(data.get("headRefOid") or "").lower() != head:
    print(f"PR #{number} is not open at head {head}")
    sys.exit(3)
# The SHA is exact lowercase hex of the repository's object format (the range
# head's length: 40 for SHA-1, 64 for SHA-256); the owner login is exact. A
# trailing CR (CRLF bodies) is stripped from each line before matching.
line_re = re.compile(r"[ \t]*gate-config-approved:[ \t]*([0-9a-f]{%d})[ \t]*" % len(head))
comments = data.get("comments") or []
reviews = data.get("reviews") or []
# gh returns at most a page of each; a full page may hide the owner's line.
if len(comments) >= 100 or len(reviews) >= 100:
    print(f"PR #{number} has a full page of comments or reviews (100); the approval search may be truncated")
    sys.exit(5)
items = [("comment", c) for c in comments if isinstance(c, dict)]
items += [("review", r) for r in reviews if isinstance(r, dict) and r.get("state") != "DISMISSED"]
others = []
for kind, item in items:
    login = str((item.get("author") or {}).get("login") or "unknown")
    for line in str(item.get("body") or "").split("\n"):
        line = line[:-1] if line.endswith("\r") else line
        m = line_re.fullmatch(line)
        if not m:
            continue
        sha = m.group(1)
        if sha == head and login == owner:
            print(f"\"{line.strip()}\" ({kind} by @{login}, the repo owner, on PR #{number})")
            sys.exit(0)
        others.append(f"{sha[:12]} by @{login}")
if others:
    print(f"PR #{number} has no repo-owner approval of head {head} (found {', '.join(others)})")
else:
    print(f"PR #{number} has no 'gate-config-approved: {head}' line from the repo owner")
sys.exit(4)
PY

# Sets CONFIG_BLOCK to the reason when the owner's approval is missing or
# cannot be read. The PR is the one OPEN PR whose head is the range head;
# none, several, or a closed one BLOCKS.
CONFIG_BLOCK=""
check_config_approval() {
  local out owner nwo number
  if [ -z "$GH_BIN" ]; then
    CONFIG_BLOCK="gh unavailable; the PR approval cannot be read"
    return
  fi
  if ! (builtin cd "$PROJECT_DIR" && "$GH_BIN" repo view --json owner,nameWithOwner) \
      >"$WORK/gh-repo.json" 2>/dev/null; then
    CONFIG_BLOCK="gh could not read the repository owner"
    return
  fi
  out="$("$PYTHON3_BIN" -I "$WORK/approval.py" repo "$WORK/gh-repo.json")" \
    || { CONFIG_BLOCK="$out"; return; }
  owner="${out%%$'\n'*}"; nwo="${out#*$'\n'}"
  if ! (builtin cd "$PROJECT_DIR" && "$GH_BIN" pr list --repo "$nwo" --state open \
      --search "$RANGE_HEAD" --json number,state,headRefOid,baseRefName --limit 1000) \
      >"$WORK/gh-prs.json" 2>/dev/null; then
    CONFIG_BLOCK="gh could not list the open PRs of $nwo"
    return
  fi
  number="$("$PYTHON3_BIN" -I "$WORK/approval.py" select "$WORK/gh-prs.json" "$RANGE_HEAD")" \
    || { CONFIG_BLOCK="$number"; return; }
  if ! (builtin cd "$PROJECT_DIR" && "$GH_BIN" pr view "$number" --repo "$nwo" \
      --json number,state,headRefOid,baseRefName,comments,reviews) >"$WORK/gh-pr.json" 2>/dev/null; then
    CONFIG_BLOCK="gh could not read PR #$number"
    return
  fi
  if out="$("$PYTHON3_BIN" -I "$WORK/approval.py" approve "$WORK/gh-pr.json" "$RANGE_HEAD" "$owner" "$number")"; then
    printf 'security-gate: approval: %s\n' "$out"
  else
    CONFIG_BLOCK="${out:-the PR approval could not be parsed}"
  fi
}

if [ -n "$CONFIG_CHANGED" ]; then
  printf 'security-gate: security-gate config files changed in range: %s\n' "$CONFIG_CHANGED"
  # A push that targets main/master (pre-push passes --target=main through
  # process-gate) never changes gate config, whatever PR approval exists.
  [ "$TARGET_MAIN" != true ] \
    || config_refuse "gate config changed in range: a push that targets main/master cannot change gate config, approved or not; merge it through its PR"
  if [ "$MODE" = merge ]; then
    check_config_approval
  else
    printf 'security-gate: NOTICE: security config changed in range: scanned with BASE config; merge requires gate-config-approved: %s\n' "$RANGE_HEAD"
  fi
fi

# Every verdict passes through here, so a pending merge refusal can never be
# skipped by an early success.
apply_config_block() {
  [ -n "$CONFIG_BLOCK" ] || return 0
  printf "security config changed: needs human review (%s); merge needs the repo owner's gate-config-approved: %s line on the PR\n" \
    "$CONFIG_BLOCK" "$RANGE_HEAD"
  OVERALL="BLOCKED"
}

if [ -z "$BASELINE" ] || [ ! -f "$BASELINE" ]; then
  echo "## security-gate verdict (diff)" >&2
  echo "" >&2
  echo "fail: no baseline JSON found for project '$PROJECT_NAME' under $AUDIT_DIR_REL/ at range base $RANGE_BASE" >&2
  echo "" >&2
  echo "The repo owner runs run-baseline.sh and commits the baseline JSON." >&2
  echo "" >&2
  echo "Diff scan cannot run — baseline required (BLOCKED)." >&2
  print_verdict "❌ fail" "❌ fail" "❌ fail" "BLOCKED"
  exit 1
fi

# --- changed files in range -----------------------------------------------
# An empty file list and a FAILED diff are different facts, and the previous
# form could not tell them apart: `2>/dev/null || true` swallowed the error, so
# a wrong repository, an unresolvable range or any git error produced an empty
# changed list and three green rows with MERGEABLE. A secret scan that reports
# clean having scanned nothing is worse than no scan, because it carries assurance.
# Capture the status separately and let a failed diff BLOCK.
CHANGED_ERR="$WORK/changed.err"
CHANGED_LIST="$WORK/changed.list"
# NUL delimiters preserve non-ASCII, quotes, tabs and newlines literally. T
# includes a symlink replaced by a regular source file, not only A/C/M/R.
git -C "$PROJECT_DIR" -c core.quotePath=false diff -z --name-only --diff-filter=ACMRT "$RANGE" >"$CHANGED_LIST" 2>"$CHANGED_ERR"
CHANGED_RC=$?
if [ "$CHANGED_RC" -ne 0 ]; then
  printf 'security-gate: could not resolve the diff for range %s in %s (git exit %s)\n' \
    "$RANGE" "$PROJECT_DIR" "$CHANGED_RC" >&2
  sed 's/^/security-gate: git: /' "$CHANGED_ERR" >&2
  rm -f "$CHANGED_ERR"
  print_verdict "❌ fail" "❌ fail" "❌ fail" "BLOCKED"
  exit 1
fi
rm -f "$CHANGED_ERR"

# `-C` changes the working directory only; it does NOT override an inherited
# GIT_DIR, so the diff above can be routed at a repository that is not
# PROJECT_DIR. Assert the resolution landed where we intended before trusting
# an empty result to mean "nothing changed".
RESOLVED_TOP="$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || printf '')"
if [ -z "$RESOLVED_TOP" ] || [ "$(cd "$RESOLVED_TOP" 2>/dev/null && pwd -P)" != "$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P)" ]; then
  printf 'security-gate: diff resolved to %s, expected %s — refusing to report a verdict\n' \
    "${RESOLVED_TOP:-<unresolvable>}" "$PROJECT_DIR" >&2
  print_verdict "❌ fail" "❌ fail" "❌ fail" "BLOCKED"
  exit 1
fi

if [ ! -s "$CHANGED_LIST" ]; then
  # A range can carry secrets even when its net file diff is empty (or contains
  # only deletions). Only an empty commit range may skip the history scan.
  RANGE_COMMITS="$(git -C "$PROJECT_DIR" rev-list --count "$RANGE" 2>/dev/null)"
  if [ "$?" -ne 0 ]; then
    printf 'gitleaks did not complete: could not resolve commit range %s\n' "$RANGE" >&2
    print_verdict "✅ pass" "✅ pass" "❌ fail" "BLOCKED"
    exit 1
  fi
  if [ "$RANGE_COMMITS" -eq 0 ]; then
    OVERALL="MERGEABLE"
    apply_config_block
    print_verdict "✅ pass" "✅ pass" "✅ pass" "$OVERALL"
    [ "$OVERALL" = MERGEABLE ] || exit 1
    exit 0
  fi
fi

# --- scoped scans ---------------------------------------------------------
SEMGREP_OUT="$WORK/semgrep.jsonl"
OSV_OUT="$WORK/osv.jsonl"
GITLEAKS_OUT="$WORK/gitleaks.jsonl"

# Completion is independent of findings and baseline dedupe. Keep the scanner's
# exit separate from the parser's; a clean-looking report cannot excuse a crash.
SAST_INCOMPLETE=0; DEPS_INCOMPLETE=0; SECRETS_INCOMPLETE=0
scanner_status() {
  local engine="$1" ran="$2" rc="$3" parsed="$4" scanned="$5" reason="$6"
  printf '%s: ran=%s exit=%s parsed=%s scanned=%s\n' "$engine" "$ran" "$rc" "$parsed" "$scanned"
  [ -n "$reason" ] || return 0
  printf '%s did not complete: %s\n' "$engine" "$reason"
  case "$engine" in
    semgrep|shellcheck) SAST_INCOMPLETE=1 ;;
    osv-scanner) DEPS_INCOMPLETE=1 ;;
    gitleaks) SECRETS_INCOMPLETE=1 ;;
  esac
}

# A shell script does not have to carry a suffix. `pre-push`, `commit-msg`,
# `pre-commit` and a CLI entrypoint conventionally carry none, so a suffix-only
# filter drops the highest-value scripts in a repository out of *every* arm at
# once — not in the semgrep scope, not in the ShellCheck scope. Classification
# falls back to the shebang, which is what ShellCheck itself dispatches on.
# `env` is resolved through to the real interpreter, and only the four dialects
# ShellCheck accepts count; a `#!/usr/bin/env bats` or `#!/usr/bin/env python3`
# file is not shell and returns non-zero here.
shebang_is_shell() {
  # Bounded read: only the shebang line can matter, and a changed file may be a
  # large binary.
  head -c 256 "$1" 2>/dev/null | awk 'BEGIN { rc = 1 }
       NR == 1 {
         if ($0 ~ /^#!/) {
           sub(/^#![ \t]*/, "")
           interp = $1
           if (interp ~ /(^|\/)env$/) {
             for (i = 2; i <= NF; i++) { if ($i !~ /^-/) { interp = $i; break } }
           }
           sub(/.*\//, "", interp)
           if (interp ~ /^(sh|bash|dash|ksh)$/) rc = 0
         }
         exit rc
       }
       END { exit rc }' 2>/dev/null
}

# Paths carved out of the ShellCheck stage, as whitespace-separated globs
# matched against the repo-relative path. Empty by default: a project sets this
# in its `security-gate-local/local.config.sh` to mirror whatever its own lint
# gate carves out, so the two agree. It is deliberately not hardcoded — this
# skill is inherited by every registered project and must not name one project's
# directory layout.
SHELLCHECK_EXCLUDE_GLOBS=()
if [ -n "${SECURITY_GATE_SHELLCHECK_EXCLUDE_GLOBS:-}" ]; then
  # Split on whitespace but never pathname-expand. These are patterns to match a
  # repo-relative path against, not paths to resolve against the current
  # directory — and `core-rules/evals/*` resolves against a real directory when
  # the gate runs from the repository root, which silently turned the pattern
  # into a list of literal paths that matched nothing.
  set -f
  # shellcheck disable=SC2206  # word splitting is the point; globbing is off
  SHELLCHECK_EXCLUDE_GLOBS=(${SECURITY_GATE_SHELLCHECK_EXCLUDE_GLOBS})
  set +f
fi

# Semgrep — scoped to changed files (filter to existing files; skip deletions).
:>"$SEMGREP_OUT"
SCOPE_FILES=()
SHELL_SCOPE_FILES=()
while IFS= read -r -d '' f; do
  [ -z "$f" ] && continue
  [ -f "$PROJECT_DIR/$f" ] || continue
  is_shell=false
  case "$f" in
    *.js|*.jsx|*.ts|*.tsx|*.mjs|*.cjs|*.py|*.go|*.rs|*.java|*.kt|*.rb|*.php) ;;
    # Shell is a first-class language here. Excluding it meant a shell-heavy
    # repository had ~2% of its diff inspected while the row still read `pass`.
    #
    # `.bats` is deliberately NOT in this list. Semgrep's default ignore set skips
    # test directories on a directory scan but not on explicit targets, so a
    # baseline can never hold a finding this mode would then raise out of a test
    # fixture — every run would report the same fixture credentials as new. Test
    # files are covered by the baseline's whole-tree scan instead.
    *.sh|*.bash) is_shell=true ;;
    # `.zsh` gets semgrep only, and that is a real gap rather than coverage:
    # semgrep's registry has no shell ruleset, so only the generic secret and
    # command-injection patterns can fire, and ShellCheck has no zsh dialect to
    # fall back on. A zsh file is listed as scanned and is, in practice, only
    # grepped for secrets.
    *.zsh) ;;
    *) shebang_is_shell "$PROJECT_DIR/$f" || continue; is_shell=true ;;
  esac
  SCOPE_FILES+=("$PROJECT_DIR/$f")
  # ShellCheck refuses anything that is not sh/bash/dash/ksh and reports the
  # refusal as a high-severity finding, so it gets its own narrower list.
  #
  # The carve-out is load-bearing rather than cosmetic: the baseline engine
  # never runs ShellCheck (scripts/lib/semgrep.sh), so a shell finding has no
  # baseline entry to be deduped against and every one is permanently "new". A
  # project therefore scopes this stage to exactly the tree its own lint gate
  # owns; a file the lint gate is not allowed to clean must not be able to block
  # a push here.
  [ "$is_shell" = true ] || continue
  shell_excluded=false
  for glob in ${SHELLCHECK_EXCLUDE_GLOBS[@]+"${SHELLCHECK_EXCLUDE_GLOBS[@]}"}; do
    # shellcheck disable=SC2254  # the config value is a glob pattern by design
    case "$f" in $glob) shell_excluded=true; break ;; esac
  done
  [ "$shell_excluded" = true ] || SHELL_SCOPE_FILES+=("$PROJECT_DIR/$f")
done < "$CHANGED_LIST"

RAN=0; RC=not-run; PARSED=0; SCANNED=0; REASON=""
if [ "${#SCOPE_FILES[@]}" -gt 0 ]; then
  [ -z "$SEMGREP_BIN" ] || RAN=1
  # One profile map owns both rule selection and required language coverage.
  # Shell has no registry SAST pack; its coverage is verified by ShellCheck.
  WEB_EXTENSIONS=".js .jsx .ts .tsx .mjs .cjs"
  SOURCE_EXTENSIONS="$WEB_EXTENSIONS .py .go .rs .java .kt .rb .php"
  case "$PROFILE" in
    web-next)      CONFIGS=(--config=p/owasp-top-ten --config=p/javascript --config=p/typescript --config=p/nextjs --config=p/react); COVERED_EXTENSIONS="$WEB_EXTENSIONS" ;;
    web-static)    CONFIGS=(--config=p/owasp-top-ten --config=p/javascript --config=p/typescript); COVERED_EXTENSIONS="$WEB_EXTENSIONS" ;;
    shell-tooling) CONFIGS=(--config=p/owasp-top-ten --config=p/command-injection --config=p/secrets); COVERED_EXTENSIONS="$SOURCE_EXTENSIONS" ;;
    *)             CONFIGS=(--config=p/owasp-top-ten); COVERED_EXTENSIONS="$SOURCE_EXTENSIONS" ;;
  esac
  # Same exclusions the baseline engine applies (scripts/lib/semgrep.sh), so a
  # diff finding is comparable to a baseline finding rather than an artefact of
  # the two modes disagreeing about scope.
  EXCLUDES=(--exclude=node_modules --exclude=.next --exclude=dist --exclude=build --exclude=.turbo --exclude=test-results --exclude=coverage --exclude=audits --exclude=playwright-report)
  RAW="$WORK/semgrep.raw.json"
  # Without --error, semgrep scan returns 0 even with findings (see
  # lib/semgrep.sh). Exit 1 is findings only WITH --error, not in this mode.
  "$SEMGREP_BIN" scan --json --metrics=off --quiet "${CONFIGS[@]}" "${EXCLUDES[@]}" "${SCOPE_FILES[@]}" >"$RAW" 2>/dev/null
  RC=$?
  [ "$RC" -eq 0 ] || REASON="scanner exit $RC"
  [ "$RAN" -eq 1 ] || REASON="binary not installed"
  # Every gate-owned parser runs isolated (-I: no cwd, no PYTHON* env) and
  # proves it reached its end by creating SG_PARSE_DONE; rc 0 alone is not
  # completion.
  # Only shell files eligible for ShellCheck can transfer parse coverage to it.
  # Keep this exact scope: excluded shell paths and zsh receive no exception.
  printf '%s\0' ${SHELL_SCOPE_FILES[@]+"${SHELL_SCOPE_FILES[@]}"} > "$WORK/semgrep.shell-scope"
  SG_SHELL_SCOPE="$WORK/semgrep.shell-scope" SG_SHELL_PARSE_NOTICE="$WORK/semgrep.shell-parse-notice" \
    SG_PARSE_DONE="$WORK/semgrep.done" "$PYTHON3_BIN" -I - "$RAW" "$PROJECT_DIR" "$WORK/semgrep.scanned" "$COVERED_EXTENSIONS" "$WORK/semgrep.reason" "${SCOPE_FILES[@]}" >"$SEMGREP_OUT" 2>/dev/null <<'PY'
import json, sys, os
raw, root = sys.argv[1], os.path.abspath(sys.argv[2])
sev_map = {"ERROR": "high", "WARNING": "medium", "INFO": "low"}
try:
    with open(raw) as fh: data = json.load(fh)
except (OSError, ValueError):
    sys.exit(2)
if not isinstance(data, dict) or not isinstance(data.get("results"), list): sys.exit(2)
if not all(isinstance(r, dict) for r in data["results"]): sys.exit(2)
if not isinstance(data.get("errors", []), list): sys.exit(2)
paths = data.get("paths", {})
if not isinstance(paths, dict) or not isinstance(paths.get("scanned"), list): sys.exit(2)
if not all(isinstance(path, str) for path in paths["scanned"]): sys.exit(2)
with open(sys.argv[3], "w") as fh:
    fh.write(str(len(paths["scanned"])) + "\n")
# The profile map above supplies coverage; do not duplicate or narrow it here.
covered = set(sys.argv[4].split())
scanned = {os.path.abspath(os.path.join(root, path)) for path in paths["scanned"]}
missing = [os.path.relpath(path, root) for path in sys.argv[6:]
           if path.endswith(tuple(covered)) and os.path.abspath(path) not in scanned]
for i, r in enumerate(data["results"], 1):
    sev = sev_map.get((r.get("extra", {}).get("severity") or "").upper(), "low")
    path = r.get("path") or ""
    if path.startswith(root + os.sep): path = path[len(root) + 1:]
    print(json.dumps({
        "id": f"semgrep-diff-{i:04d}",
        "tool": "semgrep",
        "rule": r.get("check_id", "unknown"),
        "severity": sev,
        "file": path,
        "line": (r.get("start") or {}).get("line", 0),
        "message": (r.get("extra", {}).get("message") or "").splitlines()[0][:280],
    }, ensure_ascii=False))
reasons = []
with open(os.environ["SG_SHELL_SCOPE"], "rb") as fh:
    shell_scope = {os.path.abspath(os.fsdecode(path))
                   for path in fh.read().split(b'\0') if path}
parse_types = {"Syntax error", "PartialParsing", "Lexical error"}
shell_parse_errors = 0
types = set()
for error in data.get("errors", []):
    kind = error.get("type") if isinstance(error, dict) else None
    # Semgrep uses a string for Syntax/Lexical errors and a tagged list for
    # PartialParsing. Unknown/malformed types stay fatal, never become parse.
    if isinstance(kind, list) and kind:
        kind = kind[0]
    kind = " ".join(kind.split()) if isinstance(kind, str) else "unknown"
    path = error.get("path") if isinstance(error, dict) else None
    if (kind in parse_types and isinstance(path, str) and path
            and os.path.abspath(os.path.join(root, path)) in shell_scope):
        shell_parse_errors += 1
    else:
        types.add(kind[:64] or "unknown")
if shell_parse_errors:
    with open(os.environ["SG_SHELL_PARSE_NOTICE"], "w") as fh:
        fh.write(f"semgrep: {shell_parse_errors} shell parse errors not counted (shellcheck is the shell SAST)\n")
if types:
    reasons.append("JSON errors non-empty (" + ", ".join(sorted(types)) + ")")
for path in missing:
    reasons.append("target not scanned: " + json.dumps(path, ensure_ascii=False))
open(__import__("os").environ["SG_PARSE_DONE"], "w").close()
if reasons:
    with open(sys.argv[5], "w") as fh: fh.write("partial scan: " + "; ".join(reasons) + "\n")
    sys.exit(3)
PY
  PARSE_RC=$?
  if [ -f "$WORK/semgrep.shell-parse-notice" ]; then
    while IFS= read -r line; do printf '%s\n' "$line"; done < "$WORK/semgrep.shell-parse-notice"
  fi
  [ -f "$WORK/semgrep.done" ] || PARSE_RC=2
  case "$PARSE_RC" in
    0) PARSED=1 ;;
    3) PARSED=1; read -r PARSE_REASON < "$WORK/semgrep.reason"
       REASON="${REASON:+$REASON; }$PARSE_REASON" ;;
    *) [ -n "$REASON" ] || REASON="missing or malformed JSON" ;;
  esac
  [ "$PARSED" -eq 0 ] || read -r SCANNED < "$WORK/semgrep.scanned"
fi
scanner_status semgrep "$RAN" "$RC" "$PARSED" "$SCANNED" "$REASON"

# ShellCheck — the actual SAST for shell. Semgrep's registry has no bash ruleset
# (`p/bash` 404s) and a canary proves it detects neither `eval "$x"` nor a
# hardcoded AWS secret in a .sh file, so scoping shell in without this engine
# would put shell files in `paths.scanned` and still see nothing. Findings join
# the semgrep stream because they populate the same SAST row.
#
# The stage is opt-in per project rather than fleet-wide, and the default tracks
# the profile only as a convenience. It cannot simply be on everywhere: the
# baseline engine does not run ShellCheck, so on a tree whose shell has never
# been linted every finding is permanently new and unbaselineable, and turning
# this on would block every push over pre-existing debt. `SECURITY_GATE_SHELLCHECK=1`
# in a project's `security-gate-local/local.config.sh` is the opt-in; `=0` is the
# opt-out for a `shell-tooling` project that is not ready yet.
case "${SECURITY_GATE_SHELLCHECK:-}" in
  1|true|on|yes)  SHELLCHECK_ENABLED=true ;;
  0|false|off|no) SHELLCHECK_ENABLED=false ;;
  "")             if [ "$PROFILE" = "shell-tooling" ]; then SHELLCHECK_ENABLED=true; else SHELLCHECK_ENABLED=false; fi ;;
  *)              echo "warn: unrecognized SECURITY_GATE_SHELLCHECK value — treating as unset" >&2
                  if [ "$PROFILE" = "shell-tooling" ]; then SHELLCHECK_ENABLED=true; else SHELLCHECK_ENABLED=false; fi ;;
esac

RAN=0; RC=not-run; PARSED=0; SCANNED=0; REASON=""
if [ "$SHELLCHECK_ENABLED" = true ] && [ "${#SHELL_SCOPE_FILES[@]}" -gt 0 ]; then
  [ -z "$SHELLCHECK_BIN" ] || RAN=1
  SC_RAW="$WORK/shellcheck.raw.json"
  # ShellCheck's documented return values: 0 clean, 1 issues, 2+ incomplete.
  "$SHELLCHECK_BIN" --severity=warning --format=json "${SHELL_SCOPE_FILES[@]}" >"$SC_RAW" 2>/dev/null
  RC=$?
  case "$RC" in 0|1) ;; *) REASON="scanner exit $RC" ;; esac
  [ "$RAN" -eq 1 ] || REASON="binary not installed"
  SG_PARSE_DONE="$WORK/shellcheck.done" "$PYTHON3_BIN" -I - "$SC_RAW" "$PROJECT_DIR" >>"$SEMGREP_OUT" 2>/dev/null <<'SCPY'
import json, sys, os
raw, root = sys.argv[1], os.path.abspath(sys.argv[2])
sev_map = {"error": "high", "warning": "medium", "info": "low", "style": "low"}
try:
    with open(raw) as fh: data = json.load(fh)
except (OSError, ValueError):
    sys.exit(2)
if not isinstance(data, list) or not all(isinstance(r, dict) for r in data): sys.exit(2)
for i, r in enumerate(data, 1):
    path = r.get("file") or ""
    if path.startswith(root + os.sep): path = path[len(root) + 1:]
    print(json.dumps({
        "id": f"shellcheck-diff-{i:04d}",
        "tool": "shellcheck",
        "rule": f"SC{r.get('code', 0)}",
        "severity": sev_map.get((r.get("level") or "").lower(), "low"),
        "file": path,
        "line": r.get("line", 0),
        "message": (r.get("message") or "")[:280],
    }, ensure_ascii=False))
open(__import__("os").environ["SG_PARSE_DONE"], "w").close()
SCPY
  if [ "$?" -eq 0 ] && [ -f "$WORK/shellcheck.done" ]; then
    PARSED=1
    [ -n "$REASON" ] || SCANNED="${#SHELL_SCOPE_FILES[@]}"
  else
    [ -n "$REASON" ] || REASON="missing or malformed JSON"
  fi
fi
scanner_status shellcheck "$RAN" "$RC" "$PARSED" "$SCANNED" "$REASON"

# OSV — only if a manifest changed (deps changed).
:>"$OSV_OUT"
DEPS_CHANGED=0
MANIFEST_LIST="$WORK/manifests.list"
: > "$MANIFEST_LIST"
while IFS= read -r -d '' f; do
  case "$f" in
    *pnpm-lock.yaml|*package-lock.json|*npm-shrinkwrap.json|*yarn.lock|*bun.lock|*bun.lockb|*Cargo.lock|*go.sum|*poetry.lock|*uv.lock|*Pipfile.lock|*Gemfile.lock|*requirements*.txt|*package.json|*Cargo.toml|*go.mod|*pyproject.toml)
      DEPS_CHANGED=1
      printf '%s\0' "$f" >> "$MANIFEST_LIST"
      ;;
  esac
done < "$CHANGED_LIST"
if [ "$DEPS_CHANGED" = "1" ]; then
  TRACKED_LIST="$WORK/tracked.list"
  if git -C "$PROJECT_DIR" ls-files -z --recurse-submodules > "$TRACKED_LIST" 2>/dev/null; then
    "$BASH" -p "$SKILL_DIR/scripts/lib/osv.sh" "$PROJECT_DIR" "$OSV_OUT" \
      --status "$WORK/osv.status" --changed-manifests "$MANIFEST_LIST" --tracked "$TRACKED_LIST" \
      --config "$OSV_CONFIG_FILE"
    [ "$?" -eq 0 ] || DEPS_INCOMPLETE=1
    [ ! -f "$WORK/osv.status" ] || while IFS= read -r line; do printf '%s\n' "$line"; done < "$WORK/osv.status"
  else
    scanner_status osv-scanner 0 not-run 0 0 "could not list tracked files"
  fi
else
  scanner_status osv-scanner 0 not-run 0 0 ""
fi

# Gitleaks — scoped to the diff range via --log-opts. Every non-empty range
# requires this engine, even if no changed file is in the SAST or deps scopes.
:>"$GITLEAKS_OUT"
RAN=0; RC=not-run; PARSED=0; SCANNED=0; REASON=""
if [ -n "$GITLEAKS_BIN" ]; then
  RAN=1
  RAW="$WORK/gitleaks.raw.json"
  # Config, ignore set and source are the base-tree ones prepared above.
  "$GITLEAKS_BIN" detect \
    --source "$GL_SOURCE" \
    --config "$GL_CONFIG_FILE" \
    --gitleaks-ignore-path "$GL_IGNORE_DIR" \
    --log-opts="$RANGE" \
    --report-format json \
    --report-path "$RAW" \
    --redact \
    --no-banner \
    >/dev/null 2>&1
  RC=$?
  # Gitleaks uses 1 for leaks found (lib/gitleaks.sh), not a scanner failure.
  case "$RC" in 0|1) ;; *) REASON="scanner exit $RC" ;; esac
  SG_PARSE_DONE="$WORK/gitleaks.done" "$PYTHON3_BIN" -I - "$RAW" >"$GITLEAKS_OUT" 2>/dev/null <<'PY'
import json, sys
raw = sys.argv[1]
try:
    with open(raw) as fh: data = json.load(fh)
except (OSError, ValueError):
    sys.exit(2)
if not isinstance(data, list) or not all(isinstance(leak, dict) for leak in data): sys.exit(2)
for i, leak in enumerate(data, 1):
    commit = (leak.get("Commit") or "")[:8]
    rule = leak.get("RuleID") or "unknown"
    desc = leak.get("Description") or rule
    print(json.dumps({
        "id": f"gitleaks-diff-{i:04d}",
        "tool": "gitleaks",
        "rule": rule,
        "severity": "high",
        "file": leak.get("File") or "",
        "line": leak.get("StartLine") or 0,
        "message": f"{desc} (commit={commit})" if commit else desc,
    }, ensure_ascii=False))
open(__import__("os").environ["SG_PARSE_DONE"], "w").close()
PY
  if [ "$?" -eq 0 ] && [ -f "$WORK/gitleaks.done" ]; then
    PARSED=1
    # Gitleaks JSON lists leaks, not all inspected files. Record the scanned
    # range rather than inventing a file count from an empty findings list.
    [ -n "$REASON" ] || SCANNED="range:$RANGE"
  else
    [ -n "$REASON" ] || REASON="missing or malformed JSON report"
  fi
else
  REASON="binary not installed"
fi
scanner_status gitleaks "$RAN" "$RC" "$PARSED" "$SCANNED" "$REASON"

# --- dedupe vs baseline ---------------------------------------------------
NEW_FINDINGS="$WORK/new.jsonl"
SG_PARSE_DONE="$WORK/dedupe.done" "$PYTHON3_BIN" -I - "$BASELINE" "$SEMGREP_OUT" "$OSV_OUT" "$GITLEAKS_OUT" >"$NEW_FINDINGS" <<'PY'
import json, sys, os
baseline_p, *parts = sys.argv[1:]
def load_jsonl(p):
    out = []
    if not os.path.exists(p): return out
    with open(p) as fh:
        for ln in fh:
            ln = ln.strip()
            if not ln: continue
            try: out.append(json.loads(ln))
            except json.JSONDecodeError: continue
    return out
known = set()
try:
    with open(baseline_p) as fh: doc = json.load(fh)
    # v2 historical_findings are deliberately excluded: only current-tree
    # findings form the dedupe/pass-fail baseline for a new diff.
    for f in doc.get("findings", []):
        if f.get("triage") == "dropped": continue
        known.add((f.get("tool",""), f.get("rule",""), f.get("file",""), f.get("line", 0)))
except Exception:
    pass
for p in parts:
    for f in load_jsonl(p):
        key = (f.get("tool",""), f.get("rule",""), f.get("file",""), f.get("line", 0))
        if key in known: continue
        print(json.dumps(f, ensure_ascii=False))
open(__import__("os").environ["SG_PARSE_DONE"], "w").close()
PY
# Without its completion marker the dedupe produced no trustworthy list, and an
# empty list would read as "no new findings".
DEDUPE_INCOMPLETE=0
[ -f "$WORK/dedupe.done" ] || DEDUPE_INCOMPLETE=1

# --- verdict --------------------------------------------------------------
SAST_NEW=0; DEPS_NEW=0; SECRETS_NEW=0
SAST_WORST="pass"; DEPS_WORST="pass"; SECRETS_WORST="pass"
HIGH_OR_CRIT=0
LOW_MED=0
declare -a NEW_LINES=()
while IFS= read -r line; do
  [ -z "$line" ] && continue
  NEW_LINES+=("$line")
  tool="$(printf "%s" "$line" | "$PYTHON3_BIN" -I -c 'import json,sys;print(json.loads(sys.stdin.read()).get("tool",""))')"
  sev="$(printf "%s" "$line"  | "$PYTHON3_BIN" -I -c 'import json,sys;print(json.loads(sys.stdin.read()).get("severity",""))')"
  # A finding whose tool or severity cannot be read is counted, never dropped.
  if [ -z "$tool" ] || [ -z "$sev" ]; then DEDUPE_INCOMPLETE=1; continue; fi
  case "$sev" in
    critical|high) HIGH_OR_CRIT=$((HIGH_OR_CRIT+1)); WORST="fail" ;;
    medium|low)    LOW_MED=$((LOW_MED+1));            WORST="warn" ;;
    *)             WORST="warn" ;;
  esac
  case "$tool" in
    # ShellCheck rides the same SAST row as semgrep — it is the SAST engine for
    # shell, and semgrep is blind to it. Without this arm every ShellCheck
    # finding fell through the case, updated no *_WORST, and a new high-severity
    # shell defect returned MERGEABLE/0 on a repository that is mostly Bash.
    # Kept as its own arm rather than relabelling the tool so the printed
    # provenance (`shellcheck/SC1072`) stays truthful.
    semgrep|shellcheck) SAST_NEW=$((SAST_NEW+1)); [ "$WORST" = "fail" ] && SAST_WORST="fail";    [ "$WORST" = "warn" ] && [ "$SAST_WORST" = "pass" ] && SAST_WORST="warn" ;;
    osv)      DEPS_NEW=$((DEPS_NEW+1));    [ "$WORST" = "fail" ] && DEPS_WORST="fail";    [ "$WORST" = "warn" ] && [ "$DEPS_WORST" = "pass" ] && DEPS_WORST="warn" ;;
    gitleaks) SECRETS_NEW=$((SECRETS_NEW+1)); SECRETS_WORST="fail" ;;
  esac
done < "$NEW_FINDINGS"

glyph() {
  case "$1" in
    pass) printf "✅ pass" ;;
    warn) printf "⚠️  warn" ;;
    fail) printf "❌ fail" ;;
  esac
}

[ "$SAST_INCOMPLETE" -eq 0 ] || SAST_WORST="fail"
[ "$DEPS_INCOMPLETE" -eq 0 ] || DEPS_WORST="fail"
[ "$SECRETS_INCOMPLETE" -eq 0 ] || SECRETS_WORST="fail"
if [ "$DEDUPE_INCOMPLETE" -ne 0 ]; then
  printf 'security-gate: the baseline dedupe did not complete; no verdict can be trusted\n'
  SAST_WORST="fail"; DEPS_WORST="fail"; SECRETS_WORST="fail"
fi

OVERALL="MERGEABLE"
[ "$SAST_WORST" = "warn" ] || [ "$DEPS_WORST" = "warn" ] || [ "$SECRETS_WORST" = "warn" ] && OVERALL="NEEDS CHANGES"
[ "$SAST_WORST" = "fail" ] || [ "$DEPS_WORST" = "fail" ] || [ "$SECRETS_WORST" = "fail" ] && OVERALL="BLOCKED"

apply_config_block

print_verdict "$(glyph "$SAST_WORST")" "$(glyph "$DEPS_WORST")" "$(glyph "$SECRETS_WORST")" "$OVERALL"

if [ "${#NEW_LINES[@]}" -gt 0 ]; then
  printf "## New findings vs baseline\n\n"
  printf "_Baseline: \`%s\`_\n\n" "$(basename "$BASELINE")"
  printf "_Range:    \`%s\`_\n\n" "$RANGE"
  for ln in "${NEW_LINES[@]}"; do
    printf "%s\n" "$ln" | "$PYTHON3_BIN" -I -c '
import json, sys
f = json.loads(sys.stdin.read())
loc = f.get("file","(no path)")
line = f.get("line")
if line: loc += ":" + str(line)
print("- **" + f.get("severity","") + "** `" + f.get("tool","") + "/" + f.get("rule","") + "` @ `" + loc + "` — " + f.get("message",""))
'
  done
  printf "\n"
fi

case "$OVERALL" in
  MERGEABLE)        exit 0 ;;
  "NEEDS CHANGES")  exit 2 ;;
  BLOCKED)          exit 1 ;;
esac
