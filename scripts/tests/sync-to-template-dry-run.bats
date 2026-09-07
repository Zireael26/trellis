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
  SOCKET_FIXTURE=""
  SOURCE_EXECUTED="$SANDBOX/source-script-ran"
  export HOME="$SANDBOX/home"
  export TRELLIS_HOME="$SANDBOX/trellis-home"
  LAUNCHER="$HOME/.local/bin/trellis"
  RELEASE_DIR="$TRELLIS_HOME/releases/$RELEASE_VERSION"
  PAYLOAD="$RELEASE_DIR/payload"

  mkdir -p \
    "$SOURCE/scripts/lib" "$SOURCE/core-rules/skills/herdr-foreman" \
    "$SOURCE/core-rules/references" "$SOURCE/core-rules/hooks" \
    "$SOURCE/core-rules/pi/agents" "$SOURCE/core-rules/pi/extensions" \
    "$SOURCE/core-rules/pi/hooks" "$SOURCE/core-rules/pi/patches/tests" \
    "$SOURCE/docs" "$SOURCE/audits" \
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
  printf '# Portable Pi computer-use setup\n' > "$SOURCE/docs/PI-COMPUTER-USE.md"
  printf '# Portable Pi upgrade prompt\n' > "$SOURCE/docs/PI-COMPUTER-USE-UPGRADE-PROMPT.md"
  printf '{"schema_version":1,"toolchains":[{"name":"private"}]}' > "$SOURCE/dependency-baseline.json"
  printf '{"schema_version":1,"source_reports":["private"]}' > "$SOURCE/audits/fleet-remediation-ledger.json"
  printf '# Portable core policy\n' > "$SOURCE/core-rules/CLAUDE.md"
  # The real tree tracks core-rules/AGENTS.md as a relative symlink to
  # CLAUDE.md and publishes it explicitly, so the fixture must too. A fixture
  # without it cannot reach the symlink-destination paths at all.
  ln -s CLAUDE.md "$SOURCE/core-rules/AGENTS.md"
  printf '# Private executable skill fixture\n' > "$SOURCE/core-rules/skills/herdr-foreman/SKILL.md"
  printf '# Public Herdr doctrine fixture\n' > "$SOURCE/core-rules/references/herdr-foreman.md"
  printf '#!/usr/bin/env bash\n# Portable user session hook fixture\n' \
    > "$SOURCE/core-rules/hooks/herdr-foreman-session.sh"
  write_pi_surface_fixture
  write_inheritance_manifest_fixture "$SOURCE/core-rules/inheritance-manifest.json"

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
  [ -z "${SOCKET_FIXTURE:-}" ] || rm -rf "$SOCKET_FIXTURE"
}

# The pi surface splits in two. `core-rules/pi/agents` is the operator's live
# provider roster and stays private; everything else under `core-rules/pi` is
# the machinery a mirror user needs to install pi at all and is published. Seed
# BOTH halves, and seed the private half with content the mirror lint would
# reject on sight — an operator home path, a receipt path and provider account
# names — so "the roster did not publish" is proved by bytes that could not have
# survived publication rather than by an absence that might be vacuous.
write_pi_surface_fixture() {
  # Build synthetic private sentinels without embedding a user-home path in
  # the published test source; generated negative-control bytes stay exact.
  local roster_path
  roster_path="$(printf '/%s/%s' Users rosteroperator)"
  cat > "$SOURCE/core-rules/pi/agents/private-roster-ro.md" <<AGENT
---
name: private-roster-ro
model: private-provider-2/private-model:xhigh
isolation: off
---
Roster pinned from $roster_path/.trellis/state/lane-catalog.json
Receipt: audits/2026-09-05-private/receipts/roster-probe.json
AGENT
  cat > "$SOURCE/core-rules/pi/agents/private-roster-rw.md" <<'AGENT'
---
name: private-roster-rw
model: private-provider-2/private-model:max
isolation: worktree
---
Second private account lane.
AGENT
  printf 'export default async function (pi) { return pi; }\n' \
    > "$SOURCE/core-rules/pi/extensions/trellis.ts"
  printf '#!/usr/bin/env bash\n# Portable pi hook dispatcher fixture\nexit 0\n' \
    > "$SOURCE/core-rules/pi/hooks/dispatch.sh"
  chmod 755 "$SOURCE/core-rules/pi/hooks/dispatch.sh"
  printf '#!/usr/bin/env bash\n# Portable patch installer fixture\nexit 0\n' \
    > "$SOURCE/core-rules/pi/patches/apply-fixture-patches.sh"
  chmod 755 "$SOURCE/core-rules/pi/patches/apply-fixture-patches.sh"
  printf -- '--- a/fixture.ts\n+++ b/fixture.ts\n' \
    > "$SOURCE/core-rules/pi/patches/pi-fixture-0.0.1-portable.patch"
  # A patch bundle and its regression test publish together or the version pin
  # is unverifiable downstream.
  printf 'process.exit(0);\n' \
    > "$SOURCE/core-rules/pi/patches/tests/fixture-patch.test.mjs"
  printf '# Fixture patch notes\n' > "$SOURCE/core-rules/pi/patches/FIXTURE.md"
}

