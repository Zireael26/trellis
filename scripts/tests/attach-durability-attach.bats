#!/usr/bin/env bats
# Spec 044 WS-B (attach durability), attach-side coverage.
# One case per WS-B item: B1 (R3.1) x2, B2 (R3.2/R3.3) x2, B3 (R5.1),
# B4 (R5.2), B5 (R6.1), B6 (R6.2), B8 (R4.1 docs).
# Fixtures use temp --home only; never the real home.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
ATTACH="$REPO_ROOT/scripts/attach-project.sh"
ATTACH_LIB="$REPO_ROOT/scripts/lib/attachment.sh"
HEALTH_LIB="$REPO_ROOT/scripts/lib/health-checks.sh"
load helpers/release-fixture

sha256_file() {
  shasum -a 256 "$1" | cut -d ' ' -f 1
}

file_mode() {
  local candidate
  candidate="$(stat -f %Lp "$1" 2>/dev/null)" || candidate=""
  case "$candidate" in
    ''|*[!0-7]*) candidate="" ;;
  esac
  if [ -z "$candidate" ]; then
    candidate="$(stat -c %a "$1" 2>/dev/null)" || return 1
  fi
  printf '%s\n' "$candidate"
}

canonical_dir() {
  (CDPATH= cd "$1" && pwd -P)
}

# make_release <version> [source_root]: with a source root, a complete release
# of that source, carrying its own templates and its own scripts (the dispatcher
# generator among them); the seed script stays the fixture's no-op.
make_release() {
  local release="$1" source_root="${2:-$REPO_ROOT}" repo="$SANDBOX/release-source-$1"
  mkdir -p "$repo/core-rules/commands/templates" "$repo/core-rules/templates" \
    "$repo/core-rules/husky" "$repo/core-rules/githooks" "$repo/scripts"
  printf '# fixture policy\n' > "$repo/core-rules/CLAUDE.md"
  printf '# generated primer index\n' > "$repo/core-rules/commands/templates/primer-index-template.md"
  # The contextual SessionStart renders are validated against the real shipped
  # templates by path, so the fixture release carries the real bytes.
  cp "$source_root/core-rules/templates/claude-settings.local.json" \
    "$repo/core-rules/templates/claude-settings.local.json"
  cp "$source_root/core-rules/templates/codex-hooks.local.json" \
    "$repo/core-rules/templates/codex-hooks.local.json"
  if [ "$#" -ge 2 ]; then
    rsync -a --exclude /tests --exclude /seed-inheritance-symlinks.sh "$source_root/scripts/" "$repo/scripts/"
  fi
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/core-rules/husky/pre-push"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/core-rules/githooks/pre-push"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/scripts/seed-inheritance-symlinks.sh"
  chmod 755 "$repo/core-rules/husky/pre-push" "$repo/core-rules/githooks/pre-push" "$repo/scripts/seed-inheritance-symlinks.sh"
  cat > "$repo/core-rules/inheritance-manifest.json" <<'JSON'
{
  "schema_version": 1,
  "harnesses": {
    "claude": {
      "links": [
        {"source": "core-rules/CLAUDE.md", "destination": ".claude/rules/trellis.md"}
      ],
      "render": [
        {"template": "core-rules/commands/templates/primer-index-template.md", "destination": ".claude/primers/INDEX.md", "merge": "replace", "mode": "0644", "required": true},
        {"template": "core-rules/templates/claude-settings.local.json", "destination": ".claude/settings.local.json", "merge": "explicit-json", "mode": "0600", "required": true}
      ]
    },
    "codex": {
      "links": [
        {"source": "core-rules/CLAUDE.md", "destination": ".agents/rules/trellis.md"}
      ],
      "render": [
        {"template": "core-rules/templates/codex-hooks.local.json", "destination": ".codex/hooks.json", "merge": "explicit-json", "mode": "0600", "required": true}
      ]
    }
  }
}
JSON
  printf '%s\n' "$release" > "$repo/core-rules/VERSION"
  # scripts/release.sh refuses pathname execution, so the fixture release is
  # sealed and installed through the bootstrap launcher instead.
  release_fixture_install "$HOME" "$TRELLIS_HOME" "$release" "$repo"
}

