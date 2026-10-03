#!/usr/bin/env bash
# Shared fixture for spec 055 Unit 3: a release commit, its packaged payload
# commit, an annotated tag on the payload commit, and a bare release remote
# whose main has advanced past the release commit without ever containing the
# payload commit.
#
# Callers set REPO_ROOT before loading this helper. Every git call runs without
# system or global configuration, so a signing or hooks setting on the host
# cannot change a SHA or run a hook.

PAYLOAD_FIXTURE_TOOL_REL=scripts/release-payload-commit.sh

payload_fixture_git() {
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    git -c user.email=fixture@example.invalid -c user.name='Trellis Fixture' \
    -c commit.gpgsign=false -c tag.gpgSign=false -c core.hooksPath=/dev/null \
    -c init.defaultBranch=main -c advice.detachedHead=false "$@"
}

payload_fixture_tool() {
  (cd "$1" && shift && GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    bash "$REPO_ROOT/$PAYLOAD_FIXTURE_TOOL_REL" "$@")
}

payload_fixture_write() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" > "$1"
}

# payload_fixture_source <dir> <version>
#
# A release source with the exclusion list, one kept file per excluded
# directory's neighbour, and test files the payload must drop. Leaves one
# release commit on main; PAYLOAD_FIXTURE_RELEASE holds its SHA.
payload_fixture_source() {
  local dir="$1" version="$2"
  mkdir -p "$dir"
  payload_fixture_write "$dir/core-rules/VERSION" "$version"
  printf '%s\n' specs/ scripts/tests/ core-rules/hooks/tests/ > "$dir/core-rules/payload-exclude.txt"
  payload_fixture_write "$dir/core-rules/hooks/x.sh" '#!/usr/bin/env bash'
  payload_fixture_write "$dir/core-rules/hooks/tests/x.bats" '@test "x" { true; }'
  payload_fixture_write "$dir/core-rules/hooks/tests/fixtures/data.json" '{}'
  payload_fixture_write "$dir/scripts/tool.sh" '#!/usr/bin/env bash'
  # A stable launcher dispatches to the active payload's scripts/trellis.
  printf '#!/bin/bash\nprintf "fixture dispatcher: %%s\\n" "$*"\n' > "$dir/scripts/trellis"
  chmod 755 "$dir/scripts/trellis"
  payload_fixture_write "$dir/scripts/tests/tool.bats" '@test "tool" { true; }'
  payload_fixture_write "$dir/scripts/tests/web.test.ts" 'test("x", () => {})'
  payload_fixture_write "$dir/specs/001-fixture/spec.md" '# fixture spec'
  payload_fixture_write "$dir/docs/readme.md" '# docs'
  payload_fixture_git -C "$dir" init -q -b main
  payload_fixture_git -C "$dir" add -A
  payload_fixture_git -C "$dir" commit -qm "release $version"
  PAYLOAD_FIXTURE_RELEASE="$(payload_fixture_git -C "$dir" rev-parse HEAD)"
}

# payload_fixture_package <dir>
#
# Builds the payload commit from PAYLOAD_FIXTURE_RELEASE with the shipped tool.
payload_fixture_package() {
  # shellcheck disable=SC2034  # Out-parameter: the suites that load this helper read it.
  PAYLOAD_FIXTURE_PAYLOAD="$(payload_fixture_tool "$1" "$PAYLOAD_FIXTURE_RELEASE")"
}

# payload_fixture_tag <dir> <version> <commit>: annotated v<version> on <commit>.
payload_fixture_tag() {
  payload_fixture_git -C "$1" tag -f -a "v$2" -m "release $2" "$3" >/dev/null
}

# payload_fixture_remote <dir> <remote> <version>
#
# A bare release remote: main at the release commit, then one further commit so
# main has advanced past it; the tag is pushed on its own. The remote's main
# never contains the payload commit.
payload_fixture_remote() {
  local dir="$1" remote="$2" version="$3"
  payload_fixture_git init -q --bare "$remote"
  payload_fixture_git -C "$dir" push -q "$remote" "$PAYLOAD_FIXTURE_RELEASE:refs/heads/main"
  payload_fixture_write "$dir/docs/after-release.md" '# main moved on'
  payload_fixture_git -C "$dir" add -A
  payload_fixture_git -C "$dir" commit -qm 'main after the release'
  payload_fixture_git -C "$dir" push -q "$remote" HEAD:refs/heads/main
  payload_fixture_git -C "$dir" push -q "$remote" "refs/tags/v$version:refs/tags/v$version"
}

# payload_fixture_unfiltered_remote <dir> <remote> <version>: the inversion of
# payload_fixture_remote. The same release commit is tagged directly, the way
# every release up to 1.3.6 was, and published to its own bare remote.
payload_fixture_unfiltered_remote() {
  local dir="$1" remote="$2" version="$3"
  payload_fixture_git init -q --bare "$remote"
  payload_fixture_tag "$dir" "$version" "$PAYLOAD_FIXTURE_RELEASE"
  payload_fixture_git -C "$dir" push -q "$remote" "$PAYLOAD_FIXTURE_RELEASE:refs/heads/main"
  payload_fixture_git -C "$dir" push -q -f "$remote" "refs/tags/v$version:refs/tags/v$version"
}

# payload_fixture_v136 <dest> <path>...: extract files from the released 1.3.6
# tree with `git show v1.3.6:<path>`. Fails, by design, when the tag is absent:
# the old-installer probe (spec 055 A3.4) must run the code 1.3.6 shipped.
payload_fixture_v136() {
  local dest="$1" path
  shift
  git -C "$REPO_ROOT" rev-parse -q --verify 'refs/tags/v1.3.6^{commit}' >/dev/null || {
    echo 'the v1.3.6 release tag is absent from this checkout; fetch it: git fetch origin tag v1.3.6' >&2
    return 1
  }
  for path in "$@"; do
    mkdir -p "$dest/$(dirname "$path")"
    git -C "$REPO_ROOT" show "v1.3.6:$path" > "$dest/$path" || return 1
  done
}

# payload_fixture_excluded_entries <release.json>: tree entries under the
# fixture's listed paths.
payload_fixture_excluded_entries() {
  jq '[.tree[].path | select(startswith("specs/") or startswith("scripts/tests/")
    or startswith("core-rules/hooks/tests/"))] | length' "$1"
}

# payload_fixture_is_record <path>: the records directories, which hold captured
# data rather than code. R3.4's reference scan and R3.8's consumer gate both
# skip exactly this set. The case `*` crosses `/`, so specs/*/receipts/* also
# covers a nested receipts directory such as specs/047-x/web-search/receipts/.
payload_fixture_is_record() {
  case "$1" in
    audits/*|notes/*|research/*|receipts/*|conductor/*|specs/*/receipts/*) return 0 ;;
  esac
  return 1
}

# payload_fixture_origin_main <dir> <commit>: stand in for `git fetch origin main`.
payload_fixture_origin_main() {
  payload_fixture_git -C "$1" update-ref refs/remotes/origin/main "$2"
}