# A canonical minimal manifest carrying the two exact private link entries the
# publisher projects out, plus portable neighbours that must survive untouched.
write_inheritance_manifest_fixture() {
  cat > "$1" <<'MANIFEST'
{
  "schema_version": 2,
  "harnesses": {
    "shared_agents": {
      "links": [
        {
          "source": "core-rules/CLAUDE.md",
          "destination": ".agents/rules/trellis.md"
        },
        {
          "source_children": "core-rules/pi/agents",
          "destination_dir": ".agents/agents",
          "entry_type": "file",
          "suffix": ".md"
        },
        {
          "source_children": "core-rules/skills",
          "destination_dir": ".agents/skills",
          "entry_type": "directory",
          "required_file": "SKILL.md"
        }
      ],
      "render": []
    },
    "pi": {
      "links": [
        {
          "source": "core-rules/pi/extensions/trellis.ts",
          "destination": ".pi/extensions/trellis.ts"
        },
        {
          "source": "core-rules/pi/hooks/dispatch.sh",
          "destination": ".pi/hooks/dispatch.sh",
          "executable": true
        }
      ],
      "render": []
    },
    "user": {
      "links": [
        {
          "source": "core-rules/skills/herdr-foreman",
          "destination": ".claude/skills/herdr-foreman",
          "destination_home": true
        },
        {
          "source": "core-rules/hooks/herdr-foreman-session.sh",
          "destination": ".claude/hooks/herdr-foreman-session.sh",
          "destination_home": true,
          "executable": true
        }
      ],
      "render": []
    }
  }
}
MANIFEST
}

# Rebuild and reseal the immutable release from the CURRENT committed source
# tree. Tests that need the publisher to run against changed policy must go
# through this: mutating an already-verified payload behind its release record
# is exactly the untrusted-input path the whole flow exists to refuse.
reseal_source_release() {
  git -C "$SOURCE" add -A
  git -C "$SOURCE" commit -qm "$1"
  SOURCE_COMMIT="$(git -C "$SOURCE" rev-parse HEAD)"

  chmod u+w "$RELEASE_DIR" "$RELEASE_DIR/release.json"
  find "$PAYLOAD" -type f -exec chmod u+w {} \;
  find "$PAYLOAD" -depth -type d -exec chmod u+w {} \;
  rm -rf "$PAYLOAD"
  mkdir -p "$PAYLOAD"
  git -C "$SOURCE" archive --format=tar "$SOURCE_COMMIT" | tar -x -C "$PAYLOAD"
  write_release_record
  find "$PAYLOAD" -type f -exec chmod a-w {} \;
  find "$PAYLOAD" -type d -exec chmod a-w {} \;
  chmod a-w "$RELEASE_DIR/release.json" "$RELEASE_DIR"
}

