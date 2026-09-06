#!/usr/bin/env bats
# Focused T24 portable home, registry, and immutable-release integration contracts.
# Every fixture is a local Git repository under a temporary operator home.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
CONFIGURE="$REPO_ROOT/scripts/configure.sh"
REGISTRY="$REPO_ROOT/scripts/registry.sh"
REGISTRY_LIB="$REPO_ROOT/scripts/lib/local-registry.sh"
RELEASE="$REPO_ROOT/scripts/release.sh"
ATTACH="$REPO_ROOT/scripts/attach-project.sh"
TRELLIS="$REPO_ROOT/scripts/trellis"
load helpers/release-fixture

canonical_dir() {
  (CDPATH= cd "$1" && pwd -P)
}

file_mode() {
  case "$(uname -s)" in
    Darwin) stat -f '%Lp' "$1" ;;
    *) stat -c '%a' "$1" ;;
  esac
}

sha256_file() {
  shasum -a 256 "$1" | cut -d ' ' -f 1
}

release_payload() {
  printf '%s/releases/%s/payload\n' "$1" "$2"
}

make_release_source() {
  local version="$1"
  mkdir -p "$RELEASE_SOURCE/core-rules/githooks" "$RELEASE_SOURCE/core-rules/hooks/lib" \
    "$RELEASE_SOURCE/core-rules/pi/extensions" "$RELEASE_SOURCE/scripts"
  # attach reconciles managed Git hooks out of the RELEASE payload, so a usable
  # fixture release must carry the pre-push carrier and the reconcile entry
  # point — the same minimal payload detach-project.bats seals.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$RELEASE_SOURCE/core-rules/githooks/pre-push"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$RELEASE_SOURCE/scripts/seed-inheritance-symlinks.sh"
  chmod 755 "$RELEASE_SOURCE/core-rules/githooks/pre-push" \
    "$RELEASE_SOURCE/scripts/seed-inheritance-symlinks.sh"
  printf '%s\n' "$version" > "$RELEASE_SOURCE/core-rules/VERSION"
  printf '# portable fixture policy %s\n' "$version" > "$RELEASE_SOURCE/core-rules/CLAUDE.md"
  # Payload stand-ins for the two harness-owned (non-shared) leaves below.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$RELEASE_SOURCE/core-rules/hooks/lib/action-normalize.sh"
  chmod 755 "$RELEASE_SOURCE/core-rules/hooks/lib/action-normalize.sh"
  printf 'export const trellis = {};\n' > "$RELEASE_SOURCE/core-rules/pi/extensions/trellis.ts"
  # Schema 2 is the only shape scripts/lib/surface-plan.sh accepts for the
  # current harness set: the key set must be exactly claude+codex+pi+
  # shared_agents, optionally plus user.  `user` is omitted because it is
  # planned only by the separate `--user` mode, which this suite never
  # exercises, and the validator demands it only when that harness is selected.
  #
  # OMP is retired.  The old `omp` entry's structural role — a second,
  # non-Claude harness destination — belongs to `shared_agents`, which is where
  # production owns .agents/rules/trellis.md and which codex and pi both
  # consume.  Every entry below is copied verbatim from the production
  # core-rules/inheritance-manifest.json; only the sources are stubbed above.
  # The `pi` entry gives Pi a distinct, non-shared destination in the plan
  # shape.  It is fixture structure only: nothing in this suite is evidence
  # that a native Pi runtime consumes it.
  cat > "$RELEASE_SOURCE/core-rules/inheritance-manifest.json" <<'JSON'
{
  "schema_version": 2,
  "harnesses": {
    "claude": {
      "links": [
        {"source": "core-rules/CLAUDE.md", "destination": ".claude/rules/trellis.md"}
      ],
      "render": []
    },
    "shared_agents": {
      "links": [
        {"source": "core-rules/CLAUDE.md", "destination": ".agents/rules/trellis.md"}
      ],
      "render": []
    },
    "codex": {
      "links": [
        {"source": "core-rules/hooks/lib/action-normalize.sh", "destination": ".codex/hooks/lib/action-normalize.sh", "executable": true}
      ],
      "render": []
    },
    "pi": {
      "links": [
        {"source": "core-rules/pi/extensions/trellis.ts", "destination": ".pi/extensions/trellis.ts"}
      ],
      "render": []
    }
  }
}
JSON
  printf '{}\n' > "$RELEASE_SOURCE/trellis.config.json"
  git -C "$RELEASE_SOURCE" init -q -b main
  git -C "$RELEASE_SOURCE" config user.email portable-fixture@example.invalid
  git -C "$RELEASE_SOURCE" config user.name 'Portable Fixture'
  git -C "$RELEASE_SOURCE" add -A
  git -C "$RELEASE_SOURCE" commit -q -m "release $version"
  git -C "$RELEASE_SOURCE" tag -a "v$version" -m "release $version"
}

