#!/usr/bin/env bats
# Tests for scripts/skills.sh — the Trellis-owned operator skill store
# (`trellis skills list|import|link|unlink`, spec 049 SC1/SC4).
#
# FULLY ISOLATED from the operator's real home. Every test stands up a fresh
# sandbox and points $HOME (harness roots) and $TRELLIS_HOME (store + record)
# at it, so the command under test can only ever mutate the fixture. The
# shipped-manifest collision case reads the checkout's own
# core-rules/inheritance-manifest.json, which is a source input, not a
# mutation target.
#
# The command is invoked directly from this checkout (no release install):
# skills.sh resolves TRELLIS_HOME/HOME from the environment and the shipped
# manifest from its own location, so temp-dir fixtures exercise the real
# dispatch path short of the one-line `trellis` dispatcher case below.

REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
SKILLS="$REPO_ROOT/scripts/skills.sh"
TRELLIS="$REPO_ROOT/scripts/trellis"

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/trellis-skills-command.XXXXXX")"
  SANDBOX="$(CDPATH='' cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/operator home"
  export TRELLIS_HOME="$SANDBOX/machine home"
  mkdir -p "$HOME" "$TRELLIS_HOME"
  STORE="$TRELLIS_HOME/skills"
  RECORD="$TRELLIS_HOME/state/user-skills.json"
}

teardown() {
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    chmod -R u+w "$SANDBOX" 2>/dev/null || true
    rm -rf "$SANDBOX"
  fi
}

contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) printf 'expected output to contain %s, got:\n%s\n' "$2" "$1" >&2; return 1 ;;
  esac
}

# make_skill_src <dir> [body] — a real skill source directory with SKILL.md.
make_skill_src() {
  local dir="$1" body="${2:-fixture body}"
  mkdir -p "$dir"
  printf -- '---\nname: %s\ndescription: fixture skill\n---\n\n%s\n' "${dir##*/}" "$body" > "$dir/SKILL.md"
}

# make_store_skill <name> [harness-json] — a skill already in the store.
make_store_skill() {
  local name="$1" harness_json="${2:-}"
  mkdir -p "$STORE/$name"
  printf -- '---\nname: %s\ndescription: fixture skill\n---\n\nstore body\n' "$name" > "$STORE/$name/SKILL.md"
  if [ -n "$harness_json" ]; then
    printf '%s\n' "$harness_json" > "$STORE/$name/trellis-skill.json"
  fi
}

link_target() {
  readlink "$1"
}

record_links_for() {
  jq -c --arg skill "$1" '[.links[] | select(.skill == $skill)]' "$RECORD"
}

@test "import moves the source into the store, removes the identical copy, links and records" {
  make_skill_src "$SANDBOX/inbox/greet"
  mkdir -p "$HOME/.claude/skills"
  cp -R "$SANDBOX/inbox/greet" "$HOME/.claude/skills/greet"

  run "$SKILLS" import "$SANDBOX/inbox/greet"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  contains "$output" "imported skill: greet"

  [ ! -e "$SANDBOX/inbox/greet" ] && [ ! -L "$SANDBOX/inbox/greet" ]
  [ -f "$STORE/greet/SKILL.md" ]
  [ "$(cat "$STORE/greet/SKILL.md")" = "$(printf -- '---\nname: greet\ndescription: fixture skill\n---\n\nfixture body\n')" ]

  # Default harness set (all three) maps to .claude/skills + .agents/skills.
  [ -L "$HOME/.claude/skills/greet" ]
  [ "$(link_target "$HOME/.claude/skills/greet")" = "$STORE/greet" ]
  [ -L "$HOME/.agents/skills/greet" ]
  [ "$(link_target "$HOME/.agents/skills/greet")" = "$STORE/greet" ]

  jq -e --arg home "$HOME" --arg store "$STORE" '
    .schema == "trellis-user-skills/v1"
    and ([.links[] | select(.skill == "greet" and .target == ($store + "/greet"))]
      | map(.path) | sort) == [$home + "/.agents/skills/greet", $home + "/.claude/skills/greet"]
  ' "$RECORD" >/dev/null

  run "$SKILLS" list
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  contains "$output" "greet harnesses=claude,codex,pi"
  contains "$output" ".claude/skills/greet: linked"
  contains "$output" ".agents/skills/greet: linked"
}

