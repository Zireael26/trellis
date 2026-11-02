#!/usr/bin/env bash
# stop-verify.sh — Stop. TodoWrite → typecheck → lint → test, auto-detected.
# Source: Trellis / core-rules / hooks.md
#
# Contract:
#   - TRELLIS_REVIEW_IN_PROGRESS=1: exit 0 immediately (nested-review guard).
#   - stop_hook_active guard: if set, exit 0 immediately (infinite-loop guard).
#   - Pure chat / no edits: exit 0 (skip).
#   - Receipt trigger (C01): the DoD receipt is owed only when this turn
#     mutated the tree, judged against the turn-entry baseline turn-baseline.sh
#     records at UserPromptSubmit. Unchanged → no receipt demand; changed, or a
#     missing/unreadable/uncomputable baseline → receipt required. A turn that
#     committed and left the tree clean still owes one, and in a project that
#     registers turn-baseline.sh so does a clean turn with no usable baseline.
#     Todos and checks are not narrowed.
#   - Runs checks concurrently (cargo's members in order) and blocks on the
#     first failure in plan order: emit
#     {"decision":"block","reason":"<step>: <sliced output>"} and exit 2.
#   - Reuse (spec 072 U8): a pass receipt whose key matches the tree
#     fingerprint, planned commands, tools, environment and policy skips the
#     run and says so; any doubt runs the checks (lib/deps.sh § Stop check
#     reuse). Only passes are recorded, so a failure is never reused.
#   - stop_checks.fast, from TRELLIS_HOME config.json only (never the
#     checkout), replaces the test step when that file passes its ownership
#     and mode checks. A fast run is never reused.
#   - Error slicing: typecheck/lint → first 30 lines; tests → last 30 lines.
#   - Budget: 90s soft cap.
#
# Subtree scoping: when every changed file in this turn sits under a single
# subdirectory that carries its own manifest (package.json, go.mod,
# pyproject.toml, or Cargo.toml), checks run scoped to that subtree instead
# of repo root. Cuts wall time + noise on monorepos. Escape hatch:
# PROCESS_GATE_FORCE_ROOT=1 → always run at repo root (legacy behaviour).
#
# Dependencies: jq (required). Toolchains are detected; absence → skip that step.
#
# Todo state: read from $CLAUDE_PROJECT_DIR/.claude/todos.json. A missing file
# means no persisted todos; a present but malformed file blocks because its open
# tasks cannot be determined. Override the current persistence location via
# project `.claude/hooks/config.sh` exporting TODOS_FILE.
#
# Base: github.com/iamfakeguru/claude-md (MIT). Extensions vs upstream:
#   - Step 1: TodoWrite state check (receipts-required enforcement).
#   - Go support (go vet / go test / golangci-lint).
#   - Test output uses last-30 lines; lint/typecheck use first-30.
#   - Subtree scoping (auto-detects nested manifests; PROCESS_GATE_FORCE_ROOT escape).

set -u

# Nested reviewers inherit the parent's dirty worktree. Do not make their Stop
# event run the parent turn's verifier (or recursively gate reviewer teardown).
if [ "${TRELLIS_REVIEW_IN_PROGRESS:-0}" = "1" ]; then
  exit 0
fi

INPUT=$(cat)

# Source shared lib (sibling to this script) + enforce jq dependency.
__se_lib="$(dirname "${BASH_SOURCE[0]}")/lib/deps.sh"
[ -f "$__se_lib" ] || { echo "stop-verify: missing sibling lib at $__se_lib — re-run sync-hooks" >&2; exit 1; }
# shellcheck source=lib/deps.sh disable=SC1090
. "$__se_lib"
_se_require_jq "stop-verify"

# Optional: package-manager resolver (config-driven, lockfile fallback). Absent
# copy → test step falls back to npm (legacy behaviour).
__se_pm_lib="$(dirname "${BASH_SOURCE[0]}")/lib/pm.sh"
# shellcheck source=lib/pm.sh disable=SC1090
[ -f "$__se_pm_lib" ] && . "$__se_pm_lib"

# Optional: durable executed-verification receipts (spec 045 T6). This records
# what actually ran; it NEVER skips, shortens, or reuses a check (the Stop pass
# receipts below are a separate store and record no execution). If the shared
# library is absent the fallback below runs the SAME command with the SAME
# capture and the SAME exit status and says so on stderr — visible degradation,
# never a bypass and never a false green.
__se_vr_lib="$(dirname "${BASH_SOURCE[0]}")/lib/verification-receipt.sh"
if [ -f "$__se_vr_lib" ]; then
  # shellcheck source=lib/verification-receipt.sh disable=SC1090,SC1091
  . "$__se_vr_lib"
  _VR_HARNESS=claude
else
  _VR_OUTPUT=""
  _VR_STATUS=0
  __se_vr_warned=0
  _vr_run() {
    local form="$2"
    shift 2
    if [ "$form" = "shell" ]; then
      _VR_OUTPUT="$(eval "$1" 2>&1)"
    else
      _VR_OUTPUT="$("$@" 2>&1)"
    fi
    _VR_STATUS=$?
    if [ "$__se_vr_warned" = "0" ]; then
      __se_vr_warned=1
      printf 'stop-verify: missing sibling lib at %s — checks ran unchanged, no durable evidence recorded (re-run sync-hooks)\n' "$__se_vr_lib" >&2
    fi
    return "$_VR_STATUS"
  }
fi

# --- Guard 1: stop_hook_active ---
STOP_ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$STOP_ACTIVE" = "true" ]; then
  exit 0
fi

PROJECT_DIR="${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
cd "$PROJECT_DIR" 2>/dev/null || exit 0

# Fail-counter state: absolute under the canonical project root (NOT a subtree —
# emit_block fires both before and after the subtree cd). A clean pass removes it.
STATE_FILE="${PROJECT_DIR}/.claude/.fail-counter"

