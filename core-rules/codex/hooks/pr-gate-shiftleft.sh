#!/usr/bin/env bash
# pr-gate-shiftleft.sh — Codex PreToolUse(Bash) recorder for `gh pr create`.
# Source: Trellis / core-rules / codex hooks (Spec 005 C3 / T-P4d).
#
# Contract:
#   - Reads a Codex PreToolUse JSON envelope from stdin.
#   - Runs only when a shell command contains an actual `gh pr create`
#     command (not prose such as `echo gh pr create` or `gh pr view`).
#   - Records the literal --base on the resolved PR head branch as
#     branch.<head>.trellisPrBase, the base cache read by diff-base.sh.
#   - Never runs process-gate. The pre-push gate is the authoritative local
#     check. On a recorded base it prints one stderr line; it never emits a
#     block decision and always exits 0.

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
# record a PR base.
_pg_has_gh_pr_create() {
  local input="$1"
  local line ch next next2
  local i line_len
  local quote="" comment=0 escape=0
  local token="" token_started=0 token_literal=1
  PG_WORDS=(); PG_LITERALS=(); PG_SEPS=(); PG_WORD_COUNT=0
  PG_PR_START=0; PG_PR_END=-1; PG_CD_COUNT=0; PG_UNCERTAIN=0
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

  # stage 0: command start; 1/2: gh/pr seen; 3: PR flags; 4: safe wrapper.
  # A wrapper may be chained, but arbitrary commands/options never pass
  # through this state. This is what keeps `sudo echo gh pr create` inert.
  _pg_finish_word() {
    local word="$token" literal="$token_literal" index="$PG_WORD_COUNT"
    if [ "$redirection_target" -eq 1 ]; then
      if [ "$token_started" -eq 1 ]; then
        token=""
        token_started=0
        redirection_target=0
        token_literal=1
      fi
      return 0
    fi
    [ "$token_started" -eq 1 ] || return 0
    PG_WORDS[$index]="$word"; PG_LITERALS[$index]="$literal"
    PG_WORD_COUNT=$((PG_WORD_COUNT + 1))
    token=""
    token_started=0
    token_literal=1
    if [ "$word" = cd ] && { [ "$stage" -eq 0 ] || [ "$stage" -eq 4 ]; }; then
      PG_CD_COUNT=$((PG_CD_COUNT + 1))
    fi

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
          [ "$found" -eq 0 ] || PG_UNCERTAIN=1
          if [ "$found" -eq 0 ]; then PG_PR_START="$PG_WORD_COUNT"; fi
          found=1
          stage=3
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

  _pg_boundary() {
    _pg_finish_word
    if [ "$stage" -eq 3 ] && [ "$PG_PR_END" -lt 0 ]; then PG_PR_END="$PG_WORD_COUNT"; fi
    if [ "$1" != $'\n' ]; then
      PG_SEPS[$PG_WORD_COUNT]="${PG_SEPS[$PG_WORD_COUNT]:-}$1"
    fi
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
          PG_UNCERTAIN=1
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
          '$'|'`') token_literal=0; token="${token}${ch}" ;;
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
          _pg_boundary "$ch"
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
          case "$ch" in '$'|'`'|'*'|'?'|'['|'~') token_literal=0 ;; esac
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
      _pg_boundary $'\n'
      stage=0
      wrapper=""
      wrapper_skip=0
      redirection_target=0
      comment=0
    fi
  done <<<"$input"

  [ "$PG_PR_END" -ge 0 ] || PG_PR_END="$PG_WORD_COUNT"
  [ -z "$quote" ] || PG_UNCERTAIN=1
  [ "$found" -eq 1 ]
}

if _pg_has_gh_pr_create "$COMMAND"; then
  TRIGGER=1
else
  TRIGGER=0
fi
[ "$TRIGGER" -eq 1 ] || exit 0

emit_advisory() {
  local msg="$1"
  _se_emit_hook_context "PreToolUse" "$msg"
}

