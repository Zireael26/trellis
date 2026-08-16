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
CANON_SKILLS="process-gate security-gate aeo-gate clarify spec plan tasks analyze execute brainstorming orchestrate debrief writing"
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
# empty OMP agents dir + hook adapter, registry with one active "healthy"
# project, empty blacklist). The skills/commands manifests carry OMP discovery
# frontmatter (hc_omp_manifests requires it), the agents dir holds only a
# .gitkeep (the GPTX-era custom agents were removed — empty is healthy), and
# the OMP adapter stub exists (hc_omp_adapter requires it) — a healthy
# canonical is OMP-healthy too. Does NOT git init — branch/clean state is set
# per test by the helpers below.
build_canonical_tree() {
  mkdir -p "$CANON/core-rules/skills" "$CANON/core-rules/commands" \
    "$CANON/core-rules/agents" "$CANON/core-rules/omp/hooks/pre"
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
  # The canonical agents dir is EMPTY (the GPTX-era custom agents were removed;
  # only .gitkeep remains) — an empty .omp/agents target is healthy.
  printf '' > "$CANON/core-rules/agents/.gitkeep"
  printf 'export const trellisAdapter = () => ({});\n' \
    > "$CANON/core-rules/omp/hooks/pre/trellis.ts"
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
# harness list as a JSON array body; defaults to Claude + OMP so Codex parity
# checks stay silent while the OMP contract remains active.
write_config() {
  local harnesses_json="${1:-\"claude\",\"omp\"}"
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
  printf '{"schema_version":2,"harnesses":["claude","codex","omp"]}\n' \
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
  local version="${1:-1.2.3}" manifest file relative mode oid target command_name hook
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
    "$PORTABLE_RELEASE_PAYLOAD/core-rules/omp/hooks/pre" \
    "$PORTABLE_RELEASE_PAYLOAD/core-rules/templates" \
    "$PORTABLE_RELEASE_PAYLOAD/core-rules/presets"
  cp "$REPO_ROOT/core-rules/inheritance-manifest.json" \
    "$PORTABLE_RELEASE_PAYLOAD/core-rules/inheritance-manifest.json"
  cp "$REPO_ROOT/core-rules/templates/claude-settings.local.json" \
    "$PORTABLE_RELEASE_PAYLOAD/core-rules/templates/claude-settings.local.json"
  cp "$REPO_ROOT/core-rules/templates/codex-hooks.local.json" \
    "$PORTABLE_RELEASE_PAYLOAD/core-rules/templates/codex-hooks.local.json"
  mkdir -p "$PORTABLE_RELEASE_PAYLOAD/scripts"
  cp "$REPO_ROOT/scripts/attach-project.sh" \
    "$PORTABLE_RELEASE_PAYLOAD/scripts/attach-project.sh"
  cp -R "$REPO_ROOT/scripts/lib" "$PORTABLE_RELEASE_PAYLOAD/scripts/lib"
  cp "$REPO_ROOT/scripts/seed-inheritance-symlinks.sh" \
    "$PORTABLE_RELEASE_PAYLOAD/scripts/seed-inheritance-symlinks.sh"
  cp "$REPO_ROOT/core-rules/hooks/lib/autonomy.sh" \
    "$PORTABLE_RELEASE_PAYLOAD/core-rules/hooks/lib/autonomy.sh"
  chmod 755 "$PORTABLE_RELEASE_PAYLOAD/scripts/attach-project.sh" \
    "$PORTABLE_RELEASE_PAYLOAD/scripts/seed-inheritance-symlinks.sh"
  cat > "$PORTABLE_RELEASE_PAYLOAD/trellis.config.json" <<'EOF'
{"schema_version":2,"maintainer_name":"Fixture","github_user":"fixture","harnesses":["claude","codex","omp"],"autonomy_default":2}
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
  for hook in fixture aeo-gate-warn code-reviewer decision-receipt-core spec-gate-core ui-verify-core; do
    printf '#!/usr/bin/env bash\nexit 0\n' \
      > "$PORTABLE_RELEASE_PAYLOAD/core-rules/hooks/lib/$hook.sh"
    chmod 755 "$PORTABLE_RELEASE_PAYLOAD/core-rules/hooks/lib/$hook.sh"
  done
  printf '#!/usr/bin/env bash\nexit 0\n' \
    > "$PORTABLE_RELEASE_PAYLOAD/core-rules/codex/hooks/fixture.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' \
    > "$PORTABLE_RELEASE_PAYLOAD/core-rules/codex/hooks/lib/fixture.sh"
  chmod 755 "$PORTABLE_RELEASE_PAYLOAD/core-rules/codex/hooks/fixture.sh" \
    "$PORTABLE_RELEASE_PAYLOAD/core-rules/codex/hooks/lib/fixture.sh"
  printf 'export const fixture = true;\n' \
    > "$PORTABLE_RELEASE_PAYLOAD/core-rules/omp/hooks/pre/fixture.ts"
  : > "$manifest"
  while IFS= read -r file; do
    relative="${file#"$PORTABLE_RELEASE_PAYLOAD"/}"
    if [ -L "$file" ]; then
      mode=120000
      target="$(readlink "$file")"
      oid="$(printf '%s' "$target" | git hash-object --stdin)"
    elif [ -x "$file" ]; then
      mode=100755
      oid="$(git hash-object "$file")"
    else
      mode=100644
      oid="$(git hash-object "$file")"
    fi
    jq -cn --arg path "$relative" --arg mode "$mode" --arg oid "$oid" \
      '{path: $path, mode: $mode, oid: $oid}' >> "$manifest"
  done < <(find "$PORTABLE_RELEASE_PAYLOAD" \( -type f -o -type l \) -print | LC_ALL=C sort)
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
  find "$PORTABLE_RELEASE_PAYLOAD" -type f -exec chmod a-w {} \;
  find "$PORTABLE_RELEASE_PAYLOAD" -type d -exec chmod a-w {} \;
  chmod a-w "$PORTABLE_RELEASE_DIR/release.json" "$PORTABLE_RELEASE_DIR"
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

portable_registry_sha256() {
  bash -c '. "$1"; . "$2"; local_registry_sha256 "$3"' _ \
    "$REPO_ROOT/scripts/lib/trellis-home.sh" "$REPO_ROOT/scripts/lib/local-registry.sh" "$1"
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
  local owner_project_id="${1:-portable-fixture}" identity checkout_id worktree_id owner
  run env -u TRELLIS_CONFIG HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" \
    bash "$REPO_ROOT/scripts/attach-project.sh" attach --home "$PORTABLE_HOME" \
      --fleet personal --release 1.2.3 \
      --harness claude --harness codex --harness omp "$PORTABLE_PROJECT"
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

build_shared_infra_fixture() {
  mkdir -p "$SHARED"
  cp "$SHARED_FIXTURE/Makefile" "$SHARED/Makefile"
  cp "$SHARED_FIXTURE/projects.yaml" "$SHARED/projects.yaml"
  rm -f "$SHARED/calls.log" "$SHARED/drift"
}

# Build a fully healthy "healthy" project: good rules symlink, canonical
# @-import, full skills + commands sets, a .claude/settings.json (so the
# settings-wiring check does not WARN; with no canonical template present the
# wiring check then skips -> OK), and the five OMP surface links (design
# 2026-08-09) so the OMP checks are green in every healthy-path test.
# $1 (optional) = project name; defaults to "healthy". A named second project is
# what makes --project scoping falsifiable (see the scoping test below).
build_healthy_project() {
  local name="${1:-healthy}"
  local hp="$PROJECTS/$name"
  mkdir -p "$hp/.claude/rules" "$hp/.claude/skills" "$hp/.claude/commands" "$hp/.omp"
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
  # OMP surface: the five exact live links in the shared contract.
  ln -s "$hp/CLAUDE.md" "$hp/.omp/AGENTS.md"
  ln -s "$CANON/core-rules/skills" "$hp/.omp/skills"
  ln -s "$CANON/core-rules/commands" "$hp/.omp/commands"
  ln -s "$CANON/core-rules/agents" "$hp/.omp/agents"
  ln -s "$CANON/core-rules/omp/hooks" "$hp/.omp/hooks"
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

@test "isolation: doctor reports the FIXTURE canonical path, never the live clone" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  run_doctor
  [[ "$output" == *"canonical clone: $CANON"* ]] || { echo "$output"; false; }
  # No `-z` escape hatch: LIVE_CANON is a resolved directory and is never empty,
  # so this conjunct always has to do work. The fixture lives under a fresh
  # mktemp dir, so no line of a correctly isolated report can name this checkout.
  [ -n "$LIVE_CANON" ] || { echo 'LIVE_CANON did not resolve'; false; }
  [[ "$output" != *"$LIVE_CANON"* ]] || { echo "$output"; false; }
}

@test "legacy doctor retains --project scope with an explicit legacy config" {
  # The registry carries TWO healthy projects on purpose. With a single-project
  # registry the "1 project(s) checked" claim is true whether or not --project
  # scoping exists, so the test could not go red when the scoping is removed.
  # The unselected project ("second") is the discriminator: it must be absent
  # from the report, and the count must be 1 of 2.
  build_canonical_tree
  register_project second
  git_init_canonical_main
  build_healthy_project healthy
  build_healthy_project second
  write_config

  # Unscoped control: both projects ARE reachable in this fixture, so a missing
  # `second` section below can only be the doing of --project.
  run_doctor
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"second ($PROJECTS/second)"* ]] ||
    { echo "control run did not check 'second' — fixture is not discriminating"; echo "$output"; false; }
  [[ "$output" == *"(2 project(s) checked)"* ]] || { echo "$output"; false; }

  run_doctor --project healthy

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"canonical clone: $CANON"* ]] || { echo "$output"; false; }
  # The per-project section header is `NAME (ROOT)`; there is no `== NAME (app) ==`
  # form and there never was one on this path.
  [[ "$output" == *"healthy ($PROJECTS/healthy)"* ]] || { echo "$output"; false; }
  [[ "$output" != *"second ($PROJECTS/second)"* ]] ||
    { echo "--project healthy still checked 'second' — scoping is not applied"; echo "$output"; false; }
  [[ "$output" == *"(1 project(s) checked)"* ]] || { echo "$output"; false; }
}

