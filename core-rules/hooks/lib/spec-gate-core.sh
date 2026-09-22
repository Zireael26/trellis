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
# is read-only. Fail-open on a broken environment (git error) so a hiccup never
# bricks a push; fail-closed only on a PRESENT-but-malformed config (an opted-in
# project must not be silently disabled by a typo — spec §0.6 C-6a).

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

# Echoes TAB-separated: "<value>\t<status>\t<file>"
#   status: ok | disabled | malformed | nojq
# `null` means the field was absent. A status of `ok` with `null` means that a
# valid block was present but did not declare this field, so its caller applies
# the field's built-in fallback.
_sg_resolve_block_field() {
  local root="$1" block="$2" field="$3" extra="${4:-}" f match="" value=""
  if ! command -v jq >/dev/null 2>&1; then printf 'null\tnojq\t\n'; return; fi
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    # A present unparseable or non-object config is malformed => fail closed.
    if ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
      printf 'null\tmalformed\t\n'; return
    fi
    if ! jq -e --arg b "$block" 'has($b)' "$f" >/dev/null 2>&1; then
      continue
    fi
    if ! jq -e --arg b "$block" '.[$b] | type == "object"' "$f" >/dev/null 2>&1; then
      printf 'null\tmalformed\t\n'; return
    fi
    if [ -n "$extra" ] && ! jq -e --arg b "$block" ".[\$b] | ( $extra )" "$f" >/dev/null 2>&1; then
      printf 'null\tmalformed\t\n'; return
    fi
    [ -n "$match" ] || match="$f"
    if jq -e --arg b "$block" --arg k "$field" '.[$b] | has($k)' "$f" >/dev/null 2>&1; then
      value=$(jq -r --arg b "$block" --arg k "$field" '.[$b][$k]' "$f" 2>/dev/null)
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

# Echoes: "<enabled> <floor> <ceiling> <status>"
#   status: ok | disabled | malformed | nojq
# Resolves each mandatory-pipeline field independently from canonical project,
# legacy project, immutable runtime, then its built-in default.
sg_resolve_cfg() {
  local root="$1" out enabled status file floor="" ceiling=""
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
}

# --- protected branch + diff baseline ---------------------------------------
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
    printf 'main'
  fi
}

# Echoes the merge-base SHA against the protected branch, or empty on failure.
# Uses local refs only (no network fetch in a hook): origin/<b> then <b>.
sg_merge_base() {
  local dir="$1" b="$2" base=""
  base=$(git -C "$dir" merge-base HEAD "origin/$b" 2>/dev/null) && { printf '%s' "$base"; return; }
  base=$(git -C "$dir" merge-base HEAD "$b" 2>/dev/null) && { printf '%s' "$base"; return; }
  printf ''
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
    *) return 1 ;;
  esac
}

# Echoes the net gated diff size (added+deleted, excluded paths removed) for the
# branch vs merge-base. Echoes "-1" if the diff cannot be computed (fail-open).
sg_compute_gated_diff() {
  local dir="$1" base="$2" total=0 adds dels relp numstat
  [ -n "$base" ] || { printf '%s' "-1"; return; }
  if ! numstat=$(git -C "$dir" diff --numstat "$base"...HEAD 2>/dev/null); then
    printf '%s' "-1"; return
  fi
  while IFS=$'\t' read -r adds dels relp; do
    [ -z "$relp" ] && continue
    [ "$adds" = "-" ] && continue          # binary; excluded from a line count
    sg_is_excluded_path "$relp" && continue
    total=$(( total + adds + dels ))
  done <<EOF
$numstat
EOF
  printf '%s' "$total"
}

# --- spec-triad-in-range (C-CRIT-1) + non-template (C-CRIT-2) ----------------
# Echoes the triad dir (specs/NNN-*/) iff a full spec+plan+tasks triad was
# ADDED OR MODIFIED within this branch's range AND passes the non-template
# check. Merely existing on main does NOT count. Empty with status 0 means no
# qualifying triad; status 2 means git/grep discovery failed.
sg_triad_in_range() {
  local dir="$1" base="$2" paths changed d f grep_status complete
  if ! paths=$(git -C "$dir" diff --name-only "$base"...HEAD 2>/dev/null); then
    return 2
  fi
  if changed=$(printf '%s\n' "$paths" | grep -E '^specs/[0-9][^/]*/(spec|plan|tasks)\.md$' 2>/dev/null); then
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
    if [ "$complete" = true ] && sg_nontemplate_ok "$dir/$d"; then
      printf '%s' "$d"; return
    fi
  done
  printf ''
}

# Each triad file must exceed a min size and carry no unfilled placeholder token.
sg_nontemplate_ok() {
  local tdir="$1" f bytes
  for f in spec.md plan.md tasks.md; do
    [ -f "$tdir/$f" ] || return 1
    bytes=$(wc -c < "$tdir/$f" 2>/dev/null | tr -d ' ')
    [ "${bytes:-0}" -ge "$SG_TEMPLATE_MIN_BYTES" ] || return 1
    grep -qE '<NNN>|<slug>|TODO-SPEC|SCAFFOLD-PLACEHOLDER' "$tdir/$f" && return 1
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
  _se_resolve_autonomy "$root"
  printf '%s' "${AUTONOMY_LEVEL:-3}"
}

