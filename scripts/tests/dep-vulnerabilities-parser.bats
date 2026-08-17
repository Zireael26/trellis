#!/usr/bin/env bats

ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
PARSER="$ROOT/scheduled-tasks/dep-vulnerabilities/lockfile-parser.mjs"
FIXTURE="$BATS_TEST_DIRNAME/fixtures/dep-vulnerabilities"

@test "npm parser retains nested scoped packages and keeps directness workspace-local" {
  run node "$PARSER" npm \
    --lockfile "$FIXTURE/npm/package-lock.json" \
    --manifest "$FIXTURE/npm/apps/web/package.json" \
    --workspace apps/web
  [ "$status" -eq 0 ]

  printf '%s' "$output" | jq -e '
    .packages as $packages
    | (
      ($packages | length == 9)
      and any($packages[]; .lockfile_path == "apps/web/node_modules/@scope/web-direct" and .package == "@scope/web-direct" and .directness == "direct")
      and any($packages[]; .lockfile_path == "apps/web/node_modules/@scope/web-direct/node_modules/child" and .package == "child" and .directness == "transitive")
      and any($packages[]; .lockfile_path == "node_modules/sibling/node_modules/@scope/nested" and .package == "@scope/nested" and .directness == "transitive")
      and any($packages[]; .lockfile_path == "apps/admin/node_modules/@scope/admin-direct" and .package == "@scope/admin-direct" and .directness == "transitive")
      and any($packages[]; .lockfile_path == "apps/web/node_modules/sibling" and .package == "sibling" and .directness == "direct")
    )
  ' >/dev/null

  run node "$PARSER" npm \
    --lockfile "$FIXTURE/npm/package-lock.json" \
    --manifest "$FIXTURE/npm/apps/admin/package.json" \
    --workspace apps/admin
  [ "$status" -eq 0 ]

  printf '%s' "$output" | jq -e '
    any(.packages[]; .lockfile_path == "apps/admin/node_modules/@scope/admin-direct" and .directness == "direct")
    and any(.packages[]; .lockfile_path == "apps/admin/node_modules/@scope/web-direct" and .package == "@scope/web-direct" and .directness == "transitive")
  ' >/dev/null
}

@test "pnpm parser does not merge direct declarations between sibling importers" {
  run node "$PARSER" pnpm \
    --lockfile "$FIXTURE/pnpm/pnpm-lock.yaml" \
    --workspace apps/web
  [ "$status" -eq 0 ]

  printf '%s' "$output" | jq -e '
    .packages as $packages
    | (
      ($packages | length == 5)
      and any($packages[]; .package == "@scope/shared" and .version == "1.0.0" and .directness == "direct")
      and any($packages[]; .package == "@scope/web-dev" and .version == "3.0.0" and .directness == "direct" and .direct_section == "devDependencies")
      and any($packages[]; .package == "admin-only" and .directness == "transitive")
      and any($packages[]; .package == "nested-child" and .directness == "transitive")
    )
  ' >/dev/null

  run node "$PARSER" pnpm \
    --lockfile "$FIXTURE/pnpm/pnpm-lock.yaml" \
    --workspace apps/admin
  [ "$status" -eq 0 ]

  printf '%s' "$output" | jq -e '
    any(.packages[]; .package == "admin-only" and .directness == "direct")
    and any(.packages[]; .package == "@scope/shared" and .directness == "transitive")
    and any(.packages[]; .package == "web-only" and .directness == "transitive")
  ' >/dev/null
}
