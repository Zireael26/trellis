#!/usr/bin/env bats
# Tests for scripts/doctor.sh — the P1 read-only inheritance health checker.
#
# FULLY ISOLATED from the live registry and the 7 real managed projects.
# Every test stands up its own fixture in a fresh `mktemp` dir:
#   <sandbox>/canonical   — a real git repo (the fixture canonical clone)
#   <sandbox>/projects     — the fixture PROJECTS_ROOT
#   <sandbox>/trellis.config.json — points trellis_root/projects_root at the above
# and exports $TRELLIS_CONFIG so config-load.sh resolves the FIXTURE config and
# never the worktree's real one (whose trellis_root is the live clone).
#
# Isolation invariant (asserted in at least one test): the doctor's
# "canonical clone:" header line must equal the fixture path. If it ever prints
# the live canonical clone path (the repo's own trellis_root) instead, the test
# has leaked.
#
# bash 3.2 / bats 1.x. Path note: $CANON is captured once via `cd && pwd` and
# reused verbatim for the config's trellis_root, every symlink target, and every
# assertion — hc_rules_symlink string-compares readlink output against
# "$CANON/core-rules/CLAUDE.md", so the fixture must not mix /var with
# /private/var spellings.

# Resolve paths relative to this test file so the suite is portable (no
# machine-specific absolute paths — those would also leak into the public
# mirror). $BATS_TEST_DIRNAME is scripts/tests/, so ../.. is the repo root.
REPO_ROOT="$( cd "$BATS_TEST_DIRNAME/../.." && pwd )"
DOCTOR="$REPO_ROOT/scripts/doctor.sh"
SHOW_CONFIG="$REPO_ROOT/scripts/show-config.sh"
SHARED_FIXTURE="$BATS_TEST_DIRNAME/fixtures/shared-infra"
# The live canonical clone — what doctor must NOT print when run against a
# fixture (proves the $TRELLIS_CONFIG override took effect). This is THIS
# checkout: doctor's legacy mode reports whatever `trellis_root` the config it
# is handed names, and the checkout the suite runs from is the canonical clone
# on this machine.
#
# It used to be read as `jq -r '.trellis_root' trellis.config.json`. That field
# is machine-local state and the tracked portable policy is now forbidden to
# carry it (config-load.sh rejects a policy that does), so jq printed the
# string "null" and exited 0 — the `|| true` never fired. LIVE_CANON was
# therefore the literal "null" and the isolation assertion below degenerated
# into "the report does not contain the word null", which no isolation leak can
# make false. Resolved through `pwd -P` for the same /var-vs-/private/var
# reason $CANON is.
LIVE_CANON="$(CDPATH= cd "$REPO_ROOT" && pwd -P)"

# The full canonical inheritance surface a healthy project carries. Kept in
# lockstep with HC_CANONICAL_SKILLS / HC_CANONICAL_COMMANDS in health-checks.sh.
CANON_SKILLS="process-gate security-gate aeo-gate clarify spec plan tasks analyze execute brainstorming orchestrate debrief writing wiki-maintain wiki-skill-propose"
CANON_COMMANDS="primer primer-refresh primer-check explore autonomy surgical"

setup() {
  SANDBOX="$(mktemp -d)"
  # Resolve through the real path so /var vs /private/var cannot diverge between
  # the symlink targets we write and the config's trellis_root.
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  CANON="$SANDBOX/canonical"
  PROJECTS="$SANDBOX/projects"
  SHARED="$SANDBOX/shared-infra"
  CFG="$SANDBOX/trellis.config.json"
  mkdir -p "$CANON" "$PROJECTS"
  DOCTOR_SHARED_OVERRIDE=""
  export TRELLIS_CONFIG="$CFG"
  unset PORTABLE_STRICT_PRESET_CONTENT
}

teardown() {
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    chmod -R u+w "$SANDBOX" 2>/dev/null || true
    rm -rf "$SANDBOX"
  fi
}

# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------