# --- Turn-entry baseline (C01). Consumed here, before anything else runs, and
# replaced on exit by a carry of the end state (see below).
# TURN_STATE: same | changed | unknown. Only "same" waives the receipt (inside
# _se_receipt_gate). In an armed project (turn-baseline.sh registered) unknown
# counts as changed on every path, including a clean tree after a commit.
# TURN_RANGE_FILES carries the paths a committing turn changed, or a non-doc
# sentinel when that range is unknown.
TURN_STATE=unknown
TURN_RANGE_FILES=""
__se_blocked=0
__se_harness=claude
__se_sdir=""
__se_now=""
if command -v git >/dev/null 2>&1; then
  __se_sid=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || __se_sid=""
  __se_key=""
  [ -z "$__se_sid" ] || __se_key=$(_se_state_key "" "$__se_sid") || __se_key=""
  __se_consumed=0
  if [ -n "$__se_key" ] && __se_sdir=$(_se_turn_state_dir "$PROJECT_DIR"); then
    if [ -f "$__se_sdir/claude.$__se_key" ]; then
      __se_consumed=1
      __se_baseline=$(cat "$__se_sdir/claude.$__se_key" 2>/dev/null) || __se_baseline=""
      rm -f "$__se_sdir/claude.$__se_key" || __se_baseline=""
      __se_nonces=$(_se_turn_nonce_take "$__se_sdir" "claude.$__se_key")
      if __se_now=$(_se_tree_fingerprint "$PROJECT_DIR" "$__se_sdir/fp-cache"); then
        TURN_STATE=$(_se_turn_baseline_state "$__se_baseline" "$__se_now" "$__se_nonces")
      fi
      if [ "$TURN_STATE" = "changed" ]; then
        if ! TURN_RANGE_FILES=$(_se_turn_range_files "$PROJECT_DIR" "${__se_now%% *}" "$__se_baseline"); then
          # Unreadable committed range: count it as a code change, never as docs.
          TURN_RANGE_FILES=".trellis-turn-range-unreadable"
        fi
      fi
    fi
    # Carry: when this evaluation passes (exit 0 with no block, advisory
    # included), the end state becomes the next turn's baseline, so a turn
    # that starts with no prompt compares against it. Never after a block: the
    # next Stop then finds no baseline and reads unknown, so a re-Stop with no
    # change still owes the receipt. Only where the mechanism is live, so an
    # unattached project gets no state written.
    if [ "$__se_consumed" = "1" ] || _se_turn_baseline_armed "$PROJECT_DIR" claude; then
      trap '[ "$?" -eq 0 ] && [ "$__se_blocked" = "0" ] \
        && _se_turn_carry_write "$__se_sdir" "claude.$__se_key" "$PROJECT_DIR"' EXIT
    fi
  fi
  if [ "$TURN_STATE" = "unknown" ] && _se_turn_baseline_armed "$PROJECT_DIR" claude; then
    # Missing, unreadable or uncomputable baseline: whatever the turn did,
    # including commits that left the tree clean, is unknown, never docs.
    TURN_STATE=changed
    TURN_RANGE_FILES=".trellis-turn-range-unknown"
  fi
fi

# _se_changed_files — echo the full set of files changed this turn, one per line:
# tracked diff-vs-HEAD UNION untracked (not-yet-`git add`ed). Mirrors the union
# in _se_find_subtree. cwd-independent (git -C PROJECT_DIR) so it's stable on
# both sides of the subtree cd. `git diff HEAD --name-only` alone OMITS untracked
# new files — a turn that only Writes new code files would otherwise look empty.
# The shared Git pathspec filters checkout-local hook state even when tracked;
# real settings and rule edits remain visible.
_se_changed_files() {
  { _se_hook_state_git -C "$PROJECT_DIR" diff HEAD --name-only 2>/dev/null; \
    _se_hook_state_git -C "$PROJECT_DIR" ls-files --others --exclude-standard 2>/dev/null; } \
    | sort -u
}

emit_block() {
  local step="$1"
  local output="$2"

  # --- Fail-counter: count consecutive blocks against the SAME changed file-set.
  # File-set hash is cwd-independent (git -C PROJECT_DIR) so it's stable whether
  # emit_block fires before or after the subtree cd. cksum is POSIX-portable
  # (macOS has no sha256sum); we key off the set of changed paths, not contents.
  local fileset_hash prevhash prevcount count
  fileset_hash=$(_se_changed_files | cksum | awk '{print $1}')
  prevhash=""
  prevcount=0
  if [ -f "$STATE_FILE" ]; then
    read -r prevhash prevcount < "$STATE_FILE"
  fi
  prevcount=${prevcount:-0}
  if [ "$prevhash" = "$fileset_hash" ]; then
    count=$((prevcount + 1))
  else
    count=1
  fi
  mkdir -p "${PROJECT_DIR}/.claude" 2>/dev/null || true
  printf '%s %s\n' "$fileset_hash" "$count" > "$STATE_FILE" 2>/dev/null || true

  # A blocked Stop never carries its end state forward (C01).
  __se_blocked=1

  local reason="${step}: ${output}"
  if [ "$count" -ge 2 ]; then
    reason="${reason}
STOP: re-read top-down, state the wrong assumption before retrying (same files failed ${count} times)."
  fi
  jq -nc --arg reason "$reason" '{decision: "block", reason: $reason}'
  exit 2
}

# _se_find_subtree — echo the deepest subtree (relative to PROJECT_DIR) that
# contains every changed file in this turn AND carries its own manifest. Echo
# nothing if changed files span multiple subtrees, none have a nested manifest,
# or git isn't here. Quiet by design.
_se_find_subtree() {
  command -v git >/dev/null 2>&1 || return 0
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  local file dir found common=""

  while IFS= read -r file; do
    [ -z "$file" ] && continue

    dir="$(dirname "$file")"
    found=""
    # Walk up. Stop one level above the worktree root.
    while [ -n "$dir" ] && [ "$dir" != "." ] && [ "$dir" != "/" ]; do
      if [ -f "$dir/package.json" ] || [ -f "$dir/go.mod" ] \
         || [ -f "$dir/pyproject.toml" ] || [ -f "$dir/Cargo.toml" ]; then
        found="$dir"
        break
      fi
      dir="$(dirname "$dir")"
    done

    # File has no nested manifest above it → caller falls back to repo root.
    [ -z "$found" ] && return 0

    if [ -z "$common" ]; then
      common="$found"
    elif [ "$common" != "$found" ]; then
      # Changed files span multiple subtrees → fall back to repo root.
      return 0
    fi
  done < <(
    _se_changed_files
  )

  printf '%s' "$common"
}

# Keep unavailable checks, reused checks and ignored policy visible on every
# receipt/advisory exit, without emitting multiple Stop objects or
# manufacturing executed verification evidence.
VERIFICATION_UNAVAILABLE=""
VERIFICATION_NOTE=""
_se_verification_advisory() {
  local message="$1"
  if [ -n "$VERIFICATION_NOTE" ]; then
    message="${VERIFICATION_NOTE}${message:+$'\n'}${message}"
  fi
  if [ -n "$VERIFICATION_UNAVAILABLE" ]; then
    message="${VERIFICATION_UNAVAILABLE}${message:+$'\n'}${message}"
  fi
  [ -n "$message" ] || return 0
  jq -nc --arg m "$message" '{additionalContext: $m}'
}

