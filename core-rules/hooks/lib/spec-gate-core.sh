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

# Built-in fallbacks (documented in core-rules/hooks.md; overridable via config).
SG_DEFAULT_FLOOR=80
SG_DEFAULT_CEILING=400
SG_TEMPLATE_MIN_BYTES=200

# --- config resolution ------------------------------------------------------
# ONE parser, N blocks. Every boolean-gated Trellis config block (spec 006
# `mandatory_pipeline`, spec 028 `gptx`) shares the same resolution order, the
# same unparseable-config rule, and the same enabled-key validation, so those
# live here once instead of being re-implemented per block.
#
# Echoes TAB-separated: "<enabled>\t<status>\t<file>"
#   status: ok | disabled | malformed | nojq
#   file:   the config that declared the block; empty unless status is ok.
#           (Tab-separated because a config path may contain spaces.)
#
# Args: $1 repo root, $2 block name, $3 optional jq filter evaluated against the
# block for block-specific key validation — must output true to pass.
#
# `enabled=false` is returned for every non-ok status. What false MEANS is the
# consumer's call, and the two consumers differ: `mandatory_pipeline` escalates
# `malformed` to a hard block (an opted-in project must not be silently
# disabled by a typo), whereas `gptx` simply stays off. Both are "fail closed"
# in their own direction — for a gate, closed is blocking; for a feature that
# hands out routing instructions, closed is off.
sg_resolve_block() {
  local root="$1" block="$2" extra="${3:-}" f enabled="" present=0 match=""
  if ! command -v jq >/dev/null 2>&1; then printf 'false\tnojq\t\n'; return; fi
  for f in "$root/.trellis.config.json" "$root/trellis.config.json"; do
    [ -f "$f" ] || continue
    # A present but unparseable config, or a present block that is not an
    # object, is malformed => fail closed.
    if ! jq -e . "$f" >/dev/null 2>&1; then printf 'false\tmalformed\t\n'; return; fi
    if jq -e --arg b "$block" 'has($b)' "$f" >/dev/null 2>&1; then
      present=1
      if ! jq -e --arg b "$block" '.[$b] | type == "object"' "$f" >/dev/null 2>&1; then
        printf 'false\tmalformed\t\n'; return
      fi
      if [ -n "$extra" ] && ! jq -e --arg b "$block" ".[\$b] | ( $extra )" "$f" >/dev/null 2>&1; then
        printf 'false\tmalformed\t\n'; return
      fi
      # First config that declares the block wins (project-local over central).
      # NB: do NOT use `// empty` on `enabled` — jq's `//` treats the boolean
      # `false` as absent, which would collapse `enabled:false` to empty.
      enabled=$(jq -r --arg b "$block" '.[$b].enabled' "$f" 2>/dev/null)
      match="$f"
      break
    fi
  done
  [ "$present" -eq 1 ] || { printf 'false\tdisabled\t\n'; return; }
  # Validate enabled true/false (a missing key defaults to disabled).
  case "$enabled" in
    true|false) ;;
    null|'') enabled=false ;;
    *) printf 'false\tmalformed\t\n'; return ;;
  esac
  printf '%s\tok\t%s\n' "$enabled" "$match"
}

