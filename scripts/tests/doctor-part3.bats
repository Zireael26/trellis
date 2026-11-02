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
  # A fixture attach must not spawn the detached post-attach job: it races the
  # core.hooksPath and exclude edits these tests make right after attaching,
  # records its own FAILED verdict (exit 4), and outlives teardown.
  # run-tests.sh sets this too; a direct bats run must not depend on it.
  export TRELLIS_ATTACH_POSTJOB=off
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
  cp "$REPO_ROOT/core-rules/hooks/trellis-worktree-create.sh" \
    "$REPO_ROOT/core-rules/hooks/trellis-worktree-remove.sh" \
    "$PORTABLE_RELEASE_PAYLOAD/core-rules/hooks/"
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


@test "portable doctor accepts retained explicit-json values after template changes" {
  local owner rendered rendered_mode rendered_sha rendered64
  build_portable_doctor_home
  prepare_portable_attachment
  owner="$PORTABLE_HOME/state/attachments/$PORTABLE_CHECKOUT_ID/$PORTABLE_WORKTREE_ID.json"
  rendered="$PORTABLE_PROJECT/.claude/settings.local.json"
  rendered_mode="$(stat -f '%Lp' "$rendered" 2>/dev/null)" ||
    rendered_mode="$(stat -c '%a' "$rendered")"
  # Drift an owned key's local value away from what the template renders. Owned
  # keys are nested paths derived from the template at render time, so this must
  # name one the template actually carries -- pinning `effortLevel` broke the
  # moment that key stopped being shipped.
  jq '.permissions.deny = ["Read(./legacy/**)"]' "$rendered" > "$rendered.next"
  mv "$rendered.next" "$rendered"
  chmod "$rendered_mode" "$rendered"
  rendered_sha="$(portable_file_sha256 "$rendered")"
  rendered64="$(base64 < "$rendered" | tr -d '\n')"
  jq --arg sha "$rendered_sha" --arg after64 "$rendered64" '
    .artifacts |= map(
      if .path == ".claude/settings.local.json" then .sha256 = $sha else . end
    )
    | .renders |= map(
      if .path == ".claude/settings.local.json" then
        .after_sha256 = $sha
        | .after_base64 = $after64
        | .owned_keys |= map(
            if .path == ["permissions","deny"] then .value = ["Read(./legacy/**)"] else . end
          )
      else . end
    )
  ' "$owner" > "$owner.next"
  mv "$owner.next" "$owner"
  chmod 600 "$owner"
  # The render must actually own the key, or this test proves nothing.
  [ "$(jq -r '
    [.renders[] | select(.path == ".claude/settings.local.json")
     | .owned_keys[] | select(.path == ["permissions","deny"])] | length
  ' "$owner")" -eq 1 ]
  [ "$(jq -c '.permissions.deny' "$rendered")" = '["Read(./legacy/**)"]' ]

  run_portable_doctor --project portable-fixture

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"native surfaces: claude, codex match the selected immutable harness manifest"* ]] ||
    { echo "$output"; false; }
  [ "$(jq -c '.permissions.deny' "$rendered")" = '["Read(./legacy/**)"]' ]
}

@test "portable doctor rejects inconsistent explicit-json after bytes" {
  local owner
  build_portable_doctor_home
  prepare_portable_attachment
  owner="$PORTABLE_HOME/state/attachments/$PORTABLE_CHECKOUT_ID/$PORTABLE_WORKTREE_ID.json"
  jq '
    .renders |= map(
      if .path == ".claude/settings.local.json" then .after_base64 = "e30K" else . end
    )
  ' "$owner" > "$owner.next"
  mv "$owner.next" "$owner"
  chmod 600 "$owner"

  run_portable_doctor --project portable-fixture

  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"native surfaces: committed render bytes, ownership, or live owned keys are invalid"* ]] ||
    { echo "$output"; false; }
}

# attach_and_doctor_with_claude <version>: attach and doctor both see only a
# stub claude reporting <version> ahead of the ambient PATH.
attach_and_doctor_with_claude() {
  mkdir -p "$SANDBOX/claude-stub"
  printf '#!/bin/sh\necho "%s (Claude Code)"\n' "$1" > "$SANDBOX/claude-stub/claude"
  chmod 755 "$SANDBOX/claude-stub/claude"
  export TRELLIS_ATTACH_CALLER_PATH="$SANDBOX/claude-stub:$PATH"
  build_portable_doctor_home
  prepare_portable_attachment
  run_portable_doctor --project portable-fixture
  unset TRELLIS_ATTACH_CALLER_PATH
}

