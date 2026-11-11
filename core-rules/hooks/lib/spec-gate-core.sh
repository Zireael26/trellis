#!/usr/bin/env bash
# spec-gate-core.sh — deterministic mandatory-pipeline gate (spec 006).
#
# Sourced by (never executed directly):
#   - core-rules/hooks/spec-gate.sh          (Claude: Stop early-warning + PreToolUse advisory)
#   - core-rules/codex/hooks/spec-gate.sh    (Codex twin)
#   - core-rules/husky/pre-push              (LOAD-BEARING teeth, harness-agnostic)
#   - core-rules/githooks/pre-push           (same, native-hooks projects)
#
# THE PARITY GUARANTEE: `sg_verdict` is a pure function of git/filesystem state —
# branch diff size, which paths changed, whether a spec triad was added in THIS
# branch's range, whether a bound surgical marker exists. ZERO model
# classification. Same repo state => same verdict on Claude and Codex. That is
# what makes enforcement equal across harnesses (spec §0.2, §0.6).
#
# Side effects: only `sg_valid_marker` appends to the audit log. Everything else
# is read-only. Mandatory-pipeline environment failures block (SC11): a missing
# tool or uncertain diff cannot substitute a warning for a mandatory decision.
# Valid disabled/protected/sub-floor precedence is retained; malformed policy
# never silently disables an opted-in project (spec §0.6 C-6a).

# Resolve the deps lib relative to THIS file (works from any consumer location).
_sg_lib_dir=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=/dev/null
[ -f "$_sg_lib_dir/deps.sh" ] && . "$_sg_lib_dir/deps.sh"
# The interview gate shares the canonical autonomy resolver with every other
# harness-facing hook. A deployed runtime carries this sibling beside the core.
# shellcheck source=/dev/null
[ -f "$_sg_lib_dir/autonomy.sh" ] && . "$_sg_lib_dir/autonomy.sh"


# Built-in fallbacks (documented in core-rules/hooks.md; overridable via config).
SG_DEFAULT_FLOOR=80
SG_DEFAULT_CEILING=400
SG_TEMPLATE_MIN_BYTES=200

# --- config resolution ------------------------------------------------------
# Policy is field-resolved so a portable project manifest can override only the
# value it owns. Attached projects consume the immutable runtime only; an
# unattached checkout has project policy plus built-ins, never mutable source
# policy at its repository root.
_sg_policy_files() {
  local root="$1"
  # `.trellis.config.json` is a DEPRECATED read-only fallback, retained past
  # v1.0.0-rc.25 only for checkouts still held on the legacy layout.
  printf '%s\n' \
    "$root/.trellis.json" \
    "$root/.trellis.config.json"
  [ -n "${TRELLIS_ROOT:-}" ] && printf '%s\n' "$TRELLIS_ROOT/trellis.config.json"
}

# Object reads are pinned to the requested commit. Marker/session files remain
# checkout state; only committed project policy and interview artifacts move.
sg_ref_file() {
  local dir="$1" head="$2" path="$3" entry
  entry=$(git -C "$dir" ls-tree "$head" -- "$path" 2>/dev/null) || return 1
  case "$entry" in
    *" blob "*) git -C "$dir" show "$head:$path" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

# SG_OBJECT_* are dynamically scoped to one sg_verdict; other callers read disk.
sg_policy_json() {
  case "${1##*/}" in
    .trellis.json|.trellis.config.json)
      if [ -n "${SG_OBJECT_HEAD:-}" ]; then
        sg_ref_file "$SG_OBJECT_DIR" "$SG_OBJECT_HEAD" "${1##*/}"; return
      fi ;;
  esac
  [ -f "$1" ] || return 1
  printf '%s\n' "$(< "$1")"
}

# Echoes TAB-separated: "<value>\t<status>\t<file>"
#   status: ok | disabled | malformed | nojq
# `null` means the field was absent. A status of `ok` with `null` means that a
# valid block was present but did not declare this field, so its caller applies
# the field's built-in fallback.
_sg_resolve_block_field() {
  local root="$1" block="$2" field="$3" extra="${4:-}" f json match="" value=""
  if ! command -v jq >/dev/null 2>&1; then printf 'null\tnojq\t\n'; return; fi
  while IFS= read -r f; do
    json=$(sg_policy_json "$f") || continue
    # A present unparseable or non-object config is malformed => fail closed.
    if ! jq -e 'type == "object"' <<<"$json" >/dev/null 2>&1; then
      printf 'null\tmalformed\t\n'; return
    fi
    if ! jq -e --arg b "$block" 'has($b)' <<<"$json" >/dev/null 2>&1; then
      continue
    fi
    if ! jq -e --arg b "$block" '.[$b] | type == "object"' <<<"$json" >/dev/null 2>&1; then
      printf 'null\tmalformed\t\n'; return
    fi
    if [ -n "$extra" ] && ! jq -e --arg b "$block" ".[\$b] | ( $extra )" <<<"$json" >/dev/null 2>&1; then
      printf 'null\tmalformed\t\n'; return
    fi
    [ -n "$match" ] || match="$f"
    if jq -e --arg b "$block" --arg k "$field" '.[$b] | has($k)' <<<"$json" >/dev/null 2>&1; then
      value=$(jq -r --arg b "$block" --arg k "$field" '.[$b][$k]' <<<"$json" 2>/dev/null)
      printf '%s\tok\t%s\n' "$value" "$f"
      return
    fi
  done < <(_sg_policy_files "$root")
  if [ -n "$match" ]; then
    printf 'null\tok\t%s\n' "$match"
  else
    printf 'null\tdisabled\t\n'
  fi
}