@test "import of a harness-narrowed skill removes identical copies outside its set" {
  make_skill_src "$SANDBOX/inbox/focused"
  printf '{"harnesses":["claude"]}\n' > "$SANDBOX/inbox/focused/trellis-skill.json"
  mkdir -p "$HOME/.claude/skills" "$HOME/.agents/skills"
  cp -R "$SANDBOX/inbox/focused" "$HOME/.claude/skills/focused"
  cp -R "$SANDBOX/inbox/focused" "$HOME/.agents/skills/focused"

  run "$SKILLS" import "$SANDBOX/inbox/focused"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  [ -f "$STORE/focused/SKILL.md" ]
  [ -L "$HOME/.claude/skills/focused" ]
  [ "$(link_target "$HOME/.claude/skills/focused")" = "$STORE/focused" ]
  [ ! -e "$HOME/.agents/skills/focused" ] && [ ! -L "$HOME/.agents/skills/focused" ]

  run "$SKILLS" list
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  contains "$output" "focused harnesses=claude"
}

@test "import refuses a differing copy with zero mutation" {
  make_skill_src "$SANDBOX/inbox/drift" "source body"
  mkdir -p "$HOME/.claude/skills" "$HOME/.agents/skills"
  cp -R "$SANDBOX/inbox/drift" "$HOME/.claude/skills/drift"
  make_skill_src "$HOME/.agents/skills/drift" "DIVERGENT body"
  before_src="$(shasum -a 256 "$SANDBOX/inbox/drift/SKILL.md" | cut -d ' ' -f 1)"
  before_same="$(shasum -a 256 "$HOME/.claude/skills/drift/SKILL.md" | cut -d ' ' -f 1)"
  before_divergent="$(shasum -a 256 "$HOME/.agents/skills/drift/SKILL.md" | cut -d ' ' -f 1)"

  run "$SKILLS" import "$SANDBOX/inbox/drift"
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  contains "$output" "$HOME/.agents/skills/drift"

  # Everything intact: source, both copies, no store entry, no record.
  [ -f "$SANDBOX/inbox/drift/SKILL.md" ]
  [ "$before_src" = "$(shasum -a 256 "$SANDBOX/inbox/drift/SKILL.md" | cut -d ' ' -f 1)" ]
  [ -d "$HOME/.claude/skills/drift" ] && [ ! -L "$HOME/.claude/skills/drift" ]
  [ "$before_same" = "$(shasum -a 256 "$HOME/.claude/skills/drift/SKILL.md" | cut -d ' ' -f 1)" ]
  [ -d "$HOME/.agents/skills/drift" ] && [ ! -L "$HOME/.agents/skills/drift" ]
  [ "$before_divergent" = "$(shasum -a 256 "$HOME/.agents/skills/drift/SKILL.md" | cut -d ' ' -f 1)" ]
  [ ! -e "$STORE/drift" ] && [ ! -L "$STORE/drift" ]
  [ ! -e "$RECORD" ] && [ ! -L "$RECORD" ]
}

@test "import refuses a name that collides with a release user skill" {
  # Guard: the shipped manifest really does expose herdr-foreman as a user
  # skill in a harness skill root, so the refusal below is not vacuous.
  jq -e '
    [.harnesses.user.links[]
      | select(.destination_home == true)
      | select(.destination == ".claude/skills/herdr-foreman"
        or .destination == ".agents/skills/herdr-foreman")] | length >= 1
  ' "$REPO_ROOT/core-rules/inheritance-manifest.json" >/dev/null
  make_skill_src "$SANDBOX/inbox/herdr-foreman"

  run "$SKILLS" import "$SANDBOX/inbox/herdr-foreman"
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  contains "$output" "herdr-foreman"

  [ -f "$SANDBOX/inbox/herdr-foreman/SKILL.md" ]
  [ ! -e "$STORE/herdr-foreman" ] && [ ! -L "$STORE/herdr-foreman" ]
  [ ! -e "$RECORD" ] && [ ! -L "$RECORD" ]
}

