#!/usr/bin/env bats
# Stack validators and their code (B0-4). Project validators run only as their
# range-BASE copies under the trusted root run-all.sh builds: both twins'
# process-gate-local trees, each named validator and each
# PROCESS_GATE_VALIDATOR_DEPS path. Validator paths are classified against the
# physical project root, so `.`/`..` spellings and symlinked aliases map to
# the same project file; an absolute validator outside the project is refused.
# A validator may source only trusted code: a missing sibling, a cwd-relative
# or project helper fails it. Fixture: config-fixture.bash.

load config-fixture

setup() {
  config_fixture_setup
}

# alias_case <validator spelling>: base scripts/check.sh fails; the range
# makes it pass. The base copy must run and the change must be detected.
alias_case() {
  stack_config "$1"
  put scripts/check.sh $'echo BASE-RAN\nexit 1\n'
  commit_all 'base validator' || return 1
  feature
  put scripts/check.sh $'echo HEAD-RAN\nexit 0\n'
  commit_all 'neuter validator' || return 1

  run_gate push
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"BASE-RAN"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"HEAD-RAN"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"changed: scripts/check.sh"* ]] || { echo "$output"; return 1; }
}

@test "an absolute validator spelled with /./ and .. runs its base copy" {
  local parent="${PROJECT_DIR%/*}" name="${PROJECT_DIR##*/}"
  alias_case "$parent/./$name/scripts/../scripts/check.sh"
}

@test "an absolute validator through a symlinked alias of the project runs its base copy" {
  ln -s "$PROJECT_DIR" "$BATS_TEST_TMPDIR/alias"
  alias_case "$BATS_TEST_TMPDIR/alias/scripts/check.sh"
}

@test "an absolute validator outside the project is refused" {
  printf '#!/usr/bin/env bash\necho EXTERNAL-RAN\nexit 0\n' > "$BATS_TEST_TMPDIR/external.sh"
  stack_config "$BATS_TEST_TMPDIR/external.sh"
  commit_all 'external validator' || return 1

  run_gate push
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"Stack profile:"*"fail"* ]] || { echo "$output"; false; }
  [[ "$output" == *"validator refused: $BATS_TEST_TMPDIR/external.sh is outside the project (unsupported)"* ]] || { echo "$output"; false; }
  [[ "$output" != *"EXTERNAL-RAN"* ]] || { echo "$output"; false; }
}

@test "a mode-644 base validator runs without an exec bit" {
  local marker="$BATS_TEST_TMPDIR/invoked"
  stack_config "$PROJECT_DIR/scripts/check.sh"
  put scripts/check.sh "printf invoked > '$marker'"$'\n'
  chmod 644 "$PROJECT_DIR/scripts/check.sh"
  commit_all 'mode 644 validator' || return 1
  [ "$(git -C "$PROJECT_DIR" ls-tree HEAD scripts/check.sh | cut -c1-6)" = 100644 ]

  run_gate push
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$marker")" = invoked ]
}

@test "a validator's sibling helper comes from the base tree" {
  stack_config validators/check.sh
  put .claude/skills/process-gate-local/validators/check.sh $'. "$(dirname "$0")/lib.sh"\nverdict\n'
  put .claude/skills/process-gate-local/validators/lib.sh $'verdict() { echo BASE-LIB; exit 1; }\n'
  commit_all 'validator with sibling' || return 1
  feature
  put .claude/skills/process-gate-local/validators/lib.sh $'verdict() { echo HEAD-LIB; exit 0; }\n'
  commit_all 'neuter sibling' || return 1

  run_gate push
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"BASE-LIB"* ]] || { echo "$output"; false; }
  [[ "$output" != *"HEAD-LIB"* ]] || { echo "$output"; false; }
  [[ "$output" == *"changed: .claude/skills/process-gate-local/validators/lib.sh"* ]] || { echo "$output"; false; }
}

@test "a validator whose sibling is not in the trusted tree fails instead of continuing" {
  stack_config ../../../scripts/check.sh
  put scripts/check.sh $'. "$(dirname "$0")/lib.sh"\necho CONTINUED\nexit 0\n'
  put scripts/lib.sh $'echo lib loaded\n'
  commit_all 'validator outside the tree' || return 1

  run_gate push
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"Stack profile:"*"fail"* ]] || { echo "$output"; false; }
  [[ "$output" == *"is missing from the trusted validator tree"* ]] || { echo "$output"; false; }
  [[ "$output" != *"CONTINUED"* ]] || { echo "$output"; false; }
}

