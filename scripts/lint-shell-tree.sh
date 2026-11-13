#!/usr/bin/env bash
# Lint the repository's shell tree at severity=warning.
#
# Single source of truth for what "the shell tree" means. `scripts/run-tests.sh`
# (= PROCESS_GATE_TEST_CMD) and `.github/workflows/shellcheck.yml` each carried
# their own copy of the same `find`, and both copies matched on suffix only:
# `*.sh` and `*.bash`. Every extensionless script was therefore unlinted — which
# is not an edge case here, it is the pre-push gate itself
# (`core-rules/githooks/pre-push`, `core-rules/husky/pre-push`), the two
# `commit-msg` twins, `core-rules/husky/pre-commit`, `core-rules/githooks/post-checkout`,
# and the `trellis` CLI entrypoint. The
# security-gate diff scanner then justified its own scope with the claim that
# "the repository lints its whole shell tree at severity=warning"; the claim was
# false for exactly the files with the most authority in the repository.
#
# Extensionless files are classified by shebang rather than by name, so the set
# needs no hand-kept list and a new hook is covered the moment it lands.
#
# core-rules/evals/ stays carved out: those are eval fixture seeds — illustrative
# drifted or older hook bodies a check is graded against, not shipped code.
# `.claude/worktrees/` stays carved out: those are detached git worktrees whose
# shell files are not part of the main checkout's tree and must not poison the
# process-gate shellcheck (21 wf_* trees ≈ 3400 sh files as of 2026-08-19).
# `.claude/skills`, hooks, and settings remain in the tree.
# `.claude/skills/security-gate-local/local.config.sh` pins the security gate's
# ShellCheck scope to the same carve-out so the two gates agree.
#
# Assignment guard: a bounded lexical check of temporary command prefixes in
# redirected $(...) and backticks, including nested/multiline forms, conservative
# pipeline redirects, and recognizable generated-shell heredocs. It scans this
# same shell tree, including extensionless shell scripts, but not .bats files.
# It does not follow helper calls, eval, or bash -c strings, nor later quoted
# chunks of the multi-heredoc attachment dispatcher; complex shell syntax may
# also escape it. This is a guard, not a full shell parser or execution proof.
#
# Usage: lint-shell-tree.sh [--list|--write-assignment-baseline] (from repo root)
# Review the working tree and resulting JSON diff before accepting a regenerated
# baseline. Locale assignments are never admitted; see the scanner's --help.

set -uo pipefail

MODE=lint
case "${1:-}" in
  --list) MODE=list ;;
  --write-assignment-baseline) MODE=write-baseline ;;
  "") ;;
  *) printf 'lint-shell-tree: unknown argument: %s\n' "$1" >&2; exit 64 ;;
esac

ROOTS=(core-rules/ scripts/ scheduled-tasks/ local/ .claude/ specs/)

# Exit 0 when the first line of $1 is a `#!` naming a dialect ShellCheck accepts.
# `env` is resolved through to the real interpreter and its flags are skipped, so
# `#!/usr/bin/env -S bash` classifies as bash. `#!/usr/bin/env bats` and
# `#!/usr/bin/env python3` do not classify as shell.
shebang_is_shell() {
  # Bounded read: only the shebang line can matter, and a changed file may be a
  # large binary. LC_ALL=C: under a UTF-8 locale macOS awk aborts with "towc:
  # multibyte conversion failure" on binary bytes (the shipped
  # core-rules/native/*/trellis-hooks), which would fail the whole stage.
  local kind
  kind="$(head -c 256 "$1" | /usr/bin/env LC_ALL=C awk '
       NR == 1 {
         sub(/\r$/, "")
         if ($0 ~ /^#!/) {
           sub(/^#![ \t]*/, "")
           interp = $1
           if (interp ~ /(^|\/)env$/) {
             for (i = 2; i <= NF; i++) { if ($i !~ /^-/) { interp = $i; break } }
           }
           sub(/.*\//, "", interp)
           if (interp ~ /^(sh|bash|dash|ksh)$/) shell = 1
         }
         exit
       }
       END { print shell ? "shell" : "other" }')" || return 2
  case "$kind" in
    shell) return 0 ;;
    other) return 1 ;;
    *) return 2 ;;
  esac
}