# Lay down the canonical inheritance surface (rules file, skills, commands,
# empty agents dir, registry with one active "healthy" project, and empty
# blacklist). The agents dir holds only a .gitkeep. Does NOT git init — branch
# and clean state are set
# per test by the helpers below.
build_canonical_tree() {
  mkdir -p "$CANON/core-rules/skills" "$CANON/core-rules/commands" \
    "$CANON/core-rules/agents"
  # A healthy canonical carries the dod-receipt grammar anchor (Tier-0
  # hc_receipt_grammar_present greps for the literal `dod-receipt`).
  printf '# Parent engineering rules\n\n<!-- dod-receipt cmd= exit=0 diff= -->\n' \
    > "$CANON/core-rules/CLAUDE.md"
  local s c
  for s in $CANON_SKILLS; do
    mkdir -p "$CANON/core-rules/skills/$s"
    printf -- '---\nname: %s\ndescription: fixture skill %s\n---\n\nx\n' \
      "$s" "$s" > "$CANON/core-rules/skills/$s/SKILL.md"
  done
  for c in $CANON_COMMANDS; do
    printf -- '---\ndescription: fixture command %s\n---\n\nx\n' \
      "$c" > "$CANON/core-rules/commands/$c.md"
  done
  # The canonical agents dir is empty; only .gitkeep remains.
  printf '' > "$CANON/core-rules/agents/.gitkeep"
  cat > "$CANON/registry.md" <<EOF
# Project registry

## Active projects

| Project | Path | Class | Notes |
|---|---|---|---|
| healthy | \`/personal/healthy\` | app | fixture |

---
EOF
  cat > "$CANON/blacklist.md" <<EOF
# Blacklist

## 1. Temporarily excluded (registered projects)

| Project | Reason | Added | Review after |
|---|---|---|---|
| — | — | — | — |

## 2. Permanently excluded from management

| Path | Reason |
|---|---|

## Semantics
EOF
}

# Append one more row to the fixture registry's Active-projects table. Must run
# AFTER build_canonical_tree and BEFORE git_init_canonical_main (which commits
# the canonical) so the tree stays clean.
register_project() {
  local name="$1" tmp
  tmp="$CANON/registry.md.new"
  awk -v row="| $name | \`/personal/$name\` | app | fixture |" '
    { print }
    /^\| healthy \|/ && !inserted { print row; inserted = 1 }
  ' "$CANON/registry.md" > "$tmp"
  mv "$tmp" "$CANON/registry.md"
  grep -Fq "| $name |" "$CANON/registry.md" ||
    { echo "register_project: row for '$name' was not written"; false; }
}

# git init the canonical on `main` and make one commit so the tree is clean.
git_init_canonical_main() {
  (
    cd "$CANON"
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name  "test"
    git config commit.gpgsign false
    git add -A
    git commit -q -m "init"
  )
}

# Write the fixture trellis.config.json. $1 (optional) = space-separated
# harness list as a JSON array body; defaults to the Claude baseline. Tests
# that exercise Codex parity enable it explicitly.
write_config() {
  local harnesses_json="${1:-\"claude\"}"
  local shared_root="${2:-}"
  local shared_line=""
  if [ -n "$shared_root" ]; then
    shared_line="  \"shared_infra_root\": \"$shared_root\","
  fi
  cat > "$CFG" <<EOF
{
  "trellis_root": "$CANON",
  "projects_root": "$PROJECTS",
$shared_line
  "user_home": "$SANDBOX",
  "maintainer_name": "Test Maintainer",
  "github_user": "tester",
  "harnesses": [$harnesses_json]
}
EOF
}

# Portable-doctor fixture: local machine state is intentionally separate from
# the legacy TRELLIS_CONFIG fixture above. It exercises only the T15 contract.
build_portable_doctor_home() {
  PORTABLE_HOME="$SANDBOX/portable-home"
  PORTABLE_SOURCE="$SANDBOX/portable-source"
  PORTABLE_PROJECT="$SANDBOX/portable project"
  PORTABLE_ACCOUNT_HOME="$SANDBOX/portable-account"
  mkdir -p "$PORTABLE_HOME" "$PORTABLE_SOURCE" "$PORTABLE_PROJECT" "$PORTABLE_ACCOUNT_HOME/.local/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$PORTABLE_ACCOUNT_HOME/.local/bin/trellis"
  chmod 755 "$PORTABLE_ACCOUNT_HOME/.local/bin/trellis"
  chmod 700 "$PORTABLE_HOME"
  printf '{"schema_version":2,"harnesses":["claude","codex"]}\n' \
    > "$PORTABLE_SOURCE/trellis.config.json"
  cat > "$PORTABLE_HOME/config.json" <<EOF
{"schema_version":1,"source_root":"$PORTABLE_SOURCE","release_remote":"$PORTABLE_SOURCE","active_cli_release":"1.2.3","default_fleet":"personal","fleets":{"personal":{"discovery_roots":["$SANDBOX"]}}}
EOF
  chmod 600 "$PORTABLE_HOME/config.json"
  printf '{"schema_version":1,"projects":{},"discovery_ignores":{}}\n' \
    > "$PORTABLE_HOME/registry.json"
  chmod 600 "$PORTABLE_HOME/registry.json"
  git -C "$PORTABLE_PROJECT" init -q -b main
  printf '{"schema_version":1,"project_id":"portable-fixture"}\n' \
    > "$PORTABLE_PROJECT/.trellis.json"
  git -C "$PORTABLE_PROJECT" add .trellis.json
  git -C "$PORTABLE_PROJECT" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm initial
  build_portable_release
}

build_portable_release() {
  local version="${1:-1.2.3}" manifest command_name hook
  PORTABLE_RELEASE_DIR="$PORTABLE_HOME/releases/$version"
  PORTABLE_RELEASE_PAYLOAD="$PORTABLE_RELEASE_DIR/payload"
  manifest="$SANDBOX/portable-release-$version.jsonl"
  mkdir -p \
    "$PORTABLE_RELEASE_PAYLOAD/core-rules/skills/fixture" \
    "$PORTABLE_RELEASE_PAYLOAD/core-rules/commands/templates" \
    "$PORTABLE_RELEASE_PAYLOAD/core-rules/agents" \
    "$PORTABLE_RELEASE_PAYLOAD/core-rules/hooks/lib" \
    "$PORTABLE_RELEASE_PAYLOAD/core-rules/githooks" \
    "$PORTABLE_RELEASE_PAYLOAD/core-rules/codex/hooks/lib" \
    "$PORTABLE_RELEASE_PAYLOAD/core-rules/templates" \
    "$PORTABLE_RELEASE_PAYLOAD/core-rules/templates/claude-output-styles" \
    "$PORTABLE_RELEASE_PAYLOAD/core-rules/presets"
  cp "$REPO_ROOT/core-rules/inheritance-manifest.json" \
    "$PORTABLE_RELEASE_PAYLOAD/core-rules/inheritance-manifest.json"
  cp -R "$REPO_ROOT/core-rules/pi" "$PORTABLE_RELEASE_PAYLOAD/core-rules/pi"
  cp "$REPO_ROOT/core-rules/templates/claude-settings.local.json" \
    "$PORTABLE_RELEASE_PAYLOAD/core-rules/templates/claude-settings.local.json"
  cp "$REPO_ROOT/core-rules/templates/codex-hooks.local.json" \
    "$PORTABLE_RELEASE_PAYLOAD/core-rules/templates/codex-hooks.local.json"
  cp "$REPO_ROOT/core-rules/templates/claude-user-settings.json" \
    "$PORTABLE_RELEASE_PAYLOAD/core-rules/templates/claude-user-settings.json"
  cp "$REPO_ROOT/core-rules/templates/claude-output-styles/trellis-orchestration.md" \
    "$PORTABLE_RELEASE_PAYLOAD/core-rules/templates/claude-output-styles/trellis-orchestration.md"
  cp -R "$REPO_ROOT/core-rules/skills/herdr-foreman" \
    "$PORTABLE_RELEASE_PAYLOAD/core-rules/skills/"
  cp "$REPO_ROOT/core-rules/hooks/herdr-foreman-session.sh" \
    "$PORTABLE_RELEASE_PAYLOAD/core-rules/hooks/herdr-foreman-session.sh"
  mkdir -p "$PORTABLE_RELEASE_PAYLOAD/scripts"
  cp "$REPO_ROOT/scripts/attach-project.sh" \
    "$PORTABLE_RELEASE_PAYLOAD/scripts/attach-project.sh"
  cp "$REPO_ROOT/scripts/trellis-launcher.sh" "$PORTABLE_RELEASE_PAYLOAD/scripts/trellis-launcher.sh"
  cp -R "$REPO_ROOT/scripts/lib" "$PORTABLE_RELEASE_PAYLOAD/scripts/lib"
  cp "$REPO_ROOT/scripts/seed-inheritance-symlinks.sh" \
    "$PORTABLE_RELEASE_PAYLOAD/scripts/seed-inheritance-symlinks.sh"
  cp "$REPO_ROOT/core-rules/hooks/lib/autonomy.sh" \
    "$PORTABLE_RELEASE_PAYLOAD/core-rules/hooks/lib/autonomy.sh"
  chmod 755 "$PORTABLE_RELEASE_PAYLOAD/scripts/attach-project.sh" \
    "$PORTABLE_RELEASE_PAYLOAD/scripts/seed-inheritance-symlinks.sh"
  cat > "$PORTABLE_RELEASE_PAYLOAD/trellis.config.json" <<'EOF'
{"schema_version":2,"maintainer_name":"Fixture","github_user":"fixture","harnesses":["claude","codex"],"autonomy_default":2}
EOF
  printf '%s\n' "$version" > "$PORTABLE_RELEASE_PAYLOAD/core-rules/VERSION"
  if [ -n "${PORTABLE_STRICT_PRESET_CONTENT:-}" ]; then
    printf '%s\n' "$PORTABLE_STRICT_PRESET_CONTENT" \
      > "$PORTABLE_RELEASE_PAYLOAD/core-rules/presets/strict.md"
  else
    cat > "$PORTABLE_RELEASE_PAYLOAD/core-rules/presets/strict.md" <<'EOF'
---
autonomy_default: 4
autonomy_ceiling: 2
---
Fixture preset
EOF
  fi
  printf '# fixture rules\n' > "$PORTABLE_RELEASE_PAYLOAD/core-rules/CLAUDE.md"
  printf -- '---\nname: fixture\ndescription: fixture\n---\n' \
    > "$PORTABLE_RELEASE_PAYLOAD/core-rules/skills/fixture/SKILL.md"
  for command_name in fixture primer primer-refresh primer-check explore surgical; do
    printf '# fixture command %s\n' "$command_name" \
      > "$PORTABLE_RELEASE_PAYLOAD/core-rules/commands/$command_name.md"
  done
  printf '# primer index template\n' \
    > "$PORTABLE_RELEASE_PAYLOAD/core-rules/commands/templates/primer-index-template.md"
  printf '# fixture agent\n' > "$PORTABLE_RELEASE_PAYLOAD/core-rules/agents/fixture.md"
  printf '#!/usr/bin/env bash\nexit 0\n' \
    > "$PORTABLE_RELEASE_PAYLOAD/core-rules/hooks/fixture.sh"
  chmod 755 "$PORTABLE_RELEASE_PAYLOAD/core-rules/hooks/fixture.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' \
    > "$PORTABLE_RELEASE_PAYLOAD/core-rules/githooks/pre-push"
  chmod 755 "$PORTABLE_RELEASE_PAYLOAD/core-rules/githooks/pre-push"
  # Every lib the manifest declares as an EXPLICIT codex link source has to exist
  # here: surface-plan treats a declared source as mandatory and exits 4 on the
  # first one missing, which fails prepare_portable_attachment for the whole suite.
  # This builder copies a hand-picked set, so a new manifest entry lands here too.
  for hook in fixture aeo-gate-warn code-reviewer decision-receipt-core slop-patterns spec-gate-core ui-verify-core verification-receipt action-normalize hookspath-check; do
    printf '#!/usr/bin/env bash\nexit 0\n' \
      > "$PORTABLE_RELEASE_PAYLOAD/core-rules/hooks/lib/$hook.sh"
    chmod 755 "$PORTABLE_RELEASE_PAYLOAD/core-rules/hooks/lib/$hook.sh"
  done
  # Shared task and verification primitives are explicit manifest link sources.
  # Keep this minimal payload complete before its immutable tree is sealed.
  for primitive in task-context.sh task-state.py verification-bash.py guard-supervise.pl; do
    cp "$REPO_ROOT/core-rules/hooks/lib/$primitive" "$PORTABLE_RELEASE_PAYLOAD/core-rules/hooks/lib/$primitive" || return 1
  done
  printf '#!/usr/bin/env bash\nexit 0\n' \
    > "$PORTABLE_RELEASE_PAYLOAD/core-rules/codex/hooks/fixture.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' \
    > "$PORTABLE_RELEASE_PAYLOAD/core-rules/codex/hooks/lib/fixture.sh"
  chmod 755 "$PORTABLE_RELEASE_PAYLOAD/core-rules/codex/hooks/fixture.sh" \
    "$PORTABLE_RELEASE_PAYLOAD/core-rules/codex/hooks/lib/fixture.sh"
  python3 "$REPO_ROOT/scripts/tests/helpers/fixture-tree-manifest.py" "$PORTABLE_RELEASE_PAYLOAD" > "$manifest"
  jq -n --arg version "$version" --slurpfile tree "$manifest" '
    {
      schema_version: 1,
      version: $version,
      tag: ("v" + $version),
      commit: "0000000000000000000000000000000000000000",
      remote: "fixture://release",
      tree: $tree
    }
  ' > "$PORTABLE_RELEASE_DIR/release.json"
  find "$PORTABLE_RELEASE_PAYLOAD" -type f -exec chmod a-w {} +
  find "$PORTABLE_RELEASE_PAYLOAD" -type d -exec chmod a-w {} +
  chmod a-w "$PORTABLE_RELEASE_DIR/release.json" "$PORTABLE_RELEASE_DIR"
}

copy_portable_older_release() {
  local base="$PORTABLE_HOME/releases/1.2.3"
  local release="$PORTABLE_HOME/releases/1.2.2"
  local payload="$release/payload"
  local manifest="$SANDBOX/portable-release-1.2.2.jsonl"

  cp -R "$base" "$release"
  chmod -R u+w "$release"
  mkdir -p "$payload/scripts/lib"
  cp "$REPO_ROOT/scripts/lib/attachment.sh" "$payload/scripts/lib/attachment.sh"
  # The copied generator extracts command-scratch programs from its own launcher.
  cp "$REPO_ROOT/scripts/trellis-launcher.sh" "$payload/scripts/trellis-launcher.sh"
  sed \
    -e '/^[[:space:]]*TRELLIS_ALLOW_MAIN_PUSH=.*$/d' \
    -e '/^[[:space:]]*SECURITY_GATE_SKIP=.*$/d' \
    -e '/^[[:space:]]*export TRELLIS_ALLOW_MAIN_PUSH SECURITY_GATE_SKIP$/d' \
    "$payload/scripts/lib/attachment.sh" > "$payload/scripts/lib/attachment.sh.tmp"
  mv "$payload/scripts/lib/attachment.sh.tmp" "$payload/scripts/lib/attachment.sh"
  printf '1.2.2\n' > "$payload/core-rules/VERSION"

  python3 "$REPO_ROOT/scripts/tests/helpers/fixture-tree-manifest.py" "$payload" > "$manifest"
  jq -n --arg version 1.2.2 --slurpfile tree "$manifest" '{
    schema_version:1,
    version:$version,
    tag:("v" + $version),
    commit:"0000000000000000000000000000000000000000",
    remote:"fixture://copied-older-release",
    tree:$tree
  }' > "$release/release.json"
  find "$payload" -type f -exec chmod a-w {} +
  find "$payload" -type d -exec chmod a-w {} +
  chmod a-w "$release/release.json" "$release"
}


run_portable_doctor() {
  run env -u TRELLIS_CONFIG HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" bash "$DOCTOR" "$@"
}

# show-config's entry gate is attestation-based and default-refuse, exactly like
# release.sh, upgrade.sh, and sync-to-template.sh. There is therefore no such
# thing as a meaningful direct call to "$SHOW_CONFIG": with no attestation the
# only observable behaviour is the refusal, so every behavioural test below has
# to run the command the way the launcher runs it — from the sealed execution
# snapshot of the configured release, with the launcher's verified payload
# identity exported across the boundary. This mirrors how the upgrade tests
# reach the upgrade body (scripts/tests/upgrade-semver.bats: an env-attested
# direct call whose TRELLIS_VERIFIED_PAYLOAD names a real release-store path).
PORTABLE_SHOW_CONFIG_SNAPSHOT_SUFFIX="Ab3xY9"

# The snapshot path the launcher would execute for release 1.2.3. Created on
# first use so a test that rebuilds the release fixture still gets a copy that
# matches it.
portable_show_config_snapshot() {
  local snapshot="$PORTABLE_HOME/releases/.tmp.1.2.3.exec.$PORTABLE_SHOW_CONFIG_SNAPSHOT_SUFFIX/payload"
  if [ ! -f "$snapshot/scripts/show-config.sh" ]; then
    copy_show_config_into "$snapshot" >/dev/null
  fi
  printf '%s\n' "$snapshot"
}

# Run the attested copy. Callers pass show-config's own argv; with none they get
# the default `--home "$PORTABLE_HOME"`. SHOW_CONFIG_CALLER_HOME overrides the
# account HOME (the caller-controlled value tests probe); TRELLIS_HOME is part
# of the attestation the launcher mints, so it is not caller-overridable here.
run_portable_show_config() {
  local snapshot
  snapshot="$(portable_show_config_snapshot)"
  [ "$#" -gt 0 ] || set -- --home "$PORTABLE_HOME"
  run env -u TRELLIS_CONFIG \
    HOME="${SHOW_CONFIG_CALLER_HOME-$PORTABLE_ACCOUNT_HOME}" \
    TRELLIS_HOME="$PORTABLE_HOME" \
    TRELLIS_VERIFIED_PAYLOAD="$snapshot" \
    TRELLIS_VERIFIED_RELEASE_VERSION=1.2.3 \
    bash -c '
      cd "$1" || exit $?
      shift
      script="$1"
      shift
      exec bash "$script" "$@"
    ' show-config "$PORTABLE_PROJECT" "$snapshot/scripts/show-config.sh" "$@"
}

portable_file_mode() {
  local candidate
  candidate="$(stat -f '%Lp' "$1" 2>/dev/null)" || candidate=""
  case "$candidate" in
    ''|*[!0-7]*) candidate="" ;;
  esac
  if [ -z "$candidate" ]; then
    candidate="$(stat -c '%a' "$1" 2>/dev/null)" || return 1
  fi
  printf '%s\n' "$candidate"
}

portable_registry_sha256() {
  bash -c '. "$1"; . "$2"; local_registry_sha256 "$3"' _ \
    "$REPO_ROOT/scripts/lib/trellis-home.sh" "$REPO_ROOT/scripts/lib/local-registry.sh" "$1"
}

portable_file_sha256() {
  local digest
  digest="$(shasum -a 256 "$1" 2>/dev/null)" ||
    digest="$(sha256sum "$1" 2>/dev/null)" || return 1
  digest="${digest%% *}"
  printf '%s\n' "$digest"
}

rewrite_portable_registry() {
  local next="$SANDBOX/portable-registry.next"
  jq "$@" "$PORTABLE_HOME/registry.json" > "$next" || return 1
  mv -f "$next" "$PORTABLE_HOME/registry.json" || return 1
  chmod 600 "$PORTABLE_HOME/registry.json"
}

# A registered sibling whose recorded root is present but is not a Git worktree:
# the stored hashes still verify, so the row is an identity_error rather than a
# merely unavailable root.
# A sibling project whose CHECKOUT row is healthy and whose extra worktree row
# is both unreachable and wrongly keyed. That combination is the one the two
# classifiers disagreed about: the strict validator compares stored hashes
# before the reachability short-circuit and calls it class 4, while the
# diagnostic classifier short-circuited on reachability first and called it
# `unavailable`. The checkout must stay healthy or the checkout-row fold would
# mark the row `identity_error` on its own and the case would stop
# discriminating.
add_portable_unreachable_drift_sibling() {
  local sibling="$SANDBOX/portable sibling repo" gone="$SANDBOX/portable sibling gone"
  local identity checkout_id worktree_id common zero
  mkdir -p "$sibling"
  git -C "$sibling" init -q -b main
  printf '{"schema_version":1,"project_id":"portable-sibling"}\n' > "$sibling/.trellis.json"
  git -C "$sibling" add .trellis.json
  git -C "$sibling" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm initial
  identity="$(bash -c '. "$1"; . "$2"; local_registry_identity_for_root "$3"' _ \
    "$REPO_ROOT/scripts/lib/trellis-home.sh" "$REPO_ROOT/scripts/lib/local-registry.sh" "$sibling")" || return 1
  checkout_id="$(printf '%s\n' "$identity" | jq -r '.checkout_id')" || return 1
  worktree_id="$(printf '%s\n' "$identity" | jq -r '.worktree_id')" || return 1
  common="$(printf '%s\n' "$identity" | jq -r '.git_common_dir')" || return 1
  zero="$(printf '0%.0s' $(seq 64))"
  [ ! -e "$gone" ] || return 1
  rewrite_portable_registry \
    --arg root "$sibling" --arg common "$common" --arg checkout "$checkout_id" \
    --arg worktree "$worktree_id" --arg gone "$gone" --arg zero "$zero" '
      .projects["personal/portable-sibling"] = {
        fleet: "personal",
        project_id: "portable-sibling",
        status: "active",
        metadata: {},
        checkouts: {
          ($checkout): {
            root: $root,
            git_common_dir: $common,
            harnesses: ["claude"],
            release: "1.2.3",
            worktrees: {($worktree): {root: $root}, ($zero): {root: $gone}}
          }
        }
      }'
}

add_portable_identity_error_sibling() {
  local sibling="$SANDBOX/portable sibling" checkout_id worktree_id
  mkdir -p "$sibling"
  checkout_id="$(portable_registry_sha256 "$sibling/.git")" || return 1
  worktree_id="$(portable_registry_sha256 "$sibling")" || return 1
  rewrite_portable_registry \
    --arg root "$sibling" --arg common "$sibling/.git" \
    --arg checkout "$checkout_id" --arg worktree "$worktree_id" '
      .projects["personal/portable-sibling"] = {
        fleet: "personal",
        project_id: "portable-sibling",
        status: "active",
        metadata: {},
        checkouts: {
          ($checkout): {
            root: $root,
            git_common_dir: $common,
            harnesses: ["claude"],
            release: "1.2.3",
            worktrees: {($worktree): {root: $root}}
          }
        }
      }'
}

prepare_portable_attachment() {
  local owner_project_id="${1:-portable-fixture}" release="${2:-1.2.3}"
  local identity checkout_id worktree_id owner
  run env -u TRELLIS_CONFIG HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" \
    bash "$REPO_ROOT/scripts/attach-project.sh" attach --home "$PORTABLE_HOME" \
      --fleet personal --release "$release" \
      --harness claude --harness codex "$PORTABLE_PROJECT"
  if [ "$status" -ne 0 ]; then
    printf 'prepare_portable_attachment failed (exit %s):\n%s\n' "$status" "$output" >&2
    return "$status"
  fi
  identity="$(bash -c '. "$1"; . "$2"; local_registry_identity_for_root "$3"' _ \
    "$REPO_ROOT/scripts/lib/trellis-home.sh" "$REPO_ROOT/scripts/lib/local-registry.sh" "$PORTABLE_PROJECT")"
  checkout_id="$(printf '%s\n' "$identity" | jq -r '.checkout_id')"
  worktree_id="$(printf '%s\n' "$identity" | jq -r '.worktree_id')"
  PORTABLE_CHECKOUT_ID="$checkout_id"
  PORTABLE_WORKTREE_ID="$worktree_id"
  owner="$PORTABLE_HOME/state/attachments/$checkout_id/$worktree_id.json"
  if [ "$owner_project_id" != "portable-fixture" ]; then
    jq --arg project_id "$owner_project_id" '.project_id = $project_id' "$owner" > "$owner.next"
    mv "$owner.next" "$owner"
    chmod 600 "$owner"
  fi
}

prepare_portable_user_attachment() {
  local owner
  run env -u TRELLIS_CONFIG HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" \
    bash "$PORTABLE_RELEASE_PAYLOAD/scripts/attach-project.sh" \
      attach --user --home "$PORTABLE_HOME" --release 1.2.3
  if [ "$status" -ne 0 ]; then
    printf 'prepare_portable_user_attachment failed (exit %s):\n%s\n' "$status" "$output" >&2
    return "$status"
  fi
  owner="$PORTABLE_HOME/attachments/user.json"
  [ -f "$owner" ] && [ ! -L "$owner" ] || {
    printf 'prepare_portable_user_attachment did not commit %s\n' "$owner" >&2
    return 1
  }
  PORTABLE_USER_OWNER="$owner"
}

build_shared_infra_fixture() {
  mkdir -p "$SHARED"
  cp "$SHARED_FIXTURE/Makefile" "$SHARED/Makefile"
  cp "$SHARED_FIXTURE/projects.yaml" "$SHARED/projects.yaml"
  rm -f "$SHARED/calls.log" "$SHARED/drift"
}

# Build a fully healthy "healthy" project: good rules symlink, canonical
# @-import, full skills + commands sets, and a .claude/settings.json (so the
# settings-wiring check does not WARN; with no canonical template present the
# wiring check then skips -> OK).
# $1 (optional) = project name; defaults to "healthy". A named second project is
# what makes --project scoping falsifiable (see the scoping test below).
build_healthy_project() {
  local name="${1:-healthy}"
  local hp="$PROJECTS/$name"
  mkdir -p "$hp/.claude/rules" "$hp/.claude/skills" "$hp/.claude/commands"
  ln -s "$CANON/core-rules/CLAUDE.md" "$hp/.claude/rules/trellis.md"
  local s c
  for s in $CANON_SKILLS; do
    ln -s "$CANON/core-rules/skills/$s" "$hp/.claude/skills/$s"
  done
  for c in $CANON_COMMANDS; do
    ln -s "$CANON/core-rules/commands/$c.md" "$hp/.claude/commands/$c.md"
  done
  cat > "$hp/CLAUDE.md" <<EOF
# Healthy project $name

@$CANON/core-rules/CLAUDE.md
EOF
  printf '{ "hooks": {} }\n' > "$hp/.claude/settings.json"
  # A healthy project has its pre-push wired to process-gate's run-all.sh so
  # hc_prepush_wired_runall passes. (No review hook + no tracked UI files keep
  # hc_reviewer_resolvable / hc_ui_screenshot_path silently OK by default.)
  mkdir -p "$hp/.husky"
  printf '#!/usr/bin/env sh\nbash .claude/skills/process-gate/scripts/run-all.sh --mode=merge\n' \
    > "$hp/.husky/pre-push"
}

# Run the doctor against the fixture. $TRELLIS_CONFIG is already exported in
# setup(), so this can never hit the live config. Run from the worktree root
# (NOT inside the fixture canonical) to mirror real use — doctor resolves the
# canonical from config, not cwd.
run_doctor() {
  if [ -n "$DOCTOR_SHARED_OVERRIDE" ]; then
    run env SHARED_INFRA_ROOT="$DOCTOR_SHARED_OVERRIDE" bash "$DOCTOR" "$@"
  else
    run env -u SHARED_INFRA_ROOT bash "$DOCTOR" "$@"
  fi
}

# Build a symlink-farm bin dir under $BATS_TEST_TMPDIR that mirrors EVERY
# executable on the current PATH EXCEPT any named `playwright`, then print the
# farm dir. Adapts the make_jq_free_path symlink-farm idiom from
# core-rules/hooks/tests/helpers.bash but enumerates the FULL PATH (not a fixed
# command list) so doctor's complete toolchain — git + its helpers, jq, shasum,
# coreutils — resolves under the farm and only `playwright` is excluded
# (DL-P8a-12 hermeticity: the no-screenshot-tool WARN branch must be reached on
# EVERY host, including this operator's, where playwright IS on the real PATH).
# First-wins on basename collisions to preserve PATH precedence order. Local to
# this suite — NOT cross-sourced from the hooks test dir.
make_no_playwright_path() {
  local farm dir entry base
  farm="$(mktemp -d "$BATS_TEST_TMPDIR/farm.XXXXXX")"
  # Split PATH on ':' without a subshell-unsafe IFS leak.
  local oldifs="$IFS"
  IFS=':'
  for dir in $PATH; do
    IFS="$oldifs"
    [ -d "$dir" ] || { IFS=':'; continue; }
    for entry in "$dir"/*; do
      [ -x "$entry" ] && [ ! -d "$entry" ] || continue
      base="$(basename "$entry")"
      [ "$base" = "playwright" ] && continue
      # First-wins: do not overwrite an earlier (higher-precedence) link.
      [ -e "$farm/$base" ] && continue
      ln -s "$entry" "$farm/$base"
    done
    IFS=':'
  done
  IFS="$oldifs"
  printf '%s' "$farm"
}

# ===========================================================================
# Tier 0
# ===========================================================================

# ===========================================================================
# Tier 1
# ===========================================================================

# ===========================================================================
# Exit-code polarity: 0 iff no ERROR present.
# ===========================================================================

# ===========================================================================
# Phase 8a — process-enforcement inheritance-health checks (all WARN-class,
# never flip the exit; DL-P8a-01..05). Static: never invoke the subject.
# ===========================================================================

@test "portable doctor reports user explicit-json drift without changing healthy project rows" {
  local project_owner project_owner_before project_agents_target
  build_portable_doctor_home
  prepare_portable_attachment
  prepare_portable_user_attachment
  project_owner="$PORTABLE_HOME/state/attachments/$PORTABLE_CHECKOUT_ID/$PORTABLE_WORKTREE_ID.json"
  project_owner_before="$(shasum -a 256 "$project_owner" | awk '{print $1}')"
  project_agents_target="$(readlink "$PORTABLE_PROJECT/.agents/rules/trellis.md")"

  run_portable_doctor --project portable-fixture
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  jq '.workflowSizeGuideline = "drifted"' "$PORTABLE_ACCOUNT_HOME/.claude/settings.json" \
    > "$PORTABLE_ACCOUNT_HOME/.claude/settings.json.next"
  mv "$PORTABLE_ACCOUNT_HOME/.claude/settings.json.next" "$PORTABLE_ACCOUNT_HOME/.claude/settings.json"
  chmod 600 "$PORTABLE_ACCOUNT_HOME/.claude/settings.json"

  run_portable_doctor --project portable-fixture

  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"✗ user surface: committed explicit-json keys do not match the immutable user-surface template"* ]] ||
    { echo "$output"; false; }
  [ "$(grep -c 'user surface:' <<<"$output")" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"✓ attachment ownership: exact committed owner, owned artifacts, and managed hooks match"* ]] ||
    { echo "$output"; false; }
  [ "$(shasum -a 256 "$project_owner" | awk '{print $1}')" = "$project_owner_before" ]
  [ "$(readlink "$PORTABLE_PROJECT/.agents/rules/trellis.md")" = "$project_agents_target" ]
  [ "$(jq -r '.workflowSizeGuideline' "$PORTABLE_ACCOUNT_HOME/.claude/settings.json")" = "drifted" ]
}

@test "portable doctor reports a missing owned user leaf" {
  build_portable_doctor_home
  prepare_portable_user_attachment
  rm "$PORTABLE_ACCOUNT_HOME/.claude/output-styles/trellis-orchestration.md"

  run_portable_doctor

  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"✗ user surface: a Trellis-owned leaf is missing, modified, has the wrong mode or target, or conflicts with an unowned artifact"* ]] ||
    { echo "$output"; false; }
  [ "$(grep -c 'user surface:' <<<"$output")" -eq 1 ] || { echo "$output"; false; }
  [ ! -e "$PORTABLE_ACCOUNT_HOME/.claude/output-styles/trellis-orchestration.md" ]
}

@test "portable --home --project overrides an inherited legacy config" {
  build_portable_doctor_home
  legacy_root="$SANDBOX/legacy-root"
  legacy_projects="$SANDBOX/legacy-projects"
  mkdir -p "$legacy_root" "$legacy_projects"
  cat > "$CFG" <<EOF
{"trellis_root":"$legacy_root","projects_root":"$legacy_projects","user_home":"$SANDBOX","maintainer_name":"Fixture","github_user":"fixture","harnesses":["claude"]}
EOF

  run env HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_CONFIG="$CFG" \
    TRELLIS_HOME="$SANDBOX/inherited-home" bash "$DOCTOR" --home "$PORTABLE_HOME" --project portable-fixture

  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *"trellis doctor — read-only local health"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Trellis home: $PORTABLE_HOME"* ]] || { echo "$output"; false; }
  [[ "$output" == *"local registry: validated local fleet inventory"* ]] || { echo "$output"; false; }
  [[ "$output" == *"local registry has no record for requested project portable-fixture"* ]] || { echo "$output"; false; }
}

@test "portable doctor rejects unsafe local machine state permissions before registry inspection" {
  build_portable_doctor_home
  chmod 755 "$PORTABLE_HOME"

  run_portable_doctor

  [ "$status" -ne 0 ]
  [[ "$output" == *"TRELLIS_HOME permissions must be 0700"* ]] || { echo "$output"; false; }

  chmod 700 "$PORTABLE_HOME"
  chmod 644 "$PORTABLE_HOME/config.json"

  run_portable_doctor

  [ "$status" -ne 0 ]
  [[ "$output" == *"local config permissions must be 0600"* ]] || { echo "$output"; false; }
}

@test "portable registry validation rejects terminal controls while preserving spaces and Unicode" {
  build_portable_doctor_home
  safe_registry="$SANDBOX/safe-registry.json"
  jq --arg path "$SANDBOX/naïve ignored path" --arg reason "visible reason with spaces" '
    .discovery_ignores = {personal: [{path: $path, reason: $reason}]}
  ' "$PORTABLE_HOME/registry.json" > "$safe_registry"

  run bash -c '. "$1"; local_registry_json_is_valid "$2"' _ \
    "$REPO_ROOT/scripts/lib/local-registry.sh" "$safe_registry"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  for terminal_control in $'\033' $'\302\205'; do
    jq --arg path "$SANDBOX/poisoned${terminal_control}path" --arg reason "safe reason" '
      .discovery_ignores = {personal: [{path: $path, reason: $reason}]}
    ' "$PORTABLE_HOME/registry.json" > "$SANDBOX/poisoned-registry.json"

    run bash -c '. "$1"; local_registry_json_is_valid "$2"' _ \
      "$REPO_ROOT/scripts/lib/local-registry.sh" "$SANDBOX/poisoned-registry.json"
    [ "$status" -ne 0 ]
  done
}

@test "every registry-row report line prints the ESCAPED root and identity detail" {
  # `$root` and `$identity_detail` come out of the diagnostic listing, which
  # deliberately does not require the registry file to be strict-clean, so the
  # row loop computes `$safe_root` / `$safe_identity_detail` once and every
  # reported line is supposed to use them. Five did; the `safe repair
  # available:` INFO line printed `$root` raw, and nothing caught it because no
  # fixture drives a hostile root all the way to a repairable row. A textual
  # check over the loop body does catch it, and costs nothing to keep.
  local loop start end
  start="$(grep -n '^while IFS= read -r row; do$' "$DOCTOR" | cut -d: -f1)"
  end="$(grep -n "^done < <(jq -c '.entries\[\]' \"\$SNAPSHOT\")\$" "$DOCTOR" | cut -d: -f1)"
  [ -n "$start" ] && [ -n "$end" ] && [ "$end" -gt "$start" ] ||
    { echo "could not locate the registry row loop in $DOCTOR"; false; }
  loop="$(sed -n "${start},${end}p" "$DOCTOR")"

  # Positive control: the loop really does report roots, so a green result below
  # cannot come from having matched nothing at all.
  [ "$(printf '%s\n' "$loop" | grep -c '\$safe_root')" -ge 5 ] ||
    { printf '%s\n' "$loop" | grep -n 'safe_root'; false; }

  # A `report` line may name the raw values nowhere. `\$root\b` does not match
  # `$safe_root`, whose variable name simply contains no `root` word boundary
  # at that position.
  [ "$(printf '%s\n' "$loop" | grep -E '^[[:space:]]*report ' | grep -cE '\$\{?root\}?[^_A-Za-z0-9]|\$\{?identity_detail\}?[^_A-Za-z0-9]')" -eq 0 ] ||
    { printf '%s\n' "$loop" | grep -nE '^[[:space:]]*report ' | grep -E '\$\{?root\}?[^_A-Za-z0-9]|\$\{?identity_detail\}?[^_A-Za-z0-9]'; false; }
}

