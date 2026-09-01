#!/usr/bin/env bash
# pr-gate-shiftleft.sh — Codex PreToolUse(Bash) advisory process-gate.
# Source: Trellis / core-rules / codex hooks (Spec 005 C3 / T-P4d).
#
# Contract:
#   - Reads a Codex PreToolUse JSON envelope from stdin.
#   - Runs only when a shell command contains an actual `gh pr create`
#     command (not prose such as `echo gh pr create` or `gh pr view`).
#   - Invokes the project's process-gate pre-flight with the standard
#     `--range=main..HEAD` interface.
#   - Every result is advisory: output is hookSpecificOutput additionalContext
#     and this hook always exits 0 after a valid trigger. CI and branch
#     protection remain authoritative; this hook never emits a block decision.
#   - The process-gate invocation has a portable perl-alarm process-group
#     timeout. GNU `timeout`/`gtimeout` are deliberately not used.
#
# Runner resolution:
#   PR_GATE_SHIFTLEFT_RUNNER (or PROCESS_GATE_RUNNER) may name a runner for
#   tests/operator overrides. Otherwise the installed project skill is used:
#   Codex prefers .agents/skills/process-gate, Claude is the fallback.
#
# Budget:
#   PR_GATE_SHIFTLEFT_TIMEOUT or PROCESS_GATE_SHIFTLEFT_TIMEOUT, default 90s.
#   A timeout is advisory and exits 0; the child process group is terminated.

set -u

INPUT="$(cat 2>/dev/null || true)"
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# This hook is advisory. A project with an older copied hook tree should not
# lose the Bash permission flow merely because the new shared lib is absent.
__pg_lib="$HOOK_DIR/lib/deps.sh"
[ -f "$__pg_lib" ] || exit 0
# shellcheck source=lib/deps.sh disable=SC1090
. "$__pg_lib"
_se_require_jq "pr-gate-shiftleft"

# Parse exactly one JSON value and require a string command. Malformed or
# unrelated envelopes are a silent no-op, which keeps the hook safe when the
# harness sends an event shape from another tool family.
COMMAND="$(printf '%s' "$INPUT" | jq -r -s '
  if length != 1 then empty
  elif (.[0] | type) != "object" then empty
  elif (.[0].tool_input | type) != "object" then empty
  elif (.[0].tool_input.command | type) != "string" then empty
  else .[0].tool_input.command
  end
' 2>/dev/null || true)"
[ -n "$COMMAND" ] || exit 0

# The manifest already scopes this script to Bash. Keep the guard defensive
# when a caller invokes the file directly or a harness sends another tool's
# envelope; envelopes used by narrow fixtures may omit tool_name entirely.
TOOL_NAME="$(printf '%s' "$INPUT" | jq -r -s '
  if length == 1 and (.[0] | type) == "object" then
    (.[0].tool_name // "")
  else
    empty
  end
' 2>/dev/null || true)"
case "$TOOL_NAME" in
  ""|Bash) ;;
  *) exit 0 ;;
esac

