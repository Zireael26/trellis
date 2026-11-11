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
# Usage: lint-shell-tree.sh [--list]   (run from the repository root)

set -uo pipefail

LIST_ONLY=0
case "${1:-}" in
  --list) LIST_ONLY=1 ;;
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
  kind="$(head -c 256 "$1" | LC_ALL=C awk '
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

if [ "$LIST_ONLY" -eq 1 ]; then
  shell_tree_files | tr '\0' '\n'
  exit $?
fi

shell_tree_files | xargs -0 shellcheck --severity=warning