make_project() {
  PROJECT="$SANDBOX/project with spaces"
  mkdir -p "$PROJECT"
  git init -q "$PROJECT"
  printf '{"schema_version":1,"project_id":"fixture-project"}\n' > "$PROJECT/.trellis.json"
  git -C "$PROJECT" add .trellis.json
  git -C "$PROJECT" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm initial
}

owner_for_root() {
  local root="$1" owner
  while IFS= read -r owner; do
    [ "$(jq -r '.worktree_root' "$owner")" = "$root" ] && printf '%s\n' "$owner"
  done < <(find "$TRELLIS_HOME/state/attachments" -type f -name '*.json' -print 2>/dev/null)
  return 0
}

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/attach-durability-attach.XXXXXX")"
  SANDBOX="$(canonical_dir "$SANDBOX")"
  export HOME="$SANDBOX/fixture user home"
  export TRELLIS_HOME="$SANDBOX/home"
  mkdir -p "$HOME" "$TRELLIS_HOME"
  export HOME="$(canonical_dir "$HOME")"
  export TRELLIS_HOME="$(canonical_dir "$TRELLIS_HOME")"
  release_fixture_bootstrap "$HOME" "$TRELLIS_HOME" "$SANDBOX"
  make_release 1.2.3
  make_project
  # shellcheck source=../lib/attachment.sh
  source "$ATTACH_LIB"
}

teardown() {
  chmod -R u+w "$SANDBOX" 2>/dev/null || true
  rm -rf "$SANDBOX"
}

run_attach() {
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$@" "$PROJECT"
}

run_detach() {
  run "$ATTACH" detach --home "$TRELLIS_HOME" "$@" "$PROJECT"
}

@test "B1a detach with a missing managed exclude block names path and hashes" {
  run_attach
  [ "$status" -eq 0 ]
  owner="$(owner_for_root "$PROJECT")"
  [ -f "$owner" ]
  expected_block="$(jq -r '.exclude_block_hash' "$owner")"
  [ -n "$expected_block" ]
  exclude="$PROJECT/.git/info/exclude"
  sed "/^# --- Trellis local attachment exclude block ---$/,/^# --- end Trellis local attachment exclude block ---$/d" \
    "$exclude" > "$SANDBOX/exclude-stripped"
  cat "$SANDBOX/exclude-stripped" > "$exclude"
  actual_hash="$(sha256_file "$exclude")"

  run_detach

  [ "$status" -eq 3 ]
  printf '%s\n' "$output" | grep -Fq 'state mismatch'
  printf '%s\n' "$output" | grep -Fq 'state none'
  printf '%s\n' "$output" | grep -Fq -- "$expected_block"
  printf '%s\n' "$output" | grep -Fq -- "$actual_hash"
}

@test "B1b detach with an invalid pending journal names the candidate" {
  run_attach
  [ "$status" -eq 0 ]
  owner="$(owner_for_root "$PROJECT")"
  [ -f "$owner" ]
  checkout="$(jq -r '.checkout_id' "$owner")"
  worktree="$(jq -r '.worktree_id' "$owner")"
  candidate="$TRELLIS_HOME/state/attachment-journals/detach-fake.json"
  jq -cn --arg checkout "$checkout" --arg worktree "$worktree" --arg root "$PROJECT" \
    '{status:"detaching",original_owner:{checkout_id:$checkout,worktree_id:$worktree,worktree_root:$root}}' > "$candidate"
  chmod 644 "$candidate"

  run_detach

  [ "$status" -eq 3 ]
  printf '%s\n' "$output" | grep -Fq 'pending detach journal failed validation'
  printf '%s\n' "$output" | grep -Fq 'detach-fake.json'
}

@test "B2a attach with a dangling PATH entry warns and proceeds" {
  run env TRELLIS_ATTACH_CALLER_PATH="$SANDBOX/missing-bin:$PATH" \
    "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$PROJECT"

  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fq 'skipping PATH entry'
  printf '%s\n' "$output" | grep -Fq -- "$SANDBOX/missing-bin"
  owner="$(owner_for_root "$PROJECT")"
  [ -f "$owner" ]
}

