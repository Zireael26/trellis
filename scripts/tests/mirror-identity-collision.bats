#!/usr/bin/env bats
# Synthetic registry only: public and private rows share a normalized token.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  SANDBOX="$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/mirror-collision.XXXXXX")"; MIRROR="$SANDBOX/mirror"; mkdir -p "$MIRROR"
  TRELLIS_MIRROR_IDENTITY_SOURCE="$SANDBOX/registry.json"
  export TRELLIS_MIRROR_IDENTITY_SOURCE
  cat > "$TRELLIS_MIRROR_IDENTITY_SOURCE" <<'JSON'
{
  "projects": {
    "example-owner/fixturecollide": {
      "fleet": "example-owner",
      "metadata": {
        "public_identity": true
      },
      "project_id": "fixturecollide"
    },
    "acme/fixturecollide": {
      "fleet": "acme",
      "metadata": {},
      "project_id": "fixturecollide"
    },
    "public/publicfixture": {
      "fleet": "public",
      "metadata": {
        "public_identity": true
      },
      "project_id": "publicfixture"
    },
    "other/anotherfixture": {
      "fleet": "other",
      "metadata": {},
      "project_id": "anotherfixture"
    }
  }
}
JSON
  . "$REPO_ROOT/scripts/lib/mirror-lint.sh"
}

teardown() { [ -z "${SANDBOX:-}" ] || rm -rf "${SANDBOX:?}"; }

@test "a public row cannot exempt a private row sharing its identity token" {
  printf 'publicfixture is deliberately public.\n' > "$MIRROR/public.md"
  run lint_mirror "$MIRROR"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf 'internal: acme/fixturecollide\n' > "$MIRROR/private.md"
  run lint_mirror "$MIRROR"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *'private.md: local fleet project identifier must not publish'* ]] || { echo "$output"; false; }
  [[ "$output" != *'public.md: local fleet project identifier must not publish'* ]] || { echo "$output"; false; }
}