@test "portable doctor rejects terminal controls in persisted machine paths" {
  build_portable_doctor_home

  for terminal_control in $'\033' $'\302\205'; do
    jq --arg source "$PORTABLE_SOURCE${terminal_control}poisoned" '.source_root = $source' \
      "$PORTABLE_HOME/config.json" > "$PORTABLE_HOME/config.json.next"
    mv "$PORTABLE_HOME/config.json.next" "$PORTABLE_HOME/config.json"
    chmod 600 "$PORTABLE_HOME/config.json"

    run_portable_doctor

    [ "$status" -ne 0 ]
    [[ "$output" == *"machine state: invalid local config"* ]] || { echo "$output"; false; }
  done
}

@test "portable doctor retains and reports unavailable registry rows" {
  build_portable_doctor_home
  cat > "$PORTABLE_HOME/registry.json" <<EOF
{"schema_version":1,"projects":{"personal/portable-fixture":{"fleet":"personal","project_id":"portable-fixture","status":"unavailable","metadata":{},"checkouts":{},"unavailable_roots":["$SANDBOX/unmounted volume/project"]}},"discovery_ignores":{}}
EOF
  chmod 600 "$PORTABLE_HOME/registry.json"

  run_portable_doctor

  [ "$status" -eq 5 ]
  [[ "$output" == *"unavailable: retained local registry row at $SANDBOX/unmounted volume/project"* ]] || { echo "$output"; false; }
  jq -e '.projects["personal/portable-fixture"].unavailable_roots | length == 1' "$PORTABLE_HOME/registry.json"
}

