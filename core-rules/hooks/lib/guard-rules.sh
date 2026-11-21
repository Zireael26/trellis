#!/usr/bin/env bash
# guard-rules.sh — GENERATED from core-rules/hooks/rules/*.json and
# scripts/lib/guard-rules-runtime.bash by scripts/gen-guard-rules.py.
# Do not edit. Change the JSON or the runtime, then run
#   python3 -I scripts/gen-guard-rules.py --write
# and commit the result; --check (guard-rules.bats) fails on drift.
#
# Sourced by block-destructive.sh, reread-guard.sh and track-read.sh in both
# hook trees. Sourcing defines functions and constants only.

# shellcheck disable=SC2034  # GR_* and _gr_* outputs are read by the sourcing hooks
# Guard-rules runtime: the bash matcher and input helpers that
# scripts/gen-guard-rules.py copies into core-rules/hooks/lib/guard-rules.sh
# ahead of the rules it compiles from core-rules/hooks/rules/*.json. Edit this
# file, then regenerate; never edit the generated include.
#
# Matching follows the "semantics" of rules/destructive.json: per line, as grep
# reads a command, in the C locale so no host locale changes a decision, and
# with no process spawned. Bash 3.2 compatible.

# _gr_lines_of <text>
#   Sets _gr_text to <text> and _gr_lines to its lines. Empty lines are dropped:
#   the generator refuses any pattern that matches an empty line.
_gr_lines_of() {
  _gr_text=$1
  case $1 in
    *$'\n'*)
      local IFS=$'\n' noglob=''
      case $- in *f*) noglob=1 ;; esac
      set -f
      # shellcheck disable=SC2206  # splitting on newlines is the point
      _gr_lines=($1)
      [ -n "$noglob" ] || set +f
      ;;
    *) _gr_lines=("$1") ;;
  esac
}

# _gr_m <line-re> <text-re>
#   Succeeds when some line in _gr_lines matches <line-re>. <text-re> is the
#   same pattern with ^ and $ widened to line boundaries: one test against the
#   whole text rules out every line before the per-line loop runs.
_gr_m() {
  local line
  if [ "${#_gr_lines[@]}" -le 1 ]; then
    [[ ${_gr_lines[0]-} =~ $1 ]]
    return
  fi
  [[ $_gr_text =~ $2 ]] || return 1
  for line in "${_gr_lines[@]}"; do
    [[ $line =~ $1 ]] && return 0
  done
  return 1
}

# _gr_exempt <allowed> <prefixes> <boundaries> <identifier-re> <replacement> <refuse-short-flags>
#   A rule's `exempt` step (rules/destructive.json "semantics"): rewrites
#   _gr_lines in place. Each line is cut into simple commands at every
#   <boundaries> character. <allowed> lists, comma-separated, the word
#   sequences an exempt simple command starts with, optionally after one
#   <prefixes> word. Unless every non-empty simple command is exempt, nothing
#   is rewritten; nor if one has a <refuse-short-flags> word, or an identifier
#   attached by = to a flag or right after a --flag. Otherwise identifiers
#   (group 1 of <identifier-re> is the boundary character, group 2 the
#   identifier) are rewritten to group 1 plus <replacement>. Commands without
#   an <allowed> first word skip the walk.
_gr_exempt() {
  local allowed=$1 prefixes=" $2 " bounds=$3 re=$4 repl=$5 refuse_short=$6
  local n line out seg c i entry found=0 refused=0
  local -a saved
  local IFS=,
  for entry in $allowed; do
    case $_gr_text in *"${entry%% *}"*) found=1 ;; esac
  done
  IFS=$' \t\n'
  [ "$found" = 1 ] || return 0
  saved=(${_gr_lines[@]+"${_gr_lines[@]}"})
  for ((n = 0; n < ${#_gr_lines[@]}; n++)); do
    line=${_gr_lines[n]}
    out='' seg=''
    for ((i = 0; i < ${#line}; i++)); do
      c=${line:i:1}
      case $bounds in
        *"$c"*) _gr_exempt_segment; out=$out$seg$c; seg='' ;;
        *) seg=$seg$c ;;
      esac
      [ "$refused" = 0 ] || break
    done
    _gr_exempt_segment
    _gr_lines[n]=$out$seg
    [ "$refused" = 0 ] || break
  done
  [ "$refused" = 0 ] || _gr_lines=(${saved[@]+"${saved[@]}"})
  _gr_text=''
  for line in ${_gr_lines[@]+"${_gr_lines[@]}"}; do
    _gr_text=${_gr_text:+$_gr_text$'\n'}$line
  done
}

# For _gr_exempt: sets refused=1 unless $seg is empty or an <allowed> simple
# command without a refused flag, whose identifiers it rewrites.
_gr_exempt_segment() {
  local words kept='' m pre w f k=0 entry joined prev='' ok=0 noglob=''
  local IFS=$' \t\v\f\r'
  case $- in *f*) noglob=1 ;; esac
  set -f
  # shellcheck disable=SC2206  # word splitting on blanks is the point
  words=($seg)
  [ -n "$noglob" ] || set +f
  [ "${#words[@]}" -gt 0 ] || return 0
  case $prefixes in *" ${words[0]} "*) k=1 ;; esac
  joined=" ${words[*]:k} "
  IFS=,
  for entry in $allowed; do
    case $joined in " $entry "*) ok=1 ;; esac
  done
  IFS=$' \t\v\f\r'
  [ "$ok" = 1 ] || { refused=1; return 0; }
  for w in "${words[@]:k+1}"; do
    for f in $refuse_short; do
      # A refused short flag refuses alone or with its value attached.
      if [[ $w == "$f"* ]]; then refused=1; return 0; fi
    done
    # An identifier given to a flag, as --flag=ID, -x=ID or --flag ID, could
    # name a file the flag reads.
    if [[ $w == -*=* && " ${w#*=}" =~ $re ]]; then refused=1; return 0; fi
    if [[ $prev == --?* && $prev != *=* && " $w" =~ $re ]]; then refused=1; return 0; fi
    prev=$w
  done
  m=" $seg"
  while [[ $m =~ $re ]]; do
    pre=${m%%"${BASH_REMATCH[0]}"*}
    kept=$kept$pre${BASH_REMATCH[1]}$repl
    m=${m#*"${BASH_REMATCH[0]}"}
  done
  seg=$kept$m
  seg=${seg# }
}

# _gr_icase <0|1> — ASCII case folding for the patterns that follow.
_gr_icase() {
  if [ "$1" = 1 ]; then shopt -s nocasematch; else shopt -u nocasematch; fi
}

# _gr_with_rules <function> <args>...
#   Runs a generated rule function in the C locale, with its own line state,
#   and restores the caller's nocasematch setting afterwards.
_gr_with_rules() {
  local LC_ALL=C _gr_text='' nocase=0 rc
  local -a _gr_lines
  shopt -q nocasematch && nocase=1
  "$@"
  rc=$?
  _gr_icase "$nocase"
  return "$rc"
}

# _gr_json_str <string>
#   Sets GR_JSON to <string> as a JSON string literal, escaped as jq escapes it,
#   so a decision document reads byte for byte as when jq printed it.
_gr_json_str() {
  local s=$1 out='' c i
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  case $s in
    *[$'\001\002\003\004\005\006\007\010\011\012\013\014\015\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037\177']*)
      for ((i = 0; i < ${#s}; i++)); do
        c=${s:i:1}
        case $c in
          $'\b') out="$out\\b" ;;
          $'\t') out="$out\\t" ;;
          $'\n') out="$out\\n" ;;
          $'\f') out="$out\\f" ;;
          $'\r') out="$out\\r" ;;
          [$'\001\002\003\004\005\006\007\010\011\012\013\014\015\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037\177']) printf -v c '\\u%04x' "'$c"; out="$out$c" ;;
          *) out="$out$c" ;;
        esac
      done
      s=$out
      ;;
  esac
  GR_JSON="\"$s\""
}