# ONE parser, N blocks. Every boolean-gated Trellis config block shares the
# same source order, unparseable-config rule, and enabled-key validation.
#
# Echoes TAB-separated: "<enabled>\t<status>\t<file>"
#   status: ok | disabled | malformed | nojq
#   file:   the config that supplied `enabled`, or the first declaring config
#           when a valid block omits that key.
#
# Args: $1 repo root, $2 block name, $3 optional jq filter evaluated against the
# block for block-specific key validation — must output true to pass.
#
# `enabled=false` is returned for every non-ok status. The consumer decides
# what false means; `mandatory_pipeline` escalates `malformed` to a hard block
# (an opted-in project must not be silently disabled by a typo).
sg_resolve_block() {
  local root="$1" block="$2" extra="${3:-}" out enabled status file
  out=$(_sg_resolve_block_field "$root" "$block" enabled "$extra")
  IFS=$'\t' read -r enabled status file <<EOF
$out
EOF
  case "$status" in
    nojq|malformed|disabled) printf 'false\t%s\t\n' "$status"; return ;;
  esac
  # NB: do NOT use jq's `//` on enabled — it treats boolean false as absent.
  case "$enabled" in
    true|false) ;;
    null|'') enabled=false ;;
    *) printf 'false\tmalformed\t\n'; return ;;
  esac
  printf '%s\tok\t%s\n' "$enabled" "$file"
}

# Rare multi-document inputs retain the original jq-stream semantics. The
# values below are invocation-local snapshots, not environment-supplied cache
# entries: this subshell never reopens a policy file or a committed blob.
_sg_resolve_cfg_legacy_cached() (
  local root="$1" validation="$2" out enabled status file floor="" ceiling=""
  sg_policy_json() {
    local i=0
    while [ "$i" -lt "$_sg_cfg_count" ]; do
      if [ "${_sg_cfg_paths[$i]}" = "$1" ]; then
        printf '%s' "${_sg_cfg_errors[$i]}" >&2
        [ "${_sg_cfg_present[$i]}" = 1 ] || return 1
        printf '%s\n' "${_sg_cfg_values[$i]}"
        return 0
      fi
      i=$((i + 1))
    done
    return 1
  }
  out=$(sg_resolve_block "$root" mandatory_pipeline "$validation")
  IFS=$'\t' read -r enabled status file <<EOF
$out
EOF
  if [ "$status" != ok ]; then
    echo "false $SG_DEFAULT_FLOOR $SG_DEFAULT_CEILING $status"; return
  fi
  out=$(_sg_resolve_block_field "$root" mandatory_pipeline spec_required_diff_lines "$validation")
  IFS=$'\t' read -r floor status file <<EOF
$out
EOF
  if [ "$status" != ok ]; then
    echo "false $SG_DEFAULT_FLOOR $SG_DEFAULT_CEILING $status"; return
  fi
  out=$(_sg_resolve_block_field "$root" mandatory_pipeline surgical_max_diff_lines "$validation")
  IFS=$'\t' read -r ceiling status file <<EOF
$out
EOF
  if [ "$status" != ok ]; then
    echo "false $SG_DEFAULT_FLOOR $SG_DEFAULT_CEILING $status"; return
  fi
  case "$floor" in null|'') floor=$SG_DEFAULT_FLOOR ;; esac
  case "$ceiling" in null|'') ceiling=$SG_DEFAULT_CEILING ;; esac
  echo "$enabled $floor $ceiling ok"
)