# Run the publisher's OWN projection program against an arbitrary manifest.
# Extracted from `sync-to-template.sh` rather than re-implemented, so the
# closure proof below exercises the shipped code and cannot drift from it. The
# emptiness guard is load-bearing: a changed heredoc marker would otherwise
# hand python an empty program that exits 0 and proves nothing.
project_manifest_with_publisher_program() {
  local manifest="$1" program="$SANDBOX/project-manifest.py"
  awk "/<<'PROJECT_MANIFEST'/ { inside = 1; next }
       inside && /^PROJECT_MANIFEST\$/ { inside = 0 }
       inside { print }" \
    "$REPO_ROOT/scripts/sync-to-template.sh" > "$program"
  [ -s "$program" ] || {
    echo 'projection program extraction returned nothing' >&2
    return 1
  }
  python3 -I "$program" "$manifest"
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

  # A real TRELLIS_HOME always carries a registry; the mirror lint's fleet
  # identity guard reads it and fails closed without one. Model it here with
  # synthetic ids so the fixture matches the shape the publish path actually
  # runs against, rather than leaving the guard permanently unsatisfiable.
  cat > "$TRELLIS_HOME/registry.json" <<'EOF'
{
  "schema_version": 1,
  "projects": {
    "personal/fixtureproj": { "project_id": "fixtureproj" }
  }
}
EOF
  chmod 600 "$TRELLIS_HOME/registry.json"
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

make_agent_socket_fixture() {
  # Injected sockets are runner-owned inert pre-fence fixtures. Only our own
  # Bats subtree holds aliases/negative controls and is removed by teardown.
  if [ -n "${TRELLIS_TEST_SOCKET_PATH:-}" ]; then
    [ -n "${TRELLIS_TEST_SOCKET_METADATA:-}" ] || return 1
    AGENT_SOCKET_CANONICAL="$TRELLIS_TEST_SOCKET_PATH"
    [ -S "$AGENT_SOCKET_CANONICAL" ] && [ ! -L "$AGENT_SOCKET_CANONICAL" ] || return 1
    SOCKET_FIXTURE="$BATS_TEST_TMPDIR/socket-fixture"
    mkdir -p "$SOCKET_FIXTURE/real"
    ln -s "${AGENT_SOCKET_CANONICAL%/*}" "$SOCKET_FIXTURE/alias"
    return
  fi
  # Ordinary direct runs still bind a real AF_UNIX socket; no stand-in file.
  # The physical spelling of /tmp: short enough for the 104-byte sun_path limit
  # and free of symlinks, so the fixture's own path adds none of its own. It is
  # resolved rather than written as /private/tmp, which exists only on Darwin —
  # the hardcoded spelling made this case fail outright on Linux, which is where
  # CI runs it.
  local tmp_root
  tmp_root="$(CDPATH='' cd /tmp && pwd -P)"
  SOCKET_FIXTURE="$(mktemp -d "$tmp_root/trellis-agent-socket.XXXXXX")"
  mkdir -p "$SOCKET_FIXTURE/real"
  /usr/bin/perl -MSocket -e '
    socket(my $sock, PF_UNIX, SOCK_STREAM, 0) or die "socket: $!";
    bind($sock, sockaddr_un($ARGV[0])) or die "bind: $!";
  ' "$SOCKET_FIXTURE/real/agent.sock"
  # The stock macOS spelling reaches the launchd socket through /var, a symlink
  # to /private/var, so an alias directory reproduces the real-world path.
  ln -s "$SOCKET_FIXTURE/real" "$SOCKET_FIXTURE/alias"
  AGENT_SOCKET_CANONICAL="$SOCKET_FIXTURE/real/agent.sock"
}

require_verified_ssh_socket() {
  local check
  check="$(awk '/^mirror_require_verified_ssh_socket\(\) \{/,/^\}/' "$REPO_ROOT/scripts/sync-to-template.sh")"
  TRELLIS_VERIFIED_SSH_AUTH_SOCK="$1" /bin/bash --noprofile --norc -c "set -euo pipefail
$check
mirror_require_verified_ssh_socket"
}

@test "push accepts a socket reached through a symlinked directory and refuses a symlinked socket" {
  local canonical socket_parent
  make_agent_socket_fixture
  canonical="$AGENT_SOCKET_CANONICAL"
  socket_parent="${canonical%/*}"

  run require_verified_ssh_socket "$SOCKET_FIXTURE/alias/${canonical##*/}"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "$canonical" ] || { echo "$output"; false; }

  run require_verified_ssh_socket "$canonical"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "$canonical" ] || { echo "$output"; false; }

  ln -s "$canonical" "$SOCKET_FIXTURE/real/link.sock"
  run require_verified_ssh_socket "$SOCKET_FIXTURE/real/link.sock"
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  [[ "$output" == *'requires a verified SSH agent socket'* ]] || { echo "$output"; false; }

  : > "$SOCKET_FIXTURE/real/plain"
  run require_verified_ssh_socket "$SOCKET_FIXTURE/real/plain"
  [ "$status" -eq 5 ] || { echo "$output"; false; }

  run require_verified_ssh_socket "$socket_parent/../${socket_parent##*/}/${canonical##*/}"
  [ "$status" -eq 5 ] || { echo "$output"; false; }

  run require_verified_ssh_socket ""
  [ "$status" -eq 5 ] || { echo "$output"; false; }
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

