#!/usr/bin/env bats

ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

# This is a closed exception list: adding a hook here requires a corresponding
# exact local-template registration assertion below.
is_local_template_only_hook() {
  case "$1" in
    wiki-skill-suggest.sh|hookspath-guard.sh) return 0 ;;
    *) return 1 ;;
  esac
}

# Spec 072 U4: SessionStart runs these through session-start.sh, the one
# registered SessionStart command; no manifest wires them directly.
is_session_start_dispatched_hook() {
  case "$1" in
    session-context.sh|post-compact-context.sh|inject-primer-index.sh) return 0 ;;
    *) return 1 ;;
  esac
}

# Retired from every manifest by 1.3.12 (E-15). The scripts stay as shims; the
# registration test below asserts they are absent.
is_retired_registration_hook() {
  case "$1" in
    skill-size-preflight.sh|truncation-check.sh|propose-rules.sh|primer-capture-nudge.sh) return 0 ;;
    *) return 1 ;;
  esac
}

@test "canonical hook README lists every shipped Claude hook script" {
  local script base
  while IFS= read -r script; do
    base="${script##*/}"
    grep -qF -- "\`$base\`" "$ROOT/core-rules/hooks/README.md" || {
      echo "missing from canonical hook inventory: $base"
      return 1
    }
  done < <(find "$ROOT/core-rules/hooks" -maxdepth 1 -type f -name '*.sh' | sort)
}