# Echoes: "<enabled> <floor> <ceiling> <status>"
#   status: ok | disabled | malformed | nojq
# Resolve each field independently in precedence order. A lower source is
# inspected only while a field is unresolved, exactly as in the old per-field
# searches; a malformed source cannot be skipped merely because enabled won.
sg_resolve_cfg() {
  local root="$1" f json out e n c enabled="" floor="" ceiling=""
  local found_block=0 fallback=0 _sg_cfg_count=0 i snapshot trailer length errlen read_rc
  local -a _sg_cfg_paths _sg_cfg_present _sg_cfg_values _sg_cfg_errors
  local validation='
        def optional_boolean($key):
            if (has($key) | not) then true
            else (.[$key] | type == "boolean" or type == "null")
            end;
        def positive_integer($key):
            if (has($key) | not) then true
            else (.[$key] | if type == "number" then (. > 0 and floor == .) else false end)
            end;
          optional_boolean("enabled")
          and positive_integer("spec_required_diff_lines")
          and positive_integer("surgical_max_diff_lines")'
  if ! command -v jq >/dev/null 2>&1; then
    echo "false $SG_DEFAULT_FLOOR $SG_DEFAULT_CEILING nojq"; return
  fi

  while IFS= read -r f; do
    i=$_sg_cfg_count; _sg_cfg_count=$((_sg_cfg_count + 1))
    _sg_cfg_paths[$i]=$f; _sg_cfg_present[$i]=0; _sg_cfg_values[$i]=""
    # Preserve diagnostics without printing errors from a lower source that
    # a per-field search would never reach. The suffix encodes the captured
    # value length and status, so even control characters in JSON cannot be
    # confused with the separator. A diagnostic takes the legacy replay path.
    snapshot=$(
      {
        if json=$(sg_policy_json "$f"); then read_rc=0; else read_rc=$?; fi
        printf '%s\037%s:%s' "$json" "${#json}" "$read_rc"
      } 3>&1 2>&3
    )
    trailer=${snapshot##*$'\037'}; snapshot=${snapshot%$'\037'*}
    length=${trailer%:*}; read_rc=${trailer##*:}; errlen=$((${#snapshot} - length))
    _sg_cfg_errors[$i]=${snapshot:0:errlen}; json=${snapshot:errlen}
    [ -z "${_sg_cfg_errors[$i]}" ] || fallback=1
    if [ "$read_rc" -eq 0 ]; then
      _sg_cfg_present[$i]=1; _sg_cfg_values[$i]=$json
    else
      continue
    fi
    [ "$fallback" -eq 0 ] || continue
    if ! out=$(jq -r -s '
      def optional_boolean($key):
        if (has($key) | not) then true
        else (.[$key] | type == "boolean" or type == "null") end;
      def positive_integer($key):
        if (has($key) | not) then true
        else (.[$key] | if type == "number" then (. > 0 and floor == .) else false end) end;
      if length == 0 then "malformed"
      elif length != 1 then "legacy"
      elif (.[0] | type != "object") then "malformed"
      elif (.[0] | has("mandatory_pipeline") | not) then "absent"
      elif (.[0].mandatory_pipeline | type != "object") then "malformed"
      elif (.[0].mandatory_pipeline |
        (optional_boolean("enabled") and positive_integer("spec_required_diff_lines")
         and positive_integer("surgical_max_diff_lines")) | not) then "malformed"
      else .[0].mandatory_pipeline |
        ["block",
         (if has("enabled") then "P" + (.enabled | tostring) else "A" end),
         (if has("spec_required_diff_lines") then "P" + (.spec_required_diff_lines | tostring) else "A" end),
         (if has("surgical_max_diff_lines") then "P" + (.surgical_max_diff_lines | tostring) else "A" end)] | join("\t")
      end' <<<"$json" 2>/dev/null); then
      echo "false $SG_DEFAULT_FLOOR $SG_DEFAULT_CEILING malformed"; return
    fi
    case "$out" in
      absent) continue ;;
      malformed) echo "false $SG_DEFAULT_FLOOR $SG_DEFAULT_CEILING malformed"; return ;;
      legacy) fallback=1; continue ;;
      $'block\t'*) ;;
      *) fallback=1; continue ;;
    esac
    out=${out#*$'\t'}
    IFS=$'\t' read -r e n c <<EOF
$out
EOF
    found_block=1
    [ -n "$enabled" ] || case "$e" in P*) enabled=${e#P} ;; esac
    [ -n "$floor" ] || case "$n" in P*) floor=${n#P} ;; esac
    [ -n "$ceiling" ] || case "$c" in P*) ceiling=${c#P} ;; esac
    [ -z "$enabled" ] || [ -z "$floor" ] || [ -z "$ceiling" ] || break
  done < <(_sg_policy_files "$root")

  if [ "$fallback" -eq 1 ]; then
    _sg_resolve_cfg_legacy_cached "$root" "$validation"; return
  fi
  if [ "$found_block" -eq 0 ]; then
    echo "false $SG_DEFAULT_FLOOR $SG_DEFAULT_CEILING disabled"; return
  fi
  case "$enabled" in null|'') enabled=false ;; esac
  case "$floor" in null|'') floor=$SG_DEFAULT_FLOOR ;; esac
  case "$ceiling" in null|'') ceiling=$SG_DEFAULT_CEILING ;; esac
  echo "$enabled $floor $ceiling ok"
}

# --- protected branch + diff baseline ---------------------------------------
# Optional fallback is empty for the resolver, main for the protected-branch guard.
sg_protected_branch() {
  local root="$1" out b status file
  local validation='
    if (has("branch") | not) then true
    else (.branch | type == "string" and length > 0)
    end'
  out=$(_sg_resolve_block_field "$root" template branch "$validation")
  IFS=$'\t' read -r b status file <<EOF
$out
EOF
  if [ "$status" = ok ] && [ -n "$b" ] && [ "$b" != null ]; then
    printf '%s' "$b"
  else
    printf '%s' "${2-main}"
  fi
}

# Resolver candidates match the process-gate runner layouts, including the
# common checkout for linked worktrees. The core's sibling skill covers payload
# execution and deployed .claude/hooks/lib -> .claude/skills installations.
# A gate deployed at <root>/.codex/hooks also tries <root>/.agents/skills,
# where Codex installs process-gate: still the running gate's own tree.
sg_find_resolver() {
  local dir="$1" root="$2" candidate codex_skill=""
  case "$_sg_lib_dir" in
    */.codex/hooks/lib) codex_skill="${_sg_lib_dir%/.codex/hooks/lib}/.agents/skills/process-gate/scripts/lib/diff-base.sh" ;;
  esac
  for candidate in \
    "${TRELLIS_ROOT:+$TRELLIS_ROOT/core-rules/skills/process-gate/scripts/lib/diff-base.sh}" \
    "$_sg_lib_dir/../../skills/process-gate/scripts/lib/diff-base.sh" \
    "$codex_skill"; do
    [ -n "$candidate" ] || continue
    [ -f "$candidate" ] || continue
    printf '%s' "$candidate"; return 0
  done
  return 4
}