@test "apply refuses an unpaired nested private core-rules entry before staging" {
  mirror_script="$SOURCE/scripts/sync-to-template.sh"
  /usr/bin/awk '$0 != "  '\''core-rules/skills/herdr-foreman'\''"' \
    "$mirror_script" > "$SANDBOX/unpaired-sync-to-template.sh"
  cat "$SANDBOX/unpaired-sync-to-template.sh" > "$mirror_script"
  rm -f "$SANDBOX/unpaired-sync-to-template.sh"
  git -C "$SOURCE" add scripts/sync-to-template.sh
  git -C "$SOURCE" commit -qm 'unpaired private core-rules policy'
  SOURCE_COMMIT="$(git -C "$SOURCE" rev-parse HEAD)"

  # Build and seal a fresh release from the committed invalid policy rather than
  # changing the already-verified payload behind its release record.
  chmod u+w "$RELEASE_DIR" "$RELEASE_DIR/release.json"
  find "$PAYLOAD" -type f -exec chmod u+w {} \;
  find "$PAYLOAD" -depth -type d -exec chmod u+w {} \;
  rm -rf "$PAYLOAD"
  mkdir -p "$PAYLOAD"
  git -C "$SOURCE" archive --format=tar "$SOURCE_COMMIT" | tar -x -C "$PAYLOAD"
  write_release_record
  find "$PAYLOAD" -type f -exec chmod a-w {} \;
  find "$PAYLOAD" -type d -exec chmod a-w {} \;
  chmod a-w "$RELEASE_DIR/release.json" "$RELEASE_DIR"

  mkdir -p "$MIRROR/core-rules/skills/herdr-foreman"
  printf '# Existing published executable\n' > "$MIRROR/core-rules/skills/herdr-foreman/SKILL.md"
  before="$(shasum -a 256 "$MIRROR/core-rules/skills/herdr-foreman/SKILL.md" | cut -d ' ' -f 1)"

  run_sync --apply

  [ "$status" -eq 4 ]
  [[ "$output" == *'nested private core-rules path is missing exact delist prune pair: skills/herdr-foreman -> core-rules/skills/herdr-foreman'* ]] ||
    { echo "$output"; false; }
  [[ "$output" != *'Staging portable policy'* ]] || { echo "$output"; false; }
  [ "$(shasum -a 256 "$MIRROR/core-rules/skills/herdr-foreman/SKILL.md" | cut -d ' ' -f 1)" = "$before" ]
}