@test "import refuses a name already in the store" {
  make_store_skill "dup"
  make_skill_src "$SANDBOX/inbox/dup" "second body"

  run "$SKILLS" import "$SANDBOX/inbox/dup"
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  contains "$output" "dup"

  [ -f "$SANDBOX/inbox/dup/SKILL.md" ]
  contains "$(cat "$STORE/dup/SKILL.md")" "store body"
}

@test "link is idempotent" {
  make_store_skill "steady"

  run "$SKILLS" link steady
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  before_record="$(shasum -a 256 "$RECORD" | cut -d ' ' -f 1)"
  before_claude="$(link_target "$HOME/.claude/skills/steady")"
  before_agents="$(link_target "$HOME/.agents/skills/steady")"

  run "$SKILLS" link steady
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$before_record" = "$(shasum -a 256 "$RECORD" | cut -d ' ' -f 1)" ]
  [ "$before_claude" = "$(link_target "$HOME/.claude/skills/steady")" ]
  [ "$before_agents" = "$(link_target "$HOME/.agents/skills/steady")" ]

  run "$SKILLS" link
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$before_record" = "$(shasum -a 256 "$RECORD" | cut -d ' ' -f 1)" ]
}

@test "link removes owned links when the harness set narrows" {
  make_store_skill "narrow"

  run "$SKILLS" link narrow
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -L "$HOME/.claude/skills/narrow" ]
  [ -L "$HOME/.agents/skills/narrow" ]

  printf '{"harnesses":["pi"]}\n' > "$STORE/narrow/trellis-skill.json"
  run "$SKILLS" link narrow
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  [ ! -e "$HOME/.claude/skills/narrow" ] && [ ! -L "$HOME/.claude/skills/narrow" ]
  [ ! -e "$HOME/.agents/skills/narrow" ] && [ ! -L "$HOME/.agents/skills/narrow" ]
  [ -L "$HOME/.pi/agent/skills/narrow" ]
  [ "$(link_target "$HOME/.pi/agent/skills/narrow")" = "$STORE/narrow" ]
  [ -f "$STORE/narrow/SKILL.md" ]
  [ "$(record_links_for narrow | jq 'length')" -eq 1 ]
  [ "$(record_links_for narrow | jq -r '.[0].path')" = "$HOME/.pi/agent/skills/narrow" ]

  run "$SKILLS" list
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  contains "$output" "narrow harnesses=pi"
  contains "$output" ".pi/agent/skills/narrow: linked"
}

@test "link refuses an unowned existing path and never replaces it" {
  make_store_skill "plain"
  mkdir -p "$HOME/.claude/skills/plain"
  printf 'operator-owned body\n' > "$HOME/.claude/skills/plain/SKILL.md"
  before="$(shasum -a 256 "$HOME/.claude/skills/plain/SKILL.md" | cut -d ' ' -f 1)"

  run "$SKILLS" link plain
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  contains "$output" "$HOME/.claude/skills/plain"

  [ -d "$HOME/.claude/skills/plain" ] && [ ! -L "$HOME/.claude/skills/plain" ]
  [ "$before" = "$(shasum -a 256 "$HOME/.claude/skills/plain/SKILL.md" | cut -d ' ' -f 1)" ]
  [ ! -e "$RECORD" ] && [ ! -L "$RECORD" ]
}

@test "unlink removes owned links only and leaves the store" {
  make_skill_src "$SANDBOX/inbox/bye"
  run "$SKILLS" import "$SANDBOX/inbox/bye"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  run "$SKILLS" unlink bye
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  contains "$output" "unlinked skill: bye"

  [ ! -e "$HOME/.claude/skills/bye" ] && [ ! -L "$HOME/.claude/skills/bye" ]
  [ ! -e "$HOME/.agents/skills/bye" ] && [ ! -L "$HOME/.agents/skills/bye" ]
  [ -f "$STORE/bye/SKILL.md" ]
  [ "$(jq -r '.links | length' "$RECORD")" -eq 0 ]

  run "$SKILLS" unlink bye
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$STORE/bye/SKILL.md" ]

  run "$SKILLS" unlink nosuch
  [ "$status" -eq 2 ] || { echo "$output"; false; }
}