@test "Tier-0: GREEN when fixture canonical is on main + clean" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ canonical clone is on main"* ]] || { echo "$output"; false; }
  [[ "$output" == *"✓ canonical clone is clean"* ]] || { echo "$output"; false; }
}

@test "Tier-0 shared infrastructure rows delegate validate and doctor through the configured repository" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  build_shared_infra_fixture
  write_config '"claude"' "$SHARED"
  DOCTOR_SHARED_OVERRIDE="$SHARED"

  run_doctor
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"✓ shared-infra override: resolved path matches config ($SHARED)"* ]] || { echo "$output"; false; }
  [[ "$output" == *"✓ shared-infra path: $SHARED"* ]] || { echo "$output"; false; }
  [[ "$output" == *"✓ shared-infra manifest: schema and allocation validation passed"* ]] || { echo "$output"; false; }
  [[ "$output" == *"✓ shared-infra doctor: registry parity, runtime, and fixed-port checks passed"* ]] || { echo "$output"; false; }
  grep -F 'validate PROJECT= PROJECTS_FILE=' "$SHARED/calls.log"
  grep -F "doctor PROJECT= REGISTRY_FILE=$CANON/registry.md" "$SHARED/calls.log"
}

@test "Tier-0 shared infrastructure warns when project-side default differs from configured root" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  build_shared_infra_fixture
  write_config '"claude"' "$SHARED"
  local project_default="$SANDBOX/test-home/projects/shared-infra"

  run env -u SHARED_INFRA_ROOT HOME="$SANDBOX/test-home" bash "$DOCTOR"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"⚠ shared-infra override: resolved $project_default differs from config $SHARED — set SHARED_INFRA_ROOT=$SHARED"* ]] || { echo "$output"; false; }
}

@test "Tier-0 shared infrastructure drift fails read-only and leaves drift plus manifest unchanged" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  build_shared_infra_fixture
  write_config '"claude"' "$SHARED"
  DOCTOR_SHARED_OVERRIDE="$SHARED"
  printf 'deliberate drift\n' > "$SHARED/drift"
  local manifest_before drift_before
  manifest_before="$(shasum -a 256 "$SHARED/projects.yaml" | awk '{print $1}')"
  drift_before="$(shasum -a 256 "$SHARED/drift" | awk '{print $1}')"

  run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"✗ shared-infra doctor: read-only checks failed"* ]] || { echo "$output"; false; }
  # The delegated tool's OWN reason has to reach the report. The fixture
  # Makefile writes "fixture doctor: deliberate drift remains" to stderr and
  # make then appends its recipe bookkeeping ("make: *** [doctor] Error 1"),
  # which is why reporting `tail -n 1` of the merged streams surfaced make's
  # wrapper and never the diagnostic. Assert the exit class AND the reason, in
  # one line, so dropping either half fails this test.
  [[ "$output" == *"shared-infra doctor: read-only checks failed (exit 2) — fixture doctor: deliberate drift remains"* ]] || { echo "$output"; false; }
  # make's own bookkeeping is not the diagnostic and must not be reported as one.
  [[ "$output" != *"make: *** ["* ]] || { echo "$output"; false; }
  # "leaves drift ... unchanged" — the drift file is still there, and the two
  # digest comparisons below are the unchanged claim.
  [ -f "$SHARED/drift" ] || { echo "read-only doctor removed the drift file"; false; }
  [ "$(shasum -a 256 "$SHARED/projects.yaml" | awk '{print $1}')" = "$manifest_before" ]
  [ "$(shasum -a 256 "$SHARED/drift" | awk '{print $1}')" = "$drift_before" ]
}

@test "Tier-0 shared infrastructure bounds and escapes the delegated diagnostic it reports" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  build_shared_infra_fixture
  write_config '"claude"' "$SHARED"
  DOCTOR_SHARED_OVERRIDE="$SHARED"
  # A delegated surface whose doctor target prints MORE than the report may
  # carry, one line of it terminal-hostile. `%b` expands the leading \t into the
  # real tab a Make recipe requires and leaves the inner \\-escapes for the
  # recipe's own printf.
  printf '%b\n' \
    'SHELL := /bin/sh' \
    '.PHONY: validate doctor' \
    'validate:' \
    '\t@:' \
    'doctor:' \
    '\t@printf "noise one\\n" >&2' \
    '\t@printf "noise two\\n" >&2' \
    '\t@printf "reason A\\n" >&2' \
    '\t@printf "reason B: \\033]0;pwned\\007\\n" >&2' \
    '\t@printf "reason C\\n" >&2' \
    '\t@exit 1' \
    > "$SHARED/Makefile"

  run_doctor
  [ "$status" -eq 1 ]
  # Last three lines only, joined, with the hostile one replaced in isolation so
  # its safe neighbours stay readable.
  # These assertions are about escape bytes reaching a terminal, so the failure
  # diagnostic has to render them printably rather than replay them.
  [[ "$output" == *"shared-infra doctor: read-only checks failed (exit 2) — reason A; <unsafe tool diagnostic>; reason C"* ]] || { cat -v <<<"$output"; false; }
  [[ "$output" != *"noise one"* ]] || { cat -v <<<"$output"; false; }
  [[ "$output" != *$'\033'* ]] || { cat -v <<<"$output"; false; }

  # Second delegation, identical in shape, with the hostile line carrying a C1
  # control in its UTF-8 spelling (0xC2 0x9B, CSI) instead of a C0 ESC. This is
  # the OTHER arm of `shared_infra_safe_line`'s pattern — the C0/DEL range
  # cannot match a two-byte C1 sequence, so without this case the doctor-local
  # escape copy's `*$'\302'[$'\200'-$'\237']*` branch was never executed and
  # could have been deleted with every assertion still green.
  printf '%b\n' \
    'SHELL := /bin/sh' \
    '.PHONY: validate doctor' \
    'validate:' \
    '\t@:' \
    'doctor:' \
    '\t@printf "noise one\\n" >&2' \
    '\t@printf "noise two\\n" >&2' \
    '\t@printf "reason A\\n" >&2' \
    '\t@printf "reason B: \\302\\233 0;pwned\\n" >&2' \
    '\t@printf "reason C\\n" >&2' \
    '\t@exit 1' \
    > "$SHARED/Makefile"

  run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"shared-infra doctor: read-only checks failed (exit 2) — reason A; <unsafe tool diagnostic>; reason C"* ]] || { cat -v <<<"$output"; false; }
  [[ "$output" != *"noise one"* ]] || { cat -v <<<"$output"; false; }
  # The raw C1 pair itself never reaches the report...
  [[ "$output" != *$'\302\233'* ]] || { cat -v <<<"$output"; false; }
  # ...and neither does the lone 0x9B, which is what a byte-wise reader sees.
  [[ "$output" != *$'\233'* ]] || { cat -v <<<"$output"; false; }
}

@test "Tier-0 GATE: feature-branch canonical => ERROR + non-zero exit, even though the project's rules symlink resolves" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Move the canonical off main onto a real feature branch. The project still
  # symlinks correctly into it — only Tier-0 can catch this poisoning.
  ( cd "$CANON" && git checkout -q -b feat/some-work )

  run_doctor
  # (a) Tier-0 fires the off-main ERROR.
  [ "$status" -ne 0 ]
  [[ "$output" == *"feat/some-work"* ]] || { echo "$output"; false; }
  [[ "$output" == *"expected: main"* ]] || { echo "$output"; false; }
  [[ "$output" == *"✗ inheritance is broken"* ]] || { echo "$output"; false; }
  # (b) The per-project rules check is GREEN — proving the non-zero exit comes
  # from Tier-0, not from a broken symlink. This is what makes the gate
  # load-bearing.
  [[ "$output" == *"✓ rules: trellis.md resolves to canonical"* ]] || { echo "$output"; false; }
}

@test "Tier-0: dirty canonical (uncommitted change) => ERROR + non-zero exit" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Dirty the working tree after the clean commit.
  printf 'drift\n' >> "$CANON/core-rules/CLAUDE.md"

  run_doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"✗ canonical clone has uncommitted changes"* ]] || { echo "$output"; false; }
}

@test "Tier-0: canonical AHEAD of origin/main is NOT an error (no false positive)" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Add a second commit, then plant a local origin/main ref one commit behind
  # HEAD (no network). Now HEAD is 1 ahead of origin/main — the normal state
  # for the source-of-truth clone.
  (
    cd "$CANON"
    printf 'more\n' >> core-rules/CLAUDE.md
    git add -A && git commit -q -m "second"
    git update-ref refs/remotes/origin/main HEAD~1
  )

  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"ahead of origin/main"* ]] || { echo "$output"; false; }
  # Ahead is reported with the OK glyph, never the error glyph.
  [[ "$output" == *"✓"*"ahead of origin/main"* ]] || { echo "$output"; false; }
}

