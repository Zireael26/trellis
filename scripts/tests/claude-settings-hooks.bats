#!/usr/bin/env bats
# Spec 072 T12: how the attach-rendered Claude settings start Trellis hooks.
# Exec form (no user shell) for every hook outside the contextual SessionStart
# entries; onFailure block on the bright-line PreToolUse guards and nowhere
# else; explicit timeouts; advisories filtered with `if` and kept synchronous.
# Below Claude Code 2.1.295, or on an unreadable version, the render is the
# pre-exec shell-form wiring, byte for byte. claude is a stub.
REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
TEMPLATE="$REPO/core-rules/templates/claude-settings.local.json"
GUARDS='["block-destructive","reread-guard","skill-preload-guard"]'

setup() {
  SANDBOX="$(cd "$(mktemp -d "$BATS_TEST_TMPDIR/claude-settings.XXXXXX")" && pwd -P)"
  local home="$SANDBOX/home"
  mkdir -p "$home/.local/bin" "$SANDBOX/trellis-home" "$SANDBOX/claude-bin"
  printf '#!/bin/sh\n' > "$home/.local/bin/trellis"
  chmod 755 "$home/.local/bin/trellis"
}

teardown() { [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"; }

stub_claude() {
  printf '#!/bin/sh\necho "%s (Claude Code)"\n' "$1" > "$SANDBOX/claude-bin/claude"
  chmod 755 "$SANDBOX/claude-bin/claude"
}

# render [caller-path]: the contextual render with only the stub directory (or
# the given caller PATH) able to supply claude.
render() {
  env -u TRELLIS_ATTACH_CALLER_PATH ${1:+TRELLIS_ATTACH_CALLER_PATH="$1"} \
    HOME="$SANDBOX/home" PATH="$SANDBOX/claude-bin:/usr/bin:/bin" bash -c '
    . "$1/scripts/lib/attachment.sh" || exit 90
    context="$(attachment_contextual_render_context "$2")" || exit 91
    attachment_contextual_template_render "$1/core-rules/templates/claude-settings.local.json" \
      core-rules/templates/claude-settings.local.json "$context"
  ' _ "$REPO" "$SANDBOX/trellis-home"
}

# guard_of: the bright-line guard a hook starts through the supervisor, or null.
GUARD_OF='def guard_of: ((.args // []) | index("guard-supervise")) as $i | if $i == null then null else .args[$i + 3] end;'

@test "onFailure block is on every bright-line PreToolUse guard and on no other hook" {
  jq -e --argjson guards "$GUARDS" "$GUARD_OF"'
    ([.hooks.PreToolUse[].hooks[] | select(.onFailure == "block") | guard_of] | sort) == $guards
    and ([.hooks[][].hooks[] | select(has("onFailure"))] | length) == ($guards | length)
  ' "$TEMPLATE" >/dev/null
}

@test "every hook outside SessionStart is exec form with braced placeholders only" {
  jq -e '
    [.hooks | to_entries[] | select(.key != "SessionStart") | .value[].hooks[]]
    | length > 0
    and all(.[];
      (.args | type) == "array"
      and (.command | startswith("/") and (test("\\s") | not))
      and all(.args[]; (test("\\$CLAUDE_") | not)
        and ([scan("\\$\\{[^}]*\\}")] - ["${CLAUDE_PROJECT_DIR}"] | length) == 0))
  ' "$TEMPLATE" >/dev/null
  # The contextual SessionStart commands stay shell form: attach substitutes
  # shell-quoted home, Trellis home and launcher into them.
  jq -e '[.hooks.SessionStart[].hooks[] | has("args")] | all(. == false)' "$TEMPLATE" >/dev/null
}

@test "tool, prompt and Stop hooks carry explicit short timeouts" {
  # Guards: 30 s, above the supervisor's 20 s deadline. PreToolUse advisories:
  # at most 10 s. Everything else: no higher than its reviewed ceiling.
  jq -e "$GUARD_OF"'
    def name: [.args[] | select(endswith(".sh"))] | last | capture("(?<n>[a-z-]+)\\.sh$").n;
    {"post-edit-verify":120,"slop-tripwire":5,"track-read":5,"wiki-skill-suggest":5,
     "hookspath-guard":10,"spec-gate":15,"decision-receipt":15,"stop-verify":300,
     "code-review-subagent":120,"ui-verify":120,"stamp-turn":5,"turn-baseline":10,
     "skill-slash-guard":5,"save-context-log":10} as $ceiling
    | [.hooks | to_entries[] | select(.key != "SessionStart") | .key as $event | .value[].hooks[]
       | {event:$event, guard:guard_of, name:name, timeout}]
    | length == 18
    and all(.[]; (.timeout | type) == "number" and .timeout == (.timeout | floor) and .timeout > 0)
    and all(.[] | select(.guard != null); .timeout == 30)
    and all(.[] | select(.guard == null and .event == "PreToolUse"); .timeout <= 10)
    and all(.[] | select(.guard == null and .event != "PreToolUse"); .timeout <= $ceiling[.name])
  ' "$TEMPLATE" >/dev/null
}

@test "advisories stay synchronous and only tool events use if" {
  jq -e '
    ([.hooks[][].hooks[] | select(has("async") or has("asyncRewake"))] | length) == 0
    and ([.hooks | to_entries[] | select(.key != "PreToolUse" and .key != "PostToolUse")
          | .value[].hooks[] | select(has("if"))] | length) == 0
  ' "$TEMPLATE" >/dev/null
}

# The hook records a PR base for `gh pr create` behind any of its wrappers
# (sudo, env, exec, command, nohup, time) and after shell separators. Claude
# strips only some wrappers before matching, so the filter must be a substring
# rule, not a `gh pr create` prefix.
@test "pr-gate-shiftleft is filtered to Bash commands that mention gh, at 10s" {
  local rule pattern cmd
  rule="$(jq -r '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]
    | select(any(.args[]?; endswith("/pr-gate-shiftleft.sh")))]
    | if length == 1 and .[0].timeout == 10 and (.[0] | has("onFailure") | not) then .[0].if else empty end' "$TEMPLATE")"
  [ "$rule" = 'Bash(*gh*)' ] || { echo "rule=$rule"; false; }
  # Bash rule semantics: `*` matches any text, the rest is literal.
  pattern="${rule#Bash(}" pattern="${pattern%)}"
  for cmd in 'gh pr create --base main' 'sudo gh pr create' 'env GH_HOST=x gh pr create' \
    'exec gh pr create' 'command gh pr create' 'nohup gh pr create' 'time gh pr create' \
    'cd repo && gh pr create --fill' 'gh -R o/r pr create'; do
    # shellcheck disable=SC2053
    [[ "$cmd" == $pattern ]] || { echo "filter skips: $cmd"; false; }
  done
  [[ 'git status --short' != $pattern ]]
}

@test "render keeps onFailure at or above Claude Code 2.1.295" {
  local version out
  for version in 2.1.295 2.1.314 3.0.0; do
    stub_claude "$version"
    out="$(render)" || { echo "render failed: $version"; false; }
    # The exec-form template as is, SessionStart aside.
    printf '%s\n' "$out" | jq -e --argjson guards "$GUARDS" --slurpfile t "$TEMPLATE" "$GUARD_OF"'
      ([.hooks.PreToolUse[].hooks[] | select(.onFailure == "block") | guard_of] | sort == $guards)
      and del(.hooks.SessionStart) == ($t[0] | del(.hooks.SessionStart))
    ' >/dev/null || { echo "$version: $out"; false; }
  done
}

# sha256 of `jq -cS '.hooks | del(.SessionStart)'` over the template as it was
# before exec form (641b7873e): the shell-form wiring a legacy client gets.
LEGACY_HOOKS_SHA256=b0ef593136abb7607fe68405cdcd6479b27a0ae1406a190db493af9cb15c167f

# legacy_case <case>: a claude below the floor, unreadable, or missing.
legacy_case() {
  case "$1" in
    unreadable) printf '#!/bin/sh\necho "Claude Code"\n' > "$SANDBOX/claude-bin/claude"
      chmod 755 "$SANDBOX/claude-bin/claude" ;;
    missing) rm -f "$SANDBOX/claude-bin/claude" ;;
    *) stub_claude "$1" ;;
  esac
}

