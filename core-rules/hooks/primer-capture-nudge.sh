#!/usr/bin/env bash
export GIT_OPTIONAL_LOCKS=0
# primer-capture-nudge.sh — Stop. Advisory nudge for a new subsystem after an
# edit-heavy turn.
#
# Contract:
#   - stop_hook_active=true, malformed input, a clean tree, or a missing INDEX
#     exits 0 silently. Missing git emits one stderr degradation notice, then
#     exits 0. This hook never blocks a turn.
#   - Edit-heavy means >=3 changed files OR >=200 added/deleted lines, matching
#     code-review-subagent.sh. REVIEW_MIN_FILES and REVIEW_MIN_LINES override
#     the defaults for project-local calibration.
#   - Changed paths covered by an INDEX slug or one of that primer's Entry points
#     are suppressed. Unknown subsystem slugs produce an additionalContext
#     nudge to run /primer <slug>.
#   - Tracked and untracked paths are included; .claude/ and .codex/ state is
#     excluded. Documentation-only changes do not produce a subsystem nudge.
#     Git C-quoted paths (tabs, newlines, quotes, backslashes) are not reliably
#     represented by the line-oriented scan and can be missed or misclassified.
#   - At most 200 paths are examined. An incomplete scan emits one stderr line;
#     a three-second deadline and parent-death supervision bound the whole hook.
#   - Advisory output is always exit 0. jq remains a required hook dependency;
#     set TRELLIS_NO_JQ_DEGRADE=1 to make a jq-less environment a silent no-op.
#
# Dependencies: jq (required), git and python3 (an advisory no-op if absent).
# Python supervises the complete process group, including blocked Git children.
#
# Source: Trellis / core-rules / hooks.md (C6, primer-capture-nudge).

set -u

