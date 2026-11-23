#!/usr/bin/env bats
# Lane D (v1.5.6 disk-janitor): dual tmp roots with expanded patterns, gate-xdg
# uv + report-only store rows + npm prune, new transcript histogram dirs, and
# trellis gc state/scratch + tasks + test-stray sweeps. Hermetic: fake
# HOME/TMPDIR/TRELLIS_HOME per test, stubbed tools on PATH.

REPO_ROOT="$( cd "$BATS_TEST_DIRNAME/../.." && pwd )"
DJ="$REPO_ROOT/scripts/disk-janitor.sh"
GC="$REPO_ROOT/scripts/gc.sh"
STALE_TOUCH="200001010000"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/dj-laned.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  CANON="$SANDBOX/canonical"
  PROJECTS="$SANDBOX/projects"
  TRELLIS_HOME="$SANDBOX/.trellis"
  CFG="$CANON/trellis.config.json"
  mkdir -p "$CANON/audits" "$PROJECTS" "$TRELLIS_HOME" "$SANDBOX/tmp" "$SANDBOX/home"
  chmod 700 "$TRELLIS_HOME"
  export TRELLIS_CONFIG="$CFG" TRELLIS_HOME
  export TMPDIR="$SANDBOX/tmp" HOME="$SANDBOX/home"
  export DJ_BUILD_ACTIVE_OVERRIDE=0
  mkdir -p "$TRELLIS_HOME/releases"
  cat >"$CFG" <<'EOF'
{"schema_version": 2, "maintainer_name": "Test Maintainer", "github_user": "tester", "harnesses": ["claude"]}
EOF
  cat >"$TRELLIS_HOME/config.json" <<EOF
{
  "schema_version": 1,
  "source_root": "$CANON",
  "release_remote": "https://example.invalid/trellis.git",
  "active_cli_release": "1.2.3",
  "default_fleet": "personal",
  "fleets": {"personal": {"discovery_roots": ["$PROJECTS"]}}
}
EOF
  chmod 600 "$TRELLIS_HOME/config.json"
  printf '%s\n' '{"schema_version":1,"projects":{},"discovery_ignores":{}}' >"$TRELLIS_HOME/registry.json"
  chmod 600 "$TRELLIS_HOME/registry.json"
}

teardown() {
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then chmod -R u+w "$SANDBOX" 2>/dev/null || true; rm -rf "$SANDBOX"; fi
}

age_tree() { find "$1" -exec touch -h -t "$STALE_TOUCH" {} + 2>/dev/null || true; touch -h -t "$STALE_TOUCH" "$1" 2>/dev/null || true; }