# ===========================================================================
# Tier 1
# ===========================================================================

@test "Tier-1: fully healthy project => all ✓ and exit 0" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ rules: trellis.md resolves to canonical"* ]] || { echo "$output"; false; }
  [[ "$output" == *"✓ import: @-import matches canonical"* ]] || { echo "$output"; false; }
  [[ "$output" == *"✓ skills: full canonical set resolves"* ]] || { echo "$output"; false; }
  [[ "$output" == *"✓ commands: full canonical set resolves"* ]] || { echo "$output"; false; }
  [[ "$output" == *"✓ healthy — no drift detected"* ]] || { echo "$output"; false; }
}

@test "Tier-1: missing rules symlink => ERROR + non-zero exit" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  rm -f "$PROJECTS/healthy/.claude/rules/trellis.md"

  run_doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"✗ rules:"* ]] || { echo "$output"; false; }
  [[ "$output" == *"missing"* ]] || { echo "$output"; false; }
}

@test "Tier-1: stale/broken rules symlink target => ERROR + non-zero exit" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Repoint the symlink at a dead cross-machine path (incident #1 shape).
  rm -f "$PROJECTS/healthy/.claude/rules/trellis.md"
  ln -s "/Users/helios/claude/se-core-template/core-rules/CLAUDE.md" \
        "$PROJECTS/healthy/.claude/rules/trellis.md"

  run_doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"✗ rules:"* ]] || { echo "$output"; false; }
  # Reports the wrong/stale target it found.
  [[ "$output" == *"/Users/helios/"* ]] || { echo "$output"; false; }
}

@test "Tier-1: missing @-import => Claude WARN but OMP parent-chain ERROR (exit non-zero)" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # CLAUDE.md present but with no canonical @-import line at all. The Claude
  # surface degrades to WARN (hc_import_resolves: symlink-only fallback), but
  # OMP installs no RULES.md and has no symlinked rules file — the AGENTS.md
  # @-import is the ONLY channel for parent rules, so the missing import is an
  # OMP inheritance break (hc_omp_project_import ERROR, non-zero exit).
  printf '# Healthy project\n\nNo import here.\n' > "$PROJECTS/healthy/CLAUDE.md"

  run_doctor
  [ "$status" -ne 0 ]
  # Claude row: degraded-not-broken (⚠ WARN), rules symlink still resolves.
  [[ "$output" == *"⚠ import:"* ]] || { echo "$output"; false; }
  [[ "$output" == *"✓ rules: trellis.md resolves to canonical"* ]] || { echo "$output"; false; }
  # OMP row: the missing import is an ERROR — OMP would inherit no parent rules.
  [[ "$output" == *"✗ omp-import:"* ]] || { echo "$output"; false; }
  [[ "$output" == *"no @-import"* ]] || { echo "$output"; false; }
  [[ "$output" == *"✗ inheritance is broken"* ]] || { echo "$output"; false; }
}

@test "Tier-1: dead/cross-machine @-import => ERROR + non-zero exit, rules symlink still ✓" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Present-but-DEAD @-import (incident #1's literal shape: curat.money's import
  # pointed at /Users/helios/...). The rules symlink is left healthy so the only
  # ERROR source is the import branch — this isolates hc_import_resolves's
  # HC_ERROR path from the rules-symlink ERROR path (test 8).
  printf '# Healthy project\n\n@/Users/helios/claude/se-core-template/core-rules/CLAUDE.md\n' \
    > "$PROJECTS/healthy/CLAUDE.md"

  run_doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"✗ import:"* ]] || { echo "$output"; false; }
  # Reports the dead cross-machine target it found.
  [[ "$output" == *"/Users/helios/"* ]] || { echo "$output"; false; }
  # The OMP parent chain is broken by the same dead import (ERROR row).
  [[ "$output" == *"✗ omp-import:"* ]] || { echo "$output"; false; }
  # Load-bearing: the rules symlink is GREEN, proving the non-zero exit comes
  # from the import ERROR, not a broken symlink.
  [[ "$output" == *"✓ rules: trellis.md resolves to canonical"* ]] || { echo "$output"; false; }
}

@test "Tier-1: codex harness lacking parity artifacts => WARN, exit 0" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  # Enable the codex harness. build_healthy_project lays down no AGENTS.md /
  # .agents/ / .codex/ surface, so the codex parity check WARNs with no extra
  # setup. This exercises hc_harness_artifacts's codex branch (silent under the
  # claude-only default).
  write_config '"claude","codex"'

  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠ harness[codex]: missing parity artifact(s)"* ]] || { echo "$output"; false; }
  # Missing parity is degraded, not broken: no inheritance ERROR.
  [[ "$output" != *"✗ inheritance is broken"* ]] || { echo "$output"; false; }
}

@test "Tier-1: missing skill => WARN (not ERROR), exit 0" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Drop one canonical skill symlink from the project.
  rm -f "$PROJECTS/healthy/.claude/skills/analyze"

  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠ skills:"* ]] || { echo "$output"; false; }
  [[ "$output" == *"analyze"* ]] || { echo "$output"; false; }
  # Degraded, not broken: zero errors, no broken-inheritance line.
  [[ "$output" == *"✗ 0 error(s)"* ]] || { echo "$output"; false; }
  [[ "$output" != *"✗ inheritance is broken"* ]] || { echo "$output"; false; }
}

# ===========================================================================
# Exit-code polarity: 0 iff no ERROR present.
# ===========================================================================

@test "exit code: WARN-only run exits 0; ERROR run exits 1" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config

  # WARN-only: drop a skill -> ⚠ but exit 0.
  rm -f "$PROJECTS/healthy/.claude/skills/spec"
  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠"* ]] || { echo "$output"; false; }
  [[ "$output" != *"✗ inheritance is broken"* ]] || { echo "$output"; false; }

  # Now introduce an ERROR (kill the rules symlink) -> exit 1.
  rm -f "$PROJECTS/healthy/.claude/rules/trellis.md"
  run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"✗"* ]] || { echo "$output"; false; }
}

# ===========================================================================
# Phase 8a — process-enforcement inheritance-health checks (all WARN-class,
# never flip the exit; DL-P8a-01..05). Static: never invoke the subject.
# ===========================================================================

@test "P8a hc_reviewer_resolvable: review hook wired + reviewer lib MISSING => WARN, exit 0" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Wire the review hook but leave its sibling lib absent.
  mkdir -p "$PROJECTS/healthy/.claude/hooks"
  printf '#!/usr/bin/env bash\n: review\n' \
    > "$PROJECTS/healthy/.claude/hooks/code-review-subagent.sh"

  run_doctor
  # bats fails only on the LAST command, so the load-bearing WARN assertion is
  # chained into ONE terminal statement (DL-P8a-12): any failing conjunct aborts
  # the test, and the WARN-specific substring is the final discriminator (flips
  # RED under an always-HC_OK mutation of hc_reviewer_resolvable).
  [[ "$output" != *"✗ inheritance is broken"* ]] || { echo "$output"; false; }
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"⚠ reviewer-resolvable:"* ]] \
    && [[ "$output" == *"lib/code-reviewer.sh MISSING"* ]]
}

@test "P8a hc_reviewer_resolvable: no review hook => OK (no manufactured noise)" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # build_healthy_project wires no review hook at all.
  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ reviewer-resolvable: no review hook wired"* ]] || { echo "$output"; false; }
}

@test "P8a hc_reviewer_resolvable: review hook + reviewer lib both present => OK" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  mkdir -p "$PROJECTS/healthy/.claude/hooks/lib"
  printf '#!/usr/bin/env bash\n: review\n' \
    > "$PROJECTS/healthy/.claude/hooks/code-review-subagent.sh"
  printf '#!/usr/bin/env bash\n: reviewer-lib\n' \
    > "$PROJECTS/healthy/.claude/hooks/lib/code-reviewer.sh"

  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ reviewer-resolvable: review hook + reviewer lib both present"* ]] || { echo "$output"; false; }
}

@test "P8a hc_ui_screenshot_path: tracked UI files + no screenshot tool => WARN, exit 0" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # The project must be a git work tree with a TRACKED UI source file for
  # `git ls-files` to enumerate it.
  (
    cd "$PROJECTS/healthy"
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name  "test"
    git config commit.gpgsign false
    printf 'export const X = 1;\n' > App.tsx
    git add App.tsx
    git commit -q -m "ui"
  )
  # HERMETIC (DL-P8a-12): the WARN branch is gated on `command -v playwright`,
  # which RESOLVES on this operator's host (pyenv shim) — so without isolation
  # the doctor would run the OPPOSITE (resolvable-tool) branch and the WARN
  # assertion would be false-green. Run the doctor child under a sanitized PATH
  # that mirrors every executable EXCEPT playwright, so the no-tool WARN branch
  # is deterministically reached on EVERY host. UI_SHOT_CMD="" closes the first
  # leg of "no resolvable tool".
  local farm
  farm="$(make_no_playwright_path)"
  run env PATH="$farm" UI_SHOT_CMD="" bash "$DOCTOR"
  # Chained terminal assertion (DL-P8a-12): WARN substring is the final
  # discriminator so the test goes RED under an always-HC_OK / resolvable-✓
  # mutation of hc_ui_screenshot_path.
  [[ "$output" != *"✗ inheritance is broken"* ]] || { echo "$output"; false; }
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"⚠ ui-screenshot-path:"* ]] \
    && [[ "$output" == *"no screenshot tool resolves"* ]]
}