# Scan shell text without evaluating it. The scanner is intentionally
# conservative: only an actual logical command (or one of the explicit safe
# wrappers below) can reach the `gh pr create` token sequence. Heredoc bodies
# are skipped before lexical scanning, so prose copied into a PR body cannot
# trigger the local process-gate.
_pg_has_gh_pr_create() {
  local input="$1"
  local line ch next next2
  local i line_len
  local quote="" comment=0 escape=0
  local token="" token_started=0
  local redirection_target=0
  local stage=0 wrapper="" wrapper_skip=0
  local found=0
  local heredoc_count=0 heredoc_head=0
  local heredoc_delim heredoc_compare heredoc_strip
  local delimiter_quote delimiter_char delimiter_start
  local j
  local line_count=0
  local max_lines=8192
  local -a heredoc_delims=()
  local -a heredoc_strip_tabs=()
  # `$(` inside a double-quoted word starts a nested logical command. Keep
  # the quote/context stack bounded so this remains a scanner, not eval.
  local quoted_subshell_depth=0
  local max_quoted_subshell_depth=32
  local -a quoted_subshell_quotes=()
  local -a quoted_subshell_parens=()

  # stage 0: command start; 1/2: gh/pr seen; 4: safe wrapper seen.
  # A wrapper may be chained, but arbitrary commands/options never pass
  # through this state. This is what keeps `sudo echo gh pr create` inert.
  _pg_finish_word() {
    local word="$token"
    if [ "$redirection_target" -eq 1 ]; then
      if [ "$token_started" -eq 1 ]; then
        token=""
        token_started=0
        redirection_target=0
      fi
      return 0
    fi
    [ "$token_started" -eq 1 ] || return 0
    token=""
    token_started=0

    case "$stage" in
      0)
        case "$word" in
          gh) stage=1 ;;
          command|exec|env|sudo|nohup|time)
            stage=4
            wrapper="$word"
            wrapper_skip=0
            ;;
          if|then|else|elif|while|until|do|done|case|'esac'|in|!)
            stage=0
            ;;
          [A-Za-z_]*=*)
            # Shell assignment words may precede the executable.
            stage=0
            ;;
          *) stage=-1 ;;
        esac
        ;;
      1)
        if [ "$word" = "pr" ]; then
          stage=2
        else
          stage=-1
        fi
        ;;
      2)
        if [ "$word" = "create" ]; then
          found=1
        else
          stage=-1
        fi
        ;;
      4)
        if [ "$wrapper_skip" -eq 1 ]; then
          wrapper_skip=0
          return 0
        fi
        case "$wrapper" in
          command)
            case "$word" in
              gh) stage=1 ;;
              command|exec|env|sudo|nohup|time) wrapper="$word" ;;
              --|-p) ;;
              -v|-V) stage=-1 ;;
              *) stage=-1 ;;
            esac
            ;;
          exec)
            case "$word" in
              gh) stage=1 ;;
              command|exec|env|sudo|nohup|time) wrapper="$word" ;;
              -a) wrapper_skip=1 ;;
              -c|-l|--) ;;
              *) stage=-1 ;;
            esac
            ;;
          env)
            case "$word" in
              gh) stage=1 ;;
              command|exec|env|sudo|nohup|time) wrapper="$word" ;;
              [A-Za-z_]*=*) ;;
              --|-i|--ignore-environment|-0|--null) ;;
              -u|--unset) wrapper_skip=1 ;;
              *) stage=-1 ;;
            esac
            ;;
          sudo)
            case "$word" in
              gh) stage=1 ;;
              command|exec|env|sudo|nohup|time) wrapper="$word" ;;
              --|-n|-E|-H|-k|-K|-S|-b|-s|-v|-V) ;;
              -u|-g|-h|-p|-C|-R) wrapper_skip=1 ;;
              *) stage=-1 ;;
            esac
            ;;
          nohup)
            case "$word" in
              gh) stage=1 ;;
              command|exec|env|sudo|nohup|time) wrapper="$word" ;;
              --) ;;
              *) stage=-1 ;;
            esac
            ;;
          time)
            case "$word" in
              gh) stage=1 ;;
              command|exec|env|sudo|nohup|time) wrapper="$word" ;;
              -p|--) ;;
              *) stage=-1 ;;
            esac
            ;;
          *) stage=-1 ;;
        esac
        ;;
      *) ;;
    esac
  }

  while IFS= read -r line || [ -n "$line" ]; do
    line_count=$((line_count + 1))
    [ "$line_count" -le "$max_lines" ] || return 1

    # Heredoc bodies are data, not logical commands. A quoted delimiter is
    # already normalized when it is queued; <<- permits leading tabs.
    if [ "$heredoc_head" -lt "$heredoc_count" ]; then
      heredoc_delim="${heredoc_delims[$heredoc_head]}"
      heredoc_strip="${heredoc_strip_tabs[$heredoc_head]}"
      heredoc_compare="$line"
      if [ "$heredoc_strip" -eq 1 ]; then
        while [ "${heredoc_compare:0:1}" = $'\t' ]; do
          heredoc_compare="${heredoc_compare:1}"
        done
      fi
      if [ "$heredoc_compare" = "$heredoc_delim" ]; then
        heredoc_head=$((heredoc_head + 1))
      fi
      continue
    fi

    line_len=${#line}
    i=0
    while [ "$i" -lt "$line_len" ]; do
      ch="${line:i:1}"
      next=""
      next2=""
      [ $((i + 1)) -lt "$line_len" ] && next="${line:i+1:1}"
      [ $((i + 2)) -lt "$line_len" ] && next2="${line:i+2:1}"

      if [ "$comment" -eq 1 ]; then
        i=$line_len
        continue
      fi

      if [ "$escape" -eq 1 ]; then
        token="${token}${ch}"
        token_started=1
        escape=0
        i=$((i + 1))
        continue
      fi

      if [ "$quote" = "'" ]; then
        if [ "$ch" = "'" ]; then
          quote=""
        else
          token="${token}${ch}"
        fi
        i=$((i + 1))
        continue
      elif [ "$quote" = '"' ]; then
        if [ "$ch" = '$' ] && [ "$next" = '(' ] &&
           [ "$quoted_subshell_depth" -lt "$max_quoted_subshell_depth" ]; then
          quoted_subshell_depth=$((quoted_subshell_depth + 1))
          quoted_subshell_quotes[$quoted_subshell_depth]="$quote"
          quoted_subshell_parens[$quoted_subshell_depth]=1
          quote=""
          comment=0
          escape=0
          token=""
          token_started=0
          stage=0
          wrapper=""
          wrapper_skip=0
          redirection_target=0
          i=$((i + 2))
          continue
        fi
        case "$ch" in
          \\) escape=1 ;;
          '"') quote="" ;;
          *) token="${token}${ch}" ;;
        esac
        i=$((i + 1))
        continue
      fi
      case "$ch" in
        \\)
          escape=1
          token_started=1
          ;;
        "'")
          quote="'"
          token_started=1
          ;;
        '"')
          quote='"'
          token_started=1
          ;;
        '#')
          if [ "$token_started" -eq 0 ]; then
            comment=1
          else
            token="${token}${ch}"
          fi
          ;;
        ' '|$'\t'|$'\r')
          _pg_finish_word
          ;;
        ';'|'&'|'|'|'('|')'|'{'|'}')
          if [ "$ch" = '(' ] && [ "$quoted_subshell_depth" -gt 0 ]; then
            quoted_subshell_parens[$quoted_subshell_depth]=$((quoted_subshell_parens[$quoted_subshell_depth] + 1))
            _pg_finish_word
            stage=0
            wrapper=""
            wrapper_skip=0
            redirection_target=0
          elif [ "$ch" = ')' ] && [ "$quoted_subshell_depth" -gt 0 ]; then
            if [ "${quoted_subshell_parens[$quoted_subshell_depth]}" -gt 1 ]; then
              quoted_subshell_parens[$quoted_subshell_depth]=$((quoted_subshell_parens[$quoted_subshell_depth] - 1))
              _pg_finish_word
              stage=0
              wrapper=""
              wrapper_skip=0
              redirection_target=0
            else
              _pg_finish_word
              [ "$found" -eq 1 ] && return 0
              quote="${quoted_subshell_quotes[$quoted_subshell_depth]}"
              quoted_subshell_depth=$((quoted_subshell_depth - 1))
              stage=-1
              wrapper=""
              wrapper_skip=0
              redirection_target=0
              token=""
              token_started=1
            fi
          else
            _pg_finish_word
            stage=0
            wrapper=""
            wrapper_skip=0
            redirection_target=0
          fi
          ;;
        '<'|'>')
          # Redirections delimit the command's final token without ending
          # the command. Preserve a leading numeric fd (`2>file`) as a
          # redirection rather than a command word.
          if [ "$token_started" -eq 1 ] &&
             [ "$stage" -eq 0 ] &&
             [[ "$token" != *[!0-9]* ]]; then
            token=""
            token_started=0
          else
            _pg_finish_word
          fi
          redirection_target=1

          # Queue a here-document delimiter, but not a here-string (<<<).
          if [ "$ch" = '<' ] && [ "$next" = '<' ] && [ "$next2" != '<' ]; then
            j=$((i + 2))
            heredoc_strip=0
            if [ "$j" -lt "$line_len" ] && [ "${line:j:1}" = "-" ]; then
              heredoc_strip=1
              j=$((j + 1))
            fi
            while [ "$j" -lt "$line_len" ] &&
                  { [ "${line:j:1}" = " " ] || [ "${line:j:1}" = $'\t' ]; }; do
              j=$((j + 1))
            done
            delimiter_char="${line:j:1}"
            heredoc_delim=""
            delimiter_quote=""
            if [ "$delimiter_char" = "'" ] || [ "$delimiter_char" = '"' ]; then
              delimiter_quote="$delimiter_char"
              j=$((j + 1))
              delimiter_start=$j
              while [ "$j" -lt "$line_len" ] &&
                    [ "${line:j:1}" != "$delimiter_quote" ]; do
                heredoc_delim="${heredoc_delim}${line:j:1}"
                j=$((j + 1))
              done
              [ "$j" -lt "$line_len" ] && j=$((j + 1))
              [ "$j" -gt "$delimiter_start" ] || heredoc_delim=""
            elif [ "$delimiter_char" = "\\" ]; then
              j=$((j + 1))
              if [ "$j" -lt "$line_len" ]; then
                heredoc_delim="${line:j:1}"
                j=$((j + 1))
              fi
            else
              while [ "$j" -lt "$line_len" ]; do
                delimiter_char="${line:j:1}"
                case "$delimiter_char" in
                  ' '|$'\t'|$'\r'|';'|'&'|'|'|'('|')'|'<'|'>' ) break ;;
                  *) heredoc_delim="${heredoc_delim}${delimiter_char}" ;;
                esac
                j=$((j + 1))
              done
            fi
            if [ -n "$heredoc_delim" ]; then
              heredoc_delims[$heredoc_count]="$heredoc_delim"
              heredoc_strip_tabs[$heredoc_count]="$heredoc_strip"
              heredoc_count=$((heredoc_count + 1))
            fi
            [ "$j" -gt "$i" ] && i=$((j - 1))
          fi
          # A fd duplication (`2>&1`/`2>&-`) has no pathname word to
          # consume. Keep the logical command open while skipping it.
          if [ "$ch" != '<' ] && [ "$next" = "&" ]; then
            j=$((i + 2))
            if [ "$j" -lt "$line_len" ] &&
               { [ "${line:j:1}" = "-" ] ||
                 { [ "${line:j:1}" != "" ] &&
                   [[ "${line:j:1}" != *[!0-9]* ]]; }; }; then
              j=$((j + 1))
              while [ "$j" -lt "$line_len" ] &&
                    [[ "${line:j:1}" != *[!0-9]* ]]; do
                j=$((j + 1))
              done
              redirection_target=0
              i=$((j - 1))
            fi
          fi
          ;;
        *)
          token="${token}${ch}"
          token_started=1
          ;;
      esac
      i=$((i + 1))
    done

    # A physical newline is a command separator unless escaped or quoted.
    if [ "$escape" -eq 1 ]; then
      escape=0
    elif [ -n "$quote" ]; then
      token="${token}"$'\n'
      token_started=1
    else
      _pg_finish_word
      stage=0
      wrapper=""
      wrapper_skip=0
      redirection_target=0
      comment=0
    fi

    [ "$found" -eq 1 ] && return 0
  done <<<"$input"

  [ "$found" -eq 1 ]
}

