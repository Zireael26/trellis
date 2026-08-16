#!/usr/bin/env bats
# Focused T24 two-machine portability contracts (plan section 6, criterion SC7).
#
# The oracle is deliberately the same Git commit attached twice: once under
# machine A's home, arbitrary space-bearing root, and fleet `personal`; once
# under machine B's separate home, a different arbitrary space-bearing root on
# a different parent, and fleet `work`. Tracked bytes must be indistinguishable
# afterwards, and every machine-specific absolute path must live only in local
# state.
#
# Fixtures are file-local on purpose: this suite owns no shared helper.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
RELEASE_STORE_LIB="$REPO_ROOT/scripts/lib/release-store.sh"
ATTACH="$REPO_ROOT/scripts/attach-project.sh"
REGISTRY="$REPO_ROOT/scripts/registry.sh"

MMP_VERSION=1.2.3

mmp_canonical_dir() {
  (CDPATH= cd "$1" && pwd -P)
}

mmp_mode() {
  case "$(uname -s)" in
    Darwin) stat -f '%Lp' "$1" ;;
    *) stat -c '%a' "$1" ;;
  esac
}

# Bare `[[ ]]` is vacuous when it is not the final command of a Bats test on
# this host, so every glob assertion in this file is guarded.
mmp_contains() {
  case "$2" in
    *"$1"*) return 0 ;;
  esac
  printf 'expected to contain %s:\n%s\n' "$1" "$2" >&2
  return 1
}

mmp_missing() {
  case "$2" in
    *"$1"*)
      printf 'expected NOT to contain %s:\n%s\n' "$1" "$2" >&2
      return 1
      ;;
  esac
  return 0
}

mmp_git() {
  env GIT_CONFIG_NOSYSTEM=1 HOME="$SANDBOX/git-neutral home" git "$@"
}

# The exact tracked state of a checkout: index entries (mode, blob OID, stage,
# path) plus the tree the index writes. Two machines agree only if both match.
mmp_tracked_index() {
  mmp_git -C "$1" ls-files -s
}

mmp_tracked_tree() {
  mmp_git -C "$1" write-tree
}

mmp_build_release_source() {
  local repo="$SANDBOX/policy source"
  mkdir -p "$repo/scripts" "$repo/core-rules/githooks"
  cp "$REPO_ROOT/scripts/attach-project.sh" "$repo/scripts/attach-project.sh"
  cp "$REPO_ROOT/scripts/seed-inheritance-symlinks.sh" "$repo/scripts/seed-inheritance-symlinks.sh"
  cp -R "$REPO_ROOT/scripts/lib" "$repo/scripts/lib"
  chmod 755 "$repo/scripts/attach-project.sh" "$repo/scripts/seed-inheritance-symlinks.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/core-rules/githooks/pre-push"
  chmod 755 "$repo/core-rules/githooks/pre-push"
  printf '# portable fixture policy %s\n' "$MMP_VERSION" > "$repo/core-rules/CLAUDE.md"
  printf '%s\n' "$MMP_VERSION" > "$repo/core-rules/VERSION"
  cat > "$repo/core-rules/inheritance-manifest.json" <<'JSON'
{
  "schema_version": 1,
  "harnesses": {
    "claude": {
      "links": [{"source": "core-rules/CLAUDE.md", "destination": ".claude/rules/trellis.md"}],
      "render": []
    },
    "codex": {
      "links": [{"source": "core-rules/CLAUDE.md", "destination": ".agents/rules/trellis.md"}],
      "render": []
    },
    "omp": {
      "links": [{"source": "core-rules/CLAUDE.md", "destination": ".omp/AGENTS.md"}],
      "render": []
    }
  }
}
JSON
  mmp_git init -q -b main "$repo"
  mmp_git -C "$repo" config user.email portable@example.invalid
  mmp_git -C "$repo" config user.name 'Portable Fixture'
  mmp_git -C "$repo" config commit.gpgsign false
  mmp_git -C "$repo" config tag.gpgSign false
  mmp_git -C "$repo" add -A
  mmp_git -C "$repo" -c core.hooksPath=/dev/null commit -qm "release $MMP_VERSION"
  mmp_git -C "$repo" tag -a "v$MMP_VERSION" -m "release $MMP_VERSION"
  printf '%s\n' "$repo"
}

