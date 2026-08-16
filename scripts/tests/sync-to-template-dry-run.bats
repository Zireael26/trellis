#!/usr/bin/env bats
# Mirror publication contracts run through the stable launcher. Each fixture
# creates a verified immutable payload from one committed source tree; a dirty
# source checkout is deliberately untrusted input and must never be executed.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
RELEASE_VERSION="1.2.3"

setup() {
  mkdir -p "$BATS_TEST_TMPDIR/portable-mirror"
  SANDBOX="$(CDPATH= cd "$BATS_TEST_TMPDIR/portable-mirror" && pwd -P)"
  SOURCE="$SANDBOX/source"
  MIRROR="$SANDBOX/mirror"
  VICTIM=""
  SOURCE_EXECUTED="$SANDBOX/source-script-ran"
  export HOME="$SANDBOX/home"
  export TRELLIS_HOME="$SANDBOX/trellis-home"
  LAUNCHER="$HOME/.local/bin/trellis"
  RELEASE_DIR="$TRELLIS_HOME/releases/$RELEASE_VERSION"
  PAYLOAD="$RELEASE_DIR/payload"

  mkdir -p \
    "$SOURCE/scripts/lib" "$SOURCE/core-rules" "$SOURCE/docs" "$SOURCE/audits" \
    "$MIRROR" "$SANDBOX/projects" "$HOME/.local/bin" "$TRELLIS_HOME/releases"
  chmod 700 "$TRELLIS_HOME"

  cp "$REPO_ROOT/scripts/trellis" "$SOURCE/scripts/"
  cp "$REPO_ROOT/scripts/sync-to-template.sh" "$SOURCE/scripts/"
  cp "$REPO_ROOT/scripts/lib/mirror-lint.sh" "$SOURCE/scripts/lib/"
  cp "$REPO_ROOT/scripts/lib/trellis.config.schema.json" "$SOURCE/scripts/lib/"
  cat > "$SOURCE/trellis.config.json" <<EOF
{
  "schema_version": 2,
  "trellis_root": "$SOURCE",
  "projects_root": "$SANDBOX/projects",
  "maintainer_name": "Private Operator",
  "github_user": "private-operator",
  "harnesses": ["claude"]
}
EOF
  printf '# Reviewed portable process\n' > "$SOURCE/engineering-process.md"
  printf '# Changelog\n' > "$SOURCE/CHANGELOG.md"
  printf '# Portable infrastructure guidance\n' > "$SOURCE/docs/local-development-infrastructure.md"
  printf '{"schema_version":1,"toolchains":[{"name":"private"}]}' > "$SOURCE/dependency-baseline.json"
  printf '{"schema_version":1,"source_reports":["private"]}' > "$SOURCE/audits/fleet-remediation-ledger.json"
  printf '# Portable core policy\n' > "$SOURCE/core-rules/CLAUDE.md"
  # The real tree tracks core-rules/AGENTS.md as a relative symlink to
  # CLAUDE.md and publishes it explicitly, so the fixture must too. A fixture
  # without it cannot reach the symlink-destination paths at all.
  ln -s CLAUDE.md "$SOURCE/core-rules/AGENTS.md"

  git -C "$SOURCE" init -q
  git -C "$SOURCE" config user.email ci-bats@trellis.test
  git -C "$SOURCE" config user.name 'Trellis CI'
  git -C "$SOURCE" add -A
  git -C "$SOURCE" commit -qm source
  SOURCE_COMMIT="$(git -C "$SOURCE" rev-parse HEAD)"

  mkdir -p "$PAYLOAD"
  git -C "$SOURCE" archive --format=tar "$SOURCE_COMMIT" | tar -x -C "$PAYLOAD"
  write_machine_config
  write_release_record
  find "$PAYLOAD" -type f -exec chmod a-w {} \;
  find "$PAYLOAD" -type d -exec chmod a-w {} \;
  chmod a-w "$RELEASE_DIR/release.json" "$RELEASE_DIR"

  cp "$REPO_ROOT/scripts/trellis-launcher.sh" "$LAUNCHER"
  chmod 755 "$LAUNCHER"

  git -C "$MIRROR" init -q
  git -C "$MIRROR" config user.email ci-bats@trellis.test
  git -C "$MIRROR" config user.name 'Trellis CI'
}

teardown() {
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    find "$SANDBOX" -depth -type d -exec chmod u+w {} \; 2>/dev/null || true
    rm -rf "$SANDBOX"
  fi
  [ -z "${VICTIM:-}" ] || rm -rf "$VICTIM"
}