# `scripts/tests/doctor-fix-common.bash` is Bats context: the byte-identical
# helper half of the doctor-fix.bats split (Spec 064 A1 Decision 0), loaded by
# the doctor-fix-part*.bats files. Bats files are not linted here, and the
# helper keeps that treatment so the split stays byte-identical.
#
# NUL-delimited paths. The two finds are disjoint by construction: `! -name '*.*'`
# admits only basenames with no dot at all, so nothing matched by the suffix pass
# can reappear in the shebang pass.
shell_tree_files() {
  find "${ROOTS[@]}" \
    \( -path 'core-rules/evals' -o -path '.claude/worktrees' \) -prune -o \
    \( \( -name '*.sh' -o -name '*.bash' \) -type f \
       -not -path 'scripts/tests/doctor-fix-common.bash' -print0 \) || {
    printf 'lint-shell-tree: shell-file traversal failed\n' >&2
    return 1
  }

  local file rc ended=0 find_status=""
  # NUL-frame the find status: process substitution otherwise hides its exit.
  while IFS= read -r -d '' file; do
    if [ "$ended" -eq 1 ]; then find_status="$file"; continue; fi
    if [ -z "$file" ]; then ended=1; continue; fi
    rc=0
    shebang_is_shell "$file" || rc=$?
    case "$rc" in
      0) printf '%s\0' "$file" ;;
      1) ;;
      *) printf 'lint-shell-tree: could not classify %s\n' "$file" >&2; return 1 ;;
    esac
  done < <(find "${ROOTS[@]}" \
    \( -path 'core-rules/evals' -o -path '.claude/worktrees' \) -prune -o \
    \( ! -name '*.*' -type f -print0 \); printf '\0%s\0' "$?")
  if [ "$find_status" != 0 ]; then
    printf 'lint-shell-tree: extensionless-file traversal failed\n' >&2
    return 1
  fi
}

if [ "$MODE" = list ]; then
  shell_tree_files | tr '\0' '\n'
  exit $?
fi

# Both checks consume the same complete NUL-framed inventory; traversal or a
# missing/unreadable baseline must never turn into a clean scan. In particular,
# do not use process substitution here: its exit status would be lost.
inventory="$(mktemp "${TMPDIR:-/tmp}/trellis-shell-tree.XXXXXXXX")" || exit 1
trap 'rm -f -- "$inventory"' EXIT
shell_tree_files > "$inventory" || exit 1
scanner=(python3 -I scripts/lint-shell-assignments.py --files0-from "$inventory"
         --baseline scripts/lint-shell-assignments-baseline.json)
if [ "$MODE" = write-baseline ]; then
  "${scanner[@]}" --write-baseline
  exit $?
fi

# A BSD `stat -f` probe with its fallback inside the same command substitution,
# `$(stat -f %Lp f 2>/dev/null || stat -c %a f)`, is wrong on Linux: GNU
# `stat -f` is --file-system, so it prints a filesystem block on stdout before
# failing and the fallback's answer is appended to that block. Probe GNU first
# (BSD `stat -c` fails with nothing on stdout) or give each probe its own
# assignment. ShellCheck skips Bats files and the doctor-fix helper (Bats
# context); this check reads them too. A substitution still open at the end of
# its line is flagged as well, since its fallback may follow there.
STAT_SUBST='\$\([[:space:]]*(command[[:space:]]+)?(/usr/bin/)?stat[[:space:]]+-f[^)]*(\|\||$)'
stat_dialect_check() {
  local list path findings rc=0
  local -a files=()
  list="$(tr '\0' '\n' < "$inventory")" || return 2
  while IFS= read -r path; do
    [ -z "$path" ] || files+=("$path")
  done <<< "$list"
  list="$(find "${ROOTS[@]}" \
    \( -path 'core-rules/evals' -o -path '.claude/worktrees' \) -prune -o \
    \( -name '*.bats' -type f -print \))" || {
    printf 'lint-shell-tree: bats-file traversal failed\n' >&2
    return 2
  }
  while IFS= read -r path; do
    [ -z "$path" ] || files+=("$path")
  done <<< "$list"
  [ ! -f scripts/tests/doctor-fix-common.bash ] || files+=(scripts/tests/doctor-fix-common.bash)
  [ "${#files[@]}" -gt 0 ] || return 0
  findings="$(grep -HnE -- "$STAT_SUBST" "${files[@]}")" || rc=$?
  case "$rc" in
    0) ;;
    1) return 0 ;;
    *) printf 'lint-shell-tree: stat dialect scan failed\n' >&2; return 2 ;;
  esac
  findings="$(printf '%s\n' "$findings" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')" || return 0
  printf '%s\n' "$findings"
  printf 'lint-shell-tree: BSD-first stat -f fallback inside one command substitution (see above); probe GNU first or use separate assignments\n' >&2
  return 1
}

status=0
"${scanner[@]}" || status=1
xargs -0 shellcheck --severity=warning < "$inventory" || status=1
stat_dialect_check || status=1
exit "$status"