mmp_build_project_origin() {
  local origin="$SANDBOX/project origin"
  mkdir -p "$origin"
  mmp_git init -q -b main "$origin"
  mmp_git -C "$origin" config user.email portable@example.invalid
  mmp_git -C "$origin" config user.name 'Portable Fixture'
  mmp_git -C "$origin" config commit.gpgsign false
  printf '{"schema_version":1,"project_id":"portable-fixture"}\n' > "$origin/.trellis.json"
  printf 'portable fixture project\n' > "$origin/README.md"
  printf 'node_modules/\n' > "$origin/.gitignore"
  mmp_git -C "$origin" add .trellis.json README.md .gitignore
  mmp_git -C "$origin" -c core.hooksPath=/dev/null commit -qm 'portable manifest'
  printf '%s\n' "$origin"
}

# One machine: a private operator HOME, its own TRELLIS_HOME, and its own copy
# of the release store installed from the shared annotated tag.
mmp_prepare_machine() {
  local operator_home="$1"
  mkdir -p "$operator_home/.trellis"
  chmod 700 "$operator_home" "$operator_home/.trellis"
  run env HOME="$operator_home" TRELLIS_HOME="$operator_home/.trellis" \
    GIT_CONFIG_NOSYSTEM=1 bash -c '. "$1"; release_store_install "$2" "$3" "" >/dev/null' \
    multi-machine-portability "$RELEASE_STORE_LIB" "$MMP_VERSION" "$RELEASE_SOURCE"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

mmp_attach() {
  local operator_home="$1" fleet="$2" root="$3"
  run env HOME="$operator_home" TRELLIS_HOME="$operator_home/.trellis" \
    GIT_CONFIG_NOSYSTEM=1 bash "$ATTACH" attach \
    --home "$operator_home/.trellis" --fleet "$fleet" --release "$MMP_VERSION" "$root"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

# Every managed link target as `path -> target`, sorted. Relative targets are
# machine-independent by construction; the one absolute target is the anchor.
mmp_link_map() {
  local root="$1" link
  find "$root" -type l -not -path "$root/.git/*" | LC_ALL=C sort | while read -r link; do
    printf '%s -> %s\n' "${link#$root/}" "$(readlink "$link")"
  done
}

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/multi-machine-portability.XXXXXX")"
  SANDBOX="$(mmp_canonical_dir "$SANDBOX")"
  mkdir -p "$SANDBOX/git-neutral home"

  MACHINE_A_HOME="$SANDBOX/machine A/operator home"
  MACHINE_B_HOME="$SANDBOX/other volume/operator home"
  MACHINE_A_TRELLIS="$MACHINE_A_HOME/.trellis"
  MACHINE_B_TRELLIS="$MACHINE_B_HOME/.trellis"
  # Deliberately different depths, different parents, and spaces on both sides.
  MACHINE_A_ROOT="$SANDBOX/machine A/code with spaces/portable"
  MACHINE_B_ROOT="$SANDBOX/other volume/work checkouts with spaces/nested/portable"

  RELEASE_SOURCE="$(mmp_build_release_source)"
  PROJECT_ORIGIN="$(mmp_build_project_origin)"
}

teardown() {
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    find "$SANDBOX" -type d -exec chmod u+w {} \; 2>/dev/null || true
    rm -rf "$SANDBOX"
  fi
}

# GAP: plan section 6 "Different machines, same tracked bytes" had no executable
# oracle. Existing suites register or rebuild rows on two homes but never ATTACH
# the same commit twice and compare index bytes plus tree IDs.
@test "one commit attached under two homes, roots, and fleets keeps byte-identical tracked state" {
  local index_before_a index_before_b tree_before_a tree_before_b
  local index_after_a index_after_b tree_after_a tree_after_b

  mkdir -p "$SANDBOX/machine A/code with spaces" \
    "$SANDBOX/other volume/work checkouts with spaces/nested"
  mmp_git clone -q "$PROJECT_ORIGIN" "$MACHINE_A_ROOT"
  mmp_git clone -q "$PROJECT_ORIGIN" "$MACHINE_B_ROOT"
  MACHINE_A_ROOT="$(mmp_canonical_dir "$MACHINE_A_ROOT")"
  MACHINE_B_ROOT="$(mmp_canonical_dir "$MACHINE_B_ROOT")"

  index_before_a="$(mmp_tracked_index "$MACHINE_A_ROOT")"
  index_before_b="$(mmp_tracked_index "$MACHINE_B_ROOT")"
  tree_before_a="$(mmp_tracked_tree "$MACHINE_A_ROOT")"
  tree_before_b="$(mmp_tracked_tree "$MACHINE_B_ROOT")"
  [ "$index_before_a" = "$index_before_b" ]
  [ "$tree_before_a" = "$tree_before_b" ]

  mmp_prepare_machine "$MACHINE_A_HOME"
  mmp_prepare_machine "$MACHINE_B_HOME"
  mmp_attach "$MACHINE_A_HOME" personal "$MACHINE_A_ROOT"
  mmp_attach "$MACHINE_B_HOME" work "$MACHINE_B_ROOT"

  # Both checkouts really are attached, so the comparison below is not vacuous.
  [ -L "$MACHINE_A_ROOT/.trellis/runtime" ]
  [ -L "$MACHINE_B_ROOT/.trellis/runtime" ]
  [ -L "$MACHINE_A_ROOT/.claude/rules/trellis.md" ]
  [ -L "$MACHINE_B_ROOT/.claude/rules/trellis.md" ]

  index_after_a="$(mmp_tracked_index "$MACHINE_A_ROOT")"
  index_after_b="$(mmp_tracked_index "$MACHINE_B_ROOT")"
  tree_after_a="$(mmp_tracked_tree "$MACHINE_A_ROOT")"
  tree_after_b="$(mmp_tracked_tree "$MACHINE_B_ROOT")"

  # Machine A equals machine B ...
  [ "$index_after_a" = "$index_after_b" ]
  [ "$tree_after_a" = "$tree_after_b" ]
  # ... and neither moved from the shared pre-attach oracle.
  [ "$index_after_a" = "$index_before_a" ]
  [ "$index_after_b" = "$index_before_b" ]
  [ "$tree_after_a" = "$tree_before_a" ]
  [ "$tree_after_b" = "$tree_before_b" ]
  [ "$(mmp_git -C "$MACHINE_A_ROOT" rev-parse 'HEAD^{tree}')" = "$tree_after_a" ]
  [ "$(mmp_git -C "$MACHINE_B_ROOT" rev-parse 'HEAD^{tree}')" = "$tree_after_b" ]

  # Attachment leaves no working-tree diff and nothing untracked on either side.
  [ -z "$(mmp_git -C "$MACHINE_A_ROOT" status --porcelain)" ]
  [ -z "$(mmp_git -C "$MACHINE_B_ROOT" status --porcelain)" ]
  [ -z "$(mmp_git -C "$MACHINE_A_ROOT" diff HEAD --name-only)" ]
  [ -z "$(mmp_git -C "$MACHINE_B_ROOT" diff HEAD --name-only)" ]
}

# GAP: no suite proved that the ONLY machine-dependent value a portable
# attachment writes is the local runtime anchor, or that neither machine's
# absolute paths reach tracked bytes.
@test "only the local runtime anchor differs between machines and no machine path reaches tracked bytes" {
  local links_a links_b anchor_a anchor_b tracked_bytes tracked_file

  mkdir -p "$SANDBOX/machine A/code with spaces" \
    "$SANDBOX/other volume/work checkouts with spaces/nested"
  mmp_git clone -q "$PROJECT_ORIGIN" "$MACHINE_A_ROOT"
  mmp_git clone -q "$PROJECT_ORIGIN" "$MACHINE_B_ROOT"
  MACHINE_A_ROOT="$(mmp_canonical_dir "$MACHINE_A_ROOT")"
  MACHINE_B_ROOT="$(mmp_canonical_dir "$MACHINE_B_ROOT")"

  mmp_prepare_machine "$MACHINE_A_HOME"
  mmp_prepare_machine "$MACHINE_B_HOME"
  mmp_attach "$MACHINE_A_HOME" personal "$MACHINE_A_ROOT"
  mmp_attach "$MACHINE_B_HOME" work "$MACHINE_B_ROOT"

  anchor_a="$(readlink "$MACHINE_A_ROOT/.trellis/runtime")"
  anchor_b="$(readlink "$MACHINE_B_ROOT/.trellis/runtime")"
  [ "$anchor_a" = "$MACHINE_A_TRELLIS/releases/$MMP_VERSION/payload" ]
  [ "$anchor_b" = "$MACHINE_B_TRELLIS/releases/$MMP_VERSION/payload" ]
  [ "$anchor_a" != "$anchor_b" ]

  # Every harness leaf is relative to that one anchor, so the link map is
  # identical once the anchor line is removed.
  links_a="$(mmp_link_map "$MACHINE_A_ROOT" | grep -v '^\.trellis/runtime ->')"
  links_b="$(mmp_link_map "$MACHINE_B_ROOT" | grep -v '^\.trellis/runtime ->')"
  [ -n "$links_a" ]
  [ "$links_a" = "$links_b" ]
  mmp_contains '.claude/rules/trellis.md -> ../../.trellis/runtime/core-rules/CLAUDE.md' "$links_a"

  # Both machines resolve the same policy content through their own store.
  [ "$(cat "$MACHINE_A_ROOT/.claude/rules/trellis.md")" = \
    "$(cat "$MACHINE_B_ROOT/.claude/rules/trellis.md")" ]

  # No tracked blob on either side names either machine's home or root.
  for tracked_file in $(mmp_git -C "$MACHINE_A_ROOT" ls-files); do
    tracked_bytes="$(cat "$MACHINE_A_ROOT/$tracked_file")"
    mmp_missing "$SANDBOX/machine A" "$tracked_bytes"
    mmp_missing "$SANDBOX/other volume" "$tracked_bytes"
  done
  for tracked_file in $(mmp_git -C "$MACHINE_B_ROOT" ls-files); do
    tracked_bytes="$(cat "$MACHINE_B_ROOT/$tracked_file")"
    mmp_missing "$SANDBOX/machine A" "$tracked_bytes"
    mmp_missing "$SANDBOX/other volume" "$tracked_bytes"
  done

  # Machine inventory stays private and single-machine.
  [ "$(mmp_mode "$MACHINE_A_TRELLIS/registry.json")" = 600 ]
  [ "$(mmp_mode "$MACHINE_B_TRELLIS/registry.json")" = 600 ]
  mmp_missing "$MACHINE_B_ROOT" "$(cat "$MACHINE_A_TRELLIS/registry.json")"
  mmp_missing "$MACHINE_A_ROOT" "$(cat "$MACHINE_B_TRELLIS/registry.json")"

  run env HOME="$MACHINE_A_HOME" TRELLIS_HOME="$MACHINE_A_TRELLIS" \
    bash "$REGISTRY" list --home "$MACHINE_A_TRELLIS" --json
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [ "$(printf '%s\n' "$output" | jq -r '.entries[0].project_key')" = personal/portable-fixture ]
  [ "$(printf '%s\n' "$output" | jq -r '.entries[0].root')" = "$MACHINE_A_ROOT" ]

  run env HOME="$MACHINE_B_HOME" TRELLIS_HOME="$MACHINE_B_TRELLIS" \
    bash "$REGISTRY" list --home "$MACHINE_B_TRELLIS" --json
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [ "$(printf '%s\n' "$output" | jq -r '.entries[0].project_key')" = work/portable-fixture ]
  [ "$(printf '%s\n' "$output" | jq -r '.entries[0].root')" = "$MACHINE_B_ROOT" ]
}