@test "B2b attach canonicalizes a symlinked PATH entry and names it" {
  mkdir -p "$SANDBOX/real/bin" "$SANDBOX/realbin-actual"
  ln -s "$SANDBOX/real" "$SANDBOX/linkreal"
  ln -s "$SANDBOX/realbin-actual" "$SANDBOX/nodelink"
  run env TRELLIS_ATTACH_CALLER_PATH="$SANDBOX/linkreal/bin:$PATH" \
    "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$PROJECT"

  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fq 'canonicalizing PATH entry'
  printf '%s\n' "$output" | grep -Fq -- "$SANDBOX/linkreal/bin"
  printf '%s\n' "$output" | grep -Fq -- "$SANDBOX/real/bin"

  # A default-node-style symlinked dir resolves to its target, on stdout.
  run bash -c "source '$ATTACH_LIB'; _attachment_toolchain_path_resolve '$SANDBOX/nodelink:/usr/bin' 2>/dev/null"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fq -- "$SANDBOX/realbin-actual"

  # A trailing-slash entry is canonicalized, naming the entry and its target.
  run bash -c "source '$ATTACH_LIB'; _attachment_toolchain_path_resolve '/usr/bin/:/usr/bin' 2>&1"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fq 'canonicalizing PATH entry'
  printf '%s\n' "$output" | grep -Fq '/usr/bin/'

  # REGRESSION: macOS ships /System/Cryptexes/App/usr/bin on PATH with App
  # symlinked. Model that ancestor symlink locally, including on Linux.
  mkdir -p "$SANDBOX/System/Cryptexes" "$SANDBOX/preboot/App/usr/bin"
  ln -s "$SANDBOX/preboot/App" "$SANDBOX/System/Cryptexes/App"
  run bash -c "source '$ATTACH_LIB'; _attachment_toolchain_path_resolve '$SANDBOX/System/Cryptexes/App/usr/bin:/usr/bin:/bin' 2>/dev/null"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fq -- "$SANDBOX/preboot/App/usr/bin"
  [[ "$output" != *"$SANDBOX/System/Cryptexes/App/usr/bin"* ]]

  # A real non-directory is still a hard refusal, named.
  : > "$SANDBOX/notadir"
  run bash -c "source '$ATTACH_LIB'; _attachment_toolchain_path_resolve '$SANDBOX/notadir:/usr/bin' 2>&1"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Fq 'not a directory'
  printf '%s\n' "$output" | grep -Fq -- "$SANDBOX/notadir"
}

@test "B1c owned-artifact verification names the artifact that drifted" {
  # REGRESSION: replacing an owned SYMLINK with a regular file made every
  # caller (detach included) refuse with a bare 3 naming nothing. On 2026-09-04
  # that silently pinned the affected consumer to rc.46 and took a bash -x of the whole
  # script to locate among ~200 owned leaves.
  run_attach
  [ "$status" -eq 0 ]
  owner="$(owner_for_root "$PROJECT")"
  [ -f "$owner" ]

  rel="$(jq -r 'first(.artifacts[] | select(.kind == "symlink") | .path) // empty' "$owner")"
  [ -n "$rel" ] || { echo "no owned symlink in the record"; false; }
  link="$PROJECT/$rel"
  [ -L "$link" ]
  rm "$link"
  printf 'not the symlink\n' > "$link"

  run bash -c "source '$ATTACH_LIB'; _attachment_verify_owner_artifacts '$owner' '$TRELLIS_HOME' 2>&1"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Fq 'owned artifact does not match its record'
  printf '%s\n' "$output" | grep -Fq -- "$rel"
  printf '%s\n' "$output" | grep -Fq 'symlink'
}

