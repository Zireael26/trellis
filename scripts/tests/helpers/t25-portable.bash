#!/usr/bin/env bash
# Shared isolated fixture for Spec 036 T25 attachment and inert-contributor tests.
# Callers set REPO_ROOT before loading this helper.

t25_canonical_dir() {
  (CDPATH='' cd "$1" && pwd -P)
}

t25_sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d ' ' -f 1
  else
    sha256sum "$1" | cut -d ' ' -f 1
  fi
}

t25_sha256_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | cut -d ' ' -f 1
  else
    printf '%s' "$1" | sha256sum | cut -d ' ' -f 1
  fi
}

# GNU `stat -f` is --file-system, so it prints a whole filesystem block on
# stdout before failing on the format operand. Chained in one substitution that
# block concatenates with the GNU mode and every mode assertion reads garbage.
# Probe BSD first, shape-check the answer, and fall back in a SEPARATE capture.
t25_mode() {
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

t25_git() {
  HOME="$T25_USER_HOME" GIT_CONFIG_NOSYSTEM=1 git "$@"
}

t25_git_status() {
  t25_git -C "$1" status --porcelain=v1 --untracked-files=all
}

t25_snapshot_tree() {
  local root="$1" output="$2" entry

  if [ ! -e "$root" ] && [ ! -L "$root" ]; then
    printf 'absent\n' > "$output"
    return 0
  fi
  [ -d "$root" ] && [ ! -L "$root" ] || return 1

  (
    cd "$root" || exit 1
    find . -print | LC_ALL=C sort | while IFS= read -r entry; do
      if [ -L "$entry" ]; then
        printf 'link\t%s\t%s\n' "$entry" "$(readlink "$entry")"
      elif [ -f "$entry" ]; then
        printf 'file\t%s\t%s\t%s\n' "$entry" "$(t25_mode "$entry")" "$(t25_sha256_file "$entry")"
      elif [ -d "$entry" ]; then
        printf 'directory\t%s\t%s\n' "$entry" "$(t25_mode "$entry")"
      else
        printf 'other\t%s\n' "$entry"
      fi
    done
  ) > "$output"
}

# Same snapshot with the named entries projected out, for the paths a rolled-back
# or inverted transaction is allowed to leave changed: the machine registry row,
# the hardened mode of the local exclude file, and the harness parent
# directories detach currently retains.  Every projected path is asserted
# separately by the caller.
t25_snapshot_tree_without() {
  local root="$1" output="$2" full="$2.full" skiplist="$2.skip"

  shift 2
  printf '%s\n' "$@" > "$skiplist"
  t25_snapshot_tree "$root" "$full" || return 1
  awk -F '\t' 'NR == FNR { skip[$0] = 1; next } !($2 in skip)' "$skiplist" "$full" > "$output"
}

t25_directory_is_empty() {
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  [ -z "$(ls -A "$1")" ]
}

t25_snapshot_optional_file() {
  local path="$1" output="$2"

  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    printf 'absent\n' > "$output"
    return 0
  fi
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  printf 'file\t%s\t%s\n' "$(t25_mode "$path")" "$(t25_sha256_file "$path")" > "$output"
}

t25_path_absent() {
  [ ! -e "$1" ] && [ ! -L "$1" ]
}

t25_checkout_id() {
  local root="$1" common

  common="$(t25_git -C "$root" rev-parse --git-common-dir)" || return 1
  case "$common" in
    /*) ;;
    *) common="$root/$common" ;;
  esac
  common="$(t25_canonical_dir "$common")" || return 1
  t25_sha256_text "$common"
}

t25_worktree_id() {
  t25_sha256_text "$(t25_canonical_dir "$1")"
}

t25_owner_path() {
  local root="$1"
  printf '%s/state/attachments/%s/%s.json\n' \
    "$T25_TRELLIS_HOME" "$(t25_checkout_id "$root")" "$(t25_worktree_id "$root")"
}

t25_journal_files() {
  find "$T25_TRELLIS_HOME/state/attachment-journals" -type f -name '*.json' -print 2>/dev/null
}

# Everything under this checkout's private attachment directory, whatever it is
# called and whatever type it is.  `t25_owner_path` names only the ONE filename
# a correct attach would have written; a rollback that left a differently named
# receipt, a temp file it failed to unlink, or a symlink would satisfy that check
# and still be a leak.  The directory is pre-created by `t25_warm_machine_state`
# because a refusing command creates it too, so this is where that warming is
# paid for: warming hides the directory, this asserts it stayed empty.
t25_attachment_dir_entries() {
  local directory
  directory="$T25_TRELLIS_HOME/state/attachments/$(t25_checkout_id "$1")" || return 1
  [ -d "$directory" ] || return 0
  find "$directory" -mindepth 1 -print 2>/dev/null
}

t25_attachment_state_absent() {
  t25_path_absent "$(t25_owner_path "$1")" || return 1
  [ -z "$(t25_attachment_dir_entries "$1")" ] || return 1
  [ -z "$(t25_journal_files)" ]
}

t25_attachment_env() (
  unset TRELLIS_ROOT TRELLIS_RELEASE TRELLIS_FLEET TRELLIS_CONFIG
  HOME="$T25_USER_HOME"
  TRELLIS_HOME="$T25_TRELLIS_HOME"
  GIT_CONFIG_NOSYSTEM=1
  export HOME TRELLIS_HOME GIT_CONFIG_NOSYSTEM
  "$@"
)

t25_inert_env() (
  unset TRELLIS_ROOT TRELLIS_RELEASE TRELLIS_FLEET TRELLIS_CONFIG
  HOME="$T25_USER_HOME"
  TRELLIS_HOME="$T25_TRELLIS_HOME"
  GIT_CONFIG_NOSYSTEM=1
  export HOME TRELLIS_HOME GIT_CONFIG_NOSYSTEM
  "$@"
)

# shellcheck disable=SC2120  # the version argument is optional by design; every
# caller so far takes the default.
t25_make_immutable_release() {
  local version="${1:-$T25_RELEASE}" repo="$T25_SANDBOX/release source"

  mkdir -p "$repo/scripts" "$repo/core-rules/templates" "$repo/core-rules/githooks"
  cp "$REPO_ROOT/scripts/seed-inheritance-symlinks.sh" "$repo/scripts/seed-inheritance-symlinks.sh"
  chmod 755 "$repo/scripts/seed-inheritance-symlinks.sh"
  printf '# fixture policy\n' > "$repo/core-rules/CLAUDE.md"
  printf '%s\n' "$version" > "$repo/core-rules/VERSION"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/core-rules/githooks/pre-push"
  chmod 755 "$repo/core-rules/githooks/pre-push"
  # The contextual SessionStart renders are validated against the real shipped
  # templates by path, so the fixture release carries the real bytes.
  cp "$REPO_ROOT/core-rules/templates/claude-settings.local.json" \
    "$repo/core-rules/templates/claude-settings.local.json"
  cp "$REPO_ROOT/core-rules/templates/codex-hooks.local.json" \
    "$repo/core-rules/templates/codex-hooks.local.json"
  printf '# fixture OMP preamble\n' > "$repo/core-rules/templates/omp-preamble.md"
  cat > "$repo/core-rules/inheritance-manifest.json" <<'JSON'
{
  "schema_version": 1,
  "harnesses": {
    "claude": {
      "links": [
        {"source": "core-rules/CLAUDE.md", "destination": ".claude/rules/trellis.md"}
      ],
      "render": [
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
    },
    "omp": {
      "links": [
        {"source": "core-rules/CLAUDE.md", "destination": ".omp/AGENTS.md"}
      ],
      "render": [
        {"template": "core-rules/templates/omp-preamble.md", "destination": ".omp/PREAMBLE.md", "merge": "replace", "mode": "0644", "required": true}
      ]
    }
  }
}
JSON

  release_fixture_install "$T25_USER_HOME" "$T25_TRELLIS_HOME" "$version" "$repo"
  T25_PAYLOAD="$T25_TRELLIS_HOME/releases/$version/payload"
  T25_MANIFEST="$T25_PAYLOAD/core-rules/inheritance-manifest.json"
}

t25_make_attachment_project() {
  T25_PROJECT="$T25_SANDBOX/project with spaces"
  mkdir -p \
    "$T25_PROJECT/.claude" \
    "$T25_PROJECT/.agents" \
    "$T25_PROJECT/.codex" \
    "$T25_PROJECT/.omp" \
    "$T25_PROJECT/.project-hooks"
  t25_git init -q "$T25_PROJECT"
  t25_git -C "$T25_PROJECT" config user.email fixture@example.invalid
  t25_git -C "$T25_PROJECT" config user.name 'T25 Fixture'
  t25_git -C "$T25_PROJECT" config commit.gpgsign false

  printf '{"schema_version":1,"project_id":"t25-fixture-project"}\n' > "$T25_PROJECT/.trellis.json"
  printf 'fixture project\n' > "$T25_PROJECT/README.md"
  cat > "$T25_PROJECT/.gitignore" <<'EOF'
.trellis/
.claude/rules/
.agents/rules/
.omp/AGENTS.md
.claude/settings.local.json
.codex/hooks.json
EOF
  cat > "$T25_PROJECT/.claude/settings.local.json" <<'JSON'
{
  "project": {
    "claude": "keep"
  }
}
JSON
  cat > "$T25_PROJECT/.codex/hooks.json" <<'JSON'
{
  "project": {
    "codex": "keep"
  }
}
JSON
  printf 'claude native sibling\n' > "$T25_PROJECT/.claude/project-native.md"
  printf 'codex native sibling\n' > "$T25_PROJECT/.agents/project-native.md"
  printf 'codex config sibling\n' > "$T25_PROJECT/.codex/project-native.txt"
  printf 'omp native sibling\n' > "$T25_PROJECT/.omp/project-native.md"
  cat > "$T25_PROJECT/.project-hooks/post-checkout" <<'EOF'
#!/usr/bin/env bash
printf 'project post-checkout\n' >&2
EOF
  chmod 640 "$T25_PROJECT/.claude/settings.local.json" "$T25_PROJECT/.codex/hooks.json"
  chmod 640 "$T25_PROJECT/.claude/project-native.md" "$T25_PROJECT/.agents/project-native.md" \
    "$T25_PROJECT/.codex/project-native.txt" "$T25_PROJECT/.omp/project-native.md"
  chmod 700 "$T25_PROJECT/.project-hooks/post-checkout"

  t25_git -C "$T25_PROJECT" add .trellis.json README.md .gitignore \
    .claude/project-native.md .agents/project-native.md .codex/project-native.txt \
    .omp/project-native.md .project-hooks/post-checkout
  t25_git -C "$T25_PROJECT" -c core.hooksPath=/dev/null commit -qm 'fixture project'

  T25_EXCLUDE="$T25_PROJECT/.git/info/exclude"
  printf '# project-owned exclude sentinel\n*.project-local\n' > "$T25_EXCLUDE"
  chmod 640 "$T25_EXCLUDE"
  t25_git -C "$T25_PROJECT" config --local core.hooksPath .project-hooks
}

t25_setup_attachment_fixture() {
  T25_SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/trellis-t25.XXXXXX")"
  T25_SANDBOX="$(t25_canonical_dir "$T25_SANDBOX")"
  T25_USER_HOME="$T25_SANDBOX/isolated home"
  T25_TRELLIS_HOME="$T25_USER_HOME/.trellis"
  T25_RELEASE=1.2.3
  mkdir -p "$T25_USER_HOME" "$T25_TRELLIS_HOME"
  chmod 700 "$T25_USER_HOME" "$T25_TRELLIS_HOME"
  release_fixture_bootstrap "$T25_USER_HOME" "$T25_TRELLIS_HOME" "$T25_SANDBOX"
  # shellcheck disable=SC2034  # Out-parameter: the suites that source this helper read it.
  T25_LAUNCHER="$RELEASE_FIXTURE_LAUNCHER"
  t25_make_immutable_release
  t25_make_attachment_project
  t25_warm_machine_state
}

# Every attachment command prepares the private machine directories before it
# can refuse, so a baseline taken on a machine that has never run one would
# differ by empty directories alone.  Warming them keeps the byte comparisons
# about attachment state instead of about first-run directory creation.
#
# WHAT WARMING IS ALLOWED TO HIDE, AND WHY THE PER-CHECKOUT DIRECTORY IS IN THE
# LIST. Every path below — including `state/attachments/<checkout_id>` — was
# measured to be created by a command that then REFUSES without writing
# anything: dropping the per-checkout directory from this list turns the
# preflight-refusal tests red on "machine bytes changed", which is first-run
# directory creation and not a rollback leak. So it is scaffolding, and warming
# it is correct.
#
# But warming it does mean the sweeps cannot see the directory ITSELF appear,
# and a rolled-back attach's leak would live INSIDE it. That gap is closed on
# the assertion side rather than here: `t25_attachment_state_absent` requires
# the per-checkout directory to be empty, not merely to lack the one owner-row
# filename it used to name. A leaked owner row, a partial render receipt, or any
# other file an attach dropped in there now fails regardless of its name.
#
# Anything NOT in this list stays cold, so its first appearance is a diff.
t25_warm_machine_state() {
  local directory
  for directory in \
    "$T25_TRELLIS_HOME/locks" \
    "$T25_TRELLIS_HOME/state" \
    "$T25_TRELLIS_HOME/state/attachments" \
    "$T25_TRELLIS_HOME/state/attachments/$(t25_checkout_id "$T25_PROJECT")" \
    "$T25_TRELLIS_HOME/state/attachment-journals" \
    "$T25_TRELLIS_HOME/state/locks"; do
    mkdir -p "$directory"
    chmod 700 "$directory"
  done
}

t25_make_manifest_only_clone() {
  local origin="$T25_SANDBOX/manifest origin"

  mkdir -p "$origin"
  t25_git init -q "$origin"
  t25_git -C "$origin" config user.email fixture@example.invalid
  t25_git -C "$origin" config user.name 'T25 Fixture'
  t25_git -C "$origin" config commit.gpgsign false
  printf '{"schema_version":1,"project_id":"t25-inert-project"}\n' > "$origin/.trellis.json"
  printf 'manifest-only fixture\n' > "$origin/README.md"
  t25_git -C "$origin" add .trellis.json README.md
  t25_git -C "$origin" -c core.hooksPath=/dev/null commit -qm 'manifest-only project'

  T25_PROJECT="$T25_SANDBOX/fresh manifest clone"
  t25_git clone -q "$origin" "$T25_PROJECT"
  T25_PROJECT="$(t25_canonical_dir "$T25_PROJECT")"
}

t25_setup_inert_fixture() {
  T25_SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/trellis-t25-inert.XXXXXX")"
  T25_SANDBOX="$(t25_canonical_dir "$T25_SANDBOX")"
  T25_USER_HOME="$T25_SANDBOX/isolated home"
  T25_TRELLIS_HOME="$T25_USER_HOME/.trellis"
  mkdir -p "$T25_USER_HOME"
  chmod 700 "$T25_USER_HOME"
  t25_make_manifest_only_clone
}

t25_attach() {
  t25_attachment_env bash "$REPO_ROOT/scripts/attach-project.sh" attach \
    --home "$T25_TRELLIS_HOME" --fleet personal --release "$T25_RELEASE" "$T25_PROJECT"
}

t25_attach_with_fault() {
  local phase="$1"

  t25_attachment_env env ATTACHMENT_FAULT_PHASE="$phase" \
    bash "$REPO_ROOT/scripts/attach-project.sh" attach \
      --home "$T25_TRELLIS_HOME" --fleet personal --release "$T25_RELEASE" "$T25_PROJECT"
}

t25_detach() {
  t25_attachment_env bash "$REPO_ROOT/scripts/attach-project.sh" detach \
    --home "$T25_TRELLIS_HOME" "$T25_PROJECT"
}

t25_hooks_path() {
  t25_git -C "$1" config --local --get core.hooksPath
}

# core.hooksPath is unset on a raw clone, so the getter exits 1 without output.
t25_hooks_path_or_unset() {
  t25_hooks_path "$1" 2>/dev/null || printf '%s' ''
}

# `[[ ]]` is vacuous in a non-terminal bats statement on Bash 3.2, so substring
# assertions go through `case`, which fails the test under `set -e`.
t25_contains() {
  case "$1" in
    *"$2"*) return 0 ;;
  esac
  printf 'expected substring not found: %s\n' "$2" >&2
  return 1
}

t25_lacks() {
  case "$1" in
    *"$2"*)
      printf 'unexpected substring found: %s\n' "$2" >&2
      return 1
      ;;
  esac
  return 0
}

# Destinations the installed release manifest declares, one per line, sorted:
# `links` for the symlink surfaces, `render` for the rendered files.  Tests
# project the expected surface set from the manifest rather than restating it,
# so a manifest change moves the expectation with it.
t25_manifest_destinations() {
  local kind="${1:-all}"
  case "$kind" in
    links) jq -r '.harnesses[].links[].destination' "$T25_MANIFEST" | LC_ALL=C sort ;;
    render) jq -r '.harnesses[].render[].destination' "$T25_MANIFEST" | LC_ALL=C sort ;;
    *) return 1 ;;
  esac
}

t25_manifest_link_source() {
  jq -r --arg destination "$1" \
    '.harnesses[].links[] | select(.destination == $destination) | .source' "$T25_MANIFEST"
}

t25_manifest_render_mode() {
  jq -r --arg destination "$1" \
    '.harnesses[].render[] | select(.destination == $destination) | .mode' "$T25_MANIFEST"
}

# Absolute target of a symlink, resolving a relative link against its own
# directory the way the kernel does.
t25_resolve_link_target() {
  local path="$1" target directory

  target="$(readlink "$path")" || return 1
  case "$target" in
    /*) printf '%s\n' "$target"; return 0 ;;
  esac
  directory="$(t25_canonical_dir "$(dirname "$path")/$(dirname "$target")")" || return 1
  printf '%s/%s\n' "$directory" "$(basename "$target")"
}

t25_owner_artifact_paths() {
  jq -r --arg kind "$1" \
    '[.artifacts[] | select($kind == "any" or .kind == $kind) | .path] | sort | .[]' \
    "$(t25_owner_path "$T25_PROJECT")"
}

t25_owner_artifact_count() {
  jq -r '.artifacts | length' "$(t25_owner_path "$T25_PROJECT")"
}

t25_run_session_start() (
  local hook="$1" project="$2"

  cd "$project" || return 1
  printf '%s\n' '{"hook_event_name":"SessionStart","source":"startup"}' | \
    t25_inert_env bash "$hook"
)

# Drive the real OMP extension factory over a project directory, the way
# `t25_run_session_start` drives the real Claude/Codex SessionStart hooks. The
# factory is the loader's entry point, so this is the same surface OMP itself
# reaches. Every registered lifecycle handler is dispatched with the project as
# `ctx.cwd`; on a raw clone each must resolve no runtime, return `undefined`,
# log nothing, and never set the extension label. Prints `inert` and exits 0 in
# that case, or the offending lines and exit 1 otherwise.
#
# The driver runs with the project as its working directory: Node resolves
# package configuration upward from the CWD, so running it from the Trellis
# checkout would make an unrelated repository's `package.json` decide whether
# the module loads at all.
# The OMP adapter is TypeScript with erasable syntax only, so plain Node runs it
# through type stripping — but only from 22.18/23 onward without a flag. Probing
# the capability beats comparing version numbers: the runtime either imports a
# `.ts` module or it does not.
t25_node_can_strip_types() {
  local probe="$T25_SANDBOX/strip-types-probe"
  mkdir -p "$probe" || return 1
  printf 'export const ok: number = 1;\n' > "$probe/m.ts" || return 1
  printf 'import { ok } from "./m.ts";\nif (ok !== 1) process.exit(1);\n' > "$probe/m.mjs" || return 1
  (cd "$probe" && node ./m.mjs) >/dev/null 2>&1
}

# t25_run_omp_extension <module> <project> <expected-handler-csv>
#
# The expected handler list is required, not decorative. Without it the probe
# was vacuous: `mod.default(pi)` registering nothing left `handlers` empty, the
# `for` loop never ran, `problems` stayed empty and the driver printed `inert`.
# An adapter refactor that stopped registering handlers — the single failure
# mode most likely to kill the whole extension — would have turned this probe
# GREEN. The set is compared exactly, so a dropped or renamed lifecycle event is
# a red rather than a silent narrowing.
t25_run_omp_extension() (
  local module="$1" project="$2" expected="$3" driver="$T25_SANDBOX/omp-extension-probe.mjs"

  cat > "$driver" <<'JS'
const [modulePath, projectDir, expectedCsv] = process.argv.slice(2);
const mod = await import(modulePath);
const problems = [];
const handlers = new Map();
const pi = {
  logger: {
    warn: (...a) => problems.push("logger.warn: " + a.join(" ")),
    error: (...a) => problems.push("logger.error: " + a.join(" ")),
  },
  setLabel: (label) => problems.push("setLabel: " + label),
  sendMessage: (message) => problems.push("sendMessage: " + JSON.stringify(message)),
  on: (name, fn) => handlers.set(name, fn),
};
mod.default(pi);
const expected = expectedCsv.split(",").filter(Boolean).sort();
const registered = [...handlers.keys()].sort();
if (registered.join(",") !== expected.join(",")) {
  problems.push(
    "handlers registered [" + registered.join(",") + "] != expected [" + expected.join(",") + "]",
  );
}
const ctx = { cwd: projectDir };
for (const [name, fn] of handlers) {
  let result;
  try {
    result = await fn({}, ctx);
  } catch (err) {
    problems.push(name + " threw: " + (err && err.message));
    continue;
  }
  if (result !== undefined) problems.push(name + " returned " + JSON.stringify(result));
}
if (problems.length) {
  console.log(problems.join("\n"));
  process.exit(1);
}
console.log("inert");
JS
  cd "$project" || return 1
  t25_inert_env node "$driver" "$module" "$project" "$expected"
)

t25_no_attachment_warning() {
  case "$1" in
    *"Trellis attachment"*|*"trellis attachment"*) return 1 ;;
  esac
  return 0
}

t25_teardown_sandbox() {
  if [ -n "${T25_SANDBOX:-}" ] && [ -d "$T25_SANDBOX" ]; then
    chmod -R u+w "$T25_SANDBOX" 2>/dev/null || true
    rm -rf "$T25_SANDBOX"
  fi
}