# The supervisor starts before reading stdin or invoking any external command.
# Bash defers traps while waiting for foreground children, and parent death does
# not kill a child. A separate session lets the supervisor kill the entire job;
# its watchdog also does so if the supervisor itself is killed. Python resets a
# SIGTERM disposition inherited as ignored, which Bash alone cannot trap.
if [ "${1:-}" != --pcn-worker ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    printf '%s\n' 'primer-capture-nudge: python3 not found; degrading to no-op' >&2
    exit 0
  fi
  exec python3 -I -c '
import fcntl, os, select, shutil, signal, sys, threading, time

started = time.monotonic()
deadline = started + 3.0
parent = os.getppid()
# SIGCHLD may have been ignored by the launcher. Restore normal child reaping
# before forking so our watcher PID cannot be reused before waitpid.
signal.signal(signal.SIGCHLD, signal.SIG_DFL)
# Pick an unguessable name without filesystem I/O. The worker creates it and
# acknowledges success before either supervisor is allowed to remove it.
try:
    base = os.path.abspath(os.environ.get("TMPDIR") or "/tmp")
    work = os.path.join(base, "trellis-primer-nudge." + os.urandom(16).hex())
except (OSError, ValueError):
    sys.exit(0)
def cleanup():
    # A stalled temporary filesystem must not prevent process-group teardown.
    thread = threading.Thread(target=shutil.rmtree, args=(work,), kwargs={"ignore_errors": True}, daemon=True)
    try:
        thread.start()
        thread.join(0.2)
    except RuntimeError:
        pass
def notice(message=b"primer-capture-nudge: time budget exceeded; skipping advisory"):
    def emit():
        try:
            os.write(2, message + b"\n")
        except OSError:
            pass
    thread = threading.Thread(target=emit, daemon=True)
    try:
        thread.start()
        thread.join(0.05)
    except RuntimeError:
        pass
stop = 0
def interrupted(signum, frame):
    global stop
    stop = signum
for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(sig, interrupted)
supervisor = os.getpid()
try:
    result_read, result_write = os.pipe()
    ready_read, ready_write = os.pipe()
    watcher = os.fork()
except OSError:
    sys.exit(0)
if watcher == 0:
    os.close(result_read)
    try:
        os.setsid()
    except OSError:
        os._exit(0)
    created = False
    try:
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(sig, signal.SIG_DFL)
        child = os.fork()
        if child == 0:
            try:
                os.close(result_write)
                os.close(ready_read)
                os.mkdir(work, 0o700)
                os.write(ready_write, b"R")
                os.close(ready_write)
                with open(os.path.join(work, "stdout"), "wb") as output:
                    os.dup2(output.fileno(), 1)
                    # Python ignores these signals; producers must stop when
                    # the bounded downstream reader closes its pipe.
                    for sig in (signal.SIGPIPE, signal.SIGXFSZ):
                        signal.signal(sig, signal.SIG_DFL)
                    os.execv(sys.argv[1], [sys.argv[1], sys.argv[2], "--pcn-worker", work])
            except (OSError, ValueError):
                os._exit(0)
        os.close(ready_write)
        def receive_ready(block=False):
            global created, ready_read
            if ready_read is None:
                return
            if block or select.select([ready_read], [], [], 0)[0]:
                flag = os.read(ready_read, 1)
                os.close(ready_read)
                ready_read = None
                if flag == b"R":
                    created = True
                    os.write(result_write, b"R\n")
        while True:
            receive_ready()
            done, child_status = os.waitpid(child, os.WNOHANG)
            if done:
                receive_ready(block=True)
                result = b"D" + str(os.WEXITSTATUS(child_status)).encode() if os.WIFEXITED(child_status) else b"K"
                os.write(result_write, result + b"\n")
                # Keep the group leader alive until the supervisor kills the
                # group, so its ID cannot be recycled between wait and kill.
                while os.getppid() == supervisor and time.monotonic() < deadline + 0.5:
                    time.sleep(0.05)
                break
            if os.getppid() != supervisor:
                break
            if time.monotonic() >= deadline:
                os.write(result_write, b"T\n")
                while os.getppid() == supervisor and time.monotonic() < deadline + 0.5:
                    time.sleep(0.05)
                break
            time.sleep(0.05)
    except (OSError, ValueError):
        pass
    # The supervisor may have died without running its cleanup. Never wait
    # indefinitely for cleanup before killing this session, including us.
    if created:
        cleanup()
    try:
        os.killpg(os.getpgrp(), signal.SIGKILL)
    except OSError:
        pass
    os._exit(0)

os.close(result_write)
os.close(ready_read)
os.close(ready_write)
status = 0
created = False
completed = False
buffer = b""
try:
    while True:
        if stop or os.getppid() != parent or time.monotonic() >= deadline:
            if not stop and os.getppid() == parent and time.monotonic() >= deadline:
                notice()
            break
        ready, _, _ = select.select([result_read], [], [], 0.05)
        if not ready:
            continue
        chunk = os.read(result_read, 128)
        if not chunk:
            break
        buffer += chunk
        finished = False
        while b"\n" in buffer:
            result, buffer = buffer.split(b"\n", 1)
            if result == b"R":
                created = True
            elif result == b"T":
                if not stop and os.getppid() == parent:
                    notice()
                finished = True
            elif result == b"K":
                finished = True
            elif result.startswith(b"D"):
                status = int(result[1:])
                completed = created
                finished = True
        if finished:
            break
finally:
    os.close(result_read)
    # Kill the watcher first so it cannot launch a worker between a failed
    # killpg and setsid. Its unreaped PID cannot be recycled before killpg.
    try:
        os.kill(watcher, signal.SIGKILL)
    except OSError:
        pass
    try:
        os.killpg(watcher, signal.SIGKILL)
    except OSError:
        pass
    try:
        os.waitpid(watcher, 0)
    except ChildProcessError:
        pass
    # Publish only a completed worker result: a timed-out worker cannot leak
    # partial JSON or an advisory accompanied by a misleading timeout notice.
    if completed and not stop and os.getppid() == parent:
        if time.monotonic() >= deadline:
            notice()
        else:
            output = []
            def read_output():
                try:
                    with open(os.path.join(work, "stdout"), "rb") as stream:
                        output.append(stream.read(65536))
                except OSError:
                    pass
            reader = threading.Thread(target=read_output, daemon=True)
            try:
                reader.start()
            except RuntimeError:
                reader = None
            while reader is not None and reader.is_alive() and not stop and os.getppid() == parent and time.monotonic() < deadline:
                reader.join(min(0.05, max(0, deadline - time.monotonic())))
            if reader is not None and reader.is_alive() and not stop and os.getppid() == parent:
                notice()
            elif output and output[0] and not stop and os.getppid() == parent:
                # A single <=512-byte pipe write is atomic on POSIX. Larger
                # advisories are skipped instead of publishing partial JSON.
                payload = output[0]
                if len(payload) > 512:
                    notice(b"primer-capture-nudge: atomic output limit exceeded; skipping advisory")
                else:
                    lock = threading.Lock()
                    cancel = threading.Event()
                    finished = []
                    def write_output():
                        while not cancel.is_set() and time.monotonic() < deadline:
                            with lock:
                                if cancel.is_set() or time.monotonic() >= deadline:
                                    return
                                try:
                                    flags = fcntl.fcntl(1, fcntl.F_GETFL)
                                    try:
                                        fcntl.fcntl(1, fcntl.F_SETFL, flags | os.O_NONBLOCK)
                                        count = os.write(1, payload)
                                    finally:
                                        fcntl.fcntl(1, fcntl.F_SETFL, flags)
                                    finished.append(count)
                                    return
                                except BlockingIOError:
                                    pass
                                except OSError:
                                    return
                            cancel.wait(0.05)
                    writer = threading.Thread(target=write_output, daemon=True)
                    try:
                        writer.start()
                    except RuntimeError:
                        writer = None
                    while writer is not None and writer.is_alive() and not stop and os.getppid() == parent and time.monotonic() < deadline:
                        writer.join(min(0.05, max(0, deadline - time.monotonic())))
                    cancel.set()
                    # Do not announce a skip while a writer can still publish.
                    if writer is not None and lock.acquire(timeout=0.05):
                        try:
                            if not finished and not stop and os.getppid() == parent and time.monotonic() >= deadline:
                                notice()
                        finally:
                            lock.release()
    if created:
        cleanup()
sys.exit(status)
' "$BASH" "$0"
fi
__pcn_tmp="${2:-}"
[ -n "$__pcn_tmp" ] && [ -d "$__pcn_tmp" ] || exit 0

INPUT=$(cat 2>/dev/null || true)

# Source shared lib. An advisory hook must not turn an out-of-date deployment
# into a hard Stop failure; doctor/sync-hooks reports missing siblings.
__pcn_lib="$(dirname "${BASH_SOURCE[0]}")/lib/deps.sh"
[ -f "$__pcn_lib" ] || exit 0
# shellcheck source=lib/deps.sh disable=SC1090,SC1091
. "$__pcn_lib"
_se_require_jq "primer-capture-nudge"

# Stop payloads are harness-owned JSON. A malformed payload cannot be used as a
# reliable edit signal, so advisory behavior is to stay silent and pass.
if ! printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1; then
  exit 0
fi
STOP_ACTIVE=$(printf '%s' "$INPUT" | jq -r 'if .stop_hook_active == true then "true" else "false" end' 2>/dev/null || true)
[ "$STOP_ACTIVE" = "true" ] && exit 0

PROJECT_DIR="$(_se_project_dir)"
cd "$PROJECT_DIR" 2>/dev/null || exit 0
PROJECT_DIR="$(pwd -P 2>/dev/null || printf '%s' "$PROJECT_DIR")"

# Git is the only source of a deterministic current-turn change set. No git,
# no diff, no nudge.
command -v git >/dev/null 2>&1 || { printf '%s\n' 'primer-capture-nudge: git not found; degrading to no-op' >&2; exit 0; }
git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

REPO_ROOT="$(_se_repo_root "$PROJECT_DIR")"
PRIMERS_DIR="${REPO_ROOT}/.claude/primers"
INDEX="${PRIMERS_DIR}/INDEX.md"
[ -f "$INDEX" ] || exit 0

# The supervisor owns cleanup even when the worker is killed. All lists stay
# private and path operations are read-only; paths containing spaces work.
CHANGED_FILE_LIST="${__pcn_tmp}/changed"
TRACKED_FILE_LIST="${__pcn_tmp}/tracked"
UNTRACKED_FILE_LIST="${__pcn_tmp}/untracked"
UNTRACKED_ROOT_LIST="${__pcn_tmp}/roots"
CANDIDATE_LIST="${__pcn_tmp}/candidates"
INDEX_SLUG_LIST="${__pcn_tmp}/slugs"
INDEX_ENTRY_LIST="${__pcn_tmp}/entries"
PCN_PATH_LIMIT=200

_pcn_scan_limit() {
  printf '%s\n' 'primer-capture-nudge: path scan limit reached; skipping incomplete advisory' >&2
  exit 0
}

# Stop reading as soon as the limit is known to be exceeded. Git may still
# have to inspect its index, but is itself subject to the hard deadline. Do not
# launch an fsmonitor daemon or external/textconv diff helpers for an advisory.
git -c core.fsmonitor=false -c core.quotePath=false diff HEAD --name-only --no-ext-diff --no-textconv -- \
  ':(top,exclude).claude' ':(top,exclude).codex' 2>/dev/null \
  | awk -v cap="$PCN_PATH_LIMIT" '$0 !~ /^\.(claude|codex)\// && $0 !~ /^[[:space:]]*$/ { print; if (++n > cap) exit }' > "$TRACKED_FILE_LIST"
EXAMINED=$(awk 'END { print NR + 0 }' "$TRACKED_FILE_LIST")
[ "$EXAMINED" -le "$PCN_PATH_LIMIT" ] || _pcn_scan_limit

# Start with collapsed untracked roots, then expand each through Git so ignored
# trees and nested repositories are not traversed as ordinary changed files.
# Limit the visible output; Git itself may inspect more entries before writing,
# so the supervisor deadline also bounds its work.
ROOT_LIMIT=$((PCN_PATH_LIMIT - EXAMINED))
git -c core.fsmonitor=false -c core.quotePath=false ls-files --others --directory --no-empty-directory --exclude-standard -- . \
  ':(top,exclude).claude' ':(top,exclude).codex' 2>/dev/null \
  | awk -v cap="$ROOT_LIMIT" '$0 !~ /^\.(claude|codex)\// && $0 !~ /^[[:space:]]*$/ { print; if (++n > cap) exit }' > "$UNTRACKED_ROOT_LIST"
ROOT_COUNT=$(awk 'END { print NR + 0 }' "$UNTRACKED_ROOT_LIST")
[ "$ROOT_COUNT" -le "$ROOT_LIMIT" ] || _pcn_scan_limit
: > "$UNTRACKED_FILE_LIST"
while IFS= read -r root; do
  [ -n "$root" ] || continue
  REMAINING=$((PCN_PATH_LIMIT - EXAMINED))
  case "$root" in
    */)
      git -c core.fsmonitor=false -c core.quotePath=false --literal-pathspecs \
        ls-files --others --exclude-standard -- "$root" 2>/dev/null \
        | awk -v cap="$REMAINING" '{ print; if (NR > cap) exit }' > "$CANDIDATE_LIST"
      CANDIDATE_COUNT=$(awk 'END { print NR + 0 }' "$CANDIDATE_LIST")
      [ "$CANDIDATE_COUNT" -le "$REMAINING" ] || _pcn_scan_limit
      EXAMINED=$((EXAMINED + CANDIDATE_COUNT))
      cat "$CANDIDATE_LIST" >> "$UNTRACKED_FILE_LIST"
      ;;
    *)
      [ "$REMAINING" -gt 0 ] || _pcn_scan_limit
      EXAMINED=$((EXAMINED + 1))
      printf '%s\n' "$root" >> "$UNTRACKED_FILE_LIST"
      ;;
  esac