@test "P8a hc_ui_screenshot_path: non-UI project => OK" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # build_healthy_project is not a git work tree and tracks no UI files, so
  # `git ls-files` is empty -> not a UI project.
  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ ui-screenshot-path: no tracked UI source files"* ]] || { echo "$output"; false; }
}

@test "P8a hc_prepush_wired_runall: no pre-push hook => WARN, exit 0" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Remove the pre-push the healthy fixture wires.
  rm -f "$PROJECTS/healthy/.husky/pre-push"

  run_doctor
  # Chained terminal assertion (DL-P8a-12): WARN substring is the final
  # discriminator so the test goes RED under an always-HC_OK mutation.
  [[ "$output" != *"✗ inheritance is broken"* ]] || { echo "$output"; false; }
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"⚠ prepush-wired-runall:"* ]] \
    && [[ "$output" == *"no pre-push hook"* ]]
}

@test "P8a hc_prepush_wired_runall: pre-push present but NOT wired to run-all.sh => WARN" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Overwrite the wired hook with one that does not reference run-all.sh.
  printf '#!/usr/bin/env sh\nnpm test\n' > "$PROJECTS/healthy/.husky/pre-push"

  run_doctor
  # Chained terminal assertion (DL-P8a-12): the dead non-final `status` check is
  # folded into one statement ending on the WARN-specific discriminator.
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"⚠ prepush-wired-runall:"* ]] \
    && [[ "$output" == *"not wired to run-all.sh"* ]]
}

@test "P8a hc_prepush_wired_runall: pre-push wired to run-all.sh => OK (.git/hooks fallback)" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Drop the .husky hook and instead wire .git/hooks/pre-push (the fallback
  # location) referencing the .agents/ path variant.
  rm -f "$PROJECTS/healthy/.husky/pre-push"
  mkdir -p "$PROJECTS/healthy/.git/hooks"
  printf '#!/usr/bin/env sh\nbash .agents/skills/process-gate/scripts/run-all.sh --mode=merge\n' \
    > "$PROJECTS/healthy/.git/hooks/pre-push"

  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ prepush-wired-runall: pre-push references process-gate run-all.sh"* ]] || { echo "$output"; false; }
}

@test "P8a hc_prepush_wired_runall: native core.hooksPath=.githooks wired to run-all.sh => OK" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Native-git-hooks project (lume / clusterbid-console shape): no husky, the
  # active hook lives at .githooks/pre-push via core.hooksPath. Reading
  # core.hooksPath needs a real repo, so git-init the project and pin the config.
  local hp="$PROJECTS/healthy"
  rm -rf "$hp/.husky"
  (
    cd "$hp"
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name  "test"
    git config core.hooksPath .githooks
  )
  mkdir -p "$hp/.githooks"
  printf '#!/usr/bin/env sh\nbash .claude/skills/process-gate/scripts/run-all.sh --mode=merge\n' \
    > "$hp/.githooks/pre-push"

  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ prepush-wired-runall: pre-push references process-gate run-all.sh"* ]] || { echo "$output"; false; }
}

@test "P8a hc_prepush_wired_runall: core.hooksPath set but target pre-push missing => WARN" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # No false positive: hooksPath points at .githooks but no .githooks/pre-push
  # exists, and a stale .husky/pre-push (the fixture default) must NOT be
  # consulted because git would never run it.
  local hp="$PROJECTS/healthy"
  (
    cd "$hp"
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name  "test"
    git config core.hooksPath .githooks
  )
  mkdir -p "$hp/.githooks"

  run_doctor
  # Chained terminal assertion (DL-P8a-12): WARN substring is the final
  # discriminator so the test goes RED under an always-HC_OK mutation.
  [[ "$output" != *"✗ inheritance is broken"* ]] || { echo "$output"; false; }
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"⚠ prepush-wired-runall:"* ]] \
    && [[ "$output" == *"no pre-push hook"* ]]
}

@test "P8a hc_receipt_grammar_present (Tier-0): canonical CLAUDE.md MISSING dod-receipt => WARN, exit 0" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Strip the dod-receipt grammar from the canonical rules, then re-commit so
  # the canonical tree stays clean (else the Tier-0 dirty check would fire too).
  printf '# Parent engineering rules\n' > "$CANON/core-rules/CLAUDE.md"
  ( cd "$CANON" && git add -A && git commit -q -m "strip receipt grammar" )

  run_doctor
  # Chained terminal assertion (DL-P8a-12): WARN substring is the final
  # discriminator so the test goes RED under an always-HC_OK mutation.
  [[ "$output" != *"✗ inheritance is broken"* ]] || { echo "$output"; false; }
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"⚠ receipt-grammar-present:"* ]] \
    && [[ "$output" == *"dod-receipt grammar MISSING"* ]]
}

@test "P8a hc_receipt_grammar_present (Tier-0): canonical CLAUDE.md with dod-receipt => OK" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # build_canonical_tree now lays down the dod-receipt anchor.
  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ receipt-grammar-present: dod-receipt grammar present"* ]] || { echo "$output"; false; }
}

@test "adopt-008 hc_claudemd_budget (Tier-0): canonical CLAUDE.md under line budget => OK" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # The default fixture CLAUDE.md is only a few lines — well under the 200-line
  # attention budget, so the guardrail is OK.
  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ claudemd-budget: core-rules/CLAUDE.md is"* ]] || { echo "$output"; false; }
  [[ "$output" == *"(budget: 200)"* ]] || { echo "$output"; false; }
}

@test "adopt-008 hc_claudemd_budget (Tier-0): canonical CLAUDE.md over line budget => WARN, exit 0" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Grow the canonical rules past the 200-line attention budget while KEEPING the
  # dod-receipt anchor (so receipt-grammar stays OK and this WARN is isolated),
  # then re-commit so the canonical tree stays clean (else the Tier-0 dirty check
  # would also fire and mask the result).
  {
    printf '# Parent engineering rules\n\n<!-- dod-receipt cmd= exit=0 diff= -->\n'
    i=1
    while [ "$i" -le 250 ]; do
      printf -- '- rule line %s\n' "$i"
      i=$((i + 1))
    done
  } > "$CANON/core-rules/CLAUDE.md"
  ( cd "$CANON" && git add -A && git commit -q -m "grow parent rules past budget" )

  run_doctor
  # Chained terminal assertion (DL-P8a-12): WARN substring is the final
  # discriminator so the test goes RED under an always-HC_OK mutation.
  [[ "$output" != *"✗ inheritance is broken"* ]] || { echo "$output"; false; }
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"⚠ claudemd-budget:"* ]] \
    && [[ "$output" == *"past the attention cliff"* ]]
}

# ===========================================================================
# OMP surface (design 2026-08-09) — Tier-1 live-link contract. All ERROR-class:
# OMP native discovery stops at the nearest non-empty .omp dir, so any broken
# Trellis-owned .omp path silently yields an unparented OMP session.
# ===========================================================================

@test "OMP: fully healthy OMP surface => all ✓ and exit 0" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ omp: all 5 surface links resolve to exact canonical targets"* ]] || { echo "$output"; false; }
  [[ "$output" == *"✓ omp: target kinds correct and canonical links stay under trellis_root"* ]] || { echo "$output"; false; }
  [[ "$output" == *"✓ omp-import: first @-import → canonical core-rules/CLAUDE.md"* ]] || { echo "$output"; false; }
  [[ "$output" == *"✓ omp-manifests: canonical skill/command/agent manifests satisfy OMP discovery"* ]] || { echo "$output"; false; }
  [[ "$output" == *"✓ omp-adapter: canonical adapter present"* ]] || { echo "$output"; false; }
}

@test "OMP: disabled harness imposes no .omp or canonical OMP dependency" {
  build_canonical_tree
  rm -rf "$CANON/core-rules/agents" "$CANON/core-rules/omp"
  git_init_canonical_main
  build_healthy_project
  rm -rf "$PROJECTS/healthy/.omp"
  write_config '"claude"'

  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *"omp:"* ]] || { echo "$output"; false; }
  [[ "$output" != *"omp-import:"* ]] || { echo "$output"; false; }
  [[ "$output" != *"omp-manifests:"* ]] || { echo "$output"; false; }
  [[ "$output" != *"omp-adapter:"* ]] || { echo "$output"; false; }
}

@test "OMP: missing .omp/AGENTS.md => ERROR + non-zero exit" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  rm -f "$PROJECTS/healthy/.omp/AGENTS.md"

  run_doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"✗ omp: .omp/AGENTS.md missing"* ]] || { echo "$output"; false; }
}

@test "OMP: dangling .omp/skills symlink => ERROR + non-zero exit" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  rm -f "$PROJECTS/healthy/.omp/skills"
  ln -s "$CANON/core-rules/skills-does-not-exist" "$PROJECTS/healthy/.omp/skills"
  [ ! -e "$PROJECTS/healthy/.omp/skills" ]  # precondition: truly dangling

  run_doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"✗ omp: .omp/skills →"* ]] || { echo "$output"; false; }
  [[ "$output" == *"dangling"* ]] || { echo "$output"; false; }
}

@test "OMP: wrong-target .omp/agents link => ERROR + non-zero exit" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Repoint at a dead cross-machine path (incident #1 shape).
  rm -f "$PROJECTS/healthy/.omp/agents"
  ln -s "/Users/helios/claude/se-core-template/core-rules/agents" \
        "$PROJECTS/healthy/.omp/agents"

  run_doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"✗ omp: .omp/agents →"* ]] || { echo "$output"; false; }
  # Reports the wrong/stale target it found.
  [[ "$output" == *"/Users/helios/"* ]] || { echo "$output"; false; }
}