@test "portable doctor accepts the shell-form Claude render on a client below 2.1.295" {
  attach_and_doctor_with_claude 2.1.294
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"native surfaces: claude, codex match the selected immutable harness manifest"* ]] ||
    { echo "$output"; false; }
  [[ "$output" != *"guard registration not stall-safe"* ]] || { echo "$output"; false; }
  jq -e '([.. | objects | select(has("args") or has("onFailure"))] | length) == 0
    and ([.hooks.PreToolUse[].hooks[] | select(.command | contains("guard-supervise"))] | length) == 3' \
    "$PORTABLE_PROJECT/.claude/settings.local.json" >/dev/null
}

@test "portable doctor accepts the exec-form Claude render on a client at 2.1.295 or later" {
  attach_and_doctor_with_claude 2.1.300
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"native surfaces: claude, codex match the selected immutable harness manifest"* ]] ||
    { echo "$output"; false; }
  [[ "$output" != *"guard registration not stall-safe"* ]] || { echo "$output"; false; }
  jq -e '[.hooks.PreToolUse[].hooks[] | select(.onFailure == "block") | .command] == ["/usr/bin/env","/usr/bin/env","/usr/bin/env"]' \
    "$PORTABLE_PROJECT/.claude/settings.local.json" >/dev/null
}

@test "portable doctor treats the recorded previous hooksPath as drift while hooks are enabled" {
  local current previous diagnostic current_display root_display expected_display
  build_portable_doctor_home
  previous=".husky/_"
  current="$previous"
  git -C "$PORTABLE_PROJECT" config --local core.hooksPath "$current"

  prepare_portable_attachment
  expected="$PORTABLE_HOME/state/git-hooks/$PORTABLE_CHECKOUT_ID"
  owner="$PORTABLE_HOME/state/attachments/$PORTABLE_CHECKOUT_ID/$PORTABLE_WORKTREE_ID.json"
  [ "$(git -C "$PORTABLE_PROJECT" config --local core.hooksPath)" = "$expected" ]
  [ "$(jq -r '.git_hooks.previous_hooks_path' "$owner")" = "$previous" ]
  current=$'other manager\tpath'

  git -C "$PORTABLE_PROJECT" config --local core.hooksPath "$current"
  run_portable_doctor --project portable-fixture

  [ "$status" -eq 3 ] || { echo "$output"; false; }
  current_display="$(printf '%q' "$current")"
  root_display="$(printf '%q' "$PORTABLE_PROJECT")"
  expected_display="$(printf '%q' "$expected")"
  diagnostic="core.hooksPath is $current_display in $root_display; the Trellis managed dispatcher is $expected_display; run trellis doctor --fix"
  [[ "$output" == *"git hook authority: $diagnostic"* ]] || { echo "$output"; false; }
  [[ "$output" != *"config core.hooksPath"* ]] || { echo "$output"; false; }
  [ "$(git -C "$PORTABLE_PROJECT" config --local core.hooksPath)" = "$current" ]
  [ "$(jq -r '.git_hooks.previous_hooks_path' "$owner")" = "$previous" ]
}


@test "portable doctor reports multiple local core.hooksPath values with an exact replace-all remedy" {
  local expected expected_display root_display before remedy
  build_portable_doctor_home
  prepare_portable_attachment
  expected="$PORTABLE_HOME/state/git-hooks/$PORTABLE_CHECKOUT_ID"
  git -C "$PORTABLE_PROJECT" config --local --add core.hooksPath ""
  before="$(portable_file_sha256 "$PORTABLE_PROJECT/.git/config")"
  expected_display="$(LC_ALL=C printf '%q' "$expected")"
  root_display="$(LC_ALL=C printf '%q' "$PORTABLE_PROJECT")"
  remedy="git config --replace-all core.hooksPath $expected_display"

  run_portable_doctor --project portable-fixture

  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"git hook authority: multiple local core.hooksPath values in $root_display; the Trellis managed dispatcher is $expected_display — restore with: $remedy"* ]] || { echo "$output"; false; }
  [[ "$output" != *"git hook authority: core.hooksPath is "* ]] || { echo "$output"; false; }
  [[ "$output" != *"run trellis doctor --fix"* ]] || { echo "$output"; false; }
  [ "$(portable_file_sha256 "$PORTABLE_PROJECT/.git/config")" = "$before" ]
}

