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

@test "v031: emits STALE when entry-point churned past threshold" {
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

  run bash -c "echo '{\"source\":\"startup\"}' | CLAUDE_PROJECT_DIR='$PROJECT_DIR' '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STALE"* ]]
  [[ "$output" == *"/primer-refresh"* ]]
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
  [[ "$output" == *"real"* ]]
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