@test "OMP: .omp/skills replaced by a regular file (not a symlink) => ERROR" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  rm -f "$PROJECTS/healthy/.omp/skills"
  printf 'not a link\n' > "$PROJECTS/healthy/.omp/skills"

  run_doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"✗ omp: .omp/skills exists but is not a symlink"* ]] || { echo "$output"; false; }
}

@test "OMP: wrong target kind (dir link resolving to a regular file) => ERROR + non-zero exit" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Replace the canonical hooks DIRECTORY with a regular FILE at the same path,
  # then re-commit so the canonical stays clean: .omp/hooks still has the exact
  # literal target (link row stays ✓) but resolves to a non-directory — only
  # the target-kind half of the contract can catch this.
  rm -rf "$CANON/core-rules/omp/hooks"
  printf 'not a dir\n' > "$CANON/core-rules/omp/hooks"
  ( cd "$CANON" && git add -A && git commit -q -m "hooks path becomes a file" )

  run_doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"✓ omp: all 5 surface links resolve to exact canonical targets"* ]] || { echo "$output"; false; }
  [[ "$output" == *"✗ omp: .omp/hooks resolves to a non-directory target"* ]] || { echo "$output"; false; }
}

@test "OMP: realpath containment — canonical link resolving OUTSIDE trellis_root => ERROR" {
  build_canonical_tree
  # Redirect core-rules/skills out of the canonical root BEFORE the git init so
  # the committed tree is clean: the .omp/skills link still reads
  # <canon>/core-rules/skills (exact target ✓) but its realpath escapes
  # trellis_root — only the containment half of the contract can catch this.
  mkdir -p "$SANDBOX/elsewhere/skills/process-gate"
  printf -- '---\ndescription: elsewhere skill\n---\n\nx\n' \
    > "$SANDBOX/elsewhere/skills/process-gate/SKILL.md"
  mv "$CANON/core-rules/skills" "$CANON/core-rules/skills.orig"
  ln -s "$SANDBOX/elsewhere/skills" "$CANON/core-rules/skills"
  git_init_canonical_main
  build_healthy_project
  write_config

  run_doctor
  [ "$status" -ne 0 ]
  # Load-bearing: the exact-target row is GREEN — the ERROR comes from the
  # containment check, not from re-detecting a wrong target.
  [[ "$output" == *"✓ omp: all 5 surface links resolve to exact canonical targets"* ]] || { echo "$output"; false; }
  [[ "$output" == *"✗ omp: .omp/skills resolves to"* ]] || { echo "$output"; false; }
  [[ "$output" == *"OUTSIDE the canonical root"* ]] || { echo "$output"; false; }
}

@test "OMP: first @-import is NOT canonical => ERROR even when a later import is" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # A project-local import FIRST, the canonical one second. The Claude-side
  # check (hc_import_resolves) scans every import and is satisfied; the OMP
  # check requires the FIRST import to be canonical (OMP resolves imports
  # top-down and the design pins "whose first import resolves canonical").
  printf '# Healthy project\n\n@docs/strategy.md\n@%s/core-rules/CLAUDE.md\n' \
    "$CANON" > "$PROJECTS/healthy/CLAUDE.md"

  run_doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"✓ import: @-import matches canonical"* ]] || { echo "$output"; false; }
  [[ "$output" == *"✗ omp-import:"* ]] || { echo "$output"; false; }
  [[ "$output" == *"docs/strategy.md"* ]] || { echo "$output"; false; }
}

@test "OMP: skill dir missing SKILL.md => manifest ERROR + non-zero exit" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  rm -f "$CANON/core-rules/skills/analyze/SKILL.md"
  # Re-commit so the canonical stays clean (else Tier-0 dirty would mask the
  # manifest row). The Claude-side skill LINK still resolves (dir remains).
  ( cd "$CANON" && git add -A && git commit -q -m "break skill manifest" )

  run_doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"✗ omp-manifests:"* ]] || { echo "$output"; false; }
  [[ "$output" == *"analyze"* ]] || { echo "$output"; false; }
  [[ "$output" == *"✓ skills: full canonical set resolves"* ]] || { echo "$output"; false; }
}

@test "OMP: command without description frontmatter => manifest ERROR + non-zero exit" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  printf 'no frontmatter\n' > "$CANON/core-rules/commands/primer.md"
  ( cd "$CANON" && git add -A && git commit -q -m "strip command description" )

  run_doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"✗ omp-manifests:"* ]] || { echo "$output"; false; }
  [[ "$output" == *"primer"* ]] || { echo "$output"; false; }
}

@test "OMP: legacy .md agent still discoverable in canonical agents dir => manifest ERROR" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # The custom fable/opus/codex/lane agents are GPTX-era and removed; any
  # discoverable *.md left behind is a legacy agent OMP would load (first-win
  # by name) and must be purged. Empty (only .gitkeep) is the healthy state.
  printf '# legacy agent\n' > "$CANON/core-rules/agents/legacy-agent.md"
  ( cd "$CANON" && git add -A && git commit -q -m "legacy agent resurfaces" )

  run_doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"✗ omp-manifests:"* ]] || { echo "$output"; false; }
  [[ "$output" == *"agents:legacy-agent.md"* ]] || { echo "$output"; false; }
}

@test "OMP: canonical adapter missing => ERROR + non-zero exit" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  rm -f "$CANON/core-rules/omp/hooks/pre/trellis.ts"
  ( cd "$CANON" && git add -A && git commit -q -m "drop adapter" )

  run_doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"✗ omp-adapter: canonical adapter"* ]] || { echo "$output"; false; }
  [[ "$output" == *"missing"* ]] || { echo "$output"; false; }
  # The .omp/hooks LINK itself still resolves to the (empty) hooks dir — the
  # adapter row is the isolated failure.
  [[ "$output" == *"✓ omp: all 5 surface links resolve to exact canonical targets"* ]] || { echo "$output"; false; }
}