# The protected-branch exemption must use the same trusted default-branch
# authority as the diff resolver, not policy from the branch being judged.
sg_trusted_protected_branch() (
  local dir="$1" root="$2" resolver name _dd_ref=""
  resolver=$(sg_find_resolver "$dir" "$root") || return 1
  # shellcheck source=/dev/null
  . "$resolver"
  cd -- "$dir" || return 1
  db_defbranch || return 1
  case "$_dd_ref" in
    refs/remotes/*) name=${_dd_ref#refs/remotes/}; name=${name#*/} ;;
    refs/heads/*) name=${_dd_ref#refs/heads/} ;;
    *) name=$_dd_ref ;;
  esac
  [ -n "$name" ] || return 1
  printf '%s' "$name"
)

# The caller supplies a root it has already resolved in this operation.
_sg_resolve_diff_with_root() (
  local dir="$1" range="${2:-}" ref="${3:-}" head="${4:-}" root="$5" resolver rc
  resolver=$(sg_find_resolver "$dir" "$root") || return 4
  # shellcheck source=/dev/null
  . "$resolver"
  cd -- "$dir" || return 1
  # The resolver reads template.branch from the base, never from the head tree
  # or the worktree, so the range under test cannot pick its own base.
  if db_resolve --range="$range" --ref="$ref" --head="$head"; then rc=0; else rc=$?; fi
  printf '%s\t%s\t%s' "${DB_BASE_SHA:--}" "${DB_RANGE:--}" "$(db_receipt)"
  return "$rc"
)

# Echoes TAB-separated base / exact range / receipt. No network in a hook.
# Resolve in the target checkout, without changing a sourced caller's cwd.
# Keep the public function's original behavior of ignoring extra arguments.
sg_resolve_diff() (
  local dir="$1" root
  root=$(_se_repo_root "$dir" 2>/dev/null || printf '%s' "$dir")
  _sg_resolve_diff_with_root "$dir" "${2:-}" "${3:-}" "${4:-}" "$root"
)

# Compatibility API for /surgical: new markers bind the resolver base. The
# old protected-branch argument is retained, but policy belongs to the resolver.
sg_merge_base() {
  local resolved base
  resolved=$(sg_resolve_diff "$1" "${3:-}") || return 1
  base=${resolved%%$'\t'*}
  [ -n "$base" ] || return 1
  printf '%s' "$base"
}

# 1.3.10 binding ONLY: retained for existing markers in 1.3.12a/1.3.12
# (spec 067 6.1.7). Never used to derive a verdict or write a new marker.
sg_legacy_merge_base() {
  local dir="$1" b="$2" head="${3:-HEAD}" base=""
  base=$(git -C "$dir" merge-base "$head" "origin/$b" 2>/dev/null) && { printf '%s' "$base"; return; }
  base=$(git -C "$dir" merge-base "$head" "$b" 2>/dev/null) && { printf '%s' "$base"; return; }
  printf ''
}

# Shared CLI parsing keeps both harness prefixes identical. Missing resolver
# blocks --gate even when policy would otherwise disable the pipeline.
sg_gate_args() {
  shift
  SG_REQUEST_RANGE=""; SG_REQUEST_REF=""; SG_REQUEST_HEAD=""
  local option value
  while [ "$#" -gt 0 ]; do
    option=${1%%=*}
    case "$1" in
      --range=*|--ref=*|--head=*) value=${1#*=} ;;
      --range|--ref|--head) shift; value=${1:-} ;;
      *) printf '[spec-gate] BLOCKED: unknown gate argument: %s\n' "$1" >&2; return 1 ;;
    esac
    [ -n "$value" ] || { printf '[spec-gate] BLOCKED: %s requires a value\n' "$option" >&2; return 1; }
    case "$option" in
      --range) SG_REQUEST_RANGE="$value" ;;
      --ref) SG_REQUEST_REF="$value" ;;
      --head) SG_REQUEST_HEAD="$value" ;;
    esac
    shift
  done
  local root
  root=$(_se_repo_root "$PWD" 2>/dev/null || printf '%s' "$PWD")
  sg_find_resolver "$PWD" "$root" >/dev/null || {
    printf '[spec-gate] BLOCKED: diff-base resolver missing from trusted runtime; restore the process-gate skill\n' >&2
    return 4
  }
}

# Include one receipt in the reason, before the human verdict text. Dynamic
# scope keeps SG_RECEIPT local to sg_verdict, including sourced callers.
sg_result() {
  printf '%s\t' "$1"
  [ -z "${SG_RECEIPT:-}" ] || printf '%s\n' "$SG_RECEIPT"
  printf '%s' "$2"
}

# A path excluded from the "gated" (feature-code) diff. Deterministic + shared
# so Claude and Codex classify identically (spec §0.6 C-5b/c, PD3).
sg_is_excluded_path() {
  local base="${1##*/}"
  # Test-file patterns apply only to the basename; test-like directories may hold production code.
  case "$base" in
    *_test.*|*.test.*|*.spec.*|*.bats|*Tests.swift|test_*.py|*Test.kt) return 0 ;;
  esac
  case "$1" in
    docs/*|*/docs/*|specs/*|*/specs/*|audits/*|*/audits/*) return 0 ;;
    # Inherited Trellis infrastructure: copied from the canonical clone by
    # sync-hooks.sh / sync-codex-hooks.sh / onboard-project.sh, never authored in
    # the project. The spec that governs this content lives in the Trellis repo,
    # so demanding a project-local triad for a mechanical redistribution is a
    # category error — and one that fires on every fleet hook sync by
    # construction, since the canonical hook set is far larger than any floor.
    .claude/*|*/.claude/*|.codex/*|*/.codex/*|.agents/*|*/.agents/*) return 0 ;;
    */generated/*|*.gen.*|*.pb.*|*_pb2.*|*.min.js|*.min.css|*.map) return 0 ;;
    *.svg|*.png|*.jpg|*.jpeg|*.gif|*.ico|*.pdf) return 0 ;;
    *pnpm-lock.yaml|*package-lock.json|*yarn.lock|*Cargo.lock|*go.sum|*poetry.lock|*uv.lock|*Pipfile.lock|*Gemfile.lock|*composer.lock) return 0 ;;
    package.json|*/package.json|trellis.config.json|.trellis.config.json) return 0 ;;
    *.yml|*.yaml) return 0 ;;
    # Root-level paste-into-agent guides: AGENT_SETUP.md, AGENT_ONBOARD_PROJECT.md,
    # AGENT_UPGRADE.md, AGENT_PI_SETUP.md. Prose documentation, the same category
    # `docs/*` already exempts one directory down; these sit at the root only
    # because the public mirror surfaces them there. Anchored at the start of the
    # path, so a nested docs/AGENT_*.md is covered by the docs/ rule instead.
    AGENT_*.md) return 0 ;;
    CHANGELOG.md) return 0 ;;
    # The project's own records (CLAUDE.md: gotchas.md, decisions-log.md) and
    # their archives, at the root only. Archiving moves many lines and is not
    # feature code; a nested src/decisions-log.ts still counts.
    gotchas.md|gotchas-archive.md|gotchas.archive.md|decisions-log.md|decisions-log-archive/*.md) return 0 ;;
    # Root agent instructions are prose too; a memory sweep rewrites hundreds of
    # lines. Root only: a nested pkg/CLAUDE.md still counts.
    CLAUDE.md|AGENTS.md) return 0 ;;
    *) return 1 ;;
  esac
}

# Echoes the net gated diff size (added+deleted, excluded paths removed) for the
# exact resolved range. Echoes "-1" if the diff cannot be computed (fail-open).
sg_compute_gated_diff() {
  local dir="$1" range="$2" total=0 adds dels relp row old numstat valid=1
  [ -n "$range" ] || { printf '%s' "-1"; return; }
  numstat=$(mktemp "${TMPDIR:-/tmp}/trellis-spec-numstat.XXXXXX") || { printf '%s' "-1"; return; }
  if ! git -C "$dir" diff --numstat -z "$range" > "$numstat" 2>/dev/null; then
    rm -f -- "${numstat:?}"
    printf '%s' "-1"; return
  fi
  # With -z, a rename is 'adds<TAB>dels<TAB>NUL old<NUL>new<NUL>'.
  # Classify its destination, while counting only the actual changed lines.
  while IFS= read -r -d '' row; do
    case "$row" in *$'\t'*$'\t'*) ;; *) valid=0; break ;; esac
    adds=${row%%$'\t'*}; row=${row#*$'\t'}
    dels=${row%%$'\t'*}; relp=${row#*$'\t'}
    if [ -z "$relp" ]; then
      IFS= read -r -d '' old && [ -n "$old" ] && IFS= read -r -d '' relp && [ -n "$relp" ] || { valid=0; break; }
    fi
    if [ "$adds" = '-' ] && [ "$dels" = '-' ]; then continue; fi
    case "$adds:$dels" in *[!0-9:]*|:*|*:) valid=0; break ;; esac
    sg_is_excluded_path "$relp" && continue
    total=$(( total + adds + dels ))
  done < "$numstat"
  rm -f -- "${numstat:?}"
  [ "$valid" -eq 1 ] || { printf '%s' "-1"; return; }
  printf '%s' "$total"
}

# --- spec-triad-in-range (C-CRIT-1) + non-template (C-CRIT-2) ----------------
# Echoes the triad dir (specs/NNN-*/) iff a full spec+plan+tasks triad was
# ADDED OR MODIFIED within this branch's range AND passes the non-template
# check. Merely existing on main does NOT count. Empty with status 0 means no
# qualifying triad; status 2 means git/grep discovery failed.
sg_triad_in_range() {
  local dir="$1" range="$2" head="${3:-}" paths changed d f grep_status complete
  if ! paths=$(git -C "$dir" diff --name-only "$range" 2>/dev/null); then
    return 2
  fi
  if changed=$(grep -E '^specs/[0-9][^/]*/(spec|plan|tasks)\.md$' <<<"$paths" 2>/dev/null); then
    :
  else
    grep_status=$?
    case "$grep_status" in
      1) printf ''; return 0 ;;              # no matching in-range triad paths
      *) return 2 ;;
    esac
  fi
  # Group by triad dir; a dir qualifies only if all three files are in-range.
  for d in $(printf '%s\n' "$changed" | sed -E 's#^(specs/[0-9][^/]*)/.*#\1#' | sort -u); do
    complete=true
    for f in spec.md plan.md tasks.md; do
      if printf '%s\n' "$changed" | grep -qx "$d/$f" 2>/dev/null; then
        :
      else
        grep_status=$?
        case "$grep_status" in
          1) complete=false; break ;;
          *) return 2 ;;
        esac
      fi
    done
    if [ "$complete" = true ] && sg_nontemplate_ok "$dir/$d" "$dir" "$head" "$d"; then
      printf '%s' "$d"; return
    fi
  done
  printf ''
}