@test "B1d owned-artifact verification names an owner record whose root is gone" {
  # `registry deregister` deliberately leaves owner records behind as recover
  # evidence, so a removed row's record stays live and refuses `detach
  # --all-worktrees` for its SIBLINGS with a bare 3 that names nothing.
  run_attach
  [ "$status" -eq 0 ]
  owner="$(owner_for_root "$PROJECT")"
  [ -f "$owner" ]

  gone="$SANDBOX/never-existed"
  stale="$SANDBOX/stale-owner.json"
  jq --arg root "$gone" '.worktree_root = $root' "$owner" > "$stale"
  chmod 600 "$stale"

  run bash -c "source '$ATTACH_LIB'; _attachment_verify_owner_artifacts '$stale' '$TRELLIS_HOME' 2>&1"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Fq 'worktree root that no longer exists'
  printf '%s\n' "$output" | grep -Fq -- "$gone"
}

@test "B1e shared-checkout boolean flags survive being false" {
  # REGRESSION: the sibling scan read `.git_hooks.enabled // empty`, and jq's
  # `//` treats `false` as absent -- so the non-hook-owning worktree the scan
  # exists to bless collapsed to empty and fell through to `corrupt`. Measured
  # 2026-09-04 on the live fleet: every secondary worktree in a multi-worktree
  # checkout (two worktrees in one consumer and one in another) reported a phantom `attachment
  # ownership: the required managed hook authority is missing` while its hooks
  # were in fact live -- shared core.hooksPath, executable pre-push. After the
  # fix those rows report `shared`.
  fixture="$SANDBOX/hooks-flag.json"
  printf '{"git_hooks":{"enabled":false}}\n' > "$fixture"

  # The trap, pinned so nobody reintroduces it:
  run bash -c "jq -r '.git_hooks.enabled // empty' '$fixture'"
  [ -z "$output" ]

  # The form the scan must use:
  run bash -c "jq -r 'if (.git_hooks | type) == \"object\" and (.git_hooks | has(\"enabled\")) then (.git_hooks.enabled | tostring) else \"\" end' '$fixture'"
  [ "$output" = false ]

  # A record with no git_hooks at all must still read as empty, not "null".
  printf '{}\n' > "$fixture"
  run bash -c "jq -r 'if (.git_hooks | type) == \"object\" and (.git_hooks | has(\"enabled\")) then (.git_hooks.enabled | tostring) else \"\" end' '$fixture'"
  [ -z "$output" ]

  # The helper both shared-checkout checks now use.
  run bash -c "source '$HEALTH_LIB'; hc_json_bool '{\"f\":false}' f"
  [ "$output" = false ]
  run bash -c "source '$HEALTH_LIB'; hc_json_bool '{\"f\":true}' f"
  [ "$output" = true ]
  run bash -c "source '$HEALTH_LIB'; hc_json_bool '{}' f"
  [ -z "$output" ]
  run bash -c "source '$HEALTH_LIB'; hc_json_bool '{\"f\":\"false\"}' f"
  [ -z "$output" ]   # a STRING "false" is not a boolean

  # The second site of the same trap: the managed-exclude block is owned by one
  # worktree per checkout, so `managed_by_attachment` is false on every other
  # row and collapsed to corrupt exactly like the hook flag did.
  run bash -c "source '$HEALTH_LIB'; hc_json_bool '{\"managed_by_attachment\":false}' managed_by_attachment"
  [ "$output" = false ]

  # And no boolean owner-record flag may still be read through the collapsing
  # form (comment lines, which document the trap, are stripped first).
  run bash -c "sed 's/[[:space:]]*#.*//' '$HEALTH_LIB' | grep -cE '(git_hooks.enabled|managed_by_attachment) // empty'"
  [ "$output" = 0 ] || { echo "collapsing form still in use: $output"; false; }
}

@test "B3 detach to an empty previous hooks path warns UNGATED" {
  run_attach
  [ "$status" -eq 0 ]

  run_detach

  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fq 'UNGATED'
  printf '%s\n' "$output" | grep -Fq -- "$PROJECT"
  [ -z "$(git -C "$PROJECT" config --local --get core.hooksPath 2>/dev/null || true)" ]
}

