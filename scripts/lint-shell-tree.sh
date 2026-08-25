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

# NUL-delimited paths. The two finds are disjoint by construction: `! -name '*.*'`
# admits only basenames with no dot at all, so nothing matched by the suffix pass
# can reappear in the shebang pass.
shell_tree_files() {
  find "${ROOTS[@]}" \
    \( -name '*.sh' -o -name '*.bash' \) -type f \
    -not -path 'core-rules/evals/*' -print0

  local file
  while IFS= read -r -d '' file; do
    shebang_is_shell "$file" && printf '%s\0' "$file"
  done < <(find "${ROOTS[@]}" \
    ! -name '*.*' -type f \
    -not -path 'core-rules/evals/*' -print0)
}

if [ "$LIST_ONLY" -eq 1 ]; then
  shell_tree_files | tr '\0' '\n'
  exit 0
fi

shell_tree_files | xargs -0 shellcheck --severity=warning