done < "$UNTRACKED_ROOT_LIST"
sort -u "$TRACKED_FILE_LIST" "$UNTRACKED_FILE_LIST" > "$CHANGED_FILE_LIST"

_pcn_normpath() {
  printf '%s' "$1" | sed -E 's#^\./##; s#//+#/#; s#/$##'
}

_pcn_safe_threshold() {
  case "${1:-}" in
    ''|*[!0-9]*) printf '%s' "$2" ;;
    *) printf '%s' "$1" ;;
  esac
}

_pcn_doc_path() {
  case "$1" in
    *\.md|*\.mdx|*\.rst|*\.txt) return 0 ;;
    *) return 1 ;;
  esac
}

# The default edit-heavy predicate is shared with code-review-subagent. Count
# files from the same tracked+untracked union used for the path analysis below.
[ -s "$CHANGED_FILE_LIST" ] || exit 0

MIN_FILES="$(_pcn_safe_threshold "${REVIEW_MIN_FILES:-3}" 3)"
MIN_LINES="$(_pcn_safe_threshold "${REVIEW_MIN_LINES:-200}" 200)"
CHANGED_FILES=$(awk 'END { print NR + 0 }' "$CHANGED_FILE_LIST")
# The file threshold is already sufficient in the common edit-heavy case.
# Otherwise reuse the bounded untracked list instead of enumerating it again.
if [ "$CHANGED_FILES" -lt "$MIN_FILES" ]; then
  TRACKED_LINES=$(git -c core.fsmonitor=false -c core.quotePath=false diff HEAD --numstat --no-ext-diff --no-textconv -- \
    ':(top,exclude).claude' ':(top,exclude).codex' 2>/dev/null \
    | awk '$3 !~ /^\.(claude|codex)\// && $1 != "-" && $2 != "-" { sum += $1 + $2 } END { print sum + 0 }')
  UNTRACKED_LINES=$(
    IFS=
    while read -r file; do
      [ -f "$file" ] && wc -l < "$file" 2>/dev/null || true
    done < "$UNTRACKED_FILE_LIST" | awk '{ sum += $1 } END { print sum + 0 }'
  )
  CHANGED_LINES=$((TRACKED_LINES + UNTRACKED_LINES))
  [ "$CHANGED_LINES" -ge "$MIN_LINES" ] || exit 0