@test "portable doctor keeps a rootless detached project report-only" {
  build_portable_doctor_home
  cat > "$PORTABLE_HOME/registry.json" <<EOF
{"schema_version":1,"projects":{"personal/portable-fixture":{"fleet":"personal","project_id":"portable-fixture","status":"detached","metadata":{},"checkouts":{},"unavailable_roots":[]}},"discovery_ignores":{}}
EOF
  chmod 600 "$PORTABLE_HOME/registry.json"

  run_portable_doctor

  [ "$status" -eq 0 ]
  [[ "$output" == *"detached inventory: retained project has no local worktree root to inspect"* ]] || { echo "$output"; false; }
  [[ "$output" != *"unavailable: retained local registry row at <no root>"* ]] || { echo "$output"; false; }
  [[ "$output" == *"0 error(s)"* ]] || { echo "$output"; false; }
}

@test "a project-scoped portable doctor still reports identity drift outside the selection" {
  build_portable_doctor_home
  identity="$(bash -c '. "'"$REPO_ROOT"'/scripts/lib/trellis-home.sh"; . "'"$REPO_ROOT"'/scripts/lib/local-registry.sh"; local_registry_identity_for_root "'"$PORTABLE_PROJECT"'"')"
  checkout_id="$(printf '%s\n' "$identity" | jq -r '.checkout_id')"
  worktree_id="$(printf '%s\n' "$identity" | jq -r '.worktree_id')"
  common="$(printf '%s\n' "$identity" | jq -r '.git_common_dir')"
  cat > "$PORTABLE_HOME/registry.json" <<EOF
{"schema_version":1,"projects":{"personal/portable-fixture":{"fleet":"personal","project_id":"portable-fixture","status":"active","metadata":{},"checkouts":{"$checkout_id":{"root":"$PORTABLE_PROJECT","git_common_dir":"$common","release":"1.2.3","harnesses":["claude","codex"],"worktrees":{"$worktree_id":{"root":"$PORTABLE_PROJECT"}}}}}},"discovery_ignores":{}}
EOF
  chmod 600 "$PORTABLE_HOME/registry.json"

  # Baseline: this exact registry is clean for the selected project.
  run_portable_doctor --project portable-fixture
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  add_portable_identity_error_sibling

  # The row loop applies `--project` with a `continue` BEFORE it ever reads
  # `.identity.state`, so a scoped run used to report a clean bill of health
  # over a registry it had just listed as drifted. Selection still limits what
  # is INSPECTED and repaired; it does not limit the exit class.
  run_portable_doctor --project portable-fixture
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  grep -qF 'identity drift outside --project portable-fixture' <<<"$output"
  grep -qF 'personal/portable-sibling' <<<"$output"
  grep -qF 'no automatic mutation was attempted' <<<"$output"
}