# Each triad file must exceed a min size and carry no unfilled placeholder token.
sg_nontemplate_ok() {
  local tdir="$1" dir="${2:-}" head="${3:-}" rel="${4:-}" f bytes text
  for f in spec.md plan.md tasks.md; do
    if [ -n "$head" ]; then
      text=$(sg_ref_file "$dir" "$head" "$rel/$f") || return 1
      bytes=$(git -C "$dir" cat-file -s "$head:$rel/$f" 2>/dev/null) || return 1
    else
      [ -f "$tdir/$f" ] || return 1
      text=$(< "$tdir/$f")
      bytes=$(wc -c < "$tdir/$f" 2>/dev/null | tr -d ' ')
    fi
    [ "${bytes:-0}" -ge "$SG_TEMPLATE_MIN_BYTES" ] || return 1
    printf '%s\n' "$text" | grep -qE '<NNN>|<slug>|TODO-SPEC|SCAFFOLD-PLACEHOLDER' && return 1
  done
  return 0
}

# --- interview artifact (autonomy-tied, spec §0.6 PD6a / C-4c) ---------------
sg_autonomy_level() {
  local root="$1"
  command -v jq >/dev/null 2>&1 || { printf '3'; return; }
  # Never repeat project/runtime lookup here: the shared resolver is the
  # cross-harness authority for precedence, session overrides, and ceilings.
  type _se_resolve_autonomy >/dev/null 2>&1 || { printf '3'; return; }
  if [ -n "${SG_OBJECT_HEAD:-}" ]; then
    _se_resolve_autonomy "$root" sg_policy_json || return 1
  else
    _se_resolve_autonomy "$root" || return 1
  fi
  printf '%s' "${AUTONOMY_LEVEL:-3}"
}