# _se_receipt_gate — Step 5, the receipts gate (structural done-detection).
# Called at Step 5 on a dirty tree, and from Guard 2 for a turn that committed
# and left the tree clean (C01). Returns only when no receipt is owed; every
# other path exits (pass, advisory or emit_block).
_se_receipt_gate() {
  # C01: a turn that matched its entry baseline mutated nothing → no receipt.
  # "unknown" (no, unreadable or uncomputable baseline) keeps the demand.
  [ "$TURN_STATE" = "same" ] && return 0
  if [ "${PROCESS_GATE_NO_RECEIPTS:-0}" != "1" ]; then
    # Doc-only skip: every changed file has a doc extension (.md/.mdx/.rst/.txt).
    # Reuse code-review-subagent's final-path-segment anchor + NONDOC_COUNT==0
    # logic, but over the diff-UNION-untracked set (a turn that only Writes new
    # code files has an empty `git diff HEAD` — those must NOT read as doc-only).
    # The set includes paths this turn committed (TURN_RANGE_FILES, C01).
    NONDOC_COUNT=$({ _se_changed_files; printf '%s\n' "$TURN_RANGE_FILES"; } \
      | grep -v '^$' \
      | grep -vE '(^|/)[^/]+\.(md|mdx|rst|txt)$' \
      | awk 'END{print NR}')
    if [ "$NONDOC_COUNT" != "0" ]; then
      # Two sources, same as the Codex hook. (a) last_assistant_message: the
      # final message's text, carried in the Stop envelope. Claude Code can fire
      # Stop before that message reaches the transcript file, so the transcript
      # alone misses a receipt in it. (b) the turn-scoped transcript parse:
      # catches a receipt written before the turn's last tool call. Only when
      # BOTH are unavailable is the receipt unverifiable: fail OPEN with an
      # advisory rather than block.
      # A non-string value is not message text; treat it as unavailable.
      LAST_MSG=$(printf '%s' "$INPUT" | jq -r 'if (.last_assistant_message | type) == "string" then .last_assistant_message else empty end')
      TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')
      if [ -n "$TRANSCRIPT" ] && [ ! -f "$TRANSCRIPT" ]; then
        TRANSCRIPT=""
      fi
      if [ -z "$LAST_MSG" ] && [ -z "$TRANSCRIPT" ]; then
        rm -f "$STATE_FILE"
        _se_verification_advisory 'stop-verify: receipts unverifiable (no last_assistant_message and no transcript_path in this harness envelope); state your DoD receipt to the user.'
        exit 0
      fi

      # Turn-scoping (load-bearing): a receipt from a PRIOR turn must not satisfy
      # THIS turn. The transcript is JSONL. Emit one role per input line (1:1 map,
      # robust to malformed lines via fromjson? // "null"), find the LAST user-role
      # line, and search ONLY lines after it. No user line → scope whole file.
      # _se_turn_text prints this turn's text: the envelope message, then the
      # assistant text blocks of the scoped transcript lines. Thinking, tool
      # input and tool output are not text the user saw, so a receipt there
      # does not count.
      LAST_USER=""
      if [ -n "$TRANSCRIPT" ]; then
        LAST_USER=$(jq -rR '(fromjson? | (.message.role // .role)) // "null"' "$TRANSCRIPT" 2>/dev/null \
          | grep -n '^user$' | tail -1 | cut -d: -f1)
      fi
      _se_turn_text() {
        printf '%s\n' "$LAST_MSG"
        [ -n "$TRANSCRIPT" ] && awk -v n="${LAST_USER:-0}" 'NR>n' "$TRANSCRIPT" \
          | jq -rR 'fromjson? | select((.message.role // .role) == "assistant")
              | (.message.content // .content)
              | if type == "string" then .
                elif type == "array" then .[]? | select(type == "object" and (.type == "text" or .type == "output_text")) | .text | select(type == "string")
                else empty end' 2>/dev/null
        return 0
      }
      # Canonical marker: <!-- dod-receipt cmd="…" exit=<int> diff="+N/-M (K files)" -->
      # ERE matches the fields IN ORDER and requires FILLED values, not just field
      # names: `exit=[0-9]` (a digit must follow, rejecting the literal `exit=<int>`)
      # and `diff=.*\+[0-9]` (a `+<digit>` must appear, rejecting `+N/-M`). Without
      # this, the unfilled template the block message prints below would itself
      # satisfy the gate. Anchoring on `\+[0-9]` (not the quote char) is agnostic to
      # JSONL-escaped (\") vs unescaped (") quoting. See CLAUDE.md:43.
      # Follow-ups marker (spec 012): <!-- follow-ups: <count> --> or
      # <!-- follow-ups: none -->, emitted alongside the DoD receipt. The ERE
      # requires a FILLED value (`none` or digits) after the literal
      # `follow-ups: `, so the warn message's deliberately-unfilled template
      # `<count-or-none>` can never satisfy it (`<` follows the colon-space —
      # same tightening trick as `exit=[0-9]` above). Distinct literals mean no
      # cross-collision with dod-receipt parsing in either direction, and the
      # marker carries no quote characters, so it is immune to JSONL
      # \"-escaping differences by construction.
      FOLLOWUPS_RE='<!-- follow-ups: (none|[0-9]+) -->'
      if _se_turn_text \
           | grep -Eq '<!-- dod-receipt .*cmd=.*exit=[0-9].*diff=.*\+[0-9].*-->'; then
        rm -f "$STATE_FILE"
        # Follow-ups nudge (spec 012 D4): receipt present — re-scan the SAME
        # turn-scoped window for the follow-ups marker. Present → silent pass,
        # byte-identical to pre-012 behaviour. Absent → NON-BLOCKING advisory.
        # Warn stays warn: never emit_block, never exit 2, on this path.
        # dod-receipt spans are stripped first (perl non-greedy; the transcript is
        # JSONL so a receipt quoting the marker inside cmd="…" would otherwise
        # false-satisfy the scan — 012 review F1).
        if _se_turn_text | perl -pe 's/<!--\s*dod-receipt\b.*?-->//g' | grep -Eq "$FOLLOWUPS_RE"; then
          _se_verification_advisory ''
          exit 0
        fi
        _se_verification_advisory 'stop-verify: DoD receipt found but no follow-ups marker. End the message with a Follow-ups block — numbered, decreasing priority (blocking-risk > correctness > cost/quota > hygiene), one line each, disposition fold/new-spec/surgical, derived ONLY from context already read this session (no new exploration) — or state none. Then paste the marker: <!-- follow-ups: <count-or-none> -->'
        exit 0
      fi
      emit_block "receipts" 'no Definition-of-Done receipt found for this turn. A code change is not done without one. State the verification command, its exit code, and the diff lines that prove the change, then paste the canonical marker (CLAUDE.md:43):
<!-- dod-receipt cmd="<verification command>" exit=<int> diff="+N/-M (K files)" -->'
    fi
  fi
}

# --- Step 1: TodoWrite check (runs before the dirty-tree skip — pure-chat turns
# can close todos via TodoWrite without touching files; receipts-required must
# still hold). ---
TODOS_FILE="${TODOS_FILE:-${PROJECT_DIR}/.claude/todos.json}"
if [ -f "$TODOS_FILE" ]; then
  # Parse before slicing so jq's status cannot be hidden by the head pipeline.
  if ! OPEN_TODOS=$(jq -r '
    [.. | objects | select(.status? == "in_progress" or .status? == "pending")]
    | map("- [\(.status)] \(.content // .task // "?")")
    | .[]
  ' "$TODOS_FILE" 2>&1); then
    emit_block "TodoWrite" "could not parse todos file ${TODOS_FILE}:
${OPEN_TODOS}"
  fi
  OPEN_TODOS=$(printf '%s\n' "$OPEN_TODOS" | head -20)

  if [ -n "$OPEN_TODOS" ]; then
    emit_block "TodoWrite" "open tasks remain — complete, defer with reason, or abandon with reason:
${OPEN_TODOS}"
  fi
fi

# _se_all_doc_paths: stdin is one path per line. Succeeds iff every non-empty
# path is a doc file (.md/.mdx/.rst/.txt). A rename ("old -> new"), a quoted
# path and a directory entry are never a plain doc, so they read as code.
_se_all_doc_paths() {
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      *' -> '* | '"'* | */) return 1 ;;
    esac
    printf '%s\n' "$p" | grep -qE '(^|/)[^/]+\.(md|mdx|rst|txt)$' || return 1
  done
  return 0
}

# --- Guard 2: no file edits this turn → pure chat; skip typecheck/lint/test.
# Best-effort: check git worktree dirtiness. If git isn't here, fall through
# and let downstream steps no-op when no config files exist.
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # Porcelain output is empty iff worktree matches HEAD (no staged, unstaged, or untracked changes).
  # NOTE: earlier versions used `grep -c '^' || echo 0` here — that doubles output to "0\n0"
  # when empty (grep -c prints 0 AND exits non-zero), breaking the numeric test.
  if ! WORKTREE_STATUS=$(git status --porcelain --untracked-files=all 2>&1); then
    emit_block "git status" "could not inspect worktree changes:
${WORKTREE_STATUS}"
  fi
  if [ "$TURN_STATE" = "same" ]; then
    # Existing dirty code is not a new edit: the authenticated fingerprint
    # already covers its bytes and the index. Todos were checked above.
    _se_receipt_gate
    exit 0
  fi
  if [ -z "$WORKTREE_STATUS" ] && [ -z "$TURN_RANGE_FILES" ]; then
    # Preserve the clean-tree fallback only when no committed range is known.
    if [ "$TURN_STATE" = "changed" ]; then
      _se_receipt_gate
    fi
    exit 0
  fi

  # bug #6: a dirty tree whose every path is a doc, on a turn whose baseline is
  # known, changed no code. Skip the heavy typecheck/lint/test; only the receipt
  # gate runs (it owes no receipt for docs). A code path, a rename, a quoted or
  # directory entry, a committed code path (TURN_RANGE_FILES) or an unknown
  # baseline keeps the full run.
  if [ "$TURN_STATE" != "unknown" ] \
     && { printf '%s\n' "$WORKTREE_STATUS" | cut -c4-; printf '%s\n' "$TURN_RANGE_FILES"; } \
        | _se_all_doc_paths; then
    _se_receipt_gate
    exit 0
  fi
fi

# --- Subtree scoping. If every changed file shares one subtree with its own
# manifest, run scoped checks there instead of repo-root. Opt-out:
# PROCESS_GATE_FORCE_ROOT=1.
if [ "${PROCESS_GATE_FORCE_ROOT:-0}" != "1" ]; then
  SUBTREE="$(_se_find_subtree)"
  if [ -n "$SUBTREE" ] && [ -d "$SUBTREE" ]; then
    if ! cd "$SUBTREE" 2>/dev/null; then
      emit_block "subtree" "could not enter selected verification subtree: ${SUBTREE}"
    fi
  fi
fi

CHECKS_RUN=0

# Steps 2–4 plan their checks instead of running them one by one. The plan is
# the input of the reuse key (spec 072 U8): a pass receipt for the same key
# skips the run. Otherwise every check runs, groups concurrently and the
# members of a group in order (cargo serializes on its build lock anyway), and
# the first planned check that failed blocks with the same reason and slicing
# the sequential run gave.
__se_ck_id=(); __se_ck_form=(); __se_ck_label=(); __se_ck_slice=()
__se_ck_group=(); __se_ck_dir=(); __se_ck_cmd=()
# _se_plan_check <id> <argv|shell> <block step> <head|tail> <group> <dir> <command...>
_se_plan_check() {
  local n=${#__se_ck_id[@]}
  __se_ck_id[n]=$1; __se_ck_form[n]=$2; __se_ck_label[n]=$3
  __se_ck_slice[n]=$4; __se_ck_group[n]=$5; __se_ck_dir[n]=$6
  shift 6
  __se_ck_cmd[n]="$*"
  CHECKS_RUN=$((CHECKS_RUN + 1))
}

# Parse before ANY JS runner/version probe: absent installs cannot mask a bad
# manifest. Dependency-free package scripts do not require node_modules.
HAS_TEST=""
JS_HAS_DEPS=false
if [ -f package.json ]; then
  if ! PACKAGE_INFO=$(jq -c '{test: (.scripts.test // ""), needs_dependencies:
      ([.dependencies, .devDependencies, .optionalDependencies, .peerDependencies]
       | any(. != null and length > 0))}' package.json 2>&1) || [ -z "$PACKAGE_INFO" ]; then
    emit_block "package.json" "could not parse package.json while detecting verification dependencies:
${PACKAGE_INFO}"
  fi
  HAS_TEST=$(printf '%s' "$PACKAGE_INFO" | jq -r '.test')
  JS_HAS_DEPS=$(printf '%s' "$PACKAGE_INFO" | jq -r '.needs_dependencies')
fi

# Search only this checkout: workspaces may hoist dependencies, including via
# directory symlinks. Yarn PnP installs need no node_modules directory.
_se_js_install_present() {
  local dir="$PWD" root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || root="$PROJECT_DIR"
  root=$(CDPATH='' cd "$root" 2>/dev/null && pwd -P) || root="$PWD"
  case "$dir/" in "$root/"*) ;; *) root="$dir" ;; esac
  while :; do
    [ -d "$dir/node_modules" ] || [ -f "$dir/.pnp.cjs" ] || [ -f "$dir/.pnp.js" ] && return 0
    [ "$dir" != "$root" ] && [ "$dir" != / ] || return 1
    dir=$(dirname "$dir")
  done
}
JS_AVAILABLE=0
_se_js_install_present && JS_AVAILABLE=1
_se_js_unavailable() {
  VERIFICATION_UNAVAILABLE="stop-verify: verification unavailable: dependencies not installed ($PWD; no node_modules directory or installed Yarn PnP artifact in checkout ancestors)."
}