# Echoes: "<enabled> <floor> <ceiling> <status>"
#   status: ok | disabled | malformed | nojq
# Reads mandatory_pipeline from project-local then central config at REPO_ROOT.
sg_resolve_cfg() {
  local root="$1" out enabled status file floor="" ceiling=""
  # Threshold keys are optional, but a present value must be a positive JSON
  # integer. Do not let strings, fractions, zero, negatives, booleans, or null
  # silently collapse to a built-in default in an opted-in block.
  out=$(sg_resolve_block "$root" mandatory_pipeline '
        def positive_integer($key):
            if (has($key) | not) then true
            else (.[$key] | if type == "number" then (. > 0 and floor == .) else false end)
            end;
          positive_integer("spec_required_diff_lines")
          and positive_integer("surgical_max_diff_lines")')
  IFS=$'\t' read -r enabled status file <<EOF
$out
EOF
  if [ "$status" != ok ]; then
    echo "false $SG_DEFAULT_FLOOR $SG_DEFAULT_CEILING $status"; return
  fi
  floor=$(jq -r '.mandatory_pipeline.spec_required_diff_lines // empty' "$file" 2>/dev/null)
  ceiling=$(jq -r '.mandatory_pipeline.surgical_max_diff_lines // empty' "$file" 2>/dev/null)
  [ -n "$floor" ] || floor=$SG_DEFAULT_FLOOR
  [ -n "$ceiling" ] || ceiling=$SG_DEFAULT_CEILING
  echo "$enabled $floor $ceiling ok"
}

# --- spec 028: GPTX cross-family routing switch ------------------------------
# Echoes: "<enabled> <status>" — status: ok | disabled | malformed | nojq.
# Every non-ok status resolves to OFF. Off is the safe direction here because it
# can only ever withdraw an instruction to use a lane, never invent one: a
# single-subscription operator who mistypes the block gets a Trellis that reads
# as though GPTX never shipped, which is exactly the intended default.
sg_resolve_gptx() {
  local out enabled status
  out=$(sg_resolve_block "$1" gptx)
  IFS=$'\t' read -r enabled status _ <<EOF
$out
EOF
  case "$status" in
    ok) echo "$enabled ok" ;;
    *)  echo "false $status" ;;
  esac
}

# Convenience predicate for consumers that only need the boolean.
sg_gptx_enabled() {
  local out; out=$(sg_resolve_gptx "$1")
  [ "${out%% *}" = true ]
}

# --- spec 030: GPTX directional family routing -------------------------------
# Echoes: "<default_family> <share_floor> <inline_max> <status>"
#   status: ok | disabled | malformed | nojq
#   inline_max: literal "-" when no orchestrator inline limit is configured.
# A missing routing sub-block under an enabled GPTX switch is a successful (`ok`)
# resolution to the spec-028 fallback. Every non-ok result, and an off master
# switch, returns the same fallback triple: "balanced 0.4 -".
sg_resolve_gptx_routing() {
  local root="$1" out enabled status file values
  # Resolve gptx exactly once. Nested validation rides on the winning gptx block
  # so enabled and routing cannot come from different precedence levels.
  out=$(sg_resolve_block "$root" gptx '
        def positive_integer($key):
            if (has($key) | not) then true
            else (.[$key] | if type == "number" then (. > 0 and floor == .) else false end)
            end;
          if (has("routing") | not) then true
          else (.routing
                | type == "object"
                  and has("default_family")
                  and (.default_family
                       | type == "string"
                         and (. == "gpt" or . == "claude" or . == "balanced"))
                  and has("share_floor")
                  and (.share_floor | type == "number" and . > 0 and . <= 1)
                  and positive_integer("orchestrator_inline_max_lines"))
          end')
  IFS=$'\t' read -r enabled status file <<EOF
$out
EOF
  if [ "$status" != ok ]; then
    echo "balanced 0.4 - $status"; return
  fi
  # This same-file enabled check is the sg_gptx_enabled predicate without a
  # second precedence walk. Routing cannot take effect while the master is off.
  if [ "$enabled" != true ]; then
    echo "balanced 0.4 - disabled"; return
  fi
  # Avoid `//`: jq treats false as absent. Validation already guarantees all
  # present values, so explicit has() checks make the fallback path unambiguous.
  if ! values=$(jq -r '
      if (.gptx | has("routing")) then
        [.gptx.routing.default_family,
         .gptx.routing.share_floor,
         (if (.gptx.routing | has("orchestrator_inline_max_lines"))
          then .gptx.routing.orchestrator_inline_max_lines else "-" end)]
      else ["balanced", 0.4, "-"]
      end
      | map(tostring) | join(" ")' "$file" 2>/dev/null); then
    echo "balanced 0.4 - malformed"; return
  fi
  echo "$values ok"
}

# --- protected branch + diff baseline ---------------------------------------
sg_protected_branch() {
  local root="$1" b=""
  if command -v jq >/dev/null 2>&1; then
    for f in "$root/.trellis.config.json" "$root/trellis.config.json"; do
      [ -f "$f" ] || continue
      b=$(jq -r '.template.branch // empty' "$f" 2>/dev/null)
      [ -n "$b" ] && break
    done
  fi
  printf '%s' "${b:-main}"
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
  case "$1" in
    *_test.*|*.test.*|*.spec.*|*.bats) return 0 ;;
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
    *pnpm-lock.yaml|*package-lock.json|*yarn.lock|*Cargo.lock|*go.sum|*poetry.lock|*Pipfile.lock|*Gemfile.lock|*composer.lock) return 0 ;;
    package.json|*/package.json|trellis.config.json|.trellis.config.json) return 0 ;;
    *.yml|*.yaml) return 0 ;;
    CHANGELOG.md) return 0 ;;
    *) return 1 ;;
  esac
}

