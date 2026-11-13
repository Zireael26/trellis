#!/usr/bin/env bash
# Shared fixture for the interrupted-detach suites: one attached project whose
# detach journal has enough removals to stop at phase 8, a pristine copy of it
# restored in place before every case, and a harness that SIGKILLs a real
# detach at a named step.
#
# Callers set REPO_ROOT and load release-fixture first.

detach_journal_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d ' ' -f 1
  else
    sha256sum "$1" | cut -d ' ' -f 1
  fi
}

# detach_journal_build <sandbox>: bootstrap, release 1.2.3, project, attach.
detach_journal_build() {
  local sandbox="$1" repo skill links=''
  export HOME="$sandbox/user home" TRELLIS_HOME="$sandbox/trellis home" TMPDIR="$sandbox/tmp"
  mkdir -p "$HOME" "$TRELLIS_HOME" "$TMPDIR" || return 1
  chmod 700 "$TRELLIS_HOME" || return 1
  release_fixture_bootstrap "$HOME" "$TRELLIS_HOME" "$sandbox" || return 1
  repo="$sandbox/release-source"
  mkdir -p "$repo/core-rules/commands/templates" "$repo/core-rules/templates" "$repo/core-rules/husky" \
    "$repo/core-rules/githooks" "$repo/scripts" || return 1
  printf '# fixture policy\n' > "$repo/core-rules/CLAUDE.md"
  printf '# generated primer index\n' > "$repo/core-rules/commands/templates/primer-index-template.md"
  for skill in a b c d e f g h; do
    mkdir -p "$repo/core-rules/skills/$skill" || return 1
    printf '# %s\n' "$skill" > "$repo/core-rules/skills/$skill/SKILL.md"
    links="$links{\"source\":\"core-rules/skills/$skill/SKILL.md\",\"destination\":\".agents/skills/$skill.md\"},"
  done
  mkdir -p "$repo/core-rules/legacy-hooks" || return 1
  cp -R "$REPO_ROOT/core-rules/legacy-hooks/." "$repo/core-rules/legacy-hooks/" || return 1
  cp "$REPO_ROOT/core-rules/templates/claude-settings.local.json" "$repo/core-rules/templates/" || return 1
  cp "$REPO_ROOT/core-rules/templates/codex-hooks.local.json" "$repo/core-rules/templates/" || return 1
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/core-rules/husky/pre-push"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/core-rules/githooks/pre-push"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/scripts/seed-inheritance-symlinks.sh"
  chmod 755 "$repo/core-rules/husky/pre-push" "$repo/core-rules/githooks/pre-push" "$repo/scripts/seed-inheritance-symlinks.sh"
  release_fixture_seal_executed_files "$repo" || return 1
  cat > "$repo/core-rules/inheritance-manifest.json" <<JSON
{"schema_version":1,"harnesses":{
 "claude":{"links":[{"source":"core-rules/CLAUDE.md","destination":".claude/rules/trellis.md"}],
   "render":[{"template":"core-rules/commands/templates/primer-index-template.md","destination":".claude/primers/INDEX.md","merge":"replace","mode":"0644","required":true},
             {"template":"core-rules/templates/claude-settings.local.json","destination":".claude/settings.local.json","merge":"explicit-json","mode":"0600","required":true}]},
 "codex":{"links":[${links}{"source":"core-rules/CLAUDE.md","destination":".agents/rules/trellis.md"}],
   "render":[{"template":"core-rules/templates/codex-hooks.local.json","destination":".codex/hooks.json","merge":"explicit-json","mode":"0600","required":true}]}}}
JSON
  printf '1.2.3\n' > "$repo/core-rules/VERSION"
  release_fixture_install "$HOME" "$TRELLIS_HOME" 1.2.3 "$repo" || return 1
  PROJECT="$sandbox/project with spaces"
  mkdir -p "$PROJECT" && git init -q "$PROJECT" || return 1
  printf '{"schema_version":1,"project_id":"fixture-project"}\n' > "$PROJECT/.trellis.json"
  git -C "$PROJECT" add .trellis.json || return 1
  git -C "$PROJECT" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm initial || return 1
  detach_journal_sha256 "$PROJECT/.git/info/exclude" > "$sandbox/exclude.sha256" || return 1
  TRELLIS_ATTACH_POSTJOB=off "$REPO_ROOT/scripts/attach-project.sh" attach --home "$TRELLIS_HOME" \
    --fleet personal --release 1.2.3 "$PROJECT" >/dev/null
}

