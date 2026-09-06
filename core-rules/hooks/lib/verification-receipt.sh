#!/usr/bin/env bash
# verification-receipt.sh — durable evidence of ACTUALLY EXECUTED verification.
# Source: Trellis / core-rules / spec 045 (T6 phase 1).
#
# This is NOT a cache. Nothing here lets a caller skip a check, reuse a prior
# result, or shorten a command. `_vr_run` executes the real command every time
# and records what happened. Every receipt carries `reusable:false` with reason
# `open-contract`: no producer adapter has yet established a closed input
# contract (ESLint config alone can read an external policy file, so tool name,
# lockfile and installed-state markers are not closed inputs).
#
# Ship rules:
#   - Claude gets this through `core-rules/hooks/lib` source_children.
#   - Codex/Pi get explicit single-file links (see inheritance-manifest.json),
#     matching the existing shared-lib rows (code-reviewer.sh, slop-patterns.sh).
#   - Functions/globals are prefixed _vr_ / _VR_ to avoid clashing with the
#     _se_ helpers already sourced by the same hooks.
#
# Storage convention (justified in the T6 report): FLAT worktree-keyed receipt
# files in ONE private directory under the canonical Git common directory —
#   <git-common-dir>/trellis-verification-receipts/<wt16>.<UTCstamp>.<uniq>.json
# Flat files avoid a per-worktree directory tree: isolation is a filename
# prefix plus the in-file worktree_id binding the reader re-checks anyway, and
# pruning is a bounded glob rather than directory bookkeeping.
#
# Same-user forgery: these receipts are ordinary files owned by the user the
# hooks run as. Any process with that uid can write a well-formed receipt. The
# hashes here protect against truncation and accidental corruption, NOT against
# a same-user forger. That limitation is documented, not "solved" — no signing
# service, no key material, no new ownership system.

# --- Tunables (constants, not configuration) ---------------------------------
_VR_SCHEMA_VERSION=1
_VR_MAX_OUTPUT_BYTES=65536      # 64 KiB retained raw output per receipt
_VR_MAX_RECEIPTS=20             # completed receipts retained per worktree
_VR_DIR_NAME=trellis-verification-receipts

# --- Result globals (callers read these; see _vr_run) -------------------------
# shellcheck disable=SC2034  # read by the Stop hooks that source this file.
_VR_OUTPUT=""
_VR_STATUS=0
_VR_PERSIST_ERROR=""
_VR_ADVISED=0

# _vr_safe_abs <path> — same shape test the session-context worktree diagnosis
# uses: an absolute, non-root, traversal-free, whitespace-free path.
_vr_safe_abs() {
  local path="${1:-}"
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  [ "$path" != "/" ] || return 1
  case "$path" in
    *$'\t'*|*$'\n'*|*$'\r'*|*'//'|*/./*|*/../*|*/.|*/..|*/) return 1 ;;
  esac
}

# _vr_canonical_dir <path> — a real directory that is not a symlink and whose
# resolved form is spelled exactly as given.
_vr_canonical_dir() {
  local path="$1" actual
  _vr_safe_abs "$path" || return 1
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  actual="$(CDPATH='' cd "$path" 2>/dev/null && pwd -P)" || return 1
  [ "$actual" = "$path" ]
}

_vr_mode() {
  local mode
  if mode="$(stat -f '%Lp' "$1" 2>/dev/null)"; then
    :
  elif mode="$(stat -c '%a' "$1" 2>/dev/null)"; then
    :
  else
    return 1
  fi
  case "$mode" in
    ''|*[!0-7]*) return 1 ;;
  esac
  printf '%s' "$mode"
}

_vr_hash_text() {
  local output
  output="$(printf '%s' "$1" | shasum -a 256 2>/dev/null)" ||
    output="$(printf '%s' "$1" | sha256sum 2>/dev/null)" || return 1
  printf '%s' "${output%% *}"
}