# run_hook <render> <jq-path-to-hook> <stdin>: the hook's `.command` as a
# shell-only client runs it — one `sh -c` string, `args` ignored.
run_hook() {
  local cmd
  cmd="$(jq -r "$2.command" "$1")"
  printf '%s' "$3" | env -i HOME="$SANDBOX/home" CLAUDE_PROJECT_DIR="$SANDBOX/proj" \
    PATH="$(dirname "$(command -v jq)"):/usr/bin:/bin" /bin/sh -c "$cmd"
}

@test "below 2.1.295 or when claude cannot be read, the render is the pre-exec shell-form wiring" {
  local case out supported
  stub_claude 2.1.295
  supported="$(render)"
  for case in 2.1.294 2.1.138 2.0.999 unreadable missing; do
    legacy_case "$case"
    out="$(render)" || { echo "render failed: $case"; false; }
    [ "$(printf '%s\n' "$out" | jq -cS '.hooks | del(.SessionStart)' | shasum -a 256 | cut -d' ' -f1)" = \
      "$LEGACY_HOOKS_SHA256" ] || { echo "$case: hooks are not the pre-exec wiring"; false; }
    # Everything outside .hooks, and the contextual SessionStart, is the
    # supported render's.
    printf '%s\n' "$out" | jq -e --argjson s "$supported" '
      del(.hooks) == ($s | del(.hooks)) and .hooks.SessionStart == $s.hooks.SessionStart
      and ([.. | objects | select(has("args") or has("onFailure") or has("if"))] | length) == 0
    ' >/dev/null || { echo "$case: render differs outside the hook wiring"; false; }
    # Each guard keeps the sanitizing supervisor entry and the 30 s budget.
    printf '%s\n' "$out" | jq -e --argjson guards "$GUARDS" '
      [.hooks.PreToolUse[].hooks[] | select(.command | contains("guard-supervise"))
       | select(.timeout == 30 and (.command | contains("env -u PERL5OPT -u PERL5LIB -u PERLLIB -u PERL5DB -u ENV -u BASH_ENV perl")))
       | .command | capture("claude (?<g>[a-z-]+) \"").g] | sort == $guards
    ' >/dev/null || { echo "$case: guard entries lost the supervisor or budget"; false; }
  done
}