write_stub_tools() {
  local bindir="$1"
  mkdir -p "$bindir"
  cat >"$bindir/uv" <<EOF
#!/bin/sh
printf 'UV_CACHE_DIR=%s argv=%s\n' "\$UV_CACHE_DIR" "\$*" >> "$SANDBOX/uv-argv.log"
if [ "\$1" = "cache" ] && [ "\$2" = "dir" ]; then printf '%s\n' "$SANDBOX/uv-cache"; exit 0; fi
if [ "\$1" = "cache" ] && [ "\$2" = "prune" ]; then exit 0; fi
exit 0
EOF
  cat >"$bindir/npm" <<'EOF'
#!/bin/sh
if [ "$1" = "config" ] && [ "$2" = "get" ] && [ "$3" = "cache" ]; then printf '%s\n' "$SANDBOX/npm-cache"; exit 0; fi
if [ "$1" = "cache" ] && [ "$2" = "clean" ]; then exit 0; fi
exit 0
EOF
  chmod +x "$bindir"/*
  : >"$SANDBOX/uv-argv.log"
}

@test "LD.1 tmp scans BOTH Darwin user tmp and /private/tmp override with expanded patterns" {
  local darwin system
  darwin="$SANDBOX/darwin-tmp"; system="$SANDBOX/system-tmp"
  mkdir -p "$darwin" "$system"
  export DJ_DARWIN_TMPDIR_OVERRIDE="$darwin" DJ_SYSTEM_TMPDIR_OVERRIDE="$system"
  # Aged scratch in each root across the expanded pattern set.
  for name in bats-run-ld1 tg-c123 pytest-of-abhi node-compile-cache tsx-501 trellis-test-git.xyz; do
    mkdir -p "$system/$name"; printf 'x\n' >"$system/$name/f"; age_tree "$system/$name"
  done
  mkdir -p "$darwin/rv-ld1old" "$darwin/jiti" "$darwin/pi-subagents-501"
  for name in rv-ld1old jiti pi-subagents-501; do printf 'x\n' >"$darwin/$name/f"; age_tree "$darwin/$name"; done
  # Read-only contents (Go module cache style) must still be reaped via chmod.
  mkdir -p "$system/tg-ro/cache"; printf 'ro\n' >"$system/tg-ro/cache/f"; chmod -R a-w "$system/tg-ro"; age_tree "$system/tg-ro"
  # Young entries stay; symlinks are never listed for deletion.
  mkdir -p "$darwin/rv-ld1young"; printf 'x\n' >"$darwin/rv-ld1young/f"
  mkdir -p "$system/real-target"; ln -s "$system/real-target" "$system/tg-linkld1"
  touch -t "$STALE_TOUCH" "$system/real-target"

  run bash "$DJ" --report --scopes tmp
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  for name in bats-run-ld1 tg-c123 pytest-of-abhi node-compile-cache tsx-501 trellis-test-git.xyz rv-ld1old jiti pi-subagents-501 tg-ro; do
    [[ "$output" == *"[delete] $system/$name "* || "$output" == *"[delete] $darwin/$name "* ]] || { echo "missing delete for $name: $output"; false; }
  done
  [[ "$output" != *"[delete] $darwin/rv-ld1young "* ]] || { echo "young deleted"; false; }
  [[ "$output" != *"[delete] $system/tg-linkld1 "* ]] || { echo "symlink deleted"; false; }

  run bash "$DJ" --apply --yes --scopes tmp </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  for name in tg-c123 pytest-of-abhi node-compile-cache tsx-501 jiti pi-subagents-501 tg-ro bats-run-ld1 rv-ld1old; do
    [ ! -e "$system/$name" ] && [ ! -e "$darwin/$name" ] || { echo "$name survived"; false; }
  done
  [ -d "$darwin/rv-ld1young" ] || { echo "young removed"; false; }
  [ -L "$system/tg-linkld1" ] || { echo "symlink removed"; false; }
}

@test "LD.2 stores list gate-xdg uv plus report-only rows; apply prunes gate-xdg and npm" {
  local stub="$SANDBOX/stub-bin"
  write_stub_tools "$stub"
  mkdir -p "$SANDBOX/uv-cache" "$TRELLIS_HOME/state/gate-xdg/cache/uv"
  printf 'x\n' >"$SANDBOX/uv-cache/f"; printf 'x\n' >"$TRELLIS_HOME/state/gate-xdg/cache/uv/g"
  mkdir -p "$HOME/.cache/codex-runtimes" "$HOME/Library/Caches/claude-cli-nodejs" \
    "$HOME/Library/Caches/dotslash" "$HOME/Library/Caches/node-gyp"
  for d in "$HOME/.cache/codex-runtimes" "$HOME/Library/Caches/claude-cli-nodejs" \
    "$HOME/Library/Caches/dotslash" "$HOME/Library/Caches/node-gyp"; do printf 'x\n' >"$d/f"; done
  mkdir -p "$TRELLIS_HOME/state/disk-janitor"
  printf '%s\n' "$stub" >"$TRELLIS_HOME/state/disk-janitor/tool-path"
  chmod 600 "$TRELLIS_HOME/state/disk-janitor/tool-path"

  run env PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash "$DJ" --report --scopes stores
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"uv-cache-gate"* ]] || { echo "$output"; false; }
  [[ "$output" == *"gate-xdg/cache/uv"* ]] || { echo "$output"; false; }
  for kind in codex-runtimes claude-cli-nodejs dotslash node-gyp; do
    [[ "$output" == *"$kind"* ]] || { echo "missing $kind row: $output"; false; }
  done

  run env PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash "$DJ" --apply --yes --scopes stores </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"pruned: uv cache prune (gate-xdg)"* ]] || { echo "$output"; false; }
  [[ "$output" == *"pruned: npm cache clean --force"* ]] || { echo "$output"; false; }
  grep -q "UV_CACHE_DIR=$TRELLIS_HOME/state/gate-xdg/cache/uv" "$SANDBOX/uv-argv.log" || { cat "$SANDBOX/uv-argv.log"; false; }
}

@test "LD.3 transcripts histogram covers antigravity-cli and opencode dirs, never deleted" {
  mkdir -p "$HOME/.gemini/antigravity-cli" "$HOME/.local/share/opencode"
  printf 'old\n' >"$HOME/.gemini/antigravity-cli/sess.json"
  touch -t "$STALE_TOUCH" "$HOME/.gemini/antigravity-cli/sess.json"
  printf 'new\n' >"$HOME/.local/share/opencode/sess.json"
  export DJ_DARWIN_TMPDIR_OVERRIDE="" DJ_SYSTEM_TMPDIR_OVERRIDE=""

  run bash "$DJ" --report --scopes transcripts
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"antigravity-cli"* ]] || { echo "$output"; false; }
  [[ "$output" == *"share/opencode"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[delete]"* ]] || { echo "transcript deleted: $output"; false; }
  run bash "$DJ" --apply --yes --scopes transcripts </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$HOME/.gemini/antigravity-cli/sess.json" ] || { echo "antigravity transcript removed"; false; }
}

@test "LD.4 gc sweeps state/scratch .cmd dirs, tasks .tmp orphans, and test strays" {
  mkdir -p "$TRELLIS_HOME/state/scratch/.cmd.leakld4/payload" "$TRELLIS_HOME/tasks/personal/.tmp.jobld4/work"
  printf 'x\n' >"$TRELLIS_HOME/state/scratch/.cmd.leakld4/payload/f"
  printf 'x\n' >"$TRELLIS_HOME/tasks/personal/.tmp.jobld4/work/f"
  age_tree "$TRELLIS_HOME/state/scratch/.cmd.leakld4"
  age_tree "$TRELLIS_HOME/tasks/personal/.tmp.jobld4"
  # A .cmd.* dir with an aged root but recent nested activity must NOT be swept.
  mkdir -p "$TRELLIS_HOME/state/scratch/.cmd.activeld4/payload"
  printf 'live\n' >"$TRELLIS_HOME/state/scratch/.cmd.activeld4/payload/f"
  touch -t "$STALE_TOUCH" "$TRELLIS_HOME/state/scratch/.cmd.activeld4"
  # Dead-PID tasks staging with a paired owner sidecar (both bare .tmp.* and .<task>.tmp.* forms).
  mkdir -p "$TRELLIS_HOME/tasks/personal/.tmp.ownedld4" "$TRELLIS_HOME/tasks/personal/.test-health.tmp.ownedld4"
  printf 'x\n' >"$TRELLIS_HOME/tasks/personal/.tmp.ownedld4/f"
  printf 'x\n' >"$TRELLIS_HOME/tasks/personal/.test-health.tmp.ownedld4/f"
  jq -cn --argjson pid 2147483647 '{schema_version:1,pid:$pid}' >"$TRELLIS_HOME/tasks/personal/.tmp.ownedld4.owner.json"
  jq -cn --argjson pid 2147483647 '{schema_version:1,pid:$pid}' >"$TRELLIS_HOME/tasks/personal/.test-health.tmp.ownedld4.owner.json"
  touch -t "$STALE_TOUCH" "$TRELLIS_HOME/tasks/personal/.tmp.ownedld4" "$TRELLIS_HOME/tasks/personal/.tmp.ownedld4.owner.json"
  : >"$TRELLIS_HOME/pi-worktrees.test.strayld4"

  run bash "$GC" --dry-run --home "$TRELLIS_HOME"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"would-remove scratch-cmd"*".cmd.leakld4"* ]] || { echo "$output"; false; }
  [[ "$output" != *".cmd.activeld4"* ]] || { echo "active nested scratch dir flagged: $output"; false; }
  [[ "$output" == *"would-remove task-tmp"*".tmp.jobld4"* ]] || { echo "$output"; false; }
  [[ "$output" == *"would-remove task-tmp"*".tmp.ownedld4"* ]] || { echo "$output"; false; }
  [[ "$output" == *"would-remove task-tmp"*".test-health.tmp.ownedld4"* ]] || { echo "$output"; false; }
  [[ "$output" == *"would-remove test-stray"* ]] || { echo "$output"; false; }

  run bash "$GC" --apply --home "$TRELLIS_HOME"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$TRELLIS_HOME/state/scratch/.cmd.leakld4" ] || { echo "scratch leak survived"; false; }
  [ -f "$TRELLIS_HOME/state/scratch/.cmd.activeld4/payload/f" ] || { echo "active nested scratch dir removed"; false; }
  [ ! -e "$TRELLIS_HOME/tasks/personal/.tmp.jobld4" ] || { echo "task tmp survived"; false; }
  [ ! -e "$TRELLIS_HOME/tasks/personal/.tmp.ownedld4" ] || { echo "owned task tmp survived"; false; }
  [ ! -e "$TRELLIS_HOME/tasks/personal/.tmp.ownedld4.owner.json" ] || { echo "owner sidecar survived"; false; }
  [ ! -e "$TRELLIS_HOME/tasks/personal/.test-health.tmp.ownedld4" ] || { echo "task-named tmp survived"; false; }
  [ ! -e "$TRELLIS_HOME/tasks/personal/.test-health.tmp.ownedld4.owner.json" ] || { echo "task-named owner sidecar survived"; false; }
  [ ! -e "$TRELLIS_HOME/pi-worktrees.test.strayld4" ] || { echo "test stray survived"; false; }
}

@test "LD.5 tmp reaps fastembed_cache, mypy-*, and aged claude-<uid> sessions while keeping fresh ones" {
  local system="$SANDBOX/sys-tmp" my_uid
  my_uid="$(id -u)"
  mkdir -p "$system/fastembed_cache" "$system/mypy-review" \
    "$system/claude-$my_uid/proj-a/old-sess/snap" \
    "$system/claude-$my_uid/proj-a/fresh-sess"
  printf 'x\n' >"$system/fastembed_cache/model.bin"
  printf 'x\n' >"$system/mypy-review/cache.json"
  printf 'ro\n' >"$system/claude-$my_uid/proj-a/old-sess/snap/f"
  chmod -R a-w "$system/claude-$my_uid/proj-a/old-sess/snap"
  printf 'live\n' >"$system/claude-$my_uid/proj-a/fresh-sess/f"
  age_tree "$system/fastembed_cache"
  age_tree "$system/mypy-review"
  age_tree "$system/claude-$my_uid/proj-a/old-sess"
  export DJ_DARWIN_TMPDIR_OVERRIDE="" DJ_SYSTEM_TMPDIR_OVERRIDE="$system"

  run bash "$DJ" --report --scopes tmp
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"[delete] $system/fastembed_cache "* ]] || { echo "$output"; false; }
  [[ "$output" == *"[delete] $system/mypy-review "* ]] || { echo "$output"; false; }
  [[ "$output" == *"[delete] $system/claude-$my_uid/proj-a/old-sess "* ]] || { echo "$output"; false; }
  [[ "$output" != *"[delete] $system/claude-$my_uid/proj-a/fresh-sess "* ]] || { echo "fresh claude session deleted"; false; }

  run bash "$DJ" --apply --yes --scopes tmp </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$system/fastembed_cache" ] || { echo "fastembed_cache survived"; false; }
  [ ! -e "$system/mypy-review" ] || { echo "mypy-review survived"; false; }
  [ ! -e "$system/claude-$my_uid/proj-a/old-sess" ] || { echo "old claude session survived"; false; }
  [ -f "$system/claude-$my_uid/proj-a/fresh-sess/f" ] || { echo "fresh claude session removed"; false; }
}

@test "LD.6 stores report surfaces gradle, pnpm-http, codex-plugin-staging, claude-cli-versions, and chrome-headless" {
  local stub="$SANDBOX/stub-bin"
  write_stub_tools "$stub"
  mkdir -p "$HOME/.gradle/caches" "$HOME/Library/Caches/pnpm" \
    "$HOME/.codex/plugins/.marketplace-plugin-source-staging" \
    "$HOME/.local/share/claude/versions" \
    "$HOME/Library/Application Support/Google/Chrome-headless"
  for d in "$HOME/.gradle/caches" "$HOME/Library/Caches/pnpm" \
    "$HOME/.codex/plugins/.marketplace-plugin-source-staging" \
    "$HOME/.local/share/claude/versions" \
    "$HOME/Library/Application Support/Google/Chrome-headless"; do
    printf 'x\n' >"$d/f"
  done
  mkdir -p "$TRELLIS_HOME/state/disk-janitor"
  printf '%s\n' "$stub" >"$TRELLIS_HOME/state/disk-janitor/tool-path"
  chmod 600 "$TRELLIS_HOME/state/disk-janitor/tool-path"

  run env PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash "$DJ" --report --scopes stores
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  for kind in gradle-cache pnpm-http-cache codex-plugin-staging claude-cli-versions chrome-headless; do
    [[ "$output" == *"$kind"* ]] || { echo "missing $kind row: $output"; false; }
  done
}