# jq definitions that reproduce what `jq -r FILTER` prints: strings raw, other
# values as jq's indented JSON. action-normalize.sh carries the same helpers as
# ta_*; guard-rules-runtime.bats pins both copies to jq -r itself.
# shellcheck disable=SC2016  # jq source, not shell
_GR_JQ_LIB='
def gr_pp($i):
  if type == "array" then
    if length == 0 then "[]"
    else "[\n" + (map($i + "  " + gr_pp($i + "  ")) | join(",\n")) + "\n" + $i + "]" end
  elif type == "object" then
    if length == 0 then "{}"
    else "{\n" + (to_entries | map($i + "  " + (.key | tojson) + ": " + (.value | gr_pp($i + "  "))) | join(",\n")) + "\n" + $i + "}" end
  else tojson end;
def gr_out: if type == "string" then . else gr_pp("") end;
def gr_field(f): try ("V" + ([f | gr_out + "\n"] | add // "")) catch "E";
'

# _gr_jq_fields <json> <filter>...
#   One jq run in place of one `jq -r '<filter>'` call per filter. Sets
#   GR_FV[i] to what call i would have printed, less the trailing newlines
#   command substitution strips, and GR_FE[i] to 1 when call i would have
#   exited non-zero. jq reads documents one at a time: a filter error on one
#   document prints nothing for it and processing goes on, the exit status is
#   that of the last document, and invalid JSON stops the run with an error.
#   A multi-document or truncated stream reads here as it did there.
_gr_jq_fields() {
  local json=$1 prog='' tok rc=0 i=0 n
  shift
  n=$#
  for tok in "$@"; do prog="$prog${prog:+, }gr_field($tok)"; done
  GR_FV=() GR_FE=()
  while [ "$i" -lt "$n" ]; do
    GR_FV[i]=
    GR_FE[i]=0
    i=$((i + 1))
  done
  i=0
  while IFS= read -r -d '' tok; do
    case $tok in
      E) GR_FE[i]=1 ;;
      V*) GR_FE[i]=0; GR_FV[i]=${GR_FV[i]}${tok#V} ;;
      R*) rc=${tok#R}; break ;;
    esac
    i=$(( (i + 1) % n ))
  done < <(printf '%s' "$json" |
    jq -j "$_GR_JQ_LIB [$prog] | map(split(\"\\u0000\") | join(\"\") + \"\\u0000\") | add"
    printf '\0R%s\0' "$?")
  i=0
  while [ "$i" -lt "$n" ]; do
    [ "$rc" = 0 ] || GR_FE[i]=1
    while [[ ${GR_FV[i]} == *$'\n' ]]; do GR_FV[i]=${GR_FV[i]%$'\n'}; done
    i=$((i + 1))
  done
}

# _gr_now — GR_NOW = epoch seconds, without a date process where bash has them.
# Only bash 5 has the EPOCHSECONDS clock, which ignores assignment; before that
# it is an ordinary variable the environment can set, so it is never read.
_gr_now() {
  GR_NOW=''
  [ "${BASH_VERSINFO[0]}" -lt 5 ] || GR_NOW=${EPOCHSECONDS:-}
  case $GR_NOW in
    ''|*[!0-9]*) GR_NOW=$(date +%s 2>/dev/null) ;;
  esac
}

# Reread override records (decision 3, option c). `trellis reread override
# --session <id> --reason <why>` writes $TRELLIS_HOME/state/reread-overrides/<key>
# as one line "<expires>\t<created>\t<reason>"; <key> is _se_state_key of the
# session. The record is honoured only while unexpired and never for longer
# than GR_REREAD_OVERRIDE_TTL from now, so a hand-written far-future expiry
# buys nothing. The native evaluator (read_state.rs) applies the same reading.
GR_REREAD_OVERRIDE_TTL=600