write_machine_config() {
  cat > "$TRELLIS_HOME/config.json" <<EOF
{
  "schema_version": 1,
  "source_root": "$SOURCE",
  "release_remote": "fixture://release",
  "active_cli_release": "$RELEASE_VERSION",
  "default_fleet": "personal",
  "fleets": {
    "personal": {
      "discovery_roots": ["$SANDBOX/projects"]
    }
  }
}
EOF
  chmod 600 "$TRELLIS_HOME/config.json"
}

write_release_record() {
  local manifest file relative mode oid target
  manifest="$SANDBOX/release-tree.jsonl"
  : > "$manifest"
  while IFS= read -r file; do
    relative="${file#"$PAYLOAD"/}"
    if [ -L "$file" ]; then
      mode=120000
      target="$(readlink "$file")"
      oid="$(printf '%s' "$target" | git hash-object --no-filters --stdin)"
    elif [ -x "$file" ]; then
      mode=100755
      oid="$(git hash-object --no-filters "$file")"
    else
      mode=100644
      oid="$(git hash-object --no-filters "$file")"
    fi
    jq -cn --arg path "$relative" --arg mode "$mode" --arg oid "$oid" \
      '{path: $path, mode: $mode, oid: $oid}' >> "$manifest"
  done < <(find -P "$PAYLOAD" \( -type f -o -type l \) -print | LC_ALL=C sort)
  jq -n --arg version "$RELEASE_VERSION" --arg commit "$SOURCE_COMMIT" --slurpfile tree "$manifest" '
    {
      schema_version: 1,
      version: $version,
      tag: ("v" + $version),
      commit: $commit,
      remote: "fixture://release",
      tree: $tree
    }
  ' > "$RELEASE_DIR/release.json"
}

run_sync() {
  run "$LAUNCHER" mirror --template-dir "$MIRROR" "$@"
}

# Seed the mirror with a committed core-rules/AGENTS.md symlink pointing at the
# given target, so the sync meets a destination link it did not just create.
seed_mirror_agents_link() {
  mkdir -p "$MIRROR/core-rules"
  printf '# Portable core policy\n' > "$MIRROR/core-rules/CLAUDE.md"
  ln -s "$1" "$MIRROR/core-rules/AGENTS.md"
  git -C "$MIRROR" add -A
  git -C "$MIRROR" commit -qm seed
}

@test "template directory is explicit through the verified launcher" {
  run "$LAUNCHER" mirror --dry-run

  [ "$status" -eq 2 ]
  [[ "$output" == *'--template-dir PATH'* ]] || { echo "$output"; false; }
}

@test "direct source execution is refused before it can inspect or mutate a mirror" {
  printf 'unchanged mirror\n' > "$MIRROR/README.md"
  before="$(shasum -a 256 "$MIRROR/README.md" | cut -d ' ' -f 1)"

  run bash "$SOURCE/scripts/sync-to-template.sh" --apply --template-dir "$MIRROR"

  [ "$status" -eq 2 ]
  # The refusal comes from the BOOTSTRAP, which is the earliest gate and the
  # only one reached here: the body's own "run trellis mirror from the verified
  # stable launcher" wording is downstream of an `env -i` re-exec that a direct
  # source run never gets to. This assertion asked for the body's wording and
  # was inert (a bare mid-test `[[ … ]]` does not fail a bats test on this
  # host), so it never noticed it was checking for a string this path cannot
  # produce. Assert the message the gate actually emits.
  [[ "$output" == *'direct source execution is unsupported; run trellis mirror from the installed stable launcher'* ]] ||
    { echo "$output"; false; }
  [ "$(shasum -a 256 "$MIRROR/README.md" | cut -d ' ' -f 1)" = "$before" ]
}

@test "dirty and untracked source checkout bytes cannot influence verified publication" {
  cat > "$SOURCE/scripts/sync-to-template.sh" <<EOF
#!/bin/bash
printf 'source script ran\n' > "$SOURCE_EXECUTED"
exit 99
EOF
  cat > "$SOURCE/scripts/trellis" <<EOF
#!/bin/bash
printf 'source dispatcher ran\n' > "$SOURCE_EXECUTED"
exit 98
EOF
  printf 'unreviewed source bytes\n' > "$SOURCE/engineering-process.md"
  printf 'untracked source bytes\n' > "$SOURCE/scripts/untracked-publication.sh"
  printf 'existing reviewed destination\n' > "$MIRROR/engineering-process.md"

  run_sync --apply

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$SOURCE_EXECUTED" ]
  [ -n "$(git -C "$SOURCE" status --short)" ]
  [ "$(git -C "$SOURCE" rev-parse HEAD:engineering-process.md)" = "$(git hash-object --no-filters "$MIRROR/engineering-process.md")" ]
  [ "$(cat "$MIRROR/engineering-process.md")" = '# Reviewed portable process' ]
}