# Match a literal whole branch token, not a prefix or substring of another ref.
# Whitespace/colon are ref-invalid delimiters; common paired Markdown wrappers
# permit a branch to be recorded in prose without interpreting it as a regex.
sg_branch_token_in_log() {
  [ -n "$1" ] || return 1
  LC_ALL=C awk -v branch="$1" '
    function boundary(c) { return c == "" || c ~ /[[:space:]:]/ }
    {
      text = $0
      while ((pos = index(text, branch)) != 0) {
        left = pos > 1 ? substr(text, pos - 1, 1) : ""
        right = substr(text, pos + length(branch), 1)
        if ((boundary(left) && boundary(right)) ||
            (left == "`" && right == "`") ||
            (left == "(" && right == ")") ||
            (left == "[" && right == "]")) { found = 1; exit }
        text = substr(text, pos + 1)
      }
    }
    END { exit !found }
  '
}

# L1-3: real interview => clarify.md in the triad OR an explicit spec-waiver.
# L4-5: agent self-answers => a decisions-log entry for this branch.
sg_interview_artifact_ok() {
  local dir="$1" root="$2" tdir="$3" branch="$4" head="${5:-}" lvl
  lvl=$(sg_autonomy_level "$root") || return 1
  if [ "$lvl" -ge 4 ]; then
    if [ -n "$head" ]; then
      sg_ref_file "$dir" "$head" decisions-log.md | sg_branch_token_in_log "$branch"; return
    fi
    [ -f "$root/decisions-log.md" ] && sg_branch_token_in_log "$branch" < "$root/decisions-log.md" && return 0
    return 1
  fi
  if [ -n "$head" ]; then
    sg_ref_file "$dir" "$head" "$tdir/clarify.md" >/dev/null && return 0
    sg_ref_file "$dir" "$head" .claude/spec-waiver >/dev/null; return
  fi
  [ -f "$dir/$tdir/clarify.md" ] && return 0
  [ -f "$root/.claude/spec-waiver" ] && return 0
  return 1
}

# --- surgical / emergency marker (C-3a bind + expiry, C-6c emergency) --------
# Marker file lines: branch / worktree_root / merge_base / head / session / mode / reason
# mode: surgical | emergency. Honored only on full bind match. Emits audit lines.
sg_valid_marker() {
  local dir="$1" root="$2" base="$3" diff="$4" ceiling="$5" branch="$6" head="${7:-}"
  local marker="$root/.claude/session-surgical" log="$root/.claude/spec-gate-audit.log"
  [ -f "$marker" ] || return 1
  local m_branch m_wt m_base m_mode m_reason wt
  m_branch=$(sed -n '1p' "$marker"); m_wt=$(sed -n '2p' "$marker")
  m_base=$(sed -n '3p' "$marker");   m_mode=$(sed -n '6p' "$marker")
  m_reason=$(sed -n '7p' "$marker")
  wt=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)
  # Branch/worktree binding is unchanged; only the base has a release-limited
  # compatibility allowance. An unrelated (or empty) base never qualifies.
  [ "$m_branch" = "$branch" ] && [ "$m_wt" = "$wt" ] || return 1
  [ -n "$m_base" ] || return 1
  if [ "$m_base" != "$base" ]; then
    local legacy
    legacy=$(sg_legacy_merge_base "$dir" "$(sg_protected_branch "$root")" "$head")
    [ -n "$legacy" ] && [ "$m_base" = "$legacy" ] || return 1
  fi
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "?")
  if [ "$m_mode" = "emergency" ]; then
    # SAFETY: An emergency override is valid only after its audit record is appended.
    if ! printf '%s\temergency-override\t%s\tdiff=%s\t%s\n' \
      "$ts" "$branch" "$diff" "$m_reason" 2>/dev/null >> "$log"; then
      return 1
    fi
    return 0
  fi
  if [ "$diff" -le "$ceiling" ]; then return 0; fi
  # Over-ceiling non-emergency surgical claim: invalid + flag for audit.
  printf '%s\toversized-surgical\t%s\tdiff=%s>ceiling=%s\t%s\n' "$ts" "$branch" "$diff" "$ceiling" "$m_reason" >> "$log" 2>/dev/null
  return 1
}