# spec 1.3.12 (E-15): these hooks keep their scripts but are no longer
# registered in any manifest. Adding one back needs this list edited.
@test "retired hook registrations are absent and the kept guards and tripwire remain" {
  local manifest name
  for manifest in core-rules/templates/claude-settings.local.json core-rules/templates/claude-settings.json \
    core-rules/templates/codex-hooks.local.json core-rules/codex/hooks.json; do
    for name in skill-size-preflight truncation-check propose-rules primer-capture-nudge; do
      jq -e --arg name "$name" '
        [.hooks[][]?.hooks[]? | [.command] + (.args // []) | join(" ") | select(contains($name))] | length == 0
      ' "$ROOT/$manifest" >/dev/null || {
        echo "retired hook still registered in $manifest: $name"
        return 1
      }
    done
  done
  while IFS='|' read -r manifest name; do
    jq -e --arg name "/$name.sh" '
      [.hooks[][]?.hooks[]? | [.command] + (.args // []) | join(" ") | select(contains($name))] | length == 1
    ' "$ROOT/$manifest" >/dev/null || {
      echo "kept hook not wired exactly once in $manifest: $name"
      return 1
    }
  done <<'EOF'
core-rules/templates/claude-settings.local.json|slop-tripwire
core-rules/templates/claude-settings.local.json|pr-gate-shiftleft
core-rules/templates/claude-settings.local.json|block-destructive
core-rules/templates/claude-settings.local.json|reread-guard
core-rules/templates/claude-settings.local.json|skill-preload-guard
core-rules/templates/claude-settings.local.json|skill-slash-guard
core-rules/templates/claude-settings.json|slop-tripwire
core-rules/templates/claude-settings.json|pr-gate-shiftleft
core-rules/templates/claude-settings.json|skill-preload-guard
core-rules/templates/codex-hooks.local.json|slop-tripwire
core-rules/templates/codex-hooks.local.json|pr-gate-shiftleft
core-rules/templates/codex-hooks.local.json|block-destructive
core-rules/templates/codex-hooks.local.json|reread-guard
core-rules/codex/hooks.json|slop-tripwire
core-rules/codex/hooks.json|pr-gate-shiftleft
EOF
}

@test "legacy Claude settings wire every hook not declared local-template-only" {
  local script base
  while IFS= read -r script; do
    base="${script##*/}"
    # User-global hooks (Herdr role resolution, the spec 069 A7 worktree
    # hooks) ship beside project hooks for release packaging, but must not be
    # duplicated in each attached project's canonical settings.
    case "$base" in
      herdr-foreman-session.sh|trellis-worktree-create.sh|trellis-worktree-remove.sh) continue ;;
    esac
    is_local_template_only_hook "$base" && continue
    is_retired_registration_hook "$base" && continue
    is_session_start_dispatched_hook "$base" && continue
    jq -e --arg base "$base" \
      '[.hooks[][]?.hooks[]? | [.command] + (.args // []) | join(" ") | select(endswith("/" + $base) or endswith("/" + $base + "\""))] | length == 1' \
      "$ROOT/core-rules/templates/claude-settings.json" >/dev/null || {
        echo "missing or duplicate canonical hook wiring: $base"
        return 1
      }
  done < <(find "$ROOT/core-rules/hooks" -maxdepth 1 -type f -name '*.sh' | sort)
}

@test "SessionStart context hooks run only through the session-start dispatcher" {
  local manifest name dispatcher
  for manifest in core-rules/templates/claude-settings.local.json core-rules/templates/claude-settings.json \
    core-rules/templates/codex-hooks.local.json; do
    jq -e '[.hooks.SessionStart[].hooks[].command | select(contains("session-start"))] | length == 1' \
      "$ROOT/$manifest" >/dev/null || { echo "session-start not wired exactly once in $manifest"; false; }
    for name in session-context post-compact-context inject-primer-index; do
      jq -e --arg name "$name" '[.. | strings | select(contains($name))] | length == 0' "$ROOT/$manifest" >/dev/null ||
        { echo "$name wired directly in $manifest"; false; }
    done
  done
  for dispatcher in core-rules/hooks/session-start.sh core-rules/codex/hooks/session-start.sh; do
    grep -qxF '  startup|resume) __ss_hooks="session-context.sh inject-primer-index.sh" ;;' "$ROOT/$dispatcher"
    grep -qxF '  compact) __ss_hooks="post-compact-context.sh" ;;' "$ROOT/$dispatcher"
  done
}

# The plan's wiring alarm (spec 072 U4): the attach-rendered Claude template and
# the legacy direct-copy one must register the same hooks, in the same order,
# with the same matchers, timeouts and status messages; only the hook root may
# differ. The declared exceptions are the closed local-template-only list above
# and env-echo.sh, the legacy surfaces' environment probe. The attach-rendered
# template may use exec form (command /usr/bin/env plus args, spec 072 T12), so
# a hook is identified by the scripts it invokes, from either form. A hook the
# exec form narrows with an `if` filter may carry its own timeout.
_claude_template_hooks() {
  jq -c --arg skip "$2" '
    def scripts:
      [scan("(?:\\.trellis/runtime/core-rules/hooks|\\.claude/hooks)/((?:lib/)?[a-z-]+\\.(?:sh|pl))")[0]]
      + (if test(" __TRELLIS_LAUNCHER__ hook session-start claude ") then ["session-start.sh"] else [] end);
    [.hooks | to_entries[] | .key as $event | .value[] | (.matcher // "") as $matcher | .hooks[]
     | {event: $event, matcher: $matcher, type, statusMessage,
        timeout: (if has("if") then "if-filtered" else .timeout end),
        scripts: (([.command] + (.args // [])) | join(" ") | scripts)}
     | select([.scripts[] | select(endswith(".sh")) | sub("\\.sh$"; "")] | last | IN($skip | split(" ")[]) | not)]
  ' "$1"
}

@test "the attach-rendered and legacy Claude templates register the same hooks but for the hook root" {
  local local_hooks legacy_hooks
  local_hooks="$(_claude_template_hooks "$ROOT/core-rules/templates/claude-settings.local.json" "wiki-skill-suggest hookspath-guard")"
  legacy_hooks="$(_claude_template_hooks "$ROOT/core-rules/templates/claude-settings.json" "env-echo")"
  legacy_hooks="$(jq -cn --argjson l "$local_hooks" --argjson g "$legacy_hooks" \
    '[range(0; $g | length) as $i | $g[$i]
      | if $l[$i].timeout == "if-filtered" then .timeout = "if-filtered" else . end]')"
  [ "$(printf '%s' "$local_hooks" | jq 'length')" -ge 17 ]
  [ "$local_hooks" = "$legacy_hooks" ] || {
    diff <(printf '%s' "$local_hooks" | jq .) <(printf '%s' "$legacy_hooks" | jq .)
    false
  }
}

@test "explicit local-template-only hooks are wired once locally and absent from legacy manifests" {
  local template legacy hook_path base
  while IFS='|' read -r template legacy hook_path; do
    base="${hook_path##*/}"
    jq -e --arg suffix "/$hook_path\"" '
      [.hooks[][]?.hooks[]? | [.command] + (.args // []) | join(" ")
       | select(endswith($suffix) or endswith($suffix | rtrimstr("\""))) ] | length == 1
    ' "$ROOT/$template" >/dev/null || {
      echo "missing or duplicate local-template hook wiring: $template -> $hook_path"
      return 1
    }
    jq -e --arg base "$base" '
      [.hooks[][]?.hooks[]? | [.command] + (.args // []) | join(" ") | select(contains("/" + $base))] | length == 0
    ' "$ROOT/$legacy" >/dev/null || {
      echo "local-template-only hook leaked into legacy manifest: $legacy -> $base"
      return 1
    }
  done <<'EOF'
core-rules/templates/claude-settings.local.json|core-rules/templates/claude-settings.json|core-rules/hooks/wiki-skill-suggest.sh
core-rules/templates/codex-hooks.local.json|core-rules/codex/hooks.json|core-rules/codex/hooks/wiki-skill-suggest.sh
EOF
}

# spec 055 R4.4: the advisory PostToolUse(Bash) hookspath-guard is wired once per
# local template behind a missing-script guard, so a rollback to a payload that
# lacks it leaves Bash working. It is the one command with that guard, and it
# falls back to nothing.
@test "hookspath-guard is wired once per local template behind a missing-script guard" {
  local template legacy hook_path prefix command expected
  while IFS='|' read -r template legacy hook_path prefix; do
    command="$(jq -r --arg path "$hook_path" '
      [.hooks.PostToolUse[] | select(.matcher == "Bash") | .hooks[] | .command
       | select(contains("/" + $path + "\""))] | if length == 1 then .[0] else error("not wired once") end
    ' "$ROOT/$template")" || { echo "hookspath-guard not wired exactly once in $template"; false; }
    expected="h=\"$prefix/.trellis/runtime/$hook_path\"; [ -f \"\$h\" ] || exit 0; TRELLIS_ROOT=\"$prefix/.trellis/runtime\" \"\$h\""
    [ "$command" = "$expected" ] || { printf 'got:  %s\nwant: %s\n' "$command" "$expected"; false; }
    jq -e '[.. | strings | select(contains("hookspath-guard"))] | length == 1' "$ROOT/$template" >/dev/null
    jq -e '[.. | strings | select(contains("|| exit 0"))] | length == 1' "$ROOT/$template" >/dev/null
    jq -e '[.. | strings | select(contains("hookspath-guard"))] | length == 0' "$ROOT/$legacy" >/dev/null ||
      { echo "hookspath-guard leaked into legacy manifest $legacy"; false; }
  done <<'EOF'
core-rules/templates/codex-hooks.local.json|core-rules/codex/hooks.json|core-rules/codex/hooks/hookspath-guard.sh|${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}
EOF
  # Claude spawns the same missing-script guard in exec form: /bin/sh, not the
  # user's shell, with the script path and runtime as $1 and $2.
  jq -e '
    [.hooks.PostToolUse[] | select(.matcher == "Bash") | .hooks[]
     | select(any(.args[]?; contains("hookspath-guard.sh")))]
    == [{type: "command", command: "/bin/sh",
         args: ["-c", "[ -f \"$1\" ] || exit 0; TRELLIS_ROOT=\"$2\" exec \"$1\"", "hookspath-guard",
                "${CLAUDE_PROJECT_DIR}/.trellis/runtime/core-rules/hooks/hookspath-guard.sh",
                "${CLAUDE_PROJECT_DIR}/.trellis/runtime"],
         timeout: 10, statusMessage: "Checking git hooks path..."}]
    and ([.. | strings | select(contains("|| exit 0"))] | length == 1)
  ' "$ROOT/core-rules/templates/claude-settings.local.json" >/dev/null
  jq -e '[.. | strings | select(contains("hookspath-guard"))] | length == 0' \
    "$ROOT/core-rules/templates/claude-settings.json" >/dev/null
}

# Every script at the top of a hook directory is EXECUTED by path — both harness
# templates put the bare path in a `command`, with no `bash` prefix — so a hook
# without the executable bit returns 126 in every attached project and the
# harness reports a hook failure, not a gate result. `core-rules/hooks/spec-gate.sh`
# and its Codex twin shipped 100644 from 2026-07-07 until the T34 gate: the
# mandatory-pipeline Stop hook was dead on arrival everywhere it was installed,
# and nothing in the tree noticed. Sourced libraries live one level down under
# `lib/` and are correctly non-executable; this only looks at maxdepth 1.
#
# Where the fix lives, since the commit subjects point elsewhere: the two
# 100644→100755 mode changes are carried by 72f3350 ("unchain the BSD/GNU stat
# probes in six suites"), which shows them as mode-only entries. The commit
# whose subject claims the fix, e6f0bd2 ("make spec-gate executable in both
# harness trees"), adds only the two cases below. Bisect order is safe — 72f3350
# precedes e6f0bd2 — but `git log -- core-rules/hooks/spec-gate.sh` will send a
# reader to the wrong diff without this note.
@test "every shipped hook script is executable in both harness trees" {
  local dir script offenders=""
  for dir in "$ROOT/core-rules/hooks" "$ROOT/core-rules/codex/hooks"; do
    while IFS= read -r script; do
      [ -n "$script" ] || continue
      [ -x "$script" ] || offenders="$offenders ${script#"$ROOT/"}"
    done < <(find "$dir" -maxdepth 1 -type f -name '*.sh' | sort)
  done
  [ -z "$offenders" ] || { echo "hook scripts missing the executable bit:$offenders"; false; }
}

# The working-tree mode is not what ships — `git archive`, a clone and the
# release payload all carry the INDEX mode. A `chmod +x` that was never staged
# looks fixed locally and is still broken for every consumer.
@test "the index agrees that every shipped hook script is mode 100755" {
  local offenders
  # A git pathspec `*` crosses `/`, so the lib/ subdirectory has to be filtered
  # out explicitly — those are sourced, not executed, and are correctly 100644.
  offenders="$(git -C "$ROOT" ls-files -s -- 'core-rules/hooks/*.sh' 'core-rules/codex/hooks/*.sh' |
    awk '$4 !~ /\/lib\// && $1 != "100755" { print $4 }' | tr '\n' ' ')"
  [ -z "$offenders" ] || { echo "hook scripts not 100755 in the index: $offenders"; false; }
}

# --- spec 055 R1.2/R1.5: Codex hook libraries, in place and deployed ----------
#
# The rendered .codex/hooks.json runs Codex hooks IN PLACE from the payload,
# where core-rules/codex/hooks/lib/ holds only the Codex-local libs; the shared
# cores live in core-rules/hooks/lib/. A deployed .codex/hooks/ or .pi/hooks/
# gets every lib as a sibling through the manifest. A hook whose lib resolves in
# one layout only is inert in the other, and a fallback outside the R1.1 guard
# lets a deployed hook source <project>/hooks/lib/. The expected inventory is a
# checked-in list, not derived from the hooks, so a dropped or new reference
# fails here until the list is edited.

# Libraries a Codex hook references by path, comment lines stripped. The
# payload's Python resolver is not a hook lib: it is sourced from scripts/lib/
# only when present and the hook falls back to python3 otherwise, so only that
# optional form is skipped. Any other reference to it is still inventoried.
_codex_hook_lib_refs() {
  local hook base lib
  for hook in "$ROOT"/core-rules/codex/hooks/*.sh; do
    base="${hook##*/}"
    sed -E -e 's/^[[:space:]]*#.*$//' \
      -e '/^[[:space:]]*\. "[^"]*\/scripts\/lib\/trellis-python\.sh" 2>\/dev\/null ;;$/d' "$hook" |
      grep -oiE '(lib|lib_dir)/[A-Za-z0-9_.-]+\.(sh|py)' |
      sed 's|.*/||' | sort -u |
      while IFS= read -r lib; do printf '%s\t%s\n' "$base" "$lib"; done
  done
}

# Lib basenames the manifest links into <harness>'s deployed hooks/lib/.
_deployed_hook_libs() {
  local harness="$1" dir
  jq -r --arg h "$harness" '
    .harnesses[$h].links[]
    | select((.destination // "") | test("^\\.[a-z]+/hooks/lib/[^/]+$"))
    | .destination | split("/") | last
  ' "$ROOT/core-rules/inheritance-manifest.json"
  while IFS= read -r dir; do
    find "$ROOT/$dir" -maxdepth 1 -type f -name '*.sh' -exec basename {} \;
  done < <(jq -r --arg h "$harness" '
    .harnesses[$h].links[]
    | select((.destination_dir // "") | test("^\\.[a-z]+/hooks/lib$"))
    | .source_children
  ' "$ROOT/core-rules/inheritance-manifest.json")
}

# Echo "<lib>" for each ../../hooks/lib fallback in <hook> that sits inside an
# R1.1 guard: the sibling assignment, then the fallback only when the resolved
# script directory equals realpath($TRELLIS_ROOT)/core-rules/codex/hooks. Exit 1
# on any fallback outside a guard. The three suffix-only guards the spec leaves
# for a follow-up (session-context, stop-verify, post-compact-context) are
# accepted in those three files only.
_guarded_fallbacks() {
  local hook="$1" base="${1##*/}" prev="" prev2="" line n=0 var dir rt lib
  local guard_re='^[[:space:]]*if \[ ! -f "\$([A-Za-z_]+)" \] && \[ -n "\$([A-Za-z_]+)" \] && \[ "\$([A-Za-z_]+)" = "\$([A-Za-z_]+)/core-rules/codex/hooks" \]; then$'
  local assign_re='^[[:space:]]*([A-Za-z_]+)="\$([A-Za-z_]+)/\.\./\.\./hooks/lib/([A-Za-z0-9_.-]+)"$'
  local legacy_re='^[[:space:]]*\*/core-rules/codex/hooks\)[[:space:]]+[A-Za-z_]+="\$[A-Za-z_]+/\.\./\.\./hooks/lib/([A-Za-z0-9_.-]+)"[[:space:]]*;;$'
  while IFS= read -r line; do
    n=$((n + 1))
    if [[ "$line" != *"../../hooks/lib/"* ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
      prev2="$prev" prev="$line"
      continue
    fi
    if [[ "$line" =~ $legacy_re ]]; then
      case "$base" in
        session-context.sh|stop-verify.sh|post-compact-context.sh) printf '%s\n' "${BASH_REMATCH[1]}" ;;
        *) echo "$base:$n: suffix-only fallback outside the R1.1 guard: $line"; return 1 ;;
      esac
    elif [[ "$line" =~ $assign_re ]] && var="${BASH_REMATCH[1]}" && dir="${BASH_REMATCH[2]}" && lib="${BASH_REMATCH[3]}" &&
      [[ "$prev" =~ $guard_re ]] && [ "${BASH_REMATCH[1]}" = "$var" ] && [ "${BASH_REMATCH[3]}" = "$dir" ] &&
      rt="${BASH_REMATCH[2]}" && [ "${BASH_REMATCH[4]}" = "$rt" ] &&
      [ "$prev2" = "$var=\"\$$dir/lib/$lib\"" ] &&
      grep -qxF -- "$dir=\$(unset CDPATH; cd -P -- \"\$(dirname -- \"\${BASH_SOURCE[0]}\")\" && pwd -P)" "$hook" &&
      grep -qxF -- "$rt=\$(unset CDPATH; [ -n \"\${TRELLIS_ROOT:-}\" ] && cd -P -- \"\$TRELLIS_ROOT\" 2>/dev/null && pwd -P)" "$hook"; then
      printf '%s\n' "$lib"
    else
      echo "$base:$n: ../../hooks/lib fallback outside the R1.1 guard: $line"
      return 1
    fi
    prev2="$prev" prev="$line"
  done < "$hook"
}

@test "Codex hook libraries match the expected inventory and resolve in place and deployed" {
  local expected actual hook lib codex_libs guarded missing=""
  expected="$(grep -v '^#' "$ROOT/scripts/tests/fixtures/codex-hook-libs.tsv" | sed '/^$/d' | sort)"
  actual="$(_codex_hook_lib_refs | sort)"
  diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") || {
    echo "Codex hook lib references differ from scripts/tests/fixtures/codex-hook-libs.tsv (< expected, > actual)"
    return 1
  }

  codex_libs="$(_deployed_hook_libs codex | sort -u)"
  while IFS=$'\t' read -r hook lib; do
    guarded="$(_guarded_fallbacks "$ROOT/core-rules/codex/hooks/$hook")" || { echo "$guarded"; return 1; }
    if [ ! -f "$ROOT/core-rules/codex/hooks/lib/$lib" ]; then
      { [ -f "$ROOT/core-rules/hooks/lib/$lib" ] && grep -qxF -- "$lib" <<<"$guarded"; } ||
        missing="$missing $hook->$lib(in-place)"
    fi
    grep -qxF -- "$lib" <<<"$codex_libs" || missing="$missing $hook->$lib(.codex)"
  done <<<"$expected"
  [ -z "$missing" ] || { echo "unreachable hook libs:$missing"; false; }

  # R1.2: no fallback anywhere in the tree outside a guard, inventoried or not.
  for hook in "$ROOT"/core-rules/codex/hooks/*.sh; do
    _guarded_fallbacks "$hook" >/dev/null || { _guarded_fallbacks "$hook"; return 1; }
  done
}

# --- spec 055 R1.1a: rendered in-place commands pin TRELLIS_ROOT --------------
#
# The R1.1 fallback is bound to TRELLIS_ROOT. Every rendered in-place command
# must set it to the runtime it executes from, and that runtime must be the
# rendered project's own. The renderer copies in-place commands verbatim, so the
# template is the generator; this pins the rendered output, not the template.

# _check_rendered_roots <rendered.json> <project>: echo the in-place count, or
# fail naming the first bad command.
_check_rendered_roots() {
  local rendered="$1" project="$2" hook cmd root_expr path_expr sup_expr root_val path_val runtime count=0
  local re='^TRELLIS_ROOT="([^"]+)" "([^"]+)"$'
  # The advisory hookspath-guard form (spec 055 R4.4): a missing script exits 0.
  local guarded_re='^h="([^"]+)"; \[ -f "\$h" \] \|\| exit 0; TRELLIS_ROOT="([^"]+)" "\$h"$'
  # Bright-line guards start through the sh entry and guard-supervise.pl (B0-5);
  # the supervisor and the guard must both come from the same runtime.
  local supervised_re="^TRELLIS_ROOT=\"([^\"]+)\" /bin/sh -c '[^']*' guard-supervise \"([^\"]+)/core-rules/hooks/lib/guard-supervise\\.pl\" (claude|codex) [a-z-]+ \"([^\"]+)\"$"
  while IFS= read -r hook; do
    if printf '%s' "$hook" | jq -e 'has("args")' >/dev/null; then
      # Exec form (Claude): no shell; ${CLAUDE_PROJECT_DIR} is substituted in
      # each element as plain text. `/usr/bin/env TRELLIS_ROOT=<root> ... <path>`,
      # or the hookspath-guard sh entry, which takes the path and root as $1, $2.
      printf '%s' "$hook" | jq -e 'any(.args[]; contains(".trellis/runtime/core-rules/"))' >/dev/null || continue
      count=$((count + 1))
      IFS=$'\037' read -r root_expr path_expr sup_expr < <(printf '%s' "$hook" | jq -r '
        if .command == "/usr/bin/env" and (.args[0] | startswith("TRELLIS_ROOT=")) then
          [(.args[0] | ltrimstr("TRELLIS_ROOT=")), .args[-1],
           ((.args | index("guard-supervise")) as $i | if $i == null then "-" else .args[$i + 1] end)]
        elif .command == "/bin/sh" and .args[2] == "hookspath-guard" then [.args[4], .args[3], "-"]
        else ["-", "-", "-"] end | join("\u001f")')
      [ "$root_expr" != - ] || { echo "no TRELLIS_ROOT prefix: $hook"; return 1; }
      if [ "$sup_expr" != - ] && [ "${sup_expr%/core-rules/hooks/lib/guard-supervise.pl}" != "$root_expr" ]; then
        echo "supervisor outside TRELLIS_ROOT: $hook"
        return 1
      fi
      root_val="${root_expr//\$\{CLAUDE_PROJECT_DIR\}/$project}"
      path_val="${path_expr//\$\{CLAUDE_PROJECT_DIR\}/$project}"
      cmd="$hook"
    else
      cmd="$(printf '%s' "$hook" | jq -r '.command')"
      [[ "$cmd" == *".trellis/runtime/core-rules/"* ]] || continue
      count=$((count + 1))
      if [[ "$cmd" =~ $re ]]; then
        root_expr="${BASH_REMATCH[1]}" path_expr="${BASH_REMATCH[2]}"
      elif [[ "$cmd" =~ $guarded_re ]]; then
        path_expr="${BASH_REMATCH[1]}" root_expr="${BASH_REMATCH[2]}"
      elif [[ "$cmd" =~ $supervised_re ]] && [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ]; then
        root_expr="${BASH_REMATCH[1]}" path_expr="${BASH_REMATCH[4]}"
      else
        echo "no TRELLIS_ROOT prefix: $cmd"
        return 1
      fi
      root_val="$(cd "$project" && env -i PATH="$PATH" CODEX_PROJECT_DIR="$project" CLAUDE_PROJECT_DIR="$project" bash -c "printf '%s' \"$root_expr\"")"
      path_val="$(cd "$project" && env -i PATH="$PATH" CODEX_PROJECT_DIR="$project" CLAUDE_PROJECT_DIR="$project" bash -c "printf '%s' \"$path_expr\"")"
    fi
    runtime="${path_val%%/core-rules/*}"
    [ "$runtime" = "$project/.trellis/runtime" ] || { echo "runs outside its project's runtime: $cmd"; return 1; }
    [ "$(cd -P "$root_val" 2>/dev/null && pwd -P)" = "$(cd -P "$runtime" && pwd -P)" ] ||
      { echo "TRELLIS_ROOT is not the runtime the command runs from: $cmd"; return 1; }
  done < <(jq -c '.. | objects | select(.command? | type == "string")' "$rendered")
  printf '%s\n' "$count"
}

# Renders under a pinned Claude Code (RENDER_HOME/claude-bin, when a test
# provides one) rather than whatever claude the host has installed.
_render_template() {
  env -u TRELLIS_ATTACH_CALLER_PATH HOME="$RENDER_HOME" PATH="$RENDER_HOME/claude-bin:$PATH" bash -c '
    . "$1/scripts/lib/attachment.sh" || exit 90
    context="$(attachment_contextual_render_context "$2")" || exit 91
    attachment_contextual_template_render "$3" "$4" "$context"
  ' _ "$ROOT" "$RENDER_TRELLIS_HOME" "$1" "$2"
}

@test "rendered in-place hook commands set TRELLIS_ROOT to their own project's runtime" {
  local tmp project other entry name out count
  tmp="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  RENDER_HOME="$tmp/home" RENDER_TRELLIS_HOME="$tmp/trellis-home"
  project="$tmp/project" other="$tmp/other"
  mkdir -p "$RENDER_HOME/.local/bin" "$RENDER_TRELLIS_HOME" "$project/.trellis" "$other/.trellis" \
    "$tmp/payload-a" "$tmp/payload-b"
  printf '#!/bin/sh\n' > "$RENDER_HOME/.local/bin/trellis"
  chmod +x "$RENDER_HOME/.local/bin/trellis"
  mkdir -p "$RENDER_HOME/claude-bin"
  printf '#!/bin/sh\necho "2.1.300 (Claude Code)"\n' > "$RENDER_HOME/claude-bin/claude"
  chmod +x "$RENDER_HOME/claude-bin/claude"
  ln -s "$tmp/payload-a" "$project/.trellis/runtime"
  ln -s "$tmp/payload-b" "$other/.trellis/runtime"

  for entry in claude-settings.local.json:18 codex-hooks.local.json:16; do
    name="${entry%%:*}" out="$tmp/rendered-$name"
    _render_template "$ROOT/core-rules/templates/$name" "core-rules/templates/$name" > "$out"
    count="$(_check_rendered_roots "$out" "$project")" || { echo "$name: $count"; false; }
    [ "$count" -eq "${entry##*:}" ] || { echo "$name: $count in-place commands"; false; }

    # Inversion 1: one command loses its TRELLIS_ROOT prefix (exec form: the
    # TRELLIS_ROOT= element).
    jq '(first(paths(strings) as $p | select(($p | last) == "command")
            | select(getpath($p) | contains(".trellis/runtime/core-rules/")) | $p) // null) as $p
        | if $p == null
          then (first(paths(arrays) as $a | select(($a | last) == "args")
                  | select(getpath($a)[0] | startswith("TRELLIS_ROOT=")) | $a)) as $a
               | setpath($a; getpath($a)[1:])
          else setpath($p; getpath($p) | sub("^TRELLIS_ROOT=\"[^\"]+\" "; "")) end' \
      "$ROOT/core-rules/templates/$name" > "$tmp/no-root-$name"
    _render_template "$tmp/no-root-$name" "core-rules/templates/$name" > "$out"
    if _check_rendered_roots "$out" "$project" >/dev/null; then echo "$name: mutated render accepted"; false; fi

    # Inversion 2: one command names another project's runtime.
    jq --arg other "$other/.trellis/runtime" \
      '(first(paths(strings) as $p | select(($p | last) == "command")
            | select(getpath($p) | contains(".trellis/runtime/core-rules/")) | $p) // null) as $p
        | if $p == null
          then (first(paths(arrays) as $a | select(($a | last) == "args")
                  | select(getpath($a)[0] | startswith("TRELLIS_ROOT=")) | $a)) as $a
               | setpath($a + [0]; "TRELLIS_ROOT=" + $other)
          else setpath($p; getpath($p) | sub("^TRELLIS_ROOT=\"[^\"]+\""; "TRELLIS_ROOT=\"" + $other + "\"")) end' \
      "$ROOT/core-rules/templates/$name" > "$tmp/wrong-project-$name"
    _render_template "$tmp/wrong-project-$name" "core-rules/templates/$name" > "$out"
    if _check_rendered_roots "$out" "$project" >/dev/null; then echo "$name: mutated render accepted"; false; fi
  done

  # pi runs the payload hooks in place (1.3.18 renders no .pi/hooks), with the same binding.
  grep -qF "RUNTIME = Path.cwd() / '.trellis/runtime'" "$ROOT/core-rules/pi/hooks/dispatch.sh"
  grep -qF "env = dict(os.environ, CODEX_PROJECT_DIR=cwd, TRELLIS_ROOT=str(RUNTIME), TRELLIS_HARNESS='pi')" "$ROOT/core-rules/pi/hooks/dispatch.sh"
}

@test "the contextual renderer pins the one SessionStart launcher route per harness and refuses a retired route" {
  local tmp name routes
  tmp="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  RENDER_HOME="$tmp/home" RENDER_TRELLIS_HOME="$tmp/trellis-home"
  mkdir -p "$RENDER_HOME/.local/bin" "$RENDER_TRELLIS_HOME"
  printf '#!/bin/sh\n' > "$RENDER_HOME/.local/bin/trellis"
  chmod +x "$RENDER_HOME/.local/bin/trellis"

  for name in claude-settings.local.json codex-hooks.local.json; do
    routes="$(jq -r '.hooks.SessionStart[].hooks[].command
      | capture("__TRELLIS_LAUNCHER__ hook (?<r>[a-z-]+) ").r' "$ROOT/core-rules/templates/$name" | tr '\n' ' ')"
    [ "$routes" = "session-start " ] || { echo "$name: $routes"; false; }
    _render_template "$ROOT/core-rules/templates/$name" "core-rules/templates/$name" > "$tmp/ok-$name"
    jq -e '[.. | strings | select(contains("__TRELLIS_"))] | length == 0' "$tmp/ok-$name" >/dev/null

    # A pre-1.3.12 template still carries skill-size-preflight; this release's
    # renderer must refuse it rather than render a route its dispatcher drops.
    jq '.hooks.SessionStart[0].hooks += [.hooks.SessionStart[0].hooks[0]
        | .command |= sub(" hook session-start "; " hook skill-size-preflight ")]' \
      "$ROOT/core-rules/templates/$name" > "$tmp/retired-$name"
    run _render_template "$tmp/retired-$name" "core-rules/templates/$name"
    [ "$status" -ne 0 ] || { echo "$name: retired fourth route rendered"; false; }
  done
}
