#!/usr/bin/env bats

SOURCE_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

setup() {
  HARNESS_ROOT="$(mktemp -d)"
  mkdir -p "$HARNESS_ROOT/scripts" "$HARNESS_ROOT/core-rules/evals"
  cp "$SOURCE_ROOT/scripts/run-evals.sh" "$HARNESS_ROOT/scripts/run-evals.sh"
  chmod +x "$HARNESS_ROOT/scripts/run-evals.sh"
  write_blacklist
}

teardown() {
  rm -rf "$HARNESS_ROOT"
}

write_registry() {
  {
    printf '%s\n' '# Project registry' '' '## Active projects' ''
    printf '%s\n' '| Project | Path | Class | Notes |' '|---|---|---|---|'
    for project in "$@"; do
      # Backticks in the format string are literal Markdown.
      # shellcheck disable=SC2016
      printf '| %s | `/personal/%s` | app | test |\n' "$project" "$project"
    done
    printf '%s\n' '' '---'
  } > "$HARNESS_ROOT/registry.md"
}

write_blacklist() {
  {
    printf '%s\n' '# Blacklist' '' '## 1. Temporarily excluded (registered projects)' ''
    printf '%s\n' '| Project | Reason | Added | Review after |' '|---|---|---|---|'
    for project in "$@"; do
      printf '| %s | test | 2026-07-14 | 2026-07-15 |\n' "$project"
    done
    printf '%s\n' '' '## 2. Permanently excluded from management' ''
    printf '%s\n' '| Path | Reason |' '|---|---|'
  } > "$HARNESS_ROOT/blacklist.md"
}