publish_release() {
  local version="$1"
  printf '%s\n' "$version" > "$RELEASE_SOURCE/core-rules/VERSION"
  printf '# portable fixture policy %s\n' "$version" > "$RELEASE_SOURCE/core-rules/CLAUDE.md"
  git -C "$RELEASE_SOURCE" add core-rules/VERSION core-rules/CLAUDE.md
  git -C "$RELEASE_SOURCE" commit -q -m "release $version"
  git -C "$RELEASE_SOURCE" tag -a "v$version" -m "release $version"
}

make_project() {
  local root="$1" project_id="$2"
  mkdir -p "$root"
  git init -q -b main "$root"
  git -C "$root" config user.email portable-project@example.invalid
  git -C "$root" config user.name 'Portable Project'
  printf '{"schema_version":1,"project_id":"%s"}\n' "$project_id" > "$root/.trellis.json"
  printf 'portable fixture\n' > "$root/README"
  git -C "$root" add .trellis.json README
  git -C "$root" commit -q -m fixture
}

# scripts/release.sh refuses pathname execution from a source checkout, so every
# release command in this suite goes through the installed stable launcher that
# release-fixture.bash bootstraps (the same seam release-store.bats and
# detach-project.bats use). ensure_launcher is idempotent per machine home and
# is called lazily so the homes that never install a release stay untouched.
ensure_launcher() {
  local home="$1"
  case " ${BOOTSTRAPPED_HOMES:-} " in
    *" $home "*) return 0 ;;
  esac
  release_fixture_bootstrap "$OPERATOR_HOME" "$home" "$SANDBOX"
  BOOTSTRAPPED_HOMES="${BOOTSTRAPPED_HOMES:-}${BOOTSTRAPPED_HOMES:+ }$home"
}

run_release() {
  local home="$1"
  shift
  ensure_launcher "$home"
  run env HOME="$OPERATOR_HOME" TRELLIS_HOME="$home" GIT_CONFIG_NOSYSTEM=1 \
    "$RELEASE_FIXTURE_LAUNCHER" release "$@"
}

install_release() {
  local home="$1" version="$2"
  run_release "$home" install "$version" --remote "$RELEASE_SOURCE"
}

register_worktree() {
  local home="$1" fleet="$2" project_id="$3" root="$4"
  run env HOME="$OPERATOR_HOME" TRELLIS_HOME="$home" bash -c '
    . "$1"
    local_registry_register_worktree "$2" "$3" "$4" "$5" "" "[]" "" "{}"
  ' portable-home-registry-release "$REGISTRY_LIB" "$home" "$fleet" "$project_id" "$root"
}

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/portable-home-registry-release.XXXXXX")"
  SANDBOX="$(canonical_dir "$SANDBOX")"
  OPERATOR_HOME="$SANDBOX/operator home"
  MACHINE_A_HOME="$SANDBOX/machine A/.trellis"
  MACHINE_B_HOME="$SANDBOX/machine B/.trellis"
  MACHINE_A_ROOT="$SANDBOX/machine A/projects with spaces"
  MACHINE_B_ROOT="$SANDBOX/machine B/projects with spaces"
  RELEASE_SOURCE="$SANDBOX/policy source"

  mkdir -p "$OPERATOR_HOME/.trellis" "$MACHINE_A_HOME" "$MACHINE_B_HOME" \
    "$MACHINE_A_ROOT" "$MACHINE_B_ROOT"
  printf 'operator sentinel\n' > "$OPERATOR_HOME/.trellis/registry.json"
  make_release_source 1.2.3
}