@test "portable doctor keeps single-value managed and drift core.hooksPath diagnostics unchanged" {
  local expected expected_display root_display current current_display before diagnostic
  build_portable_doctor_home
  prepare_portable_attachment
  expected="$PORTABLE_HOME/state/git-hooks/$PORTABLE_CHECKOUT_ID"
  expected_display="$(LC_ALL=C printf '%q' "$expected")"
  root_display="$(LC_ALL=C printf '%q' "$PORTABLE_PROJECT")"
  before="$(portable_file_sha256 "$PORTABLE_PROJECT/.git/config")"

  run_portable_doctor --project portable-fixture

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"git hook authority: core.hooksPath matches the Trellis managed dispatcher at $expected_display"* ]] || { echo "$output"; false; }
  [[ "$output" != *"git config --replace-all core.hooksPath"* ]] || { echo "$output"; false; }
  [ "$(portable_file_sha256 "$PORTABLE_PROJECT/.git/config")" = "$before" ]

  for current in .husky/_ /custom; do
    git -C "$PORTABLE_PROJECT" config --local core.hooksPath "$current"
    before="$(portable_file_sha256 "$PORTABLE_PROJECT/.git/config")"
    current_display="$(LC_ALL=C printf '%q' "$current")"
    diagnostic="core.hooksPath is $current_display in $root_display; the Trellis managed dispatcher is $expected_display; run trellis doctor --fix"

    run_portable_doctor --project portable-fixture

    [ "$status" -eq 3 ] || { echo "$output"; false; }
    [[ "$output" == *"git hook authority: $diagnostic"* ]] || { echo "$output"; false; }
    [[ "$output" != *"multiple local core.hooksPath values"* ]] || { echo "$output"; false; }
    [[ "$output" != *"git config --replace-all core.hooksPath"* ]] || { echo "$output"; false; }
    [ "$(portable_file_sha256 "$PORTABLE_PROJECT/.git/config")" = "$before" ]
  done
}

@test "portable doctor reports when Husky reclaims core.hooksPath without repairing it" {
  local current diagnostic current_display root_display expected_display
  build_portable_doctor_home
  prepare_portable_attachment
  expected="$PORTABLE_HOME/state/git-hooks/$PORTABLE_CHECKOUT_ID"
  mkdir -p "$PORTABLE_PROJECT/.husky/_"
  current=".husky/_"
  git -C "$PORTABLE_PROJECT" config --local core.hooksPath "$current"

  run_portable_doctor --project portable-fixture

  [ "$status" -eq 3 ] || { echo "$output"; false; }
  current_display="$(printf '%q' "$current")"
  root_display="$(printf '%q' "$PORTABLE_PROJECT")"
  expected_display="$(printf '%q' "$expected")"
  diagnostic="core.hooksPath is $current_display in $root_display; the Trellis managed dispatcher is $expected_display; run trellis doctor --fix"
  [[ "$output" == *"git hook authority: $diagnostic"* ]] || { echo "$output"; false; }
  [[ "$output" != *"config core.hooksPath"* ]] || { echo "$output"; false; }
  [ "$(git -C "$PORTABLE_PROJECT" config --local core.hooksPath)" = ".husky/_" ]
  [ ! -e "$PORTABLE_PROJECT/.husky/_/pre-push" ]
}