# _gr_trellis_home — GR_TRELLIS_HOME = $TRELLIS_HOME, else $HOME/.trellis, else empty.
_gr_trellis_home() {
  GR_TRELLIS_HOME=${TRELLIS_HOME:-}
  [ -n "$GR_TRELLIS_HOME" ] || { [ -z "${HOME:-}" ] || GR_TRELLIS_HOME=${HOME%/}/.trellis; }
}

# _gr_reread_override_active <state-key> — succeeds when an unexpired override
# record exists for that key. The record must be exactly the CLI's one row:
# "<expires>\t<created>\t<reason>\n", decimal fields without leading zeros,
# expires = created + GR_REREAD_OVERRIDE_TTL, a nonempty reason of at most 2000
# bytes without control characters, and nothing after the row. Any doubt
# (missing, symlinked, malformed, extra data, expired, over-long) is "no
# override": the guard then runs as usual. read_state.rs applies the same rules.
_gr_reread_override_active() {
  local key=$1 file line extra="" expires created reason rest field byte_count byte_discard
  case $key in ''|*[!0123456789abcdef]*) return 1 ;; esac
  [ "${#key}" -eq 16 ] || return 1
  _gr_trellis_home
  [ -n "$GR_TRELLIS_HOME" ] || return 1
  file=$GR_TRELLIS_HOME/state/reread-overrides/$key
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  { IFS= read -r line && ! IFS= read -r extra; } < "$file" 2>/dev/null || return 1
  # printf's %n counts output bytes, even in a multibyte caller locale.
  printf -v byte_discard '%s%n' "$line" byte_count
  [ -z "$extra" ] && [ "$byte_count" -le 4095 ] || return 1
  case $line in *$'\t'*$'\t'*) ;; *) return 1 ;; esac
  expires=${line%%$'\t'*} rest=${line#*$'\t'}
  created=${rest%%$'\t'*} reason=${rest#*$'\t'}
  for field in "$expires" "$created"; do
    case $field in ''|0*|*[!0123456789]*) return 1 ;; esac
    [ "${#field}" -le 12 ] || return 1
  done
  case $reason in ''|*[$'\001\002\003\004\005\006\007\010\011\012\013\014\015\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037\177']*) return 1 ;; esac
  printf -v byte_discard '%s%n' "$reason" byte_count
  [ "$byte_count" -le 2000 ] || return 1
  [ $((created + GR_REREAD_OVERRIDE_TTL)) -eq "$expires" ] || return 1
  _gr_now
  case $GR_NOW in ''|*[!0123456789]*) return 1 ;; esac
  [ "$expires" -gt "$GR_NOW" ] && [ $((expires - GR_NOW)) -le "$GR_REREAD_OVERRIDE_TTL" ]
}

# _gr_reread_override_path <normalized-path> — succeeds when the path is an
# override record or its directory: only the CLI writes overrides.
_gr_reread_override_path() {
  _gr_guarded_state_path "$1" reread-overrides
}

# _gr_gate_verdict_path <normalized-path> — succeeds when the path is in the
# process-gate verdict store ($TRELLIS_HOME/state/gate-verdicts): only the gate
# writes verdicts, their execution logs and the reuse kill switch.
_gr_gate_verdict_path() {
  _gr_guarded_state_path "$1" gate-verdicts
}

