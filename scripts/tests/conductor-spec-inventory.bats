#!/usr/bin/env bats

ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
CLI="$ROOT/scripts/verify-conductor-spec-inventory.mjs"

make_repo() {
  local name="$1"
  shift
  local repo="$PROJECTS/$name"
  mkdir -p "$repo/specs"
  git -C "$repo" init -q --initial-branch=main
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name test
  local spec
  for spec in "$@"; do
    mkdir -p "$repo/specs/$spec"
    : > "$repo/specs/$spec/spec.md"
  done
  git -C "$repo" add specs
  git -C "$repo" commit -qm "main specs"
}

add_queued_specs() {
  local project="$1"
  local branch="$2"
  shift 2
  local repo="$PROJECTS/$project"
  git -C "$repo" checkout -q -b "$branch"
  local spec
  for spec in "$@"; do
    mkdir -p "$repo/specs/$spec"
    : > "$repo/specs/$spec/spec.md"
  done
  git -C "$repo" add specs
  git -C "$repo" commit -qm "$branch"
  git -C "$repo" checkout -q main
}

write_fixture() {
  mkdir -p "$FIXTURE/control/conductor" "$FIXTURE/control/scheduled-tasks/conductor" "$PROJECTS"
  cat > "$FIXTURE/control/registry.md" <<'EOF'
# Project registry

## Active projects

| Project | Path | Class |
|---|---|---|
| projalpha | `/personal/projalpha` | app |
| projgamma | `/personal/projgamma` | app |
| projbeta | `/personal/projbeta` | app |

---
EOF
  cat > "$FIXTURE/control/conductor/backlog.yml" <<'EOF'
version: 1
projects:
  projalpha:
    repo: personal/projalpha
    tasks:
      - id: ce-brainstorm
  projgamma:
    repo: personal/projgamma
    tasks:
      - id: cb-orchestration-deploy
  projbeta:
    repo: personal/projbeta
    tasks:
      - id: vc-marketing-bot
      - id: vc-demo-videos
EOF
  cat > "$FIXTURE/control/scheduled-tasks/conductor/targets.md" <<'EOF'
| Knob | Default | Meaning |
|---|---|---|
| `auto_spec_top_n` | **0** | rank only |
EOF
}

setup() {
  FIXTURE="$BATS_TEST_TMPDIR/conductor-spec-inventory"
  PROJECTS="$FIXTURE/projects"
  write_fixture

  make_repo projalpha 001-platform 002-audit
  make_repo projgamma 042-runtime
  make_repo projbeta 015-credentials 016-tenants
  add_queued_specs projalpha audit/2026-08-13-specs 003-brand-positioning 004-brand-identity 005-marketing-landing
  add_queued_specs projgamma audit/2026-08-13-specs 043-orchestration-deploy
  add_queued_specs projbeta audit/2026-08-13-specs 017-marketing-bot 018-demo-videos
}

@test "two labelled passes share a digest when the queued inventory is collision-free" {
  run node "$CLI" --root "$FIXTURE/control" --projects-root "$PROJECTS" --date 2026-08-13 --pass pass-1 --queued projalpha=audit/2026-08-13-specs --queued projgamma=audit/2026-08-13-specs --queued projbeta=audit/2026-08-13-specs
  [ "$status" -eq 0 ]
  first="$output"
  first_digest="$(printf '%s' "$first" | jq -r '.inventory_digest')"
  printf '%s' "$first" | jq -e '
    .ok
    and .auto_spec_top_n == 0
    and .auto_spec_disabled
    and .summary.active_projects == 3
    and .summary.queued_spec_ids == 6
    and .summary.duplicate_spec_ids == 0
    and .summary.queued_vs_main_collisions == 0
  ' >/dev/null

  run node "$CLI" --root "$FIXTURE/control" --projects-root "$PROJECTS" --date 2026-08-13 --pass pass-2 --queued projalpha=audit/2026-08-13-specs --queued projgamma=audit/2026-08-13-specs --queued projbeta=audit/2026-08-13-specs
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.inventory_digest')" = "$first_digest" ]
}

@test "a queued ID that reaches main fails the collision gate" {
  mkdir -p "$PROJECTS/projbeta/specs/017-main-reuse"
  : > "$PROJECTS/projbeta/specs/017-main-reuse/spec.md"
  git -C "$PROJECTS/projbeta" add specs
  git -C "$PROJECTS/projbeta" commit -qm "reuse queued ID"

  run node "$CLI" --root "$FIXTURE/control" --projects-root "$PROJECTS" --date 2026-08-13 --pass collision --queued projalpha=audit/2026-08-13-specs --queued projgamma=audit/2026-08-13-specs --queued projbeta=audit/2026-08-13-specs
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '
    (.ok | not)
    and .summary.queued_vs_main_collisions == 1
    and .queued_vs_main_collisions[0] == {
      project: "projbeta",
      id: "17",
      branch: "audit/2026-08-13-specs",
      queued_directory: "017-marketing-bot",
      main_directories: ["017-main-reuse"]
    }
  ' >/dev/null
}

