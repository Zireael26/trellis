#!/usr/bin/env bats
# Focused T5 machine-local registry contracts. Every case uses a temporary home.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
REGISTRY="$REPO_ROOT/scripts/registry.sh"
REGISTRY_LIB="$REPO_ROOT/scripts/lib/local-registry.sh"

setup() {
  SANDBOX="$(mktemp -d)"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  TRELLIS_HOME_FIX="$SANDBOX/trellis home"
  mkdir -p "$TRELLIS_HOME_FIX"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
}

# BSD and GNU stat are probed in SEPARATE captures: GNU `stat -f` is
# --file-system and prints a filesystem block before failing, which a chained
# substitution would concatenate onto the mode.
file_mode() {
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

make_repo() {
  local path="$1" project_id="$2"
  mkdir -p "$path"
  git -C "$path" init -q -b main
  git -C "$path" config user.email registry@example.invalid
  git -C "$path" config user.name Registry
  printf '%s\n' '{"schema_version":1,"project_id":"'"$project_id"'"}' > "$path/.trellis.json"
  printf '%s\n' fixture > "$path/README"
  git -C "$path" add .
  git -C "$path" commit -q -m fixture
}

register_repo() {
  local fleet="$1" project_id="$2" path="$3"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c '. "$1"; local_registry_register_worktree "$TRELLIS_HOME" "$2" "$3" "$4" "" "[]" "" "{}"' _ "$REGISTRY_LIB" "$fleet" "$project_id" "$path"
  [ "$status" -eq 0 ]
}

# A PATH holding everything the registry CLI needs EXCEPT a SHA-256 command.
# Shadowing is impossible (`command -v` would still find the real tool later in
# PATH), so the tool set is rebuilt from scratch by symlink.
hashless_path() {
  local bin="$SANDBOX/hashless bin" tool source
  mkdir -p "$bin"
  for tool in jq git mktemp grep awk sed cat cp mv rm chmod ls find sort tr \
    date dirname basename id stat uname readlink head tail wc printf env sh; do
    source="$(command -v "$tool" 2>/dev/null)" || continue
    ln -sf "$source" "$bin/$tool"
  done
  printf '%s\n' "$bin"
}

# `registry import` writes fleet-scoped rows, so it now refuses a fleet this
# machine has never configured. Import fixtures declare the fleet the same way
# `trellis fleet add` would, without needing a source clone or a launcher.
configure_fleet() {
  local fleet="$1" cfg="$TRELLIS_HOME_FIX/config.json"
  jq -n --arg fleet "$fleet" --arg root "$SANDBOX" \
    '{schema_version: 1, source_root: $root, release_remote: $root,
      active_cli_release: "1.0.0", default_fleet: $fleet,
      fleets: {($fleet): {discovery_roots: [$root]}}}' > "$cfg"
  chmod 600 "$cfg"
}

rewrite_registry_json() {
  local filter="$1" next
  shift
  next="$(mktemp "$TRELLIS_HOME_FIX/.registry.test.XXXXXX")"
  jq "$@" "$filter" "$TRELLIS_HOME_FIX/registry.json" > "$next" || { rm -f "$next"; return 1; }
  mv -f "$next" "$TRELLIS_HOME_FIX/registry.json"
  chmod 600 "$TRELLIS_HOME_FIX/registry.json"
}

@test "same project ID remains fleet-scoped and paths with spaces survive JSON listing" {
  personal="$SANDBOX/personal clone"
  work="$SANDBOX/work clone"
  make_repo "$personal" alpha
  make_repo "$work" alpha
  register_repo personal alpha "$personal"
  register_repo work alpha "$work"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" list --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq '[.entries[] | select(.project_key == "personal/alpha")] | length')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | jq '[.entries[] | select(.project_key == "work/alpha")] | length')" -eq 1 ]
  [[ "$output" == *"personal clone"* ]] || { echo "$output"; false; }
}

@test "multiple clones and linked worktrees retain distinct checkout and worktree IDs" {
  clone_a="$SANDBOX/clone a"
  clone_b="$SANDBOX/clone b"
  linked="$SANDBOX/linked worktree"
  make_repo "$clone_a" alpha
  git clone -q "$clone_a" "$clone_b"
  git -C "$clone_a" worktree add -q -b topic "$linked"
  register_repo personal alpha "$clone_a"
  register_repo personal alpha "$clone_b"
  register_repo personal alpha "$linked"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" list --json --fleet personal
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq '[.entries[].checkout_id] | unique | length')" -eq 2 ]
  [ "$(printf '%s\n' "$output" | jq '[.entries[].worktree_id] | unique | length')" -eq 3 ]
}

@test "corrupt registry and path or identity collisions fail closed" {
  printf '%s\n' '{broken' > "$TRELLIS_HOME_FIX/registry.json"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" list --json
  [ "$status" -eq 4 ]

  printf '%s\n' '{"$schema":1,"schema_version":1,"projects":{}}' > "$TRELLIS_HOME_FIX/registry.json"
  chmod 700 "$TRELLIS_HOME_FIX"
  chmod 600 "$TRELLIS_HOME_FIX/registry.json"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" list --json
  [ "$status" -eq 4 ]
  [[ "$output" == *"registry failed schema-aware validation"* ]] || { echo "$output"; false; }

  rm -f "$TRELLIS_HOME_FIX/registry.json"
  first="$SANDBOX/first"
  second="$SANDBOX/second"
  make_repo "$first" alpha
  make_repo "$second" other
  register_repo personal alpha "$first"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c '. "$1"; local_registry_record_unavailable_root "$TRELLIS_HOME" work other "$2" "{}"' _ "$REGISTRY_LIB" "$first"
  [ "$status" -eq 3 ]

  registry_file="$TRELLIS_HOME_FIX/registry.json"
  jq '.projects["personal/alpha"].checkouts |= (to_entries | .[0].key = ("0" * 64) | from_entries)' \
    "$registry_file" > "$registry_file.next"
  mv "$registry_file.next" "$registry_file"
  chmod 600 "$registry_file"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" list --json
  [ "$status" -eq 4 ]
}

@test "unavailable roots are retained and reported rather than removed" {
  missing="$SANDBOX/missing volume/project"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c '. "$1"; local_registry_record_unavailable_root "$TRELLIS_HOME" personal absent "$2" "{}"' _ "$REGISTRY_LIB" "$missing"
  [ "$status" -eq 0 ]

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" list --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r '.entries[0].status')" = unavailable ]
  [ "$(printf '%s\n' "$output" | jq -r '.entries[0].root')" = "$missing" ]
}

registry_file_sha256() {
  shasum -a 256 "$TRELLIS_HOME_FIX/registry.json" | awk '{print $1}'
}

registry_row_json() {
  jq -cS --arg key "$1" '.projects[$key]' "$TRELLIS_HOME_FIX/registry.json"
}

# GAP: existing unavailable coverage records a root that never existed and reads
# it once. Nothing pinned the DETERMINISM of a previously reachable checkout
# whose volume goes away: repeated listings must agree byte for byte, the stored
# row must not be edited by a read, a reachable sibling must be untouched, and
# remounting must restore the row without rewriting it.
@test "a vanished volume degrades one row deterministically and restores it unchanged on return" {
  local volume offline sibling detached
  local row_before registry_before listing_before first second third

  volume="$SANDBOX/removable volume"
  offline="$volume/offline project with spaces"
  sibling="$SANDBOX/always present/sibling project"
  detached="$SANDBOX/detached volume"
  make_repo "$offline" offline-project
  make_repo "$sibling" sibling-project
  register_repo personal offline-project "$offline"
  register_repo personal sibling-project "$sibling"

  row_before="$(registry_row_json personal/offline-project)"
  registry_before="$(registry_file_sha256)"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" list --fleet personal --json
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  listing_before="$output"
  [ "$(printf '%s\n' "$listing_before" | jq -r '[.entries[] | select(.project_key == "personal/offline-project")] | .[0].status')" = active ]

  # The volume goes away with the project still registered.
  mv "$volume" "$detached"
  [ ! -e "$offline" ]

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" list --fleet personal --json
  # Report-only: a missing volume is a per-row fact, not an environment fault,
  # so the listing itself still succeeds.
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  first="$output"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" list --fleet personal --json
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  second="$output"
  [ "$first" = "$second" ]

  [ "$(printf '%s\n' "$first" | jq -r '[.entries[] | select(.project_key == "personal/offline-project")] | .[0].status')" = unavailable ]
  [ "$(printf '%s\n' "$first" | jq -r '[.entries[] | select(.project_key == "personal/offline-project")] | .[0].root')" = "$offline" ]
  # The reachable sibling is unaffected by its neighbour's missing volume.
  [ "$(printf '%s\n' "$first" | jq -r '[.entries[] | select(.project_key == "personal/sibling-project")] | .[0].status')" = active ]
  [ "$(printf '%s\n' "$first" | jq '.entries | length')" -eq 2 ]

  # Reading never rewrites machine state, so nothing was pruned or repaired.
  [ "$(registry_file_sha256)" = "$registry_before" ]
  [ "$(registry_row_json personal/offline-project)" = "$row_before" ]

  # The volume comes back: the same row returns to active with identical bytes
  # and the listing matches the pre-removal snapshot exactly.
  mv "$detached" "$volume"
  [ -d "$offline" ]
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" list --fleet personal --json
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  third="$output"
  [ "$third" = "$listing_before" ]
  [ "$(registry_file_sha256)" = "$registry_before" ]
  [ "$(registry_row_json personal/offline-project)" = "$row_before" ]
}