# Echoes the net gated diff size (added+deleted, excluded paths removed) for the
# branch vs merge-base. Echoes "-1" if the diff cannot be computed (fail-open).
sg_compute_gated_diff() {
  local dir="$1" base="$2" total=0 adds dels relp
  [ -n "$base" ] || { printf '%s' "-1"; return; }
  while IFS=$'\t' read -r adds dels relp; do
    [ -z "$relp" ] && continue
    [ "$adds" = "-" ] && continue          # binary; excluded from a line count
    sg_is_excluded_path "$relp" && continue
    total=$(( total + adds + dels ))
  done < <(git -C "$dir" diff --numstat "$base"...HEAD 2>/dev/null)
  # Distinguish "clean, zero gated lines" from "git failed": a failed diff
  # produces no rows AND a nonzero rc; guard by re-checking the range resolves.
  if ! git -C "$dir" rev-parse --verify --quiet "$base^{commit}" >/dev/null 2>&1; then
    printf '%s' "-1"; return
  fi
  printf '%s' "$total"
}

# --- spec-triad-in-range (C-CRIT-1) + non-template (C-CRIT-2) ----------------
# Echoes the triad dir (specs/NNN-*/) iff a full spec+plan+tasks triad was
# ADDED OR MODIFIED within this branch's range AND passes the non-template
# check. Merely existing on main does NOT count. Empty on failure.
sg_triad_in_range() {
  local dir="$1" base="$2" changed d
  changed=$(git -C "$dir" diff --name-only "$base"...HEAD 2>/dev/null | grep -E '^specs/[0-9][^/]*/(spec|plan|tasks)\.md$') || true
  [ -n "$changed" ] || { printf ''; return; }
  # Group by triad dir; a dir qualifies only if all three files are in-range.
  for d in $(printf '%s\n' "$changed" | sed -E 's#^(specs/[0-9][^/]*)/.*#\1#' | sort -u); do
    if printf '%s\n' "$changed" | grep -qx "$d/spec.md" \
      && printf '%s\n' "$changed" | grep -qx "$d/plan.md" \
      && printf '%s\n' "$changed" | grep -qx "$d/tasks.md"; then
      if sg_nontemplate_ok "$dir/$d"; then printf '%s' "$d"; return; fi
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
sg_valid_autonomy_level() {
  case "${1:-}" in
    1|2|3|4|5) return 0 ;;
    *) return 1 ;;
  esac
}

sg_autonomy_frontmatter_value() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  awk -v wanted="$key" '
    NR == 1 {
      sub(/\r$/, "")
      if ($0 != "---") exit
      in_frontmatter = 1
      next
    }
    in_frontmatter {
      sub(/\r$/, "")
      if ($0 == "---") exit
      line = $0
      if (line ~ "^[[:space:]]*" wanted ":[[:space:]]*") {
        sub("^[[:space:]]*" wanted ":[[:space:]]*", "", line)
        sub(/[[:space:]]*$/, "", line)
        print line
        exit
      }
    }
  ' "$file" 2>/dev/null
}