@test "the project-scoped pre-pass catches a row only the strict classifier condemned" {
  build_portable_doctor_home
  identity="$(bash -c '. "'"$REPO_ROOT"'/scripts/lib/trellis-home.sh"; . "'"$REPO_ROOT"'/scripts/lib/local-registry.sh"; local_registry_identity_for_root "'"$PORTABLE_PROJECT"'"')"
  checkout_id="$(printf '%s\n' "$identity" | jq -r '.checkout_id')"
  worktree_id="$(printf '%s\n' "$identity" | jq -r '.worktree_id')"
  common="$(printf '%s\n' "$identity" | jq -r '.git_common_dir')"
  cat > "$PORTABLE_HOME/registry.json" <<EOF
{"schema_version":1,"projects":{"personal/portable-fixture":{"fleet":"personal","project_id":"portable-fixture","status":"active","metadata":{},"checkouts":{"$checkout_id":{"root":"$PORTABLE_PROJECT","git_common_dir":"$common","release":"1.2.3","harnesses":["claude","codex"],"worktrees":{"$worktree_id":{"root":"$PORTABLE_PROJECT"}}}}}},"discovery_ignores":{}}
EOF
  chmod 600 "$PORTABLE_HOME/registry.json"

  run_portable_doctor --project portable-fixture
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  add_portable_unreachable_drift_sibling

  # `registry list` condemns this row class 4. Before the two classifiers were
  # merged, the diagnostic listing this pre-pass reads called the same row
  # `unavailable` and the scoped run reported a clean bill of health over it.
  run env TRELLIS_HOME="$PORTABLE_HOME" bash "$REPO_ROOT/scripts/registry.sh" list --json
  [ "$status" -eq 4 ] || { echo "$output"; false; }

  run_portable_doctor --project portable-fixture
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  grep -qF 'identity drift outside --project portable-fixture' <<<"$output"
  grep -qF 'personal/portable-sibling' <<<"$output"
}