@test "portable show-config separates tracked policy from validated local fleet state" {
  build_portable_doctor_home

  run_portable_show_config

  [ "$status" -eq 0 ]
  [[ "$output" == *"=== Tracked portable policy ==="* ]] || { echo "$output"; false; }
  [[ "$output" == *"tracked policy contains no machine path, fleet, checkout, or release selection"* ]] || { echo "$output"; false; }
  [[ "$output" == *"=== Local machine state (not tracked config) ==="* ]] || { echo "$output"; false; }
  [[ "$output" == *"machine config:        $PORTABLE_HOME/config.json (validated local state)"* ]] || { echo "$output"; false; }
  [[ "$output" == *"management source:     $PORTABLE_SOURCE (validated; not attached runtime)"* ]] || { echo "$output"; false; }
  [[ "$output" == *"selected fleet:        personal"* ]] || { echo "$output"; false; }
  [[ "$output" == *"active CLI release:    1.2.3"* ]] || { echo "$output"; false; }
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

@test "portable show-config refuses every execution without a verified attestation" {
  local mutable worktree decoy_home
  build_portable_doctor_home

  # The configured management source is a clone, not a runtime. No attestation,
  # so the refusal does not depend on the clone being recognisable as one.
  mutable="$(copy_show_config_into "$PORTABLE_SOURCE")"
  run env -u TRELLIS_CONFIG -u TRELLIS_VERIFIED_PAYLOAD -u TRELLIS_VERIFIED_RELEASE_VERSION \
    HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" \
    bash "$mutable" --home "$PORTABLE_HOME"
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *'direct source execution is unsupported; run trellis show-config from the installed stable launcher'* ]] ||
    { echo "$output"; false; }
  [[ "$output" != *"=== Tracked portable policy ==="* ]] || { echo "$output"; false; }

  # The case the old identity-based gate could not decide, and therefore
  # allowed: a copy of the source that no machine config anywhere names — a
  # worktree, an unpacked tarball, a clone at a fresh path. Undecidable is now
  # refusal, so this is the same exit and the same message as the clone above.
  worktree="$SANDBOX/unnamed-source-copy"
  copy_show_config_into "$worktree" >/dev/null
  run env -u TRELLIS_CONFIG -u TRELLIS_VERIFIED_PAYLOAD -u TRELLIS_VERIFIED_RELEASE_VERSION \
    HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" \
    bash "$worktree/scripts/show-config.sh" --home "$PORTABLE_HOME"
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *'direct source execution is unsupported'* ]] || { echo "$output"; false; }
  [[ "$output" != *"=== Tracked portable policy ==="* ]] || { echo "$output"; false; }

  # Nor can pointing the environment at a home with no source_root at all buy a
  # render: with the gate no longer reading any config, home selection is not a
  # lever on the refusal in either direction.
  decoy_home="$SANDBOX/decoy-home"
  mkdir -p "$decoy_home"
  chmod 700 "$decoy_home"
  printf '{"schema_version":1,"release_remote":"%s","active_cli_release":"1.2.3","default_fleet":"personal","fleets":{"personal":{"discovery_roots":["%s"]}}}\n' \
    "$decoy_home" "$SANDBOX" > "$decoy_home/config.json"
  chmod 600 "$decoy_home/config.json"
  run env -u TRELLIS_CONFIG -u TRELLIS_VERIFIED_PAYLOAD -u TRELLIS_VERIFIED_RELEASE_VERSION \
    HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$decoy_home" \
    bash "$worktree/scripts/show-config.sh" --home "$PORTABLE_HOME"
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *'direct source execution is unsupported'* ]] || { echo "$output"; false; }
  [[ "$output" != *"=== Tracked portable policy ==="* ]] || { echo "$output"; false; }

  # An empty attestation is no attestation: it must not read as one.
  run env -u TRELLIS_CONFIG HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" \
    TRELLIS_VERIFIED_PAYLOAD= TRELLIS_VERIFIED_RELEASE_VERSION= \
    bash "$worktree/scripts/show-config.sh" --home "$PORTABLE_HOME"
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *'direct source execution is unsupported'* ]] || { echo "$output"; false; }

  # ARGV IS NOT A WAY PAST THE GATE. `-h` is the only argument with an exit-0
  # path, so it is the one that shows whether parsing runs before the gate. An
  # unattested copy must refuse it exactly like every other invocation: same
  # exit 2, same refusal line, and no usage text — usage printed from here would
  # be an ungated copy answering for itself. release.sh, upgrade.sh, and
  # sync-to-template.sh all gate before touching argv; this keeps the fourth
  # gate the same shape.
  run env -u TRELLIS_CONFIG -u TRELLIS_VERIFIED_PAYLOAD -u TRELLIS_VERIFIED_RELEASE_VERSION \
    HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" \
    bash "$worktree/scripts/show-config.sh" -h
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *'direct source execution is unsupported'* ]] || { echo "$output"; false; }
  [[ "$output" != *'Usage: show-config.sh'* ]] ||
    { echo 'an unattested copy printed its own usage text'; echo "$output"; false; }

  # ...and the attested copy still answers -h normally, so the reorder did not
  # simply delete the option.
  run_portable_show_config -h
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'Usage: show-config.sh'* ]] || { echo "$output"; false; }
}