teardown() {
  chmod -R u+w "$SANDBOX" 2>/dev/null || true
  rm -rf "$SANDBOX"
}

@test "private machine homes and configuration remain under the explicitly selected home" {
  run env HOME="$OPERATOR_HOME" TRELLIS_HOME="$MACHINE_B_HOME" bash "$CONFIGURE" \
    --source "$RELEASE_SOURCE" \
    --home "$MACHINE_A_HOME" \
    --default-fleet personal \
    --discovery-root "$MACHINE_A_ROOT" \
    --no-install-launcher
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  [ "$(file_mode "$MACHINE_A_HOME")" = 700 ]
  [ "$(file_mode "$MACHINE_A_HOME/locks")" = 700 ]
  [ "$(file_mode "$MACHINE_A_HOME/state")" = 700 ]
  [ "$(file_mode "$MACHINE_A_HOME/releases")" = 700 ]
  [ "$(file_mode "$MACHINE_A_HOME/config.json")" = 600 ]
  [ ! -e "$MACHINE_B_HOME/config.json" ]
  [ "$(cat "$OPERATOR_HOME/.trellis/registry.json")" = 'operator sentinel' ]
  jq -e --arg source "$RELEASE_SOURCE" --arg root "$MACHINE_A_ROOT" '
    .source_root == $source
    and .default_fleet == "personal"
    and .fleets.personal.discovery_roots == [$root]
  ' "$MACHINE_A_HOME/config.json" >/dev/null
}

@test "two machine homes isolate personal and work clones at arbitrary roots with identical tracked bytes" {
  local seed personal work personal_state work_state
  seed="$SANDBOX/portable seed"
  personal="$MACHINE_A_ROOT/personal clone with spaces"
  work="$MACHINE_B_ROOT/work clone with spaces"
  make_project "$seed" portable-fixture
  git clone -q "$seed" "$personal"
  git clone -q "$seed" "$work"

  run env HOME="$OPERATOR_HOME" TRELLIS_HOME="$MACHINE_A_HOME" bash "$REGISTRY" \
    rebuild --home "$MACHINE_A_HOME" --fleet personal --apply "$MACHINE_A_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run env HOME="$OPERATOR_HOME" TRELLIS_HOME="$MACHINE_B_HOME" bash "$REGISTRY" \
    rebuild --home "$MACHINE_B_HOME" --fleet work --apply "$MACHINE_B_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  [ "$(git -C "$personal" rev-parse HEAD)" = "$(git -C "$work" rev-parse HEAD)" ]
  [ "$(git -C "$personal" ls-files -s)" = "$(git -C "$work" ls-files -s)" ]
  [ "$(git -C "$personal" write-tree)" = "$(git -C "$work" write-tree)" ]
  [ "$(file_mode "$MACHINE_A_HOME/registry.json")" = 600 ]
  [ "$(file_mode "$MACHINE_B_HOME/registry.json")" = 600 ]

  run env HOME="$OPERATOR_HOME" TRELLIS_HOME="$MACHINE_A_HOME" bash "$REGISTRY" \
    list --home "$MACHINE_A_HOME" --fleet personal --json
  [ "$status" -eq 0 ]
  personal_state="$output"
  [ "$(printf '%s\n' "$personal_state" | jq '.entries | length')" -eq 1 ]
  [ "$(printf '%s\n' "$personal_state" | jq -r '.entries[0].root')" = "$personal" ]
  [ "$(printf '%s\n' "$personal_state" | jq -r '.entries[0].project_key')" = personal/portable-fixture ]
  printf '%s\n' "$personal_state" | jq -e '
    .entries[0].checkout_id | test("^[0-9a-f]{64}$")
  ' >/dev/null
  [[ "$personal_state" != *"$work"* ]] || { echo "$personal_state"; false; }

  run env HOME="$OPERATOR_HOME" TRELLIS_HOME="$MACHINE_B_HOME" bash "$REGISTRY" \
    list --home "$MACHINE_B_HOME" --fleet work --json
  [ "$status" -eq 0 ]
  work_state="$output"
  [ "$(printf '%s\n' "$work_state" | jq '.entries | length')" -eq 1 ]
  [ "$(printf '%s\n' "$work_state" | jq -r '.entries[0].root')" = "$work" ]
  [ "$(printf '%s\n' "$work_state" | jq -r '.entries[0].project_key')" = work/portable-fixture ]
  printf '%s\n' "$work_state" | jq -e '
    .entries[0].worktree_id | test("^[0-9a-f]{64}$")
  ' >/dev/null
  [[ "$work_state" != *"$personal"* ]] || { echo "$work_state"; false; }
}