fi

# INDEX is a curated subsystem map. Parse only its locked link format. An
# INDEX with no valid entries is treated as unavailable rather than turning a
# malformed file into a nudge storm.
sed -nE 's/^[[:space:]]*-[[:space:]]*\[([A-Za-z0-9._/-]+)\]\(\.\/[^)]*\).*$/\1/p' "$INDEX" \
  | sort -u > "$INDEX_SLUG_LIST" 2>/dev/null || true
[ -s "$INDEX_SLUG_LIST" ] || exit 0

# For each indexed primer, retain its Entry points. A changed sibling in the
# same entry-point directory is part of that subsystem even when the exact file
# is not one of the three-to-five listed entry points.
: > "$INDEX_ENTRY_LIST"
while IFS= read -r slug; do
  [ -n "$slug" ] || continue
  primer="${PRIMERS_DIR}/${slug}.md"
  [ -f "$primer" ] || continue
  awk '
    /^##[[:space:]]+Entry points[[:space:]]*$/ { in_entries = 1; next }
    in_entries && /^##[[:space:]]+/ { in_entries = 0 }
    in_entries { print }
  ' "$primer" \
    | sed -nE 's/^[[:space:]]*-[[:space:]]*`([^`]+)`.*/\1/p' \
    | while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        entry="$(_pcn_normpath "$entry")"
        [ -n "$entry" ] || continue
        printf '%s\t%s\n' "$slug" "$entry"
      done >> "$INDEX_ENTRY_LIST"
done < "$INDEX_SLUG_LIST"

_pcn_index_covers() {
  local path="$1" slug entry candidate

  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    # Slugs come from a constrained INDEX grammar; reject anything that could
    # be interpreted as a shell pattern in the case expression.
    case "$slug" in *[!A-Za-z0-9._/-]*) continue ;; esac
    case "$path" in
      "$slug"|"$slug"/*|*/"$slug"|*/"$slug"/*) return 0 ;;
    esac
  done < "$INDEX_SLUG_LIST"

  while IFS=$'\t' read -r slug entry; do
    [ -n "$entry" ] || continue
    case "$path" in
      "$entry"|"$entry"/*) return 0 ;;
    esac
  done < "$INDEX_ENTRY_LIST"

  # A file-shaped subsystem (for example src/payments.py) has the same
  # candidate slug as its directory-shaped sibling (src/payments/). Treat an
  # indexed slug as covering both forms.
  candidate="$(_pcn_slug_for_path "$path" 2>/dev/null || true)"
  if [ -n "$candidate" ]; then
    while IFS= read -r slug; do
      [ "$slug" = "$candidate" ] && return 0
    done < "$INDEX_SLUG_LIST"
  fi

  return 1
}

# Pick a stable, useful slug from a repo-relative path. Generic source-layout
# roots are stripped so src/billing/... nudges /primer billing rather than the
# unhelpful /primer src. The output is sanitized to the slug alphabet accepted
# by the /primer command.
_pcn_slug_for_path() {
  local path="$1" first rest candidate
  path="$(_pcn_normpath "$path")"
  case "$path" in
    */*)
      first="${path%%/*}"
      rest="${path#*/}"
      ;;
    *)
      first="$path"
      rest=""
      ;;
  esac

  case "$first" in
    src|lib|app|apps|pkg|packages|package|modules|module|services|service|components|component|internal|cmd|server|client|backend|frontend|core|core-rules|tests|test|spec|specs|docs|scripts|config|configs|fixtures|examples|example|bin|build|dist|public|static)
      if [ -n "$rest" ]; then candidate="${rest%%/*}"; else candidate="$first"; fi
      ;;
    *)
      candidate="$first"
      ;;
  esac

  candidate=$(printf '%s' "$candidate" \
    | sed -E 's/\.[^./]+$//; s/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//')
  case "$candidate" in
    ''|.|..|.claude|.codex|primers|INDEX) return 1 ;;
  esac
  printf '%s' "$candidate"
}

# Documentation and harness-state paths are not subsystems. For all other
# changed paths, collect unique uncovered slugs and cap the message so a broad
# refactor remains a small advisory.
MISSING_SLUGS=""
while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    .claude/*|.codex/*) continue ;;
  esac
  _pcn_doc_path "$path" && continue
  path="$(_pcn_normpath "$path")"
  _pcn_index_covers "$path" && continue

  slug="$(_pcn_slug_for_path "$path" 2>/dev/null || true)"
  [ -n "$slug" ] || continue
  case $'\n'"${MISSING_SLUGS}"$'\n' in
    *$'\n'"$slug"$'\n'*) continue ;;
  esac
  if [ -n "$MISSING_SLUGS" ]; then MISSING_SLUGS="${MISSING_SLUGS}"$'\n'; fi
  MISSING_SLUGS="${MISSING_SLUGS}${slug}"
  [ "$(printf '%s\n' "$MISSING_SLUGS" | awk 'END { print NR }')" -ge 5 ] && break
done < "$CHANGED_FILE_LIST"

[ -n "$MISSING_SLUGS" ] || exit 0

NUDGES=""
while IFS= read -r slug; do
  [ -n "$slug" ] || continue
  if [ -n "$NUDGES" ]; then NUDGES="${NUDGES}; "; fi
  NUDGES="${NUDGES}/primer ${slug}"
done <<EOF
$MISSING_SLUGS
EOF

MESSAGE="primer-capture-nudge: edit-heavy changes touched subsystem(s) without an INDEX primer. Consider ${NUDGES} to capture the context."
jq -nc --arg ctx "$MESSAGE" '{additionalContext: $ctx}'
exit 0
