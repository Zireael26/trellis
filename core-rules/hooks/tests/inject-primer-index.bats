#!/usr/bin/env bats
# inject-primer-index.bats — regression coverage for the v0.3.1 primer-injection hook.

load helpers

setup() {
  setup_project_dir
  HOOK="$HOOKS_DIR/inject-primer-index.sh"
}

teardown() {
  teardown_project_dir
}

@test "codex-only attachment loads its manifest-rendered agents primer index" {
  mkdir -p "$PROJECT_DIR/.agents/primers"
  printf '%s\n' '- [native](./native.md) — native primer' > "$PROJECT_DIR/.agents/primers/INDEX.md"
  printf '%s\n' '# Native primer' > "$PROJECT_DIR/.agents/primers/native.md"
  run env CODEX_PROJECT_DIR="$PROJECT_DIR" bash "$CODEX_HOOKS_DIR/inject-primer-index.sh" <<< '{"source":"startup"}'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart" and (.hookSpecificOutput.additionalContext | contains("native"))'
  if grep -q MISSING_FILE <<< "$output"; then false; fi
}

@test "codex keeps existing shared primer authority when both indices exist" {
  mkdir -p "$PROJECT_DIR/.agents/primers" "$PROJECT_DIR/.claude/primers"
  printf '%s\n' '- [native](./native.md)' > "$PROJECT_DIR/.agents/primers/INDEX.md"
  printf '%s\n' '- [shared](./shared.md)' > "$PROJECT_DIR/.claude/primers/INDEX.md"
  printf '%s\n' '# Shared primer' > "$PROJECT_DIR/.claude/primers/shared.md"
  run env CODEX_PROJECT_DIR="$PROJECT_DIR" bash "$CODEX_HOOKS_DIR/inject-primer-index.sh" <<< '{"source":"startup"}'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("shared") and (contains("native") | not)'
}

