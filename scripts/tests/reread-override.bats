#!/usr/bin/env bats
# Decision 3 option (c): `trellis reread override --session <id> --reason <why>`
# writes a short-lived record under TRELLIS_HOME state; both shell reread-guard
# twins honour it (native: read_state.rs tests), and agents cannot write it
# directly (block-destructive rule + reread-guard target check).
# Every fixture lives under $BATS_TEST_TMPDIR; TRELLIS_HOME is private.

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
GUARD="$REPO/core-rules/hooks/reread-guard.sh"
CODEX_GUARD="$REPO/core-rules/codex/hooks/reread-guard.sh"
SID="reread-override-bats-session"

setup() {
  unset TRELLIS_REREAD_OVERRIDE TRELLIS_ROOT CODEX_PROJECT_DIR TRELLIS_HARNESS
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export TRELLIS_HOME="$TMP/trellis-home"
  mkdir -m 700 "$TRELLIS_HOME"
  PROJECT_DIR="$TMP/project"
  mkdir "$PROJECT_DIR"
  git -C "$PROJECT_DIR" init -q
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
  KEY="$(printf '%s' "$SID" | shasum -a 256 | cut -c1-16)"
  RECORDS="$TRELLIS_HOME/state/reread-overrides"
  TARGET="$PROJECT_DIR/stale.txt"
  printf 'old\n' > "$TARGET"
}

# guard <claude|codex> <target> → status, output, stderr
guard() {
  local script=$GUARD errf="$TMP/stderr"
  # In place from the payload, as the rendered hooks.json runs it.
  [ "$1" = claude ] || { script=$CODEX_GUARD; export CODEX_PROJECT_DIR="$PROJECT_DIR" TRELLIS_ROOT="$REPO"; }
  set +e
  output="$(jq -nc --arg sid "$SID" --arg t "$2" --arg cwd "$PROJECT_DIR" \
      '{session_id: $sid, cwd: $cwd, tool_name: "Write", tool_input: {file_path: $t, content: "x"}}' |
    bash "$script" 2>"$errf")"
  status=$?
  set -e
  stderr="$(cat "$errf")"
}

state_dir() { [ "$1" = claude ] && echo "$PROJECT_DIR/.claude/.reread-state" || echo "$PROJECT_DIR/.codex/.reread-state"; }

@test "CLI writes a private, expiring record and a logged breadcrumb" {
  run "$REPO/scripts/trellis" reread override --session "$SID" --reason "operator-approved stale edit"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"override for session key $KEY active for 600s"* ]]
  [ -f "$RECORDS/$KEY" ]
  [ "$(stat -f %Lp "$RECORDS" 2>/dev/null || stat -c %a "$RECORDS")" = 700 ]
  IFS=$'\t' read -r expires created reason < "$RECORDS/$KEY"
  [ "$((expires - created))" -eq 600 ]
  [ "$reason" = "operator-approved stale edit" ]
  run awk -F '\t' -v k="$KEY" '$2 == k && $4 == "operator-approved stale edit" { n++ } END { print n + 0 }' "$RECORDS/log.tsv"
  [ "$output" = 1 ]
}

@test "CLI refuses missing arguments, control characters and a symlinked state dir" {
  run "$REPO/scripts/trellis" reread override --session "$SID"
  [ "$status" -eq 2 ]
  run "$REPO/scripts/trellis" reread override --reason why
  [ "$status" -eq 2 ]
  run "$REPO/scripts/trellis" reread --session "$SID" --reason why
  [ "$status" -eq 2 ]
  run "$REPO/scripts/trellis" reread override --session "$SID" --reason $'two\nlines'
  [ "$status" -eq 2 ]
  mkdir "$TMP/elsewhere"
  ln -s "$TMP/elsewhere" "$TRELLIS_HOME/state"
  run "$REPO/scripts/trellis" reread override --session "$SID" --reason why
  [ "$status" -eq 5 ]
  [ -z "$(ls -A "$TMP/elsewhere")" ]
}