@test "OMP: canonical control-plane project — .omp/AGENTS.md → core-rules/CLAUDE.md, no parent import" {
  build_canonical_tree
  # The canonical clone carries its own ignored .claude/.omp/.husky surfaces
  # (managed-ignore pattern); commit the ignore so the tree stays clean while
  # those surfaces are untracked.
  printf '.claude/\n.omp/\n.husky/\n' > "$CANON/.gitignore"
  git_init_canonical_main
  # Register the canonical clone itself as a control-plane project. The
  # canonical root has no CLAUDE.md (build_canonical_tree writes only
  # core-rules/CLAUDE.md), so the OMP contract expects .omp/AGENTS.md to link
  # the parent rules file directly and skips the parent-import check.
  cat > "$CANON/registry.md" <<EOF
# Project registry

## Active projects

| Project | Path | Class | Notes |
|---|---|---|---|
| trellis | \`/trellis\` | control-plane | canonical clone itself |
| healthy | \`/personal/healthy\` | app | fixture |

---
EOF
  ( cd "$CANON" && git add registry.md && git commit -q -m "register control-plane" )
  # $PROJECTS/trellis IS the canonical clone (realpath-equal) — the shape
  # doctor resolves for a control-plane registry row.
  ln -s "$CANON" "$PROJECTS/trellis"
  local cp="$PROJECTS/trellis"
  # Seed the canonical's own inheritance surfaces (ignored -> tree stays clean).
  mkdir -p "$cp/.claude/rules" "$cp/.claude/skills" "$cp/.claude/commands" \
    "$cp/.omp" "$cp/.husky"
  ln -s "$CANON/core-rules/CLAUDE.md" "$cp/.claude/rules/trellis.md"
  local s c

  for s in $CANON_SKILLS; do
    ln -s "$CANON/core-rules/skills/$s" "$cp/.claude/skills/$s"
  done
  for c in $CANON_COMMANDS; do
    ln -s "$CANON/core-rules/commands/$c.md" "$cp/.claude/commands/$c.md"
  done
  printf '{ "hooks": {} }\n' > "$cp/.claude/settings.json"
  printf '#!/usr/bin/env sh\nbash .claude/skills/process-gate/scripts/run-all.sh --mode=merge\n' \
    > "$cp/.husky/pre-push"
  # OMP control-plane surface: AGENTS.md links the parent rules FILE.
  ln -s "$CANON/core-rules/CLAUDE.md" "$cp/.omp/AGENTS.md"
  ln -s "$CANON/core-rules/skills" "$cp/.omp/skills"
  ln -s "$CANON/core-rules/commands" "$cp/.omp/commands"
  ln -s "$CANON/core-rules/agents" "$cp/.omp/agents"
  ln -s "$CANON/core-rules/omp/hooks" "$cp/.omp/hooks"
  build_healthy_project
  write_config

  run_doctor
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # The control-plane project's .omp/AGENTS.md links the parent rules FILE...
  [ "$(readlink "$cp/.omp/AGENTS.md")" = "$CANON/core-rules/CLAUDE.md" ]
  # ...and passes without a parent-import row (there is no parent above it).
  [[ "$output" == *"✓ omp: all 5 surface links resolve to exact canonical targets"* ]] || { echo "$output"; false; }
  [[ "$output" == *"✓ omp-import: canonical control-plane project"* ]] || { echo "$output"; false; }
  # The ordinary healthy project still requires its own CLAUDE.md import.
  [[ "$output" == *"✓ omp-import: first @-import → canonical core-rules/CLAUDE.md"* ]] || { echo "$output"; false; }
}

# ===========================================================================
# Portable local-registry doctor (Spec 036 T15)
# ===========================================================================

@test "portable doctor accepts an empty validated local registry" {
  build_portable_doctor_home

  run_portable_doctor

  [ "$status" -eq 0 ]
  [[ "$output" == *"local registry: validated local fleet inventory"* ]] || { echo "$output"; false; }
  [[ "$output" == *"no locally registered checkout records"* ]] || { echo "$output"; false; }
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
{"schema_version":1,"projects":{"personal/portable-fixture":{"fleet":"personal","project_id":"portable-fixture","status":"active","metadata":{},"checkouts":{"$checkout_id":{"root":"$PORTABLE_PROJECT","git_common_dir":"$common","release":"1.2.3","harnesses":["claude","codex","omp"],"worktrees":{"$worktree_id":{"root":"$PORTABLE_PROJECT"}}}}}},"discovery_ignores":{}}
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
{"schema_version":1,"projects":{"personal/portable-fixture":{"fleet":"personal","project_id":"portable-fixture","status":"active","metadata":{},"checkouts":{"$checkout_id":{"root":"$PORTABLE_PROJECT","git_common_dir":"$common","release":"1.2.3","harnesses":["claude","codex","omp"],"worktrees":{"$worktree_id":{"root":"$PORTABLE_PROJECT"}}}}}},"discovery_ignores":{}}
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
{"schema_version":1,"projects":{"personal/portable-fixture":{"fleet":"personal","project_id":"portable-fixture","status":"active","metadata":{},"checkouts":{"$checkout_id":{"root":"$PORTABLE_PROJECT","git_common_dir":"$common","release":"1.2.3","harnesses":["claude","codex","omp"],"worktrees":{"$worktree_id":{"root":"$PORTABLE_PROJECT"}}}}}},"discovery_ignores":{}}
EOF
  chmod 600 "$PORTABLE_HOME/registry.json"

  run_portable_doctor

  [ "$status" -eq 0 ]
  [[ "$output" == *"layout: inert non-user portable manifest (not locally attached)"* ]] || { echo "$output"; false; }
  [[ "$output" == *"attachment ownership: no committed owner record"* ]] || { echo "$output"; false; }
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

@test "portable show-config rejects a selected fleet that conflicts with registry ownership" {
  build_portable_doctor_home
  prepare_portable_attachment
  jq '.fleets.work = .fleets.personal' "$PORTABLE_HOME/config.json" \
    > "$PORTABLE_HOME/config.json.next"
  mv "$PORTABLE_HOME/config.json.next" "$PORTABLE_HOME/config.json"
  chmod 600 "$PORTABLE_HOME/config.json"

  run_portable_show_config --home "$PORTABLE_HOME" --fleet work

  [ "$status" -eq 3 ]
  [[ "$output" == *"registry:              fleet conflict (selected work, authoritative personal)"* ]] || { echo "$output"; false; }
  [[ "$output" == *"registry move:         detach, then reattach with --fleet work"* ]] || { echo "$output"; false; }
  [[ "$output" != *"valid local owner record"* ]] || { echo "$output"; false; }
}

@test "portable show-config retains safe sections when source is unavailable" {
  build_portable_doctor_home
  rm -rf "$PORTABLE_SOURCE"

  run_portable_show_config

  [ "$status" -ne 0 ]
  [[ "$output" == *"management source:     unavailable ($PORTABLE_SOURCE)"* ]] || { echo "$output"; false; }
  [[ "$output" == *"=== Checkout/worktree context (local registry) ==="* ]] || { echo "$output"; false; }
  [[ "$output" == *"=== Portable project policy ==="* ]] || { echo "$output"; false; }
}

@test "portable show-config reports an invalid active release without stopping safe output" {
  build_portable_doctor_home
  jq '.active_cli_release = "9.9.9"' "$PORTABLE_HOME/config.json" > "$PORTABLE_HOME/config.json.next"
  mv "$PORTABLE_HOME/config.json.next" "$PORTABLE_HOME/config.json"
  chmod 600 "$PORTABLE_HOME/config.json"

  run_portable_show_config

  [ "$status" -ne 0 ]
  [[ "$output" == *"active CLI release:    9.9.9"* ]] || { echo "$output"; false; }
  [[ "$output" == *"release payload:       unavailable or invalid"* ]] || { echo "$output"; false; }
  [[ "$output" == *"=== Portable project policy ==="* ]] || { echo "$output"; false; }
}

@test "portable show-config does not mislabel corrupt registry state as unregistered" {
  build_portable_doctor_home
  printf '{not json}\n' > "$PORTABLE_HOME/registry.json"
  chmod 600 "$PORTABLE_HOME/registry.json"

  run_portable_show_config

  [ "$status" -ne 0 ]
  [[ "$output" == *"registry:              unavailable, invalid, unsafe, or identity-drift local state"* ]] || { echo "$output"; false; }
  [[ "$output" != *"registry:              this worktree is not locally registered"* ]] || { echo "$output"; false; }
  [[ "$output" == *"=== Portable project policy ==="* ]] || { echo "$output"; false; }
}

@test "portable show-config reports fleet identity drift and this worktree's own drifted row" {
  build_portable_doctor_home
  prepare_portable_attachment
  add_portable_identity_error_sibling

  run_portable_show_config

  # A sibling's drift never hides this worktree's own resolvable registration,
  # but it stays visible and it still fails the run.
  [ "$status" -eq 4 ]
  [[ "$output" == *"registry state:        1 row(s) in fleet personal failed identity validation"* ]] || { echo "$output"; false; }
  [[ "$output" == *"registry project:      portable-fixture"* ]] || { echo "$output"; false; }
  [[ "$output" != *"registry:              unavailable, invalid, unsafe, or identity-drift local state"* ]] || { echo "$output"; false; }
  [[ "$output" != *"registry:              this worktree is not locally registered"* ]] || { echo "$output"; false; }

  # The same worktree's OWN row failing identity validation is a state error.
  rewrite_portable_registry --arg moved "$SANDBOX/moved checkout" '
    .projects["personal/portable-fixture"].checkouts |= with_entries(.value.root = $moved)'

  run_portable_show_config

  [ "$status" -eq 4 ]
  [[ "$output" == *"registry:              this worktree's registered row failed identity validation"* ]] || { echo "$output"; false; }
  [[ "$output" != *"registry:              this worktree is not locally registered"* ]] || { echo "$output"; false; }
  [[ "$output" == *"=== Portable project policy ==="* ]] || { echo "$output"; false; }
}

@test "portable show-config reports drifted rows outside the selected fleet report-only" {
  build_portable_doctor_home
  prepare_portable_attachment
  add_portable_identity_error_sibling
  # Move the drifted sibling into a SECOND fleet. The listing show-config reads
  # is taken with no fleet argument — it covers the whole machine — but the only
  # count it kept was the selected fleet's, so this row was invisible and the
  # whole-machine claim disagreed with the behaviour.
  jq --arg root "$SANDBOX" '.fleets.work = {discovery_roots: [$root]}' \
    "$PORTABLE_HOME/config.json" > "$SANDBOX/config.next"
  mv -f "$SANDBOX/config.next" "$PORTABLE_HOME/config.json"
  chmod 600 "$PORTABLE_HOME/config.json"
  rewrite_portable_registry '
    .projects["work/portable-sibling"] = (.projects["personal/portable-sibling"] | .fleet = "work")
    | del(.projects["personal/portable-sibling"])'

  run_portable_show_config

  # Report-only: the selected fleet is clean, so the exit class stays clean too.
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qF 'registry state (machine): 1 row(s) outside fleet personal failed identity validation (report-only)' <<<"$output"
  [ "$(grep -cF 'row(s) in fleet personal failed identity validation' <<<"$output")" -eq 0 ]
}

@test "portable show-config reports an invalid manifest without hiding local state" {
  build_portable_doctor_home
  printf '%s\n' '{"schema_version":1,"project_id":"portable-fixture","fleet":"personal"}' \
    > "$PORTABLE_PROJECT/.trellis.json"

  run_portable_show_config

  [ "$status" -ne 0 ]
  [[ "$output" == *"manifest:              invalid portable policy"* ]] || { echo "$output"; false; }
  [[ "$output" == *"selected fleet:        personal"* ]] || { echo "$output"; false; }
  [[ "$output" == *"=== Resolved autonomy level (this turn) ==="* ]] || { echo "$output"; false; }
}

@test "portable show-config rejects a schema-valid owner with mismatched registry identity" {
  build_portable_doctor_home
  prepare_portable_attachment "different-project"

  run_portable_show_config

  [ "$status" -ne 0 ]
  [[ "$output" == *"attachment:            invalid local attachment"* ]] || { echo "$output"; false; }
  [[ "$output" == *"owner record does not exactly match its registry checkout/worktree identity"* ]] || { echo "$output"; false; }
  [[ "$output" != *"valid strict local attachment"* ]] || { echo "$output"; false; }
}

@test "portable show-config renders autonomy from verified attachment policy" {
  build_portable_doctor_home
  prepare_portable_attachment
  jq '.presets = ["strict"]' "$PORTABLE_PROJECT/.trellis.json" > "$PORTABLE_PROJECT/.trellis.json.next"
  mv "$PORTABLE_PROJECT/.trellis.json.next" "$PORTABLE_PROJECT/.trellis.json"
  mkdir -p "$PORTABLE_PROJECT/.claude"
  printf '5\n' > "$PORTABLE_PROJECT/.claude/session-autonomy"

  run_portable_show_config

  [ "$status" -eq 0 ]
  [[ "$output" == *"policy source:         verified immutable attachment payload $PORTABLE_RELEASE_PAYLOAD"* ]] || { echo "$output"; false; }
  [[ "$output" == *"strict: default=L4 ceiling=L2"* ]] || { echo "$output"; false; }
  [[ "$output" == *"session override:      L5"* ]] || { echo "$output"; false; }
  [[ "$output" == *"requested level:       L5"* ]] || { echo "$output"; false; }
  [[ "$output" == *"effective level:       L2 (Cautious)"* ]] || { echo "$output"; false; }
  [[ "$output" == *"effective ceiling:     L2"* ]] || { echo "$output"; false; }
  [[ "$output" == *"limiting preset:       strict"* ]] || { echo "$output"; false; }
}

@test "portable show-config verifies render context from the owner rather than caller HOME" {
  build_portable_doctor_home
  prepare_portable_attachment
  hostile_home="$SANDBOX/hostile caller home"
  mkdir -p "$hostile_home/.local/bin"
  printf '#!/usr/bin/env bash\nexit 99\n' > "$hostile_home/.local/bin/trellis"
  chmod 755 "$hostile_home/.local/bin/trellis"

  # HOME is the caller-controlled value under test. TRELLIS_HOME is not a peer
  # of it any more: the launcher exports it as part of the attestation that
  # authorizes this run at all, so a hostile TRELLIS_HOME now produces the
  # direct-source refusal rather than a render, and the render-context claim is
  # made against the caller HOME alone.
  SHOW_CONFIG_CALLER_HOME="$hostile_home"
  run_portable_show_config
  unset SHOW_CONFIG_CALLER_HOME

  [ "$status" -eq 0 ]
  [[ "$output" == *"attachment:            valid strict local attachment"* ]] || { echo "$output"; false; }
  [[ "$output" == *"policy source:         verified immutable attachment payload $PORTABLE_RELEASE_PAYLOAD"* ]] || { echo "$output"; false; }
}

@test "portable show-config rejects contextual renders without their committed render context" {
  build_portable_doctor_home
  prepare_portable_attachment
  owner="$PORTABLE_HOME/state/attachments/$PORTABLE_CHECKOUT_ID/$PORTABLE_WORKTREE_ID.json"
  jq 'del(.render_context)' "$owner" > "$owner.next"
  mv "$owner.next" "$owner"
  chmod 600 "$owner"

  run_portable_show_config

  [ "$status" -ne 0 ]
  [[ "$output" == *"attachment:            invalid local attachment"* ]] || { echo "$output"; false; }
  [[ "$output" != *"valid strict local attachment"* ]] || { echo "$output"; false; }
}

@test "portable show-config rejects render context bound to another machine home" {
  build_portable_doctor_home
  prepare_portable_attachment
  other_home="$SANDBOX/another machine home"
  mkdir -p "$other_home"
  chmod 700 "$other_home"
  owner="$PORTABLE_HOME/state/attachments/$PORTABLE_CHECKOUT_ID/$PORTABLE_WORKTREE_ID.json"
  jq --arg home "$other_home" --arg shell "'$other_home'" '
    .render_context.trellis_home = $home
    | .render_context.trellis_home_shell = $shell
  ' "$owner" > "$owner.next"
  mv "$owner.next" "$owner"
  chmod 600 "$owner"

  run_portable_show_config

  [ "$status" -ne 0 ]
  [[ "$output" == *"attachment:            invalid local attachment"* ]] || { echo "$output"; false; }
  [[ "$output" != *"valid strict local attachment"* ]] || { echo "$output"; false; }
}

@test "portable show-config rejects a missing runtime anchor" {
  build_portable_doctor_home
  prepare_portable_attachment
  rm "$PORTABLE_PROJECT/.trellis/runtime"

  run_portable_show_config

  [ "$status" -ne 0 ]
  [[ "$output" == *"attachment:            invalid local attachment"* ]] || { echo "$output"; false; }
  [[ "$output" == *"runtime anchor is missing"* ]] || { echo "$output"; false; }
  [[ "$output" != *"valid strict local attachment"* ]] || { echo "$output"; false; }
}

@test "portable show-config rejects managed hook drift" {
  build_portable_doctor_home
  prepare_portable_attachment
  printf '# drift\n' >> "$PORTABLE_HOME/state/git-hooks/$PORTABLE_CHECKOUT_ID/post-checkout"

  run_portable_show_config

  [ "$status" -ne 0 ]
  [[ "$output" == *"attachment:            invalid local attachment"* ]] || { echo "$output"; false; }
  [[ "$output" == *"managed hook"* ]] || { echo "$output"; false; }
  [[ "$output" != *"valid strict local attachment"* ]] || { echo "$output"; false; }
}

@test "portable show-config rejects an owned native artifact that drifts" {
  build_portable_doctor_home
  prepare_portable_attachment
  rm "$PORTABLE_PROJECT/.omp/AGENTS.md"

  run_portable_show_config

  [ "$status" -ne 0 ]
  [[ "$output" == *"attachment:            invalid local attachment"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Trellis-owned artifact"* ]] || { echo "$output"; false; }
  [[ "$output" != *"valid strict local attachment"* ]] || { echo "$output"; false; }
}

@test "portable show-config rejects native surface and exclude drift" {
  build_portable_doctor_home
  prepare_portable_attachment
  jq --arg checkout "$PORTABLE_CHECKOUT_ID" '
    .projects["personal/portable-fixture"].checkouts[$checkout].harnesses = ["claude"]
  ' "$PORTABLE_HOME/registry.json" > "$PORTABLE_HOME/registry.json.next"
  mv "$PORTABLE_HOME/registry.json.next" "$PORTABLE_HOME/registry.json"
  chmod 600 "$PORTABLE_HOME/registry.json"

  run_portable_show_config

  [ "$status" -ne 0 ]
  # hc_portable_attachment runs hc_portable_excludes before
  # hc_portable_native_surfaces and returns on the first error
  # (scripts/lib/health-checks.sh), and the registry harness selection is an
  # input to the native-surface plan the exclude block is derived from. So
  # shrinking the harness list is caught by the excludes check first and never
  # reaches the "native surfaces: registry harness selection does not exactly
  # match" wording this assertion used to ask for. That assertion was inert (a
  # bare mid-test `[[ … ]]` does not fail a bats test on this host), so it never
  # reported that it was checking for a message this path cannot produce.
  # Failing closed at the earliest check is the intended behaviour; assert the
  # reason actually emitted.
  [[ "$output" == *"managed excludes: owner block does not match the exact immutable native surface plan"* ]] ||
    { echo "$output"; false; }

  [[ "$output" != *"valid strict local attachment"* ]] || { echo "$output"; false; }

  jq --arg checkout "$PORTABLE_CHECKOUT_ID" '
    .projects["personal/portable-fixture"].checkouts[$checkout].harnesses = ["claude", "codex", "omp"]
  ' "$PORTABLE_HOME/registry.json" > "$PORTABLE_HOME/registry.json.next"
  mv "$PORTABLE_HOME/registry.json.next" "$PORTABLE_HOME/registry.json"
  chmod 600 "$PORTABLE_HOME/registry.json"
  printf '\n# local exclude drift\n' >> "$PORTABLE_PROJECT/.git/info/exclude"

  run_portable_show_config

  [ "$status" -ne 0 ]
  [[ "$output" == *"managed excludes: exact Trellis-owned block or surrounding user bytes changed"* ]] || { echo "$output"; false; }
  [[ "$output" != *"valid strict local attachment"* ]] || { echo "$output"; false; }
}
@test "portable show-config rejects a forged owner exclude block that differs from immutable surfaces" {
  build_portable_doctor_home
  prepare_portable_attachment
  owner="$PORTABLE_HOME/state/attachments/$PORTABLE_CHECKOUT_ID/$PORTABLE_WORKTREE_ID.json"
  common="$(git -C "$PORTABLE_PROJECT" rev-parse --git-common-dir)"
  case "$common" in /*) ;; *) common="$PORTABLE_PROJECT/$common" ;; esac
  common="$(cd "$common" && pwd -P)"
  forged_block=$'# --- Trellis local attachment exclude block ---\n/.trellis/runtime\n/forged-owned-leaf\n# --- end Trellis local attachment exclude block ---'
  forged_after="$(printf '%s\n' "$forged_block")"
  forged_hash="$(printf '%s' "$forged_after" | shasum -a 256 | awk '{print $1}')"
  block_hash="$(printf '%s' "$forged_block" | shasum -a 256 | awk '{print $1}')"
  before_hash="$(printf '' | shasum -a 256 | awk '{print $1}')"
  # GNU base64 wraps at 76 columns while macOS base64 does not, and the owner
  # schema's b64 predicate rejects embedded newlines — without the `tr` this
  # forged owner is thrown out as malformed on Linux before show-config can
  # reach the exclude-block mismatch this test is about.
  forged_block64="$(printf '%s' "$forged_block" | base64 | tr -d '\n')"
  forged_after64="$(printf '%s' "$forged_after" | base64 | tr -d '\n')"
  empty64="$(printf '' | base64 | tr -d '\n')"
  printf '%s' "$forged_after" > "$common/info/exclude"
  jq --arg hash "$forged_hash" --arg block_hash "$block_hash" \
    --arg block64 "$forged_block64" --arg after64 "$forged_after64" \
    --arg before_hash "$before_hash" --arg empty64 "$empty64" '
    .exclude.after_sha256 = $hash
    | .exclude.after_base64 = $after64
    | .exclude.managed_block_sha256 = $block_hash
    | .exclude.managed_block_base64 = $block64
    | .exclude.before_sha256 = $before_hash
    | .exclude.before_base64 = $empty64
    | .exclude.after_exists = true
    | .exclude.managed_by_attachment = true
    | .exclude_block_hash = $block_hash
  ' "$owner" > "$owner.next"
  mv "$owner.next" "$owner"
  chmod 600 "$owner"

  run_portable_show_config

  [ "$status" -ne 0 ]
  [[ "$output" == *"managed excludes: owner block does not match the exact immutable native surface plan"* ]] || { echo "$output"; false; }
  [[ "$output" != *"valid strict local attachment"* ]] || { echo "$output"; false; }
}

@test "portable show-config accepts an attachment that deferred a project-authored primer INDEX" {
  local owner
  build_portable_doctor_home
  mkdir -p "$PORTABLE_PROJECT/.claude/primers"
  printf '# authored index\n' > "$PORTABLE_PROJECT/.claude/primers/INDEX.md"
  git -C "$PORTABLE_PROJECT" add .claude/primers/INDEX.md
  git -C "$PORTABLE_PROJECT" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm primers
  prepare_portable_attachment
  owner="$PORTABLE_HOME/state/attachments/$PORTABLE_CHECKOUT_ID/$PORTABLE_WORKTREE_ID.json"
  jq -e '[.pre_existing[].path] == [".claude/primers/INDEX.md"]' "$owner" >/dev/null ||
    { jq -c '.pre_existing' "$owner"; false; }

  run_portable_show_config

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"attachment:            valid strict local attachment"* ]] || { echo "$output"; false; }
  [ "$(cat "$PORTABLE_PROJECT/.claude/primers/INDEX.md")" = '# authored index' ]
  [ -z "$(git -C "$PORTABLE_PROJECT" status --porcelain)" ]
}

@test "portable show-config rejects a project-owned deferral the checkout no longer justifies" {
  build_portable_doctor_home
  mkdir -p "$PORTABLE_PROJECT/.claude/primers"
  printf '# authored index\n' > "$PORTABLE_PROJECT/.claude/primers/INDEX.md"
  git -C "$PORTABLE_PROJECT" add .claude/primers/INDEX.md
  git -C "$PORTABLE_PROJECT" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm primers
  prepare_portable_attachment
  # The deferred INDEX is in neither the artifact list nor the managed exclude
  # block, so removing it is invisible to every other check: only re-deriving
  # the deferral against the checkout can catch it.
  rm "$PORTABLE_PROJECT/.claude/primers/INDEX.md"

  run_portable_show_config

  [ "$status" -ne 0 ]
  [[ "$output" == *"native surfaces: a leaf recorded as project-owned no longer matches the immutable manifest or the checkout"* ]] ||
    { echo "$output"; false; }
  [[ "$output" != *"valid strict local attachment"* ]] || { echo "$output"; false; }
}

@test "portable show-config accepts an attachment that deferred a project-authored AGENTS.md" {
  local owner
  build_portable_doctor_home
  printf '# AGENTS\n\nProject-authored codex directives.\n' > "$PORTABLE_PROJECT/AGENTS.md"
  git -C "$PORTABLE_PROJECT" add AGENTS.md
  git -C "$PORTABLE_PROJECT" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm agents
  prepare_portable_attachment
  owner="$PORTABLE_HOME/state/attachments/$PORTABLE_CHECKOUT_ID/$PORTABLE_WORKTREE_ID.json"
  jq -e '[.pre_existing[] | select(.path == "AGENTS.md") | .reason] == ["project-authored-file"]' "$owner" >/dev/null ||
    { jq -c '.pre_existing' "$owner"; false; }

  run_portable_show_config

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"attachment:            valid strict local attachment"* ]] || { echo "$output"; false; }
  [ -f "$PORTABLE_PROJECT/AGENTS.md" ] && [ ! -L "$PORTABLE_PROJECT/AGENTS.md" ]
  [ -z "$(git -C "$PORTABLE_PROJECT" status --porcelain)" ]
}

# The authored-file deferral is re-derived per RECORDED REASON, so deleting the
# file that justified it is caught even though the leaf appears in neither the
# artifact list nor the managed exclude block.
@test "portable show-config rejects an authored-file deferral whose file the checkout no longer holds" {
  build_portable_doctor_home
  printf '# AGENTS\n\nProject-authored codex directives.\n' > "$PORTABLE_PROJECT/AGENTS.md"
  git -C "$PORTABLE_PROJECT" add AGENTS.md
  git -C "$PORTABLE_PROJECT" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm agents
  prepare_portable_attachment
  rm "$PORTABLE_PROJECT/AGENTS.md"

  run_portable_show_config

  [ "$status" -ne 0 ]
  [[ "$output" == *"native surfaces: a leaf recorded as project-owned no longer matches the immutable manifest or the checkout"* ]] ||
    { echo "$output"; false; }
  [[ "$output" != *"valid strict local attachment"* ]] || { echo "$output"; false; }
}

# Replacing the authored file with the exact managed symlink changes the leaf's
# SHAPE under a live attachment: the checkout now derives `pre-existing-symlink`
# while the owner still claims `project-authored-file`.  Doctor reports the
# drift rather than silently re-labelling it.
@test "portable show-config rejects an authored-file deferral replaced by the managed symlink" {
  build_portable_doctor_home
  printf '# AGENTS\n\nProject-authored codex directives.\n' > "$PORTABLE_PROJECT/AGENTS.md"
  git -C "$PORTABLE_PROJECT" add AGENTS.md
  git -C "$PORTABLE_PROJECT" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm agents
  prepare_portable_attachment
  rm "$PORTABLE_PROJECT/AGENTS.md"
  ln -s .trellis/runtime/core-rules/CLAUDE.md "$PORTABLE_PROJECT/AGENTS.md"

  run_portable_show_config

  [ "$status" -ne 0 ]
  [[ "$output" == *"native surfaces: a leaf recorded as project-owned no longer matches the immutable manifest or the checkout"* ]] ||
    { echo "$output"; false; }
  [[ "$output" != *"valid strict local attachment"* ]] || { echo "$output"; false; }
}

@test "portable show-config keeps safe sections while a selected preset is missing" {
  build_portable_doctor_home
  prepare_portable_attachment
  jq '.presets = ["missing-preset"]' "$PORTABLE_PROJECT/.trellis.json" \
    > "$PORTABLE_PROJECT/.trellis.json.next"
  mv "$PORTABLE_PROJECT/.trellis.json.next" "$PORTABLE_PROJECT/.trellis.json"

  run_portable_show_config

  [ "$status" -ne 0 ]
  [[ "$output" == *"machine config:        $PORTABLE_HOME/config.json (validated local state)"* ]] || { echo "$output"; false; }
  [[ "$output" == *"valid strict local attachment"* ]] || { echo "$output"; false; }
  [[ "$output" == *"resolution:            unavailable (active preset missing-preset is missing from the verified immutable payload)"* ]] || { echo "$output"; false; }
}

@test "portable show-config rejects a malformed preset in the selected immutable payload" {
  PORTABLE_STRICT_PRESET_CONTENT=$'---\nautonomy_default: 9\nautonomy_ceiling: 2\n---\nFixture preset'
  build_portable_doctor_home
  prepare_portable_attachment
  jq '.presets = ["strict"]' "$PORTABLE_PROJECT/.trellis.json" > "$PORTABLE_PROJECT/.trellis.json.next"
  mv "$PORTABLE_PROJECT/.trellis.json.next" "$PORTABLE_PROJECT/.trellis.json"

  run_portable_show_config

  [ "$status" -ne 0 ]
  [[ "$output" == *"valid strict local attachment"* ]] || { echo "$output"; false; }
  [[ "$output" == *"resolution:            unavailable (active preset strict has an invalid autonomy_default in the verified immutable payload)"* ]] || { echo "$output"; false; }
}

@test "portable show-config ignores a poisoned sibling autonomy resolver" {
  local snapshot
  build_portable_doctor_home
  prepare_portable_attachment
  jq '.presets = ["strict"]' "$PORTABLE_PROJECT/.trellis.json" > "$PORTABLE_PROJECT/.trellis.json.next"
  mv "$PORTABLE_PROJECT/.trellis.json.next" "$PORTABLE_PROJECT/.trellis.json"
  # The resolver has to be planted next to the copy that actually runs, which
  # is now always the attested snapshot: autonomy must come from the owner's
  # verified attachment payload, never from $SCRIPT_DIR/../core-rules. Planting
  # it in an unattested tree would only prove the entry gate refuses, which is
  # a different test.
  snapshot="$(portable_show_config_snapshot)"
  mkdir -p "$snapshot/core-rules/hooks/lib"
  cat > "$snapshot/core-rules/hooks/lib/autonomy.sh" <<'EOF'
echo 'MUTABLE_RESOLVER_WAS_USED' >&2
return 97
EOF

  run_portable_show_config

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"policy source:         verified immutable attachment payload $PORTABLE_RELEASE_PAYLOAD"* ]] || { echo "$output"; false; }
  [[ "$output" == *"strict: default=L4 ceiling=L2"* ]] || { echo "$output"; false; }
  [[ "$output" != *"MUTABLE_RESOLVER_WAS_USED"* ]] || { echo "$output"; false; }
}