write_public_controls() {
  cat > "$HARNESS_ROOT/registry.md" <<'EOF'
# Project registry

Projects under the Trellis process regime. Opt-in list. A project is "active" for process purposes if and only if it appears here and is **not** listed in `blacklist.md`.

This registry is also the input for any private operator audits you configure; no audit schedule ships in the public template.

> **Template note:** this file ships empty. As you onboard projects (see [`engineering-process.md` §10](engineering-process.md#10-onboarding-a-new-project-full-playbook)), append rows below.

---

## Active projects

| Project | Path | Class | Notes |
|---|---|---|---|
| _(none yet)_ | | | |

<!--
Example rows — uncomment and edit when you onboard projects:

| my-app           | `__PROJECTS_ROOT__/my-app`           | monorepo SaaS       | Onboarded YYYY-MM-DD. |
| my-marketing-site| `__PROJECTS_ROOT__/my-marketing-site`| single Next.js app  | Onboarded YYYY-MM-DD. |
| my-game          | `__PROJECTS_ROOT__/my-game`          | game (Unity, 3D)    | Onboarded YYYY-MM-DD. Native git hooks via `.githooks/` — see `core-rules/inheritance.md`. |
-->

---

## Not in the registry (intentionally)

Everything else under your personal projects root is outside this regime. Reasons vary — archived, experiment, client-owned, or just too small to benefit from the hook stack. If one of them becomes active enough to matter, add a row here.

---

## How to add a project

Full playbook: [`engineering-process.md` §10](engineering-process.md#10-onboarding-a-new-project-full-playbook). That is the single source of truth for onboarding steps — keep them there, not here. Registry-local steps only:

1. Add a row to the "Active projects" table above with `Path` and `Class`.
2. Commit in `trellis-instance/` with `chore: register <name>`.
3. If private operator audits are configured, the project becomes eligible under that operator's own cadence.

## How to remove a project

Move it to `blacklist.md` with a reason. Operator checks should skip it. Don't delete the row — we want the history of "this project was active once."
EOF

  cat > "$HARNESS_ROOT/blacklist.md" <<'EOF'
# Blacklist

Two scopes, both excluded from registry-driven operator checks.

> **Template note:** this file ships empty. Add entries as you decide which projects to pause or permanently exclude.

## 1. Temporarily excluded (registered projects)

Projects listed in `registry.md` that should be **temporarily** excluded from centralized process checks. Every entry needs a **reason** and a **review-after** date.

| Project | Reason | Added | Review after |
|---|---|---|---|
| — | — | — | — |

*(empty)*

## 2. Permanently excluded from management

Git repos under `__PROJECTS_ROOT__/` that should **never** be onboarded to Trellis. Operator checks that scan the filesystem should skip these paths.

If any row becomes an active project, move it to `registry.md` (step 1 of onboarding).

| Path | Reason |
|---|---|
| _(none yet)_ | |

<!--
Example rows — uncomment as you blacklist things:

| `__PROJECTS_ROOT__/scratch-tool` | One-off script, not a managed app.       |
| `__PROJECTS_ROOT__/old-experiment`| Dormant; kept locally but not maintained.|
-->

---

## Semantics

- **Temporarily excluded** (section 1) — for projects that ARE in `registry.md` but need a time-bound pause (refactor freeze, bootstrap period, noisy-audit window). Reason + review-after required.
- **Permanently excluded** (section 2) — for git repos that are NOT in `registry.md` and never will be unless explicitly moved. No review-after needed.
- Registry-driven operator checks should read both sections: a project participates iff it is in `registry.md` AND not in either blacklist section. Filesystem checks should skip every path listed in section 2.
- Temporary entries older than 90 days trigger a prompt to make them permanent or lift them.
EOF
}

write_fixture() {
  project="$1"
  fixture="$HARNESS_ROOT/core-rules/evals/$project/smoke"
  mkdir -p "$fixture"
  cat > "$fixture/manifest.yml" <<EOF
version: 1
id: smoke
project: $project
prompt: Create SMOKE.md.
EOF
  printf '%s\n' '{"assertions": []}' > "$fixture/expected.json"
}

run_mode() {
  local mode="$1"
  run bash "$HARNESS_ROOT/scripts/run-evals.sh" "--$mode"
}

@test "check and dry-run allow the shipped placeholder-only public controls without private evals" {
  write_public_controls
  rm -rf "$HARNESS_ROOT/core-rules/evals"

  for mode in check dry-run; do
    run_mode "$mode"

    [ "$status" -eq 0 ]
    [[ "$output" == *"no fixtures matched"* ]]
  done
}

@test "check and dry-run fail closed when public control files are absent" {
  rm -f "$HARNESS_ROOT/registry.md" "$HARNESS_ROOT/blacklist.md"
  rm -rf "$HARNESS_ROOT/core-rules/evals"

  for mode in check dry-run; do
    run_mode "$mode"

    [ "$status" -eq 4 ]
    [[ "$output" == *"registry is missing"* ]]
  done
}

@test "check and dry-run fail closed when a public control file is empty" {
  rm -rf "$HARNESS_ROOT/core-rules/evals"

  for control in registry blacklist; do
    write_public_controls
    : > "$HARNESS_ROOT/$control.md"

    for mode in check dry-run; do
      run_mode "$mode"

      [ "$status" -eq 4 ]
      [[ "$output" == *"$control"* ]]
      [[ "$output" == *"placeholder-only structure"* ]]
    done
  done
}

@test "check and dry-run fail closed when public controls are truncated or malformed" {
  rm -rf "$HARNESS_ROOT/core-rules/evals"

  for mode in check dry-run; do
    write_public_controls
    printf '%s\n' '# Project registry' '' '## Active projects' > "$HARNESS_ROOT/registry.md"

    run_mode "$mode"

    [ "$status" -eq 4 ]
    [[ "$output" == *"registry"* ]]
    [[ "$output" == *"placeholder-only structure"* ]]

    write_public_controls
    cat > "$HARNESS_ROOT/blacklist.md" <<'EOF'
# Blacklist

## 1. Temporarily excluded (registered projects)

| Project | Reason |
|---|---|
| — | — |

## 2. Permanently excluded from management

| Path |
|---|
| _(none yet)_ |
EOF

    run_mode "$mode"

    [ "$status" -eq 4 ]
    [[ "$output" == *"blacklist"* ]]
    [[ "$output" == *"placeholder-only structure"* ]]
  done
}

@test "check and dry-run fail closed when nonempty private controls have no eval root" {
  write_registry alpha
  rm -rf "$HARNESS_ROOT/core-rules/evals"

  for mode in check dry-run; do
    run_mode "$mode"

    [ "$status" -eq 4 ]
    [[ "$output" == *"eval fixture root"* ]]
  done
}

@test "check and dry-run fail closed when private inputs are partial" {
  write_registry alpha
  rm -f "$HARNESS_ROOT/blacklist.md"
  rm -rf "$HARNESS_ROOT/core-rules/evals"

  for mode in check dry-run; do
    run_mode "$mode"

    [ "$status" -eq 4 ]
    [[ "$output" == *"blacklist"* ]]
  done
}

@test "check and dry-run fail when an active registry project has no eval fixture manifest" {
  write_registry beta
  mkdir -p "$HARNESS_ROOT/core-rules/evals/beta"

  for mode in check dry-run; do
    run_mode "$mode"

    [ "$status" -eq 4 ]
    [[ "$output" == *"beta"* ]]
    [[ "$output" == *"missing eval fixture"* ]]
  done
}

@test "check and dry-run validate a complete private fixture set" {
  write_registry alpha beta
  write_blacklist beta
  write_fixture alpha

  for mode in check dry-run; do
    run_mode "$mode"

    [ "$status" -eq 0 ]
    [[ "$output" == *"1 fixture(s) valid"* ]]
    if [ "$mode" = "dry-run" ]; then
      [[ "$output" == *"would run:"* ]]
    fi
  done
}