@test "both shell twins honour a live record as a logged escape and ignore other sessions" {
  for h in claude codex; do
    guard "$h" "$TARGET"
    [ "$status" -eq 0 ] && [[ "$stderr" == *"warn 1/"* ]] || { echo "$h: $status $output $stderr"; false; }
  done
  "$REPO/scripts/trellis" reread override --session "$SID" --reason "bats" 2>/dev/null
  for h in claude codex; do
    guard "$h" "$TARGET"
    [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$h: $status $output $stderr"; false; }
    [[ "$stderr" != *"warn "* ]] || { echo "$h: $stderr"; false; }
    grep -qF -- "OVERRIDE:$TARGET" "$(state_dir "$h")/$KEY.warns.tsv"
  done
  # A record for another session does not reach this one.
  mv "$RECORDS/$KEY" "$RECORDS/0123456789abcdef"
  guard claude "$TARGET"
  [[ "$stderr" == *"warn 2/"* ]] || { echo "$stderr"; false; }
}

@test "both shell twins ignore expired, over-long and symlinked records" {
  mkdir -p "$RECORDS"
  now=$(date +%s)
  for line in "$((now - 1))\t$now\twhy" "$((now + 4000))\t$now\twhy"; do
    printf "$line\n" > "$RECORDS/$KEY"
    for h in claude codex; do
      rm -rf "${PROJECT_DIR:?}/.claude" "${PROJECT_DIR:?}/.codex"
      guard "$h" "$TARGET"
      [[ "$stderr" == *"warn 1/"* ]] || { echo "$h $line: $stderr"; false; }
    done
  done
  rm -f "${RECORDS:?}/$KEY"
  printf '%s\t%s\twhy\n' "$((now + 300))" "$now" > "$TMP/real"
  ln -s "$TMP/real" "$RECORDS/$KEY"
  guard claude "$TARGET"
  [[ "$stderr" == *"warn 1/"* ]] || { echo "$stderr"; false; }
}

@test "both shell twins deny edits inside the record directory, even under an override" {
  "$REPO/scripts/trellis" reread override --session "$SID" --reason "bats" 2>/dev/null
  export TRELLIS_REREAD_OVERRIDE=1
  for t in "$RECORDS/$KEY" "$RECORDS/new" "$RECORDS/../reread-overrides/x" "$TRELLIS_HOME/State/Reread-Overrides/x"; do
    guard claude "$t"
    [ "$status" -eq 0 ] && [[ "$output" == *'"permissionDecision":"deny"'* ]] || { echo "$t: $output"; false; }
    [[ "$output" == *"written only by trellis reread override"* ]]
    guard codex "$t"
    [ "$status" -eq 2 ] && [[ "$output" == *'"decision":"block"'* ]] || { echo "$t: $status $output"; false; }
    [[ "$output" == *"written only by trellis reread override"* ]] || { echo "$t: $output"; false; }
  done
}

@test "block-destructive denies shell writes to the record directory, not the CLI" {
  for engine_hook in core-rules/hooks core-rules/codex/hooks; do
    for cmd in \
      "printf '9999999999\t1\tx\n' > ~/.trellis/state/reread-overrides/0123456789abcdef" \
      "echo x | tee \$TRELLIS_HOME/state/reread-overrides/k" \
      "cp /tmp/r ~/.trellis/state/reread-overrides/k" \
      "python3 -c 'open(\"/h/.trellis/state/reread-overrides/k\",\"w\")'" \
      "printf x 1> \"\$TRELLIS_HOME/state/reread-overrides/0123456789abcdef\"" \
      "printf x 2> \"\$TRELLIS_HOME/state/reread-overrides/0123456789abcdef\"" \
      "printf x 1>>~/.trellis/state/reread-overrides/k" \
      "printf x 3>|~/.trellis/state/reread-overrides/k" \
      "printf x 2>&k ~/.trellis/state/reread-overrides" \
      "printf x 9> /dev/nullx ~/.trellis/state/reread-overrides" \
      "cd ~/.trellis/state/reread-overrides && printf x 1>k" \
      "printf x > ~/.trellis/STATE/Reread-Overrides/k" \
      "echo x | TEE ~/.trellis/State/reread-overrides/k"; do
      run bash "$REPO/$engine_hook/block-destructive.sh" <<<"$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')"
      [[ "$output$status" == *deny* || "$output$status" == *block* || "$status" = 2 ]] || { echo "$engine_hook: $cmd -> $status $output"; false; }
    done
    for cmd in "trellis reread override --session abc --reason 'stale edit approved'" \
      "grep -rn state/reread-overrides scripts 2>/dev/null" \
      "ls ~/.trellis/state/reread-overrides 2> /dev/null | wc -l" \
      "cat ~/.trellis/state/reread-overrides/log.tsv 2>&1 1>&2" \
      "grep -c x ~/.trellis/state/reread-overrides/log.tsv 2>/dev/null; echo done"; do
      run bash "$REPO/$engine_hook/block-destructive.sh" <<<"$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')"
      [ "$status" -eq 0 ] && [[ "$output" != *deny* ]] || { echo "$engine_hook: $cmd -> $status $output"; false; }
    done
  done
}

@test "a failed audit append publishes no override and leaves an earlier record untouched" {
  mkdir -p "$RECORDS/log.tsv"
  run "$REPO/scripts/trellis" reread override --session "$SID" --reason "will fail audit"
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [ ! -e "$RECORDS/$KEY" ] || { echo "override published without an audit row"; false; }
  [ -z "$(find "$RECORDS" -maxdepth 1 -name '.record.*')" ]
  guard claude "$TARGET"
  [[ "$stderr" == *"warn 1/"* ]] || { echo "$stderr"; false; }
  # Replacement: an earlier, audited record is neither extended nor removed.
  now=$(date +%s)
  printf '%s\t%s\tearlier\n' "$((now + 100))" "$now" > "$RECORDS/$KEY"
  cp "$RECORDS/$KEY" "$TMP/earlier"
  run "$REPO/scripts/trellis" reread override --session "$SID" --reason "will fail audit"
  [ "$status" -ne 0 ]
  cmp "$RECORDS/$KEY" "$TMP/earlier"
}

@test "both shell twins honour only the CLI's exact one-row record (qp-native H5)" {
  mkdir -p "$RECORDS"
  now=$(date +%s)
  c=$((now - 100)) e=$((now + 500))
  long=$(printf '%2001s' '' | tr ' ' r)
  # Control: a hand-built record with the CLI's exact shape is honoured.
  printf '%s\t%s\twhy\n' "$e" "$c" > "$RECORDS/$KEY"
  guard claude "$TARGET"
  [ "$status" -eq 0 ] && [[ "$stderr" != *"warn "* ]] || { echo "control: $stderr"; false; }
  for record in "$e\n" "$e\t$c\n" "$e\t$c\t\n" "$e\t$c\twhy\nextra\n" "$e\t$c\twhy\nX" "$e\t$c\twhy\n\n" \
    "$e\t$c\twhy\tmore\n" "$e\t$((c + 1))\twhy\n" "0$e\t0$c\twhy\n" "$e\t$c\twh\033y\n" "$e\t$c\twhy\r\n" \
    "$e\t$c\t$long\n" "$e\t\t$c\twhy\n"; do
    printf "$record" > "$RECORDS/$KEY"
    for h in claude codex; do
      rm -rf "${PROJECT_DIR:?}/.claude" "${PROJECT_DIR:?}/.codex"
      guard "$h" "$TARGET"
      [[ "$stderr" == *"warn 1/"* ]] || { echo "$h $(printf '%q' "$record"): $status $output $stderr"; false; }
    done
  done
}