# This fixture is the end-to-end proof that `lint_mirror`'s structural reject
# terms and `sync-to-template.sh`'s `delist_prune` stay paired. Every private
# root seeded here must be pruned by the simulation, otherwise the lint still
# sees it and "simulated mirror clean." never prints — which is exactly the
# permanently unpublishable state an unpaired reject term would create. Seed a
# real on-disk layout for each root so the assertion cannot pass vacuously.
@test "dry-run simulates pruning private machine state without changing the mirror" {
  mkdir -p "$MIRROR/.trellis/releases/1.2.3" "$MIRROR/scheduled-tasks" \
    "$MIRROR/state/attachments/0f1e2d3c" "$MIRROR/state/git-hooks/0f1e2d3c" \
    "$MIRROR/tasks/parent/conductor" "$MIRROR/locks/registry.lock" \
    "$MIRROR/releases/1.2.3/payload" "$MIRROR/local"
  printf '{}\n' > "$MIRROR/.trellis/registry.json"
  printf '{}\n' > "$MIRROR/config.json"
  printf '{}\n' > "$MIRROR/registry.json"
  source_before="$(git -C "$SOURCE" status --short)"
  printf 'private attachment\n' > "$MIRROR/state/attachment.json"
  printf '{}\n' > "$MIRROR/state/attachments/0f1e2d3c/worktree-a.json"
  printf '#!/bin/sh\nexit 0\n' > "$MIRROR/state/git-hooks/0f1e2d3c/pre-push"
  printf 'private prompt\n' > "$MIRROR/scheduled-tasks/prompt.md"
  printf '{}\n' > "$MIRROR/tasks/parent/conductor/snapshot.json"
  printf '{}\n' > "$MIRROR/tasks/parent/conductor/backlog.json"
  printf '4321\n' > "$MIRROR/locks/registry.lock/pid"
  printf '{}\n' > "$MIRROR/releases/1.2.3/release.json"
  printf 'policy\n' > "$MIRROR/releases/1.2.3/payload/CLAUDE.md"
  printf 'private\n' > "$MIRROR/local/notes.md"
  git -C "$MIRROR" add -A
  git -C "$MIRROR" commit -qm seed
  before="$(git -C "$MIRROR" status --short)"

  run_sync --dry-run

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'simulated mirror clean.'* ]] || { echo "$output"; false; }
  [ "$(git -C "$SOURCE" status --short)" = "$source_before" ]
  [ -f "$MIRROR/.trellis/registry.json" ]
  [ -f "$MIRROR/scheduled-tasks/prompt.md" ]
  [ -f "$MIRROR/config.json" ]
  [ -f "$MIRROR/registry.json" ]
  [ -f "$MIRROR/state/attachment.json" ]
  [ -f "$MIRROR/state/attachments/0f1e2d3c/worktree-a.json" ]
  [ -f "$MIRROR/state/git-hooks/0f1e2d3c/pre-push" ]
  [ -f "$MIRROR/tasks/parent/conductor/snapshot.json" ]
  [ -f "$MIRROR/locks/registry.lock/pid" ]
  [ -f "$MIRROR/releases/1.2.3/release.json" ]
  [ -f "$MIRROR/local/notes.md" ]
  [ "$(git -C "$MIRROR" status --short)" = "$before" ]
}

@test "dry-run catches a leaked public-only operator path without touching the mirror" {
  operator_path="/Users/${BATS_TEST_NUMBER:-fixture}-operator/private/mirror"
  printf 'Leak: %s\n' "$operator_path" > "$MIRROR/README.md"
  git -C "$MIRROR" add README.md
  git -C "$MIRROR" commit -qm seed
  before_sha="$(shasum -a 256 "$MIRROR/README.md" | cut -d ' ' -f 1)"

  run_sync --dry-run

  [ "$status" -eq 4 ]
  [[ "$output" == *'MIRROR LINT FAILED'* ]] || { echo "$output"; false; }
  [[ "$output" == *'README.md: absolute-path leak'* ]] || { echo "$output"; false; }
  [ "$(shasum -a 256 "$MIRROR/README.md" | cut -d ' ' -f 1)" = "$before_sha" ]
}