# _gr_guarded_state_path <normalized-path> <directory> — succeeds when the path
# names <directory> under a state directory, or a file in it, in any letter
# case (macOS volumes usually fold case); also through the real path of its
# deepest existing ancestor, so a symlinked parent reaches the same answer; and
# when it is another name — a hard link, or a symlink — for a file in
# $GR_TRELLIS_HOME/state/<directory>, whatever its spelling. Mirrors
# is_guarded_state_path and guarded_inode in read_state.rs and
# isGuardedStatePath and guardedInode in the Pi extension.
_gr_guarded_state_path() {
  local path=$1 dir=$2 real rest='' probe store file
  _gr_guarded_state_named "$path" "$dir" && return 0
  real=$path
  while [ -n "$real" ] && [ ! -d "$real" ]; do
    rest=/${real##*/}$rest
    real=${real%/*}
  done
  [ -n "$real" ] || real=/
  # Resolve only when some component is a symlink: an ordinary path forks nothing.
  probe=$real
  while [ -n "$probe" ] && [ "$probe" != / ] && [ ! -L "$probe" ]; do probe=${probe%/*}; done
  if [ -n "$probe" ] && [ "$probe" != / ]; then
    real=$(cd -P -- "$real" 2>/dev/null && pwd -P) &&
      _gr_guarded_state_named "${real%/}$rest" "$dir" && return 0
  fi
  [ -f "$path" ] || return 1
  _gr_trellis_home
  store=$GR_TRELLIS_HOME/state/$dir
  [ -n "$GR_TRELLIS_HOME" ] && [ -d "$store" ] || return 1
  # Only a symlink or a file with more than one link can be another name, so an
  # ordinary edit never walks the store.
  if [ ! -L "$path" ]; then
    [ -n "$(find "$path" -prune -links +1 -print 2>/dev/null)" ] || return 1
  fi
  while IFS= read -r file; do
    [ "$path" -ef "$file" ] && return 0
  done < <(find "$store" -type f 2>/dev/null)
  return 1
}

_gr_guarded_state_named() {
  local folded=0 rc=1
  shopt -q nocasematch && folded=1 || shopt -s nocasematch
  case $1 in
    */state/"$2"|*/state/"$2"/*) rc=0 ;;
  esac
  [ "$folded" -eq 1 ] || shopt -u nocasematch
  return "$rc"
}

# --- rules/destructive.json --------------------------------------------------

# _gr_destructive <claude|codex> <command>
#   Applies rules/destructive.json. Prints each firing warn rule's message to
#   stderr. Succeeds when a deny rule fires, with GR_DENY_ID, GR_DENY_REASON and
#   GR_DENY_JSON (the reason as a JSON string literal) set.
_gr_destructive() {
  GR_DENY_ID='' GR_DENY_REASON='' GR_DENY_JSON=''
  _gr_with_rules _gr_destructive_rules "$@"
}

_gr_destructive_rules() {
  _gr_lines_of "$2"
  # rm-outside-cwd
  if _gr_m $'rm[ \t\n\v\f\r]+([^;&|<>]*[ \t\n\v\f\r])?[\'"]?\\\\*((/|~|\\$HOME|\\$\\{HOME[}])[^ \t\n\v\f\r]*|(\\./)*\\.\\.(/[^ \t\n\v\f\r]*)?)([ \t\n\v\f\r]|$)' $'rm[ \t\n\v\f\r]+([^;&|<>]*[ \t\n\v\f\r])?[\'"]?\\\\*((/|~|\\$HOME|\\$\\{HOME[}])[^ \t\n\v\f\r]*|(\\./)*\\.\\.(/[^ \t\n\v\f\r]*)?)([ \t\n\v\f\r]|(\n|$))'; then
    GR_DENY_ID=rm-outside-cwd
    GR_DENY_REASON=$'Blocked destructive rm targeting absolute path, ~, $HOME, or .. — run manually if intentional.'
    GR_DENY_JSON=$'"Blocked destructive rm targeting absolute path, ~, $HOME, or .. — run manually if intentional."'
    return 0
  fi
  # git-force-push
  if _gr_m $'git[ \t\n\v\f\r]+(-C[ \t\n\v\f\r]+[^ \t\n\v\f\r]+[ \t\n\v\f\r]+)*push([ \t\n\v\f\r]+[^ \t\n\v\f\r;&|]+)*[ \t\n\v\f\r]+(--force(-with-lease)?(=[^ \t\n\v\f\r]+)?|-[a-zA-Z]*f[a-zA-Z]*|\\+[^ \t\n\v\f\r]+)([ \t\n\v\f\r]|$)' $'git[ \t\n\v\f\r]+(-C[ \t\n\v\f\r]+[^ \t\n\v\f\r]+[ \t\n\v\f\r]+)*push([ \t\n\v\f\r]+[^ \t\n\v\f\r;&|]+)*[ \t\n\v\f\r]+(--force(-with-lease)?(=[^ \t\n\v\f\r]+)?|-[a-zA-Z]*f[a-zA-Z]*|\\+[^ \t\n\v\f\r]+)([ \t\n\v\f\r]|(\n|$))'; then
    GR_DENY_ID=git-force-push
    GR_DENY_REASON=$'Blocked force push — run manually if intentional.'
    GR_DENY_JSON=$'"Blocked force push — run manually if intentional."'
    return 0
  fi
  # git-reset-hard
  if _gr_m $'git[ \t\n\v\f\r]+reset[ \t\n\v\f\r]+--hard([ \t\n\v\f\r]+(HEAD(~[0-9]+)?|origin/[^ \t\n\v\f\r;&|]+)([ \t\n\v\f\r;&|]|$)|[ \t\n\v\f\r]*([;&|]|$))' $'git[ \t\n\v\f\r]+reset[ \t\n\v\f\r]+--hard([ \t\n\v\f\r]+(HEAD(~[0-9]+)?|origin/[^ \t\n\v\f\r;&|]+)([ \t\n\v\f\r;&|]|(\n|$))|[ \t\n\v\f\r]*([;&|]|(\n|$)))'; then
    GR_DENY_ID=git-reset-hard
    GR_DENY_REASON=$'Blocked git reset --hard without a target or on HEAD/HEAD~N/origin/* — run manually if intentional.'
    GR_DENY_JSON=$'"Blocked git reset --hard without a target or on HEAD/HEAD~N/origin/* — run manually if intentional."'
    return 0
  fi
  # codex-sandboxless-max-effort
  if _gr_m $'codex[ \t\n\v\f\r]([^|;&]*)?(--dangerously-bypass-approvals-and-sandbox|(-s|--sandbox)[ \t\n\v\f\r]*=?[ \t\n\v\f\r]*danger-full-access|sandbox_mode[ \t\n\v\f\r]*=[ \t\n\v\f\r]*danger-full-access)' $'codex[ \t\n\v\f\r]([^|;&]*)?(--dangerously-bypass-approvals-and-sandbox|(-s|--sandbox)[ \t\n\v\f\r]*=?[ \t\n\v\f\r]*danger-full-access|sandbox_mode[ \t\n\v\f\r]*=[ \t\n\v\f\r]*danger-full-access)' && _gr_m $'model_reasoning_effort["\'= \t\n\v\f\r]*(max|ultra)' $'model_reasoning_effort["\'= \t\n\v\f\r]*(max|ultra)'; then
    GR_DENY_ID=codex-sandboxless-max-effort
    GR_DENY_REASON=$'Blocked max/ultra effort on the sandboxless codex hatch — forbidden compound (docs/codex-routing.md §3); run at xhigh or restore the sandbox.'
    GR_DENY_JSON=$'"Blocked max/ultra effort on the sandboxless codex hatch — forbidden compound (docs/codex-routing.md §3); run at xhigh or restore the sandbox."'
    return 0
  fi
  # sql-drop
  _gr_icase 1
  if _gr_m $'DROP[ \t\n\v\f\r]+(TABLE|DATABASE)' $'DROP[ \t\n\v\f\r]+(TABLE|DATABASE)'; then
    GR_DENY_ID=sql-drop
    GR_DENY_REASON=$'Blocked destructive SQL DROP (TABLE/DATABASE) — run manually if intentional.'
    GR_DENY_JSON=$'"Blocked destructive SQL DROP (TABLE/DATABASE) — run manually if intentional."'
    return 0
  fi
  # sql-truncate
  if _gr_m $'((psql|mysql|sqlite3|duckdb|clickhouse)[ \t\n\v\f\r][^;&|]*(-c|--command|-e|--execute|--query|<<)|[^|][|][ \t\n\v\f\r]*([^ \t\n\v\f\r|;&]*/)?(psql|mysql|sqlite3|duckdb|clickhouse)([ \t\n\v\f\r]|$))' $'((psql|mysql|sqlite3|duckdb|clickhouse)[ \t\n\v\f\r][^;&|]*(-c|--command|-e|--execute|--query|<<)|[^|][|][ \t\n\v\f\r]*([^ \t\n\v\f\r|;&]*/)?(psql|mysql|sqlite3|duckdb|clickhouse)([ \t\n\v\f\r]|(\n|$)))' && _gr_m $'TRUNCATE[ \t\n\v\f\r]+(TABLE[ \t\n\v\f\r]+)?\\\\?["`]?[a-zA-Z_]' $'TRUNCATE[ \t\n\v\f\r]+(TABLE[ \t\n\v\f\r]+)?\\\\?["`]?[a-zA-Z_]'; then
    GR_DENY_ID=sql-truncate
    GR_DENY_REASON=$'Blocked destructive SQL TRUNCATE in a client invocation — run manually if intentional.'
    GR_DENY_JSON=$'"Blocked destructive SQL TRUNCATE in a client invocation — run manually if intentional."'
    return 0
  fi
  # sql-delete-without-where
  if _gr_m $'DELETE[ \t\n\v\f\r]+FROM[ \t\n\v\f\r]+["`]?[a-zA-Z_][a-zA-Z0-9_."`]*' $'DELETE[ \t\n\v\f\r]+FROM[ \t\n\v\f\r]+["`]?[a-zA-Z_][a-zA-Z0-9_."`]*' && ! _gr_m $'DELETE[ \t\n\v\f\r]+FROM[ \t\n\v\f\r]+["`]?[a-zA-Z_][a-zA-Z0-9_."`]*[^;]*[ \t\n\v\f\r]WHERE[ \t\n\v\f\r]' $'DELETE[ \t\n\v\f\r]+FROM[ \t\n\v\f\r]+["`]?[a-zA-Z_][a-zA-Z0-9_."`]*[^;]*[ \t\n\v\f\r]WHERE[ \t\n\v\f\r]'; then
    GR_DENY_ID=sql-delete-without-where
    GR_DENY_REASON=$'Blocked DELETE FROM without WHERE — unbounded delete, run manually if intentional.'
    GR_DENY_JSON=$'"Blocked DELETE FROM without WHERE — unbounded delete, run manually if intentional."'
    return 0
  fi
  # env-read
  _gr_icase 0
  if _gr_m $'(^|[ \t\n\v\f\r|;&(])(cat|less|head|tail|more|source|\\.|grep|sed|awk|bat)[ \t\n\v\f\r]+[^|;&]*\\.env([^A-Za-z0-9/]|$)' $'((^|\n)|[ \t\n\v\f\r|;&(])(cat|less|head|tail|more|source|\\.|grep|sed|awk|bat)[ \t\n\v\f\r]+[^|;&]*\\.env([^A-Za-z0-9/]|(\n|$))'; then
    if [ "$1" = claude ]; then
      printf '%s\n' $'block-destructive: .env read allowed (warn-only). Contents are now in this session\'s context and Anthropic-side transcript. Don\'t commit session logs or memory files that capture this run.' >&2
    else
      printf '%s\n' $'block-destructive: .env read allowed (warn-only). Contents are now in this session\'s context and provider-side transcript. Don\'t commit session logs or memory files that capture this run.' >&2
    fi
  fi
  # exfil-pipe
  if _gr_m $'(cat|less|head|tail|more|source|grep|sed|awk|bat)[ \t\n\v\f\r]+([^|]*\\.env([^A-Za-z0-9/]|$)|(([^|]*[ /"\'`<@=])?secrets/([^ \t\n\v\f\r|;&]|$)))[^\n]*[|][ \t\n\v\f\r]*(curl|wget|nc|netcat|ncat|xargs|ssh|scp|rsync|base64|openssl|sh|bash)([ \t\n\v\f\r]|$)' $'(cat|less|head|tail|more|source|grep|sed|awk|bat)[ \t\n\v\f\r]+([^|]*\\.env([^A-Za-z0-9/]|(\n|$))|(([^|]*[ /"\'`<@=])?secrets/([^ \t\n\v\f\r|;&]|(\n|$))))[^\n]*[|][ \t\n\v\f\r]*(curl|wget|nc|netcat|ncat|xargs|ssh|scp|rsync|base64|openssl|sh|bash)([ \t\n\v\f\r]|(\n|$))'; then
    GR_DENY_ID=exfil-pipe
    GR_DENY_REASON=$'Blocked piping sensitive file (.env or /secrets/) into network tool — prompt-injection exfil vector.'
    GR_DENY_JSON=$'"Blocked piping sensitive file (.env or /secrets/) into network tool — prompt-injection exfil vector."'
    return 0
  fi
  # exfil-upload
  if _gr_m $'(curl|wget)[ \t\n\v\f\r][^;&|]*(--data|--data-raw|--data-binary|--data-urlencode|--data-ascii|--form|-[A-Za-z]*F([ \t\n\v\f\r=/]|@|$)|-[A-Za-z]*d([ \t\n\v\f\r=/]|@|$)|--post-file|--upload-file|-[A-Za-z]*T([ \t\n\v\f\r=/]|@|$))[ \t\n\v\f\r=]*@?([^ \t\n\v\f\r]*\\.env([^A-Za-z0-9/]|$)|(([^ \t\n\v\f\r]*[ /"\'`<@=])?secrets/([^ \t\n\v\f\r|;&]|$)))' $'(curl|wget)[ \t\n\v\f\r][^;&|]*(--data|--data-raw|--data-binary|--data-urlencode|--data-ascii|--form|-[A-Za-z]*F([ \t\n\v\f\r=/]|@|(\n|$))|-[A-Za-z]*d([ \t\n\v\f\r=/]|@|(\n|$))|--post-file|--upload-file|-[A-Za-z]*T([ \t\n\v\f\r=/]|@|(\n|$)))[ \t\n\v\f\r=]*@?([^ \t\n\v\f\r]*\\.env([^A-Za-z0-9/]|(\n|$))|(([^ \t\n\v\f\r]*[ /"\'`<@=])?secrets/([^ \t\n\v\f\r|;&]|(\n|$))))'; then
    GR_DENY_ID=exfil-upload
    GR_DENY_REASON=$'Blocked curl/wget uploading sensitive file (.env or /secrets/) as body — prompt-injection exfil vector.'
    GR_DENY_JSON=$'"Blocked curl/wget uploading sensitive file (.env or /secrets/) as body — prompt-injection exfil vector."'
    return 0
  fi
  # exfil-command-substitution
  if _gr_m $'(curl|wget)[ \t\n\v\f\r][^;&|]*([$]\\(|`)[ \t\n\v\f\r]*(cat|less|head|tail|more|grep|sed|awk|bat)[ \t\n\v\f\r]+[^)`]*((([^)`]*[ /"\'`<@=])?secrets/([^ \t\n\v\f\r|;&]|$))|\\.env)' $'(curl|wget)[ \t\n\v\f\r][^;&|]*([$]\\(|`)[ \t\n\v\f\r]*(cat|less|head|tail|more|grep|sed|awk|bat)[ \t\n\v\f\r]+[^)`]*((([^)`]*[ /"\'`<@=])?secrets/([^ \t\n\v\f\r|;&]|(\n|$)))|\\.env)'; then
    GR_DENY_ID=exfil-command-substitution
    GR_DENY_REASON=$'Blocked curl/wget with command-substituted sensitive file in body — prompt-injection exfil vector.'
    GR_DENY_JSON=$'"Blocked curl/wget with command-substituted sensitive file in body — prompt-injection exfil vector."'
    return 0
  fi
  # secrets-read
  if [ "$1" = claude ] && _gr_m $'(^|[ \t\n\v\f\r|;&(`])([^ \t\n\v\f\r|;&(`]*/)?(cat|less|head|tail|more|source|\\.|grep|sed|awk|bat)[ \t\n\v\f\r]+(([^|;&]*[ /"\'`<@=])?secrets/([^ \t\n\v\f\r|;&]|$))' $'((^|\n)|[ \t\n\v\f\r|;&(`])([^ \t\n\v\f\r|;&(`]*/)?(cat|less|head|tail|more|source|\\.|grep|sed|awk|bat)[ \t\n\v\f\r]+(([^|;&]*[ /"\'`<@=])?secrets/([^ \t\n\v\f\r|;&]|(\n|$)))' && ! _gr_m $'\'' $'\'' && ! _gr_m '"' '"' && ! _gr_m $'\\\\' $'\\\\' && ! _gr_m '#' '#' && ! _gr_m '<' '<' && ! _gr_m '>' '>'; then
    _gr_exempt 'gcloud secrets list,gcloud secrets describe,gcloud secrets versions list,gcloud secrets versions describe,gcloud secrets versions access,kubectl get,kubectl describe' 'sudo' \
      ';&|()`' '([^A-Za-z0-9_./~-])((projects|namespaces)/[A-Za-z0-9_-][A-Za-z0-9_.-]*/secrets/)' '<exempt-identifier>' \
      '-f'
  fi
  if _gr_m $'(^|[ \t\n\v\f\r|;&(`])([^ \t\n\v\f\r|;&(`]*/)?(cat|less|head|tail|more|source|\\.|grep|sed|awk|bat)[ \t\n\v\f\r]+(([^|;&]*[ /"\'`<@=])?secrets/([^ \t\n\v\f\r|;&]|$))' $'((^|\n)|[ \t\n\v\f\r|;&(`])([^ \t\n\v\f\r|;&(`]*/)?(cat|less|head|tail|more|source|\\.|grep|sed|awk|bat)[ \t\n\v\f\r]+(([^|;&]*[ /"\'`<@=])?secrets/([^ \t\n\v\f\r|;&]|(\n|$)))'; then
    GR_DENY_ID=secrets-read
    GR_DENY_REASON=$'Blocked read under **/secrets/** — credentials must not be exposed to the agent.'
    GR_DENY_JSON=$'"Blocked read under **/secrets/** — credentials must not be exposed to the agent."'
    return 0
  fi
  _gr_lines_of "$2"
  # reread-override-direct-write
  _gr_icase 1
  if _gr_m 'state/reread-overrides' 'state/reread-overrides' && _gr_m $'(^|[^0-9])>|[0-9]>>?[|]?[ \t]*([^&/ \t>|]|&[^0-9-]|/([^d]|d([^e]|e([^v]|v([^/]|/([^n]|n([^u]|u([^l]|l([^l]|l[^ \t\n;&|)])))))))))|(^|[ \t\n\v\f\r|;&(`])(tee|cp|mv|ln|install|touch|dd|rsync|mkdir|chmod|truncate|perl|python[0-9]*|ruby|node|osascript)([ \t\n\v\f\r]|$)|sed[^|;&]*[ \t\n\v\f\r]-i' $'((^|\n)|[^0-9])>|[0-9]>>?[|]?[ \t]*([^&/ \t>|]|&[^0-9-]|/([^d]|d([^e]|e([^v]|v([^/]|/([^n]|n([^u]|u([^l]|l([^l]|l[^ \t\n;&|)])))))))))|((^|\n)|[ \t\n\v\f\r|;&(`])(tee|cp|mv|ln|install|touch|dd|rsync|mkdir|chmod|truncate|perl|python[0-9]*|ruby|node|osascript)([ \t\n\v\f\r]|(\n|$))|sed[^|;&]*[ \t\n\v\f\r]-i'; then
    GR_DENY_ID=reread-override-direct-write
    GR_DENY_REASON=$'Blocked direct write to a reread override record — only `trellis reread override --session <id> --reason <why>` writes these, with a logged breadcrumb.'
    GR_DENY_JSON=$'"Blocked direct write to a reread override record — only `trellis reread override --session <id> --reason <why>` writes these, with a logged breadcrumb."'
    return 0
  fi
  # gate-verdict-direct-write
  if case $1 in claude|codex) true ;; *) false ;; esac && _gr_m '(^|[^A-Za-z0-9_.-])gate-verdicts([^A-Za-z0-9_.-]|$)' $'((^|\n)|[^A-Za-z0-9_.-])gate-verdicts([^A-Za-z0-9_.-]|(\n|$))' && ! _gr_m $'(^|[^0-9])>|[0-9]>>?[|]?[ \t]*([^&/ \t>|]|&[^0-9-]|/([^d]|d([^e]|e([^v]|v([^/]|/([^n]|n([^u]|u([^l]|l([^l]|l[^ \t\n;&|)])))))))))' $'((^|\n)|[^0-9])>|[0-9]>>?[|]?[ \t]*([^&/ \t>|]|&[^0-9-]|/([^d]|d([^e]|e([^v]|v([^/]|/([^n]|n([^u]|u([^l]|l([^l]|l[^ \t\n;&|)])))))))))'; then
    _gr_exempt 'cat,head,tail,ls,stat,wc,jq,sha256sum,shasum,test,grep,cd,echo,printf,0,1,2,3,4,5,6,7,8,9' '' \
      ';&|()`' '([^A-Za-z0-9_.-])(gate-verdicts)' '<exempt-identifier>' \
      ''
  fi
  if _gr_m '(^|[^A-Za-z0-9_.-])gate-verdicts([^A-Za-z0-9_.-]|$)' $'((^|\n)|[^A-Za-z0-9_.-])gate-verdicts([^A-Za-z0-9_.-]|(\n|$))'; then
    GR_DENY_ID=gate-verdict-direct-write
    GR_DENY_REASON=$'Blocked a command that names the process-gate verdict store — only read-only tools (cat, head, tail, ls, stat, wc, jq, sha256sum, shasum, test, grep, cd, echo, printf) may name it; only the gate writes or removes verdicts, their execution logs and the reuse kill switch, and an operator changes them outside the agent.'
    GR_DENY_JSON=$'"Blocked a command that names the process-gate verdict store — only read-only tools (cat, head, tail, ls, stat, wc, jq, sha256sum, shasum, test, grep, cd, echo, printf) may name it; only the gate writes or removes verdicts, their execution logs and the reuse kill switch, and an operator changes them outside the agent."'
    return 0
  fi
  _gr_lines_of "$2"
  # gate-verdict-ancestor-write
  if case $1 in claude|codex) true ;; *) false ;; esac && _gr_m $'(((^|[ \t"\'=/])\\.trellis|\\$\\{?TRELLIS_HOME[}]?)(/+\\.)*/*(["\' \t\n\v\f\r;&|)<>]|$)|((^|[ \t"\'=/])\\.trellis|\\$\\{?TRELLIS_HOME[}]?)(/+\\.)*/+state(/|["\' \t\n\v\f\r;&|)<>]|$)|((^|[ \t"\'=/])\\.trellis|\\$\\{?TRELLIS_HOME[}]?)/([^ \t\n\v\f\r;&|"\'<>]*/)?\\.\\.([/"\' \t\n\v\f\r;&|)<>]|$)|(^|[ \t;&|(])cd[ \t]+["\']?[^ \t;&|"\']*((^|[ \t"\'=/])\\.trellis|\\$\\{?TRELLIS_HOME[}]?)[^ \t;&|"\']*["\']?[ \t]*(&&|;)[^\n]*[ \t"\'=](\\./)*(\\.\\./)*(state|\\.\\.)(/|["\' \t\n\v\f\r;&|)<>]|$))' $'((((^|\n)|[ \t"\'=/])\\.trellis|\\$\\{?TRELLIS_HOME[}]?)(/+\\.)*/*(["\' \t\n\v\f\r;&|)<>]|(\n|$))|(((^|\n)|[ \t"\'=/])\\.trellis|\\$\\{?TRELLIS_HOME[}]?)(/+\\.)*/+state(/|["\' \t\n\v\f\r;&|)<>]|(\n|$))|(((^|\n)|[ \t"\'=/])\\.trellis|\\$\\{?TRELLIS_HOME[}]?)/([^ \t\n\v\f\r;&|"\'<>]*/)?\\.\\.([/"\' \t\n\v\f\r;&|)<>]|(\n|$))|((^|\n)|[ \t;&|(])cd[ \t]+["\']?[^ \t;&|"\']*(((^|\n)|[ \t"\'=/])\\.trellis|\\$\\{?TRELLIS_HOME[}]?)[^ \t;&|"\']*["\']?[ \t]*(&&|;)[^\n]*[ \t"\'=](\\./)*(\\.\\./)*(state|\\.\\.)(/|["\' \t\n\v\f\r;&|)<>]|(\n|$)))' && ! _gr_m $'(^|[^0-9])>|[0-9]>>?[|]?[ \t]*([^&/ \t>|]|&[^0-9-]|/([^d]|d([^e]|e([^v]|v([^/]|/([^n]|n([^u]|u([^l]|l([^l]|l[^ \t\n;&|)])))))))))' $'((^|\n)|[^0-9])>|[0-9]>>?[|]?[ \t]*([^&/ \t>|]|&[^0-9-]|/([^d]|d([^e]|e([^v]|v([^/]|/([^n]|n([^u]|u([^l]|l([^l]|l[^ \t\n;&|)])))))))))'; then
    _gr_exempt 'cat,head,tail,ls,stat,wc,jq,sha256sum,shasum,test,grep,cd,echo,printf,0,1,2,3,4,5,6,7,8,9' '' \
      ';&|()`' '([^A-Za-z0-9_.-])(\.trellis|\$\{?TRELLIS_HOME[}]?)' '<exempt-identifier>' \
      ''
  fi
  if _gr_m $'(((^|[ \t"\'=/])\\.trellis|\\$\\{?TRELLIS_HOME[}]?)(/+\\.)*/*(["\' \t\n\v\f\r;&|)<>]|$)|((^|[ \t"\'=/])\\.trellis|\\$\\{?TRELLIS_HOME[}]?)(/+\\.)*/+state(/|["\' \t\n\v\f\r;&|)<>]|$)|((^|[ \t"\'=/])\\.trellis|\\$\\{?TRELLIS_HOME[}]?)/([^ \t\n\v\f\r;&|"\'<>]*/)?\\.\\.([/"\' \t\n\v\f\r;&|)<>]|$)|(^|[ \t;&|(])cd[ \t]+["\']?[^ \t;&|"\']*((^|[ \t"\'=/])\\.trellis|\\$\\{?TRELLIS_HOME[}]?)[^ \t;&|"\']*["\']?[ \t]*(&&|;)[^\n]*[ \t"\'=](\\./)*(\\.\\./)*(state|\\.\\.)(/|["\' \t\n\v\f\r;&|)<>]|$))' $'((((^|\n)|[ \t"\'=/])\\.trellis|\\$\\{?TRELLIS_HOME[}]?)(/+\\.)*/*(["\' \t\n\v\f\r;&|)<>]|(\n|$))|(((^|\n)|[ \t"\'=/])\\.trellis|\\$\\{?TRELLIS_HOME[}]?)(/+\\.)*/+state(/|["\' \t\n\v\f\r;&|)<>]|(\n|$))|(((^|\n)|[ \t"\'=/])\\.trellis|\\$\\{?TRELLIS_HOME[}]?)/([^ \t\n\v\f\r;&|"\'<>]*/)?\\.\\.([/"\' \t\n\v\f\r;&|)<>]|(\n|$))|((^|\n)|[ \t;&|(])cd[ \t]+["\']?[^ \t;&|"\']*(((^|\n)|[ \t"\'=/])\\.trellis|\\$\\{?TRELLIS_HOME[}]?)[^ \t;&|"\']*["\']?[ \t]*(&&|;)[^\n]*[ \t"\'=](\\./)*(\\.\\./)*(state|\\.\\.)(/|["\' \t\n\v\f\r;&|)<>]|(\n|$)))'; then
    GR_DENY_ID=gate-verdict-ancestor-write
    GR_DENY_REASON=$'Blocked a command that names the Trellis home, its state directory or a path under it, which holds the process-gate verdict store — only read-only tools may name them; an operator moves, removes or replaces them outside the agent.'
    GR_DENY_JSON=$'"Blocked a command that names the Trellis home, its state directory or a path under it, which holds the process-gate verdict store — only read-only tools may name them; an operator moves, removes or replaces them outside the agent."'
    return 0
  fi
  return 1
}