@test "apply excludes and prunes the private Herdr skill while publishing its doctrine reference" {
  mkdir -p "$MIRROR/core-rules/skills/herdr-foreman"
  printf '# Stale published executable\n' > "$MIRROR/core-rules/skills/herdr-foreman/SKILL.md"
  git -C "$MIRROR" add -A
  git -C "$MIRROR" commit -qm seed

  run_sync --dry-run

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$MIRROR/core-rules/skills/herdr-foreman/SKILL.md" ]
  [ ! -e "$MIRROR/core-rules/references/herdr-foreman.md" ]

  run_sync --apply

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$MIRROR/core-rules/skills/herdr-foreman" ]
  [ "$(cat "$MIRROR/core-rules/references/herdr-foreman.md")" = '# Public Herdr doctrine fixture' ]
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
  cmp "$SOURCE/docs/PI-COMPUTER-USE.md" "$MIRROR/docs/PI-COMPUTER-USE.md"
  cmp "$SOURCE/docs/PI-COMPUTER-USE-UPGRADE-PROMPT.md" "$MIRROR/docs/PI-COMPUTER-USE-UPGRADE-PROMPT.md"
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

@test "the published dependency baseline and remediation ledger stay empty shells" {
  # Widening the allowlist to carry the pi subtree must not quietly widen what
  # these two bootstrap files carry. The source fixture seeds each with private
  # fleet observations; the mirror must receive the deterministic empty shell.
  run_sync --apply

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  jq -e '.toolchains == [] and .packages == [] and .security_floors == [] and .exceptions == []' \
    "$MIRROR/dependency-baseline.json" >/dev/null
  jq -e '.source_reports == [] and .findings == []' \
    "$MIRROR/audits/fleet-remediation-ledger.json" >/dev/null
  run grep -F 'private' "$MIRROR/dependency-baseline.json"
  [ "$status" -eq 1 ]
  run grep -F 'private' "$MIRROR/audits/fleet-remediation-ledger.json"
  [ "$status" -eq 1 ]
}

@test "apply publishes the portable pi surface and prunes the private roster" {
  mkdir -p "$MIRROR/core-rules/pi/agents"
  printf 'stale private roster leaf\n' > "$MIRROR/core-rules/pi/agents/private-roster-ro.md"
  git -C "$MIRROR" add -A
  git -C "$MIRROR" commit -qm seed

  run_sync --apply

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$MIRROR/core-rules/pi/extensions/trellis.ts" ]
  [ -f "$MIRROR/core-rules/pi/hooks/dispatch.sh" ]
  [ -x "$MIRROR/core-rules/pi/hooks/dispatch.sh" ]
  [ -f "$MIRROR/core-rules/pi/patches/apply-fixture-patches.sh" ]
  [ -f "$MIRROR/core-rules/pi/patches/pi-fixture-0.0.1-portable.patch" ]
  # Patch and companion test publish together, or the version pin is
  # unverifiable by whoever installs it.
  [ -f "$MIRROR/core-rules/pi/patches/tests/fixture-patch.test.mjs" ]
  [ ! -e "$MIRROR/core-rules/pi/agents" ]
  [ "$(git -C "$SOURCE" rev-parse HEAD:core-rules/pi/extensions/trellis.ts)" = \
    "$(git hash-object --no-filters "$MIRROR/core-rules/pi/extensions/trellis.ts")" ]
}

@test "the withheld roster's private sentinels never reach the mirror" {
  run_sync --apply

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # Each of these is present in the private roster fixture and would have
  # failed the mirror lint outright had the roster published, so the absence
  # cannot be vacuous: the same run that asserts them absent also asserts a
  # clean apply.
  run grep -rF -- "$(printf '/%s/%s' Users rosteroperator)" "$MIRROR"
  [ "$status" -eq 1 ]
  run grep -rF -- 'audits/2026-09-05-private' "$MIRROR"
  [ "$status" -eq 1 ]
  run grep -rF -- 'private-provider-2' "$MIRROR"
  [ "$status" -eq 1 ]
}

@test "apply projects the staged manifest and leaves the immutable source manifest byte-identical" {
  payload_before="$(shasum -a 256 "$PAYLOAD/core-rules/inheritance-manifest.json" | cut -d ' ' -f 1)"

  run_sync --apply

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'Projecting staged inheritance manifest'* ]] || { echo "$output"; false; }
  published="$MIRROR/core-rules/inheritance-manifest.json"
  [ -f "$published" ]

  # The two private entries are gone.
  jq -e '[.harnesses.shared_agents.links[] | select(.source_children == "core-rules/pi/agents")] | length == 0' \
    "$published" >/dev/null
  jq -e '[.harnesses.user.links[] | select(.source == "core-rules/skills/herdr-foreman")] | length == 0' \
    "$published" >/dev/null

  # Everything else — key order, harness order, sibling entries, the user link
  # whose name merely CONTAINS "herdr-foreman" — survives untouched.
  jq -e '(.harnesses | keys_unsorted) == ["shared_agents", "pi", "user"]' "$published" >/dev/null
  jq -e '.schema_version == 2' "$published" >/dev/null
  jq -e '[.harnesses.shared_agents.links[] | .source // .source_children]
         == ["core-rules/CLAUDE.md", "core-rules/skills"]' "$published" >/dev/null
  jq -e '[.harnesses.pi.links[] | .source]
         == ["core-rules/pi/extensions/trellis.ts", "core-rules/pi/hooks/dispatch.sh"]' "$published" >/dev/null
  jq -e '.harnesses.pi.links[1].executable == true' "$published" >/dev/null
  jq -e '[.harnesses.user.links[] | .source]
         == ["core-rules/hooks/herdr-foreman-session.sh"]' "$published" >/dev/null
  jq -e '.harnesses.user.links[0].destination_home == true' "$published" >/dev/null
  jq -e '(.harnesses.shared_agents.render | length) == 0' "$published" >/dev/null

  # Stable JSON with a trailing newline, not a stripped one-liner.
  [ "$(tail -c 1 "$published" | od -An -c | tr -d ' ')" = '\n' ]

  # The verified payload is read-only input and stays exactly as sealed.
  [ "$(shasum -a 256 "$PAYLOAD/core-rules/inheritance-manifest.json" | cut -d ' ' -f 1)" = "$payload_before" ]
  [ "$(git -C "$SOURCE" rev-parse HEAD:core-rules/inheritance-manifest.json)" = \
    "$(git hash-object --no-filters "$PAYLOAD/core-rules/inheritance-manifest.json")" ]
}