# _se_resolve_python_tool <tool> — echo a command with pinned-project
# precedence. A direct .venv path prevents a global tool shim from winning.
_se_resolve_python_tool() {
  local tool="$1"

  if [ -x ".venv/bin/$tool" ]; then
    printf '%s' ".venv/bin/$tool"
  elif [ -f "uv.lock" ] && command -v uv >/dev/null 2>&1; then
    printf 'uv run %s' "$tool"
  elif command -v "$tool" >/dev/null 2>&1; then
    command -v "$tool"
  fi
}

# _se_mypy_pyproject_files — succeed when mypy reads pyproject.toml here and its
# [tool.mypy] table declares `files`. mypy.ini and .mypy.ini win over
# pyproject.toml in the same directory, so they keep the '.' default. Scoped awk,
# not a TOML parse: comments and other tables never count.
_se_mypy_pyproject_files() {
  if [ -f "mypy.ini" ] || [ -f ".mypy.ini" ] || [ ! -f "pyproject.toml" ]; then
    return 1
  fi
  awk '
    /^[[:space:]]*\[/ { in_mypy = ($0 ~ /^[[:space:]]*\[[[:space:]]*tool\.mypy[[:space:]]*\]/); next }
    in_mypy && /^[[:space:]]*files[[:space:]]*=/ { found = 1 }
    END { exit (found ? 0 : 1) }
  ' pyproject.toml
}

# --- Step 2: Typecheck ---
# TypeScript
if [ -f "tsconfig.json" ] && [ "$JS_AVAILABLE" -eq 0 ]; then
  _se_js_unavailable
elif [ -f "tsconfig.json" ] && command -v npx >/dev/null 2>&1; then
  # The node_modules/.bin copy npx --no-install would resolve, run directly
  # (same argv, no npx startup, and a closure the reuse key can bind). With
  # none inside the worktree, npx runs it and that Stop is never reused.
  if __se_bin=$(_se_node_bin tsc "$PWD"); then
    _se_plan_check typecheck.tsc argv "typecheck (tsc)" head tsc "$PWD" "$__se_bin" --noEmit
  else
    _se_plan_check typecheck.tsc argv "typecheck (tsc)" head tsc "$PWD" npx --no-install tsc --noEmit
  fi
fi

# Python (mypy)
MYPY_CMD="$(_se_resolve_python_tool mypy)"
if [ -n "$MYPY_CMD" ]; then
  HAS_MYPY_CFG=0
  [ -f "mypy.ini" ] && HAS_MYPY_CFG=1
  if [ -f "pyproject.toml" ] && grep -q '\[tool.mypy\]' pyproject.toml 2>/dev/null; then
    HAS_MYPY_CFG=1
  fi
  if [ "$HAS_MYPY_CFG" = "1" ]; then
    # A configured [tool.mypy] files list is mypy's own target set; a positional
    # '.' would override it and re-collect conftest modules.
    if _se_mypy_pyproject_files; then
      _se_plan_check typecheck.mypy shell "typecheck (mypy)" head mypy "$PWD" "$MYPY_CMD"
    else
      _se_plan_check typecheck.mypy shell "typecheck (mypy)" head mypy "$PWD" "$MYPY_CMD ."
    fi
  fi
fi

# Rust
if [ -f "Cargo.toml" ] && command -v cargo >/dev/null 2>&1; then
  _se_plan_check typecheck.cargo-check argv "typecheck (cargo check)" head cargo "$PWD" cargo check
fi

# Go
if [ -f "go.mod" ] && command -v go >/dev/null 2>&1; then
  _se_plan_check typecheck.go-vet argv "typecheck (go vet)" head go-vet "$PWD" go vet ./...
fi

# --- Step 3: Lint (repo-wide) ---
# ESLint. The probe's output is the eslint version the reuse key binds.
ESLINT_VERSION=""
if [ -f ".eslintrc" ] || [ -f ".eslintrc.js" ] || [ -f ".eslintrc.cjs" ] \
   || [ -f ".eslintrc.json" ] || [ -f ".eslintrc.yml" ] || [ -f ".eslintrc.yaml" ] \
   || [ -f "eslint.config.js" ] || [ -f "eslint.config.mjs" ] || [ -f "eslint.config.ts" ]; then
  if [ "$JS_AVAILABLE" -eq 0 ]; then
    _se_js_unavailable
  elif ! command -v npx >/dev/null 2>&1; then
    :
  elif __se_bin=$(_se_node_bin eslint "$PWD"); then
    ESLINT_VERSION=$("$__se_bin" --version 2>/dev/null) \
      && _se_plan_check lint.eslint argv "lint (eslint)" head eslint "$PWD" "$__se_bin" . --quiet
  elif ESLINT_VERSION=$(npx --no-install eslint --version 2>/dev/null); then
    _se_plan_check lint.eslint argv "lint (eslint)" head eslint "$PWD" npx --no-install eslint . --quiet
  fi
fi

# ruff
if command -v ruff >/dev/null 2>&1 && { [ -f "pyproject.toml" ] || [ -f "ruff.toml" ] || [ -f ".ruff.toml" ]; }; then
  _se_plan_check lint.ruff argv "lint (ruff)" head ruff "$PWD" ruff check .
fi

# clippy
if [ -f "Cargo.toml" ] && command -v cargo >/dev/null 2>&1; then
  _se_plan_check lint.clippy argv "lint (clippy)" head cargo "$PWD" cargo clippy --quiet --message-format=short -- -D warnings
fi

# golangci-lint
if [ -f "go.mod" ] && command -v golangci-lint >/dev/null 2>&1; then
  _se_plan_check lint.golangci-lint argv "lint (golangci-lint)" head golangci-lint "$PWD" golangci-lint run
fi

# Resolve Python's test runner before selecting a manifest branch so mixed
# Python/Rust/Go repositories still fall through when pytest is unavailable.
PYTEST_CMD=""
if [ -f "pyproject.toml" ] || [ -f "pytest.ini" ] || [ -f "setup.cfg" ]; then
  PYTEST_CMD="$(_se_resolve_python_tool pytest)"
  if [ -n "$PYTEST_CMD" ]; then
    PYTEST_CMD="$PYTEST_CMD --tb=short -q"
  fi
fi

# --- Step 4: Test (fast suite; skip e2e unless explicitly configured) ---
TEST_CMD=""
_PM=""
if [ -f "package.json" ] && command -v jq >/dev/null 2>&1; then
  if [ -n "$HAS_TEST" ] && [ "$HAS_TEST" != "echo \"Error: no test specified\" && exit 1" ]; then
    if [ "$JS_AVAILABLE" -eq 0 ] && [ "$JS_HAS_DEPS" = true ]; then
      _se_js_unavailable
    elif command -v trellis_resolve_pm >/dev/null 2>&1; then
      _PM="$(trellis_resolve_pm "$PROJECT_DIR")"
    else
      _PM="npm"
    fi
    # Configured-but-missing PM → skip the test step rather than hard-fail.
    if [ -n "${_PM:-}" ] && command -v "$_PM" >/dev/null 2>&1; then
      TEST_CMD="$_PM run test"
    fi
  fi
elif [ -n "$PYTEST_CMD" ]; then
  TEST_CMD="$PYTEST_CMD"
elif [ -f "Cargo.toml" ] && command -v cargo >/dev/null 2>&1; then
  TEST_CMD="cargo test --quiet"
elif [ -f "go.mod" ] && command -v go >/dev/null 2>&1; then
  TEST_CMD="go test ./..."
fi

# A faster Stop suite comes only from machine config:
# projects.<canonical root>.stop_checks.fast in <TRELLIS_HOME>/config.json
# (_se_stop_fast_config). Nothing in the checkout can set it; .trellis.json
# and the working tree are writable by a same-user agent. It replaces the test
# step and runs from the project root. A config that fails the ownership and
# mode checks, or a malformed value, keeps the detected suite and says so. A
# fast run is never reused and never earns a pass receipt. The merge gate
# never reads this key and always runs its own checks.
STOP_FAST_CMD=$(_se_stop_fast_config "$PROJECT_DIR")
case $? in
  0) [ -z "$STOP_FAST_CMD" ] \
       || VERIFICATION_NOTE="stop-verify: the test step ran stop_checks.fast from TRELLIS_HOME config.json (${STOP_FAST_CMD}), not the detected suite; not reused." ;;
  1) STOP_FAST_CMD=""
     VERIFICATION_NOTE="stop-verify: stop_checks.fast in TRELLIS_HOME config.json is unreadable or malformed (want a one-line string under projects.<root>.stop_checks); ran the full test step." ;;
  *) STOP_FAST_CMD=""
     VERIFICATION_NOTE="stop-verify: stop_checks.fast ignored: TRELLIS_HOME config.json must be a regular file you own with mode 0600 or stricter, in a directory with no group or other write bit; ran the full test step." ;;