@test "clean-tree apply publishes committed engineering bytes and portable config" {
  mkdir -p "$MIRROR/.trellis/state/attachments" "$MIRROR/local" "$MIRROR/state"
  printf '{}\n' > "$MIRROR/.trellis/config.json"
  printf '{}\n' > "$MIRROR/config.json"
  printf 'private attachment\n' > "$MIRROR/state/attachment.json"
  printf 'private\n' > "$MIRROR/local/operator.txt"

  run_sync --apply

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'applied.'* ]] || { echo "$output"; false; }
  [ ! -e "$MIRROR/.trellis" ]
  [ ! -e "$MIRROR/local" ]
  [ ! -e "$MIRROR/config.json" ]
  [ ! -e "$MIRROR/state" ]
  [ "$(git -C "$SOURCE" rev-parse HEAD:engineering-process.md)" = "$(git hash-object --no-filters "$MIRROR/engineering-process.md")" ]
  jq -e '
    .schema_version == 2
    and (.trellis_root? | not)
    and (.projects_root? | not)
    and (.template.redact_paths? | not)
    and .maintainer_name == "__MAINTAINER_NAME__"
  ' "$MIRROR/trellis.config.json" >/dev/null
  run grep -F "$SOURCE" "$MIRROR/trellis.config.json"
  [ "$status" -eq 1 ]
}

@test "dry-run rejects a non-directory destination parent before mutation" {
  printf 'not a directory\n' > "$MIRROR/core-rules"
  before="$(shasum -a 256 "$MIRROR/core-rules" | cut -d ' ' -f 1)"

  run_sync --dry-run

  [ "$status" -eq 4 ]
  [[ "$output" == *'destination parent is not a directory: core-rules'* ]] || { echo "$output"; false; }
  [ "$(shasum -a 256 "$MIRROR/core-rules" | cut -d ' ' -f 1)" = "$before" ]
}

@test "dry-run rejects a safe relative symlinked file destination" {
  printf 'public target\n' > "$MIRROR/README.md"
  ln -s README.md "$MIRROR/engineering-process.md"

  run_sync --dry-run

  [ "$status" -eq 4 ]
  [[ "$output" == *'destination is a symlink: engineering-process.md'* ]] || { echo "$output"; false; }
  [ "$(readlink "$MIRROR/engineering-process.md")" = 'README.md' ]
}

@test "dry-run and apply reject a relative symlinked sync parent before external mutation" {
  VICTIM="$SANDBOX/victim"
  mkdir -p "$VICTIM"
  printf 'external victim\n' > "$VICTIM/sentinel"
  ln -s ../victim "$MIRROR/scripts"
  victim_before="$(shasum -a 256 "$VICTIM/sentinel" | cut -d ' ' -f 1)"
  source_before="$(git -C "$SOURCE" status --short)"
  mirror_before="$(git -C "$MIRROR" status --short)"

  for mode in --dry-run --apply; do
    run_sync "$mode"

    [ "$status" -eq 4 ]
    [[ "$output" == *'template destination has unsafe mutation path'* ]] || { echo "$output"; false; }
    [ "$(git -C "$SOURCE" status --short)" = "$source_before" ]
    [ "$(git -C "$MIRROR" status --short)" = "$mirror_before" ]
    [ "$(readlink "$MIRROR/scripts")" = '../victim' ]
    [ "$(shasum -a 256 "$VICTIM/sentinel" | cut -d ' ' -f 1)" = "$victim_before" ]
  done
}

# The published tree contains a tracked symlink, so the simulation installs one
# into the simulated mirror and then re-preflights it. Preflight must be
# idempotent over its own output or publication is blocked outright.
@test "dry-run and apply publish the tracked core-rules AGENTS.md symlink" {
  mirror_before="$(git -C "$MIRROR" status --short)"

  run_sync --dry-run

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'simulated mirror clean.'* ]] || { echo "$output"; false; }
  [ ! -L "$MIRROR/core-rules/AGENTS.md" ]
  [ "$(git -C "$MIRROR" status --short)" = "$mirror_before" ]

  run_sync --apply

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -L "$MIRROR/core-rules/AGENTS.md" ]
  [ "$(readlink "$MIRROR/core-rules/AGENTS.md")" = 'CLAUDE.md' ]
}