@test "duplicate numeric IDs on main and queued refs fail the gate" {
  mkdir -p "$PROJECTS/projalpha/specs/009-main" "$PROJECTS/projalpha/specs/0009-main"
  : > "$PROJECTS/projalpha/specs/009-main/spec.md"
  : > "$PROJECTS/projalpha/specs/0009-main/spec.md"
  git -C "$PROJECTS/projalpha" add specs
  git -C "$PROJECTS/projalpha" commit -qm "duplicate main IDs"

  git -C "$PROJECTS/projbeta" checkout -q audit/2026-08-13-specs
  mkdir -p "$PROJECTS/projbeta/specs/00017-queued"
  : > "$PROJECTS/projbeta/specs/00017-queued/spec.md"
  git -C "$PROJECTS/projbeta" add specs
  git -C "$PROJECTS/projbeta" commit -qm "duplicate queued ID"
  git -C "$PROJECTS/projbeta" checkout -q main

  run node "$CLI" --root "$FIXTURE/control" --projects-root "$PROJECTS" --date 2026-08-13 --pass duplicates --queued projalpha=audit/2026-08-13-specs --queued projgamma=audit/2026-08-13-specs --queued projbeta=audit/2026-08-13-specs
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '
    .summary.duplicate_spec_ids == 2
    and .duplicates == [
      {
        project: "projalpha",
        source: "main",
        ref: "refs/heads/main",
        id: "9",
        directories: ["0009-main", "009-main"]
      },
      {
        project: "projbeta",
        source: "queued-branch",
        branch: "audit/2026-08-13-specs",
        id: "17",
        directories: ["00017-queued", "017-marketing-bot"]
      }
    ]
  ' >/dev/null
}

@test "every mandatory queued project must be active" {
  cat > "$FIXTURE/control/registry.md" <<'EOF'
# Project registry

## Active projects

| Project | Path | Class |
|---|---|---|
| projalpha | `/personal/projalpha` | app |
| projgamma | `/personal/projgamma` | app |

---
EOF

  run node "$CLI" --root "$FIXTURE/control" --projects-root "$PROJECTS" --date 2026-08-13 --pass missing-queue --queued projalpha=audit/2026-08-13-specs --queued projgamma=audit/2026-08-13-specs --queued projbeta=audit/2026-08-13-specs
  [ "$status" -eq 2 ]
  printf '%s' "$output" | jq -e '.error == "required queued project is not active: projbeta"' >/dev/null
}

@test "auto_spec_top_n must be exactly zero" {
  cat > "$FIXTURE/control/scheduled-tasks/conductor/targets.md" <<'EOF'
| Knob | Default | Meaning |
|---|---|---|
| `auto_spec_top_n` | **1** | writes specs |
EOF

  run node "$CLI" --root "$FIXTURE/control" --projects-root "$PROJECTS" --date 2026-08-13 --pass config --queued projalpha=audit/2026-08-13-specs --queued projgamma=audit/2026-08-13-specs --queued projbeta=audit/2026-08-13-specs
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '(.ok | not) and .auto_spec_top_n == 1 and (.auto_spec_disabled | not)' >/dev/null
}

@test "a project main-ref override inventories a committed repair branch" {
  git -C "$PROJECTS/projalpha" checkout -q -b repair-main
  mkdir -p "$PROJECTS/projalpha/specs/009-repair"
  : > "$PROJECTS/projalpha/specs/009-repair/spec.md"
  git -C "$PROJECTS/projalpha" add specs
  git -C "$PROJECTS/projalpha" commit -qm "repair main"
  git -C "$PROJECTS/projalpha" checkout -q main

  run node "$CLI" --root "$FIXTURE/control" --projects-root "$PROJECTS" --date 2026-08-13 --pass override --main-ref projalpha=refs/heads/repair-main --queued projalpha=audit/2026-08-13-specs --queued projgamma=audit/2026-08-13-specs --queued projbeta=audit/2026-08-13-specs
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .inventory.main_ref_overrides == {projalpha: "refs/heads/repair-main"}
    and (.inventory.projects[] | select(.project == "projalpha") | .main.ref == "refs/heads/repair-main")
    and (.inventory.projects[] | select(.project == "projalpha") | any(.main.spec_ids[]; .directory == "009-repair"))
  ' >/dev/null
}

@test "a main-ref override cannot omit current main commits" {
  git -C "$PROJECTS/projalpha" branch stale-main main
  mkdir -p "$PROJECTS/projalpha/specs/009-current"
  : > "$PROJECTS/projalpha/specs/009-current/spec.md"
  git -C "$PROJECTS/projalpha" add specs
  git -C "$PROJECTS/projalpha" commit -qm "advance main"

  run node "$CLI" --root "$FIXTURE/control" --projects-root "$PROJECTS" --date 2026-08-13 --pass stale --main-ref projalpha=refs/heads/stale-main --queued projalpha=audit/2026-08-13-specs --queued projgamma=audit/2026-08-13-specs --queued projbeta=audit/2026-08-13-specs
  [ "$status" -eq 2 ]
  printf '%s' "$output" | jq -e '.error == "main-ref override must descend from refs/heads/main: projalpha=refs/heads/stale-main"' >/dev/null
}