@test "import preserves legacy source, previews per-row output, and writes mode 0600 registry" {
  configure_fleet personal
  legacy="$SANDBOX/registry.md"
  missing="$SANDBOX/offline/project"
  cat > "$legacy" <<EOF
# Registry
## Active projects
| Project | Path | Class | Shared services | Project-owned local infrastructure | Fixed-port status | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| offline | \`$missing\` | app | {} | none | {} | unavailable fixture |
EOF
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" import --fleet personal --registry "$legacy"
  [ "$status" -eq 0 ]
  [ -f "$legacy" ]
  [[ "$output" == *$'ok\toffline'* ]] || { echo "$output"; false; }
  run bash -c '. "$1"; local_registry_mode "$2"' _ "$REGISTRY_LIB" "$TRELLIS_HOME_FIX/registry.json"
  [ "$status" -eq 0 ]
  [ "$output" = 600 ]
}

@test "import writes successful rows, reports failures, and returns the highest exit class" {
  configure_fleet personal
  legacy="$SANDBOX/partial-registry.md"
  good="$SANDBOX/offline/good"
  cat > "$legacy" <<EOF
# Registry
## Active projects
| Project | Path | Class | Shared services | Project-owned local infrastructure | Fixed-port status | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| good | \`$good\` | app | {} | none | {} | retained |
| bad | relative/path | app | {} | none | {} | rejected |
EOF

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" import --fleet personal --registry "$legacy"
  [ "$status" -eq 2 ]
  [[ "$output" == *$'ok\tgood'* ]] || { echo "$output"; false; }
  [[ "$output" == *$'error\tbad'* ]] || { echo "$output"; false; }
  [ "$(jq -r '.projects["personal/good"].unavailable_roots[0]' "$TRELLIS_HOME_FIX/registry.json")" = "$good" ]
  [ "$(jq -r '.projects["personal/bad"] // "absent"' "$TRELLIS_HOME_FIX/registry.json")" = absent ]
}

@test "import refuses a fleet this machine has not configured before writing any state" {
  configure_fleet personal
  legacy="$SANDBOX/registry.md"
  cat > "$legacy" <<EOF
# Registry
## Active projects
| Project | Path | Class | Shared services | Project-owned local infrastructure | Fixed-port status | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| offline | \`$SANDBOX/offline/project\` | app | {} | none | {} | fixture |
EOF

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" import --fleet work --registry "$legacy"
  [ "$status" -eq 2 ]
  [[ "$output" == *"fleet is not configured on this machine: work"* ]] || { echo "$output"; false; }
  [[ "$output" == *"trellis fleet add work"* ]] || { echo "$output"; false; }
  [ ! -e "$TRELLIS_HOME_FIX/registry.json" ]

  # The refusal is fleet membership, not the presence of a config file.
  rm -f "$TRELLIS_HOME_FIX/config.json"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" import --fleet personal --registry "$legacy"
  [ "$status" -eq 2 ]
  [[ "$output" == *"machine config not found"* ]] || { echo "$output"; false; }
  [ ! -e "$TRELLIS_HOME_FIX/registry.json" ]

  # A configured fleet still imports, so the guard is membership and nothing else.
  configure_fleet work
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" import --fleet work --registry "$legacy"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -r '.projects["work/offline"].unavailable_roots[0]' "$TRELLIS_HOME_FIX/registry.json")" = "$SANDBOX/offline/project" ]
}

@test "an escaped pipe stays inside its cell and reaches imported metadata unescaped" {
  configure_fleet personal
  legacy="$SANDBOX/escaped-registry.md"
  missing="$SANDBOX/offline/escaped"
  cat > "$legacy" <<EOF
# Registry
## Active projects
| Project | Path | Class | Shared services | Project-owned local infrastructure | Fixed-port status | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| escaped | \`$missing\` | app | {} | none | {} | Root \`Makefile\` orchestrates \`vet\|lint\|test\`. |
EOF

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" import --fleet personal --registry "$legacy"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *$'ok\tescaped'* ]] || { echo "$output"; false; }
  [ "$(jq -r '.projects["personal/escaped"].metadata.legacy.notes' "$TRELLIS_HOME_FIX/registry.json")" = 'Root `Makefile` orchestrates `vet|lint|test`.' ]
  [ "$(jq -r '.projects["personal/escaped"].metadata.legacy.class' "$TRELLIS_HOME_FIX/registry.json")" = app ]
  [ "$(jq -r '.projects["personal/escaped"].unavailable_roots[0]' "$TRELLIS_HOME_FIX/registry.json")" = "$missing" ]

  # An escaped pipe in the Path cell is cell content too, not a column break.
  piped="$SANDBOX/offline/pipe|name"
  cat > "$legacy" <<EOF
# Registry
## Active projects
| Project | Path | Class | Shared services | Project-owned local infrastructure | Fixed-port status | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| piped | \`${piped//|/\\|}\` | app | {} | none | {} | path carries a literal pipe |
EOF
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" import --fleet personal --registry "$legacy"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -r '.projects["personal/piped"].unavailable_roots[0]' "$TRELLIS_HOME_FIX/registry.json")" = "$piped" ]
}

@test "one ambiguous row is rejected by line and cell while every other row imports" {
  configure_fleet personal
  legacy="$SANDBOX/ambiguous-registry.md"
  good="$SANDBOX/offline/good"
  later="$SANDBOX/offline/later"
  cat > "$legacy" <<EOF
# Registry
## Active projects
| Project | Path | Class | Shared services | Project-owned local infrastructure | Fixed-port status | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| good | \`$good\` | app | {} | none | {} | retained |
| ambiguous | \`$SANDBOX/offline/ambiguous\` | app | {} | none | {} | vet|lint|test |
| later | \`$later\` | app | {} | none | {} | still imported |
EOF

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" import --fleet personal --registry "$legacy"
  [ "$status" -eq 4 ]
  [[ "$output" == *"legacy registry row rejected: $legacy:6:"* ]] || { echo "$output"; false; }
  [[ "$output" == *"expected 7 cells, found 9"* ]] || { echo "$output"; false; }
  [[ "$output" == *$'ok\tgood'* ]] || { echo "$output"; false; }
  [[ "$output" == *$'ok\tlater'* ]] || { echo "$output"; false; }
  [ "$(jq -r '.projects["personal/good"].unavailable_roots[0]' "$TRELLIS_HOME_FIX/registry.json")" = "$good" ]
  [ "$(jq -r '.projects["personal/later"].unavailable_roots[0]' "$TRELLIS_HOME_FIX/registry.json")" = "$later" ]
  [ "$(jq -r '.projects["personal/ambiguous"] // "absent"' "$TRELLIS_HOME_FIX/registry.json")" = absent ]

  # An empty required cell is row-scoped for the same reason.
  cat > "$legacy" <<EOF
# Registry
## Active projects
| Project | Path | Class | Shared services | Project-owned local infrastructure | Fixed-port status | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| good | \`$good\` | app | {} | none | {} | retained |
| nameless |  | app | {} | none | {} | no path |
EOF
  rm -f "$TRELLIS_HOME_FIX/registry.json"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" import --fleet personal --registry "$legacy"
  [ "$status" -eq 4 ]
  [[ "$output" == *"$legacy:6: cell 2 (Path) is empty"* ]] || { echo "$output"; false; }
  [ "$(jq -r '.projects["personal/good"].unavailable_roots[0]' "$TRELLIS_HOME_FIX/registry.json")" = "$good" ]

  # A structural fault is still whole-file: no header, no trustworthy row.
  cat > "$legacy" <<EOF
# Registry
## Active projects
| Project | Path | Class | Shared services | Fixed-port status | Notes |
| --- | --- | --- | --- | --- | --- |
| good | \`$good\` | app | {} | {} | retained |
EOF
  rm -f "$TRELLIS_HOME_FIX/registry.json"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" import --fleet personal --registry "$legacy"
  [ "$status" -eq 4 ]
  [[ "$output" == *"legacy registry Markdown is malformed"* ]] || { echo "$output"; false; }
  [ ! -e "$TRELLIS_HOME_FIX/registry.json" ]
}

@test "a parser caller that asks for no reject records keeps the whole-file refusal" {
  legacy="$SANDBOX/strict-registry.md"
  rows="$SANDBOX/rows.tsv"
  rejects="$SANDBOX/rejects.tsv"
  cat > "$legacy" <<EOF
# Registry
## Active projects
| Project | Path | Class | Shared services | Project-owned local infrastructure | Fixed-port status | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| good | \`$SANDBOX/offline/good\` | app | {} | none | {} | retained |
| ambiguous | \`$SANDBOX/offline/bad\` | app | {} | none | {} | vet|lint|test |
EOF

  run bash -c '. "$1"; local_registry_parse_legacy_markdown "$2" "$3"' _ "$REGISTRY_LIB" "$legacy" "$rows"
  [ "$status" -eq 4 ]
  [[ "$output" == *"legacy registry row rejected: $legacy:6:"* ]] || { echo "$output"; false; }
  [ ! -e "$rows" ]

  run bash -c '. "$1"; local_registry_parse_legacy_markdown "$2" "$3" "$4"' _ "$REGISTRY_LIB" "$legacy" "$rows" "$rejects"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(wc -l < "$rows" | tr -d '[:space:]')" -eq 1 ]
  [ "$(cut -f1 "$rows")" = good ]
  [ "$(cut -f1 "$rejects")" = 6 ]
}

@test "--projects-root resolves recorded shorthand and retains it as legacy metadata" {
  configure_fleet personal
  projects_root="$SANDBOX/projects root"
  make_repo "$projects_root/personal/present" present
  legacy="$SANDBOX/shorthand-registry.md"
  cat > "$legacy" <<EOF
# Registry
## Active projects
| Project | Path | Class | Shared services | Project-owned local infrastructure | Fixed-port status | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| present | \`/personal/present\` | app | {} | none | {} | reachable after resolution |
| absent | \`/personal/absent\` | app | {} | none | {} | still unavailable |
EOF

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" import --fleet personal \
    --registry "$legacy" --projects-root "$projects_root"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"ok"$'\t'"present"$'\t'"$projects_root/personal/present"* ]] || { echo "$output"; false; }

  # A resolved path that exists becomes the row root, identified as a worktree.
  [ "$(jq -r '[.projects["personal/present"].checkouts[].worktrees[].root][0]' "$TRELLIS_HOME_FIX/registry.json")" = "$projects_root/personal/present" ]
  [ "$(jq -r '.projects["personal/present"].metadata.legacy.legacy_path' "$TRELLIS_HOME_FIX/registry.json")" = /personal/present ]

  # A resolved path that does not exist stays visible as an unavailable row at
  # the resolved path, never silently dropped.
  [ "$(jq -r '.projects["personal/absent"].unavailable_roots[0]' "$TRELLIS_HOME_FIX/registry.json")" = "$projects_root/personal/absent" ]
  [ "$(jq -r '.projects["personal/absent"].metadata.legacy.legacy_path' "$TRELLIS_HOME_FIX/registry.json")" = /personal/absent ]

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" list --fleet personal
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"unavailable"*"$projects_root/personal/absent"* ]] || { echo "$output"; false; }
}

@test "an existing absolute row path and every path without the flag are used exactly as recorded" {
  configure_fleet personal
  projects_root="$SANDBOX/projects root"
  reachable="$SANDBOX/reachable checkout"
  make_repo "$reachable" reachable
  mkdir -p "$projects_root$reachable"
  legacy="$SANDBOX/mixed-registry.md"
  cat > "$legacy" <<EOF
# Registry
## Active projects
| Project | Path | Class | Shared services | Project-owned local infrastructure | Fixed-port status | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| reachable | \`$reachable\` | app | {} | none | {} | already absolute and present |
| shorthand | \`/personal/shorthand\` | app | {} | none | {} | resolved |
EOF

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" import --fleet personal \
    --registry "$legacy" --projects-root "$projects_root"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -r '[.projects["personal/reachable"].checkouts[].worktrees[].root][0]' "$TRELLIS_HOME_FIX/registry.json")" = "$reachable" ]
  [ "$(jq -r '.projects["personal/reachable"].metadata.legacy.legacy_path // "absent"' "$TRELLIS_HOME_FIX/registry.json")" = absent ]

  # Without the flag the shorthand row is retained at its exact recorded path
  # and carries no resolution metadata at all.
  rm -f "$TRELLIS_HOME_FIX/registry.json"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" import --fleet personal --registry "$legacy"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -r '.projects["personal/shorthand"].unavailable_roots[0]' "$TRELLIS_HOME_FIX/registry.json")" = /personal/shorthand ]
  [ "$(jq -r '.projects["personal/shorthand"].metadata.legacy.legacy_path // "absent"' "$TRELLIS_HOME_FIX/registry.json")" = absent ]
  [ "$(jq -r '[.projects["personal/reachable"].checkouts[].worktrees[].root][0]' "$TRELLIS_HOME_FIX/registry.json")" = "$reachable" ]

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" import --fleet personal \
    --registry "$legacy" --projects-root "relative/root"
  [ "$status" -eq 2 ]
  [[ "$output" == *"projects root must be an absolute path"* ]] || { echo "$output"; false; }
}

@test "rebuild scans only selected roots, previews by default, applies explicitly, and rejects duplicate IDs" {
  selected="$SANDBOX/selected root"
  outside="$SANDBOX/outside"
  make_repo "$selected/one" alpha
  make_repo "$outside/two" beta

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" rebuild --fleet personal "$selected"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r '.apply_required')" = true ]
  [ "$(printf '%s\n' "$output" | jq '.candidates | length')" -eq 1 ]
  [ ! -e "$TRELLIS_HOME_FIX/registry.json" ]

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" rebuild --fleet personal "$selected" --apply
  [ "$status" -eq 0 ]
  [ -f "$TRELLIS_HOME_FIX/registry.json" ]

  make_repo "$selected/duplicate" alpha
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" rebuild --fleet personal "$selected"
  [ "$status" -eq 3 ]
}

@test "rebuild propagates selected-root discovery and ordering failures" {
  selected="$SANDBOX/selected"
  make_repo "$selected/one" alpha
  output_file="$SANDBOX/candidates.jsonl"
  state_file="$SANDBOX/state.json"
  printf '%s\n' '{"schema_version":1,"projects":{},"discovery_ignores":{}}' > "$state_file"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c '. "$1"; find() { return 1; }; rebuild_candidates "$2" "$3" personal 6 off "$4"' _ \
    "$REGISTRY" "$output_file" "$state_file" "$selected"
  [ "$status" -eq 5 ]
  [[ "$output" == *"could not scan selected rebuild root"* ]] || { echo "$output"; false; }

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c '. "$1"; sort() { return 1; }; rebuild_candidates "$2" "$3" personal 6 off "$4"' _ \
    "$REGISTRY" "$output_file" "$state_file" "$selected"
  [ "$status" -eq 5 ]
  [[ "$output" == *"could not sort selected rebuild candidates"* ]] || { echo "$output"; false; }

  # The scan bound is a refusal, not a clamp: a depth outside the supported
  # range must not silently become the default and report a believable scan.
  for depth in 0 65 two ''; do
    run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c '. "$1"; rebuild_candidates "$2" "$3" personal "$5" off "$4"' _ \
      "$REGISTRY" "$output_file" "$state_file" "$selected" "$depth"
    [ "$status" -eq 2 ] || { echo "depth=$depth: $output"; false; }
    [[ "$output" == *"rebuild max depth must be"* ]] || { echo "$output"; false; }
  done
}


@test "external Git directories register and reachable roots remain canonical" {
  separate="$SANDBOX/separate checkout"
  git_dir="$SANDBOX/separate git storage"
  git init -q -b main --separate-git-dir="$git_dir" "$separate"
  git -C "$separate" config user.email registry@example.invalid
  git -C "$separate" config user.name Registry
  printf '%s\n' '{"schema_version":1,"project_id":"separate"}' > "$separate/.trellis.json"
  git -C "$separate" add .
  git -C "$separate" commit -q -m fixture
  register_repo personal separate "$separate"

  clone="$SANDBOX/canonical clone"
  linked_a="$SANDBOX/linked a"
  linked_b="$SANDBOX/linked b"
  make_repo "$clone" canonical
  git -C "$clone" worktree add -q -b linked-a "$linked_a"
  git -C "$clone" worktree add -q -b linked-b "$linked_b"
  register_repo personal canonical "$linked_a"
  rm -rf "$linked_a"
  ln -s "$linked_b" "$linked_a"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" list --json
  [ "$status" -eq 4 ]
  [[ "$output" == *"registered canonical Git identity no longer matches"* ]] || { echo "$output"; false; }
}

@test "registry reads enforce private modes and writes reject bad identity hashes" {
  repo="$SANDBOX/private"
  make_repo "$repo" private
  register_repo personal private "$repo"
  registry_file="$TRELLIS_HOME_FIX/registry.json"

  chmod 644 "$registry_file"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" list --json
  [ "$status" -eq 4 ]
  [[ "$output" == *"registry permissions must be 0600"* ]] || { echo "$output"; false; }
  chmod 600 "$registry_file"

  proposal="$SANDBOX/bad-proposal.json"
  jq '.projects["personal/private"].checkouts |= (to_entries | .[0].key = ("0" * 64) | from_entries)' \
    "$registry_file" > "$proposal"
  chmod 600 "$proposal"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c '
    . "$1"
    trellis_home_lock_acquire "$TRELLIS_HOME" registry 30 || exit "$?"
    local_registry_write_locked "$TRELLIS_HOME" "$2"
    rc=$?
    trellis_home_lock_release >/dev/null 2>&1 || true
    exit "$rc"
  ' _ "$REGISTRY_LIB" "$proposal"
  [ "$status" -eq 4 ]
  [ "$(jq -r '.projects["personal/private"].checkouts | keys[0]' "$registry_file")" != "$(printf '%064d' 0)" ]
}

@test "register transitions detached projects back to active" {
  repo="$SANDBOX/detached"
  make_repo "$repo" detached
  register_repo personal detached "$repo"
  registry_file="$TRELLIS_HOME_FIX/registry.json"
  jq '.projects["personal/detached"].status = "detached"' "$registry_file" > "$registry_file.next"
  mv "$registry_file.next" "$registry_file"
  chmod 600 "$registry_file"

  register_repo personal detached "$repo"
  [ "$(jq -r '.projects["personal/detached"].status' "$registry_file")" = active ]
}

@test "diagnostic retains rootless detached projects without marking them unavailable" {
  repo="$SANDBOX/detached without root"
  make_repo "$repo" detached
  register_repo personal detached "$repo"
  registry_file="$TRELLIS_HOME_FIX/registry.json"
  jq '.projects["personal/detached"] |= (.status = "detached" | .checkouts = {})' \
    "$registry_file" > "$registry_file.next"
  mv "$registry_file.next" "$registry_file"
  chmod 600 "$registry_file"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c \
    '. "$1"; local_registry_list_diagnostic_json "$TRELLIS_HOME" personal' _ "$REGISTRY_LIB"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(printf '%s\n' "$output" | jq -r '.entries | length')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | jq -r '.entries[0].kind')" = project ]
  [ "$(printf '%s\n' "$output" | jq -r '.entries[0].root')" = null ]
  # `not-applicable` is the IDENTITY-state word, not an availability word: the
  # availability vocabulary is a three-word contract the strict snapshot
  # validator enforces, and both listings have to name this row the same way.
  [ "$(printf '%s\n' "$output" | jq -r '.entries[0].availability')" = available ]
  [ "$(printf '%s\n' "$output" | jq -r '.entries[0].status')" = detached ]
  [ "$(printf '%s\n' "$output" | jq -r '.entries[0].identity.state')" = not-applicable ]

  # Parity with the strict listing, which is the point of the word change.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c \
    '. "$1"; local_registry_list_json "$TRELLIS_HOME" personal' _ "$REGISTRY_LIB"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(printf '%s\n' "$output" | jq -r '.entries[0].kind')" = project ]
  [ "$(printf '%s\n' "$output" | jq -r '.entries[0].availability')" = available ]
}

@test "legacy blacklist is strict and preserves both exclusion scopes" {
  configure_fleet personal
  repo="$SANDBOX/blacklisted repo"
  ignored="$SANDBOX/permanently ignored*"
  valid_sibling="$SANDBOX/permanently ignored-valid"
  make_repo "$repo" excluded
  make_repo "$ignored" permanently-ignored
  make_repo "$valid_sibling" valid-sibling
  legacy="$SANDBOX/registry.md"
  blacklist="$SANDBOX/blacklist.md"
  cat > "$legacy" <<EOF
# Registry
## Active projects
| Project | Path | Class | Shared services | Project-owned local infrastructure | Fixed-port status | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| excluded | \`$repo\` | app | {} | none | {} | retained |
EOF
  cat > "$blacklist" <<EOF
# Blacklist
## 1. Temporarily excluded (registered projects)
| Project | Reason | Added | Review after |
|---|---|---|---|
| excluded | maintenance | 2026-08-01 | 2026-09-01 |
## 2. Permanently excluded from management
| Path | Reason |
|---|---|
| \`$ignored\` | unmanaged fixture |
EOF

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" import --fleet personal --registry "$legacy" --blacklist "$blacklist"
  [ "$status" -eq 0 ]
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" list --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r '.entries[0].availability')" = available ]
  [ "$(printf '%s\n' "$output" | jq -r '.entries[0].status')" = active ]
  [ "$(printf '%s\n' "$output" | jq -r '.entries[0].excluded')" = true ]
  [ "$(printf '%s\n' "$output" | jq -r '.entries[0].metadata.legacy.blacklist.reason')" = maintenance ]
  [ "$(printf '%s\n' "$output" | jq -r '.entries[0].metadata.legacy.blacklist.added')" = 2026-08-01 ]
  [ "$(printf '%s\n' "$output" | jq -r '.entries[0].metadata.legacy.blacklist.review_after')" = 2026-09-01 ]
  [ "$(printf '%s\n' "$output" | jq -r '.discovery_ignores.personal[0].path')" = "$ignored" ]
  [ "$(printf '%s\n' "$output" | jq -r '.discovery_ignores.personal[0].reason')" = "unmanaged fixture" ]

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" list --fleet personal
  [ "$status" -eq 0 ]
  [[ "$output" == FLEET$'\t'PROJECT$'\t'STATUS$'\t'EXCLUDED$'\t'* ]] || { echo "$output"; false; }
  [[ "$output" == *$'\ttrue\tworktree\t'* ]] || { echo "$output"; false; }
  [[ "$output" == *$'personal\t-\texcluded\ttrue\tdiscovery-ignore\t-\t-\t'* ]] || { echo "$output"; false; }

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c \
    '. "$1"; local_registry_register_worktree "$TRELLIS_HOME" personal permanently-ignored "$2" "" "[]" "" "{}"' \
    _ "$REGISTRY_LIB" "$ignored"
  [ "$status" -eq 3 ]

  printf '%s\n' '{malformed' > "$ignored/.trellis.json"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" rebuild --fleet personal "$SANDBOX"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq --arg root "$ignored" '[.candidates[] | select(.worktree_root == $root)] | length')" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq --arg root "$valid_sibling" '[.candidates[] | select(.worktree_root == $root)] | length')" -eq 1 ]

  sed 's/Temporarily excluded/Drifted exclusion/' "$blacklist" > "$blacklist.bad"
  rm -f "$TRELLIS_HOME_FIX/registry.json"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" import --fleet personal --registry "$legacy" --blacklist "$blacklist.bad"
  [ "$status" -eq 4 ]
  [ ! -e "$TRELLIS_HOME_FIX/registry.json" ]

  sed 's/| excluded |/| missing |/' "$blacklist" > "$blacklist.missing"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" import --fleet personal --registry "$legacy" --blacklist "$blacklist.missing"
  [ "$status" -eq 4 ]
  [ ! -e "$TRELLIS_HOME_FIX/registry.json" ]
}


@test "discovery ignore containment blocks ancestors descendants and preview races" {
  empty="$SANDBOX/empty.json"
  proposal="$SANDBOX/ignored-state.json"
  registry_file="$TRELLIS_HOME_FIX/registry.json"
  ignored_parent="$SANDBOX/ignored parent"
  printf '%s\n' '{"schema_version":1,"projects":{},"discovery_ignores":{}}' > "$empty"
  ignore_payload="$(jq -cn --arg path "$ignored_parent" '[{path: $path, reason: "fixture"}]')"

  run bash -c '. "$1"; local_registry_propose_discovery_ignores "$2" "$3" personal "$4"' \
    _ "$REGISTRY_LIB" "$empty" "$proposal" "$ignore_payload"
  [ "$status" -eq 0 ]
  chmod 700 "$TRELLIS_HOME_FIX"
  cp "$proposal" "$registry_file"
  chmod 600 "$registry_file"

  child="$ignored_parent/child"
  make_repo "$child" ignored-child
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c \
    '. "$1"; local_registry_register_worktree "$TRELLIS_HOME" personal ignored-child "$2" "" "[]" "" "{}"' \
    _ "$REGISTRY_LIB" "$child"
  [ "$status" -eq 3 ]

  active="$SANDBOX/active"
  make_repo "$active" active
  register_repo personal active "$active"
  ancestor_payload="$(jq -cn --arg path "$SANDBOX" '[{path: $path, reason: "too broad"}]')"
  run bash -c '. "$1"; local_registry_propose_discovery_ignores "$2" "$3" personal "$4"' \
    _ "$REGISTRY_LIB" "$registry_file" "$SANDBOX/ancestor.json" "$ancestor_payload"
  [ "$status" -eq 3 ]

  jq --arg path "$SANDBOX" '.discovery_ignores.personal = [{path: $path, reason: "corrupt overlap"}]' \
    "$registry_file" > "$SANDBOX/corrupt-overlap.json"
  run bash -c '. "$1"; local_registry_validate_file "$2"' \
    _ "$REGISTRY_LIB" "$SANDBOX/corrupt-overlap.json"
  [ "$status" -eq 4 ]

  race_parent="$SANDBOX/race parent"
  race="$race_parent/project"
  candidates="$SANDBOX/race-candidates.jsonl"
  make_repo "$race" race
  run bash -c '. "$1"; rebuild_candidates "$2" "$3" personal 6 off "$4"' \
    _ "$REGISTRY" "$candidates" "$registry_file" "$race_parent"
  [ "$status" -eq 0 ]
  [ "$(jq -s 'length' "$candidates")" -eq 1 ]

  race_payload="$(jq -cn --arg path "$race_parent" '[{path: $path, reason: "added after preview"}]')"
  race_state="$SANDBOX/race-state.json"
  run bash -c '. "$1"; local_registry_propose_discovery_ignores "$2" "$3" personal "$4"' \
    _ "$REGISTRY_LIB" "$registry_file" "$race_state" "$race_payload"
  [ "$status" -eq 0 ]
  run bash -c '
    . "$1"
    candidate="$(cat "$2")"
    local_registry_propose_register_worktree "$3" "$4" personal \
      "$(printf "%s\n" "$candidate" | jq -r .project_id)" \
      "$(printf "%s\n" "$candidate" | jq -r .checkout_root)" \
      "$(printf "%s\n" "$candidate" | jq -r .git_common_dir)" \
      "$(printf "%s\n" "$candidate" | jq -r .checkout_id)" \
      "$(printf "%s\n" "$candidate" | jq -r .worktree_root)" \
      "$(printf "%s\n" "$candidate" | jq -r .worktree_id)" \
      "" "[]" "" "$(printf "%s\n" "$candidate" | jq -c .metadata)"
  ' _ "$REGISTRY_LIB" "$candidates" "$race_state" "$SANDBOX/race-proposal.json"
  [ "$status" -eq 3 ]
}
@test "real legacy blacklist parser preserves two temporary and three permanent records" {
  names="$SANDBOX/names"
  ignores="$SANDBOX/ignores"
  # Until v1.0.0-rc.25 this read the repository's own tracked `blacklist.md`.
  # The cutover untracked it, and `registry import` now only ever sees a file
  # the operator supplies (from Git history or a backup). The historical bytes
  # are reproduced here verbatim — same two sections, same two temporary rows,
  # same three permanent rows with backticked paths — so the parser is still
  # measured against the real shape it has to keep reading, not a simplified one.
  legacy_blacklist="$SANDBOX/legacy-blacklist.md"
  cat > "$legacy_blacklist" <<'LEGACY'
# Blacklist

Two scopes, both excluded from scheduled-task scans.

## 1. Temporarily excluded (registered projects)

Projects that should be **temporarily** excluded from centralized process checks. Every entry needs a **reason** and a **review-after** date.

| Project | Reason | Added | Review after |
|---|---|---|---|
| lambda | Active Astro rewrite awaiting production cutover. `PROCESS_GATE_STACK_PROFILE="n-a"` remains deliberate until the migration pipeline defines project-local validators. | 2026-07-30 | 2026-09-30 |
| mu | Phase-0 scaffold. Proof-of-architecture work is still on `feat/proof-of-architecture`. Same reasoning as `lambda`. | 2026-07-30 | 2026-08-31 |

## 2. Permanently excluded from management

Git repos that should **never** be onboarded to Trellis. Scheduled tasks that scan the filesystem skip these paths — no findings, no weekly re-surfacing.

| Path | Reason |
|---|---|
| `/personal/product-videos` | Permanently excluded content-production repository; never a managed Trellis application. |
| `/personal/multi-store-inventory-mgmt` | Early-stage experiment; will join the registry if it matures. |
| `/personal/copilot-agent-mode-template` | Experiment template; not a managed project. |

---

## Semantics

- **Temporarily excluded** (section 1) — a time-bound pause. Reason + review-after required.
- **Permanently excluded** (section 2) — never managed. No review-after needed.
LEGACY
  run bash -c '
    . "$1"
    legacy_blacklist_records "$2" "$3" "$4" || exit "$?"
    [ "$(awk "END { print NR }" "$3")" -eq 2 ] || exit 1
    jq -s -e "
      length == 3
      and ([.[].path] | sort) == [
        \"/personal/copilot-agent-mode-template\",
        \"/personal/multi-store-inventory-mgmt\",
        \"/personal/product-videos\"
      ]
      and all(.[]; (.reason | length) > 0)
    " "$4" >/dev/null
  ' _ "$REGISTRY" "$legacy_blacklist" "$names" "$ignores"
  [ "$status" -eq 0 ]
}

@test "the tracked central inventory is gone from the repository" {
  # The cutover deliverable, asserted where a reintroduction would be caught:
  # `registry import` reads only operator-supplied files, so a tracked roster
  # reappearing at the repo root would silently restore a second, competing
  # source of fleet membership.
  [ ! -e "$REPO_ROOT/registry.md" ]
  [ ! -e "$REPO_ROOT/blacklist.md" ]
  run git -C "$REPO_ROOT" ls-files --error-unmatch registry.md blacklist.md
  [ "$status" -ne 0 ]
}

@test "rebuild rejects discovered manifest paths containing control characters" {
  selected="$SANDBOX/control-root"
  unsafe="$selected/"$'bad\nname'
  make_repo "$unsafe" unsafe

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" rebuild --fleet personal "$selected"
  [ "$status" -eq 2 ]
  # The rejected class is every terminal control character, not just tab/newline,
  # and the diagnostic must still name WHICH input was rejected.
  [[ "$output" == *"discovered project manifest contains terminal control characters"* ]] || {
    printf '%s\n' "$output"
    false
  }

  # ASSERT THE REFUSAL IN `--apply` TOO, AND ASSERT IT BY CLASS AND CAUSE.
  #
  # An earlier revision asserted `[ ! -e registry.json ]` here. That assertion is
  # not worth keeping, and the reason is worth recording so it is not re-added:
  # a control-character root cannot reach registry.json by ANY route. Removing
  # this screen and re-running `--apply` was measured against three further
  # independent defences — the newline-bearing path is truncated at the newline
  # and rejected as "must be a regular file" (class 4); the escape-bearing path
  # is caught by `trellis_home_require_safe_text` on the worktree root; and with
  # both of those removed the registry schema still rejects the write. The file
  # is therefore absent under every mutation, so its absence discriminates
  # nothing and would pass over a completely removed screen.
  #
  # What DOES discriminate is the pair below: the exit CLASS and the specific
  # cause. With the screen removed the same `--apply` call still fails, but as
  # class 4 with "must be a regular file", or as a `worktree root` message from
  # a later layer — never as this one. Asserting the cause pins that the refusal
  # comes from the discovery-time screen rather than incidentally from a
  # downstream validator that happens to also say no.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" rebuild --fleet personal --apply "$selected"
  [ "$status" -eq 2 ]
  [[ "$output" == *"discovered project manifest contains terminal control characters"* ]] || {
    printf '%s\n' "$output"
    false
  }

  # An escape-bearing path is inside the same rejected class, so a rebuild that
  # only screened tab/newline would register it instead of refusing.
  escaped="$SANDBOX/escape-root"
  make_repo "$escaped/"$'bad\033name' unsafe
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" rebuild --fleet personal "$escaped"
  [ "$status" -eq 2 ]
  [[ "$output" == *"discovered project manifest contains terminal control characters"* ]] || {
    printf '%s\n' "$output"
    false
  }

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" rebuild --fleet personal --apply "$escaped"
  [ "$status" -eq 2 ]
  [[ "$output" == *"discovered project manifest contains terminal control characters"* ]] || {
    printf '%s\n' "$output"
    false
  }
}

# Control for the `--apply` refusals above. Asserting "`--apply` refused" only
# means something if `--apply` over an ACCEPTED root in the same fixture really
# does write — otherwise the refusal could be a fact about the fixture, or about
# rebuild never writing at all, rather than about the screen.
@test "rebuild --apply writes registry.json for an accepted root in the same fixture" {
  accepted="$SANDBOX/accepted-root"
  make_repo "$accepted/plain" accepted-project

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" rebuild --fleet personal --apply "$accepted"
  [ "$status" -eq 0 ]
  [ -f "$TRELLIS_HOME_FIX/registry.json" ]
  run jq -r '.projects | to_entries[] | .value.project_id' "$TRELLIS_HOME_FIX/registry.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *accepted-project* ]] || {
    printf '%s\n' "$output"
    false
  }
}

@test "all local state stays under TRELLIS_HOME rather than operator home" {
  repo="$SANDBOX/repo"
  make_repo "$repo" isolate
  operator_home="$SANDBOX/operator home"
  mkdir -p "$operator_home/.trellis"
  printf '%s\n' sentinel > "$operator_home/.trellis/registry.json"

  run env HOME="$operator_home" TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" rebuild --fleet personal --apply "$SANDBOX"
  [ "$status" -eq 0 ]
  [ "$(cat "$operator_home/.trellis/registry.json")" = sentinel ]
}

@test "a missing SHA-256 command fails the whole listing rather than every row" {
  repo="$SANDBOX/hashless clone"
  make_repo "$repo" alpha
  register_repo personal alpha "$repo"

  bin="$(hashless_path)"
  run env -i PATH="$bin" HOME="$SANDBOX" TMPDIR="$SANDBOX" \
    TRELLIS_HOME="$TRELLIS_HOME_FIX" /bin/bash "$REGISTRY" list --json
  # ENVIRONMENT fault, not a per-row state: class 5 for the listing itself, so a
  # consumer can never read an all-rows-unavailable snapshot as a clean exit 0.
  [ "$status" -eq 5 ]
  [[ "$output" == *"a SHA-256 command (shasum or sha256sum) is required"* ]] || { echo "$output"; false; }
  [[ "$output" != *'"availability": "unavailable"'* ]] || { echo "$output"; false; }
}

@test "a present but broken SHA-256 command fails the whole listing rather than every row" {
  repo="$SANDBOX/broken hash clone"
  make_repo "$repo" alpha
  register_repo personal alpha "$repo"

  # `hashless_path` gives a tool set with NO SHA-256 command; adding a `shasum`
  # that runs, exits 0, and prints something that is not a digest reproduces the
  # broken-Perl install a presence-only probe used to certify. `sha256sum` stays
  # absent so the hasher's preferred command is the broken one.
  bin="$(hashless_path)"
  cat > "$bin/shasum" <<'STUB'
#!/bin/sh
echo "Can't locate Digest/SHA.pm in @INC"
exit 0
STUB
  chmod 755 "$bin/shasum"

  run env -i PATH="$bin" HOME="$SANDBOX" TMPDIR="$SANDBOX" \
    TRELLIS_HOME="$TRELLIS_HOME_FIX" /bin/bash "$REGISTRY" list --json
  # Same class as the missing-command case: the fault is the machine's, so it
  # fails the listing once instead of degrading every row to `unavailable`.
  [ "$status" -eq 5 ]
  [[ "$output" == *"does not compute correct digests"* ]] || { echo "$output"; false; }
  [[ "$output" != *'"availability": "unavailable"'* ]] || { echo "$output"; false; }
}

@test "checkout-level drift on a POPULATED checkout is reported by the listing" {
  clone="$SANDBOX/populated clone"
  linked="$SANDBOX/populated worktree"
  make_repo "$clone" alpha
  git -C "$clone" worktree add -q -b topic "$linked"
  register_repo personal alpha "$clone"
  register_repo personal alpha "$linked"

  # The discriminating shape: every registered WORKTREE root is unreachable, and
  # the checkout root is reachable but drifted. Each worktree row verifies its
  # stored hashes and then short-circuits at `[ -d "$root" ] || return 0`, so
  # every worktree row classifies class 0 / `unavailable`. Only the checkout row
  # resolves the live identity of the checkout root — the row the listing used to
  # emit only for an EMPTY checkout.
  decoy="$SANDBOX/decoy checkout"
  make_repo "$decoy" decoy
  rm -rf "$linked" "$clone"
  rewrite_registry_json '
    .projects["personal/alpha"].checkouts |= with_entries(.value.root = $decoy)
  ' --arg decoy "$decoy"

  # The whole-file validator is the parity oracle: it enumerates a checkout row
  # for every checkout, so it fails class 4 on this state.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c '
    . "$1"; local_registry_validate_available_identities "$2"
  ' _ "$REGISTRY_LIB" "$TRELLIS_HOME_FIX/registry.json"
  [ "$status" -eq 4 ]

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c \
    'bash "$1" list --json > "$2" 2> "$3"' _ "$REGISTRY" "$SANDBOX/list.json" "$SANDBOX/list.err"
  [ "$status" -eq 4 ]
  [ "$(jq '[.entries[] | select(.availability == "identity_error")] | length' "$SANDBOX/list.json")" -eq 2 ]
  [ "$(jq '[.entries[] | select(.availability == "unavailable")] | length' "$SANDBOX/list.json")" -eq 0 ]
  # DEDUPE: one broken checkout reports its root cause once, not once per
  # worktree row filed under it.
  [ "$(grep -c 'registry:' "$SANDBOX/list.err")" -eq 1 ]
}

@test "a second worktree row for one root in one checkout is refused structurally" {
  repo="$SANDBOX/duplicate root clone"
  make_repo "$repo" alpha
  register_repo personal alpha "$repo"

  # Re-key the existing row so the root no longer hashes to its worktree ID.
  # Registering the same root again now computes a DIFFERENT key, which without
  # a structural guard would leave two worktree rows sharing one root — the
  # whole-file identity validation that used to catch this by accident no longer
  # runs for a bound-row registration.
  rewrite_registry_json '
    .projects["personal/alpha"].checkouts |= with_entries(
      .value.worktrees |= (to_entries | {($drifted): .[0].value})
    )
  ' --arg drifted "$(printf '0%.0s' $(seq 64))"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c \
    '. "$1"; local_registry_register_worktree "$TRELLIS_HOME" personal alpha "$2" "" "[]" "" "{}"' \
    _ "$REGISTRY_LIB" "$repo"
  [ "$status" -eq 3 ]
  [[ "$output" == *"identity or path collision"* ]] || { echo "$output"; false; }
  [ "$(jq '[.projects["personal/alpha"].checkouts[].worktrees[]] | length' "$TRELLIS_HOME_FIX/registry.json")" -eq 1 ]
}

@test "detach clears one attachment while an unrelated registry row is broken" {
  attached="$SANDBOX/attached clone"
  sibling="$SANDBOX/broken sibling clone"
  attachment=11111111-2222-3333-4444-555555555555
  make_repo "$attached" attached
  make_repo "$sibling" sibling
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c \
    '. "$1"; local_registry_register_worktree "$TRELLIS_HOME" personal attached "$2" "" "[]" "$3" "{}"' \
    _ "$REGISTRY_LIB" "$attached" "$attachment"
  [ "$status" -eq 0 ]
  register_repo personal sibling "$sibling"

  # Present root that no longer resolves as a canonical Git worktree: the row
  # lists as identity_error. The detach writer used to validate the WHOLE file,
  # so this one broken sibling blocked every detach on the machine.
  rm -rf "$sibling/.git"

  checkout_id="$(jq -r '.projects["personal/attached"].checkouts | keys[0]' "$TRELLIS_HOME_FIX/registry.json")"
  worktree_id="$(jq -r '.projects["personal/attached"].checkouts[].worktrees | keys[0]' "$TRELLIS_HOME_FIX/registry.json")"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c \
    '. "$1"; local_registry_clear_attachment "$TRELLIS_HOME" personal attached "$2" "$3" "$4"' \
    _ "$REGISTRY_LIB" "$checkout_id" "$worktree_id" "$attachment"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.projects["personal/attached"].status' "$TRELLIS_HOME_FIX/registry.json")" = detached ]
  [ "$(jq '[.. | objects | .attachment_id? // empty] | length' "$TRELLIS_HOME_FIX/registry.json")" -eq 0 ]
  # The broken sibling row is untouched, not repaired and not removed.
  [ "$(jq --arg root "$sibling" '[.projects["personal/sibling"].checkouts[].worktrees[] | select(.root == $root)] | length' "$TRELLIS_HOME_FIX/registry.json")" -eq 1 ]
}

@test "a bound-row write with nothing bound is a usage refusal" {
  repo="$SANDBOX/bound floor clone"
  make_repo "$repo" alpha
  register_repo personal alpha "$repo"
  before="$(jq -S . "$TRELLIS_HOME_FIX/registry.json")"

  # The last two carry whitespace: the binding list is consumed by a two-field
  # `read -r checkout worktree`, so a spaced or tabbed ID splits into two
  # nonexistent IDs, matches no row, validates vacuously, and degrades the write
  # to schema-only — the same hole as binding nothing at all.
  for bindings in '[]' '[{"checkout_id":"","worktree_id":""}]' '[{"worktree_id":"x"}]' \
    '[{"checkout_id":"aaaa bbbb","worktree_id":""}]' '[{"checkout_id":"aaaa\tbbbb","worktree_id":""}]'; do
    run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c '
      . "$1"
      trellis_home_lock_acquire "$TRELLIS_HOME" registry 30 || exit 9
      local_registry_load "$TRELLIS_HOME" "$2" || exit 9
      local_registry_write_locked_bound_rows "$TRELLIS_HOME" "$2" "$3"
      rc=$?
      trellis_home_lock_release >/dev/null 2>&1
      exit "$rc"
    ' _ "$REGISTRY_LIB" "$SANDBOX/proposal.json" "$bindings"
    [ "$status" -eq 2 ]
    [[ "$output" == *"non-empty binding array"* ]] || { echo "$output"; false; }
  done
  [ "$(jq -S . "$TRELLIS_HOME_FIX/registry.json")" = "$before" ]
}

@test "a bound-row write refuses a whitespace-bearing worktree ID" {
  repo="$SANDBOX/bound worktree floor clone"
  make_repo "$repo" alpha
  register_repo personal alpha "$repo"
  before="$(jq -S . "$TRELLIS_HOME_FIX/registry.json")"
  checkout_id="$(jq -r '.projects["personal/alpha"].checkouts | keys[0]' "$TRELLIS_HOME_FIX/registry.json")"

  # The checkout ID is legal here, so the entry passes the existing floor. The
  # WORKTREE ID is where `read -r checkout worktree` hides the split: the whole
  # tail lands in `worktree` intact, naming no registered row, so the bound-row
  # validator vouches only for the checkout and the worktree row this write
  # mutates is never checked — a silently weaker write than the caller asked for.
  for worktree_id in 'aaaa bbbb' "$(printf 'aaaa\tbbbb')"; do
    run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c '
      . "$1"
      trellis_home_lock_acquire "$TRELLIS_HOME" registry 30 || exit 9
      local_registry_load "$TRELLIS_HOME" "$2" || exit 9
      bindings="$(jq -cn --arg checkout "$3" --arg worktree "$4" \
        "[{checkout_id: \$checkout, worktree_id: \$worktree}]")"
      local_registry_write_locked_bound_rows "$TRELLIS_HOME" "$2" "$bindings"
      rc=$?
      trellis_home_lock_release >/dev/null 2>&1
      exit "$rc"
    ' _ "$REGISTRY_LIB" "$SANDBOX/proposal.json" "$checkout_id" "$worktree_id"
    [ "$status" -eq 2 ]
    printf '%s\n' "$output" | grep -Fq 'whitespace-free checkout and worktree IDs' 
  done
  [ "$(jq -S . "$TRELLIS_HOME_FIX/registry.json")" = "$before" ]
}

@test "a broken SHA-256 command fails a bound-row WRITE as an environment fault" {
  repo="$SANDBOX/write probe clone"
  attachment=11111111-2222-3333-4444-555555555555
  make_repo "$repo" alpha
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c \
    '. "$1"; local_registry_register_worktree "$TRELLIS_HOME" personal alpha "$2" "" "[]" "$3" "{}"' \
    _ "$REGISTRY_LIB" "$repo" "$attachment"
  [ "$status" -eq 0 ]
  checkout_id="$(jq -r '.projects["personal/alpha"].checkouts | keys[0]' "$TRELLIS_HOME_FIX/registry.json")"
  worktree_id="$(jq -r '.projects["personal/alpha"].checkouts[].worktrees | keys[0]' "$TRELLIS_HOME_FIX/registry.json")"

  # A hasher that returns a WELL-FORMED but wrong digest is the discriminating
  # stub: `local_registry_sha256`'s own format check passes it, so without an
  # up-front probe the machine fault reaches the bound-row identity comparison
  # and is reported as class 4 — registry corruption — for a registry that is
  # perfectly intact. The read path already probed once; the write path did not.
  bin="$(hashless_path)"
  for tool in mkdir rmdir ln touch; do
    ln -sf "$(command -v "$tool")" "$bin/$tool"
  done
  cat > "$bin/shasum" <<'STUB'
#!/bin/sh
echo "0000000000000000000000000000000000000000000000000000000000000000  -"
exit 0
STUB
  chmod 755 "$bin/shasum"

  run env -i PATH="$bin" HOME="$SANDBOX" TMPDIR="$SANDBOX" \
    TRELLIS_HOME="$TRELLIS_HOME_FIX" /bin/bash -c \
    '. "$1"; local_registry_clear_attachment "$TRELLIS_HOME" personal alpha "$2" "$3" "$4"' \
    _ "$REGISTRY_LIB" "$checkout_id" "$worktree_id" "$attachment"
  # ENVIRONMENT (5), never STATE (4). A bare `[[ ]]` is a bats keyword and does
  # not trip the ERR trap mid-test, so message assertions are counted instead.
  [ "$status" -eq 5 ]
  [ "$(printf '%s\n' "$output" | grep -cF 'does not compute correct digests')" -ge 1 ] ||
    { echo "$output"; false; }
  # COUNTED ZERO, not `grep -Fqv`: -qv succeeds the moment ANY line fails to
  # match, so on multi-line output it was true no matter what was printed — the
  # class-4 cause could reach the operator with this assertion still green.
  [ "$(printf '%s\n' "$output" | grep -cF 'does not match recorded Git common directory')" -eq 0 ] ||
    { echo "$output"; false; }
  # Report-only: the write never happened, so the attachment is intact.
  [ "$(jq -r '.projects["personal/alpha"].checkouts[].worktrees[].attachment_id' "$TRELLIS_HOME_FIX/registry.json")" = "$attachment" ]
}

@test "a worktree row's own cause survives the checkout-level dedupe" {
  clone="$SANDBOX/dedupe clone"
  linked="$SANDBOX/dedupe worktree"
  decoy="$SANDBOX/dedupe decoy"
  make_repo "$clone" alpha
  git -C "$clone" worktree add -q -b topic "$linked"
  register_repo personal alpha "$clone"
  register_repo personal alpha "$linked"
  make_repo "$decoy" decoy

  # Two INDEPENDENT faults under one checkout: the checkout root is repointed at
  # an unrelated repository (checkout-level drift), and one worktree row is
  # re-keyed so its stored ID no longer hashes its own recorded root.
  rewrite_registry_json '
    .projects["personal/alpha"].checkouts |= with_entries(
      .value.root = $decoy
      | .value.worktrees |= (to_entries
          | map(if .value.root == $decoy then . else {key: $drifted, value: .value} end)
          | from_entries)
    )
  ' --arg decoy "$decoy" --arg drifted "$(printf '0%.0s' $(seq 64))"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c \
    'bash "$1" list --json > "$2" 2> "$3"' _ "$REGISTRY" "$SANDBOX/dedupe.json" "$SANDBOX/dedupe.err"
  [ "$status" -eq 4 ]

  # The checkout-level cause is still reported exactly once, not once per
  # worktree filed under it.
  [ "$(grep -c 'recorded Git common directory\|canonical Git identity no longer matches' "$SANDBOX/dedupe.err")" -eq 1 ]
  # ...and the worktree row's OWN, distinct cause is not swallowed with it.
  grep -Fq 'worktree ID does not match recorded root' "$SANDBOX/dedupe.err"
}

@test "a row the strict validator calls class 4 is identity_error in BOTH listings" {
  clone="$SANDBOX/agreement clone"
  gone="$SANDBOX/agreement gone"
  make_repo "$clone" alpha
  register_repo personal alpha "$clone"

  # THE discriminating fixture for the two-classifier defect: a worktree row
  # whose root is UNREACHABLE and whose stored ID is also wrong, filed under a
  # perfectly HEALTHY checkout. The strict validator compares the stored hashes
  # before it short-circuits on reachability, so it condemns the row class 4.
  # The diagnostic classifier short-circuited on reachability FIRST and called
  # the very same row `unavailable` — a benign word — so every diagnostic
  # consumer under-reported it.
  #
  # The checkout must stay healthy or the checkout-row FOLD would supply
  # `identity_error` on its own and the case would stop discriminating.
  rewrite_registry_json '
    .projects["personal/alpha"].checkouts |= with_entries(
      .value.worktrees[$zero] = {root: $gone}
    )
  ' --arg zero "$(printf '0%.0s' $(seq 64))" --arg gone "$gone"
  [ ! -d "$gone" ]

  # Strict, whole-file: class 4.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c \
    '. "$1"; local_registry_read_state "$TRELLIS_HOME" >/dev/null' _ "$REGISTRY_LIB"
  [ "$status" -eq 4 ]

  # Strict listing: the class-4 word. Diagnostics go to a file — `run` merges
  # stderr into `$output`, which would not parse as JSON.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c \
    'bash "$1" list --json > "$2" 2>/dev/null' _ "$REGISTRY" "$SANDBOX/agree.strict.json"
  [ "$status" -eq 4 ]
  [ "$(jq -r --arg gone "$gone" '[.entries[] | select(.root == $gone) | .availability] | join(",")' "$SANDBOX/agree.strict.json")" = identity_error ]
  # The healthy sibling under the same checkout is untouched: per-row continuation.
  [ "$(jq -r --arg root "$clone" '[.entries[] | select(.root == $root) | .availability] | join(",")' "$SANDBOX/agree.strict.json")" = available ]

  # Diagnostic listing: the SAME word, from the same classifier, carrying the
  # same class. `unavailable` here would be the old, silently divergent answer.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c \
    '. "$1"; local_registry_list_diagnostic_json "$TRELLIS_HOME" > "$2"' \
    _ "$REGISTRY_LIB" "$SANDBOX/agree.diag.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r --arg gone "$gone" '[.entries[] | select(.root == $gone) | .identity.state] | join(",")' "$SANDBOX/agree.diag.json")" = identity_error ]
  [ "$(jq -r --arg gone "$gone" '[.entries[] | select(.root == $gone) | .identity.class] | join(",")' "$SANDBOX/agree.diag.json")" = 4 ]
  [ "$(jq -r --arg root "$clone" '[.entries[] | select(.root == $root) | .identity.state] | join(",")' "$SANDBOX/agree.diag.json")" = verified ]
}

@test "a fleet-scoped listing never prints another fleet's checkout cause" {
  personal="$SANDBOX/scoped personal"
  work="$SANDBOX/scoped work"
  make_repo "$personal" alpha
  make_repo "$work" alpha
  register_repo personal alpha "$personal"
  register_repo work alpha "$work"

  # Break ONLY the work fleet's checkout row: its stored checkout ID no longer
  # hashes from the recorded Git common directory. That is a checkout-scoped
  # class-4 fault, which the checkout pre-pass reports on stderr.
  rewrite_registry_json '
    .projects["work/alpha"].checkouts |= with_entries(.value.git_common_dir = $moved)
  ' --arg moved "$SANDBOX/moved common dir"

  # Fleet scoping is a documented contract: a personal-fleet consumer cannot act
  # on a work-fleet row and does not raise its class for one, so it must not be
  # handed that row's terminal text either. The pre-pass ran in report mode over
  # the whole file and printed the work cause into every personal listing.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c \
    '. "$1"; local_registry_list_json "$TRELLIS_HOME" personal > "$2" 2>"$3"' \
    _ "$REGISTRY_LIB" "$SANDBOX/scoped.personal.json" "$SANDBOX/scoped.personal.err"
  [ "$status" -eq 0 ] || { cat "$SANDBOX/scoped.personal.err"; false; }
  [ ! -s "$SANDBOX/scoped.personal.err" ] || { cat "$SANDBOX/scoped.personal.err"; false; }
  [ "$(jq -r --arg root "$personal" '[.entries[] | select(.root == $root) | .availability] | join(",")' "$SANDBOX/scoped.personal.json")" = available ]

  # The class table itself is still computed whole-file: listing the work fleet
  # folds the same checkout verdict onto its row and prints the cause once.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c \
    '. "$1"; local_registry_list_json "$TRELLIS_HOME" work > "$2" 2>"$3"' \
    _ "$REGISTRY_LIB" "$SANDBOX/scoped.work.json" "$SANDBOX/scoped.work.err"
  [ "$status" -eq 0 ]
  [ "$(jq -r --arg root "$work" '[.entries[] | select(.root == $root) | .availability] | join(",")' "$SANDBOX/scoped.work.json")" = identity_error ]
  grep -qF 'checkout ID does not match recorded Git common directory' "$SANDBOX/scoped.work.err"

  # A whole-machine consumer still sees it, which is the case the scoping keeps.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c \
    '. "$1"; local_registry_list_json "$TRELLIS_HOME" > "$2" 2>"$3"' \
    _ "$REGISTRY_LIB" "$SANDBOX/scoped.all.json" "$SANDBOX/scoped.all.err"
  [ "$status" -eq 0 ]
  grep -qF 'checkout ID does not match recorded Git common directory' "$SANDBOX/scoped.all.err"
}

@test "a worktree's own class-5 cause is printed under a failed checkout row" {
  clone="$SANDBOX/class5 clone"
  linked="$SANDBOX/class5 linked"
  make_repo "$clone" alpha
  git -C "$clone" worktree add -q -b topic "$linked"
  register_repo personal alpha "$linked"

  # Both roots stay REACHABLE — `-d` succeeds — but neither can be canonicalized,
  # which is the class-5 environment answer rather than the class-4 state one.
  # The owning checkout row fails first, so the row loop suppresses this
  # worktree's stderr to avoid repeating the checkout-level cause; the narrowed
  # re-report handled class 4 only, so the worktree's own class-5 cause went out
  # with it and the row surfaced as the bare word `unavailable` — the same word
  # an unmounted volume gets — with nothing naming the real fault.
  chmod 000 "$clone" "$linked"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c \
    '. "$1"; local_registry_list_json "$TRELLIS_HOME" > "$2" 2>"$3"' \
    _ "$REGISTRY_LIB" "$SANDBOX/class5.json" "$SANDBOX/class5.err"
  chmod 755 "$clone" "$linked"

  [ "$status" -eq 0 ] || { cat "$SANDBOX/class5.err"; false; }
  [ "$(jq -r --arg root "$linked" '[.entries[] | select(.root == $root) | .availability] | join(",")' "$SANDBOX/class5.json")" = unavailable ]
  # The checkout-level cause, printed exactly once by the pre-pass...
  [ "$(grep -cF "$clone" "$SANDBOX/class5.err")" -eq 1 ] || { cat "$SANDBOX/class5.err"; false; }
  # ...and this worktree's own, distinct cause, printed exactly once.
  [ "$(grep -cF "$linked" "$SANDBOX/class5.err")" -eq 1 ] || { cat "$SANDBOX/class5.err"; false; }
}

@test "the checkout class-vocabulary guard scopes its diagnostic to the listed fleet" {
  # The class table is computed WHOLE-FILE, so a class the fold logic cannot
  # interpret may belong to a fleet the caller cannot see. The guard still fails
  # the listing class 4 — that is a listing-level fault, not a row disposition —
  # but a fleet-scoped caller must not be handed another fleet's project key,
  # exactly as the per-checkout identity causes are withheld from it.
  local table
  table="$(printf 'work/alpha\t8fbc\t9\n')"

  run env bash -c '. "$1"; local_registry_require_checkout_class_vocabulary "$2" "$3"' \
    _ "$REGISTRY_LIB" "$table" personal
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  # Exact equality IS the absence claim: the cross-fleet key and checkout ID are
  # nowhere in the line, and the class the caller must act on still is.
  [ "$output" = 'trellis registry: could not classify a registry checkout row outside fleet personal (exit 9)' ] ||
    { echo "$output"; false; }

  # In-fleet, the offending checkout is still named.
  run env bash -c '. "$1"; local_registry_require_checkout_class_vocabulary "$2" "$3"' \
    _ "$REGISTRY_LIB" "$table" work
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [ "$output" = 'trellis registry: could not classify registry checkout row (exit 9): work/alpha 8fbc' ] ||
    { echo "$output"; false; }

  # So is it for a whole-machine consumer, which passes no fleet at all.
  run env bash -c '. "$1"; local_registry_require_checkout_class_vocabulary "$2"' \
    _ "$REGISTRY_LIB" "$table"
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [ "$output" = 'trellis registry: could not classify registry checkout row (exit 9): work/alpha 8fbc' ] ||
    { echo "$output"; false; }

  # A table holding only reportable classes passes silently, which is what keeps
  # the three assertions above from being satisfied by an always-failing guard.
  run env bash -c '. "$1"; local_registry_require_checkout_class_vocabulary "$2" "$3"' \
    _ "$REGISTRY_LIB" "$(printf 'work/alpha\t8fbc\t4\npersonal/alpha\t2ab1\t5\n')" personal
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = '' ] || { echo "$output"; false; }
}

# T31 F3. `--projects-root` used to resolve registry ROWS only, so a legacy
# blacklist section 2 that records the same portable shorthand imported ignores
# nobody could ever match: state that reads exactly like working exclusion and
# excludes nothing. The counterfactual at the end of this case is the point —
# the unresolved ignore lets the rebuild scan pick the ignored project straight
# back up.
@test "shorthand blacklist ignores resolve through --projects-root and rebuild honors them" {
  configure_fleet personal
  projects_root="$SANDBOX/projects root"
  make_repo "$projects_root/personal/kept" kept
  make_repo "$projects_root/personal/ignored" ignored
  legacy="$SANDBOX/shorthand-registry.md"
  blacklist="$SANDBOX/shorthand-blacklist.md"
  cat > "$legacy" <<EOF
# Registry
## Active projects
| Project | Path | Class | Shared services | Project-owned local infrastructure | Fixed-port status | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| kept | \`/personal/kept\` | app | {} | none | {} | resolved row |
EOF
  cat > "$blacklist" <<EOF
# Blacklist
## 1. Temporarily excluded (registered projects)
| Project | Reason | Added | Review after |
|---|---|---|---|
| kept | maintenance | 2026-08-01 | 2026-09-01 |
## 2. Permanently excluded from management
| Path | Reason |
|---|---|
| \`/personal/ignored\` | unmanaged fixture |
EOF

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" import --fleet personal \
    --registry "$legacy" --blacklist "$blacklist" --projects-root "$projects_root"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  # The ignore is stored resolved, and the recorded shorthand survives the
  # resolution exactly as a resolved row's `legacy.legacy_path` does.
  [ "$(jq -r '.discovery_ignores.personal[0].path' "$TRELLIS_HOME_FIX/registry.json")" = "$projects_root/personal/ignored" ]
  [ "$(jq -r '.discovery_ignores.personal[0].legacy_path' "$TRELLIS_HOME_FIX/registry.json")" = /personal/ignored ]

  # ...and the scan actually honours it: the ignored project is gone from the
  # rebuild preview while its sibling under the same root is still found.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" rebuild --fleet personal "$projects_root"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(printf '%s\n' "$output" | jq --arg root "$projects_root/personal/ignored" '[.candidates[] | select(.worktree_root == $root)] | length')" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq --arg root "$projects_root/personal/kept" '[.candidates[] | select(.worktree_root == $root)] | length')" -eq 1 ]

  # COUNTERFACTUAL: the same blacklist imported without the flag keeps the
  # shorthand, and the rebuild then registers the project the operator excluded.
  rm -f "$TRELLIS_HOME_FIX/registry.json"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" import --fleet personal \
    --registry "$legacy" --blacklist "$blacklist"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -r '.discovery_ignores.personal[0].path' "$TRELLIS_HOME_FIX/registry.json")" = /personal/ignored ]
  [ "$(jq -r '.discovery_ignores.personal[0].legacy_path // "absent"' "$TRELLIS_HOME_FIX/registry.json")" = absent ]
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" rebuild --fleet personal "$projects_root"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(printf '%s\n' "$output" | jq --arg root "$projects_root/personal/ignored" '[.candidates[] | select(.worktree_root == $root)] | length')" -eq 1 ]
}

# The contradiction check has to compare RESOLVED paths on both sides. A row
# recorded as an absolute present path and an ignore recorded as the shorthand
# that resolves onto it are the same path claimed twice; comparing the recorded
# strings sees two different paths and imports the contradiction.
@test "a resolved discovery ignore that lands on a resolved registry row is refused" {
  configure_fleet personal
  projects_root="$SANDBOX/projects root"
  make_repo "$projects_root/personal/kept" kept
  legacy="$SANDBOX/absolute-registry.md"
  blacklist="$SANDBOX/colliding-blacklist.md"
  cat > "$legacy" <<EOF
# Registry
## Active projects
| Project | Path | Class | Shared services | Project-owned local infrastructure | Fixed-port status | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| kept | \`$projects_root/personal/kept\` | app | {} | none | {} | absolute and present |
EOF
  cat > "$blacklist" <<EOF
# Blacklist
## 1. Temporarily excluded (registered projects)
| Project | Reason | Added | Review after |
|---|---|---|---|
| kept | maintenance | 2026-08-01 | 2026-09-01 |
## 2. Permanently excluded from management
| Path | Reason |
|---|---|
| \`/personal/kept\` | shorthand for the same project |
EOF

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" import --fleet personal \
    --registry "$legacy" --blacklist "$blacklist" --projects-root "$projects_root"
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *"permanent discovery ignore is also present in legacy registry"* ]] || { echo "$output"; false; }
  [ ! -e "$TRELLIS_HOME_FIX/registry.json" ]
}

# T31. The unbounded full-tree `find` timed out at two minutes on a real
# projects tree. The bound is two facts a fixture can pin exactly: dependency
# and VCS directories are never descended into, and a documented per-root depth
# cap applies — while a manifest AT the cap is still found, which is what stops
# "bounded" from quietly meaning "misses things".
@test "rebuild bounds its scan by pruned directories and a per-root depth cap" {
  root="$SANDBOX/bounded root"
  make_repo "$root/shallow" shallow
  make_repo "$root/a/b/c/at-cap" at-cap
  make_repo "$root/a/b/c/d/beyond-cap" beyond-cap
  make_repo "$root/shallow/node_modules/vendored" vendored-dep
  make_repo "$root/shallow/vendor/bundled" bundled-dep
  # A deep chain no scan should walk: it is both beyond the cap and, at its top,
  # inside a pruned directory.
  mkdir -p "$root/shallow/node_modules/$(printf 'deep/%.0s' $(seq 1 40))"

  started="$SECONDS"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" rebuild --fleet personal --max-depth 4 "$root"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  elapsed="$(( SECONDS - started ))"
  [ "$elapsed" -lt 20 ] || { echo "bounded scan took ${elapsed}s"; false; }

  found_ids="$(printf '%s\n' "$output" | jq -r '[.candidates[].project_id] | sort | join(",")')"
  # `shallow` is depth 1 and `at-cap` is exactly the requested depth 4; the
  # project one level deeper and both vendored copies are outside the bound.
  [ "$found_ids" = "at-cap,shallow" ] || { echo "$found_ids"; false; }

  # Raising the cap reaches the deeper project, so the exclusion above is the
  # depth bound doing its job rather than the fixture being unreachable.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" rebuild --fleet personal --max-depth 5 "$root"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  found_ids="$(printf '%s\n' "$output" | jq -r '[.candidates[].project_id] | sort | join(",")')"
  [ "$found_ids" = "at-cap,beyond-cap,shallow" ] || { echo "$found_ids"; false; }

  # No depth reaches a pruned directory: the vendored manifests stay invisible
  # at the maximum supported cap.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" rebuild --fleet personal --max-depth 64 "$root"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(printf '%s\n' "$output" | jq '[.candidates[] | select(.project_id == "vendored-dep" or .project_id == "bundled-dep")] | length')" -eq 0 ]

  # A selected root named like a pruned directory is still scanned: the prune
  # group must not be able to prune the starting point and report an empty,
  # entirely believable result.
  make_repo "$SANDBOX/vendor/inside" inside-vendor-root
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" rebuild --fleet personal "$SANDBOX/vendor"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(printf '%s\n' "$output" | jq -r '[.candidates[].project_id] | join(",")')" = inside-vendor-root ]

  # The default cap is the documented one, and it is what an operator gets
  # without the flag.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c '. "$1"; printf "%s\n" "$REBUILD_MAX_DEPTH_DEFAULT"' _ "$REGISTRY"
  [ "$output" = 6 ] || { echo "$output"; false; }
}

@test "rebuild streams scan progress to stderr only when asked and never onto stdout" {
  root="$SANDBOX/progress root"
  make_repo "$root/one" progress-one
  preview="$SANDBOX/preview.json"
  progress_log="$SANDBOX/progress.log"

  # Run OUTSIDE bats' `run`, which merges stderr into stdout and would make the
  # separation this case exists to prove unobservable.
  env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" rebuild --fleet personal --progress "$root" \
    > "$preview" 2> "$progress_log"
  [ "$(jq -r '.candidates[0].project_id' "$preview")" = progress-one ]
  grep -Fq "scanning $root (max depth 6)" "$progress_log" || { cat "$progress_log"; false; }
  grep -Fq "found $root/one/.trellis.json" "$progress_log" || { cat "$progress_log"; false; }
  grep -Fq "scanned $root: 1 manifest(s)" "$progress_log" || { cat "$progress_log"; false; }

  # Not a terminal and not asked for: silent, so a machine consumer reading the
  # preview never has to filter a progress stream out of its logs.
  : > "$progress_log"
  env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" rebuild --fleet personal "$root" \
    > "$preview" 2> "$progress_log"
  [ ! -s "$progress_log" ] || { cat "$progress_log"; false; }
  [ "$(jq -r '.candidates[0].project_id' "$preview")" = progress-one ]

  : > "$progress_log"
  env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" rebuild --fleet personal --progress --no-progress "$root" \
    > "$preview" 2> "$progress_log"
  [ ! -s "$progress_log" ] || { cat "$progress_log"; false; }
}

# T31. Machine-local facts that a migrated project can no longer track — the
# per-project gptx routing block being the case that forced this — need a
# private home that survives migration. `registry annotate` is that setter, and
# these are its contracts.
@test "annotate merges machine-local metadata onto a registered row without dropping legacy keys" {
  configure_fleet personal
  repo="$SANDBOX/annotated clone"
  make_repo "$repo" alpha
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c \
    '. "$1"; local_registry_register_worktree "$TRELLIS_HOME" personal alpha "$2" "" "[]" "" "$3"' \
    _ "$REGISTRY_LIB" "$repo" '{"legacy":{"notes":"imported"}}'
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" annotate --fleet personal --project alpha \
    --metadata-json '{"gptx":{"enabled":true,"lane":"codex"}}'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(printf '%s\n' "$output" | jq -r '.metadata.gptx.lane')" = codex ]
  [ "$(jq -r '.projects["personal/alpha"].metadata.gptx.enabled' "$TRELLIS_HOME_FIX/registry.json")" = true ]
  # The import's own metadata is retained, not replaced wholesale.
  [ "$(jq -r '.projects["personal/alpha"].metadata.legacy.notes' "$TRELLIS_HOME_FIX/registry.json")" = imported ]
  [ "$(file_mode "$TRELLIS_HOME_FIX/registry.json")" = 600 ]

  # The merge is SHALLOW by contract: a supplied top-level key replaces its
  # counterpart outright rather than being deep-merged into it, so a re-stated
  # routing block is the whole routing block.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" annotate --fleet personal --project alpha \
    --metadata-json '{"gptx":{"enabled":false}}'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -cS '.projects["personal/alpha"].metadata.gptx' "$TRELLIS_HOME_FIX/registry.json")" = '{"enabled":false}' ]
  [ "$(jq -r '.projects["personal/alpha"].metadata.legacy.notes' "$TRELLIS_HOME_FIX/registry.json")" = imported ]
}

@test "annotate refuses unregistered rows and non-object metadata, and writes nothing" {
  configure_fleet personal
  repo="$SANDBOX/annotate refusal clone"
  make_repo "$repo" alpha
  register_repo personal alpha "$repo"
  before="$(jq -S . "$TRELLIS_HOME_FIX/registry.json")"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" annotate --fleet personal --project absent \
    --metadata-json '{"gptx":{"enabled":true}}'
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  [[ "$output" == *"project is not registered: personal/absent"* ]] || { echo "$output"; false; }

  for payload in '[]' '"routing"' 'null' 'not json'; do
    run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" annotate --fleet personal --project alpha \
      --metadata-json "$payload"
    [ "$status" -eq 2 ] || { echo "payload=$payload: $output"; false; }
    [[ "$output" == *"--metadata-json must be a JSON object"* ]] || { echo "$output"; false; }
  done

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" annotate --fleet personal --project alpha
  [ "$status" -eq 2 ] || { echo "$output"; false; }

  # An unconfigured fleet is the same refusal `import` makes: annotate writes
  # fleet-scoped state, so a typo must not leave rows doctor cannot inspect.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" annotate --fleet typo --project alpha \
    --metadata-json '{"gptx":{"enabled":true}}'
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"fleet is not configured on this machine: typo"* ]] || { echo "$output"; false; }

  [ "$(jq -S . "$TRELLIS_HOME_FIX/registry.json")" = "$before" ]
}

@test "annotate binds the annotated project's rows and survives a broken sibling" {
  configure_fleet personal
  annotated="$SANDBOX/annotated project"
  sibling="$SANDBOX/broken sibling"
  make_repo "$annotated" alpha
  make_repo "$sibling" sibling
  register_repo personal alpha "$annotated"
  register_repo personal sibling "$sibling"

  # Present root that no longer resolves as a canonical Git worktree: a
  # whole-file writer would refuse every annotation on the machine over it.
  rm -rf "$sibling/.git"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" annotate --fleet personal --project alpha \
    --metadata-json '{"gptx":{"enabled":true}}'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -r '.projects["personal/alpha"].metadata.gptx.enabled' "$TRELLIS_HOME_FIX/registry.json")" = true ]
  # The broken sibling row is untouched, not repaired and not removed.
  [ "$(jq --arg root "$sibling" '[.projects["personal/sibling"].checkouts[].worktrees[] | select(.root == $root)] | length' "$TRELLIS_HOME_FIX/registry.json")" -eq 1 ]

  # A row whose only inventory is an unavailable root has no checkout or
  # worktree to bind. It is still annotatable — that row is precisely the one an
  # operator annotates while the volume is away.
  legacy="$SANDBOX/unavailable-registry.md"
  cat > "$legacy" <<EOF
# Registry
## Active projects
| Project | Path | Class | Shared services | Project-owned local infrastructure | Fixed-port status | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| away | \`$SANDBOX/unmounted volume\` | app | {} | none | {} | unavailable |
EOF
  rm -f "$TRELLIS_HOME_FIX/registry.json"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" import --fleet personal --registry "$legacy"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -r '.projects["personal/away"].checkouts | length' "$TRELLIS_HOME_FIX/registry.json")" -eq 0 ]

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" annotate --fleet personal --project away \
    --metadata-json '{"gptx":{"enabled":true}}'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -r '.projects["personal/away"].metadata.gptx.enabled' "$TRELLIS_HOME_FIX/registry.json")" = true ]
}