# Only literal flags from the triggering command can describe the PR.
_pg_resolve_pr_head() {
  local i="$PG_PR_START" word kind value literal dir="$PROJECT_DIR"
  local head="" head_set=0 repo="" origin path=""
  PR_BASE=""
  [ "$PG_UNCERTAIN" -eq 0 ] || return 1
  while [ "$i" -lt "$PG_PR_END" ]; do
    word="${PG_WORDS[$i]}"; kind=""; value=""; literal="${PG_LITERALS[$i]}"
    case "$word" in
      --base|-B) kind=base ;;
      --head|-H) kind="head"; head_set=1 ;;
      --repo|-R) kind=repo ;;
      --base=*) kind=base; value="${word#--base=}" ;;
      -B?*) kind=base; value="${word#-B}" ;;
      --head=*) kind="head"; head_set=1; value="${word#--head=}" ;;
      -H?*) kind="head"; head_set=1; value="${word#-H}" ;;
      --repo=*) kind=repo; value="${word#--repo=}" ;;
      -R?*) kind=repo; value="${word#-R}" ;;
      --title|-t|--body|-b|--body-file|-F|--reviewer|-r|--assignee|-a|--label|-l|--milestone|-m|--project|-p|--template|-T)
        i=$((i + 2)); continue ;;
      --) break ;;
    esac
    if [ -n "$kind" ]; then
      case "$word" in
        --base|-B|--head|-H|--repo|-R)
          i=$((i + 1))
          if [ "$i" -lt "$PG_PR_END" ]; then
            value="${PG_WORDS[$i]}"; literal="${PG_LITERALS[$i]}"
          fi
          ;;
      esac
      if [ "$literal" -eq 0 ] || [ -z "$value" ]; then
        [ "$kind" = base ] || return 1
        value=""
      fi
      case "$kind" in base) PR_BASE="$value" ;; head) head="$value" ;; repo) repo="$value" ;; esac
    fi
    i=$((i + 1))
  done
  if [ "$PG_CD_COUNT" -gt 0 ]; then
    [ "$PG_CD_COUNT" -eq 1 ] || return 1
    [ "${PG_WORDS[0]}" = cd ] || return 1
    [ -z "${PG_SEPS[0]:-}" ] || return 1
    [ "${PG_LITERALS[1]:-0}" -eq 1 ] || return 1
    [ "${PG_SEPS[2]:-}" = '&&' ] || return 1
    dir="${PG_WORDS[1]}"
    case "$dir" in /*) ;; *) dir="$PROJECT_DIR/$dir" ;; esac
  fi
  if [ "$head_set" -eq 0 ]; then
    for ((i=0; i<PG_PR_START; i++)); do
      if [ "${PG_WORDS[$i]}" = git ] && [ "${PG_WORDS[$((i + 1))]:-}" = -C ]; then return 1; fi
    done
  fi
  dir="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || return 1
  PG_HEAD_DIR="$dir"
  if [ "$head_set" -eq 1 ]; then
    PG_HEAD_DIR=""
    while IFS= read -r word; do
      case "$word" in
        'worktree '*) path="${word#worktree }" ;;
        "branch refs/heads/$head") PG_HEAD_DIR="$path"; break ;;
      esac
    done < <(git -C "$dir" worktree list --porcelain 2>/dev/null)
    [ -n "$PG_HEAD_DIR" ] || return 1
  fi
  PG_HEAD_BRANCH="$(git -C "$PG_HEAD_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null)" || return 1
  if [ "$head_set" -eq 1 ]; then [ "$PG_HEAD_BRANCH" = "$head" ] || return 1; fi
  if [ -n "$repo" ]; then
    origin="$(git -C "$PG_HEAD_DIR" config --get remote.origin.url)" || return 1
    origin="${origin#*://}"; origin="${origin#*@}"; origin="${origin/:/\/}"
    origin="${origin%/}"; origin="${origin%.git}"
    [ "$repo" = "$origin" ] || [ "$repo" = "${origin#*/}" ] || return 1
  fi
}

PROJECT_DIR="$(_se_project_dir)"
if ! _pg_resolve_pr_head; then
  emit_advisory 'pr-gate-shiftleft: cannot resolve the PR head; advisory skipped'
  exit 0
fi
if [ -n "$PR_BASE" ] &&
  git -C "$PG_HEAD_DIR" config "branch.$PG_HEAD_BRANCH.trellisPrBase" "$PR_BASE" 2>/dev/null; then
  printf '%s\n' "pr-gate-shiftleft: recorded PR base $PR_BASE; the full process gate runs at push" >&2
fi

exit 0