@test "dry-run leaves the mirror byte-identical and reapply republishes the same bytes" {
  run_sync --apply
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  git -C "$MIRROR" add -A
  git -C "$MIRROR" commit -qm published
  applied_state="$(git -C "$MIRROR" status --porcelain=v1 --untracked-files=all)"
  applied_tree="$(cd "$MIRROR" && find . -path ./.git -prune -o \( -type f -o -type l \) -print \
    | LC_ALL=C sort | xargs shasum -a 256)"

  run_sync --dry-run

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'simulated mirror clean.'* ]] || { echo "$output"; false; }
  [ "$(git -C "$MIRROR" status --porcelain=v1 --untracked-files=all)" = "$applied_state" ]
  [ "$(cd "$MIRROR" && find . -path ./.git -prune -o \( -type f -o -type l \) -print \
    | LC_ALL=C sort | xargs shasum -a 256)" = "$applied_tree" ]

  run_sync --apply

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(git -C "$MIRROR" status --porcelain=v1 --untracked-files=all)" = "$applied_state" ]
  [ "$(cd "$MIRROR" && find . -path ./.git -prune -o \( -type f -o -type l \) -print \
    | LC_ALL=C sort | xargs shasum -a 256)" = "$applied_tree" ]
}

@test "projection is a no-op over an already-portable manifest" {
  write_inheritance_manifest_fixture "$SANDBOX/full-manifest.json"
  jq '.harnesses.shared_agents.links |= map(select(.source_children != "core-rules/pi/agents"))
      | .harnesses.user.links |= map(select(.source != "core-rules/skills/herdr-foreman"))' \
    "$SANDBOX/full-manifest.json" > "$SOURCE/core-rules/inheritance-manifest.json"
  reseal_source_release 'already-portable manifest'
  expected="$(shasum -a 256 "$PAYLOAD/core-rules/inheritance-manifest.json" | cut -d ' ' -f 1)"

  run_sync --apply

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(shasum -a 256 "$MIRROR/core-rules/inheritance-manifest.json" | cut -d ' ' -f 1)" = "$expected" ]
}

@test "projection repair refuses numeric boolean aliases without changing staged bytes" {
  for value in 1 1.0; do
    write_inheritance_manifest_fixture "$SANDBOX/input.json"
    # Preserve the numeric spelling: jq serializes 1.0 back to 1.
    python3 - "$SANDBOX/input.json" "$value" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
path.write_text(path.read_text().replace('"destination_home": true', '"destination_home": ' + sys.argv[2]))
PY
    cp "$SANDBOX/input.json" "$SANDBOX/before.json"
    run project_manifest_with_publisher_program "$SANDBOX/input.json"
    echo "destination_home=$value raw_exit=$status $output"
    [ "$status" -eq 4 ]
    [[ "$output" == *'does not match the withheld shape'* ]]
    cmp "$SANDBOX/before.json" "$SANDBOX/input.json"
  done
}

@test "projection repair refuses misplaced and cross-array private sources under every source key" {
  for harness in shared_agents user; do
    for key in source source_children fallback_source; do
      for mode in misplaced duplicate; do
        write_inheritance_manifest_fixture "$SANDBOX/input.json"
        python3 - "$SANDBOX/input.json" "$harness" "$key" "$mode" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
document = json.loads(path.read_text())
harness, key, mode = sys.argv[2:]
links = document['harnesses'][harness]['links']
index = 1 if harness == 'shared_agents' else 0
entry = links[index].copy()
source_key = 'source_children' if harness == 'shared_agents' else 'source'
entry[key] = entry.pop(source_key)
document['harnesses']['pi']['links'].append(entry)
if mode == 'misplaced':
    del links[index]
path.write_text(json.dumps(document, indent=2) + '\n')
PY
        cp "$SANDBOX/input.json" "$SANDBOX/before.json"
        run project_manifest_with_publisher_program "$SANDBOX/input.json"
        echo "$harness $key $mode raw_exit=$status $output"
        [ "$status" -eq 4 ]
        [[ "$output" == *'misplaced or cross-array private source'* ]]
        cmp "$SANDBOX/before.json" "$SANDBOX/input.json"
      done
    done
  done
}