@test "portable doctor classifies a registered manifest without owner as inert non-user" {
  build_portable_doctor_home
  identity="$(bash -c '. "'"$REPO_ROOT"'/scripts/lib/trellis-home.sh"; . "'"$REPO_ROOT"'/scripts/lib/local-registry.sh"; local_registry_identity_for_root "'"$PORTABLE_PROJECT"'"')"
  checkout_id="$(printf '%s\n' "$identity" | jq -r '.checkout_id')"
  worktree_id="$(printf '%s\n' "$identity" | jq -r '.worktree_id')"
  common="$(printf '%s\n' "$identity" | jq -r '.git_common_dir')"
  cat > "$PORTABLE_HOME/registry.json" <<EOF
{"schema_version":1,"projects":{"personal/portable-fixture":{"fleet":"personal","project_id":"portable-fixture","status":"active","metadata":{},"checkouts":{"$checkout_id":{"root":"$PORTABLE_PROJECT","git_common_dir":"$common","release":"1.2.3","harnesses":["claude","codex"],"worktrees":{"$worktree_id":{"root":"$PORTABLE_PROJECT"}}}}}},"discovery_ignores":{}}
EOF
  chmod 600 "$PORTABLE_HOME/registry.json"

  run_portable_doctor

  [ "$status" -eq 0 ]
  [[ "$output" == *"layout: inert non-user portable manifest (not locally attached)"* ]] || { echo "$output"; false; }
  [[ "$output" == *"attachment ownership: no committed owner record"* ]] || { echo "$output"; false; }
}

