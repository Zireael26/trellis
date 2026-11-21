# Frozen test oracle: spec-gate configuration and verdict at 45b79dbf.
# This is appended only to a private test copy of spec-gate-core.sh. The generic
# block resolver, Git predicates and public wrappers still come from that copy.
# Frozen optimization oracle for unchanged fixtures, not the authority for the
# 1.5.3 merge receipts or historical-range marker semantics. Do not rewrite this
# oracle to mirror those repairs; their expected outcomes have direct tests.
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
  # shellcheck disable=SC2034  # preserve the original read's source field
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

sg_verdict() {
  local dir; dir=$(git -C "${1:-$PWD}" rev-parse --show-toplevel 2>/dev/null) || { printf 'advisory\tnot-a-git-worktree'; return; }
  local root; root=$(_se_repo_root "$dir" 2>/dev/null || printf '%s' "$dir")
  local branch protected base diff range resolved rc SG_RECEIPT=""
  local ref="${3:-${SG_REQUEST_REF:-}}" head="${4:-${SG_REQUEST_HEAD:-}}"
  # shellcheck disable=SC2034  # dynamically scoped to sg_policy_json
  local SG_OBJECT_DIR="$dir" SG_OBJECT_HEAD=""
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
  if resolved=$(sg_resolve_diff "$dir" "${2:-${SG_REQUEST_RANGE:-}}" "$ref" "$head"); then
    rc=0
  else
    rc=$?
  fi
  if [ -n "$resolved" ]; then
    # shellcheck disable=SC2034  # dynamically scoped to sg_result
    IFS=$'\t' read -r base range SG_RECEIPT <<EOF
$resolved
EOF
  fi
  local cfg enabled floor ceiling cfgst
  cfg=$(sg_resolve_cfg "$root"); read -r enabled floor ceiling cfgst <<EOF
$cfg
EOF
  case "$cfgst" in
    disabled) sg_result pass disabled; return ;;
    nojq)     sg_result advisory jq-absent-cannot-evaluate; return ;;
    malformed) sg_result block 'mandatory_pipeline config present but malformed — fix trellis.config.json'; return ;;
  esac
  [ "$enabled" = "true" ] || { sg_result pass disabled; return; }
  [ -n "$branch" ] && [ "$branch" != "HEAD" ] || { sg_result advisory detached-or-unknown-branch; return; }
  protected=$(sg_trusted_protected_branch "$dir" "$root") || protected=""
  [ -n "$protected" ] && [ "$branch" = "$protected" ] && { sg_result pass on-protected-branch; return; }
  if [ "$rc" -eq 2 ]; then
    sg_result advisory 'diff-base resolver missing'; return
  fi
  if [ "$rc" -ne 0 ]; then
    sg_result block 'cannot-resolve-diff-base'; return
  fi
  diff=$(sg_compute_gated_diff "$dir" "$range")
  [ "$diff" = "-1" ] && { sg_result advisory 'cannot-compute-diff-baseline'; return; }
  [ "$diff" -le "$floor" ] && { sg_result pass "sub-floor($diff<=$floor)"; return; }
  local tdir
  if ! tdir=$(sg_triad_in_range "$dir" "$range" "$SG_OBJECT_HEAD"); then
    sg_result advisory 'cannot-discover-spec-triad'; return
  fi
  if [ -n "$tdir" ]; then
    if sg_interview_artifact_ok "$dir" "$root" "$tdir" "$branch" "$SG_OBJECT_HEAD"; then
      sg_result pass "spec-triad($tdir)+interview"; return
    fi
    sg_result block "spec triad $tdir present but the interview artifact is missing (clarify.md / spec-waiver at L1-3)"; return
  fi
  if sg_valid_marker "$dir" "$root" "$base" "$diff" "$ceiling" "$branch" "$SG_OBJECT_HEAD"; then
    sg_result pass 'surgical-marker'; return
  fi
  sg_result block "$diff gated lines over floor $floor with no in-range spec triad and no valid surgical declaration"
}