@test "annotated release trees survive source poisoning and fail closed when installed bytes drift" {
  local release_dir payload runtime_project runtime_anchor payload_hash record_hash expected_oid moved_source
  [ "$(git -C "$RELEASE_SOURCE" cat-file -t v1.2.3)" = tag ]

  install_release "$MACHINE_A_HOME" 1.2.3
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  release_dir="$MACHINE_A_HOME/releases/1.2.3"
  payload="$(release_payload "$MACHINE_A_HOME" 1.2.3)"
  [ "$output" = "$release_dir" ]
  [ -f "$release_dir/release.json" ]
  [ -d "$payload/core-rules" ]
  expected_oid="$(git -C "$RELEASE_SOURCE" rev-parse 'v1.2.3:core-rules/CLAUDE.md')"
  [ "$(jq -r '.tree[] | select(.path == "core-rules/CLAUDE.md") | .oid' "$release_dir/release.json")" = "$expected_oid" ]

  runtime_project="$SANDBOX/runtime project"
  runtime_anchor="$runtime_project/.trellis/runtime"
  mkdir -p "$runtime_project/.trellis"
  run_release "$MACHINE_A_HOME" adopt 1.2.3 --runtime-anchor "$runtime_anchor"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(readlink "$runtime_anchor")" = "$payload" ]

  payload_hash="$(sha256_file "$payload/core-rules/CLAUDE.md")"
  record_hash="$(sha256_file "$release_dir/release.json")"
  git -C "$RELEASE_SOURCE" checkout -q -b poisoned-source
  printf '# poisoned mutable source\n' > "$RELEASE_SOURCE/core-rules/CLAUDE.md"
  moved_source="$SANDBOX/moved poisoned source"
  mv "$RELEASE_SOURCE" "$moved_source"

  run_release "$MACHINE_A_HOME" verify 1.2.3
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(readlink "$runtime_anchor")" = "$payload" ]
  [ "$(sha256_file "$payload/core-rules/CLAUDE.md")" = "$payload_hash" ]
  [ "$(sha256_file "$release_dir/release.json")" = "$record_hash" ]

  chmod u+w "$payload/core-rules/CLAUDE.md"
  printf '# tampered installed payload\n' > "$payload/core-rules/CLAUDE.md"
  chmod a-w "$payload/core-rules/CLAUDE.md"
  run_release "$MACHINE_A_HOME" verify 1.2.3
  [ "$status" -eq 4 ]
  [[ "$output" == *'changed release content: core-rules/CLAUDE.md'* ]] || { echo "$output"; false; }
}