@test "v031: skips silently when INDEX.md absent" {
  run bash -c "echo '{\"source\":\"startup\"}' | CLAUDE_PROJECT_DIR='$PROJECT_DIR' '$HOOK'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "v031: emits FRESH for a primer pinned to HEAD" {
  mkdir -p "$PROJECT_DIR/.claude/primers"
  echo "hello" > "$PROJECT_DIR/foo.txt"
  ( cd "$PROJECT_DIR" && git add foo.txt && git commit -q -m "seed" )
  SHA=$( cd "$PROJECT_DIR" && git rev-parse HEAD )

  cat > "$PROJECT_DIR/.claude/primers/INDEX.md" <<EOF
- [foo](./foo.md) — sample
EOF

  cat > "$PROJECT_DIR/.claude/primers/foo.md" <<EOF
---
slug: foo
pinned_to: $SHA
---
## Entry points
- \`foo.txt\`
EOF

  run bash -c "echo '{\"source\":\"startup\"}' | CLAUDE_PROJECT_DIR='$PROJECT_DIR' '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"foo — FRESH"* ]]
}

# Lean C04: startup no longer counts commits (`rev-list <pin>..HEAD -- paths`
# walked the commit graph once per primer and hit the 5 s timeout on deep
# histories). It compares the entry-point trees at the pin and HEAD instead;
# /primer-check still produces the WARM/STALE commit count on demand.
@test "C04: entry points that differ from the pin are CHANGED, not counted (both twins)" {
  local hook
  mkdir -p "$PROJECT_DIR/.claude/primers"
  echo "v1" > "$PROJECT_DIR/foo.txt"
  ( cd "$PROJECT_DIR" && git add foo.txt && git commit -q -m "seed" )
  SHA=$( cd "$PROJECT_DIR" && git rev-parse HEAD )

  for i in $(seq 2 13); do
    echo "v$i" > "$PROJECT_DIR/foo.txt"
    ( cd "$PROJECT_DIR" && git add foo.txt && git commit -q -m "bump $i" )
  done

  cat > "$PROJECT_DIR/.claude/primers/INDEX.md" <<EOF
- [foo](./foo.md) — sample
EOF
  cat > "$PROJECT_DIR/.claude/primers/foo.md" <<EOF
---
slug: foo
pinned_to: $SHA
---
## Entry points
- \`foo.txt\`
EOF

  for hook in "$HOOK" "$CODEX_HOOKS_DIR/inject-primer-index.sh"; do
    run bash -c "echo '{\"source\":\"startup\"}' | CLAUDE_PROJECT_DIR='$PROJECT_DIR' CODEX_PROJECT_DIR='$PROJECT_DIR' '$hook'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"foo — CHANGED"* ]] || { echo "$hook: $output"; false; }
    [[ "$output" == *"/primer-check"* ]] || { echo "$hook: $output"; false; }
    [[ "$output" != *"STALE"* && "$output" != *"WARM"* && "$output" != *"commits"* ]] || { echo "$hook still counts commits: $output"; false; }
  done
}

@test "C04: entry points churned and restored to the pinned content stay FRESH" {
  mkdir -p "$PROJECT_DIR/.claude/primers"
  echo "v1" > "$PROJECT_DIR/foo.txt"
  ( cd "$PROJECT_DIR" && git add foo.txt && git commit -q -m "seed" )
  SHA=$( cd "$PROJECT_DIR" && git rev-parse HEAD )
  echo "v2" > "$PROJECT_DIR/foo.txt"
  ( cd "$PROJECT_DIR" && git add foo.txt && git commit -q -m "churn" )
  echo "v1" > "$PROJECT_DIR/foo.txt"
  ( cd "$PROJECT_DIR" && git add foo.txt && git commit -q -m "restore" )

  cat > "$PROJECT_DIR/.claude/primers/INDEX.md" <<EOF
- [foo](./foo.md) — sample
EOF
  cat > "$PROJECT_DIR/.claude/primers/foo.md" <<EOF
---
slug: foo
pinned_to: $SHA
---
## Entry points
- \`foo.txt\`
EOF

  run bash -c "echo '{\"source\":\"startup\"}' | CLAUDE_PROJECT_DIR='$PROJECT_DIR' '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"foo — FRESH"* ]] || { echo "$output"; false; }
}

@test "C04: startup never walks the commit graph and finishes despite a hanging walk (both twins)" {
  local hook start elapsed
  mkdir -p "$PROJECT_DIR/.claude/primers"
  echo "v1" > "$PROJECT_DIR/foo.txt"
  ( cd "$PROJECT_DIR" && git add foo.txt && git commit -q -m "seed" )
  SHA=$( cd "$PROJECT_DIR" && git rev-parse HEAD )
  echo "v2" > "$PROJECT_DIR/foo.txt"
  ( cd "$PROJECT_DIR" && git add foo.txt && git commit -q -m "bump" )
  printf -- '- [p%s](./p%s.md) — primer\n' 1 1 2 2 3 3 > "$PROJECT_DIR/.claude/primers/INDEX.md"
  for i in 1 2 3; do
    printf -- '---\nslug: p%s\npinned_to: %s\n---\n## Entry points\n- `foo.txt`\n' "$i" "$SHA" \
      > "$PROJECT_DIR/.claude/primers/p$i.md"
  done

  REAL_GIT=$(command -v git)
  GIT_LOG="$BATS_TEST_TMPDIR/git-argv.log"
  FAKE_BIN="$BATS_TEST_TMPDIR/fake-hanging-walk"
  mkdir -p "$FAKE_BIN"
  cat > "$FAKE_BIN/git" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GIT_LOG"
case " \$* " in
  *" rev-list "*|*" log "*|*" merge-base "*) sleep 10 ;;
esac
exec "$REAL_GIT" "\$@"
EOS
  chmod +x "$FAKE_BIN/git"

  for hook in "$HOOK" "$CODEX_HOOKS_DIR/inject-primer-index.sh"; do
    : > "$GIT_LOG"
    start=$(date +%s)
    run bash -c "PATH=\"$FAKE_BIN:\$PATH\" CLAUDE_PROJECT_DIR=\"$PROJECT_DIR\" CODEX_PROJECT_DIR=\"$PROJECT_DIR\" bash \"$hook\" <<< '{\"source\":\"startup\"}'"
    elapsed=$(( $(date +%s) - start ))
    [ "$status" -eq 0 ]
    [ "$elapsed" -lt 4 ] || { echo "$hook took ${elapsed}s"; false; }
    if grep -E '(^| )(rev-list|log|merge-base)( |$)' "$GIT_LOG"; then
      echo "$hook walked the commit graph at startup"; false
    fi
    [[ "$output" == *"p1 — CHANGED"* && "$output" == *"p3 — CHANGED"* ]] || { echo "$hook: $output"; false; }
  done
}

@test "C04: injected index stays within the 1,500-char cap" {
  local i
  mkdir -p "$PROJECT_DIR/.claude/primers"
  : > "$PROJECT_DIR/.claude/primers/INDEX.md"
  for i in $(seq 1 80); do
    printf -- '- [primer-with-a-long-slug-%02d](./primer-with-a-long-slug-%02d.md) — x\n' "$i" "$i" \
      >> "$PROJECT_DIR/.claude/primers/INDEX.md"
  done
  run bash -c "echo '{\"source\":\"startup\"}' | CLAUDE_PROJECT_DIR='$PROJECT_DIR' '$HOOK'"
  [ "$status" -eq 0 ]
  ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  [ "${#ctx}" -le 1500 ] || { echo "context is ${#ctx} chars"; false; }
  [[ "$ctx" == *"...[trimmed]" ]]
}

@test "v031: emits MISSING_PATHS when entry-point file deleted" {
  mkdir -p "$PROJECT_DIR/.claude/primers"
  echo "x" > "$PROJECT_DIR/gone.txt"
  ( cd "$PROJECT_DIR" && git add gone.txt && git commit -q -m "seed" )
  SHA=$( cd "$PROJECT_DIR" && git rev-parse HEAD )
  rm "$PROJECT_DIR/gone.txt"
  ( cd "$PROJECT_DIR" && git add -A && git commit -q -m "rm gone.txt" )

  cat > "$PROJECT_DIR/.claude/primers/INDEX.md" <<EOF
- [g](./g.md) — sample
EOF
  cat > "$PROJECT_DIR/.claude/primers/g.md" <<EOF
---
slug: g
pinned_to: $SHA
---
## Entry points
- \`gone.txt\`
EOF

  run bash -c "echo '{\"source\":\"startup\"}' | CLAUDE_PROJECT_DIR='$PROJECT_DIR' '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"MISSING_PATHS"* ]]
}

@test "v031: source=compact is a no-op" {
  mkdir -p "$PROJECT_DIR/.claude/primers"
  echo "- [x](./x.md) — sample" > "$PROJECT_DIR/.claude/primers/INDEX.md"

  run bash -c "echo '{\"source\":\"compact\"}' | CLAUDE_PROJECT_DIR='$PROJECT_DIR' '$HOOK'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "v031: emits NO_ENTRY_POINTS when primer file lacks Entry points section" {
  mkdir -p "$PROJECT_DIR/.claude/primers"
  ( cd "$PROJECT_DIR" && git commit -q --allow-empty -m "seed" )
  SHA=$( cd "$PROJECT_DIR" && git rev-parse HEAD )

  cat > "$PROJECT_DIR/.claude/primers/INDEX.md" <<EOF
- [n](./n.md) — sample
EOF
  cat > "$PROJECT_DIR/.claude/primers/n.md" <<EOF
---
slug: n
pinned_to: $SHA
---
## Purpose
no entry points section by design
EOF

  run bash -c "echo '{\"source\":\"startup\"}' | CLAUDE_PROJECT_DIR='$PROJECT_DIR' '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NO_ENTRY_POINTS"* ]]
}

@test "v031: skips fenced code-block content in INDEX.md" {
  mkdir -p "$PROJECT_DIR/.claude/primers"
  ( cd "$PROJECT_DIR" && git commit -q --allow-empty -m "seed" )

  cat > "$PROJECT_DIR/.claude/primers/INDEX.md" <<'EOF'
# Primers Index

Format example:

```
- [<slug>](./<slug>.md) — <one-line description>
```

- [real](./real.md) — actual entry
EOF

  SHA=$( cd "$PROJECT_DIR" && git rev-parse HEAD )
  cat > "$PROJECT_DIR/.claude/primers/real.md" <<EOF
---
slug: real
pinned_to: $SHA
---
## Purpose
real
EOF

  run bash -c "echo '{\"source\":\"startup\"}' | CLAUDE_PROJECT_DIR='$PROJECT_DIR' '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"real"* ]] || { echo "$output"; false; }
  [[ "$output" != *"<slug>"* ]]
}

@test "v031: skips template-placeholder slugs containing angle brackets" {
  mkdir -p "$PROJECT_DIR/.claude/primers"
  ( cd "$PROJECT_DIR" && git commit -q --allow-empty -m "seed" )

  cat > "$PROJECT_DIR/.claude/primers/INDEX.md" <<'EOF'
- [<placeholder>](./<placeholder>.md) — example
EOF

  run bash -c "echo '{\"source\":\"startup\"}' | CLAUDE_PROJECT_DIR='$PROJECT_DIR' '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" != *"<placeholder>"* ]]
}

@test "v031: skips example rows inside a multi-line HTML comment" {
  mkdir -p "$PROJECT_DIR/.claude/primers"
  ( cd "$PROJECT_DIR" && git commit -q --allow-empty -m "seed" )

  # Mirrors the bootstrap INDEX.md template shipped to fresh projects.
  cat > "$PROJECT_DIR/.claude/primers/INDEX.md" <<'EOF'
# Primers Index

<!-- Primers start below. Example:

- [marketing-chatbot-core](./marketing-chatbot-core.md) — Core persona/dispatch pipeline
- [persona-system](./persona-system.md) — Persona definition and selection logic

Delete the comment and example lines above when you add your first real primer.
-->

- [real](./real.md) — actual entry
EOF

  SHA=$( cd "$PROJECT_DIR" && git rev-parse HEAD )
  cat > "$PROJECT_DIR/.claude/primers/real.md" <<EOF
---
slug: real
pinned_to: $SHA
---
## Purpose
real
EOF

  run bash -c "echo '{\"source\":\"startup\"}' | CLAUDE_PROJECT_DIR='$PROJECT_DIR' '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"real"* ]]
  [[ "$output" != *"MISSING_FILE"* ]]
  [[ "$output" != *"marketing-chatbot-core"* ]]
  [[ "$output" != *"persona-system"* ]]
}

@test "v031: handles entry-point paths containing spaces" {
  mkdir -p "$PROJECT_DIR/.claude/primers"
  mkdir -p "$PROJECT_DIR/has space"
  echo "v1" > "$PROJECT_DIR/has space/file.txt"
  ( cd "$PROJECT_DIR" && git add -A && git commit -q -m "seed" )
  SHA=$( cd "$PROJECT_DIR" && git rev-parse HEAD )

  cat > "$PROJECT_DIR/.claude/primers/INDEX.md" <<EOF
- [s](./s.md) — sample
EOF
  cat > "$PROJECT_DIR/.claude/primers/s.md" <<EOF
---
slug: s
pinned_to: $SHA
---
## Entry points
- \`has space/file.txt\`
EOF

  run bash -c "echo '{\"source\":\"startup\"}' | CLAUDE_PROJECT_DIR='$PROJECT_DIR' '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"s — FRESH"* ]]
}

# --- v032 guards: no-git, drift-comparison error, multiline comment (both twins) ---

@test "v032: no-git yields UNKNOWN not FRESH (canonical)" {
  mkdir -p "$PROJECT_DIR/.claude/primers"
  echo "x" > "$PROJECT_DIR/entry.txt"
  ( cd "$PROJECT_DIR" && git add -A && git commit -q -m "seed" )
  SHA=$( cd "$PROJECT_DIR" && git rev-parse HEAD )
  cat > "$PROJECT_DIR/.claude/primers/INDEX.md" <<EOF
- [p1](./p1.md) — primer one
- [p2](./p2.md) — primer two
EOF
  cat > "$PROJECT_DIR/.claude/primers/p1.md" <<EOF
---
slug: p1
pinned_to: $SHA
---
## Entry points
- \`entry.txt\`
EOF
  cat > "$PROJECT_DIR/.claude/primers/p2.md" <<EOF
---
slug: p2
pinned_to: $SHA
---
## Entry points
- \`entry.txt\`
EOF
  FAKE_BIN="$BATS_TEST_TMPDIR/fake-no-git-canonical"
  mkdir -p "$FAKE_BIN"
  cat > "$FAKE_BIN/git" <<'EOS'
#!/usr/bin/env bash
echo "fake git unavailable" >&2
exit 1
EOS
  chmod +x "$FAKE_BIN/git"
  run bash -c "PATH=\"$FAKE_BIN:\$PATH\" CLAUDE_PROJECT_DIR=\"$PROJECT_DIR\" CODEX_PROJECT_DIR=\"$PROJECT_DIR\" bash \"$HOOK\" <<< '{\"source\":\"startup\"}'"
  [ "$status" -eq 0 ]
  [[ "$output" != *"FRESH"* ]] || { echo "unexpected FRESH in no-git canonical: $output"; false; }
  [[ "$output" == *"UNKNOWN"* || "$output" == *"INDETERMINATE"* ]] || { echo "expected UNKNOWN in no-git canonical: $output"; false; }
  [[ "$output" == *"p1 — UNKNOWN"* || "$output" == *"p1 — INDETERMINATE"* ]] || { echo "p1 not UNKNOWN: $output"; false; }
  [[ "$output" == *"p2 — UNKNOWN"* || "$output" == *"p2 — INDETERMINATE"* ]] || { echo "p2 not UNKNOWN: $output"; false; }
}

@test "v032: no-git yields UNKNOWN not FRESH (codex)" {
  mkdir -p "$PROJECT_DIR/.claude/primers"
  echo "x" > "$PROJECT_DIR/entry.txt"
  ( cd "$PROJECT_DIR" && git add -A && git commit -q -m "seed" )
  SHA=$( cd "$PROJECT_DIR" && git rev-parse HEAD )
  cat > "$PROJECT_DIR/.claude/primers/INDEX.md" <<EOF
- [p1](./p1.md) — primer one
- [p2](./p2.md) — primer two
EOF
  cat > "$PROJECT_DIR/.claude/primers/p1.md" <<EOF
---
slug: p1
pinned_to: $SHA
---
## Entry points
- \`entry.txt\`
EOF
  cat > "$PROJECT_DIR/.claude/primers/p2.md" <<EOF
---
slug: p2
pinned_to: $SHA
---
## Entry points
- \`entry.txt\`
EOF
  CODEX_HOOK="$CODEX_HOOKS_DIR/inject-primer-index.sh"
  FAKE_BIN="$BATS_TEST_TMPDIR/fake-no-git-codex"
  mkdir -p "$FAKE_BIN"
  cat > "$FAKE_BIN/git" <<'EOS'
#!/usr/bin/env bash
echo "fake git unavailable" >&2
exit 1
EOS
  chmod +x "$FAKE_BIN/git"
  run bash -c "PATH=\"$FAKE_BIN:\$PATH\" CLAUDE_PROJECT_DIR=\"$PROJECT_DIR\" CODEX_PROJECT_DIR=\"$PROJECT_DIR\" bash \"$CODEX_HOOK\" <<< '{\"source\":\"startup\"}'"
  [ "$status" -eq 0 ]
  [[ "$output" != *"FRESH"* ]] || { echo "unexpected FRESH in no-git codex: $output"; false; }
  [[ "$output" == *"UNKNOWN"* || "$output" == *"INDETERMINATE"* ]] || { echo "expected UNKNOWN in no-git codex: $output"; false; }
  [[ "$output" == *"p1 — UNKNOWN"* || "$output" == *"p1 — INDETERMINATE"* ]] || { echo "p1 not UNKNOWN codex: $output"; false; }
  [[ "$output" == *"p2 — UNKNOWN"* || "$output" == *"p2 — INDETERMINATE"* ]] || { echo "p2 not UNKNOWN codex: $output"; false; }
}

@test "v032: drift-comparison failure yields UNKNOWN not FRESH (canonical)" {
  mkdir -p "$PROJECT_DIR/.claude/primers"
  echo "v1" > "$PROJECT_DIR/entry.txt"
  ( cd "$PROJECT_DIR" && git add -A && git commit -q -m "seed" )
  SHA=$( cd "$PROJECT_DIR" && git rev-parse HEAD )
  cat > "$PROJECT_DIR/.claude/primers/INDEX.md" <<EOF
- [p1](./p1.md) — primer
EOF
  cat > "$PROJECT_DIR/.claude/primers/p1.md" <<EOF
---
slug: p1
pinned_to: $SHA
---
## Entry points
- \`entry.txt\`
EOF
  REAL_GIT=$(command -v git)
  FAKE_BIN="$BATS_TEST_TMPDIR/fake-difftree-canonical"
  mkdir -p "$FAKE_BIN"
  cat > "$FAKE_BIN/git" <<EOS
#!/usr/bin/env bash
if [[ "\$*" == *"diff-tree"* ]]; then
  echo "simulated diff-tree failure" >&2
  exit 1
fi
exec "$REAL_GIT" "\$@"
EOS
  chmod +x "$FAKE_BIN/git"
  run bash -c "PATH=\"$FAKE_BIN:\$PATH\" CLAUDE_PROJECT_DIR=\"$PROJECT_DIR\" CODEX_PROJECT_DIR=\"$PROJECT_DIR\" bash \"$HOOK\" <<< '{\"source\":\"startup\"}'"
  [ "$status" -eq 0 ]
  [[ "$output" != *"FRESH"* ]] || { echo "unexpected FRESH on diff-tree error canonical: $output"; false; }
  [[ "$output" == *"UNKNOWN"* || "$output" == *"INDETERMINATE"* ]] || { echo "expected UNKNOWN on diff-tree error canonical: $output"; false; }
  [[ "$output" == *"p1 — UNKNOWN"* || "$output" == *"p1 — INDETERMINATE"* ]] || { echo "p1 not UNKNOWN on diff-tree error canonical: $output"; false; }
}

@test "v032: drift-comparison failure yields UNKNOWN not FRESH (codex)" {
  mkdir -p "$PROJECT_DIR/.claude/primers"
  echo "v1" > "$PROJECT_DIR/entry.txt"
  ( cd "$PROJECT_DIR" && git add -A && git commit -q -m "seed" )
  SHA=$( cd "$PROJECT_DIR" && git rev-parse HEAD )
  cat > "$PROJECT_DIR/.claude/primers/INDEX.md" <<EOF
- [p1](./p1.md) — primer
EOF
  cat > "$PROJECT_DIR/.claude/primers/p1.md" <<EOF
---
slug: p1
pinned_to: $SHA
---
## Entry points
- \`entry.txt\`
EOF
  REAL_GIT=$(command -v git)
  FAKE_BIN="$BATS_TEST_TMPDIR/fake-difftree-codex"
  mkdir -p "$FAKE_BIN"
  cat > "$FAKE_BIN/git" <<EOS
#!/usr/bin/env bash
if [[ "\$*" == *"diff-tree"* ]]; then
  echo "simulated diff-tree failure" >&2
  exit 1
fi
exec "$REAL_GIT" "\$@"
EOS
  chmod +x "$FAKE_BIN/git"
  CODEX_HOOK="$CODEX_HOOKS_DIR/inject-primer-index.sh"
  run bash -c "PATH=\"$FAKE_BIN:\$PATH\" CLAUDE_PROJECT_DIR=\"$PROJECT_DIR\" CODEX_PROJECT_DIR=\"$PROJECT_DIR\" bash \"$CODEX_HOOK\" <<< '{\"source\":\"startup\"}'"
  [ "$status" -eq 0 ]
  [[ "$output" != *"FRESH"* ]] || { echo "unexpected FRESH on diff-tree error codex: $output"; false; }
  [[ "$output" == *"UNKNOWN"* || "$output" == *"INDETERMINATE"* ]] || { echo "expected UNKNOWN on diff-tree error codex: $output"; false; }
  [[ "$output" == *"p1 — UNKNOWN"* || "$output" == *"p1 — INDETERMINATE"* ]] || { echo "p1 not UNKNOWN on diff-tree error codex: $output"; false; }
}

@test "v032: codex multiline HTML comment does not produce phantom MISSING_FILE" {
  mkdir -p "$PROJECT_DIR/.claude/primers"
  ( cd "$PROJECT_DIR" && git commit -q --allow-empty -m "seed" )
  cat > "$PROJECT_DIR/.claude/primers/INDEX.md" <<'EOF'
# Primers Index
<!-- Primer examples:
- [phantom1](./phantom1.md) — should be ignored
- [phantom2](./phantom2.md) — also ignored
-->
- [real](./real.md) — actual entry
EOF
  SHA=$( cd "$PROJECT_DIR" && git rev-parse HEAD )
  cat > "$PROJECT_DIR/.claude/primers/real.md" <<EOF
---
slug: real
pinned_to: $SHA
---
## Entry points
- \`real.txt\`
EOF
  echo "content" > "$PROJECT_DIR/real.txt"
  ( cd "$PROJECT_DIR" && git add -A && git commit -q -m "add real" )
  CODEX_HOOK="$CODEX_HOOKS_DIR/inject-primer-index.sh"
  run bash -c "CLAUDE_PROJECT_DIR=\"$PROJECT_DIR\" CODEX_PROJECT_DIR=\"$PROJECT_DIR\" bash \"$CODEX_HOOK\" <<< '{\"source\":\"startup\"}'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"real"* ]] || { echo "real missing: $output"; false; }
  [[ "$output" != *"phantom1"* ]] || { echo "phantom1 incorrectly parsed: $output"; false; }
  [[ "$output" != *"phantom2"* ]] || { echo "phantom2 incorrectly parsed: $output"; false; }
  [[ "$output" != *"MISSING_FILE"* ]] || { echo "unexpected MISSING_FILE from phantom: $output"; false; }
}