# detach_journal_setup_file: build once per file; every case restores the
# pristine attached tree at the same absolute path, since records hold paths.
detach_journal_setup_file() {
  local base
  base="$(release_fixture_canonical_dir "$BATS_FILE_TMPDIR")" || return 1
  mkdir -p "$base/sandbox" || return 1
  detach_journal_build "$base/sandbox" || return 1
  cp -Rp "$base/sandbox" "$base/pristine"
}

# The release store is read-only by design; make the file's tree removable.
detach_journal_teardown_file() {
  chmod -R u+w "$BATS_FILE_TMPDIR" 2>/dev/null || true
}

detach_journal_setup() {
  local base
  base="$(release_fixture_canonical_dir "$BATS_FILE_TMPDIR")"
  SANDBOX="$base/sandbox"
  chmod -R u+w "$SANDBOX" 2>/dev/null
  rm -rf "$SANDBOX"
  cp -Rp "$base/pristine" "$SANDBOX"
  export HOME="$SANDBOX/user home" TRELLIS_HOME="$SANDBOX/trellis home" TMPDIR="$SANDBOX/tmp"
  PROJECT="$SANDBOX/project with spaces"
  EXCLUDE_HASH="$(cat "$SANDBOX/exclude.sha256")"
  ATTACH="$REPO_ROOT/scripts/attach-project.sh"
  JOURNALS="$TRELLIS_HOME/state/attachment-journals"
}

detach_journal_path() {
  find "$JOURNALS" -maxdepth 1 -type f -name 'detach-*.json' -print
}

