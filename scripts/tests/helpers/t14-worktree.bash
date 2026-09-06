#!/usr/bin/env bash
# Shared isolated fixture for Spec 036 T14 worktree tests.
# Callers set REPO_ROOT before loading this helper.

t14_canonical_dir() {
  (CDPATH='' cd "$1" && pwd -P)
}

t14_sha256_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | cut -d ' ' -f 1
  else
    printf '%s' "$1" | sha256sum | cut -d ' ' -f 1
  fi
}

t14_setup_sandbox() {
  T14_SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/trellis-t14.XXXXXX")"
  T14_SANDBOX="$(t14_canonical_dir "$T14_SANDBOX")"
  export TRELLIS_HOME="$T14_SANDBOX/trellis home"
  mkdir -p "$TRELLIS_HOME"
  chmod 700 "$TRELLIS_HOME"
  T14_RELEASE="1.2.3"
}

t14_teardown_sandbox() {
  if [ -n "${T14_SANDBOX:-}" ] && [ -d "$T14_SANDBOX" ]; then
    chmod -R u+w "$T14_SANDBOX" 2>/dev/null || true
    rm -rf "$T14_SANDBOX"
  fi
}

t14_make_runtime_release() {
  local version="${1:-$T14_RELEASE}" repo="$T14_SANDBOX/release source"
  mkdir -p "$repo/scripts" "$repo/core-rules/husky" "$repo/core-rules/githooks"
  cp "$REPO_ROOT/scripts/attach-project.sh" "$repo/scripts/attach-project.sh"
  cp "$REPO_ROOT/scripts/trellis-launcher.sh" "$repo/scripts/trellis-launcher.sh"
  cp "$REPO_ROOT/scripts/seed-inheritance-symlinks.sh" "$repo/scripts/seed-inheritance-symlinks.sh"
  cp -R "$REPO_ROOT/scripts/lib" "$repo/scripts/lib"
  chmod +x "$repo/scripts/attach-project.sh" "$repo/scripts/seed-inheritance-symlinks.sh"
  printf '# fixture policy\n' > "$repo/core-rules/CLAUDE.md"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/core-rules/husky/pre-push"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/core-rules/githooks/pre-push"
  chmod 755 "$repo/core-rules/husky/pre-push" "$repo/core-rules/githooks/pre-push"
  printf '%s\n' "$version" > "$repo/core-rules/VERSION"
  cat > "$repo/core-rules/inheritance-manifest.json" <<'JSON'
{
  "schema_version": 1,
  "harnesses": {
    "claude": {
      "links": [
        {"source": "core-rules/CLAUDE.md", "destination": ".claude/rules/trellis.md"}
      ],
      "render": []
    },
    "codex": {
      "links": [
        {"source": "core-rules/CLAUDE.md", "destination": ".agents/rules/trellis.md"}
      ],
      "render": []
    }
  }
}
JSON
  (
    cd "$repo" || exit 1
    git init -q
    git config user.email fixture@example.invalid
    git config user.name 'T14 Fixture'
    git config commit.gpgsign false
    git config tag.gpgSign false
    git add -A
    git commit -qm "release $version"
    git tag -a "v$version" -m "release $version"
  )
  TRELLIS_HOME="$TRELLIS_HOME" bash -c \
    '. "$1"; release_store_install "$2" "$3" "" >/dev/null' \
    t14-release-bootstrap "$REPO_ROOT/scripts/lib/release-store.sh" "$version" "$repo"
}

t14_make_project() {
  T14_PROJECT="${1:-$T14_SANDBOX/project with spaces}"
  mkdir -p "$T14_PROJECT"
  git init -q "$T14_PROJECT"
  git -C "$T14_PROJECT" config user.email fixture@example.invalid
  git -C "$T14_PROJECT" config user.name 'T14 Fixture'
  git -C "$T14_PROJECT" config commit.gpgsign false
  printf '{"schema_version":1,"project_id":"fixture-project"}\n' > "$T14_PROJECT/.trellis.json"
  printf 'fixture\n' > "$T14_PROJECT/README.md"
  git -C "$T14_PROJECT" add .trellis.json README.md
  git -C "$T14_PROJECT" commit -qm initial
}

t14_attach() {
  local target="${1:-$T14_PROJECT}"
  env TRELLIS_HOME="$TRELLIS_HOME" bash "$REPO_ROOT/scripts/attach-project.sh" attach \
    --home "$TRELLIS_HOME" --fleet personal --release "$T14_RELEASE" "$target"
}

t14_detach() {
  local target="${1:-$T14_PROJECT}"
  env TRELLIS_HOME="$TRELLIS_HOME" bash "$REPO_ROOT/scripts/attach-project.sh" detach \
    --home "$TRELLIS_HOME" "$target"
}

t14_owner_for_root() {
  local root owner canonical
  root="$1"
  canonical="$(t14_canonical_dir "$root")"
  while IFS= read -r owner; do
    [ -n "$owner" ] || continue
    if [ "$(jq -r '.worktree_root' "$owner")" = "$canonical" ]; then
      printf '%s\n' "$owner"
      return 0
    fi
  done < <(find "$TRELLIS_HOME/state/attachments" -type f -name '*.json' -print 2>/dev/null)
  return 1
}

t14_checkout_id() {
  local root common
  root="$1"
  common="$(git -C "$root" rev-parse --git-common-dir)"
  case "$common" in
    /*) ;;
    *) common="$root/$common" ;;
  esac
  common="$(t14_canonical_dir "$common")"
  t14_sha256_text "$common"
}