@test "portable show-config binds a verified attestation to the copy it describes" {
  local snapshot verified ambiguous outside
  build_portable_doctor_home

  # The sealed execution snapshot the launcher actually runs is allowed.
  snapshot="$(portable_show_config_snapshot)"
  verified="$snapshot/scripts/show-config.sh"
  run_portable_show_config
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"=== Local machine state (not tracked config) ==="* ]] || { echo "$output"; false; }
  [[ "$output" == *"active CLI release:    1.2.3"* ]] || { echo "$output"; false; }

  # A verified attestation that does not describe this copy is refused: the
  # attestation names the snapshot, the running file is the source checkout.
  run env -u TRELLIS_CONFIG HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" \
    TRELLIS_VERIFIED_PAYLOAD="$snapshot" TRELLIS_VERIFIED_RELEASE_VERSION=1.2.3 \
    bash "$SHOW_CONFIG" --home "$PORTABLE_HOME"
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *'direct source execution is unsupported'* ]] || { echo "$output"; false; }

  # So is a snapshot that belongs to another release.
  run env -u TRELLIS_CONFIG HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" \
    TRELLIS_VERIFIED_PAYLOAD="$snapshot" TRELLIS_VERIFIED_RELEASE_VERSION=9.9.9 \
    bash "$verified" --home "$PORTABLE_HOME"
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *'direct source execution is unsupported'* ]] || { echo "$output"; false; }

  # And so is a self-consistent attestation for a payload outside the attested
  # home's release store entirely: naming your own directory is not authority.
  outside="$(copy_show_config_into "$PORTABLE_SOURCE")"
  [ -f "$outside" ] || { echo "fixture missing: $outside"; false; }
  run env -u TRELLIS_CONFIG HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" \
    TRELLIS_VERIFIED_PAYLOAD="$PORTABLE_SOURCE" TRELLIS_VERIFIED_RELEASE_VERSION=1.2.3 \
    bash "$outside" --home "$PORTABLE_HOME"
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *'direct source execution is unsupported'* ]] || { echo "$output"; false; }

  # A snapshot name is delimiter-exact, not a version prefix. Release versions
  # may contain dots, so a snapshot of release '1.2.3.exec.9' shares the whole
  # '.tmp.1.2.3.exec.' prefix with a snapshot of release 1.2.3 and must not be
  # accepted under the 1.2.3 attestation.
  ambiguous="$PORTABLE_HOME/releases/.tmp.1.2.3.exec.9.exec.Ab3xY9/payload"
  copy_show_config_into "$ambiguous" >/dev/null
  run env -u TRELLIS_CONFIG HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" \
    TRELLIS_VERIFIED_PAYLOAD="$ambiguous" TRELLIS_VERIFIED_RELEASE_VERSION=1.2.3 \
    bash "$ambiguous/scripts/show-config.sh" --home "$PORTABLE_HOME"
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *'direct source execution is unsupported'* ]] || { echo "$output"; false; }
}

@test "portable show-config fails closed for an unavailable local home" {
  build_portable_doctor_home
  unavailable_home="$SANDBOX/unavailable local home"

  run_portable_show_config --home "$unavailable_home"

  [ "$status" -ne 0 ]
  [[ "$output" == *"=== Tracked portable policy ==="* ]] || { echo "$output"; false; }
  [[ "$output" == *"=== Local machine state (not tracked config) ==="* ]] || { echo "$output"; false; }
  [[ "$output" == *"Trellis home:          unavailable ($unavailable_home)"* ]] || { echo "$output"; false; }
  [[ "$output" != *"machine config:        $unavailable_home/config.json (validated local state)"* ]] || { echo "$output"; false; }
  [[ "$output" != *"selected fleet:"* ]] || { echo "$output"; false; }
  [[ "$output" != *"active CLI release:"* ]] || { echo "$output"; false; }
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