# W5 integration contract: the stable dispatcher must resolve a registered
# project selector. Current T4-only release.sh intentionally rejects --project;
# this assertion is deliberately not skipped so the missing selector API fails.
@test "registry-selected release adoption changes no runtime without an explicit adoption request" {
  local project release_a release_b tracked_before
  project="$MACHINE_A_ROOT/adoption project"
  make_project "$project" portable-adoption

  install_release "$MACHINE_A_HOME" 1.2.3
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  release_a="$(release_payload "$MACHINE_A_HOME" 1.2.3)"
  run env HOME="$OPERATOR_HOME" TRELLIS_HOME="$MACHINE_A_HOME" bash "$ATTACH" \
    attach --home "$MACHINE_A_HOME" --fleet personal --release 1.2.3 "$project"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  tracked_before="$(git -C "$project" ls-files -s)"
  [ "$(readlink "$project/.trellis/runtime")" = "$release_a" ]

  publish_release 1.2.4
  install_release "$MACHINE_A_HOME" 1.2.4
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  release_b="$(release_payload "$MACHINE_A_HOME" 1.2.4)"
  [ "$(readlink "$project/.trellis/runtime")" = "$release_a" ]

  run_release "$MACHINE_A_HOME" adopt 1.2.4 --project portable-adoption
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$release_b" ]
  [ "$(git -C "$project" ls-files -s)" = "$tracked_before" ]
}

@test "a moved policy worktree relinks the recorded runtime without changing project identity" {
  local project release_payload_path tracked_before owner owner_identity moved_source
  project="$MACHINE_A_ROOT/relink project"
  make_project "$project" portable-relink

  install_release "$MACHINE_A_HOME" 1.2.3
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  release_payload_path="$(release_payload "$MACHINE_A_HOME" 1.2.3)"
  run env HOME="$OPERATOR_HOME" TRELLIS_HOME="$MACHINE_A_HOME" bash "$ATTACH" \
    attach --home "$MACHINE_A_HOME" --fleet personal --release 1.2.3 "$project"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  tracked_before="$(git -C "$project" ls-files -s)"
  owner="$(find "$MACHINE_A_HOME/state/attachments" -type f -name '*.json' -print)"
  [ -f "$owner" ]
  owner_identity="$(jq -cS '{project_id,checkout_id,worktree_id,worktree_root,release}' "$owner")"
  [ "$(readlink "$project/.trellis/runtime")" = "$release_payload_path" ]

  moved_source="$SANDBOX/moved policy worktree"
  mv "$RELEASE_SOURCE" "$moved_source"
  run env HOME="$OPERATOR_HOME" TRELLIS_HOME="$MACHINE_B_HOME" bash "$CONFIGURE" \
    --source "$moved_source" \
    --home "$MACHINE_A_HOME" \
    --default-fleet personal \
    --active-cli-release 1.2.3 \
    --discovery-root "$MACHINE_A_ROOT" \
    --no-install-launcher
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$release_payload_path" ]

  rm "$project/.trellis/runtime"
  run env HOME="$OPERATOR_HOME" TRELLIS_HOME="$MACHINE_A_HOME" \
    bash "$TRELLIS" relink --home "$MACHINE_A_HOME" "$project"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$release_payload_path" ]
  [ "$(git -C "$project" ls-files -s)" = "$tracked_before" ]
  [ "$(jq -cS '{project_id,checkout_id,worktree_id,worktree_root,release}' "$owner")" = "$owner_identity" ]

  rm "$project/.trellis/runtime"
  ln -s "$SANDBOX/wrong immutable payload" "$project/.trellis/runtime"
  run env HOME="$OPERATOR_HOME" TRELLIS_HOME="$MACHINE_A_HOME" \
    bash "$TRELLIS" relink --home "$MACHINE_A_HOME" "$project"
  [ "$status" -eq 4 ]
  [ "$(readlink "$project/.trellis/runtime")" = "$SANDBOX/wrong immutable payload" ]
  [ "$(git -C "$project" ls-files -s)" = "$tracked_before" ]
}