@test "portable doctor reports the managed core.hooksPath without a false positive" {
  build_portable_doctor_home
  prepare_portable_attachment
  expected="$PORTABLE_HOME/state/git-hooks/$PORTABLE_CHECKOUT_ID"

  run_portable_doctor --project portable-fixture

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"git hook authority: core.hooksPath matches the Trellis managed dispatcher at $expected"* ]] ||
    { echo "$output"; false; }
}
@test "portable doctor accepts foreign bytes outside the managed exclude block" {
  local exclude foreign_before foreign_after with_foreign duplicate_block
  build_portable_doctor_home
  prepare_portable_attachment
  exclude="$PORTABLE_PROJECT/.git/info/exclude"
  foreign_before="$SANDBOX/foreign-exclude-before"
  foreign_after="$SANDBOX/foreign-exclude-after"
  printf 'foreign prefix embeds %s in arbitrary bytes\n' \
    '# --- Trellis local attachment exclude block ---' > "$foreign_before"
  printf 'foreign suffix embeds %s in arbitrary bytes\n' \
    '# --- end Trellis local attachment exclude block ---' > "$foreign_after"
  cat "$foreign_before" "$exclude" > "$exclude.tmp"
  mv "$exclude.tmp" "$exclude"
  cat "$exclude" "$foreign_after" > "$exclude.tmp"
  mv "$exclude.tmp" "$exclude"
  with_foreign="$SANDBOX/exclude-with-foreign"
  cp "$exclude" "$with_foreign"
  duplicate_block="$SANDBOX/duplicate-block"
  sed -n '/^# --- Trellis local attachment exclude block ---$/,/^# --- end Trellis local attachment exclude block ---$/p' \
    "$exclude" > "$duplicate_block"
  cat "$duplicate_block" >> "$exclude"
  run_portable_doctor --project portable-fixture
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  cp "$with_foreign" "$exclude"

  run_portable_doctor --project portable-fixture

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"managed excludes: exact immutable native-surface block matches; surrounding user bytes drifted at $exclude"* ]] || { echo "$output"; false; }
  cmp -s "$with_foreign" "$exclude"
  grep -Fq 'foreign prefix embeds' "$exclude"
  grep -Fq 'foreign suffix embeds' "$exclude"
}