@test "a validator sourcing a cwd-relative project helper fails" {
  stack_config validators/check.sh
  put .claude/skills/process-gate-local/validators/check.sh $'. scripts/validator-lib.sh\nverdict\n'
  put scripts/validator-lib.sh $'verdict() { echo BASE-HELPER; exit 1; }\n'
  commit_all 'cwd-relative helper' || return 1
  feature
  put scripts/validator-lib.sh $'verdict() { echo HEAD-HELPER; exit 0; }\n'
  commit_all 'neuter helper' || return 1

  run_gate push
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"validator dependency scripts/validator-lib.sh is outside the trusted validator tree"* ]] || { echo "$output"; false; }
  [[ "$output" != *"HEAD-HELPER"* ]] || { echo "$output"; false; }
}

@test "a validator sourcing an absolute project helper fails" {
  stack_config validators/check.sh
  put .claude/skills/process-gate-local/validators/check.sh $'. "$CLAUDE_PROJECT_DIR/scripts/helper.sh"\nverdict\n'
  put scripts/helper.sh $'verdict() { echo BASE-HELPER; exit 1; }\n'
  commit_all 'absolute helper' || return 1
  feature
  put scripts/helper.sh $'verdict() { echo HEAD-HELPER; exit 0; }\n'
  commit_all 'neuter helper' || return 1

  run_gate push
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"/scripts/helper.sh is outside the trusted validator tree"* ]] || { echo "$output"; false; }
  [[ "$output" != *"HEAD-HELPER"* ]] || { echo "$output"; false; }
}

@test "a declared validator dependency runs from the base, whatever the caller exports" {
  local body
  body='PROCESS_GATE_STACK_PROFILE="custom"'$'\n''PROCESS_GATE_STACK_VALIDATORS=("validators/check.sh")'$'\n''PROCESS_GATE_VALIDATOR_DEPS=("scripts/lister.sh")'$'\n'
  put "$CFG" "$body"
  put .claude/skills/process-gate-local/validators/check.sh $'bash "$PG_TRUSTED_ROOT/scripts/lister.sh"\n'
  put scripts/lister.sh $'echo BASE-LISTER\nexit 1\n'
  commit_all 'declared dependency' || return 1
  feature
  put scripts/lister.sh $'echo HEAD-LISTER\nexit 0\n'
  commit_all 'neuter lister' || return 1
  mkdir -p "$BATS_TEST_TMPDIR/evil/scripts"
  printf 'echo EVIL-LISTER\nexit 0\n' > "$BATS_TEST_TMPDIR/evil/scripts/lister.sh"

  run bash -c "cd '$PROJECT_DIR' && PG_TRUSTED_ROOT='$BATS_TEST_TMPDIR/evil' '$STUB/scripts/run-all.sh' --mode=push --range=main..HEAD"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"BASE-LISTER"* ]] || { echo "$output"; false; }
  [[ "$output" != *"HEAD-LISTER"* && "$output" != *"EVIL-LISTER"* ]] || { echo "$output"; false; }
  [[ "$output" == *"changed: scripts/lister.sh"* ]] || { echo "$output"; false; }
}

@test "a declared validator dependency missing at the base is BLOCKED" {
  put "$CFG" $'PROCESS_GATE_VALIDATOR_DEPS=("scripts/absent.sh")\n'
  commit_all 'dangling dependency' || return 1
  run_gate push
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"process-gate validator dependency scripts/absent.sh is missing at range base"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
}

@test "a named validator with an unusual filename runs its base copy and its change is detected" {
  local name='scripts/chéck "q" v.sh'
  stack_config "../../../$name"
  put "$name" $'echo BASE-RAN\nexit 1\n'
  commit_all 'odd validator name' || return 1
  feature
  put "$name" $'echo HEAD-RAN\nexit 0\n'
  commit_all 'neuter odd validator' || return 1

  run_gate push
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"BASE-RAN"* ]] || { echo "$output"; false; }
  [[ "$output" != *"HEAD-RAN"* ]] || { echo "$output"; false; }
  [[ "$output" == *"changed: $name"* ]] || { echo "$output"; false; }
}