@test "corrupt registry bytes and duplicate project or checkout identities fail closed" {
  local duplicates canonical linked registry_before corrupt_before
  duplicates="$SANDBOX/duplicate projects"
  make_project "$duplicates/one" duplicate-id
  make_project "$duplicates/two" duplicate-id

  run env HOME="$OPERATOR_HOME" TRELLIS_HOME="$MACHINE_A_HOME" bash "$REGISTRY" \
    rebuild --home "$MACHINE_A_HOME" --fleet personal "$duplicates"
  [ "$status" -eq 3 ]
  [[ "$output" == *'rebuild found duplicate project IDs in selected roots'* ]] || { echo "$output"; false; }
  [ ! -e "$MACHINE_A_HOME/registry.json" ]

  canonical="$SANDBOX/canonical checkout"
  linked="$SANDBOX/linked checkout"
  make_project "$canonical" alpha
  git -C "$canonical" worktree add -q -b identity-collision "$linked"
  printf '{"schema_version":1,"project_id":"beta"}\n' > "$linked/.trellis.json"

  register_worktree "$MACHINE_A_HOME" personal alpha "$canonical"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  registry_before="$(sha256_file "$MACHINE_A_HOME/registry.json")"
  register_worktree "$MACHINE_A_HOME" personal beta "$linked"
  [ "$status" -eq 3 ]
  [[ "$output" == *'identity or path collision for personal/beta'* ]] || { echo "$output"; false; }
  [ "$(sha256_file "$MACHINE_A_HOME/registry.json")" = "$registry_before" ]

  printf '{corrupt\n' > "$MACHINE_A_HOME/registry.json"
  chmod 600 "$MACHINE_A_HOME/registry.json"
  corrupt_before="$(sha256_file "$MACHINE_A_HOME/registry.json")"
  run env HOME="$OPERATOR_HOME" TRELLIS_HOME="$MACHINE_A_HOME" bash "$REGISTRY" \
    list --home "$MACHINE_A_HOME" --json
  [ "$status" -eq 4 ]
  [[ "$output" == *'registry failed schema-aware validation'* ]] || { echo "$output"; false; }
  [ "$(sha256_file "$MACHINE_A_HOME/registry.json")" = "$corrupt_before" ]
}

@test "an unavailable volume remains listed and is never reconstructed by selected rebuilds" {
  local offline_parent offline_root offline_record_before offline_record_after available_root listed
  offline_parent="$SANDBOX/unavailable volume"
  offline_root="$offline_parent/project with spaces"
  make_project "$offline_root" offline-project

  run env HOME="$OPERATOR_HOME" TRELLIS_HOME="$MACHINE_A_HOME" bash "$REGISTRY" \
    rebuild --home "$MACHINE_A_HOME" --fleet personal --apply "$offline_parent"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  offline_record_before="$(jq -cS '.projects["personal/offline-project"]' "$MACHINE_A_HOME/registry.json")"
  rm -rf "$offline_parent"
  [ ! -e "$offline_root" ]

  run env HOME="$OPERATOR_HOME" TRELLIS_HOME="$MACHINE_A_HOME" bash "$REGISTRY" \
    list --home "$MACHINE_A_HOME" --fleet personal --json
  [ "$status" -eq 0 ]
  listed="$output"
  [ "$(printf '%s\n' "$listed" | jq --arg root "$offline_root" '[.entries[] | select(.root == $root and .status == "unavailable")] | length')" -eq 1 ]

  available_root="$SANDBOX/selected rebuild root"
  make_project "$available_root/available project" available-project
  run env HOME="$OPERATOR_HOME" TRELLIS_HOME="$MACHINE_A_HOME" bash "$REGISTRY" \
    rebuild --home "$MACHINE_A_HOME" --fleet personal --apply "$available_root"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  offline_record_after="$(jq -cS '.projects["personal/offline-project"]' "$MACHINE_A_HOME/registry.json")"
  [ "$offline_record_after" = "$offline_record_before" ]
  [ ! -e "$offline_parent" ]

  run env HOME="$OPERATOR_HOME" TRELLIS_HOME="$MACHINE_A_HOME" bash "$REGISTRY" \
    list --home "$MACHINE_A_HOME" --fleet personal --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq --arg root "$offline_root" '[.entries[] | select(.root == $root and .status == "unavailable")] | length')" -eq 1 ]
}