@test "link refuses an unknown harness in trellis-skill.json with exit 2" {
  make_store_skill "weird" '{"harnesses":["claude","bogus"]}'
  run "$SKILLS" link weird
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  contains "$output" "weird"
  [ ! -e "$RECORD" ] && [ ! -L "$RECORD" ]
}

@test "link refuses an empty harnesses list with exit 2" {
  make_store_skill "empty" '{"harnesses":[]}'
  run "$SKILLS" link empty
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  contains "$output" "empty"
}

@test "list reports a malformed trellis-skill.json with exit 2" {
  make_store_skill "broken"
  printf 'not json at all\n' > "$STORE/broken/trellis-skill.json"
  run "$SKILLS" list
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  contains "$output" "broken"
}

@test "import refuses a source without SKILL.md with exit 2" {
  mkdir -p "$SANDBOX/inbox/noskill"
  printf 'no skill here\n' > "$SANDBOX/inbox/noskill/notes.txt"
  run "$SKILLS" import "$SANDBOX/inbox/noskill"
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [ -f "$SANDBOX/inbox/noskill/notes.txt" ]
  [ ! -e "$RECORD" ] && [ ! -L "$RECORD" ]
}

@test "trellis dispatcher routes the skills subcommand" {
  make_store_skill "via"
  run "$TRELLIS" skills link via
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -L "$HOME/.claude/skills/via" ]
  run "$TRELLIS" skills list
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  contains "$output" "via harnesses=claude,codex,pi"
}

@test "import refuses an unowned desired path with zero mutation" {
  make_skill_src "$SANDBOX/inbox/gated"
  mkdir -p "$HOME/.agents/skills"
  printf 'operator-owned file\n' > "$HOME/.agents/skills/gated"
  before="$(shasum -a 256 "$HOME/.agents/skills/gated" | cut -d ' ' -f 1)"

  run "$SKILLS" import "$SANDBOX/inbox/gated"
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  contains "$output" "$HOME/.agents/skills/gated"

  [ -f "$SANDBOX/inbox/gated/SKILL.md" ]
  [ ! -e "$STORE/gated" ] && [ ! -L "$STORE/gated" ]
  [ -f "$HOME/.agents/skills/gated" ] && [ ! -L "$HOME/.agents/skills/gated" ]
  [ "$before" = "$(shasum -a 256 "$HOME/.agents/skills/gated" | cut -d ' ' -f 1)" ]
  [ ! -e "$RECORD" ] && [ ! -L "$RECORD" ]
}

@test "multi-arg import refusal leaves every source untouched" {
  make_skill_src "$SANDBOX/inbox/keepme" "keepme body"
  mkdir -p "$HOME/.claude/skills"
  cp -R "$SANDBOX/inbox/keepme" "$HOME/.claude/skills/keepme"
  make_skill_src "$SANDBOX/inbox/baddiff" "source body"
  mkdir -p "$HOME/.agents/skills"
  make_skill_src "$HOME/.agents/skills/baddiff" "DIVERGENT body"

  run "$SKILLS" import "$SANDBOX/inbox/keepme" "$SANDBOX/inbox/baddiff"
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  contains "$output" "$HOME/.agents/skills/baddiff"

  [ -f "$SANDBOX/inbox/keepme/SKILL.md" ]
  [ -d "$HOME/.claude/skills/keepme" ] && [ ! -L "$HOME/.claude/skills/keepme" ]
  [ -f "$SANDBOX/inbox/baddiff/SKILL.md" ]
  [ ! -e "$STORE/keepme" ] && [ ! -L "$STORE/keepme" ]
  [ ! -e "$STORE/baddiff" ] && [ ! -L "$STORE/baddiff" ]
  [ ! -e "$RECORD" ] && [ ! -L "$RECORD" ]
}

@test "import refuses a newline skill name with exit 2" {
  nlname="$(printf 'we\nird')"
  mkdir -p "$SANDBOX/inbox/$nlname"
  printf -- '---\nname: weird\ndescription: fixture skill\n---\n\nbody\n' > "$SANDBOX/inbox/$nlname/SKILL.md"

  run "$SKILLS" import "$SANDBOX/inbox/$nlname"
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [ -f "$SANDBOX/inbox/$nlname/SKILL.md" ]
  [ ! -e "$RECORD" ] && [ ! -L "$RECORD" ]
}

