#!/usr/bin/env bats
# r151-sol H1(a): process-gate verdicts live in $TRELLIS_HOME/state/gate-verdicts,
# which agent tools cannot write: both reread-guard twins deny a Write or Edit
# target there, and both block-destructive twins deny shell writes and removals
# that name it. (Native: read_state.rs; pi: native-guards.test.mjs.)
# Every fixture lives under $BATS_TEST_TMPDIR; TRELLIS_HOME is private.

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  unset TRELLIS_REREAD_OVERRIDE TRELLIS_ROOT CODEX_PROJECT_DIR TRELLIS_HARNESS
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export TRELLIS_HOME="$TMP/trellis-home"
  STORE="$TRELLIS_HOME/state/gate-verdicts"
  mkdir -p -m 700 "$STORE/verdicts" "$STORE/logs"
  PROJECT_DIR="$TMP/project"
  mkdir "$PROJECT_DIR"
  git -C "$PROJECT_DIR" init -q
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
  printf '{}' > "$STORE/verdicts/existing.json"
  ln -s "$TRELLIS_HOME/state" "$TMP/alias"
}

# edit <claude|codex> <tool> <target> → status, output
edit() {
  local script="$REPO/core-rules/hooks/reread-guard.sh" input
  if [ "$1" = codex ]; then
    script="$REPO/core-rules/codex/hooks/reread-guard.sh"
    export CODEX_PROJECT_DIR="$PROJECT_DIR" TRELLIS_ROOT="$REPO"
  fi
  if [ "$2" = Edit ]; then
    input="$(jq -nc --arg t "$3" --arg cwd "$PROJECT_DIR" \
      '{session_id: "gv", cwd: $cwd, tool_name: "Edit", tool_input: {file_path: $t, old_string: "{", new_string: "["}}')"
  else
    input="$(jq -nc --arg t "$3" --arg cwd "$PROJECT_DIR" \
      '{session_id: "gv", cwd: $cwd, tool_name: "Write", tool_input: {file_path: $t, content: "{}"}}')"
  fi
  run bash "$script" <<<"$input"
}

@test "agent Write and Edit into the verdict store are denied by both reread-guards" {
  for target in "$STORE/verdicts/existing.json" "$STORE/verdicts/forged.json" "$STORE/logs/x.log" \
    "$STORE/reuse-disabled" "$STORE" "$TRELLIS_HOME/State/Gate-Verdicts/verdicts/k.json"; do
    for tool in Write Edit; do
      TRELLIS_REREAD_OVERRIDE=1 edit claude "$tool" "$target"
      [ "$status" -eq 0 ] && [[ "$output" == *'"permissionDecision":"deny"'* ]] || { echo "claude $tool $target: $output"; false; }
      [[ "$output" == *"written only by the process gate"* ]] || { echo "claude $tool $target reason: $output"; false; }
      TRELLIS_REREAD_OVERRIDE=1 edit codex "$tool" "$target"
      [ "$status" -eq 2 ] && [[ "$output" == *'"decision":"block"'* ]] || { echo "codex $tool $target: $status $output"; false; }
    done
  done
  # A neighbouring name is an ordinary target.
  printf 'x\n' > "$TRELLIS_HOME/state/gate-verdicts-notes"
  edit claude Write "$TRELLIS_HOME/state/gate-verdicts-notes"
  [[ "$output" != *"written only by the process gate"* ]] || { echo "neighbour: $output"; false; }
}

# r151-reuse2 Sol N1: another name for a stored file is still the stored file.
# A hard link made through the symlinked state parent, a plain hard link, a
# symlink to a stored file and a write through the symlinked parent are all
# refused, with the operator override set; an unrelated multi-link file is not.
@test "Write and Edit through a hard link, symlink or aliased parent of a stored file are denied" {
  printf '{}' > "$STORE/logs/x.log"
  mkdir -p "$TRELLIS_HOME/state/reread-overrides"
  printf 'r\n' > "$TRELLIS_HOME/state/reread-overrides/0123456789abcdef"
  ln "$TMP/alias/gate-verdicts/verdicts/existing.json" "$PROJECT_DIR/via-alias.json"
  ln "$STORE/logs/x.log" "$PROJECT_DIR/linked.log"
  ln -s "$STORE/logs/x.log" "$PROJECT_DIR/symlinked.log"
  ln "$TRELLIS_HOME/state/reread-overrides/0123456789abcdef" "$PROJECT_DIR/record"
  wrong=()
  for target in "$PROJECT_DIR/via-alias.json" "$PROJECT_DIR/linked.log" "$PROJECT_DIR/symlinked.log" \
    "$TMP/alias/gate-verdicts/verdicts/existing.json" "$TMP/alias/./gate-verdicts/verdicts/new.json" \
    "$PROJECT_DIR/record"; do
    want="written only by the process gate"
    [ "$target" != "$PROJECT_DIR/record" ] || want="written only by trellis reread override"
    for tool in Write Edit; do
      TRELLIS_REREAD_OVERRIDE=1 edit claude "$tool" "$target"
      [ "$status" -eq 0 ] && [[ "$output" == *'"permissionDecision":"deny"'* && "$output" == *"$want"* ]] ||
        wrong+=("claude $tool $target")
      TRELLIS_REREAD_OVERRIDE=1 edit codex "$tool" "$target"
      [ "$status" -eq 2 ] && [[ "$output" == *'"decision":"block"'* && "$output" == *"$want"* ]] ||
        wrong+=("codex $tool $target")
    done
  done
  printf 'x\n' > "$PROJECT_DIR/plain"
  ln "$PROJECT_DIR/plain" "$PROJECT_DIR/plain-twin"
  for hooks in claude codex; do
    TRELLIS_REREAD_OVERRIDE=1 edit "$hooks" Write "$PROJECT_DIR/plain-twin"
    [ "$status" -eq 0 ] && [[ "$output" != *"written only by"* ]] || wrong+=("$hooks plain-twin")
  done
  [ "${#wrong[@]}" -eq 0 ] || { printf 'wrong: %s\n' "${wrong[@]}"; false; }
}

@test "shell commands naming the verdict store or its parents are denied unless every command is read-only" {
  wrong=()
  for hooks in core-rules/hooks core-rules/codex/hooks; do
    for cmd in \
      "printf '{}' > ~/.trellis/state/gate-verdicts/verdicts/k.json" \
      "printf x 1>> \"\$TRELLIS_HOME/state/gate-verdicts/logs/x.log\"" \
      "echo x | tee \$TRELLIS_HOME/state/gate-verdicts/verdicts/k.json" \
      "cp /tmp/forged.json ~/.trellis/state/gate-verdicts/verdicts/" \
      "python3 -c 'open(\"/h/.trellis/state/gate-verdicts/verdicts/k.json\",\"w\")'" \
      "rm -f ~/.trellis/state/gate-verdicts/reuse-disabled" \
      "cd ~/.trellis/state/gate-verdicts && rm -f reuse-disabled" \
      "cd ~/.trellis/state/gate-verdicts && printf x 1>verdicts/k.json" \
      "printf x > ~/.trellis/STATE/Gate-Verdicts/k" \
      "unlink \$TRELLIS_HOME/state/./gate-verdicts/reuse-disabled" \
      "ln \$TRELLIS_HOME/../alias/gate-verdicts/verdicts/existing.json k.json" \
      "mv \$TRELLIS_HOME/state \$TRELLIS_HOME/state-backup" \
      "cd \$TRELLIS_HOME && mv state/ state-backup" \
      "tar -xf /tmp/evil.tar -C \$TRELLIS_HOME/state/gate-verdicts" \
      "unzip -o /tmp/evil.zip -d ~/.trellis/state/gate-verdicts/verdicts" \
      "patch ~/.trellis/state/gate-verdicts/verdicts/k.json < /tmp/p.diff" \
      "rename 's/state/state-backup/' ~/.trellis/state" \
      "chown nobody ~/.trellis/state/gate-verdicts/verdicts/k.json" \
      "tar -xf /tmp/evil.tar -C ~/.trellis/state/x" \
      "cat ~/.trellis/state/gate-verdicts/verdicts/k.json | tee /tmp/k"; do
      run bash "$REPO/$hooks/block-destructive.sh" <<<"$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')"
      [[ "$output$status" == *deny* || "$output$status" == *block* || "$status" = 2 ]] || wrong+=("$hooks: $cmd -> $status")
    done
    [ "${#wrong[@]}" -eq 0 ] || { printf 'wrong: %s\n' "${wrong[@]}"; false; }
    for cmd in "ls ~/.trellis/state/gate-verdicts 2>/dev/null" \
      "cat ~/.trellis/state/gate-verdicts/logs/x.log 2>&1 1>&2" \
      "grep -rn state/gate-verdicts scripts 2>/dev/null" \
      "cat ~/.trellis/state/gate-verdicts/verdicts/k.json" \
      "ls -la \$TRELLIS_HOME/state && jq . ~/.trellis/state/gate-verdicts/verdicts/k.json"; do
      run bash "$REPO/$hooks/block-destructive.sh" <<<"$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')"
      [ "$status" -eq 0 ] && [[ "$output" != *deny* ]] || { echo "$hooks: $cmd -> $status $output"; false; }
    done
  done
}

@test "the gate's own store path is the guarded one" {
  run env -u TRELLIS_GATE_STATE_DIR python3 -I -c '
import sys; sys.path.insert(0, sys.argv[1])
import gate_verdict; print(gate_verdict.command_store())' "$REPO/scripts/lib"
  [ "$status" -eq 0 ] && [ "$output" = "$STORE" ] || { echo "$output"; false; }
}