# kill_detach_at <point> <nth> [detach args...]: run a real detach and SIGKILL
# its whole process group right after the nth time <point> succeeds. Points are
# wrapped functions, or the quarantine steps of a pinned removal:
#   intent q_mkdir q_claim q_rm q_rmdir clear phase owner_rm owner_committed
#   attachment_detach_render_{begin,stage,claim,publish,cleanup,finish}
#   attachment_detach_mark_external_phase
# and "any": every durable step of the commit loop, whatever its name.
# Nothing in the product is instrumented; the wrappers live in this process,
# and the commit loop's points come from a copy of the detach program whose
# no-op checkpoint seam is replaced (as attachment-journal-v2.bats does).
kill_detach_at() {
  local point="$1" nth="$2" counter
  shift 2
  counter="$(mktemp "$TMPDIR/kill-count.XXXXXX")"
  printf '0\n' > "$counter"
  KILL_STATUS=0
  KILL_POINT="$point" KILL_NTH="$nth" KILL_COUNTER="$counter" \
    python3 -c 'import os, sys; os.setpgrp(); os.execvp(sys.argv[1], sys.argv[1:])' bash -c '
      . "$1"; shift
      __kp() {
        [ "$1" = "$KILL_POINT" ] || return 0
        local n
        n=$(( $(command cat "$KILL_COUNTER") + 1 ))
        printf "%s\n" "$n" > "$KILL_COUNTER"
        [ "$n" -ne "$KILL_NTH" ] || kill -KILL 0
      }
      __after() {
        local point=$1 status
        shift
        "$@"; status=$?
        [ "$status" -ne 0 ] || __kp "$point"
        return "$status"
      }
      for f in attachment_detach_mark_external_phase attachment_detach_render_begin attachment_detach_render_stage \
        attachment_detach_render_claim attachment_detach_render_publish attachment_detach_render_cleanup \
        attachment_detach_render_finish; do
        eval "$(declare -f "$f" | sed "1s/^$f /__orig_$f /")"
        eval "$f() { __after $f __orig_$f \"\$@\"; }"
      done
      eval "$(declare -f _attachment_set_removal_intent | sed "1s/^_attachment_set_removal_intent /__orig_intent /")"
      _attachment_set_removal_intent() { __after intent __orig_intent "$@"; }
      eval "$(declare -f _attachment_clear_removal_intent | sed "1s/^_attachment_clear_removal_intent /__orig_clear /")"
      _attachment_clear_removal_intent() { __after clear __orig_clear "$@"; }
      eval "$(declare -f _attachment_detach_journal_update | sed "1s/^_attachment_detach_journal_update /__orig_update /")"
      _attachment_detach_journal_update() {
        case "$*" in
          *".owner_committed = true"*) __after owner_committed __orig_update "$@" ;;
          *".phase = \$phase"*) __after phase __orig_update "$@" ;;
          *) __orig_update "$@" ;;
        esac
      }
      # The commit removal loop runs in one Python process; its durable steps
      # call checkpoint(<point>) with the same names, and this copy of the
      # program counts and kills there.
      __seam="    return None  # crash-test seam"
      __kill_seam="    if os.environ.get(\"KILL_POINT\") in (label, \"any\"):
        with open(os.environ[\"KILL_COUNTER\"]) as counter:
            hits = int(counter.read()) + 1
        with open(os.environ[\"KILL_COUNTER\"], \"w\") as counter:
            counter.write(\"%d\\n\" % hits)
        if hits == int(os.environ[\"KILL_NTH\"]):
            os.killpg(0, signal.SIGKILL)"
      eval "$(declare -f _attachment_detach_program | sed "1s/^_attachment_detach_program /__orig_program /")"
      # One python3 substitution: bash 3.2 pattern substitution over the
      # program text takes over a minute per call.
      _attachment_detach_program() {
        local program
        program=$(__orig_program) || return 1
        printf "%s\n" "$program" | SEAM="$__seam" KILL_SEAM="$__kill_seam" python3 -c "
import os, sys
text = sys.stdin.read()
seam = os.environ[\"SEAM\"]
if text.count(seam) != 1:
    sys.exit(1)
sys.stdout.write(text.replace(seam, os.environ[\"KILL_SEAM\"]))
"
      }
      mkdir() { case "$*" in *.trellis-attachment-remove-*) __after q_mkdir command mkdir "$@" ;; *) command mkdir "$@" ;; esac; }
      mv() { case "$*" in *.trellis-attachment-remove-*/artifact) __after q_claim command mv "$@" ;; *) command mv "$@" ;; esac; }
      rm() {
        case "$*" in
          *.trellis-attachment-remove-*/artifact) __after q_rm command rm "$@" ;;
          *"$TRELLIS_HOME/state/attachments/"*) __after owner_rm command rm "$@" ;;
          *) command rm "$@" ;;
        esac
      }
      rmdir() { case "$*" in *.trellis-attachment-remove-*) __after q_rmdir command rmdir "$@" ;; *) command rmdir "$@" ;; esac; }
      main "$@"
    ' kill-detach "$ATTACH" detach --home "$TRELLIS_HOME" "$@" "$PROJECT" || KILL_STATUS=$?
  KILL_HITS="$(cat "$counter")"
  [ "$KILL_STATUS" -eq 137 ] && [ "$KILL_HITS" -eq "$nth" ] || {
    printf 'kill at %s #%s: status %s after %s hits\n' "$point" "$nth" "$KILL_STATUS" "$KILL_HITS" >&2
    return 1
  }
  [ -n "$(detach_journal_path)" ] || { printf 'kill at %s #%s left no journal\n' "$point" "$nth" >&2; return 1; }
}

# The worktree is exactly as a clean detach leaves it.
assert_detached() {
  local leftovers
  [ -z "$(ls -A "$JOURNALS")" ] || { ls -la "$JOURNALS" >&2; return 1; }
  [ -z "$(find "$TRELLIS_HOME/state/attachments" -type f -name '*.json' 2>/dev/null)" ] || { echo 'owner record remains' >&2; return 1; }
  [ ! -e "$PROJECT/.trellis/runtime" ] && [ ! -L "$PROJECT/.trellis/runtime" ] || { echo 'runtime anchor remains' >&2; return 1; }
  leftovers="$(find "$PROJECT/.agents" "$PROJECT/.claude" "$PROJECT/.codex" \( -type f -o -type l \) -print 2>/dev/null)"
  [ -z "$leftovers" ] || { printf 'leaves remain:\n%s\n' "$leftovers" >&2; return 1; }
  [ -z "$(find "$PROJECT" -name '.trellis-attachment-remove-*' -print)" ] || { echo 'quarantine remains' >&2; return 1; }
  [ "$(detach_journal_sha256 "$PROJECT/.git/info/exclude")" = "$EXCLUDE_HASH" ] || { echo 'exclude not restored' >&2; return 1; }
  jq -e '[.. | objects | .attachment_id? // empty] | length == 0' "$TRELLIS_HOME/registry.json" >/dev/null ||
    { echo 'registry still binds an attachment' >&2; return 1; }
  [ -z "$(git -C "$PROJECT" status --porcelain)" ] || { git -C "$PROJECT" status --porcelain >&2; return 1; }
}