@test "B4 attach manages hooksPath and refuses a raced hooksPath loudly" {
  run_attach
  [ "$status" -eq 0 ]
  owner="$(owner_for_root "$PROJECT")"
  [ -f "$owner" ]
  managed="$(jq -r '.git_hooks.managed_hooks_path' "$owner")"
  [ -n "$managed" ]
  [ "$(git -C "$PROJECT" config --local --get core.hooksPath)" = "$managed" ]
  [ -x "$managed/pre-push" ]

  git -C "$PROJECT" config --local core.hooksPath "$SANDBOX/rogue-hooks"
  run_attach

  [ "$status" -eq 3 ]
  printf '%s\n' "$output" | grep -Fq 'core.hooksPath'
  printf '%s\n' "$output" | grep -Fq -- "$SANDBOX/rogue-hooks"
  printf '%s\n' "$output" | grep -Fq -- "$managed"
}

@test "B5 rendered dispatcher exports managed XDG dirs" {
  body="$(_attachment_hooks_dispatcher_common_body "$TRELLIS_HOME/releases/1.2.3/payload" "core-rules/githooks/pre-push" "manifest")"
  printf '%s\n' "$body" | grep -Fq 'XDG_CONFIG_HOME'
  printf '%s\n' "$body" | grep -Fq 'XDG_CACHE_HOME'
  printf '%s\n' "$body" | grep -Fq 'COREPACK_HOME'
  printf '%s\n' "$body" | grep -Fq 'trellis-gate-xdg-begin'
  printf '%s\n' "$body" | grep -Fq 'trellis_run_gate_payload'

  gate_home="$SANDBOX/gate-home"
  mkdir -p "$gate_home/state"
  awk '/# trellis-gate-xdg-begin/{f=1;next}/# trellis-gate-xdg-end/{f=0}f' \
    < <(printf '%s\n' "$body") > "$SANDBOX/gate-xdg-block.sh"
  [ -s "$SANDBOX/gate-xdg-block.sh" ]
  run bash -c 'managed_home="'"$gate_home"'"; set -u; HOME=/dev/null; . "'"$SANDBOX"'/gate-xdg-block.sh"; printf "%s\n%s\n%s\n" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$COREPACK_HOME"'
  [ "$status" -eq 0 ]
  config_home="$(printf '%s\n' "$output" | sed -n '1p')"
  cache_home="$(printf '%s\n' "$output" | sed -n '2p')"
  corepack_home="$(printf '%s\n' "$output" | sed -n '3p')"
  case "$config_home" in "$gate_home"/*) ;; *) false ;; esac
  case "$cache_home" in "$gate_home"/*) ;; *) false ;; esac
  case "$corepack_home" in "$cache_home"/*) ;; *) false ;; esac
  [ -d "$config_home" ]
  [ -d "$cache_home" ]
  [ -d "$corepack_home" ]
  [ "$(file_mode "$config_home")" = 700 ]
  [ "$(file_mode "$cache_home")" = 700 ]
}

@test "B6 resolver normalizes the brew anchor ahead of nvm entries" {
  fixture="$SANDBOX/toolchain"
  mkdir -p "$fixture/brew-bin" "$fixture/user-home/.nvm/versions/node/v20/bin" "$fixture/other"
  nvm="$fixture/user-home/.nvm/versions/node/v20/bin"
  run bash -c "source '$ATTACH_LIB'; export TRELLIS_HOMEBREW_BIN='$fixture/brew-bin'; _attachment_toolchain_path_resolve '$nvm:$fixture/other' 2>/dev/null | jq -r 'join(\":\")'"
  [ "$status" -eq 0 ]
  [ "$output" = "$fixture/brew-bin:$nvm:$fixture/other" ]

  run bash -c "source '$ATTACH_LIB'; export TRELLIS_HOMEBREW_BIN='$fixture/brew-bin'; _attachment_toolchain_path_resolve '$nvm:$fixture/brew-bin:$fixture/other' 2>/dev/null | jq -r 'join(\":\")'"
  [ "$status" -eq 0 ]
  [ "$output" = "$fixture/brew-bin:$nvm:$fixture/other" ]

  run bash -c "source '$ATTACH_LIB'; export TRELLIS_HOMEBREW_BIN='$fixture/brew-bin'; _attachment_toolchain_path_resolve '$fixture/brew-bin:$nvm' 2>/dev/null | jq -r 'join(\":\")'"
  [ "$status" -eq 0 ]
  [ "$output" = "$fixture/brew-bin:$nvm" ]

  run bash -c "source '$ATTACH_LIB'; export TRELLIS_HOMEBREW_BIN='$fixture/brew-bin'; _attachment_toolchain_path_resolve '$fixture/other:/usr/bin' 2>/dev/null | jq -r 'join(\":\")'"
  [ "$status" -eq 0 ]
  [ "$output" = "$fixture/other:/usr/bin" ]

  run bash -c "source '$ATTACH_LIB'; export TRELLIS_HOMEBREW_BIN='$fixture/no-such-dir'; _attachment_toolchain_path_resolve '$nvm:$fixture/other' 2>/dev/null | jq -r 'join(\":\")'"
  [ "$status" -eq 0 ]
  [ "$output" = "$nvm:$fixture/other" ]
}

@test "B8 portable inheritance docs preserve the merge_missing add-only contract" {
  run grep -Fq "merge_missing" "$REPO_ROOT/core-rules/inheritance.md"
  [ "$status" -eq 0 ]
  run grep -Fq "add-only" "$REPO_ROOT/core-rules/inheritance.md"
  [ "$status" -eq 0 ]
  run grep -Fq "detach+attach" "$REPO_ROOT/core-rules/inheritance.md"
  [ "$status" -eq 0 ]
}

# Journal v2 (1.3.12) across releases. PRE_V2_COMMIT is the last commit before
# journal v2; its scripts run as the other release of a mixed group. Each side
# is a consistent release: a payload's templates are valid only to its own
# renderer, and its dispatchers are rebuilt by the generator it ships. So the
# pre-v2 release (1.2.2) is built from PRE_V2_COMMIT's core-rules and scripts,
# and this release (1.2.4) from this checkout's.
PRE_V2_COMMIT=bdc21b05

pre_v2_attach_script() {
  git -C "$REPO_ROOT" cat-file -e "$PRE_V2_COMMIT^{commit}" 2>/dev/null ||
    skip "the pre-v2 release ($PRE_V2_COMMIT) is not in this clone's history"
  mkdir "$SANDBOX/pre-v2"
  git -C "$REPO_ROOT" archive "$PRE_V2_COMMIT" scripts core-rules/templates | tar -x -C "$SANDBOX/pre-v2"
  PRE_V2_ATTACH="$SANDBOX/pre-v2/scripts/attach-project.sh"
  make_release 1.2.2 "$SANDBOX/pre-v2"
  make_release 1.2.4 "$REPO_ROOT"
}

run_attach_v2() {
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.4 "$PROJECT"
}

pre_v2_cli() {
  run env -u TRELLIS_LIBS_PRELOADED "$PRE_V2_ATTACH" "$@"
}

assert_detached_clean() {
  [ -z "$(owner_for_root "$PROJECT")" ]
  [ -z "$(find "$TRELLIS_HOME/state/attachment-journals" -name '*.json' -print 2>/dev/null)" ]
  [ -z "$(git -C "$PROJECT" status --porcelain)" ]
  [ ! -e "$PROJECT/.trellis/runtime" ] && [ ! -L "$PROJECT/.trellis/runtime" ]
}

@test "V2a an owner attached by the pre-v2 release detaches under this release" {
  pre_v2_attach_script
  pre_v2_cli attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.2 "$PROJECT"
  [ "$status" -eq 0 ]

  run_detach

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_detached_clean
}

@test "V2b an owner attached by this release detaches under the pre-v2 release" {
  pre_v2_attach_script
  run_attach_v2
  [ "$status" -eq 0 ]

  pre_v2_cli detach --home "$TRELLIS_HOME" "$PROJECT"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_detached_clean
}

@test "V2c this release recovers a pre-v2 attach stopped before commit" {
  pre_v2_attach_script
  ATTACHMENT_FAULT_PHASE=prepared pre_v2_cli attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.2 "$PROJECT"
  [ "$status" -eq 5 ]

  run "$ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_detached_clean
}

@test "V2d the pre-v2 release recovers this release's attach stopped after owner publication" {
  pre_v2_attach_script
  ATTACHMENT_FAULT_PHASE=owner-published run_attach_v2
  [ "$status" -eq 5 ]
  owner="$(owner_for_root "$PROJECT")"
  [ -f "$owner" ]
  # The commit folded its progress log before publishing the owner, so the
  # journal left behind is in the shape every release reads.
  journal="$(find "$TRELLIS_HOME/state/attachment-journals" -name '*.json' -print)"
  jq -e 'has("journal_version") | not' "$journal"
  [ -z "$(find "$TRELLIS_HOME/state/attachment-progress" -type f -print)" ]

  pre_v2_cli recover --home "$TRELLIS_HOME" "$PROJECT"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$journal" ]
  [ -f "$owner" ]
  run_detach
  [ "$status" -eq 0 ]
  assert_detached_clean
}

# The --expected-journal-sha256 digest of a journal v2 (a commit killed
# mid-publish): its bytes and its progress log's, in a fixed framing.
journal_v2_digest() {
  local journal="$1" log="$2" log_sha=none
  [ ! -e "$log" ] || log_sha="$(sha256_file "$log")"
  printf 'trellis-attachment-journal-v2\n%s\n%s\n' "$(sha256_file "$journal")" "$log_sha" | shasum -a 256 | cut -d ' ' -f 1
}

@test "V2e a journal digest taken before progress moved is refused by recover" {
  local journal attachment log program status journal_sha log_sha inspected_log stale_digest current_digest
  ATTACHMENT_FAULT_PHASE=prepared run_attach
  [ "$status" -eq 5 ]
  journal="$(find "$TRELLIS_HOME/state/attachment-journals" -name '*.json' -print)"
  attachment="$(jq -r '.attachment_id' "$journal")"
  log="$TRELLIS_HOME/state/attachment-progress/$attachment.log"
  # A commit killed at its 20th durable step leaves a v2 journal and its log.
  program="$(_attachment_commit_program)"
  program="${program/'    return None  # crash-test seam'/'    checkpoint.calls = getattr(checkpoint, "calls", 0) + 1
    if checkpoint.calls == 20: os.kill(os.getpid(), signal.SIGKILL)'}"
  [ "$program" != "$(_attachment_commit_program)" ]
  _attachment_ensure_private_dir "$TRELLIS_HOME/state/attachment-progress"
  _attachment_ensure_private_dir "$SANDBOX/holder"
  status=0
  python3 -I -c "$program" "$journal" "$log" "" "$SANDBOX/holder" "$BASHPID" || status=$?
  [ "$status" -eq 137 ]
  jq -e '.journal_version == 2' "$journal"
  [ "$(wc -l < "$log")" -gt 3 ]
  journal_sha="$(sha256_file "$journal")"
  log_sha="$(sha256_file "$log")"
  # An operator inspected this transaction three log records earlier: the
  # journal file was the same bytes, the log a prefix of today's.
  inspected_log="$SANDBOX/inspected.log"
  head -n 3 "$log" > "$inspected_log"
  stale_digest="$(journal_v2_digest "$journal" "$inspected_log")"

  run "$ATTACH" recover --home "$TRELLIS_HOME" --expected-journal-sha256 "$journal_sha" "$PROJECT"
  [ "$status" -eq 3 ] || { echo "journal-only digest: $status $output"; false; }
  run "$ATTACH" recover --home "$TRELLIS_HOME" --expected-journal-sha256 "$stale_digest" "$PROJECT"
  [ "$status" -eq 3 ] || { echo "stale digest: $status $output"; false; }
  [[ "$output" == *"expected attachment journal changed"* ]] || { echo "$output"; false; }
  [ "$(sha256_file "$journal")" = "$journal_sha" ]
  [ "$(sha256_file "$log")" = "$log_sha" ]

  current_digest="$(journal_v2_digest "$journal" "$log")"
  run "$ATTACH" recover --home "$TRELLIS_HOME" --expected-journal-sha256 "$current_digest" "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_detached_clean
  [ ! -e "$log" ]
}
