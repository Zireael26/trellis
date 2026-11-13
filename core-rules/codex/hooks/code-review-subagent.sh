#!/usr/bin/env bash
export GIT_OPTIONAL_LOCKS=0
# code-review-subagent.sh — Codex Stop. Advisory review on edit-heavy turns.
# Source: Trellis / core-rules / codex hooks. LEAN MIRROR of the merged Claude
# core-rules/hooks/code-review-subagent.sh (Phase 2b port).
#
# Contract:
#   - Guard: stop_hook_active → exit 0.
#   - Re-entrancy guard: TRELLIS_REVIEW_IN_PROGRESS==1 on entry → exit 0 (the
#     ladder's rung-2 `claude -p` child would otherwise re-fire this hook).
#   - Runs only on edit-heavy turns: ≥3 files changed OR ≥200 lines added/changed
#     in `git diff HEAD`. Threshold overridable via REVIEW_MIN_FILES /
#     REVIEW_MIN_LINES env vars from project hook config.
#   - Sends the staged+unstaged diff (`git diff HEAD`) to the canonical reviewer
#     ladder in {diff, autonomy_level, decisions_log} JSON; findings are advisory.
#   - Blocks only on severity=critical returned by the ladder.
#   - After a completed review, the next one sees only the change since the
#     tree it covered; a failed review is retried at most 3 times per diff and
#     then reported as unreviewed on every Stop (spec 072 U8, see below).
#   - Budget: bounded by the ladder's internal perl-alarm timeout (no outer cap).
#
# Dependencies: jq (required), git (required for diff / skipped otherwise),
#   lib/code-reviewer.sh (the Phase-1 ladder; synced beside this hook by
#   sync-codex-hooks.sh at deploy time → .codex/hooks/lib/code-reviewer.sh).
#
# Status: wired (Phase 2b) — calls lib/code-reviewer.sh ladder; fail-open on
# infra, fail-closed on a parsed `critical` finding.
#
# Autonomy payload contract:
#   - lib/autonomy.sh resolves the canonical fleet -> preset -> project ->
#     session precedence and lowest-preset ceiling.
#   - At L4/L5, the reviewer receives up to 50 KiB of decisions-log.md and must
#     verify decision-log completeness against the diff.
#   - At L1-L3, decisions_log is an empty string. The findings schema is stable.
#
# *** REVIEWER LADDER WIRING — the crux (Phase 2a bug, do NOT repeat) ***
# The single canonical reviewer is the ladder lib/code-reviewer.sh, invoked as a
# sibling: bash "$HOOK_DIR/lib/code-reviewer.sh". Do NOT pre-export
# TRELLIS_REVIEW_IN_PROGRESS before that call: the ladder gates rung 2 on that
# sentinel, so pre-setting it would force every default-path call straight to the
# rung-3 regex and the built-in `claude -p` reviewer would never run. The ladder
# exports the sentinel itself, internally, right before spawning ANY child, so
# the child's own top-of-hook guard still trips — recursion is prevented without
# disabling rung 2. No outer `timeout` (and never a bare `timeout` — GNU/gtimeout
# are absent on macOS); the ladder bounds rung 2 via its own perl-alarm shim.

set -u

INPUT=$(cat)

# Source shared lib (sibling to this script) + enforce jq dependency.
__se_lib="$(dirname "${BASH_SOURCE[0]}")/lib/deps.sh"
[ -f "$__se_lib" ] || { echo "code-review-subagent: missing sibling lib at $__se_lib — re-run sync-hooks" >&2; exit 1; }
# shellcheck source=lib/deps.sh disable=SC1090,SC1091
. "$__se_lib"
_se_require_jq "code-review-subagent"
__se_autonomy_lib="$(dirname "${BASH_SOURCE[0]}")/lib/autonomy.sh"
[ -f "$__se_autonomy_lib" ] || { echo "code-review-subagent: missing sibling lib at $__se_autonomy_lib — re-run sync-codex-hooks" >&2; exit 1; }
# shellcheck source=lib/autonomy.sh disable=SC1090,SC1091
. "$__se_autonomy_lib"

STOP_ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active == true')
if [ "$STOP_ACTIVE" = "true" ]; then
  exit 0
fi

# --- Mandatory fork-bomb sentinel ---
# Rung 2 of the ladder spawns a child `claude -p` turn, whose own Stop hook would
# otherwise re-fire this reviewer — recursively. `stop_hook_active` does NOT guard
# this: it is FALSE in the `claude -p` child (a fresh, separate session, not a
# re-entrant stop). The ladder exports TRELLIS_REVIEW_IN_PROGRESS=1 before its
# claude call, and that env propagates into the child's Stop-hook environment. So
# on entry, if the sentinel is set, bail immediately.
if [ "${TRELLIS_REVIEW_IN_PROGRESS:-}" = "1" ]; then
  exit 0
fi

# Resolve the hook directory now, BEFORE any `cd`, so the sibling-ladder path
# below is correct regardless of the working directory we change into. The
# ladder is a sibling when deployed; run in place from the payload, the shared
# core-rules/hooks/lib/ is the fallback, and only when this directory IS the
# declared runtime's Codex tree (spec 055 R1.1) — never for a project path that
# merely ends in core-rules/codex/hooks.
HOOK_DIR=$(unset CDPATH; cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
__h_rt=$(unset CDPATH; [ -n "${TRELLIS_ROOT:-}" ] && cd -P -- "$TRELLIS_ROOT" 2>/dev/null && pwd -P)
REVIEWER_LIB="$HOOK_DIR/lib/code-reviewer.sh"
if [ ! -f "$REVIEWER_LIB" ] && [ -n "$__h_rt" ] && [ "$HOOK_DIR" = "$__h_rt/core-rules/codex/hooks" ]; then
  REVIEWER_LIB="$HOOK_DIR/../../hooks/lib/code-reviewer.sh"
fi

PROJECT_DIR="${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
cd "$PROJECT_DIR" 2>/dev/null || exit 0
# Counts, review payload and recorded tree must all cover the same worktree,
# including untracked files outside a project subdirectory.
if CR_WORKTREE=$(git rev-parse --show-toplevel 2>/dev/null); then
  cd "$CR_WORKTREE" 2>/dev/null || exit 0
fi
CR_HAS_HEAD=0
git rev-parse -q --verify 'HEAD^{commit}' >/dev/null 2>&1 && CR_HAS_HEAD=1

# --- Resolve canonical repo root (worktree-aware; falls back to PROJECT_DIR) ---
REPO_ROOT=$(_se_repo_root "$PROJECT_DIR")

# --- Untracked-inclusive change set (read-only) -------------------------------
# `git diff HEAD` omits untracked files, but a turn that only CREATES new files
# is exactly what needs review — and the reviewer must see their contents, not a
# blank diff. Fold untracked (non-ignored) files into every count AND into the
# reviewer payload, all from the same source, so the gate and the diff never
# disagree. Strictly read-only: `git ls-files --others` and `git diff --no-index`
# never touch the index (no `git add -N`), so the user's staging/status is
# unchanged.
# Exclude harness-state dirs: `.claude/` / `.codex/` hold symlinks, primers, and
# THIS hook's own idempotency marker — never user code to review. Not excluding
# them self-poisons idempotency (the marker written this turn would reappear as
# untracked content next turn, changing the diff hash).
_cr_untracked() {
  git ls-files --others --exclude-standard -z -- ':/' ':(exclude,top).claude' ':(exclude,top).codex' 2>/dev/null
}
_cr_tracked_diff() {
  if [ "$CR_HAS_HEAD" -eq 1 ]; then
    git diff HEAD "$@" 2>/dev/null
  else
    # Preserve unborn-index/worktree coverage; D2 renders the captured tree.
    git diff --cached "$@" 2>/dev/null && git diff "$@" 2>/dev/null
  fi
}
_cr_changed_names() {
  {
    _cr_tracked_diff --no-renames --name-only
    _cr_untracked | while IFS= read -r -d '' f; do
      case "$f" in
        *$'\n'*|*$'\r'*|*$'\t'*)
          printf '.trellis-encoded-path-%s\n' "$(printf '%s' "$f" | od -An -tx1 | tr -d ' \n')" ;;
        *) printf '%s\n' "$f" ;;
      esac
    done
  } | /usr/bin/env LC_ALL=C sort -u | /usr/bin/env LC_ALL=C sed '/^$/d'
}

# --- TRELLIS_REVIEW_OVERRIDE escape ---
# Documented, LOGGED deferral — mirrors the TRELLIS_ALLOW_MAIN_PUSH tripwire. When
# the operator sets this, code-review is skipped for this turn, but NEVER silently:
# we append an acknowledged-and-deferred entry to the decisions-log so a false
# critical never trains the operator toward a habitual --no-verify. Logged in the
# dated format session-context.sh greps ("- 20YY-..."). The decisions-log stays at
# the canonical repo root (NOT under .codex) — it is shared across harnesses.
if [ -n "${TRELLIS_REVIEW_OVERRIDE:-}" ]; then
  OVERRIDE_FILES=$(_cr_changed_names | awk 'END{print NR}')
  if printf '%s\n' "- $(date +%Y-%m-%d) code-review deferred via TRELLIS_REVIEW_OVERRIDE on a turn touching ${OVERRIDE_FILES} file(s)" \
       >> "$REPO_ROOT/decisions-log.md" 2>/dev/null; then
    :
  else
    # The deferral must never be both un-logged AND un-surfaced. If the
    # decisions-log is unwritable (read-only file/dir/FS), surface a breadcrumb
    # instead of silently swallowing the skip.
    _se_emit_system_message "code-review override applied (TRELLIS_REVIEW_OVERRIDE) but the decisions-log at $REPO_ROOT/decisions-log.md was unwritable — record the deferral manually."
  fi
  exit 0