@test "projection repair preserves absent exact and idempotent controls and refuses extra keys" {
  write_inheritance_manifest_fixture "$SANDBOX/input.json"
  jq '.harnesses.shared_agents.links |= map(select(.source_children != "core-rules/pi/agents"))
      | .harnesses.user.links |= map(select(.source != "core-rules/skills/herdr-foreman"))' \
    "$SANDBOX/input.json" > "$SANDBOX/expected.json"
  run project_manifest_with_publisher_program "$SANDBOX/input.json"
  echo "exact raw_exit=$status $output"
  [ "$status" -eq 0 ]
  cmp "$SANDBOX/expected.json" "$SANDBOX/input.json"
  run project_manifest_with_publisher_program "$SANDBOX/input.json"
  echo "absent/idempotent raw_exit=$status $output"
  [ "$status" -eq 0 ]
  cmp "$SANDBOX/expected.json" "$SANDBOX/input.json"

  write_inheritance_manifest_fixture "$SANDBOX/full.json"
  jq '.harnesses.user.links[0].unexpected = true' "$SANDBOX/full.json" > "$SANDBOX/input.json"
  cp "$SANDBOX/input.json" "$SANDBOX/before.json"
  run project_manifest_with_publisher_program "$SANDBOX/input.json"
  echo "extra-key raw_exit=$status $output"
  [ "$status" -eq 4 ]
  [[ "$output" == *'does not match the withheld shape'* ]]
  cmp "$SANDBOX/before.json" "$SANDBOX/input.json"
}

@test "coverage repair checks the actual publisher function for valid unknown and symlink directories" {
  local program="$SANDBOX/coverage.sh" root="$SANDBOX/coverage"
  awk '/^check_payload_core_rules_coverage\(\) \{/ { inside = 1 }
       inside { print }
       inside && /^\}/ { exit }' "$REPO_ROOT/scripts/sync-to-template.sh" > "$program"
  [ -s "$program" ]
  cat >> "$program" <<'SH'
PAYLOAD_ROOT="$1"
sync_paths=(core-rules/hooks/ core-rules/bare)
core_rules_no_sync=(private)
check_payload_core_rules_coverage
SH
  mkdir -p "$root/core-rules/"{hooks,bare,private}
  run bash "$program" "$root"
  echo "valid raw_exit=$status $output"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  mkdir "$root/core-rules/unknown"
  run bash "$program" "$root"
  echo "unknown raw_exit=$status $output"
  [ "$status" -eq 1 ]
  [ "$output" = 'core-rules/unknown/' ]
  rmdir "$root/core-rules/unknown" "$root/core-rules/hooks"
  ln -s bare "$root/core-rules/hooks"
  run bash "$program" "$root"
  echo "symlink raw_exit=$status $output"
  [ "$status" -eq 1 ]
  [ "$output" = 'core-rules/hooks/' ]
}

@test "projection refuses a duplicated private manifest entry instead of guessing" {
  jq '.harnesses.shared_agents.links += [.harnesses.shared_agents.links[1]]' \
    "$SOURCE/core-rules/inheritance-manifest.json" > "$SANDBOX/dup-manifest.json"
  cat "$SANDBOX/dup-manifest.json" > "$SOURCE/core-rules/inheritance-manifest.json"
  reseal_source_release 'duplicated private manifest entry'
  printf 'unchanged mirror\n' > "$MIRROR/README.md"
  before="$(shasum -a 256 "$MIRROR/README.md" | cut -d ' ' -f 1)"

  run_sync --apply

  [ "$status" -eq 4 ]
  [[ "$output" == *'names private source core-rules/pi/agents 2 times in shared_agents.links'* ]] ||
    { echo "$output"; false; }
  [[ "$output" != *'applied.'* ]] || { echo "$output"; false; }
  [ "$(shasum -a 256 "$MIRROR/README.md" | cut -d ' ' -f 1)" = "$before" ]
}

@test "projection refuses a private entry whose destination semantics were altered" {
  jq '.harnesses.user.links[0].destination = ".claude/skills/renamed-foreman"' \
    "$SOURCE/core-rules/inheritance-manifest.json" > "$SANDBOX/altered-manifest.json"
  cat "$SANDBOX/altered-manifest.json" > "$SOURCE/core-rules/inheritance-manifest.json"
  reseal_source_release 'altered private destination semantics'

  run_sync --apply

  [ "$status" -eq 4 ]
  [[ "$output" == *'core-rules/skills/herdr-foreman in user.links does not match the withheld shape'* ]] ||
    { echo "$output"; false; }
  [ ! -e "$MIRROR/core-rules/inheritance-manifest.json" ]
}