# L1-3: real interview => clarify.md in the triad OR an explicit spec-waiver.
# L4-5: agent self-answers => a decisions-log entry for this branch.
sg_interview_artifact_ok() {
  local dir="$1" root="$2" tdir="$3" branch="$4" lvl
  lvl=$(sg_autonomy_level "$root")
  if [ "$lvl" -ge 4 ]; then
    [ -f "$root/decisions-log.md" ] && grep -qF "$branch" "$root/decisions-log.md" && return 0
    return 1
  fi
  [ -f "$dir/$tdir/clarify.md" ] && return 0
  [ -f "$root/.claude/spec-waiver" ] && return 0
  return 1
}

# --- surgical / emergency marker (C-3a bind + expiry, C-6c emergency) --------
# Marker file lines: branch / worktree_root / merge_base / head / session / mode / reason
# mode: surgical | emergency. Honored only on full bind match. Emits audit lines.
sg_valid_marker() {
  local dir="$1" root="$2" base="$3" diff="$4" ceiling="$5" branch="$6"
  local marker="$root/.claude/session-surgical" log="$root/.claude/spec-gate-audit.log"
  [ -f "$marker" ] || return 1
  local m_branch m_wt m_base m_mode m_reason wt
  m_branch=$(sed -n '1p' "$marker"); m_wt=$(sed -n '2p' "$marker")
  m_base=$(sed -n '3p' "$marker");   m_mode=$(sed -n '6p' "$marker")
  m_reason=$(sed -n '7p' "$marker")
  wt=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)
  # Full-bind match: same branch, same worktree, same merge-base. Else stale.
  [ "$m_branch" = "$branch" ] && [ "$m_wt" = "$wt" ] && [ "$m_base" = "$base" ] || return 1
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
  base=$(sg_merge_base "$dir" "$(sg_protected_branch "$root")")
  head=$(git -C "$dir" rev-parse HEAD 2>/dev/null)
  mkdir -p "$root/.claude" 2>/dev/null || return 1
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$branch" "$wt" "$base" "$head" "${TRELLIS_SESSION_ID:-cli}" "$mode" "$reason" \
    > "$root/.claude/session-surgical"
}

# --- the verdict ------------------------------------------------------------
# Echoes "<verdict>\t<reason>"  verdict in: pass | block | advisory
# Pure function of state. Callers map verdict to their output shape.
sg_verdict() {
  local dir; dir=$(git -C "${1:-$PWD}" rev-parse --show-toplevel 2>/dev/null) || { printf 'advisory\tnot-a-git-worktree'; return; }
  local root; root=$(_se_repo_root "$dir" 2>/dev/null || printf '%s' "$dir")
  local cfg enabled floor ceiling cfgst
  cfg=$(sg_resolve_cfg "$root"); read -r enabled floor ceiling cfgst <<EOF
$cfg
EOF
  case "$cfgst" in
    disabled) printf 'pass\tdisabled'; return ;;
    nojq)     printf 'advisory\tjq-absent-cannot-evaluate'; return ;;
    malformed) printf 'block\tmandatory_pipeline config present but malformed — fix trellis.config.json'; return ;;
  esac
  [ "$enabled" = "true" ] || { printf 'pass\tdisabled'; return; }

  local branch protected base diff
  branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
  [ -n "$branch" ] && [ "$branch" != "HEAD" ] || { printf 'advisory\tdetached-or-unknown-branch'; return; }
  protected=$(sg_protected_branch "$root")
  [ "$branch" = "$protected" ] && { printf 'pass\ton-protected-branch'; return; }
  base=$(sg_merge_base "$dir" "$protected")
  diff=$(sg_compute_gated_diff "$dir" "$base")
  [ "$diff" = "-1" ] && { printf 'advisory\tcannot-compute-diff-baseline'; return; }
  [ "$diff" -le "$floor" ] && { printf 'pass\tsub-floor(%s<=%s)' "$diff" "$floor"; return; }

  # Over the floor: need triad-in-range (+interview) OR a valid marker.
  local tdir
  if ! tdir=$(sg_triad_in_range "$dir" "$base"); then
    printf 'advisory\tcannot-discover-spec-triad'; return
  fi
  if [ -n "$tdir" ]; then
    if sg_interview_artifact_ok "$dir" "$root" "$tdir" "$branch"; then
      printf 'pass\tspec-triad(%s)+interview' "$tdir"; return
    fi
    printf 'block\tspec triad %s present but the interview artifact is missing (clarify.md / spec-waiver at L1-3, decisions-log entry at L4-5)' "$tdir"; return
  fi
  if sg_valid_marker "$dir" "$root" "$base" "$diff" "$ceiling" "$branch"; then
    printf 'pass\tsurgical-marker'; return
  fi
  printf 'block\t%s gated lines over floor %s with no in-range spec triad and no valid surgical declaration' "$diff" "$floor"
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