@test "full link commits the first skill before the second skill refuses" {
  make_store_skill "alpha"
  make_store_skill "beta"
  mkdir -p "$HOME/.claude/skills"
  printf 'operator-owned file\n' > "$HOME/.claude/skills/beta"

  run "$SKILLS" link
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  contains "$output" "$HOME/.claude/skills/beta"

  # Alpha is fully committed (links plus record); beta is untouched.
  [ -L "$HOME/.claude/skills/alpha" ]
  [ -L "$HOME/.agents/skills/alpha" ]
  [ "$(link_target "$HOME/.claude/skills/alpha")" = "$STORE/alpha" ]
  [ "$(record_links_for alpha | jq 'length')" -eq 2 ]
  [ -f "$HOME/.claude/skills/beta" ] && [ ! -L "$HOME/.claude/skills/beta" ]
  [ "$(record_links_for beta | jq 'length')" -eq 0 ]

  # Removing the blocker converges on the next run.
  rm -f "$HOME/.claude/skills/beta"
  run "$SKILLS" link
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -L "$HOME/.claude/skills/beta" ]
}

@test "import replaces a relative harness-root symlink to the source with owned links" {
  # Operator layout: real skill in .agents, relative pointer from .claude.
  make_skill_src "$HOME/.agents/skills/find-skills" "find-skills body"
  mkdir -p "$HOME/.claude/skills"
  ln -s "../../.agents/skills/find-skills" "$HOME/.claude/skills/find-skills"
  [ "$(readlink "$HOME/.claude/skills/find-skills")" = "../../.agents/skills/find-skills" ]

  run "$SKILLS" import "$HOME/.agents/skills/find-skills"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  contains "$output" "imported skill: find-skills"

  [ -d "$STORE/find-skills" ] && [ ! -L "$STORE/find-skills" ]
  contains "$(cat "$STORE/find-skills/SKILL.md")" "find-skills body"
  [ -L "$HOME/.claude/skills/find-skills" ]
  [ "$(link_target "$HOME/.claude/skills/find-skills")" = "$STORE/find-skills" ]
  [ -L "$HOME/.agents/skills/find-skills" ]
  [ "$(link_target "$HOME/.agents/skills/find-skills")" = "$STORE/find-skills" ]
  [ "$(record_links_for find-skills | jq 'length')" -eq 2 ]
}

@test "import replaces an absolute harness-root symlink to the source with owned links" {
  make_skill_src "$HOME/.agents/skills/absfind" "absfind body"
  mkdir -p "$HOME/.claude/skills"
  ln -s "$HOME/.agents/skills/absfind" "$HOME/.claude/skills/absfind"

  run "$SKILLS" import "$HOME/.agents/skills/absfind"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  contains "$output" "imported skill: absfind"

  [ -d "$STORE/absfind" ] && [ ! -L "$STORE/absfind" ]
  [ "$(link_target "$HOME/.claude/skills/absfind")" = "$STORE/absfind" ]
  [ "$(link_target "$HOME/.agents/skills/absfind")" = "$STORE/absfind" ]
  [ "$(record_links_for absfind | jq 'length')" -eq 2 ]
}

@test "link refusal leaves stale owned links and the record untouched" {
  make_store_skill "shift"
  run "$SKILLS" link shift
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf '{"harnesses":["pi"]}' > "$STORE/shift/trellis-skill.json"
  mkdir -p "$HOME/.pi/agent/skills"
  printf 'operator-owned file\n' > "$HOME/.pi/agent/skills/shift"
  before_record="$(shasum -a 256 "$RECORD" | cut -d ' ' -f 1)"

  run "$SKILLS" link shift
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  contains "$output" "$HOME/.pi/agent/skills/shift"

  # Preflight refused before any mutation: owned links and record intact.
  [ -L "$HOME/.claude/skills/shift" ]
  [ -L "$HOME/.agents/skills/shift" ]
  [ "$before_record" = "$(shasum -a 256 "$RECORD" | cut -d ' ' -f 1)" ]
}