@test "private content injected into an included portable pi file fails the mirror lint" {
  printf 'const root = "/%s/leakoperator/.pi/agent";\nexport default root;\n' Users \
    > "$SOURCE/core-rules/pi/extensions/trellis.ts"
  reseal_source_release 'operator path inside a portable pi file'
  mirror_before="$(git -C "$MIRROR" status --porcelain=v1 --untracked-files=all)"

  run_sync --dry-run

  [ "$status" -eq 4 ]
  # The STAGE lint fires first, before a simulated mirror is ever built, so the
  # leak never reaches the destination-shaped check at all. Assert the message
  # this path actually emits rather than the later `MIRROR LINT FAILED` banner.
  [[ "$output" == *'staged policy contains forbidden content'* ]] || { echo "$output"; false; }
  [[ "$output" == *'core-rules/pi/extensions/trellis.ts: absolute-path leak'* ]] || { echo "$output"; false; }
  [ "$(git -C "$MIRROR" status --porcelain=v1 --untracked-files=all)" = "$mirror_before" ]
}

# Portable installability proof, and the only test here that reads the REAL
# manifest and the REAL exported sources. It runs the publisher's own projection
# program and then the actual planner — no stubbed responses, no second
# attachment mechanism. `project_target` resolution stays planner-owned; nothing
# below asserts on it.
@test "the projected real manifest closes against the real exported sources for every harness selection" {
  local export_root="$SANDBOX/real-export" plan
  mkdir -p "$export_root"
  rsync -a --links --safe-links \
    --exclude='core-rules/pi/agents' \
    --exclude='core-rules/skills/herdr-foreman' \
    --exclude='core-rules/evals' \
    --exclude='core-rules/usage-federation' \
    "$REPO_ROOT/core-rules" "$export_root/"

  # Unprojected, the real manifest cannot close against the exported subset:
  # this is the failure the projection exists to remove, asserted before the fix
  # so the passing assertions below are not vacuous.
  run bash "$REPO_ROOT/scripts/lib/surface-plan.sh" --payload "$export_root" --harness pi
  [ "$status" -eq 4 ]
  [[ "$output" == *'required source is missing from immutable payload: core-rules/pi/agents'* ]] ||
    { echo "$output"; false; }
  run bash "$REPO_ROOT/scripts/lib/surface-plan.sh" --payload "$export_root" --harness user
  [ "$status" -eq 4 ]
  [[ "$output" == *'required source is missing from immutable payload: core-rules/skills/herdr-foreman'* ]] ||
    { echo "$output"; false; }

  run project_manifest_with_publisher_program "$export_root/core-rules/inheritance-manifest.json"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  for selection in "--harness pi" "--harness codex" "--harness user"; do
    # shellcheck disable=SC2086  # deliberate word splitting of the selection
    run bash "$REPO_ROOT/scripts/lib/surface-plan.sh" --payload "$export_root" $selection
    [ "$status" -eq 0 ] || { echo "$selection"; echo "$output"; false; }
    [ "$(printf '%s' "$output" | jq '.artifacts | length')" -gt 0 ] || { echo "$selection"; echo "$output"; false; }
  done

  run bash "$REPO_ROOT/scripts/lib/surface-plan.sh" --payload "$export_root" \
    --harness claude --harness codex --harness pi
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  plan="$output"
  [ "$(printf '%s' "$plan" | jq '.artifacts | length')" -gt 0 ]
  [ "$(printf '%s' "$plan" | jq '[.artifacts[] | select(.destination | test("\\.agents/agents/"))] | length')" -eq 0 ]

  # The user surface keeps its hook and output-style links and its settings
  # render; only the private skill link is gone.
  run bash "$REPO_ROOT/scripts/lib/surface-plan.sh" --payload "$export_root" --harness user
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(printf '%s' "$output" | jq -r '[.artifacts[] | .destination | sub("^.*/\\.claude/"; ".claude/")] | sort | join(",")')" = \
    '.claude/hooks/herdr-foreman-session.sh,.claude/output-styles/trellis-orchestration.md,.claude/settings.json' ]
}

@test "removing a required portable manifest source fails closure at the business boundary" {
  local export_root="$SANDBOX/incomplete-export"
  mkdir -p "$export_root"
  rsync -a --links --safe-links \
    --exclude='core-rules/pi/agents' \
    --exclude='core-rules/skills/herdr-foreman' \
    --exclude='core-rules/evals' \
    --exclude='core-rules/usage-federation' \
    "$REPO_ROOT/core-rules" "$export_root/"
  run project_manifest_with_publisher_program "$export_root/core-rules/inheritance-manifest.json"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  rm -f "$export_root/core-rules/pi/extensions/trellis.ts"

  run bash "$REPO_ROOT/scripts/lib/surface-plan.sh" --payload "$export_root" --harness pi
  [ "$status" -eq 4 ]
  [[ "$output" == *'required source is missing from immutable payload: core-rules/pi/extensions/trellis.ts'* ]] ||
    { echo "$output"; false; }
}