fi

if ! command -v git >/dev/null 2>&1 || ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exit 0
fi

# --- D2 metadata-only admission (before wc, diff render or shadow-index add) ---
# This is NOT a reviewed-state key. It may suppress an identical unmet notice,
# never authorize a completed marker. Budgets are fixed, not env-overridable.
_cr_resolve_python() {
  local resolver
  case "$HOOK_DIR" in
    */core-rules/hooks) resolver="$HOOK_DIR/../../scripts/lib/trellis-python.sh" ;;
    */core-rules/codex/hooks) resolver="$HOOK_DIR/../../../scripts/lib/trellis-python.sh" ;;
    *) resolver="$HOOK_DIR/lib/trellis-python.sh"
       if [ ! -f "$resolver" ]; then
         if [ -n "${TRELLIS_ROOT:-}" ]; then resolver="$TRELLIS_ROOT/scripts/lib/trellis-python.sh"
         else resolver="$HOOK_DIR/../../scripts/lib/trellis-python.sh"; fi
       fi ;;
  esac
  [ -f "$resolver" ] || return 1
  # Resolve from this hook's own installation, never an unrelated cwd/PATH.
  # shellcheck source=../../../scripts/lib/trellis-python.sh disable=SC1090,SC1091
  . "$resolver" || return 1
  trellis_python_trusted || return 1
  CR_PYTHON="$TRELLIS_PYTHON"
}
_cr_capture_metadata() {
  "$CR_PYTHON" -I - "$CR_WORKTREE" <<'CR_METADATA_PY'
import hashlib
import json
import os
import stat
import subprocess
import sys

limit_bytes, limit_files = 200000, 256
binary_suffixes = {'.bin', '.png', '.jpg', '.jpeg', '.gif', '.webp', '.ico',
                  '.pdf', '.zip', '.gz', '.xz', '.bz2', '.7z', '.tar', '.dmg',
                  '.exe', '.dll', '.so', '.dylib', '.o', '.a', '.wasm',
                  '.mp3', '.mp4', '.mov', '.woff', '.woff2', '.ttf'}
proc = subprocess.Popen(['git', 'ls-files', '--others', '--exclude-standard', '-z', '--', ':/'],
                        cwd=sys.argv[1], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
count = total = 0
reason = ''
excluded = []
eligible = []
identity = hashlib.sha256(b'trellis-review-capture-admission-v1\0')
pending = b''
stopped = False
try:
    while not stopped:
        chunk = proc.stdout.read1(8192)
        if not chunk:
            break
        pending += chunk
        while b'\0' in pending:
            raw, pending = pending.split(b'\0', 1)
            if raw in (b'.claude', b'.codex') or raw.startswith((b'.claude/', b'.codex/')):
                continue
            count += 1
            identity.update(raw + b'\0')
            if count > limit_files:
                reason = 'untracked count exceeds 256 files'
                stopped = True
                break
            path = os.fsdecode(raw)
            entry = os.lstat(os.path.join(sys.argv[1], path))
            metadata = (entry.st_dev, entry.st_ino, entry.st_mode, entry.st_size,
                        entry.st_mtime_ns, entry.st_ctime_ns)
            identity.update(repr(metadata).encode() + b'\0')
            # No open/read/sniff here: known binary/opaque paths are announced
            # exclusions, not assumed reviewed. Unknown content classification
            # belongs to the later bounded-capture phase.
            if (not stat.S_ISREG(entry.st_mode)
                    or os.path.splitext(path)[1].lower() in binary_suffixes
                    or any(0xDC80 <= ord(c) <= 0xDCFF for c in path)):
                excluded.append(path.encode('utf-8', 'backslashreplace').decode('utf-8'))
                continue
            eligible.append(path)
            # Excluded entries are metadata-only: their bytes will never be
            # opened by wc or hashed into the shadow index. Budget every entry
            # for count, and every eligible regular file for logical bytes.
            total += entry.st_size
            if total > limit_bytes:
                reason = 'untracked logical size exceeds 200000 bytes'
                stopped = True
                break
    if pending and not stopped:
        raise ValueError('unterminated path enumeration')
finally:
    proc.stdout.close()
    if stopped and proc.poll() is None:
        proc.terminate()
    code = proc.wait()
if code and not stopped:
    raise ValueError('untracked enumeration failed')
print(json.dumps({'schema_version': 1, 'status': 'unmet' if reason else 'admitted',
                  'reason': reason, 'count': count, 'bytes': total,
                  'excluded': excluded, 'eligible': eligible, 'notice_key': identity.hexdigest()}))
CR_METADATA_PY
}

_cr_capture_unmet() {
  local meta="$1" ns=codex state='' notice='' key old='' tmp='' message
  [ "${TRELLIS_HARNESS:-codex}" != pi ] || ns=pi
  if [ "${CR_LOST_NOTICE:-0}" -eq 1 ]; then
    meta=$(printf '%s' "$meta" | jq --arg note "$(_cr_reset_note)" --arg lost_key "$CR_LOST_KEY" \
      '.loss_context = $note | .notice_key = ((.notice_key // "unavailable") + ":coverage-loss:" + $lost_key)')
  fi
  key=$(printf '%s' "$meta" | jq -r '.notice_key // "unavailable"')
  if state=$(_se_turn_state_dir "$PROJECT_DIR"); then
    state="${state%/turn-baseline/*}/code-review/${state##*/}"
    ( umask 077 && mkdir -p "$state" ) 2>/dev/null || state=''
  fi
  if [ -n "$state" ]; then
    notice="$state/unmet.capture.$ns"
    old=$(jq -r '.notice_key // empty' "$notice" 2>/dev/null) || old=''
    if [ "$old" = "$key" ]; then
      printf '%s\n' 'code-review-subagent: review unmet: remains UNREVIEWED; repeated capture notice suppressed' >&2
      _se_emit_system_message 'code-review-subagent: review remains UNREVIEWED; identical unmet capture, no model call'
      return 0
    fi
    if tmp=$(mktemp "$state/.unmet.XXXXXX" 2>/dev/null); then
      if ! { printf '%s\n' "$meta" > "$tmp" && mv -f "$tmp" "$notice"; }; then
        rm -f -- "${tmp:?}"
      fi
    fi
  fi
  message=$(printf '%s' "$meta" | jq -r '"code-review-subagent: UNREVIEWED — review unmet: " + .reason + (if (.excluded | length) > 0 then "; excluded: " + (.excluded[:8] | map(.[0:256]) | tojson) else "" end) + (.loss_context // "") + ". No reviewer was called and nothing is marked completed. Please commit, split or exclude the change set explicitly before retrying."')
  printf '%s\n' "$message" >&2
  _se_emit_system_message "$message"
}

if ! _cr_resolve_python 2>/dev/null; then
  printf '%s\n' 'code-review-subagent: review unmet: trusted Python resolver unavailable relative to hook directory or supplied payload root' >&2
  _se_emit_system_message 'code-review-subagent: review unmet: trusted Python resolver unavailable relative to hook directory or supplied payload root'
  exit 0
fi
CR_CAPTURE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/trellis-review-capture.XXXXXX") || exit 0
trap 'rm -rf -- "${CR_CAPTURE_DIR:?}"' EXIT
CR_KNOWN_FILE="$CR_CAPTURE_DIR/known.json"
CR_EXCLUDED_FILE="$CR_CAPTURE_DIR/diff.excluded"
CR_OPAQUE_FILE="$CR_CAPTURE_DIR/diff.opaque"
CR_COVERED_FILE="$CR_CAPTURE_DIR/covered.json"
CR_PENDING_FILE="$CR_CAPTURE_DIR/pending.json"
CR_PATH_HEX_FILE="$CR_CAPTURE_DIR/diff.path-hex"
printf '%s\n' '{}' > "$CR_COVERED_FILE"
printf '%s\n' '{}' > "$CR_PENDING_FILE"
if ! CR_CAPTURE_META=$(_cr_capture_metadata); then
  CR_CAPTURE_META='{"status":"unmet","reason":"metadata admission unavailable","excluded":[],"notice_key":"unavailable"}'
fi
if [ "$(printf '%s' "$CR_CAPTURE_META" | jq -r '.status')" != admitted ]; then
  _cr_capture_unmet "$CR_CAPTURE_META"
  exit 0
fi

# The NUL path stream is derived from the admitted metadata snapshot. Never
# re-enumerate all untracked paths for a content read or shadow-index add.
_cr_reviewable_untracked() {
  printf '%s' "$CR_CAPTURE_META" | jq -j '.eligible[] | . + "\u0000"'
}
printf '%s' "$CR_CAPTURE_META" | jq -c '.excluded | unique' > "$CR_KNOWN_FILE"
cp "$CR_KNOWN_FILE" "$CR_EXCLUDED_FILE"
CR_KNOWN_EXCLUDED=$(cat "$CR_KNOWN_FILE")
CR_EXCLUDED="$CR_KNOWN_EXCLUDED"
CR_INCOMPLETE=0
[ "$CR_EXCLUDED" = '[]' ] || CR_INCOMPLETE=1

# --- Threshold check ---
MIN_FILES="${REVIEW_MIN_FILES:-3}"
MIN_LINES="${REVIEW_MIN_LINES:-200}"

# Count always outputs a number, never errors. Avoid `grep -c '^' || echo 0` —
# that doubles output to "0\n0" on empty input and breaks numeric comparisons.
CHANGED_FILES=$(_cr_changed_names | awk 'END{print NR}')

# Sum added+deleted lines: tracked via numstat (skip binary rows marked '-'),
# untracked via line count (the whole new file is an addition).
TRACKED_LINES=$(_cr_tracked_diff --numstat \
  | awk '$1 != "-" && $2 != "-" { sum += $1 + $2 } END { print sum+0 }')
UNTRACKED_LINES=$(while IFS= read -r -d '' f; do [ -f "$f" ] && wc -l < "$f" 2>/dev/null; done < <(_cr_reviewable_untracked) \
  | awk '{ sum += $1 } END { print sum+0 }')
CHANGED_LINES=$((TRACKED_LINES + UNTRACKED_LINES))

if [ "$CHANGED_FILES" -lt "$MIN_FILES" ] && [ "$CHANGED_LINES" -lt "$MIN_LINES" ]; then
  exit 0
fi

# --- Doc-only skip: if every changed file has a doc extension (.md/.mdx/.rst/.txt),
# skip. Earlier versions also skipped anything under `docs/` regardless of
# extension — that wrongly skipped non-doc files like `docs/scripts/setup.sh`
# or `docs/examples/app.ts`. The `(^|/)[^/]+\.ext$` anchor matches the final
# path segment only, so a doc anywhere in the tree (e.g. `src/notes.md`) still
# counts as a doc and a non-doc under `docs/` still counts as a non-doc.
NONDOC_COUNT=$(_cr_changed_names \
  | /usr/bin/env LC_ALL=C grep -vE '(^|/)[^/]+\.(md|mdx|rst|txt)$' \
  | awk 'END{print NR}')
if [ "$NONDOC_COUNT" -eq 0 ]; then
  exit 0
fi

# Resolve the context level before exact lookup; old or lower-level coverage
# cannot authorize skipping a newly required L4/L5 decision-log review.
if ! _se_resolve_autonomy "$REPO_ROOT"; then
  echo 'code-review-subagent: review degraded: autonomy policy unavailable; no review marker written' >&2
  exit 0
fi
export AUTONOMY_LEVEL
export DECISIONS_LOG_PATH="$REPO_ROOT/decisions-log.md"

# --- Exact reviewed-state lookup, before diff rendering/hashing ---
# D2: a budget prefix is never reviewed. Announced opaque exclusions may
# accompany review of the eligible text, but can never authorize completion.
# Text coverage and cached blocking verdicts are distinct from completion;
# exact incomplete captures repeat a notice, not a model call. Oversized
# capture exits unmet before the reviewer.
CR_DIFF_BASE=HEAD
CR_TRUNCATED=0

# --- Idempotency marker ---
# A turn can fire this hook AND run the execute-body review over the same diff;
# we must not double-charge the LLM. Key the marker on a content hash of the
# diff (git hash-object --stdin — always present in a git hook, no coreutils
# dependency). If this exact diff was already reviewed this turn, exit 0. The marker is touched only AFTER a completed
# review (clean + advisory paths), NOT on the block path — a blocked turn must
# re-review once the diff changes via the fix. Hashed over the FULL diff (see
# above), so a prefix-reviewed diff never shares a marker with its full self.
# Codex marker lives under .codex/.
# Marker identity is computed from the complete bounded capture only, below.

# --- Delta review and bounded retry (spec 072 U8) ---
# State lives outside the worktree, beside the turn baseline:
# <TRELLIS_HOME|~/.trellis>/state/code-review/<worktree hash>/
#   capture.<codex|pi>.json — last reviewed or cached-block capture + exclusions
#   covered.<codex|pi>.json — noncritical text coverage base, NOT completion
#   reviewed.<codex|pi> — "<HEAD|unborn> <tree>" of the last COMPLETED review
#   fail.<diff hash> — failed attempts on that exact diff
# A completed review records the tree it covered; the next one reviews only
# the change from that tree, when the recorded HEAD is an ancestor of HEAD and
# both trees are readable. Anything else reviews the full diff, as before.
# A failed review leaves no marker and no recorded tree: the same diff is
# retried on each Stop up to CR_MAX_ATTEMPTS times, then every Stop says it
# is unreviewed until the diff changes. A failure never reads as reviewed.
CR_MAX_ATTEMPTS=3
CR_HARNESS=codex
[ "${TRELLIS_HARNESS:-codex}" = "pi" ] && CR_HARNESS=pi
CR_STATE="" CR_TREE="" CR_HEAD="unborn" CR_FAILS=0
_cr_tree() {
  local idx real out
  # Resolve the real index BEFORE pointing GIT_INDEX_FILE elsewhere: a copy of
  # it keeps every tracked path (harness directories included) and its stat
  # cache, so `add -u` hashes only what changed. No index file and an unborn
  # HEAD mean nothing is tracked yet; any other failure to copy returns
  # nothing, and the caller reviews the full diff.
  real=$(git rev-parse --git-path index 2>/dev/null) && [ -n "$real" ] || return 1
  idx=$(mktemp "${TMPDIR:-/tmp}/trellis-review-index.XXXXXX") || return 1
  if [ -e "$real" ]; then
    # Preserve the index timestamp: a fresh copy mtime hides racy-clean
    # same-size edits from Git's stat-cache/content recheck.
    cp -p "$real" "$idx" 2>/dev/null || { rm -f "$idx"; return 1; }
  elif git rev-parse -q --verify 'HEAD^{commit}' >/dev/null 2>&1; then
    rm -f "$idx"
    return 1
  else
    rm -f "$idx"
  fi
  out=$( export GIT_INDEX_FILE="$idx"
    set -o pipefail
    { [ -e "$idx" ] || git read-tree --empty; } \
      && git add -u 2>/dev/null \
      && { if printf '%s' "$CR_CAPTURE_META" | jq -e '.eligible | length > 0' >/dev/null; then
             _cr_reviewable_untracked | git --literal-pathspecs add --pathspec-from-file=- --pathspec-file-nul 2>/dev/null
           else :; fi; } \
      && git write-tree 2>/dev/null ) || out=""
  rm -f "$idx" "$idx.lock"
  [ -n "$out" ] && printf '%s' "$out"
}
_cr_warn() {
  printf '%s\n' "$1" >&2
  _se_emit_system_message "$1"
}
# _cr_failed <message> — count one failed attempt on this diff, say so, exit 0.
_cr_failed() {
  local n=$((CR_FAILS + 1))
  [ -z "$CR_STATE" ] || ( umask 077 && printf '%s\n' "$n" > "$CR_STATE/fail.$DIFF_HASH" ) 2>/dev/null
  printf '%s (attempt %s of %s on this diff)\n' "$1" "$n" "$CR_MAX_ATTEMPTS" >&2
  if [ "${CR_LOST_NOTICE:-0}" -eq 1 ]; then
    _cr_warn "code-review-subagent: UNREVIEWED$(_cr_reset_note)"
  fi
  exit 0
}
# Coverage is not completion. Only this separate record can advance a delta
# after all reviewable text was reviewed while opaque exclusions remained.
_cr_reset_note() {
  local tmp
  if [ "${CR_COVERAGE_RESET:-0}" -eq 1 ]; then
    printf '%s' '; coverage record was reset; no opaque debt retires in this Stop'
    if [ "${CR_RESET_HOLD:-0}" -eq 1 ]; then printf '%s' '; temporary hold clears after the next clean recapture'; fi
    if [ "${CR_BASE_LOST:-0}" -eq 1 ] && [ "${CR_LOST_NOTICE:-0}" -eq 1 ]; then
      printf '%s' '; coverage base lost; this Stop remains incomplete and recaptures from HEAD'
      if [ -n "$CR_LOST_FILE" ] && tmp=$(mktemp "$CR_STATE/.lost-base.XXXXXX" 2>/dev/null); then
        if ! { printf '%s\n' "$CR_LOST_KEY" > "$tmp" && mv -f "$tmp" "$CR_LOST_FILE"; } 2>/dev/null; then rm -f -- "$tmp"; fi
      fi
    fi
  fi
}
_cr_exclusion_notice() {
  local shown
  local message
  shown=$(jq -c 'map(.[0:256]) | .[:8]' "$1")
  message="code-review-subagent: review incomplete: excluded (up to 8 paths): $shown; coverage remains UNREVIEWED, no completed marker or tree written"
  message="$message$(_cr_reset_note)"
  printf '%s\n' "$message" >&2
  if [ "${2:-stderr}" = model ]; then _se_emit_system_message "$message"; fi
}
# Opaque debt is not a policy-context authorization. Preserve it across level
# and completion-reference/history changes. Only its structure is relevant;
# A readable covered tree survives a proven local HEAD rewrite, not a branch
# switch or rebase onto upstream. Descendant/merge behavior is unchanged.
_cr_valid_debt() {
  local doc="$1"
  printf '%s' "$doc" | jq -e '
    .schema_version == 3 and (.opaque | type == "array")
    and ((.reset_hold // false) | type == "boolean")
    and all(.opaque[]; (.path | type == "string") and (.path_hex | type == "string")
      and (.path_hex | test("^([0-9a-f]{2})+$")) and (.blob | type == "string")
      and (.base_blob == null or (.base_blob | type == "string")) and (.announced_head | type == "string"))
    and (.head | type == "string") and (.tree | type == "string")' >/dev/null 2>&1
}
_cr_readable_tree() {
  local tree
  tree=$(printf '%s' "$1" | jq -r '.tree')
  [[ "$tree" =~ $CR_OID ]] && git cat-file -e "$tree^{tree}" 2>/dev/null
}
_cr_valid_text_base() {
  local old
  _cr_readable_tree "$1" || return 1
  old=$(printf '%s' "$1" | jq -r '.head')
  [ "$old" = "$CR_HEAD" ] && return 0
  if [ "$old" != unborn ]; then
    [[ "$old" =~ $CR_OID ]] || return 2
    git merge-base --is-ancestor "$old" "$CR_HEAD" 2>/dev/null && return 0
  fi
  # A sibling graph alone cannot distinguish amend from checkout. Require
  # the shared/reduced parent chain AND bounded worktree reflog evidence of
  # amend/reset, with no checkout/rebase crossing since the covered HEAD.
  if "$CR_PYTHON" -I - "$old" "$CR_HEAD" <<'CR_REWRITE_PY'
import subprocess
import sys
from pathlib import Path

old, head = sys.argv[1:]
logging = subprocess.run(['git', 'config', '--bool', 'core.logAllRefUpdates'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
log_path = subprocess.run(['git', 'rev-parse', '--git-path', 'logs/HEAD'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
if logging.returncode not in (0, 1) or logging.stdout.strip() == b'false' or log_path.returncode:
    sys.exit(1)
# Without the worktree HEAD log, `reflog show HEAD` may silently fall back
# to a branch log that cannot prove intervening checkout crossings.
try:
    if Path(log_path.stdout.decode().strip()).stat().st_size == 0:
        sys.exit(1)
except (OSError, UnicodeError):
    sys.exit(1)
def parent(commit):
    row = subprocess.run(['git', 'rev-parse', '--verify', commit + '^1'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if row.returncode == 0:
        return row.stdout.strip()
    if subprocess.run(['git', 'cat-file', '-e', commit + '^{commit}'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        sys.exit(1)
    return None  # A verified root commit has no first parent.

if old != 'unborn':
    a, b = parent(head), parent(old)
    if (a is None) != (b is None):
        sys.exit(1)
    if a is not None and subprocess.run(['git', 'merge-base', '--is-ancestor', a, b], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        sys.exit(1)
proc = subprocess.Popen(['git', 'reflog', 'show', '-n', '32', '--format=%H%x00%gs%x00', 'HEAD'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
data = proc.stdout.read(200001)
proc.stdout.close()
if len(data) > 200000 and proc.poll() is None:
    proc.terminate()
code = proc.wait()
if code or len(data) > 200000:
    sys.exit(1)
fields = data.split(b'\0')
rewrite = False
for n in range(0, len(fields) - 1, 2):
    oid, action = fields[n].strip(), fields[n + 1]
    if n == 0 and oid != head.encode():
        sys.exit(1)
    if old == 'unborn':
        sys.exit(0 if action.startswith(b'commit (initial):') else 1)
    if oid == old.encode():
        sys.exit(0 if rewrite else 1)
    if action.startswith(b'reset:'):
        # Resetting to a sibling/upstream ref is a switch, not a rewrite of
        # the covered commit. The reflog oid is the reset's actual target.
        if subprocess.run(['git', 'merge-base', '--is-ancestor', oid, old], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
            sys.exit(1)
        rewrite = True
    elif action.startswith(b'commit (amend):'):
        previous = fields[n + 2].strip() if n + 2 < len(fields) else b''
        if len(previous) not in (40, 64) or any(c not in b'0123456789abcdef' for c in previous):
            sys.exit(1)
        # The label alone is forgeable via update-ref. An amend must preserve
        # the first parent of the HEAD replaced by this exact reflog entry.
        if parent(oid.decode('ascii')) != parent(previous.decode('ascii')):
            sys.exit(1)
        rewrite = True
    elif not action.startswith(b'commit:'):
        sys.exit(1)
sys.exit(1)
CR_REWRITE_PY
  then return 0; fi
  # Readable coverage, but its history cannot be proved locally. The caller
  # announces this loss once and recaptures from HEAD without upstream blame.
  return 2
}
_cr_valid_coverage() {
  local doc="$1"
  _cr_valid_debt "$doc" || return 1
  printf '%s' "$doc" | jq -e '
    (.contract | type == "string") and (.completed_record | type == "string")
    and (.verdict == "text-reviewed" or .verdict == "block")
    and (.incomplete | type == "boolean") and (.reason | type == "string")
    and ((.coverage_reset // false) | type == "boolean")
    and ((.coverage_base_lost // false) | type == "boolean")
    and (if has("reviewed_path_hex") then (.reviewed_path_hex | type == "array" and all(.[]; type == "string" and test("^([0-9a-f]{2})+$"))) else true end)
    and (.coverage_accepted == (.verdict == "text-reviewed"))
    and all(.reviewed_files, .known_excluded, .excluded; type == "array" and all(.[]; type == "string"))' >/dev/null 2>&1 || return 1
  git cat-file -e "$(printf '%s' "$doc" | jq -r '.tree')^{tree}" 2>/dev/null
}
_cr_reference_matches() {
  # Reference identity belongs to the saved capture's level. A new autonomy
  # level invalidates its verdict cache, not the already-reviewed tree base.
  printf '%s' "$1" | jq -e --arg completed "$CR_COMPLETED_RECORD" '
    (.contract | capture("^capture-v5:(?<level>L[1-5])$").level) as $level
    | (.completed_record == $completed or
       (.verdict == "text-reviewed" and .incomplete == false
        and $completed == (.head + " " + .tree + " capture-v2:" + $level)))' >/dev/null 2>&1
}
_cr_context_matches() {
  _cr_reference_matches "$1" || return 1
  printf '%s' "$1" | jq -e --arg context "capture-v5:L$AUTONOMY_LEVEL" '.contract == $context' >/dev/null 2>&1
}
_cr_valid_capture() {
  _cr_valid_coverage "$1" || return 1
  _cr_valid_text_base "$1" || return $?
  _cr_context_matches "$1" || return 1
  printf '%s' "$1" | jq -e '(.opaque | length) <= 256' >/dev/null 2>&1
}
_cr_record_capture() {
  local verdict="$1" reason="${2:-}" record tmp completed
  # Cached blocks retain the critical finding, not an already-announced loss.
  if [ "$verdict" = block ] && [ "${CR_LOST_NOTICE:-0}" -eq 1 ]; then
    reason=${reason%'; coverage base lost; this Stop remains incomplete and recaptures from HEAD'}
  fi
  [ -n "$CR_STATE" ] && [ -n "$CR_TREE" ] || return 0
  completed=$(cat "$CR_STATE/reviewed.$CR_HARNESS" 2>/dev/null) || completed=''
  record=$(jq -nc --arg contract "capture-v5:L$AUTONOMY_LEVEL" --arg completed "$completed" --arg head "$CR_HEAD" --arg tree "$CR_TREE" \
    --arg base "$CR_DIFF_BASE" --arg hash "$DIFF_HASH" --arg verdict "$verdict" --arg reason "$reason" \
    --slurpfile known "$CR_KNOWN_FILE" --slurpfile excluded "$CR_EXCLUDED_FILE" --slurpfile opaque "$CR_OPAQUE_FILE" \
    --argjson incomplete "$CR_INCOMPLETE" --argjson reset "$CR_COVERAGE_RESET" --argjson hold "$CR_RESET_HOLD" --argjson lost "$CR_BASE_LOST" \
    --slurpfile files "$CR_REVIEW_FILES" --slurpfile path_hex "$CR_PATH_HEX_FILE" '{schema_version:3,contract:$contract,completed_record:$completed,head:$head,tree:$tree,
      coverage_reset:($reset == 1),reset_hold:($hold == 1),coverage_base_lost:($lost == 1),
      diff_base:$base,diff_hash:$hash,verdict:$verdict,reason:$reason,incomplete:($incomplete == 1),
      coverage_accepted:($verdict == "text-reviewed"),reviewed_files:$files[0],reviewed_path_hex:$path_hex[0],known_excluded:$known[0],excluded:$excluded[0],opaque:$opaque[0]}') || return 1
  tmp=$(mktemp "$CR_STATE/.capture.XXXXXX") || return 1
  if ! ( umask 077; printf '%s\n' "$record" > "$tmp" && mv -f "$tmp" "$CR_STATE/capture.$CR_HARNESS.json" ); then
    rm -f -- "$tmp"; return 1
  fi
  if [ "$verdict" = text-reviewed ]; then
    tmp=$(mktemp "$CR_STATE/.covered.XXXXXX") || return 1
    if ! ( umask 077; printf '%s\n' "$record" > "$tmp" && mv -f "$tmp" "$CR_STATE/covered.$CR_HARNESS.json" ); then
      rm -f -- "$tmp"; return 1
    fi
  fi
}
CR_HEAD=$(git rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) || CR_HEAD=unborn
CR_TREE=$(_cr_tree) || CR_TREE=""
CR_CAPTURE_AFTER=$(_cr_capture_metadata) || CR_CAPTURE_AFTER='{}'
if [ "$(printf '%s' "$CR_CAPTURE_AFTER" | jq -r '.notice_key')" != "$(printf '%s' "$CR_CAPTURE_META" | jq -r '.notice_key')" ]; then
  _cr_capture_unmet '{"reason":"untracked inputs changed during capture","excluded":[],"notice_key":"capture-changed"}'
  exit 0
fi
if CR_STATE=$(_se_turn_state_dir "$PROJECT_DIR"); then
  CR_STATE="${CR_STATE%/turn-baseline/*}/code-review/${CR_STATE##*/}"
  ( umask 077 && mkdir -p "$CR_STATE" ) 2>/dev/null || CR_STATE=""
else
  CR_STATE=""
fi
CR_OID='^[0-9a-f]{40}([0-9a-f]{24})?$'
CR_COVERAGE_RESET=0 CR_RESET_HOLD=0 CR_RECAPTURE=0 CR_BASE_LOST=0 CR_AGGREGATE_HEAD='' CR_AGGREGATE_TREE=''
CR_LOST_NOTICE=0 CR_LOST_KEY='' CR_LOST_FILE='' CR_CONTEXT_REFRESH=0
if [ -n "$CR_STATE" ] && [ -n "$CR_TREE" ]; then
  CR_AGGREGATE_HEAD=$(jq -r 'select(.reason == "opaque debt exceeds 256 paths") | .opaque_cap_head // empty' "$CR_STATE/unmet.capture.$CR_HARNESS" 2>/dev/null) || CR_AGGREGATE_HEAD=''
  CR_AGGREGATE_TREE=$(jq -r 'select(.reason == "opaque debt exceeds 256 paths") | .opaque_cap_tree // (.notice_key | split(":")[0]) // empty' "$CR_STATE/unmet.capture.$CR_HARNESS" 2>/dev/null) || CR_AGGREGATE_TREE=''
  [[ "$CR_AGGREGATE_TREE" =~ $CR_OID ]] || CR_AGGREGATE_TREE=''
  # A changed completion record invalidates dependent coverage, even when a
  # separate capture still names readable objects. Never hide a corrupt base
  # behind an older completed record: present-but-invalid coverage means HEAD.
  CR_COMPLETED_RECORD=$(cat "$CR_STATE/reviewed.$CR_HARNESS" 2>/dev/null) || CR_COMPLETED_RECORD=''
  CR_COVERED=$(cat "$CR_STATE/covered.$CR_HARNESS.json" 2>/dev/null) || CR_COVERED='{}'
  CR_COVERED_VALID=0 CR_COVERED_PRESENT=0
  if [ -e "$CR_STATE/covered.$CR_HARNESS.json" ] || [ -L "$CR_STATE/covered.$CR_HARNESS.json" ]; then CR_COVERED_PRESENT=1; fi
  CR_COVERED_CHECK=0
  _cr_valid_capture "$CR_COVERED" || CR_COVERED_CHECK=$?
  if [ "$(printf '%s' "$CR_COVERED" | jq -r '.verdict // empty' 2>/dev/null)" = text-reviewed ]; then
    if [ "$CR_COVERED_CHECK" -eq 0 ]; then CR_COVERED_VALID=1
    elif [ "$CR_COVERED_CHECK" -eq 2 ]; then CR_COVERAGE_RESET=1 CR_RESET_HOLD=1 CR_BASE_LOST=1; fi
  fi
  CR_SAVED=$(cat "$CR_STATE/capture.$CR_HARNESS.json" 2>/dev/null) || CR_SAVED='{}'
  if [ "$CR_COVERED_CHECK" -eq 1 ] && _cr_valid_coverage "$CR_COVERED" \
     && [ "$(printf '%s' "$CR_COVERED" | jq -r '.verdict')" = text-reviewed ] \
     && [ "$(printf '%s' "$CR_COVERED" | jq -r '.contract')" != "capture-v5:L$AUTONOMY_LEVEL" ] \
     && _cr_reference_matches "$CR_COVERED" && _cr_valid_text_base "$CR_COVERED"; then
    CR_CONTEXT_REFRESH=1
    printf '%s\n' "$CR_COVERED" > "$CR_PENDING_FILE"
  fi
  if _cr_valid_coverage "$CR_COVERED" && [ "$(printf '%s' "$CR_COVERED" | jq -r '.verdict')" = text-reviewed ]; then
    printf '%s\n' "$CR_COVERED" > "$CR_COVERED_FILE"
    # A previous reset hold requires one fresh capture, not another hold.
    if [ "$(printf '%s' "$CR_COVERED" | jq -r '.reset_hold // false')" = true ]; then CR_RECAPTURE=1; fi
  elif [ "$CR_COVERED_PRESENT" -eq 1 ] || [ -e "$CR_STATE/capture.$CR_HARNESS.json" ] || [ -n "$CR_COMPLETED_RECORD" ]; then
    # A first critical capture never created text coverage: its absent
    # covered record is not a reset, and its exact block must still replay.
    if [ "$CR_COVERED_PRESENT" -eq 1 ]; then
      CR_COVERAGE_RESET=1 CR_RESET_HOLD=1
      if _cr_valid_debt "$CR_COVERED" && ! _cr_readable_tree "$CR_COVERED"; then CR_BASE_LOST=1; fi
    elif [ "$(printf '%s' "$CR_SAVED" | jq -r '.verdict // empty' 2>/dev/null)" = text-reviewed ]; then CR_COVERAGE_RESET=1; fi
    if _cr_valid_debt "$CR_COVERED"; then
      printf '%s\n' "$CR_COVERED" > "$CR_COVERED_FILE"
    elif _cr_valid_debt "$CR_SAVED"; then
      printf '%s\n' "$CR_SAVED" > "$CR_COVERED_FILE"
    fi
  fi
  if [ "$CR_BASE_LOST" -eq 1 ]; then
    CR_LOST_FILE="$CR_STATE/lost-base-notice.$CR_HARNESS"
    CR_LOST_KEY=$(printf '%s' "$CR_COVERED" | jq -c --arg head "$CR_HEAD" '[.head, .tree, .contract, $head]')
    if _cr_valid_coverage "$CR_SAVED" && [ "$(printf '%s' "$CR_SAVED" | jq -r '.verdict')" = block ]; then
      printf '%s\n' "$CR_SAVED" > "$CR_PENDING_FILE"
    fi
    CR_LOST_OLD=$(cat "$CR_LOST_FILE" 2>/dev/null) || CR_LOST_OLD=''
    [ "$CR_LOST_OLD" = "$CR_LOST_KEY" ] || CR_LOST_NOTICE=1
  fi
  if _cr_valid_capture "$CR_SAVED" \
     && [ "$CR_RECAPTURE" -eq 0 ] \
     && { [ "$CR_COVERAGE_RESET" -eq 0 ] || [ "$CR_COVERED_VALID" -eq 1 ]; } \
     && { [ "$CR_COVERED_PRESENT" -eq 0 ] || [ "$CR_COVERED_VALID" -eq 1 ]; } \
     && { [ "$(printf '%s' "$CR_SAVED" | jq -r '.verdict')" = block ] \
          || { [ "$CR_COVERED_VALID" -eq 1 ] && [ "$(printf '%s' "$CR_COVERED" | jq -r '.tree')" = "$(printf '%s' "$CR_SAVED" | jq -r '.tree')" ]; }; } \
     && { [ "$(printf '%s' "$CR_SAVED" | jq -r '.opaque | length')" -eq 0 ] || [ "$(printf '%s' "$CR_SAVED" | jq -r '.head')" = "$CR_HEAD" ]; } \
     && [ "$(printf '%s' "$CR_SAVED" | jq -r '.tree')" = "$CR_TREE" ] \
     && [ "$(printf '%s' "$CR_SAVED" | jq -c '.known_excluded')" = "$CR_KNOWN_EXCLUDED" ]; then
    printf '%s' "$CR_SAVED" | jq -c '.excluded' > "$CR_EXCLUDED_FILE"
    CR_COVERAGE_RESET=$(printf '%s' "$CR_SAVED" | jq -r 'if .coverage_reset then 1 else 0 end')
    CR_RESET_HOLD=$(printf '%s' "$CR_SAVED" | jq -r 'if .reset_hold then 1 else 0 end')
    CR_BASE_LOST=$(printf '%s' "$CR_SAVED" | jq -r 'if .coverage_base_lost then 1 else 0 end')
    if [ "$(printf '%s' "$CR_SAVED" | jq -r '.verdict')" = block ]; then
      _cr_exclusion_notice "$CR_EXCLUDED_FILE"
      printf '%s' "$CR_SAVED" | jq -c '{decision:"block",reason:.reason}'
      exit 0
    fi
    if [ "$(printf '%s' "$CR_SAVED" | jq -r '.incomplete')" = true ]; then
      _cr_exclusion_notice "$CR_EXCLUDED_FILE" model
    else
      rm -f -- "${CR_STATE:?}/unmet.capture.$CR_HARNESS"
    fi
    exit 0
  fi
  if [ "$CR_COVERED_VALID" -eq 1 ] || [ "$CR_CONTEXT_REFRESH" -eq 1 ] \
     || { [ "$CR_COVERAGE_RESET" -eq 1 ] && [ "$CR_BASE_LOST" -eq 0 ] \
          && [ "$(printf '%s' "$CR_COVERED" | jq -r '.verdict // empty' 2>/dev/null)" = text-reviewed ] \
          && _cr_valid_debt "$CR_COVERED" && _cr_context_matches "$CR_COVERED" \
          && _cr_valid_text_base "$CR_COVERED"; }; then
    # A reset never erases an otherwise readable last text-covered tree.
    # In particular it cannot turn a pending aggregate into a HEAD-only diff.
    CR_DIFF_BASE=$(printf '%s' "$CR_COVERED" | jq -r '.tree')
  fi
  # Older records did not retain opaque debt. A contract miss starts at HEAD,
  # never at a legacy tree that could already contain an unreviewed blob.
fi

# --- Stream one immutable tree diff after the exact-state lookup ---
CR_DIFF_FILE="$CR_CAPTURE_DIR/diff"
CR_REVIEW_FILES="$CR_CAPTURE_DIR/diff.files"
if [ "$CR_HEAD" = unborn ]; then CR_DIFF_BASE=$(git hash-object -t tree /dev/null)
elif [ "$CR_DIFF_BASE" = HEAD ]; then CR_DIFF_BASE="$CR_HEAD"; fi
CR_CAPTURE_STATUS=0
printf '%s\n' '[]' > "$CR_CAPTURE_DIR/diff.cap-excluded"
"$CR_PYTHON" -I - "$CR_DIFF_BASE" "$CR_TREE" "$CR_DIFF_FILE" "$CR_HEAD" "$CR_KNOWN_FILE" "$CR_COVERED_FILE" "$CR_COVERAGE_RESET" "$CR_AGGREGATE_HEAD" "$CR_AGGREGATE_TREE" "$CR_PENDING_FILE" <<'CR_STREAM_PY' || CR_CAPTURE_STATUS=$?
import io
import json
import os
import pathlib
import subprocess
import sys

base, target, name, head, known_file, covered_file, coverage_reset, aggregate_head, aggregate_tree, pending_file = sys.argv[1:]
allow_retirement = coverage_reset == '0'
path = pathlib.Path(name)
limit = 200000

def capture(args, sink, from_tree=None):
    proc = subprocess.Popen(['git', 'diff', '--no-ext-diff', '--no-textconv', *args,
                             base if from_tree is None else from_tree, target, '--'], stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL)
    size = 0
    overflow = False
    try:
        while True:
            chunk = proc.stdout.read1(min(8192, limit + 1 - size))
            if not chunk:
                break
            sink.write(chunk)
            size += len(chunk)
            if size > limit:
                overflow = True
                break
    finally:
        proc.stdout.close()
        if overflow and proc.poll() is None:
            proc.terminate()
        code = proc.wait()
    if overflow:
        return 10
    return 0 if code == 0 else 11

if not target:
    path.with_suffix('.reason').write_text('immutable tree capture unavailable')
    sys.exit(11)
# Lost-history blocks retain their reviewed paths; context changes re-review
# the previous capture at the new level. Restore only those paths to their
# pre-review baseline in a private synthetic diff base. Other paths retain the
# selected covered/HEAD base, so switched upstream content is not attributed.
pending = json.loads(pathlib.Path(pending_file).read_text())
if pending.get('verdict') == 'block' or (pending.get('verdict') == 'text-reviewed' and pending.get('reviewed_files')):
    index = path.with_suffix('.pending-index')
    prefix = ['git', '-c', 'core.fsmonitor=false', '-c', 'core.splitIndex=false', '-c', 'core.sparseCheckout=false']
    def metadata(args):
        proc = subprocess.Popen(prefix + args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        data = proc.stdout.read(limit + 1)
        proc.stdout.close()
        if len(data) > limit and proc.poll() is None:
            proc.terminate()
        code = proc.wait()
        if code or len(data) > limit:
            raise ValueError('pending block metadata unavailable')
        return data
    try:
        for key in ('tree', 'diff_base'):
            value = pending[key]
            if not isinstance(value, str) or len(value) not in (40, 64) or any(c not in '0123456789abcdef' for c in value):
                raise ValueError('pending object identity unavailable')
        if 'reviewed_path_hex' in pending:
            blocked = {bytes.fromhex(raw) for raw in pending['reviewed_path_hex']}
        else:
            # Older schema3 records have display names only. Resolve every
            # matching raw name, never guess an escaped/non-UTF8 identity.
            names = set(pending['reviewed_files'])
            blocked = set()
            for row in metadata(['ls-tree', '-rz', '--full-tree', pending['tree']]).split(b'\0'):
                if row:
                    raw = row.split(b'\t', 1)[1]
                    shown = os.fsdecode(raw).encode('utf-8', 'backslashreplace').decode('utf-8')
                    if shown in names:
                        blocked.add(raw)
            if len(blocked) < len(names):
                raise ValueError('pending file identity unavailable')
        if not blocked or sum(len(raw) + 1 for raw in blocked) > limit:
            raise ValueError('pending file set unavailable or over budget')
        chunks, batch, size = [], [], 0
        for raw in sorted(blocked):
            if not raw or len(raw) > 32768:
                raise ValueError('pending path exceeds metadata bound')
            if batch and size + len(raw) + 1 > 32768:
                chunks.append(batch); batch, size = [], 0
            batch.append(raw); size += len(raw) + 1
        if batch:
            chunks.append(batch)
        def entries(tree):
            result, total = {}, 0
            for batch in chunks:
                data = metadata(['--literal-pathspecs', 'ls-tree', '-rz', '--full-tree', tree, '--', *batch])
                total += len(data)
                if total > limit:
                    raise ValueError('pending metadata exceeds capture budget')
                for row in data.split(b'\0'):
                    if row:
                        info, raw = row.split(b'\t', 1)
                        if raw not in blocked:
                            raise ValueError('pending file changed into a directory')
                        mode, _, oid = info.split()
                        result[raw] = mode + b' ' + oid + b'\t' + raw + b'\0'
            return result
        before = entries(pending['diff_base'])
        entries(base)  # Refuse unsupported directory/file transitions.
        env = dict(os.environ, GIT_INDEX_FILE=str(index))
        subprocess.run(prefix + ['read-tree', base], env=env, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        rows = b''.join(b'0 ' + b'0' * len(target) + b'\t' + raw + b'\0' for raw in sorted(blocked))
        rows += b''.join(before[raw] for raw in sorted(before))
        if len(rows) > 2 * limit:
            raise ValueError('pending index metadata exceeds budget')
        subprocess.run(prefix + ['update-index', '-z', '--index-info'], input=rows, env=env, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        base = subprocess.run(prefix + ['write-tree'], env=env, check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout.decode('ascii').strip()
        if len(base) not in (40, 64) or any(c not in '0123456789abcdef' for c in base):
            raise ValueError('pending diff base unavailable')
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError):
        path.with_suffix('.reason').write_text('pending blocked-file coverage unavailable')
        sys.exit(11)
    finally:
        index.unlink(missing_ok=True)
        pathlib.Path(str(index) + '.lock').unlink(missing_ok=True)
path.with_suffix('.effective-base').write_text(base)
known = json.loads(pathlib.Path(known_file).read_text())
prior = json.loads(pathlib.Path(covered_file).read_text()).get('opaque', [])
# Acknowledge only the opaque set announced by this exact notice tree.
# Never advance the text base or discard the earlier per-entry ledger.
aggregate_ack = False
aggregate_changes = set()
if aggregate_head and aggregate_tree and head != aggregate_head and head != 'unborn' and allow_retirement:
    probe = io.BytesIO()
    probe_code = capture(['--no-renames', '--numstat', '-z'], probe, head)
    probe_rows = [row for row in probe.getvalue().split(b'\0') if row]
    dirty = {row.split(b'\t', 2)[2] for row in probe_rows}
    prior_paths = {bytes.fromhex(entry['path_hex']) for entry in prior}
    if not probe_code and not any(row.startswith(b'-\t-\t') for row in probe_rows) and not dirty.intersection(prior_paths):
        announced = io.BytesIO()
        announced_code = capture(['--no-renames', '--numstat', '-z'], announced, aggregate_tree)
        announced_rows = [row for row in announced.getvalue().split(b'\0') if row]
        aggregate_changes = {row.split(b'\t', 2)[2] for row in announced_rows if row.startswith(b'-\t-\t')}
        aggregate_ack = not announced_code and not aggregate_changes
# Known opaque untracked files were excluded before any content read. Git
# identifies other binary changes in the bounded immutable-tree metadata.
# Render the text remainder, but never authorize completed coverage for it.
stat = io.BytesIO()
code = capture(['--no-renames', '--numstat', '-z'], stat)
if code:
    path.with_suffix('.reason').write_text('change-set metadata exceeds capture budget' if code == 10 else 'change-set inspection failed')
    sys.exit(code)
rows = [row for row in stat.getvalue().split(b'\0') if row]
binary_paths = {row.split(b'\t', 2)[2] for row in rows if row.startswith(b'-\t-\t')}
if aggregate_ack:
    binary_paths = set()  # Only the announced aggregate; prior still reconciles below.

def display(raw):
    return os.fsdecode(raw).encode('utf-8', 'backslashreplace').decode('utf-8')

def over_cap():
    path.with_suffix('.reason').write_text('opaque debt exceeds 256 paths')
    shown = sorted(aggregate_changes or binary_paths)[:8]
    path.with_suffix('.cap-excluded').write_text(json.dumps([display(raw)[:256] for raw in shown]))
    sys.exit(12)

# The ledger shares the 256-file capture budget. Refuse before constructing
# per-entry Git queries, rendering text or advancing coverage; never trim debt.
if len(prior) > 256 or len(binary_paths) > 256:
    over_cap()
paths = binary_paths | {bytes.fromhex(entry['path_hex']) for entry in prior}
if len(paths) > 256:
    over_cap()

def tree_entries(tree):
    # Metadata only. Individual literal paths and 32KiB batches avoid both
    # MAX_ARG_STRLEN and aggregate argv limits; no blob content is opened.
    result = {}
    if tree == 'unborn' or not paths:
        return result
    chunks, batch, size = [], [], 0
    for raw in sorted(paths):
        if len(raw) > 32768:
            raise ValueError('opaque path metadata exceeds literal-argument bound')
        if batch and size + len(raw) + 1 > 32768:
            chunks.append(batch)
            batch, size = [], 0
        batch.append(raw)
        size += len(raw) + 1
    if batch:
        chunks.append(batch)
    for batch in chunks:
        out = subprocess.run(['git', '--literal-pathspecs', 'ls-tree', '-rz', '--full-tree', tree, '--', *batch],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout
        for row in out.split(b'\0'):
            if not row:
                continue
            metadata, raw = row.split(b'\t', 1)
            if raw in paths:
                result[raw] = metadata.split()[2].decode('ascii')
    return result

current, at_head, baseline = tree_entries(target), tree_entries(head), tree_entries(base)
opaque, retired = {}, set()
for old in prior:
    raw = bytes.fromhex(old['path_hex'])
    blob = current.get(raw)
    if allow_retirement and (blob is None or (blob == old['base_blob'] and at_head.get(raw) == blob)):
        retired.add(raw)                 # deletion or exact pre-exclusion reversion
        continue
    if allow_retirement and blob == old['blob'] and head != old['announced_head'] and at_head.get(raw) == blob:
        retired.add(raw)                 # later commit contains the announced blob
        continue
    entry = dict(old)
    if blob is not None and blob != old['blob']:
        entry.update(blob=blob, announced_head=head)  # changed bytes must be announced anew
    opaque[raw] = entry
for raw in sorted(binary_paths):
    if raw in retired or raw in opaque or raw not in current:
        continue
    if current[raw] == baseline.get(raw):
        continue
    opaque[raw] = dict(path=display(raw), path_hex=raw.hex(), blob=current[raw],
                       base_blob=baseline.get(raw), announced_head=head)
ledger = [opaque[raw] for raw in sorted(opaque)]
path.with_suffix('.opaque').write_text(json.dumps(ledger))
path.with_suffix('.excluded').write_text(json.dumps(sorted(set(known + [entry['path'] for entry in ledger]))))
reviewable = [display(row.split(b'\t', 2)[2]) for row in rows if not row.startswith(b'-\t-\t')]
path.with_suffix('.files').write_text(json.dumps(reviewable))
path.with_suffix('.path-hex').write_text(json.dumps(sorted({row.split(b'\t', 2)[2].hex() for row in rows if not row.startswith(b'-\t-\t')})))
with path.open('wb') as sink:
    code = capture([], sink)
if code:
    path.with_suffix('.reason').write_text('complete diff exceeds 200000-byte cap' if code == 10 else 'diff capture failed')
    sys.exit(code)
# Preserve the previous command-substitution newline normalization without
# retaining the change set in shell memory.
with path.open('r+b') as sink:
    end = sink.seek(0, 2)
    while end:
        sink.seek(end - 1)
        if sink.read(1) != b'\n':
            break
        end -= 1
    sink.truncate(end)
CR_STREAM_PY
if [ "$CR_CAPTURE_STATUS" -ne 0 ]; then
  CR_CAPTURE_REASON=$(cat "$CR_CAPTURE_DIR/diff.reason" 2>/dev/null) || CR_CAPTURE_REASON='bounded capture unavailable'
  CR_REJECT=$(jq -nc --arg reason "$CR_CAPTURE_REASON" --arg key "$CR_TREE:$CR_CAPTURE_REASON" --arg head "$CR_HEAD" --arg tree "$CR_TREE" \
    --slurpfile excluded "$CR_CAPTURE_DIR/diff.cap-excluded" \
    '{reason:$reason,excluded:$excluded[0],notice_key:$key} + (if $reason == "opaque debt exceeds 256 paths" then {opaque_cap_head:$head,opaque_cap_tree:$tree} else {} end)')
  _cr_capture_unmet "$CR_REJECT"
  exit 0
fi
CR_CAPTURE_BASE=$(cat "$CR_CAPTURE_DIR/diff.effective-base" 2>/dev/null) || CR_CAPTURE_BASE=''
if [[ ! "$CR_CAPTURE_BASE" =~ $CR_OID ]]; then
  _cr_capture_unmet '{"reason":"pending diff base identity unavailable","excluded":[],"notice_key":"pending-base-unavailable"}'
  exit 0
fi
CR_DIFF_BASE="$CR_CAPTURE_BASE"
if ! jq -e 'type == "array" and all(.[]; type == "string")' "$CR_EXCLUDED_FILE" >/dev/null 2>&1; then
  _cr_capture_unmet '{"reason":"binary exclusion metadata unavailable","excluded":[],"notice_key":"classification-unavailable"}'
  exit 0
fi
CR_EXCLUDED=$(cat "$CR_EXCLUDED_FILE")
CR_INCOMPLETE=0
[ "$CR_EXCLUDED" = '[]' ] && [ "$CR_COVERAGE_RESET" -eq 0 ] || CR_INCOMPLETE=1
if ! jq -e 'type == "array" and all(.[]; type == "string")' "$CR_REVIEW_FILES" >/dev/null 2>&1; then
  _cr_capture_unmet '{"reason":"reviewable file metadata unavailable","excluded":[],"notice_key":"files-unavailable"}'
  exit 0
fi
if [ ! -s "$CR_DIFF_FILE" ] || [ "$(jq -r 'length' "$CR_REVIEW_FILES")" -eq 0 ]; then
  # No reviewable text, including a binary-only delta: announce, never model.
  [ "$CR_INCOMPLETE" -eq 0 ] || _cr_exclusion_notice "$CR_EXCLUDED_FILE" model
  DIFF_HASH=$(git hash-object "$CR_DIFF_FILE") || exit 0
  if _cr_record_capture text-reviewed; then
    if [ "$CR_INCOMPLETE" -eq 0 ] && [ -n "$CR_STATE" ]; then rm -f -- "$CR_STATE/unmet.capture.$CR_HARNESS"; fi
  else printf '%s\n' 'code-review-subagent: capture cache unavailable' >&2; fi
  exit 0
fi
CR_DISPLAY_EXCLUDED=$(jq -c 'map(.[0:256]) | .[:8]' "$CR_EXCLUDED_FILE")
FULL_BYTES=$(wc -c < "$CR_DIFF_FILE" | tr -d ' ')
DIFF_HASH=$(git hash-object "$CR_DIFF_FILE") || exit 0
MARKER="$REPO_ROOT/.codex/.review-done-${DIFF_HASH}"
# The exact tree lookup is authoritative; a marker alone cannot cover a delta
# relative to a different reviewed base. If state storage is unavailable, only
# this full-capture Git hash can retain the legacy marker fallback.
if [ "$CR_INCOMPLETE" -eq 0 ] && [ -z "$CR_STATE" ] && [ -f "$MARKER" ]; then exit 0; fi
if [ -n "$CR_STATE" ]; then
  CR_FAILS=$(cat "$CR_STATE/fail.$DIFF_HASH" 2>/dev/null) || CR_FAILS=0
  case "$CR_FAILS" in ''|*[!0-9]*) CR_FAILS=0 ;; esac
  if [ "$CR_FAILS" -ge "$CR_MAX_ATTEMPTS" ]; then
    _cr_warn "code-review-subagent: review unavailable: $CR_FAILS attempts failed on this exact diff, so it is UNREVIEWED. It will not be retried until the diff changes; fix the reviewer or change the diff."
    exit 0
  fi
fi

# --- Build the reviewer envelope ---
# The guarded resolved context level above is shared with exact lookup.
if [ "$AUTONOMY_LEVEL" -ge 4 ] && [ -f "$DECISIONS_LOG_PATH" ]; then
  DECISIONS_PAYLOAD=$(head -c 50000 "$DECISIONS_LOG_PATH" 2>/dev/null)
else
  DECISIONS_PAYLOAD=""
fi
jq -nc --rawfile diff "$CR_DIFF_FILE" \
  --arg level "$AUTONOMY_LEVEL" --arg decisions "$DECISIONS_PAYLOAD" --slurpfile excluded "$CR_EXCLUDED_FILE" \
  '{diff: $diff, autonomy_level: ($level | tonumber), decisions_log: $decisions, excluded_paths: $excluded[0]}' \
  > "$CR_CAPTURE_DIR/request.json" || _cr_failed 'code-review-subagent: review envelope unavailable'

# --- Invoke the reviewer ladder (sibling lib) ---
# The 3-rung ladder (operator override → claude -p → deterministic regex) owns
# rung selection and ALWAYS emits one findings line, fail-open on every infra
# failure. Do NOT pre-export TRELLIS_REVIEW_IN_PROGRESS here: the ladder gates
# rung 2 on that sentinel, so pre-setting it would force every default-path call
# straight to the rung-3 regex and the built-in `claude -p` reviewer would never
# run. The ladder exports the sentinel itself before spawning ANY child, so the
# child's own top-of-hook guard still trips — recursion is prevented without
# disabling rung 2. No outer `timeout` — the ladder bounds rung 2 internally via
# its perl-alarm shim.
# NB: no `2>/dev/null` here. lib/code-reviewer.sh deliberately leaves the rung-2
# `claude` stderr unsuppressed so a failing reviewer is visible; silencing fd 2
# on the caller side would hide the degradation. stdout (the one findings line)
# is captured and validated before it can authorize an idempotency marker.
if [ ! -f "$REVIEWER_LIB" ]; then
  printf '%s\n' 'code-review-subagent: review degraded: reviewer library unavailable; this diff will be retried on the next Stop' >&2
  exit 0
fi

REVIEWER_STATUS=0
if FINDINGS=$(bash "$REVIEWER_LIB" < "$CR_CAPTURE_DIR/request.json"); then
  :
else
  REVIEWER_STATUS=$?
fi
if [ "$REVIEWER_STATUS" -ne 0 ]; then
  _cr_failed 'code-review-subagent: review degraded: reviewer command failed; this diff will be retried on the next Stop'
fi

# Parse exactly one JSON object. `fromjson?` turns malformed reviewer text into
# an empty result without leaking parser internals; the caller emits one bounded,
# stable degradation below. A missing status is completed only for a rung-1
# operator override (legacy); otherwise it is incomplete.
if VALIDATED_FINDINGS=$(printf '%s' "$FINDINGS" | jq -Rces '
    fromjson?
    | select(type == "object")
    | select(.findings | type == "array")
    | ( .findings | map(select(type == "object"
        and (.severity | type == "string")
        and ( (.severity | ascii_downcase | gsub("^\\s+|\\s+$"; "") | if . == "blocker" then "critical" else . end) == "critical" )
        and ( (.file | type) != "string" or (.msg | type) != "string" ))) | map({severity: "critical", file: (if (.file | type) == "string" then .file else "?" end), line: (.line // "?"), msg: (if (.msg | type) == "string" then .msg else "(malformed finding)" end)}) ) as $dropped_crit
    | (.findings | length) as $orig_len
    | .findings |= map(select(type == "object"
        and (.severity | type == "string")
        and (.file | type == "string")
        and (.msg | type == "string")))
    | (.findings | length) as $valid_len
    | .findings += $dropped_crit
    | . + {_dropped: ($orig_len - $valid_len), _dropped_critical: ($dropped_crit | length)}
    | select((has("status") | not) or .status == "completed" or .status == "degraded")
    | .findings |= map(.severity |= (ascii_downcase | gsub("^\\s+|\\s+$"; "") | if . == "blocker" then "critical" else . end))
  '); then
  :
else
  # A parseable critical blocks whatever the envelope's status or shape: an
  # unrecognised status, findings given as an object, or a later JSON value.
  CRITICAL=$(printf '%s' "$FINDINGS" | jq -r '
      select(type == "object") | .findings
      | if type == "array" then .[]
        elif type == "object" then (if has("severity") then . else .[] end)
        else empty end
      | select(type == "object" and (.severity | type) == "string"
          and (.severity | ascii_downcase | gsub("^\\s+|\\s+$"; "") | . == "critical" or . == "blocker"))
      | "- \(if (.file | type) == "string" then .file else "?" end):\(.line // "?") \(if (.msg | type) == "string" then .msg else "(malformed finding)" end)"
    ' 2>/dev/null | head -10)
  if [ -n "$CRITICAL" ]; then
    jq -nc --arg reason "Code review flagged critical issues — resolve or explicitly defer:
${CRITICAL}" '{decision: "block", reason: $reason}'
    exit 0
  fi
  _cr_failed 'code-review-subagent: review degraded: reviewer returned a malformed findings envelope; this diff will be retried on the next Stop'
fi
FINDINGS="$VALIDATED_FINDINGS"
_DROPPED=$(printf '%s' "$FINDINGS" | jq -r '._dropped // 0' 2>/dev/null) || _DROPPED=0
case "$_DROPPED" in ''|*[!0-9]*) _DROPPED=0 ;; esac
# A missing status counts as completed only for a rung-1 operator override
# (legacy override envelopes may omit it). The built-in ladder always states its
# status, so anything else without one is not a completed review.
if [ -n "${CODE_REVIEWER_CMD:-}" ]; then STATUS_DEFAULT=completed; else STATUS_DEFAULT=incomplete; fi
COMPLETION_STATUS=$(printf '%s' "$FINDINGS" | jq -r --arg d "$STATUS_DEFAULT" '.status // $d')

CRITICAL=$(printf '%s' "$FINDINGS" | jq -r '.findings[]? | select(.severity == "critical") | "- \(.file):\(.line // "?") \(.msg)"' | head -10)
if [ -n "$CRITICAL" ]; then
  REASON="Code review flagged critical issues — resolve or explicitly defer:
${CRITICAL}"
  if [ "$CR_INCOMPLETE" -eq 1 ]; then
    _cr_exclusion_notice "$CR_EXCLUDED_FILE"
    REASON="$REASON
Coverage remains UNREVIEWED; excluded (up to 8 paths): $CR_DISPLAY_EXCLUDED$(_cr_reset_note)"; fi
  if [ "$CR_INCOMPLETE" -eq 1 ] && [ "$COMPLETION_STATUS" = completed ]; then
    _cr_record_capture block "$REASON" || printf '%s\n' 'code-review-subagent: capture cache unavailable' >&2
  fi
  jq -nc --arg reason "$REASON" '{decision: "block", reason: $reason}'
  # Block path: do NOT touch the marker — a blocked turn must re-review the
  # corrected diff (which will hash differently anyway). Codex consumes the
  # stdout block decision on exit 0; exit 2 would require a stderr prompt.
  exit 0
fi

# Never mark an unrecognised severity as reviewed. A known critical in the
# same envelope was handled first, before rejecting the malformed remainder.
if ! printf '%s' "$FINDINGS" | jq -e 'all(.findings[]; .severity == "critical" or .severity == "important" or .severity == "minor")' >/dev/null; then
  _cr_failed 'code-review-subagent: review degraded: reviewer returned a malformed severity; this diff will be retried on the next Stop'
fi

# Advisory findings → Stop-safe systemMessage (shown to the model, not blocking).
ADVISORY=$(printf '%s' "$FINDINGS" | jq -r '.findings[]? | "- [\(.severity)] \(.file):\(.line // "?") \(.msg)"' | head -30)
if [ "${_DROPPED:-0}" -gt 0 ] 2>/dev/null; then
  _DROPPED_NOTICE="Note: ${_DROPPED} malformed finding(s) were dropped; only valid findings are shown."
  if [ -n "$ADVISORY" ]; then
    ADVISORY="$ADVISORY
$_DROPPED_NOTICE"
  else
    ADVISORY="$_DROPPED_NOTICE"
  fi
fi
if [ "$CR_INCOMPLETE" -eq 1 ]; then
  # One output object, including when findings and exclusions both exist.
  ADVISORY="$ADVISORY
- [unreviewed] Excluded (up to 8 paths): $CR_DISPLAY_EXCLUDED; coverage remains UNREVIEWED, no completed marker or tree written.$(_cr_reset_note)"
fi
if [ -n "$ADVISORY" ]; then
  _se_emit_system_message "<review>
${ADVISORY}
</review>"
fi
if [ "${_DROPPED:-0}" -gt 0 ] 2>/dev/null; then
  _cr_failed "code-review-subagent: review degraded: ${_DROPPED} malformed finding(s) dropped; no marker written; this diff will be retried on the next Stop"
fi

# Only a validated completed review authorizes the idempotency marker. A
# degraded deterministic fallback remains advisory and is retried next Stop.
# SAFETY: a truncated (prefix-only) review must never mint a completed marker —
# force the status away from completed so the marker below is never written.
if [ "$CR_TRUNCATED" -eq 1 ]; then
  _cr_failed "code-review-subagent: review incomplete: diff (${FULL_BYTES} bytes) exceeds the 200000-byte reviewer payload cap; only the prefix was reviewed, no marker written — will re-review on the next Stop"
fi
if [ "$COMPLETION_STATUS" != "completed" ]; then
  _cr_failed "code-review-subagent: cross-family review unmet (status=${COMPLETION_STATUS}); no marker written — will re-review on the next Stop"
fi
if [ "$CR_INCOMPLETE" -eq 1 ]; then
  _cr_record_capture text-reviewed || printf '%s\n' 'code-review-subagent: capture cache unavailable' >&2
  printf 'code-review-subagent: review incomplete: eligible text reviewed, excluded (up to 8 paths): %s; coverage remains UNREVIEWED, no completed marker or tree written\n' "$CR_DISPLAY_EXCLUDED" >&2
  exit 0
fi
if ! mkdir -p "$REPO_ROOT/.codex"; then
  exit 0
fi
# Save coverage before advancing completion. It remains bound to the previous
# reference if publication fails; a later committed edit cannot fall through
# a mismatched reference to HEAD and disappear from the next reviewer payload.
if ! _cr_record_capture text-reviewed; then
  _cr_warn 'code-review-subagent: capture cache unavailable; completion record unchanged; aggregate notice retained, no completed marker written'
  exit 0
fi
if [ -n "$CR_STATE" ]; then
  if ! CR_TMP=$(mktemp "$CR_STATE/.reviewed.XXXXXX" 2>/dev/null); then
    _cr_warn 'code-review-subagent: coverage saved but completion record unavailable; aggregate notice retained, no completed marker written'
    exit 0
  fi
  if ! { printf '%s %s %s\n' "$CR_HEAD" "$CR_TREE" "capture-v2:L$AUTONOMY_LEVEL" > "$CR_TMP" && mv -f "$CR_TMP" "$CR_STATE/reviewed.$CR_HARNESS"; }; then
    rm -f "$CR_TMP"
    _cr_warn 'code-review-subagent: coverage saved but completion record unavailable; aggregate notice retained, no completed marker written'
    exit 0
  fi
  rm -f "${CR_STATE:?}/fail.$DIFF_HASH"
  find "$CR_STATE" -maxdepth 1 -type f -name 'fail.*' -mtime +7 -exec rm -f {} + 2>/dev/null
fi
if ! : > "$MARKER"; then exit 0; fi
[ -z "$CR_STATE" ] || rm -f -- "$CR_STATE/unmet.capture.$CR_HARNESS"
find "$REPO_ROOT/.codex" -maxdepth 1 -type f -name '.review-done-*' -mtime +7 -exec rm -f {} + 2>/dev/null

exit 0
