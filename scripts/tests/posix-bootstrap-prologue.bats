#!/usr/bin/env bats
# Four scripts carry a `#!/bin/sh` POSIX bootstrap whose only job is to `exec` a
# clean `/bin/bash --noprofile --norc` through `env -i`. Everything after the
# `# -- <name> body --` sentinel is Bash and is linted as Bash, because each file
# now carries a `# shellcheck shell=bash` directive.
#
# ShellCheck only honours `shell=` at the top of a file, so that directive also
# stops it from checking the prologue as `sh` — exactly the guarantee that makes
# the bootstrap safe. This suite restores it: extract each prologue and lint it
# as POSIX `sh` on its own. A `local`, an array, or a `$'...'` sneaking into a
# prologue would run under `/bin/sh` and fail on a dash-based system.
#
# The extraction drops the `shell=bash` directive itself; a file directive
# outranks the `-s sh` flag, so leaving it in would make the whole check vacuous.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  WORK="$(mktemp -d)"
}

teardown() {
  if [ -n "${WORK:-}" ] && [ -d "$WORK" ]; then
    rm -rf "$WORK"
  fi
}

# extract_prologue <script> <sentinel> -> writes $WORK/prologue.sh
extract_prologue() {
  local script="$REPO_ROOT/$1" sentinel="$2"
  grep -Fq "$sentinel" "$script"
  # Match the sentinel as a WHOLE LINE. Every one of these scripts also mentions
  # its own sentinel inside the awk program that extracts the body, so a substring
  # cut truncates the prologue mid-quote and the lint reports a parse error instead
  # of a dialect finding.
  awk -v sentinel="$sentinel" '
    $0 == sentinel { exit }
    /^# shellcheck shell=bash$/ { next }
    { print }
  ' "$script" > "$WORK/prologue.sh"
  [ -s "$WORK/prologue.sh" ]
  grep -Fq 'exec /usr/bin/env -i' "$WORK/prologue.sh"
}

lint_as_posix_sh() {
  run shellcheck -s sh --severity=warning -f gcc "$WORK/prologue.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "trellis-launcher.sh prologue is POSIX sh clean" {
  extract_prologue scripts/trellis-launcher.sh '# -- trellis launcher body --'
  lint_as_posix_sh
}

@test "sync-to-template.sh prologue is POSIX sh clean" {
  extract_prologue scripts/sync-to-template.sh '# -- trellis mirror body --'
  lint_as_posix_sh
}

@test "install-disk-janitor-launchd.sh prologue is POSIX sh clean" {
  extract_prologue scripts/install-disk-janitor-launchd.sh '# -- trellis disk janitor launchd body --'
  lint_as_posix_sh
}

@test "upgrade.sh prologue is POSIX sh clean" {
  extract_prologue scripts/upgrade.sh '# -- trellis upgrade body --'
  lint_as_posix_sh
}

@test "the extraction is discriminating: a bashism in a prologue is caught" {
  printf '#!/bin/sh\n# shellcheck shell=bash\nfoo() { local x=1; echo "$x"; }\n# -- trellis launcher body --\n' \
    > "$WORK/fixture.sh"
  awk '
    $0 == "# -- trellis launcher body --" { exit }
    /^# shellcheck shell=bash$/ { next }
    { print }
  ' "$WORK/fixture.sh" > "$WORK/prologue.sh"
  run shellcheck -s sh --severity=warning -f gcc "$WORK/prologue.sh"
  [ "$status" -ne 0 ]
  grep -Fq 'SC3043' <<<"$output"
}

@test "every one of the four still declares shell=bash exactly once" {
  local script
  for script in scripts/trellis-launcher.sh scripts/sync-to-template.sh \
                scripts/install-disk-janitor-launchd.sh scripts/upgrade.sh; do
    [ "$(grep -cFx '# shellcheck shell=bash' "$REPO_ROOT/$script")" -eq 1 ]
  done
}