@test "the legacy wiring registers the same events and hook scripts as the template" {
  local out
  legacy_case missing
  out="$(render)"
  printf '%s\n' "$out" | jq -e --slurpfile t "$TEMPLATE" '
    def scripts: [.hooks[][].hooks[] | [.command] + (.args // []) | join(" ")
                  | scan("/(?:hooks/|lib/)[a-z-]+\\.(?:sh|pl)")] | unique;
    (.hooks | keys) == ($t[0].hooks | keys) and (del(.hooks.SessionStart) | scripts)
      == ($t[0] | del(.hooks.SessionStart) | scripts)
  ' >/dev/null
}

# A shell-only client runs `.command` and nothing else. Each hook outside
# SessionStart must start its own script with TRELLIS_ROOT set.
@test "a shell-only client running the legacy render starts every hook script" {
  local out hooks="$SANDBOX/proj/.trellis/runtime/core-rules/hooks" log="$SANDBOX/hooks.log"
  local path name want got
  legacy_case 2.1.294
  out="$SANDBOX/render.json"
  render > "$out"
  mkdir -p "$hooks/lib"
  cp "$REPO/core-rules/hooks/lib/guard-supervise.pl" "$hooks/lib/"
  for name in $(jq -r '[.hooks[][].hooks[].command | scan("/hooks/([a-z-]+)\\.sh") | .[0]] | unique[]' "$out"); do
    printf '#!/bin/sh\ncat >/dev/null\nprintf "%%s %%s\\n" %s "$TRELLIS_ROOT" >> %s\n' "$name" "$log" > "$hooks/$name.sh"
    chmod 755 "$hooks/$name.sh"
  done
  [ "$(jq '[.hooks | to_entries[] | select(.key != "SessionStart") | .value[].hooks[]] | length' "$out")" -eq 18 ]
  for path in $(jq -c 'paths(objects and has("type")) | select(.[1] != "SessionStart")' "$out"); do
    want="$(jq -r --argjson p "$path" 'getpath($p).command | [scan("/hooks/([a-z-]+)\\.sh")] | last[0]' "$out")"
    : > "$log"
    run_hook "$out" "getpath($path)" '{}' >/dev/null
    got="$(cat "$log")"
    [ "$got" = "$want $SANDBOX/proj/.trellis/runtime" ] || { echo "$path ($want) ran: '$got'"; false; }
  done
}

# rm -r on an absolute path is not in permissions.deny (that names only rm -rf
# and rm -fr forms), so on a legacy client only the guard stops it.
@test "a shell-only client running the legacy render still denies through block-destructive" {
  local out deny cmd payload pattern rule
  deny='rm -r /tmp/claude-settings-never-executed'
  legacy_case 2.1.138
  out="$SANDBOX/render.json"
  render > "$out"
  while IFS= read -r rule; do
    pattern="${rule#Bash(}" pattern="${pattern%)}"
    # shellcheck disable=SC2053
    [[ "$deny" != $pattern ]] || { echo "permissions.deny covers it: $rule"; false; }
  done < <(jq -r '.permissions.deny[] | select(startswith("Bash("))' "$out")
  mkdir -p "$SANDBOX/proj/.trellis"
  ln -s "$REPO" "$SANDBOX/proj/.trellis/runtime"
  cmd='.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[0]'
  payload="$(jq -cn --arg c "$deny" --arg d "$SANDBOX/proj" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c},cwd:$d}')"
  run run_hook "$out" "$cmd" "$payload"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf '%s\n' "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"
    and (.hookSpecificOutput.permissionDecisionReason | test("Blocked destructive rm"))' >/dev/null ||
    { echo "no guard deny: $output"; false; }
  payload="$(jq -cn --arg d "$SANDBOX/proj" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"ls /tmp"},cwd:$d}')"
  run run_hook "$out" "$cmd" "$payload"
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "allow case: $status $output"; false; }
}