esac
if [ -n "$STOP_FAST_CMD" ]; then
  _se_plan_check test.fast shell "test (stop_checks.fast: ${STOP_FAST_CMD})" tail test "$PROJECT_DIR" "$STOP_FAST_CMD"
elif [ -n "$TEST_CMD" ]; then
  case "$TEST_CMD" in
    cargo\ *) __se_test_group=cargo ;;
    *) __se_test_group='test' ;;
  esac
  _se_plan_check test shell "test (${TEST_CMD})" tail "$__se_test_group" "$PWD" "$TEST_CMD"
fi

# _se_stop_key <fingerprint> — print the sha256 reuse key for the planned
# checks, or fail when any input cannot be bound; the caller then runs the
# checks and writes no receipt. It over-includes on purpose: anything that
# might change a result changes the key, and then the checks run.
#   - no perl setting (PERL5OPT, PERL5LIB, PERLLIB, PERL5DB, PERL_*) and no
#     BASH_ENV may be exported at all, and every perl here runs with the
#     first four unset: perl does the policing below.
#   - every PATH entry must be absolute with no . or .. segment, and every
#     word of every check and each resolved program plain bytes
#     ([A-Za-z0-9_@%+=:,./-]): what is resolved here is what runs.
#   - each planned program must be a script inside the worktree (covered by
#     the fingerprint and the ignored digest: node_modules/.bin, .venv) run
#     by a listed interpreter, a listed interpreter itself (node, nodejs,
#     python*, perl*: _se_tool_closure), or npm/pnpm with its whole
#     installation tree bound (_se_pkg_digest), its subcommand limited to
#     running a package.json script whose programs pass the same rule
#     (_se_pm_progs), and its config files bound (_se_pm_config). Any
#     other native program (cargo, go, rustc, ruff, a compiled tool) or
#     script outside the worktree, npx included, gets a full run: the key
#     cannot see the code or configuration it reads. cargo, go, rustc,
#     rustup, gofmt and golangci-lint are refused by name too.
#   - the whole exported environment, harness and agent variables included,
#     since any check may read any variable. Only PWD, OLDPWD and _ are left
#     out: each check's cd and exec overwrite them before it runs, from the
#     directories and command already in the key. Read raw, so a name bash
#     would not list is bound too; an exported function refuses reuse. A
#     variable that selects code by path or option (NODE_OPTIONS=--require=,
#     NODE_PATH, PYTHONPATH, LD_PRELOAD, GO*, CARGO_*, GIT_*, ...) refuses
#     reuse too (_se_env_moves_code): its text is not the code it selects.
#   - every git-ignored input, recursively (_se_ignored_digest).
_se_stop_key() {
  local i prog n sum top checks="" progs=() words=() closure kind path roots pkgroots=() pkg="" pmcfg="" envsum ignored stats shells=()
  # perl polices the rest, so nothing may reach into perl itself: any perl
  # setting, or BASH_ENV, refuses before the first perl runs.
  for n in $(compgen -e); do
    case "$n" in (PERL5OPT|PERL5LIB|PERLLIB|PERL5DB|PERL_*|BASH_ENV) return 1 ;; esac
  done
  top=$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null) \
    && top=$(CDPATH='' cd -P "$top" 2>/dev/null && pwd -P) || return 1
  # An empty or relative PATH entry is the working directory to execvp and
  # env: the programs resolved here would not be the ones that run.
  case ":$PATH:" in (*::*) return 1 ;; esac
  IFS=: read -r -a words <<< "$PATH"
  for n in "${words[@]}"; do
    case "$n" in (/*) ;; (*) return 1 ;; esac
    case "$n/" in (*/./*|*/../*) return 1 ;; esac
  done
  for (( i = 0; i < CHECKS_RUN; i++ )); do
    checks="${checks}check ${__se_ck_id[$i]} ${__se_ck_form[$i]} ${__se_ck_dir[$i]} ${__se_ck_cmd[$i]}"$'\n'
    # A check must be plain words of plain bytes: no operator, expansion,
    # quote, escape or glob that eval would read differently from this split.
    read -r -a words <<< "${__se_ck_cmd[$i]}"
    for n in "${words[@]}"; do
      case "$n" in (*[!A-Za-z0-9_@%+=:,./-]*) return 1 ;; esac
    done
    # Launchers that fetch or pick code at run time are never reused, as
    # any word of the command: npx and pnpx run whichever copy they find,
    # dlx and exec subcommands are refused in _se_pm_progs. Nor are the Rust
    # and Go toolchains, whose configuration and caches the key cannot see.
    for n in "${words[@]}"; do
      case "${n##*/}" in
        (npx|pnpx|bunx|dlx|yarn|yarnpkg|corepack|bun|deno|cargo|go|rustc|rustup|gofmt|golangci-lint) return 1 ;;
      esac
    done
    prog=${words[0]}
    case "$prog" in
      /*) ;;
      */*) prog="${__se_ck_dir[$i]}/$prog" ;;
      *) prog=$(command -v "$prog" 2>/dev/null) || return 1 ;;
    esac
    case "$prog" in (/*) ;; (*) return 1 ;; esac
    case "$prog" in (*[!A-Za-z0-9_@%+=:,./-]*) return 1 ;; esac
    progs[${#progs[@]}]=$prog
    # npm/pnpm: only `run <script>`, `run-script <script>` or `test`, every
    # program its scripts start, the shell that runs them, and every npmrc
    # and pnpm config file it reads.
    case "${prog##*/}" in
      npm|pnpm)
        n=$(_se_pm_progs "$top" "${__se_ck_dir[$i]}" "${words[@]}") || return 1
        while IFS= read -r path; do
          case "$path" in
            '') ;;
            arg$'\t'*) pmcfg="${pmcfg}${path}"$'\n' ;;
            *) progs[${#progs[@]}]=$path ;;
          esac
        done <<< "$n"
        n=$(command -v sh 2>/dev/null) || return 1
        shells=("$n" /bin/sh)
        n=$(_se_pm_config "${__se_ck_dir[$i]}") || return 1
        pmcfg="${pmcfg}${n}"$'\n' ;;
    esac
  done
  closure=$(_se_tool_closure "$top" "${progs[@]}") || return 1
  # The shell npm runs scripts with: native, bound by identity.
  if [ "${#shells[@]}" -gt 0 ]; then
    n=$(_se_tool_closure "$top" --shell "${shells[@]}") || return 1
    closure="${closure}"$'\n'"${n}"
  fi
  while IFS=$'\t' read -r kind path _ _ _ roots; do
    case "$kind" in
      tree|native) ;;
      pm)
        while [ -n "$roots" ]; do
          pkgroots[${#pkgroots[@]}]=${roots%%$'\t'*}
          case "$roots" in *$'\t'*) roots=${roots#*$'\t'} ;; *) roots="" ;; esac
        done ;;
      *) return 1 ;;
    esac
  done <<< "$closure"
  if [ "${#pkgroots[@]}" -gt 0 ]; then
    pkg=$(_se_pkg_digest "${pkgroots[@]}") || return 1
  fi
  ! _se_env_moves_code "$top" || return 1
  # The raw environment the checks inherit, names bash would not list
  # (a.b=1) included. An exported function (BASH_FUNC_*) refuses reuse: its
  # body would run in place of the program it names.
  envsum=$(/usr/bin/env -u PERL5OPT -u PERL5LIB -u PERLLIB -u PERL5DB perl -MDigest::SHA -e '
      my $d = Digest::SHA->new(256);
      for my $n (sort keys %ENV) {
        exit 3 if $n =~ /^BASH_FUNC_/;
        $d->add("$n=$ENV{$n}\0") unless $n eq "PWD" || $n eq "OLDPWD" || $n eq "_";
      }
      print $d->hexdigest') || return 1
  ignored=$(_se_ignored_digest "$PROJECT_DIR") || return 1
  stats=$(_se_stat_lines "s:${BASH_SOURCE[0]}" "s:$__se_lib" "s:$__se_vr_lib" "s:$__se_pm_lib" \
    "s:$PROJECT_DIR/.trellis.json" "s:${HOME:-/nonexistent}/.pyenv/version" \
    "s:${RUSTUP_HOME:-${HOME:-/nonexistent}/.rustup}/settings.toml") || return 1
  sum=$(printf '%s\n' 'trellis-stop-key v2' "fp $1" "cwd $(pwd -P) $PWD" "$checks" "$closure" "pkg $pkg" "pmcfg $pmcfg" \
    "eslint $ESLINT_VERSION" "env ${envsum%% *}" "ignored $ignored" "$stats" | shasum -a 256) || return 1
  sum=${sum%% *}
  [ "${#sum}" -eq 64 ] || return 1
  printf '%s' "$sum"
}

# _se_check_job <lead> <outdir> — run, in order, every planned check whose
# group <lead> leads, writing <n>.out and <n>.rc for each. Stops at the first
# failure: the collector blocks on it before reaching a later member.
_se_check_job() {
  local k argv=()
  for (( k = $1; k < CHECKS_RUN; k++ )); do
    [ "${__se_ck_lead[$k]}" -eq "$1" ] || continue
    if ! cd "${__se_ck_dir[$k]}" 2>/dev/null; then
      printf 'could not enter %s' "${__se_ck_dir[$k]}" > "$2/$k.out"
      printf '1\n' > "$2/$k.rc"
      return 0
    fi
    if [ "${__se_ck_form[$k]}" = argv ]; then
      read -r -a argv <<< "${__se_ck_cmd[$k]}"
      _vr_run "${__se_ck_id[$k]}" argv "${argv[@]}"
    else
      _vr_run "${__se_ck_id[$k]}" shell "${__se_ck_cmd[$k]}"
    fi
    printf '%s' "$_VR_OUTPUT" > "$2/$k.out"
    printf '%s\n' "$_VR_STATUS" > "$2/$k.rc"
    [ "$_VR_STATUS" -eq 0 ] || return 0
  done
}

# _se_run_checks — run the plan and block on the first planned check that
# failed (or never recorded an exit status). Jobs still running at that point
# are signalled with their descendants and reaped, so no check outlives the
# hook. Returns only when every check passed.
__se_ck_lead=(); __se_ck_pid=(); __se_ck_reaped=()
_se_check_abort() {
  local i live=""
  for (( i = 0; i < CHECKS_RUN; i++ )); do
    [ -n "${__se_ck_pid[$i]:-}" ] && [ -z "${__se_ck_reaped[$i]:-}" ] && live="$live ${__se_ck_pid[$i]}"
  done
  if [ -n "$live" ]; then
    # shellcheck disable=SC2086  # one pid per word
    _se_kill_tree $live
    # shellcheck disable=SC2086
    wait $live 2>/dev/null
  fi
  rm -rf "$__se_ck_out"
}
_se_run_checks() {
  local i j rc out
  __se_ck_out=$(mktemp -d "${TMPDIR:-/tmp}/trellis-stop.XXXXXX") \
    || emit_block "checks" "could not create a private directory for check output under ${TMPDIR:-/tmp}"
  for (( i = 0; i < CHECKS_RUN; i++ )); do
    __se_ck_lead[i]=$i
    for (( j = 0; j < i; j++ )); do
      if [ "${__se_ck_group[$j]}" = "${__se_ck_group[$i]}" ]; then
        __se_ck_lead[i]=$j
        break
      fi
    done
  done
  trap '_se_check_abort; exit 143' TERM INT HUP
  for (( i = 0; i < CHECKS_RUN; i++ )); do
    [ "${__se_ck_lead[$i]}" -eq "$i" ] || continue
    _se_check_job "$i" "$__se_ck_out" < /dev/null &
    __se_ck_pid[i]=$!
  done
  for (( i = 0; i < CHECKS_RUN; i++ )); do
    j=${__se_ck_lead[$i]}
    if [ -z "${__se_ck_reaped[$j]:-}" ]; then
      wait "${__se_ck_pid[$j]}"
      __se_ck_reaped[j]=1
    fi
    rc=$(cat "$__se_ck_out/$i.rc" 2>/dev/null) || rc=""
    [ "$rc" = 0 ] && continue
    out=$(cat "$__se_ck_out/$i.out" 2>/dev/null)
    [ -n "$rc" ] || out="check did not finish: no exit status was recorded"
    _se_check_abort
    trap - TERM INT HUP
    # Typecheck/lint: first 30 lines. Tests: last 30 (stack traces and
    # assertions land at the end).
    if [ "${__se_ck_slice[$i]}" = tail ]; then
      out=$(printf '%s' "$out" | tail -30)
    else
      out=$(printf '%s' "$out" | head -30)
    fi
    emit_block "${__se_ck_label[$i]}" "$out"
  done
  trap - TERM INT HUP
  rm -rf "$__se_ck_out"
}

if [ "$CHECKS_RUN" -gt 0 ]; then
  STOP_RECEIPT="" STOP_KEY="" STOP_FP=""
  if [ -z "$VERIFICATION_UNAVAILABLE" ] && [ -z "$STOP_FAST_CMD" ] \
     && STOP_RECEIPT=$(_se_stop_receipt_file "$PROJECT_DIR" "$__se_harness") \
     && { [ -n "$__se_now" ] && STOP_FP="$__se_now" \
          || STOP_FP=$(_se_tree_fingerprint "$PROJECT_DIR" "${__se_sdir:+$__se_sdir/fp-cache}"); } \
     && STOP_KEY=$(_se_stop_key "$STOP_FP"); then
    if _se_stop_receipt_match "$STOP_RECEIPT" "$STOP_KEY"; then
      VERIFICATION_NOTE="${VERIFICATION_NOTE:+$VERIFICATION_NOTE$'\n'}stop-verify: checks reused, not re-run: pass receipt ${STOP_KEY:0:12} matches this tree, commands, tools and policy (${STOP_RECEIPT})."
    else
      _se_run_checks
      # A receipt certifies exactly what the checks consumed: every input in
      # the key, ignored files and tools included, must read the same after
      # the run as before it. Anything that moved, whether a check wrote it
      # or another process did, means no receipt (the next Stop runs again).
      if STOP_FP2=$(_se_tree_fingerprint "$PROJECT_DIR" "${__se_sdir:+$__se_sdir/fp-cache}") \
         && [ "$(_se_stop_key "$STOP_FP2")" = "$STOP_KEY" ]; then
        _se_stop_receipt_write "$STOP_RECEIPT" "$STOP_KEY" "$(
          printf 'harness %s\nwritten %s\n' "$__se_harness" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          for (( __se_i = 0; __se_i < CHECKS_RUN; __se_i++ )); do
            printf 'check %s %s\n' "${__se_ck_id[$__se_i]}" "${__se_ck_cmd[$__se_i]}"
          done)"
      fi
    fi
  else
    _se_run_checks
  fi
fi

# --- Step 5: Receipts gate — structural done-detection. -----------------------
# Reached on a dirty tree (the clean-tree skip already exited, except for a
# committing turn, which Guard 2 sends straight to the gate) with no open todos
# (TodoWrite check already blocked) and all configured checks passed.
# Runs even when CHECKS_RUN==0: a code change with no toolchain STILL needs a
# receipt. Placed BEFORE the CHECKS_RUN==0 advisory so it gates that path too.
_se_receipt_gate

# --- Pass / no-check advisory ---
rm -f "$STATE_FILE"
if [ "$CHECKS_RUN" -eq 0 ] && [ -z "$VERIFICATION_UNAVAILABLE" ]; then
  _se_verification_advisory "stop-verify: no typecheck/lint/test configured for this repo. Task completion is unverified — state this to the user."
  exit 0
fi
_se_verification_advisory ''
exit 0