# --- marker writer (used by /surgical) --------------------------------------
# Writes a fully-bound marker so sg_valid_marker honors it (and only it).
# mode: surgical | emergency. Fields (one per line): branch, worktree root,
# merge-base, declaring HEAD, session id, mode, reason.
sg_write_marker() {
  local mode="$1" reason="$2" dir root branch wt base head
  dir=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  root=$(_se_repo_root "$dir" 2>/dev/null || printf '%s' "$dir")
  branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
  [ -n "$branch" ] && [ "$branch" != "HEAD" ] || return 1
  wt="$dir"
  base=$(sg_merge_base "$dir" "$(sg_protected_branch "$root")") || return 1
  head=$(git -C "$dir" rev-parse HEAD 2>/dev/null)
  mkdir -p "$root/.claude" 2>/dev/null || return 1
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$branch" "$wt" "$base" "$head" "${TRELLIS_SESSION_ID:-cli}" "$mode" "$reason" \
    > "$root/.claude/session-surgical"
}

# --- the verdict ------------------------------------------------------------
# Echoes "<verdict>\t<reason>"  verdict in: pass | block | advisory
# sg_verdict dir [range [ref [head]]]; explicit identity pins object content.
# Pure function of state. Callers map verdict to their output shape.
sg_verdict() {
  local dir requested="${1:-$PWD}" is_git=1
  if ! dir=$(git -C "$requested" rev-parse --show-toplevel 2>/dev/null); then
    dir="$requested"; is_git=0
  fi
  local root; root=$(_se_repo_root "$dir" 2>/dev/null || printf '%s' "$dir")
  local branch="" protected base diff range resolved="" rc=1 SG_RECEIPT=""
  local ref="${3:-${SG_REQUEST_REF:-}}" head="${4:-${SG_REQUEST_HEAD:-}}"
  local SG_OBJECT_DIR="$dir" SG_OBJECT_HEAD=""
  if [ "$is_git" -eq 1 ]; then
  if [ -n "$ref" ]; then
    branch=${ref#refs/heads/}
    git check-ref-format "refs/heads/$branch" >/dev/null 2>&1 || { sg_result block invalid-ref; return; }
    head=${head:-refs/heads/$branch}
  else
    branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
  fi
  if [ -n "$ref" ] || [ -n "$head" ]; then
    SG_OBJECT_HEAD=$(git -C "$dir" rev-parse --verify "$head^{commit}" 2>/dev/null) || { sg_result block invalid-head; return; }
    head="$SG_OBJECT_HEAD"
  fi
  if resolved=$(_sg_resolve_diff_with_root "$dir" "${2:-${SG_REQUEST_RANGE:-}}" "$ref" "$head" "$root"); then
    rc=0
  else
    rc=$?
  fi
  if [ -n "$resolved" ]; then
    IFS=$'\t' read -r base range SG_RECEIPT <<EOF
$resolved
EOF
  fi
  fi

  local cfg enabled floor ceiling cfgst
  cfg=$(sg_resolve_cfg "$root"); read -r enabled floor ceiling cfgst <<EOF
$cfg
EOF
  case "$cfgst" in
    disabled) sg_result pass disabled; return ;;
    nojq)     sg_result block 'jq required but not found — cannot read mandatory_pipeline policy'; return ;;
    malformed) sg_result block 'mandatory_pipeline config present but malformed — fix trellis.config.json'; return ;;
  esac
  [ "$enabled" = "true" ] || { sg_result pass disabled; return; }
  [ "$is_git" -eq 1 ] || { sg_result block not-a-git-worktree; return; }

  [ -n "$branch" ] && [ "$branch" != "HEAD" ] || { sg_result block detached-or-unknown-branch; return; }
  protected=$(sg_trusted_protected_branch "$dir" "$root") || protected=""
  [ -n "$protected" ] && [ "$branch" = "$protected" ] && { sg_result pass on-protected-branch; return; }
  if [ "$rc" -eq 4 ]; then
    sg_result block 'diff-base resolver missing from trusted runtime; restore the process-gate skill'; return
  fi
  if [ "$rc" -ne 0 ]; then
    sg_result block 'cannot-resolve-diff-base'; return
  fi
  diff=$(sg_compute_gated_diff "$dir" "$range")
  [ "$diff" = "-1" ] && { sg_result block 'cannot-compute-diff-baseline'; return; }
  [ "$diff" -le "$floor" ] && { sg_result pass "sub-floor($diff<=$floor)"; return; }

  # Option 1 (spec 067): only B's range qualifies. An inherited parent triad
  # or a tasks-only tick never substitutes for B's own triad (+interview).
  local tdir
  if ! tdir=$(sg_triad_in_range "$dir" "$range" "$SG_OBJECT_HEAD"); then
    sg_result block 'cannot-discover-spec-triad'; return
  fi
  if [ -n "$tdir" ]; then
    if sg_interview_artifact_ok "$dir" "$root" "$tdir" "$branch" "$SG_OBJECT_HEAD"; then
      sg_result pass "spec-triad($tdir)+interview"; return
    fi
    sg_result block "spec triad $tdir present but the interview artifact is missing (clarify.md / spec-waiver at L1-3, decisions-log entry at L4-5)"; return
  fi
  if sg_valid_marker "$dir" "$root" "$base" "$diff" "$ceiling" "$branch" "$SG_OBJECT_HEAD"; then
    sg_result pass 'surgical-marker'; return
  fi
  sg_result block "$diff gated lines over floor $floor with no in-range spec triad and no valid surgical declaration"
}