sg_autonomy_level() {
  local root="$1" project_cfg="" trellis_root="" fleet_cfg=""
  local lvl=3 project_level="" preset_default="" ceiling=5
  local candidate preset preset_file value session_file

  command -v jq >/dev/null 2>&1 || { printf '3'; return; }

  # Project-local config selects presets and may provide the project override.
  # The dotfile is canonical; the non-dot filename remains a compatibility path.
  for candidate in "$root/.trellis.config.json" "$root/trellis.config.json"; do
    if [ -f "$candidate" ]; then
      project_cfg="$candidate"
      break
    fi
  done

  # Locate the fleet config and canonical preset directory. A deployed hook may
  # receive TRELLIS_ROOT, while project configs carry the same pointer for normal
  # pre-push use. The Trellis control-plane repo can resolve to itself.
  if [ -n "${TRELLIS_ROOT:-}" ]; then
    trellis_root="$TRELLIS_ROOT"
  elif [ -n "$project_cfg" ]; then
    trellis_root=$(jq -r '(.trellis_root // empty) | strings' "$project_cfg" 2>/dev/null || true)
  fi
  if [ -z "$trellis_root" ] && [ -f "$root/trellis.config.json" ]; then
    trellis_root="$root"
  fi
  if [ -n "$trellis_root" ] && [ -f "$trellis_root/trellis.config.json" ]; then
    fleet_cfg="$trellis_root/trellis.config.json"
  fi

  if [ -n "$fleet_cfg" ]; then
    value=$(jq -r '.autonomy_default // empty' "$fleet_cfg" 2>/dev/null || true)
    sg_valid_autonomy_level "$value" && lvl="$value"
  fi

  if [ -n "$project_cfg" ]; then
    value=$(jq -r '.autonomy // empty' "$project_cfg" 2>/dev/null || true)
    sg_valid_autonomy_level "$value" && project_level="$value"

    # Preset order is declaration order: first valid default wins, while the
    # lowest valid ceiling wins across every active preset.
    while IFS= read -r preset; do
      [ -n "$preset" ] || continue
      preset_file="$trellis_root/core-rules/presets/$preset.md"
      [ -f "$preset_file" ] || continue

      value=$(sg_autonomy_frontmatter_value "$preset_file" autonomy_default)
      if [ -z "$preset_default" ] && sg_valid_autonomy_level "$value"; then
        preset_default="$value"
      fi

      value=$(sg_autonomy_frontmatter_value "$preset_file" autonomy_ceiling)
      if sg_valid_autonomy_level "$value" && [ "$value" -lt "$ceiling" ]; then
        ceiling="$value"
      fi
    done < <(jq -r '(.presets // [])[]? | strings' "$project_cfg" 2>/dev/null || true)
  fi

  # Pick phase: fleet -> preset default (only without project override) ->
  # project -> shared cross-harness session marker at the canonical repo root.
  if [ -n "$preset_default" ] && [ -z "$project_level" ]; then
    lvl="$preset_default"
  fi
  [ -n "$project_level" ] && lvl="$project_level"

  session_file="$root/.claude/session-autonomy"
  if [ -f "$session_file" ]; then
    value=$(head -1 "$session_file" 2>/dev/null | tr -d '[:space:]')
    sg_valid_autonomy_level "$value" && lvl="$value"
  fi

  # Clamp phase: presets are additive, so the most restrictive ceiling wins.
  [ "$lvl" -gt "$ceiling" ] && lvl="$ceiling"
  printf '%s' "$lvl"
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
    printf '%s\temergency-override\t%s\tdiff=%s\t%s\n' "$ts" "$branch" "$diff" "$m_reason" >> "$log" 2>/dev/null
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
  local tdir; tdir=$(sg_triad_in_range "$dir" "$base")
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
