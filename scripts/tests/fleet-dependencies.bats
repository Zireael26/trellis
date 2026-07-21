#!/usr/bin/env bats

ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
FIXTURE="$BATS_TEST_DIRNAME/fixtures/fleet-dependencies"
CLI="$ROOT/scripts/fleet-dependencies.mjs"

setup() {
  FIXTURE_COPY="$BATS_TEST_TMPDIR/fleet"
  cp -R "$FIXTURE" "$FIXTURE_COPY"
}

run_check() {
  run node "$CLI" check \
    --baseline "$FIXTURE_COPY/baseline.json" \
    --registry "$FIXTURE_COPY/registry.md" \
    --blacklist "$FIXTURE_COPY/blacklist.md" \
    --projects-root "$FIXTURE_COPY" \
    --ref worktree \
    --today 2026-07-21 \
    --json
}

@test "npm pnpm Poetry uv aliases and compatible peer ranges pass one baseline" {
  run_check
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq '.findings | length')" -eq 0 ]
}

@test "peer compatibility accepts a matching alternative range" {
  jq '.peerDependencies.react = "^18.0.0 || ^19.0.0"' \
    "$FIXTURE_COPY/repo-a/package.json" > "$FIXTURE_COPY/repo-a/package-next.json"
  mv "$FIXTURE_COPY/repo-a/package-next.json" "$FIXTURE_COPY/repo-a/package.json"
  run_check
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq '.findings | length')" -eq 0 ]
}

@test "all patched brace-expansion branches are checked independently" {
  sed -i.bak 's/brace-expansion@2.1.2/brace-expansion@2.1.1/' "$FIXTURE_COPY/repo-a/pnpm-lock.yaml"
  run_check
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.findings[] | select(.type == "security-floor" and .package == "brace-expansion" and .resolved == "2.1.1" and .minimum == "2.1.2")' >/dev/null
}

@test "expired exceptions fail even when dependency versions match" {
  jq '.exceptions = [{id:"expired",project:"repo-a",workspace:".",ecosystem:"npm",package:"foo",reason:"fixture",owner:"platform",replacement_condition:"remove fixture",expires_on:"2026-07-20"}]' \
    "$FIXTURE_COPY/baseline.json" > "$FIXTURE_COPY/baseline-expired.json"
  mv "$FIXTURE_COPY/baseline-expired.json" "$FIXTURE_COPY/baseline.json"
  run_check
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.findings[] | select(.type == "expired-exception" and .exception == "expired")' >/dev/null
}

@test "snapshot discovers shared direct dependencies across ecosystems" {
  run node "$CLI" snapshot \
    --baseline "$FIXTURE_COPY/baseline.json" \
    --registry "$FIXTURE_COPY/registry.md" \
    --blacklist "$FIXTURE_COPY/blacklist.md" \
    --projects-root "$FIXTURE_COPY" \
    --ref worktree
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.packages[] | select(.ecosystem == "npm" and .name == "foo")' >/dev/null
  printf '%s' "$output" | jq -e '.packages[] | select(.ecosystem == "pypi" and .name == "fastapi")' >/dev/null
}

@test "terminal ledger rows require evidence and risk dispositions require expiry metadata" {
  run node "$CLI" ledger-check --ledger "$FIXTURE_COPY/ledger-valid.json" --today 2026-07-21
  [ "$status" -eq 0 ]

  jq '.findings[0].evidence = [] | .findings[0].disposition = "accepted-risk"' \
    "$FIXTURE_COPY/ledger-valid.json" > "$FIXTURE_COPY/ledger-invalid.json"
  run node "$CLI" ledger-check --ledger "$FIXTURE_COPY/ledger-invalid.json" --today 2026-07-21
  [ "$status" -eq 1 ]
  [[ "$output" == *"terminal disposition requires evidence"* ]]
  [[ "$output" == *"accepted-risk requires owner"* ]]
}

@test "public validator source carries no maintainer-specific absolute path" {
  run rg -n '/Users/'"abhishek" "$CLI"
  [ "$status" -eq 1 ]
}

@test "empty public registry and sanitized bootstrap files validate" {
  cat > "$FIXTURE_COPY/public-registry.md" <<'EOF'
## Active projects

| Project | Path | Class | Notes |
|---|---|---|---|
| _(none yet)_ | | | |

<!--
Example rows — these must remain inert until explicitly uncommented:
| my-app | `__PROJECTS_ROOT__/my-app` | monorepo SaaS | Onboarded YYYY-MM-DD. |
-->
EOF
  cat > "$FIXTURE_COPY/public-blacklist.md" <<'EOF'
| Project | Reason | Added | Review after |
|---|---|---|---|
| — | — | — | — |

| Path | Reason |
|---|---|
| _(none yet)_ | |

<!--
| `__PROJECTS_ROOT__/scratch-tool` | One-off script. |
-->
EOF
  cat > "$FIXTURE_COPY/public-baseline.json" <<'EOF'
{
  "schema_version": 1,
  "policy": {
    "shared_project_minimum": 2,
    "direct_versions": "exact-per-lane",
    "peer_versions": "compatible-range",
    "expired_exceptions": "fail"
  },
  "toolchains": [],
  "packages": [],
  "security_floors": [],
  "exceptions": []
}
EOF
  cat > "$FIXTURE_COPY/public-ledger.json" <<'EOF'
{
  "schema_version": 1,
  "audit_date": "2026-07-21",
  "source_reports": [],
  "findings": []
}
EOF

  run node "$CLI" check \
    --baseline "$FIXTURE_COPY/public-baseline.json" \
    --registry "$FIXTURE_COPY/public-registry.md" \
    --blacklist "$FIXTURE_COPY/public-blacklist.md" \
    --projects-root "$FIXTURE_COPY" \
    --ref worktree \
    --today 2026-07-21 \
    --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq '.projects | length')" -eq 0 ]
  [ "$(printf '%s' "$output" | jq '.findings | length')" -eq 0 ]

  run node "$CLI" ledger-check \
    --ledger "$FIXTURE_COPY/public-ledger.json" \
    --today 2026-07-21
  [ "$status" -eq 0 ]
  [[ "$output" == *"fleet remediation ledger: valid"* ]]
}