# --- Stop-hook pass cache (spec 072 U8) ---------------------------------------
# The Stop early warning re-derives the same verdict on every Stop. A pass is
# cached under a key over everything sg_verdict reads in Stop mode: the
# worktree and canonical root, HEAD, the branch, every ref, the common-dir
# config and reflogs (diff-base reads them), policy and preset files, the
# surgical marker, autonomy session, decisions-log, spec waiver, every
# specs/*/*.md file, the resolver and these scripts, and TRELLIS_ROOT and the
# SG_REQUEST_* inputs. Only passes are cached, and never a surgical-marker pass
# (its validation appends to the audit log), so a hit can only be a pass the
# full path also gives. The pre-push --gate never reads the cache. Requires
# the deps.sh helpers; without them there is no cache.

# sg_stop_cache_file <dir> <harness> — print the per-worktree pass cache path.
sg_stop_cache_file() {
  local sdir
  sdir=$(_se_turn_state_dir "$1") || return 1
  printf '%s/spec-gate/%s.%s' "${sdir%/turn-baseline/*}" "${sdir##*/}" "$2"
}

# sg_stop_cache_key <dir> — print the sha256 key; fails when any input cannot
# be read.
sg_stop_cache_key() {
  local dir root common branch head refs stats resolver f sum key_input list=()
  dir=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
  root=$(_se_repo_root "$dir" 2>/dev/null || printf '%s' "$dir")
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in /*) ;; *) common="$dir/$common" ;; esac
  branch=$(git -C "$dir" symbolic-ref -q --short HEAD 2>/dev/null) || branch=""
  head=$(git -C "$dir" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) || head=unborn
  refs=$(git -C "$dir" for-each-ref --format='%(refname) %(objectname)' 2>/dev/null) || return 1
  resolver=$(sg_find_resolver "$dir" "$root") || resolver=""
  for f in "$common/config" "$common/logs/HEAD" "$common/logs/refs/heads/$branch" \
      "$root/.trellis.json" "$root/.trellis.config.json" "$root/.claude/session-surgical" \
      "$root/.claude/session-autonomy" "$root/.claude/spec-waiver" "$root/decisions-log.md" \
      "${TRELLIS_ROOT:-/nonexistent}/trellis.config.json" \
      "${TRELLIS_ROOT:-/nonexistent}"/core-rules/presets/*.md "$dir"/specs/*/*.md \
      "$resolver" "$_sg_lib_dir/spec-gate-core.sh" "$_sg_lib_dir/deps.sh" \
      "$_sg_lib_dir/autonomy.sh" "$0"; do
    list[${#list[@]}]="s:$f"
  done
  stats=$(_se_stat_lines "${list[@]}") || return 1
  # Preserve the final newline: command substitution would change the key.
  printf -v key_input '%s\n' 'trellis-spec-gate-key v1' "dir $dir" "root $root" "branch $branch" "head $head" \
    "env ${TRELLIS_ROOT:-}|${SG_REQUEST_RANGE:-}|${SG_REQUEST_REF:-}|${SG_REQUEST_HEAD:-}" \
    "$refs" "$stats"
  sum=$(_se_stop_sha256_text "$key_input") || return 1
  sum=${sum%% *}
  [ "${#sum}" -eq 64 ] || return 1
  printf '%s' "$sum"
}

# Human-facing remedy message (shared by all callers).
sg_remedy_message() {
  cat <<'MSG'
Trellis mandatory-pipeline gate: this branch changes more feature code than the
size floor with no spec behind it. Choose one:
  1. Spec it   — run the spec pipeline (clarify -> spec -> plan -> tasks) so a
                 specs/NNN-*/ triad is added on THIS branch. This is the path
                 for a real feature. (Code already written on this branch?
                 commit the WIP first, then author the triad in-place on THIS
                 branch — see the spec skill's "Remediation" note.)
  2. Surgical  — if this is genuinely a small/mechanical change, declare it:
                 /surgical "<why this needs no spec>"   (size-capped).
  3. Emergency — urgent over-cap work: /surgical --emergency "<why>" (logged;
                 obligates a post-facto spec).
MSG
}