if _pg_has_gh_pr_create "$COMMAND"; then
  TRIGGER=1
else
  TRIGGER=0
fi
[ "$TRIGGER" -eq 1 ] || exit 0

# run_with_timeout <seconds> <command> [args...]
#
# Keep this process-group shim in sync with codex/hooks/lib/code-reviewer.sh
# and codex/hooks/propose-rules.sh. A direct SIGALRM only reaches the
# immediate child; the fork + setsid child group also covers descendants of
# run-all.sh.
# ---------------------------------------------------------------------------
run_with_timeout() {
  local secs="$1"
  shift
  if command -v perl >/dev/null 2>&1; then
    perl -e '
      use POSIX ();
      my $secs = shift @ARGV;
      my $pid = fork();
      if (!defined $pid) { exec @ARGV; }
      if ($pid == 0) { POSIX::setsid(); exec @ARGV or POSIX::_exit(127); }
      $SIG{ALRM} = sub {
        kill("TERM", -$pid); select(undef, undef, undef, 0.3);
        kill("KILL", -$pid); waitpid($pid, 0); exit(142);
      };
      alarm $secs;
      waitpid($pid, 0);
      my $st = $?;
      exit($st & 127 ? 128 + ($st & 127) : $st >> 8);
    ' "$secs" "$@"
  else
    # Match the existing advisory-hook convention when perl is unavailable:
    # execute without a wall-clock cap rather than relying on GNU timeout.
    "$@"
  fi
}