# --- rules/reread.json -------------------------------------------------------

# _gr_reread_budget <autonomy-level> — GR_BUDGET = warns allowed before a block.
_gr_reread_budget() {
  case $1 in
    4|5) GR_BUDGET=1 ;;
    *) GR_BUDGET=2 ;;
  esac
}

# _gr_reread_warn_msg <path> <count> <budget> — GR_MSG = the warn advisory.
_gr_reread_warn_msg() {
  GR_MSG='reread-guard: about to edit '"$1"' not Read this turn (warn '"$2"'/'"$3"'). Read it first, or have the operator run trellis reread override --session <id> --reason <why> (legacy shell hooks also accept TRELLIS_REREAD_OVERRIDE=1). Repeated FAILED stale edits will BLOCK.'
}

# _gr_reread_block_msg <path> — GR_MSG = the block reason.
_gr_reread_block_msg() {
  GR_MSG='reread-guard: BLOCKED edit of '"$1"$' — it was not Read this turn and the re-read warn budget is exhausted. Read it first, or have the operator run trellis reread override --session <id> --reason <why> (legacy shell hooks also accept TRELLIS_REREAD_OVERRIDE=1).'
}

# Edit-family error-string markers. The Codex guards hand these to jq's
# test(GR_EDIT_FAILURE_RE; GR_EDIT_FAILURE_FLAGS); _gr_edit_failed tests them here.
GR_EDIT_FAILURE_RE='does not match|String to replace|no changes|Error:|tool_use_error|ENOENT|not found|has not been read'
GR_EDIT_FAILURE_FLAGS=i

# _gr_edit_failed <response> — the response carries an edit-failure marker.
_gr_edit_failed() {
  _gr_with_rules _gr_edit_failed_rules "$1"
}

_gr_edit_failed_rules() {
  _gr_lines_of "$1"
  _gr_icase 1
  _gr_m 'does not match|String to replace|no changes|Error:|tool_use_error|ENOENT|not found|has not been read' 'does not match|String to replace|no changes|Error:|tool_use_error|ENOENT|not found|has not been read'
}
