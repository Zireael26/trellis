#!/usr/bin/env bash
# Single source of truth for which bats suites under `scripts/tests/` run, where
# they run, and which are deliberately skipped and why.
#
# Nothing is hand-listed as INCLUDED. The runner globs the directory, so a suite
# is covered the moment it lands. The one hand-maintained list is
# TEST_SUITE_EXCLUSIONS below, and `scripts/tests/suite-coverage.bats` fails when
# a `.bats` file is neither globbed nor named there.
#
# Why the guard exists: `run-tests.sh` (= PROCESS_GATE_TEST_CMD) and
# `.github/workflows/bats.yml` each named their suites by hand, and both lists
# stopped at 20 of 57. The 37 unrun suites were nearly the whole portable-fleet
# surface, and one of them — attachment-contracts-integration — had been red at
# the committed tip for days behind a green "Tests & coverage" row. A hand-kept
# include list fails silently; a glob plus a guarded exclusion list cannot.
#
# Exclusion record format: `<suite>|<scope>|<reason>`
#   scope=all  never run, anywhere
#   scope=ci   runs locally, skipped under GitHub Actions
# `<suite>` is the basename without the `.bats` extension.
#
# The workflow's old hand-list carried a standing claim that "the broader
# scripts/tests/ suite is macOS-developed and carries host-specific assumptions
# not yet hardened for ubuntu CI". That claim was tested rather than inherited.
# T27 ran the doctor lane in ubuntu:24.04 and found three real defects, none of
# them "the suite is macOS-only": a chained `stat -f … || stat -c …` in
# release-store.sh (GNU `-f` is --file-system, so it printed a filesystem block
# on stdout before failing and the block concatenated with the mode), the same
# shape in attachment.sh's mode probe, and a fixture that base64'd without
# `tr -d '\n'` (GNU base64 wraps at 76 columns). T34 found the same chained
# shape in six more suites and unchained them, then ran 32 of the newly-enabled
# suites in ubuntu:24.04. Seven came back red and every one was run down:
# `codex-hooks-enabled` assumed the codex CLI was installed and now stubs it;
# `fleet-dependencies` shelled out to `rg`, which a stock runner does not have,
# and now uses `grep`; `fleet-dependencies` and `codex-effort-preflight` need
# Node, which the workflow now pins; `disk-janitor-lib` has one case that
# simulates the GNU dialect ON TOP OF the BSD binary and is skipped off Darwin;
# `local-registry` and `release-store` each have a case that revokes directory
# permissions, which a ROOT container ignores. That last disposition was a
# PREDICTION about a non-root host, so it was re-run as one: both suites in
# ubuntu:24.04 as an unprivileged user, 97 cases, 0 failures. The prediction
# held, and it is a measurement now. That leaves exactly one genuine host
# dependency, excluded below. A suite belongs here because a run proved it
# cannot pass, never because nobody has tried.
#
# The battery itself had never been executed in a CI-shaped environment when it
# was switched on — every local receipt was macOS on bats 1.13.0, while the
# workflow installs the apt bats, which is 1.10.0 on ubuntu 24.04. It has been
# now: all four shards of `run-tests.sh --scope=ci --shard=k/4` in ubuntu:24.04
# as an unprivileged user on apt bats 1.10.0. Two real defects surfaced and are
# fixed on this branch — a socket fixture built its path from a literal
# `/private/tmp`, which exists only on Darwin, and four intentional patterns
# that shellcheck 0.11.0 accepts are warnings under the 0.9.0 ubuntu ships.
# Three further reds were artifacts of a minimal image rather than of CI: `awk`
# resolving to mawk, whose regex compiler panics on the interval in the writing
# gate, and missing `rsync` and `lsof` — all three of which a GitHub runner
# image provides.

# shellcheck disable=SC2034  # consumed by sourcing runners and the guard suite
TEST_SUITE_EXCLUSIONS=(
  # Verified on ubuntu:24.04 at this tip: 9 cases fail because the installer
  # validates the plist template with macOS `plutil` and probes BSD ACLs on the
  # destination. launchd itself is mocked, but those two boundaries are not, and
  # there is no launchd on a GitHub runner to install into either.
  "install-disk-janitor-launchd|ci|macOS launchd installer: plutil plist validation and BSD ACL probes have no Linux equivalent"
  # The subject is a Darwin-only host runner by design: the installer validates
  # its plist with `plutil` and reads it back with `PlistBuddy`, and the runner
  # takes its lock with macOS `shlock`. None exist on a GitHub Linux runner.
  # This suite never ran in CI before the sharded runner: the old workflow
  # listed suites by hand and omitted it, so the sharded runner did not break
  # it, it revealed it.
  "test-health-launchd|ci|Darwin-only host runner: plutil, PlistBuddy and shlock have no Linux equivalent"
)

# Absolute path of the repository root, derived from this file's location.
test_suites_root() {
  (CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
}

# Every `.bats` file under scripts/tests/, as basenames, sorted.
test_suites_all() {
  local root suite
  root="$(test_suites_root)"
  for suite in "$root"/tests/*.bats; do
    [ -e "$suite" ] || continue
    suite="${suite##*/}"
    printf '%s\n' "${suite%.bats}"
  done | LC_ALL=C sort
}

# Exclusion scope for one suite, or the empty string when it is not excluded.
test_suites_exclusion_scope() {
  local want="$1" record
  for record in ${TEST_SUITE_EXCLUSIONS[@]+"${TEST_SUITE_EXCLUSIONS[@]}"}; do
    [ "${record%%|*}" = "$want" ] || continue
    record="${record#*|}"
    printf '%s\n' "${record%%|*}"
    return 0
  done
  printf '\n'
}

# Suites to run for a scope: `local` or `ci`.
test_suites_for() {
  local scope="${1:-local}" suite excluded
  case "$scope" in
    local|ci) ;;
    *) printf 'test-suites: unknown scope: %s\n' "$scope" >&2; return 64 ;;
  esac
  while IFS= read -r suite; do
    [ -n "$suite" ] || continue
    excluded="$(test_suites_exclusion_scope "$suite")"
    case "$excluded" in
      all) continue ;;
      ci)  if [ "$scope" = "ci" ]; then continue; fi ;;
    esac
    printf '%s\n' "$suite"
  done < <(test_suites_all)
}