emit_advisory() {
  local msg="$1"
  _se_emit_hook_context "PreToolUse" "$msg"
}

PROJECT_DIR="$(_se_project_dir)"
if [ ! -d "$PROJECT_DIR" ]; then
  emit_advisory "pr-gate-shiftleft: project directory is unavailable; process-gate was not run (advisory only; CI remains authoritative)."
  exit 0
fi

# Resolve an explicit runner override first; this is useful for isolated
# fixtures and preserves the same bash-invocation contract as pre-push.
RUNNER="${PR_GATE_SHIFTLEFT_RUNNER:-${PROCESS_GATE_RUNNER:-}}"
if [ -n "$RUNNER" ]; then
  case "$RUNNER" in
    /*) ;;
    *) RUNNER="$PROJECT_DIR/$RUNNER" ;;
  esac
fi

if [ -z "$RUNNER" ]; then
  # Installed project-local paths win. The tracked source copy covers linked
  # worktrees of this repository; attached-project worktrees fall back through
  # the main checkout derived from Git's shared COMMON dir. `--git-dir` cannot
  # substitute here because it identifies the linked worktree's own admin dir.
  COMMON_DIR="$(git -C "$PROJECT_DIR" rev-parse --git-common-dir 2>/dev/null || true)"
  COMMON_RUNNER=""
  COMMON_ALT_RUNNER=""
  if [ -n "$COMMON_DIR" ]; then
    case "$COMMON_DIR" in
      /*) ;;
      *) COMMON_DIR="$PROJECT_DIR/$COMMON_DIR" ;;
    esac
    MAIN_CHECKOUT="$(dirname "$COMMON_DIR")"
    COMMON_RUNNER="$MAIN_CHECKOUT/.agents/skills/process-gate/scripts/run-all.sh"
    COMMON_ALT_RUNNER="$MAIN_CHECKOUT/.claude/skills/process-gate/scripts/run-all.sh"
  fi

  CANDIDATES=(
    "$PROJECT_DIR/.agents/skills/process-gate/scripts/run-all.sh"
    "$PROJECT_DIR/.claude/skills/process-gate/scripts/run-all.sh"
    "$PROJECT_DIR/core-rules/skills/process-gate/scripts/run-all.sh"
  )
  [ -z "$COMMON_RUNNER" ] || CANDIDATES+=("$COMMON_RUNNER" "$COMMON_ALT_RUNNER")

  RUNNER_MISSES=""
  for candidate in "${CANDIDATES[@]}"; do
    if [ -f "$candidate" ]; then
      RUNNER="$candidate"
      break
    fi
    skill_dir="${candidate%/scripts/run-all.sh}"
    if [ -L "$skill_dir" ] && [ ! -e "$skill_dir" ]; then
      miss="process-gate skill symlink target is unavailable"
    elif [ -L "$candidate" ] && [ ! -e "$candidate" ]; then
      miss="broken runner symlink"
    elif [ -e "$candidate" ]; then
      miss="exists but is not a regular file"
    else
      miss="not found"
    fi
    RUNNER_MISSES+="  - ${candidate}: ${miss}"$'\n'
  done
  if [ -z "$COMMON_RUNNER" ]; then
    RUNNER_MISSES+="  - <main-checkout>/.agents/skills/process-gate/scripts/run-all.sh: git rev-parse --git-common-dir failed"$'\n'
    RUNNER_MISSES+="  - <main-checkout>/.claude/skills/process-gate/scripts/run-all.sh: git rev-parse --git-common-dir failed"$'\n'
  fi
fi

if [ -z "$RUNNER" ]; then
  emit_advisory "pr-gate-shiftleft: process-gate runner was not found; skipped local pre-flight (advisory only; CI and branch protection remain authoritative). Candidates tried:
${RUNNER_MISSES}"
  exit 0
fi

TIMEOUT="${PR_GATE_SHIFTLEFT_TIMEOUT:-${PROCESS_GATE_SHIFTLEFT_TIMEOUT:-90}}"
case "$TIMEOUT" in
  ''|*[!0-9]*) TIMEOUT=90 ;;
esac
RANGE="${PR_GATE_SHIFTLEFT_RANGE:-main..HEAD}"

GATE_OUTPUT=""
GATE_RC=0
if GATE_OUTPUT="$(cd "$PROJECT_DIR" && run_with_timeout "$TIMEOUT" bash "$RUNNER" --range="$RANGE" 2>&1)"; then
  GATE_RC=0
else
  GATE_RC=$?
fi

case "$GATE_RC" in
  0)   RESULT="MERGEABLE" ;;
  1)   RESULT="BLOCKED" ;;
  2)   RESULT="NEEDS CHANGES" ;;
  142) RESULT="TIMED OUT after ${TIMEOUT}s" ;;
  *)   RESULT="FAILED (exit ${GATE_RC})" ;;
esac

MSG="pr-gate-shiftleft: process-gate ${RESULT} (advisory only; gh pr create is never blocked here; CI and branch protection remain authoritative)."
if [ -n "$GATE_OUTPUT" ]; then
  MSG="${MSG}

${GATE_OUTPUT}"
fi
emit_advisory "$MSG"
exit 0