@test "a base validator that is a symlink is refused" {
  stack_config ../../../scripts/check.sh
  put scripts/real.sh $'echo LINK-TARGET-RAN\nexit 0\n'
  ln -s real.sh "$PROJECT_DIR/scripts/check.sh"
  commit_all 'symlinked validator' || return 1

  run_gate push
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"validator refused: scripts/check.sh at the range base is not a regular file"* ]] || { echo "$output"; false; }
  [[ "$output" != *"LINK-TARGET-RAN"* ]] || { echo "$output"; false; }
}

# Validator identity is fixed by the base tree. The range swaps the
# validator's parent directory for an in-project symlink to a passing base
# script; the configured base validator must still run, and the swap counts as
# a gate-config change.
@test "a range that symlinks a validator's parent still runs the configured base validator" {
  stack_config "$PROJECT_DIR/scripts/check.sh"
  put scripts/check.sh $'echo BASE-RAN\nexit 1\n'
  put benign/check.sh $'echo BENIGN-RAN\nexit 0\n'
  commit_all 'validator and a benign script' || return 1
  feature
  git -C "$PROJECT_DIR" rm -rq scripts
  ln -s benign "$PROJECT_DIR/scripts"
  commit_all 'redirect scripts/ to benign/' || return 1
  local head
  head="$(head_sha)"

  run_gate push
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"BASE-RAN"* ]] || { echo "$output"; false; }
  [[ "$output" != *"BENIGN-RAN"* ]] || { echo "$output"; false; }
  [[ "$output" == *"changed: scripts/check.sh"* ]] || { echo "$output"; false; }

  run_gate merge
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"no single open PR has head $head"* ]] || { echo "$output"; false; }

  run bash -c "cd '$PROJECT_DIR' && '$STUB/scripts/run-all.sh' --mode=merge --range=main..HEAD --target=main"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"cannot change gate config, approved or not"* ]] || { echo "$output"; false; }
}

# rc_name_case <config body> <path>: the base names <path> (a validator or a
# declared dependency); the range changes it without touching the config.
rc_name_case() {
  put "$CFG" "$1"
  put "$2" $'echo BASE-CODE\nexit 0\n'
  commit_all "base names $2" || return 1
  feature
  put "$2" $'echo HEAD-CODE\nexit 0\n'
  commit_all "change $2" || return 1
  local head
  head="$(head_sha)"

  run_gate push
  [[ "$output" == *"changed: $2"* ]] || { echo "$output"; return 1; }
  run_gate merge
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"no single open PR has head $head"* ]] || { echo "$output"; return 1; }
}

@test "a validator named rc=0 is change-detected" {
  rc_name_case $'PROCESS_GATE_STACK_PROFILE="custom"\nPROCESS_GATE_STACK_VALIDATORS=("../../../rc=0")\n' 'rc=0'
}

@test "a validator named rc=validator.sh is change-detected" {
  rc_name_case $'PROCESS_GATE_STACK_PROFILE="custom"\nPROCESS_GATE_STACK_VALIDATORS=("../../../rc=validator.sh")\n' 'rc=validator.sh'
}

@test "a declared root dependency named rc=helper.sh is change-detected" {
  rc_name_case $'PROCESS_GATE_VALIDATOR_DEPS=("rc=helper.sh")\n' 'rc=helper.sh'
}

@test "a sourced sibling sees the validator's range and shares the caller's scope" {
  stack_config validators/check.sh
  put .claude/skills/process-gate-local/validators/lib.sh $'LIB_ARG="${1-}"\nname=LIB-NAME\nroot=LIB-ROOT\nphys=LIB-PHYS\n'
  put .claude/skills/process-gate-local/validators/check.sh \
    $'. "$(dirname "$0")/lib.sh"\n[ "$LIB_ARG" = "--range=main..HEAD" ] || { echo "lib saw [$LIB_ARG]"; exit 1; }\n[ "$name/$root/$phys" = LIB-NAME/LIB-ROOT/LIB-PHYS ] || { echo "scope lost [$name/$root/$phys]"; exit 1; }\necho SOURCE-OK\n'
  commit_all 'sibling reads its args' || return 1

  run_gate push
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"lib saw"* && "$output" != *"scope lost"* ]] || { echo "$output"; false; }
}