# Any mirror published once already carries that symlink, so the very first
# preflight of the next run meets it.
@test "a mirror already carrying the published AGENTS.md symlink re-syncs" {
  seed_mirror_agents_link CLAUDE.md
  mirror_before="$(git -C "$MIRROR" status --short)"

  run_sync --dry-run

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'simulated mirror clean.'* ]] || { echo "$output"; false; }
  [ "$(readlink "$MIRROR/core-rules/AGENTS.md")" = 'CLAUDE.md' ]
  [ "$(git -C "$MIRROR" status --short)" = "$mirror_before" ]

  run_sync --apply

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'applied.'* ]] || { echo "$output"; false; }
  [ -L "$MIRROR/core-rules/AGENTS.md" ]
  [ "$(readlink "$MIRROR/core-rules/AGENTS.md")" = 'CLAUDE.md' ]
}

@test "dry-run and apply reject a destination symlink with an absolute target" {
  seed_mirror_agents_link "$MIRROR/core-rules/CLAUDE.md"
  mirror_before="$(git -C "$MIRROR" status --short)"

  for mode in --dry-run --apply; do
    run_sync "$mode"

    [ "$status" -eq 4 ] || { echo "$output"; false; }
    [[ "$output" == *'core-rules/AGENTS.md: symlink target leaks absolute path'* ]] ||
      { echo "$output"; false; }
    [[ "$output" == *'template destination has unsafe mutation path'* ]] || { echo "$output"; false; }
    [ "$(readlink "$MIRROR/core-rules/AGENTS.md")" = "$MIRROR/core-rules/CLAUDE.md" ]
    [ "$(git -C "$MIRROR" status --short)" = "$mirror_before" ]
  done
}

@test "dry-run and apply reject a destination symlink whose relative target escapes the mirror" {
  VICTIM="$SANDBOX/victim"
  mkdir -p "$VICTIM"
  printf 'external victim\n' > "$VICTIM/sentinel"
  seed_mirror_agents_link ../../victim/sentinel
  victim_before="$(shasum -a 256 "$VICTIM/sentinel" | cut -d ' ' -f 1)"
  mirror_before="$(git -C "$MIRROR" status --short)"

  for mode in --dry-run --apply; do
    run_sync "$mode"

    [ "$status" -eq 4 ] || { echo "$output"; false; }
    [[ "$output" == *'core-rules/AGENTS.md: symlink target escapes mirror'* ]] ||
      { echo "$output"; false; }
    [ "$(readlink "$MIRROR/core-rules/AGENTS.md")" = '../../victim/sentinel' ]
    [ "$(shasum -a 256 "$VICTIM/sentinel" | cut -d ' ' -f 1)" = "$victim_before" ]
    [ "$(git -C "$MIRROR" status --short)" = "$mirror_before" ]
  done
}

# Contained and relative, so the mirror-wide symlink scan passes it. Only the
# link-text equality rule stands between this redirect and a write through it.
@test "dry-run and apply reject a destination symlink whose link text differs from the staged link" {
  seed_mirror_agents_link ../engineering-process.md
  printf 'reviewed destination\n' > "$MIRROR/engineering-process.md"
  mirror_before="$(git -C "$MIRROR" status --short)"

  for mode in --dry-run --apply; do
    run_sync "$mode"

    [ "$status" -eq 4 ] || { echo "$output"; false; }
    [[ "$output" == *'destination is a symlink: core-rules/AGENTS.md'* ]] || { echo "$output"; false; }
    [ "$(readlink "$MIRROR/core-rules/AGENTS.md")" = '../engineering-process.md' ]
    [ "$(cat "$MIRROR/engineering-process.md")" = 'reviewed destination' ]
    [ "$(git -C "$MIRROR" status --short)" = "$mirror_before" ]
  done
}

@test "dry-run and apply reject a relative symlinked prune target before external mutation" {
  VICTIM="$SANDBOX/victim"
  mkdir -p "$VICTIM"
  printf 'external victim\n' > "$VICTIM/sentinel"
  ln -s ../victim "$MIRROR/local"
  victim_before="$(shasum -a 256 "$VICTIM/sentinel" | cut -d ' ' -f 1)"
  source_before="$(git -C "$SOURCE" status --short)"
  mirror_before="$(git -C "$MIRROR" status --short)"

  for mode in --dry-run --apply; do
    run_sync "$mode"

    [ "$status" -eq 4 ]
    [[ "$output" == *'template destination has unsafe mutation path'* ]] || { echo "$output"; false; }
    [ "$(git -C "$SOURCE" status --short)" = "$source_before" ]
    [ "$(git -C "$MIRROR" status --short)" = "$mirror_before" ]
    [ "$(readlink "$MIRROR/local")" = '../victim' ]
    [ "$(shasum -a 256 "$VICTIM/sentinel" | cut -d ' ' -f 1)" = "$victim_before" ]
  done
}
