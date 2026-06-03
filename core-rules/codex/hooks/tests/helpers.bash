#!/usr/bin/env bash
# Shared helpers for the CODEX bats hook test suite.
# Loaded via `load helpers` from individual .bats files.
#
# DEPLOYED-LAYOUT philosophy (anti-stub mandate — Phase 2a trap re-armed):
# stop-verify.sh resolves its real core via $HOOK_DIR/lib/{deps.sh,pm.sh}
# (sibling to the hook). There is NO separate code-reviewer/ui-verify core for
# stop-verify — those belong to code-review-subagent.sh. So the REAL core here
# is: the actual stop-verify.sh + the actual deps.sh + the actual pm.sh. We
# deploy all three into <tmp>/.codex/hooks/{,lib/} and run the hook from there so
# $HOOK_DIR/lib resolves to the real libs. No stub of any of these.
#
# PORTABLE: no absolute machine paths. Sources are located relative to
# $BATS_TEST_DIRNAME. The canonical Codex hook lives at
# $BATS_TEST_DIRNAME/../stop-verify.sh; its libs at $BATS_TEST_DIRNAME/../lib/;
# the canonical Claude core libs at $BATS_TEST_DIRNAME/../../../hooks/lib/.
#
# POLLUTION INVARIANT (load-bearing): the deployed .codex/hooks/ tree must NOT
# live inside CODEX_PROJECT_DIR, or git ls-files --others would surface the
# deployed .sh files into _se_changed_files (breaking the doc-only skip and
# polluting the fileset hash). We therefore DECOUPLE: the deployment lives under
# $BATS_TEST_TMPDIR/deploy, while CODEX_PROJECT_DIR is a SEPARATE fresh git repo.
# BASH_SOURCE resolves the libs to the deploy copy; the project dir never
# contains the deployment. Transcript fixtures likewise live directly under
# $BATS_TEST_TMPDIR (outside the project dir) so they never enter the set.

# Resolve canonical sources from $BATS_TEST_DIRNAME (= .../codex/hooks/tests).
_codex_hook_src() { printf '%s' "$BATS_TEST_DIRNAME/../stop-verify.sh"; }
_codex_lib_dir()  { printf '%s' "$BATS_TEST_DIRNAME/../lib"; }
# Canonical Claude core libs (deps.sh/pm.sh are byte-identical across harnesses;
# we copy from the Codex sibling lib, but keep this resolver per the CTX note).
_claude_core_lib_dir() { printf '%s' "$BATS_TEST_DIRNAME/../../../hooks/lib"; }

# setup_deployed_hook — build a real deployed layout and a separate project dir.
# Exports:
#   HOOK            absolute path to the deployed stop-verify.sh (run THIS)
#   PROJECT_DIR     a fresh git repo (= CODEX_PROJECT_DIR), the "project root"
#   CODEX_PROJECT_DIR  exported, equals PROJECT_DIR
setup_deployed_hook() {
  local deploy="$BATS_TEST_TMPDIR/deploy/.codex/hooks"
  mkdir -p "$deploy/lib"
  cp "$(_codex_hook_src)" "$deploy/stop-verify.sh"
  # Real libs the hook actually sources (deps.sh + pm.sh). Copy from the Codex
  # sibling lib; these are the same bytes as the canonical Claude core libs.
  cp "$(_codex_lib_dir)/deps.sh" "$deploy/lib/deps.sh"
  cp "$(_codex_lib_dir)/pm.sh"   "$deploy/lib/pm.sh"
  chmod +x "$deploy/stop-verify.sh"
  # HOOK is consumed by the .bats files that `load` this helper, not here.
  # shellcheck disable=SC2034
  HOOK="$deploy/stop-verify.sh"

  # Separate project root: a fresh git repo, NOT containing the deployment.
  PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PROJECT_DIR"
  ( cd "$PROJECT_DIR" && git init -q && git commit --allow-empty -q -m init )
  export CODEX_PROJECT_DIR="$PROJECT_DIR"
  # Defensive: ensure no stray Claude precedence leaks in from the env.
  unset CLAUDE_PROJECT_DIR
}