@test "portable doctor accepts an authentic dispatcher from an older release payload" {
  local old_release old_payload manifest owner managed legacy_post legacy_pre
  build_portable_doctor_home
  copy_portable_older_release
  prepare_portable_attachment portable-fixture 1.2.2
  owner="$PORTABLE_HOME/state/attachments/$PORTABLE_CHECKOUT_ID/$PORTABLE_WORKTREE_ID.json"
  managed="$PORTABLE_HOME/state/git-hooks/$PORTABLE_CHECKOUT_ID"
  old_release="$PORTABLE_HOME/releases/1.2.2"
  old_payload="$old_release/payload"
  manifest="$(portable_file_sha256 "$old_release/release.json")"
  legacy_post="$(
    TRELLIS_LIBS_PRELOADED=1 TRELLIS_VERIFIED_PAYLOAD="$old_payload" \
      /bin/bash --noprofile --norc -c '
        source "${1%/*}/trellis-home.sh" || exit
        source "$1"
        _attachment_hooks_post_checkout_dispatcher_body "$2" "$3"
      ' legacy-dispatcher "$old_payload/scripts/lib/attachment.sh" "$old_payload" "$manifest"
  )"
  legacy_pre="$(
    TRELLIS_LIBS_PRELOADED=1 TRELLIS_VERIFIED_PAYLOAD="$old_payload" \
      /bin/bash --noprofile --norc -c '
        source "${1%/*}/trellis-home.sh" || exit
        source "$1"
        _attachment_hooks_pre_push_dispatcher_body "$2" "$3" "$4"
      ' legacy-dispatcher "$old_payload/scripts/lib/attachment.sh" "$old_payload" \
        core-rules/githooks/pre-push "$manifest"
  )"
  [ "$(jq -r '.release' "$owner")" = 1.2.2 ]
  [ -n "$legacy_post" ]
  [ -n "$legacy_pre" ]
  [[ "$legacy_post" != *"TRELLIS_ALLOW_MAIN_PUSH"* ]]
  printf '%s\n' "$legacy_post" > "$managed/post-checkout"
  printf '%s\n' "$legacy_pre" > "$managed/pre-push"
  chmod 700 "$managed/post-checkout" "$managed/pre-push"

  run_portable_doctor --project portable-fixture

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  expected="$managed"
  [[ "$output" == *"git hook authority: core.hooksPath matches the Trellis managed dispatcher at $expected"* ]] ||
    { echo "$output"; false; }
}


# show-config renders local authority state, so it carries the same
# attestation-based direct-source refusal release, upgrade, and mirror carry:
# the launcher's verified payload identity is the only anchor, and no machine
# config is consulted.
copy_show_config_into() {
  local root="$1"
  local scripts="$root/scripts"
  mkdir -p "$scripts"
  cp "$PORTABLE_RELEASE_PAYLOAD/trellis.config.json" "$root/trellis.config.json"
  cp "$SHOW_CONFIG" "$scripts/show-config.sh"
  cp -R "$REPO_ROOT/scripts/lib" "$scripts/lib"
  chmod 755 "$scripts/show-config.sh"
  printf '%s\n' "$scripts/show-config.sh"
}

# ===========================================================================
# Gate interpreter diagnostics — static resolution mirrors stop-verify.
# ===========================================================================

# Spec 053 O3: doctor reads owner records straight from state, independently of
# the registry, and classifies them with the same predicate attach uses.
write_portable_owner_record() {
  local dir="$PORTABLE_HOME/state/attachments/$1"
  mkdir -p "$dir"
  chmod 700 "$PORTABLE_HOME/state" "$PORTABLE_HOME/state/attachments" "$dir"
  jq -n --arg root "$3" --arg common "$4" '{worktree_root:$root,exclude:{git_common_dir:$common}}' > "$dir/$2.json"
  chmod 600 "$dir/$2.json"
}

orphan_rows() {
  printf '%s\n' "$output" | grep -E 'orphan-(owner-record|check-undetermined) ' || true
}

# Runtime rows use the real health predicate with a fixture application path;
# doctor itself always passes /Applications/Docker.app. This avoids touching
# host /Applications while testing both the active and dormant classifications.
container_runtime_stubs() {
  RUNTIME_BIN="$SANDBOX/runtime-bin"
  RUNTIME_APP="$SANDBOX/Docker.app"
  RUNTIME_HOME="$SANDBOX/runtime-home"
  RUNTIME_TRELLIS_HOME="$SANDBOX/runtime-trellis-home"
  mkdir -p "$RUNTIME_BIN" "$RUNTIME_HOME" "$RUNTIME_TRELLIS_HOME"
  cat > "$RUNTIME_BIN/uname" <<'SH'
#!/bin/sh
printf '%s\n' "$RUNTIME_OS"
SH
  cat > "$RUNTIME_BIN/docker" <<'SH'
#!/bin/sh
if [ "$1" = context ] && [ "$2" = show ]; then
  printf '%s\n' "$RUNTIME_CONTEXT"
fi
SH
  cat > "$RUNTIME_BIN/realpath" <<'SH'
#!/bin/sh
printf '%s\n' "$RUNTIME_RESOLVED"
SH
  chmod 700 "$RUNTIME_BIN/uname" "$RUNTIME_BIN/docker" "$RUNTIME_BIN/realpath"
}

run_container_runtime_rows() {
  run /usr/bin/env -u DOCKER_HOST -u TRELLIS_CONFIG \
    HOME="$RUNTIME_HOME" TRELLIS_HOME="$RUNTIME_TRELLIS_HOME" \
    PATH="$RUNTIME_BIN:/usr/bin:/bin" \
    RUNTIME_OS="$RUNTIME_OS" RUNTIME_CONTEXT="${RUNTIME_CONTEXT:-colima}" \
    RUNTIME_RESOLVED="${RUNTIME_RESOLVED:-$RUNTIME_BIN/docker}" "$@" \
    /bin/bash -c '. "$1"; hc_container_runtime_rows "$2"' \
    _ "$REPO_ROOT/scripts/lib/health-checks.sh" "$RUNTIME_APP"
}