_vr_byte_len() {
  printf '%s' "$1" | wc -c | tr -d '[:space:]'
}

_vr_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_vr_now_stamp() { date -u +%Y%m%dT%H%M%SZ; }

# _vr_advise <message> — the distinct "durable evidence unavailable" channel.
# Deliberately stderr: Stop stdout is a single-emission JSON contract, and the
# captured command output belongs to the caller's slicing/blocking logic. Never
# fold a recording failure into either. Emitted at most once per hook run.
_vr_advise() {
  [ "$_VR_ADVISED" = "0" ] || return 0
  _VR_ADVISED=1
  printf 'verification-receipt: durable evidence unavailable — %s (the check itself ran unchanged)\n' "$1" >&2
}

# _vr_roots — resolve and validate the canonical Git roots + provenance.
# Sets _VR_COMMON_DIR _VR_WORKTREE_ROOT _VR_CHECKOUT_ID _VR_WORKTREE_ID _VR_HEAD
# ("" for an unborn HEAD; rendered as JSON null). Returns non-zero with
# _VR_PERSIST_ERROR set on any failure.
_vr_roots() {
  local dir="${1:-$PWD}" common toplevel

  command -v git >/dev/null 2>&1 || { _VR_PERSIST_ERROR="git not found"; return 1; }
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    { _VR_PERSIST_ERROR="not inside a Git work tree"; return 1; }

  common="$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null)" ||
    { _VR_PERSIST_ERROR="could not resolve the Git common directory"; return 1; }
  case "$common" in /*) ;; *) common="$dir/$common" ;; esac
  common="$(CDPATH='' cd "$common" 2>/dev/null && pwd -P)" ||
    { _VR_PERSIST_ERROR="could not canonicalize the Git common directory"; return 1; }
  _vr_canonical_dir "$common" ||
    { _VR_PERSIST_ERROR="unsafe Git common directory: $common"; return 1; }

  toplevel="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" ||
    { _VR_PERSIST_ERROR="could not resolve the worktree root"; return 1; }
  toplevel="$(CDPATH='' cd "$toplevel" 2>/dev/null && pwd -P)" ||
    { _VR_PERSIST_ERROR="could not canonicalize the worktree root"; return 1; }
  _vr_canonical_dir "$toplevel" ||
    { _VR_PERSIST_ERROR="unsafe worktree root: $toplevel"; return 1; }

  _VR_COMMON_DIR="$common"
  _VR_WORKTREE_ROOT="$toplevel"
  _VR_CHECKOUT_ID="$(_vr_hash_text "$common")" ||
    { _VR_PERSIST_ERROR="could not hash the Git common directory"; return 1; }
  _VR_WORKTREE_ID="$(_vr_hash_text "$toplevel")" ||
    { _VR_PERSIST_ERROR="could not hash the worktree root"; return 1; }
  # Unborn HEAD is legitimate provenance-absent, not an error.
  _VR_HEAD="$(git -C "$dir" rev-parse HEAD 2>/dev/null || printf '')"
  case "$_VR_HEAD" in
    ''|*[!0-9a-f]*) _VR_HEAD="" ;;
  esac
}

# _vr_state_root <create:0|1> — validate (and optionally create) the private
# receipt directory. Never repairs permissions on a pre-existing user path; an
# unsafe destination is refused rather than written through.
_vr_state_root() {
  local create="${1:-0}" root mode
  root="$_VR_COMMON_DIR/$_VR_DIR_NAME"

  if [ -e "$root" ] || [ -L "$root" ]; then
    if [ -L "$root" ]; then
      _VR_PERSIST_ERROR="receipt directory is a symlink: $root"
      return 1
    fi
    _vr_canonical_dir "$root" || {
      _VR_PERSIST_ERROR="receipt directory is not a canonical directory: $root"
      return 1
    }
    mode="$(_vr_mode "$root")" || {
      _VR_PERSIST_ERROR="could not read the receipt directory mode: $root"
      return 1
    }
    # Refuse a group/other-writable destination. Do NOT chmod it: repairing a
    # pre-existing user path is out of scope for a hook.
    case "$mode" in
      *[2367]|*[2367]?) _VR_PERSIST_ERROR="receipt directory is group/other-writable (mode $mode): $root"; return 1 ;;
    esac
  else
    [ "$create" = "1" ] || { _VR_PERSIST_ERROR="no receipt directory at $root"; return 1; }
    ( umask 077 && mkdir "$root" ) 2>/dev/null || {
      _VR_PERSIST_ERROR="could not create the receipt directory: $root"
      return 1
    }
    chmod 700 "$root" 2>/dev/null || true
    _vr_canonical_dir "$root" || {
      _VR_PERSIST_ERROR="created receipt directory failed validation: $root"
      return 1
    }
  fi

  _VR_STATE_ROOT="$root"
}

# _vr_tmpdir — private capture/staging directory INSIDE the validated state
# root, never ambient TMPDIR (a receipt must never transit a shared path).
_vr_tmpdir() {
  local tmp="$_VR_STATE_ROOT/.tmp"
  if [ -L "$tmp" ]; then
    _VR_PERSIST_ERROR="receipt staging path is a symlink: $tmp"
    return 1
  fi
  if [ ! -e "$tmp" ]; then
    ( umask 077 && mkdir "$tmp" ) 2>/dev/null || {
      _VR_PERSIST_ERROR="could not create the receipt staging directory: $tmp"
      return 1
    }
    chmod 700 "$tmp" 2>/dev/null || true
  fi
  _vr_canonical_dir "$tmp" || {
    _VR_PERSIST_ERROR="receipt staging directory failed validation: $tmp"
    return 1
  }
  _VR_TMP_DIR="$tmp"
}

# _vr_harness_name — the producing harness, from the validated enum only.
_vr_harness_name() {
  case "${_VR_HARNESS:-}" in
    claude|codex|pi) printf '%s' "$_VR_HARNESS" ;;
    *) printf 'unknown' ;;
  esac
}

# _vr_collect <worktree-prefix> — fill _VR_FILES with the producer-owned receipt
# paths for this worktree, ascending by name. Validate the complete producer
# basename before reading OR pruning: numeric UTC stamp, positive PID and the
# concatenated numeric RANDOM values (2–10 digits). Unknown/control-bearing
# names never enter the array. Symlinks are rejected by both consumers.
_vr_collect() {
  local prefix="$1" file name
  local shape='^[0-9a-f]{16}\.[0-9]{8}T[0-9]{6}Z\.[1-9][0-9]{0,9}-[0-9]{2,10}\.json$'
  _VR_FILES=()
  for file in "$_VR_STATE_ROOT/$prefix".????????T??????Z.*.json; do
    name="${file##*/}"
    [[ "$name" =~ $shape ]] || continue
    [ -e "$file" ] || continue
    _VR_FILES[${#_VR_FILES[@]}]="$file"
  done
  [ "${#_VR_FILES[@]}" -gt 0 ]
}

# _vr_prune — keep at most _VR_MAX_RECEIPTS receipts for THIS worktree. Only
# producer-owned artifacts are eligible: our directory, our name shape, a
# regular non-symlink file, our schema version, and a matching worktree_id.
# Anything else (unknown file, symlink, foreign JSON) is left untouched.
_vr_prune() {
  local keep="$_VR_MAX_RECEIPTS" prefix file id version count=0 i
  local candidates=()
  prefix="$(printf '%s' "$_VR_WORKTREE_ID" | cut -c1-16)"

  # Collection validates names before any candidate can be read or removed.
  _vr_collect "$prefix" || return 0
  candidates=("${_VR_FILES[@]}")

  # Walk newest-first (the UTC stamp sorts lexicographically, and the glob
  # expands ascending) so only the tail past the cap is removed.
  for (( i=${#candidates[@]}-1; i>=0; i-- )); do
    file="${candidates[$i]}"
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    version="$(jq -r '.schema_version // empty' "$file" 2>/dev/null)" || continue
    [ "$version" = "$_VR_SCHEMA_VERSION" ] || continue
    id="$(jq -r '.roots.worktree_id // empty' "$file" 2>/dev/null)" || continue
    [ "$id" = "$_VR_WORKTREE_ID" ] || continue
    count=$((count + 1))
    if [ "$count" -gt "$keep" ]; then
      rm -f "$file" 2>/dev/null || true
    fi
  done
}

# _vr_persist <check_id> <form> <started> <finished> <status> <cwd> [cmd...]
# Writes ONE atomic receipt. Returns non-zero with _VR_PERSIST_ERROR set on any
# failure; the caller's check result is never affected either way.
_vr_persist() {
  local check_id="$1" form="$2" started="$3" finished="$4" status="$5" cwd="$6"
  shift 6

  local out_bytes out_hash retained text omitted argv_json shell_json form_label
  local stamp uniq name target tmpfile

  out_bytes="$(_vr_byte_len "$_VR_OUTPUT")"
  out_hash="$(_vr_hash_text "$_VR_OUTPUT")" || {
    _VR_PERSIST_ERROR="could not hash captured output"
    return 1
  }
  if [ "$out_bytes" -gt "$_VR_MAX_OUTPUT_BYTES" ]; then
    retained=false
    text=""
    omitted="output is ${out_bytes} bytes, above the ${_VR_MAX_OUTPUT_BYTES}-byte retention cap; raw output not retained"
  else
    retained=true
    text="$_VR_OUTPUT"
    omitted=""
  fi

  # `form` is the caller-facing keyword; the receipt records the SCHEMA value,
  # so a legacy `eval` site is never mistaken for an argv execution.
  if [ "$form" = "argv" ]; then
    form_label=argv
    argv_json="$(printf '%s\n' "$@" | jq -R . | jq -sc .)" || {
      _VR_PERSIST_ERROR="could not encode argv"
      return 1
    }
    shell_json=null
  else
    form_label=legacy-shell
    argv_json=null
    shell_json="$(jq -nc --arg s "$1" '$s')" || {
      _VR_PERSIST_ERROR="could not encode the legacy shell command"
      return 1
    }
  fi

  _vr_tmpdir || return 1

  stamp="$(_vr_now_stamp)"
  uniq="$$-${RANDOM}${RANDOM}"
  name="$(printf '%s' "$_VR_WORKTREE_ID" | cut -c1-16).${stamp}.${uniq}.json"
  target="$_VR_STATE_ROOT/$name"
  tmpfile="$_VR_TMP_DIR/$name.partial"

  if ! ( umask 077 && jq -n \
      --argjson schema_version "$_VR_SCHEMA_VERSION" \
      --arg check_id "$check_id" \
      --arg form "$form_label" \
      --argjson argv "$argv_json" \
      --argjson shell "$shell_json" \
      --arg cwd "$cwd" \
      --arg common_dir "$_VR_COMMON_DIR" \
      --arg worktree_root "$_VR_WORKTREE_ROOT" \
      --arg checkout_id "$_VR_CHECKOUT_ID" \
      --arg worktree_id "$_VR_WORKTREE_ID" \
      --arg head "$_VR_HEAD" \
      --arg harness "$(_vr_harness_name)" \
      --arg started_at "$started" \
      --arg finished_at "$finished" \
      --argjson exit_status "$status" \
      --argjson out_bytes "$out_bytes" \
      --arg out_hash "$out_hash" \
      --argjson retained "$retained" \
      --arg text "$text" \
      --arg omitted "$omitted" \
      '{
        schema_version: $schema_version,
        executed: true,
        check_id: $check_id,
        command: {form: $form, argv: $argv, shell: $shell},
        cwd: $cwd,
        roots: {
          git_common_dir: $common_dir,
          worktree_root: $worktree_root,
          checkout_id: $checkout_id,
          worktree_id: $worktree_id
        },
        head: (if $head == "" then null else $head end),
        harness: $harness,
        started_at: $started_at,
        finished_at: $finished_at,
        exit_status: $exit_status,
        output: {
          bytes: $out_bytes,
          sha256: $out_hash,
          retained: $retained,
          text: (if $retained then $text else null end),
          omitted_reason: (if $omitted == "" then null else $omitted end)
        },
        reusable: false,
        reusable_reason: "open-contract"
      }' > "$tmpfile" ) 2>/dev/null; then
    rm -f "$tmpfile" 2>/dev/null || true
    _VR_PERSIST_ERROR="could not stage the receipt under $_VR_TMP_DIR"
    return 1
  fi

  chmod 600 "$tmpfile" 2>/dev/null || true
  if ! mv -f "$tmpfile" "$target" 2>/dev/null; then
    rm -f "$tmpfile" 2>/dev/null || true
    _VR_PERSIST_ERROR="could not publish the receipt to $target"
    return 1
  fi

  _vr_prune
}

# _vr_run <check_id> argv  <program> [args...]
# _vr_run <check_id> shell <command-string>
#
# Runs the command EXACTLY as the caller would have (same argv or the same
# `eval` of the same string, same cwd, same inherited environment), captures
# combined stdout/stderr into _VR_OUTPUT, preserves the real exit status in
# _VR_STATUS, returns that status, and records an execution receipt. The
# command runs on every call — there is no reuse path.
_vr_run() {
  local check_id="$1" form="$2"
  shift 2
  local started finished cwd

  _VR_OUTPUT=""
  _VR_STATUS=0
  started="$(_vr_now_iso)"
  cwd="$PWD"

  if [ "$form" = "shell" ]; then
    # Same command substitution + eval the caller used. Not relocated into a
    # differently configured shell, and never reinterpreted as argv.
    _VR_OUTPUT="$(eval "$1" 2>&1)"
    _VR_STATUS=$?
  else
    _VR_OUTPUT="$("$@" 2>&1)"
    _VR_STATUS=$?
  fi
  finished="$(_vr_now_iso)"

  if _vr_roots "$cwd" && _vr_state_root 1 &&
     _vr_persist "$check_id" "$form" "$started" "$finished" "$_VR_STATUS" "$cwd" "$@"; then
    :
  else
    _vr_advise "${_VR_PERSIST_ERROR:-unknown recording failure}"
  fi

  return "$_VR_STATUS"
}

# _vr_read_recent [limit] — reader adapter. Prints at most <limit> (default 3)
# single-line summaries of VALID receipts for the ACTIVE worktree, newest
# first, or nothing at all when there are none. Prints only structured fields:
# never raw output, never a transcript, never reasoning. A malformed, tampered
# or foreign-worktree receipt is silently skipped — it is not evidence.
#
# Returns 0 when at least one summary was printed; 1 otherwise (the caller
# decides whether to render a bounded "unavailable" advisory).
_vr_read_recent() {
  local limit="${1:-3}" dir="${2:-$PWD}"
  local prefix file shown=0 i
  local check status harness head retained rbytes rhash text validated

  _vr_roots "$dir" || return 1
  _vr_state_root 0 || return 1

  prefix="$(printf '%s' "$_VR_WORKTREE_ID" | cut -c1-16)"
  _vr_collect "$prefix" || return 1
  for (( i=${#_VR_FILES[@]}-1; i>=0; i-- )); do
    [ "$shown" -lt "$limit" ] || break
    file="${_VR_FILES[$i]}"
    [ -f "$file" ] && [ ! -L "$file" ] || continue

    # Parse exactly one complete current-schema object, then use only that
    # validated snapshot. Hashes detect corruption, not same-user forgery.
    validated="$(jq -ces --arg common "$_VR_COMMON_DIR" \
      --arg root "$_VR_WORKTREE_ROOT" --arg checkout "$_VR_CHECKOUT_ID" \
      --arg worktree "$_VR_WORKTREE_ID" --argjson cap "$_VR_MAX_OUTPUT_BYTES" '
      def shape($expected): type == "object" and keys == ($expected | sort);
      def integer: type == "number" and . == floor;
      def bounded_text($max): type == "string" and length > 0 and length <= $max
        and (test("[\u0000-\u001f\u007f-\u009f]") | not);
      def utc:
        type == "string" and length == 20
        and test("^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z$")
        and (.[0:4] | tonumber) >= 1
        and (. as $s | try (strptime("%Y-%m-%dT%H:%M:%SZ") | mktime
          | strftime("%Y-%m-%dT%H:%M:%SZ") == $s) catch false);
      select(length == 1) | .[0] |
      select(shape(["schema_version","executed","check_id","command","cwd",
        "roots","head","harness","started_at","finished_at","exit_status",
        "output","reusable","reusable_reason"])) |
      select(.schema_version == 1 and .executed == true and .reusable == false
        and .reusable_reason == "open-contract") |
      select(.check_id | bounded_text(64) and test("^[a-z][a-z0-9_.-]*$")) |
      select(.command | shape(["form","argv","shell"]) and
        (if .form == "argv" then
          (.argv | type == "array" and length > 0 and all(.[]; type == "string"))
          and .shell == null
        elif .form == "legacy-shell" then
          .argv == null and (.shell | type == "string" and length > 0)
        else false end)) |
      select(.roots == {git_common_dir:$common, worktree_root:$root,
        checkout_id:$checkout, worktree_id:$worktree}) |
      select(.cwd | type == "string" and (. == $root or startswith($root + "/"))
        and (test("[\u0000-\u001f\u007f-\u009f]|//|/$|/(\\.\\.?)(/|$)") | not)) |
      select(.head == null or (.head | type == "string" and
        (length == 40 or length == 64) and test("^[0-9a-f]+$"))) |
      select(.harness == "claude" or .harness == "codex" or .harness == "pi") |
      select((.started_at | utc) and (.finished_at | utc) and .started_at <= .finished_at) |
      select(.exit_status | integer and . >= 0 and . <= 255) |
      select(.output | shape(["bytes","sha256","retained","text","omitted_reason"])
        and (.bytes | integer and . >= 0)
        and (.sha256 | type == "string" and length == 64 and test("^[0-9a-f]+$"))
        and (if .retained == true then
          (.text | type == "string") and .bytes <= $cap and .omitted_reason == null
        elif .retained == false then
          .text == null and .bytes > $cap and (.omitted_reason | bounded_text(256))
        else false end))
      ' "$file" 2>/dev/null)" || continue

    check="$(jq -r '.check_id' <<< "$validated")"
    status="$(jq -r '.exit_status' <<< "$validated")"
    harness="$(jq -r '.harness' <<< "$validated")"
    head="$(jq -r '.head // "unborn"' <<< "$validated")"

    # Retained-output integrity: a retained receipt whose stored text no longer
    # matches its recorded hash/size has been tampered with or truncated.
    retained="$(jq -r '.output.retained' <<< "$validated")"
    if [ "$retained" = "true" ]; then
      text="$(jq -r '.output.text' <<< "$validated")"
      rbytes="$(jq -r '.output.bytes' <<< "$validated")"
      rhash="$(jq -r '.output.sha256' <<< "$validated")"
      [ "$(_vr_byte_len "$text")" = "$rbytes" ] || continue
      [ "$(_vr_hash_text "$text")" = "$rhash" ] || continue
    fi

    printf -- '- %s: exit %s (%s, HEAD %s, receipt %s)\n' \
      "$check" "$status" "$harness" "$(printf '%s' "$head" | cut -c1-8)" \
      "$(basename "$file" .json)"
    shown=$((shown + 1))
  done

  [ "$shown" -gt 0 ]
}