@test "a sourced sibling with explicit arguments sees exactly those" {
  stack_config validators/check.sh
  put .claude/skills/process-gate-local/validators/lib.sh $'LIB_ARGS="$#:${1-}:${2-}"\n'
  put .claude/skills/process-gate-local/validators/check.sh \
    $'. "$(dirname "$0")/lib.sh" one two\n[ "$LIB_ARGS" = "2:one:two" ] || { echo "lib saw [$LIB_ARGS]"; exit 1; }\n'
  commit_all 'sibling with explicit args' || return 1

  run_gate push
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "a declared mode-755 helper is directly executable; an undeclared one fails the validator" {
  local body
  body='PROCESS_GATE_STACK_PROFILE="custom"'$'\n''PROCESS_GATE_STACK_VALIDATORS=("validators/check.sh")'$'\n''PROCESS_GATE_VALIDATOR_DEPS=("scripts/helper.sh")'$'\n'
  put "$CFG" "$body"
  put scripts/helper.sh $'#!/usr/bin/env bash\necho HELPER-RAN\n'
  chmod 755 "$PROJECT_DIR/scripts/helper.sh"
  put .claude/skills/process-gate-local/validators/check.sh \
    $'"$PG_TRUSTED_ROOT/scripts/helper.sh" || exit 1\necho EXEC-OK\n'
  commit_all 'executable helper' || return 1
  [ "$(git -C "$PROJECT_DIR" ls-tree HEAD scripts/helper.sh | cut -c1-6)" = 100755 ]

  run_gate push
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  put .claude/skills/process-gate-local/validators/check.sh \
    $'"$PG_TRUSTED_ROOT/scripts/undeclared.sh" || exit 1\necho CONTINUED\nexit 0\n'
  commit_all 'undeclared helper' || return 1
  run_gate push
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" != *"CONTINUED"* ]] || { echo "$output"; false; }
}

# Validators run from the base copy, but against the checkout under test:
# PROCESS_GATE_PROJECT_DIR names it and is their cwd, wherever run-all was
# started from. A validator that finds the project from its own path sees the
# private copy instead (the break UPGRADING describes).
checkout_validator_case() {
  stack_config validators/check.sh
  put .claude/skills/process-gate-local/validators/check.sh "$1"
  commit_all 'checkout-aware validator' || return 1
  printf 'only in the checkout\n' > "$PROJECT_DIR/checkout-only.txt"
  mkdir -p "$PROJECT_DIR/sub"
  run bash -c "cd '$PROJECT_DIR/sub' && '$STUB/scripts/run-all.sh' --mode=push --range=main..HEAD"
}

@test "a validator reaches the checkout through PROCESS_GATE_PROJECT_DIR" {
  checkout_validator_case $'cd "$PROCESS_GATE_PROJECT_DIR" || exit 1\n[ -f checkout-only.txt ] || { echo "no checkout file"; exit 1; }\n'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "a validator's cwd is the checkout under test" {
  local seen="$BATS_TEST_TMPDIR/pwd-seen"
  checkout_validator_case "printf '%s\\n%s\\n' \"\$PWD\" \"\$PROCESS_GATE_PROJECT_DIR\" > '$seen'"$'\n'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cd "$(sed -n 1p "$seen")" && pwd -P)" = "$(cd "$PROJECT_DIR" && pwd -P)" ] || { cat "$seen"; false; }
  [ "$(sed -n 1p "$seen")" = "$(sed -n 2p "$seen")" ] || { cat "$seen"; false; }
}

@test "a validator that finds the project from its own path sees the private copy" {
  checkout_validator_case $'root="$(cd "$(dirname "$0")/../../../.." && pwd)"\nif [ -f "$root/checkout-only.txt" ]; then echo SEES-CHECKOUT; else echo PRIVATE-COPY; fi\nexit 1\n'
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"PRIVATE-COPY"* ]] || { echo "$output"; false; }
  [[ "$output" != *"SEES-CHECKOUT"* ]] || { echo "$output"; false; }
}