@test "render reads claude from the forwarded caller PATH" {
  local out
  mkdir -p "$SANDBOX/caller-bin"
  printf '#!/bin/sh\necho "2.1.300 (Claude Code)"\n' > "$SANDBOX/caller-bin/claude"
  chmod 755 "$SANDBOX/caller-bin/claude"
  out="$(render "$SANDBOX/caller-bin:/usr/bin")"
  printf '%s\n' "$out" | jq -e '[.. | objects | select(.onFailure == "block")] | length == 3' >/dev/null
}

# An npm-style `#!/usr/bin/env node` claude needs its runtime from the caller
# PATH too, not only the CLI.
@test "render runs a claude whose shebang runtime is only on the forwarded caller PATH" {
  local out
  mkdir -p "$SANDBOX/caller-bin"
  printf '#!/usr/bin/env claude-stub-runtime\n' > "$SANDBOX/caller-bin/claude"
  printf '#!/bin/sh\necho "2.1.300 (Claude Code)"\n' > "$SANDBOX/caller-bin/claude-stub-runtime"
  chmod 755 "$SANDBOX/caller-bin/claude" "$SANDBOX/caller-bin/claude-stub-runtime"
  out="$(render "$SANDBOX/caller-bin:/usr/bin:/bin")"
  printf '%s\n' "$out" | jq -e '[.. | objects | select(.onFailure == "block")] | length == 3' >/dev/null
}

@test "the bench spawns exec-form hooks directly and honours a Bash if filter" {
  run python3 -I - "$REPO/scripts/bench/trellis-latency.py" "$TEMPLATE" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("bench", sys.argv[1])
bench = importlib.util.module_from_spec(spec)
sys.modules["bench"] = bench
spec.loader.exec_module(bench)
hooks = json.load(open(sys.argv[2]))["hooks"]
def names(command):
    stdin = json.dumps({"tool_input": {"command": command}}).encode()
    members = bench.matched_hooks(hooks, "PreToolUse", "Bash", "/p", stdin)
    return [m.name for m in members], [m.command() for m in members]
plain, argv = names("git status --short")
gh, _ = names("sudo gh pr create")
assert plain == ["block-destructive"], plain
assert argv[0][:2] == ["/usr/bin/env", "TRELLIS_ROOT=/p/.trellis/runtime"], argv
assert argv[0][-1] == "/p/.trellis/runtime/core-rules/hooks/block-destructive.sh", argv
assert gh == ["block-destructive", "pr-gate-shiftleft"], gh
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
