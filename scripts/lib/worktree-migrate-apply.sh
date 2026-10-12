#!/usr/bin/env bash
# worktree-migrate-apply.sh — the journaled apply engine, resume and revert (A.5-A.8).
#
# Part of `trellis worktree migrate` (spec 069); sourced by worktree-migrate.sh,
# which defines wm_git, wm_err and the inventory. Function-only.

# ---------------------------------------------------------------------------
# Apply (A.5). One entry at a time, journaled, revalidated just before it is
# touched. A failing entry is put back as it was, journaled `failed`, and
# reported held; the run continues. Attach and detach are never run under a
# timeout (a killed attach leaves a journal), and each attached worktree is
# detached on its own, never as a group (ARG_MAX on groups of 11+ records).
# Order: prune, remove, preserve, move.
#
# Journal: TRELLIS_HOME/state/worktree-migrate/<utc-stamp>.jsonl, 0600,
# append-only, one line per step:
#   {id, action, old, new, step, error, ts, ...step data}
# `id` is the sha256 of the old path, so a resumed run finds its entries.
# ---------------------------------------------------------------------------

wm_state_dir() {
  printf '%s/state/worktree-migrate\n' "${TRELLIS_HOME:-$HOME/.trellis}"
}

wm_id() {
  printf '%s' "$1" | shasum -a 256 | cut -c1-64
}

# wm_journal JOURNAL ACTION OLD NEW STEP [ERROR] [EXTRA-JSON]
wm_journal() {
  local extra="${7:-}"
  [ -n "$extra" ] || extra='{}'
  jq -nc --arg id "$(wm_id "$3")" --arg action "$2" --arg old "$3" --arg new "$4" \
    --arg step "$5" --arg error "${6:-}" --argjson extra "$extra" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{id:$id, action:$action, old:$old, new:(if $new == "" then null else $new end),
      step:$step, error:(if $error == "" then null else $error end), ts:$ts} + $extra' >> "$1"
  # Test seam: stop dead after a named step, as a crash or kill would.
  if [ -n "${WM_FAULT_STEP:-}" ] && [ "$WM_FAULT_STEP" = "$5" ]; then
    exit 99
  fi
}

# wm_attach_cmd VERB PATH [RELEASE] — attach-project.sh for one worktree,
# with no timeout. Output goes to WM_LOG.
wm_attach_cmd() {
  local verb="$1" path="$2" release="${3:-}" home="${TRELLIS_HOME:-$HOME/.trellis}"
  if [ "$verb" = attach ]; then
    bash "$_WM_LIB_DIR/../attach-project.sh" attach --home "$home" --release "$release" "$path" >> "$WM_LOG" 2>&1
  else
    bash "$_WM_LIB_DIR/../attach-project.sh" detach --home "$home" "$path" >> "$WM_LOG" 2>&1
  fi
}

wm_log_tail() {
  tail -n 3 "$WM_LOG" 2>/dev/null | tr '\n' ' '
}

# wm_canonical_move_target TARGET — canonicalize TARGET's parent and require
# it to stay below the sanctioned root. The returned path no longer traverses
# a symlinked parent when git performs the move.
wm_canonical_move_target() {
  local target="$1" root parent name
  root="$(hy_root)" || return 1
  parent="$(_hy_canon "${target%/*}")" || return 1
  if [ "$root" != / ]; then
    case "$parent" in "$root"|"$root"/*) ;; *) return 1 ;; esac
  fi
  name="${target##*/}"
  printf '%s/%s\n' "${parent%/}" "$name"
}

# wm_revalidate WORK ROW — re-plan ROW's entry from fresh state (porcelain,
# owner records, lsof) and print the new row. Returns 1 with the reason on
# stdout when the entry's class changed or it vanished.
wm_revalidate() {
  local work="$1" row="$2" common path class fresh root
  common="$(printf '%s' "$row" | jq -r '.common')"
  path="$(printf '%s' "$row" | jq -r '.path')"
  class="$(printf '%s' "$row" | jq -r '.class')"
  root="$(hy_root)" || { printf 'cannot resolve the worktree root'; return 1; }
  wm_owner_index "$work"
  wm_facts_repo "$work" "$common" "$root" "$path" > "$work/one.jsonl"
  if [ ! -s "$work/one.jsonl" ]; then
    printf 'changed since the plan: no longer listed by git'
    return 1
  fi
  dj_capture_lsof_snapshot "$work/lsof" 30 >/dev/null 2>&1 || true
  fresh="$(wm_classify_row "$(cat "$work/one.jsonl")" "$work/lsof" "$work")"
  if [ "$(printf '%s' "$fresh" | jq -r '.class')" != "$class" ]; then
    printf 'changed since the plan: was %s, now %s (%s)' "$class" \
      "$(printf '%s' "$fresh" | jq -r '.class')" "$(printf '%s' "$fresh" | jq -r '.reasons | join("; ")')"
    return 1
  fi
  printf '%s\n' "$fresh"
}

# wm_apply_prune WORK JOURNAL ROWS COMMON — prune one repository when its
# prunable set is still exactly the planned prune rows.
wm_apply_prune() {
  local work="$1" journal="$2" rows="$3" common="$4" planned live owned linked admin path
  planned="$(jq -r --arg c "$common" 'select(.class == "prune" and .common == $c) | .path' "$rows" | sort)"
  live="$(wm_porcelain "$common" | jq -r 'select(.prunable and (.locked | not) and (.main | not)) | .path' | sort)"
  wm_owner_index "$work"
  owned="$(printf '%s\n' "$planned" | while IFS= read -r path; do
    jq -r --arg p "$path" 'select(.root == $p) | .root' "$work/owners.jsonl"
  done)"
  # Never prune an admin dir that a directory on disk still points at (a
  # worktree moved by hand): the prune would orphan that directory's work.
  linked="$(printf '%s\n' "$planned" | while IFS= read -r path; do
    admin="$(wm_admin_dir "$common" "$path")" && wm_linked_from "$work" "$admin"
  done)"
  if [ "$planned" != "$live" ] || [ -n "$owned" ] || [ -n "$linked" ]; then
    printf '%s\n' "$planned" | while IFS= read -r path; do
      wm_journal "$journal" prune "$path" "" failed "changed since the plan: the prunable set, its owner records or its back-links moved"
    done
    return 1
  fi
  if ! wm_git --git-dir="$common" worktree prune >> "$WM_LOG" 2>&1; then
    printf '%s\n' "$planned" | while IFS= read -r path; do
      wm_journal "$journal" prune "$path" "" failed "git worktree prune failed: $(wm_log_tail)"
    done
    return 1
  fi
  printf '%s\n' "$planned" | while IFS= read -r path; do
    wm_journal "$journal" prune "$path" "" "done"
  done
}

# wm_rollback_move JOURNAL ACTION OLD NEW COMMON RELEASE MOVED ERROR — put an
# entry back where it was (move back, re-attach) and journal it failed.
wm_rollback_move() {
  local journal="$1" action="$2" old="$3" new="$4" common="$5" release="$6" moved="$7" error="$8" undo=""
  if [ "$moved" -eq 1 ]; then
    if wm_git --git-dir="$common" worktree move "$new" "$old" >> "$WM_LOG" 2>&1 &&
       wm_git -C "$old" worktree repair >> "$WM_LOG" 2>&1; then
      undo="moved back"
    else
      undo="MOVE BACK FAILED: the worktree is at $new"
    fi
  fi
  if [ -n "$release" ]; then
    if wm_attach_cmd attach "$old" "$release"; then
      undo="${undo:+$undo, }re-attached at $release"
    else
      undo="${undo:+$undo, }RE-ATTACH FAILED: run trellis attach --release $release $old"
    fi
  fi
  wm_journal "$journal" "$action" "$old" "$new" failed "$error${undo:+ ($undo)}"
}

# wm_deregister JOURNAL ACTION OLD NEW — drop the registry row left naming a
# worktree path migrate emptied (detach keeps the row; spec A6 wants zero
# registered-but-missing). Only `registry deregister`, which removes a dead
# row without --force; a failure is journaled, never fatal.
wm_deregister() {
  local journal="$1" action="$2" old="$3" new="$4" registry fleet
  registry="${TRELLIS_HOME:-$HOME/.trellis}/registry.json"
  [ -f "$registry" ] || return 0
  fleet="$(jq -r --arg r "$old" '.projects | to_entries[]
    | select(any(.value.checkouts[]?.worktrees[]?; .root == $r)) | .key | split("/")[0]' "$registry" 2>/dev/null | head -n 1)"
  [ -n "$fleet" ] || return 0
  if bash "$_WM_LIB_DIR/../registry.sh" deregister --fleet "$fleet" --worktree-root "$old" \
       --home "${TRELLIS_HOME:-$HOME/.trellis}" >> "$WM_LOG" 2>&1; then
    wm_journal "$journal" "$action" "$old" "$new" deregistered
  else
    wm_journal "$journal" "$action" "$old" "$new" deregister-failed \
      "run: trellis registry deregister --fleet $fleet --worktree-root $old"
  fi
}

# wm_move_steps WORK JOURNAL ACTION ROW FROM-STEP — detach, dehydrate, move,
# repair, attach, from FROM-STEP on (`start`, `moved`, `repaired` or
# `attached`; a resumed entry skips what its journal already recorded). Any
# failure rolls back.
wm_move_steps() {
  local work="$1" journal="$2" action="$3" row="$4" from="$5"
  local path target common release rel dir dehydrated="" after moved=0
  path="$(printf '%s' "$row" | jq -r '.path')"
  target="$(printf '%s' "$row" | jq -r '.target')"
  common="$(printf '%s' "$row" | jq -r '.common')"
  # Attached (an owner record) means detach, then attach at the group release.
  release="$(printf '%s' "$row" | jq -r 'if .release then (.group_release // .release) else "" end')"
  after="$(printf '%s' "$row" | jq -c '.after // []')"
  if [ "$from" = start ]; then
    if [ "$action" != revert ]; then
      target="$(wm_canonical_move_target "$target")" || {
        wm_journal "$journal" "$action" "$path" "$target" failed \
          "move target parent is outside the sanctioned worktree root or cannot be canonicalized"
        return 1
      }
      if ! mkdir -p "${target%/*}" ||
         ! target="$(wm_canonical_move_target "$target")"; then
        wm_journal "$journal" "$action" "$path" "$target" failed \
          "move target parent changed or escaped the sanctioned worktree root"
        return 1
      fi
    fi
    if [ -n "$release" ]; then
      if ! wm_attach_cmd detach "$path"; then
        wm_journal "$journal" "$action" "$path" "$target" failed "detach failed: $(wm_log_tail)"
        return 1
      fi
      wm_journal "$journal" "$action" "$path" "$target" detached "" "$(jq -nc --arg r "$release" '{release:$r}')"
    fi
    # B4: a regenerable directory that bakes in absolute paths (.venv) is
    # deleted, never carried or copied; the row names the reinstall.
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      dir="$path/$rel"
      if [ ! -L "$dir" ] && hy_regenerable_kind "$dir" >/dev/null; then
        rm -rf "$dir"
        dehydrated="$dehydrated$rel"$'\n'
      fi
    done <<EOF
$(printf '%s' "$row" | jq -r '.dehydrate[]?')
EOF
    if [ -n "$dehydrated" ]; then
      wm_journal "$journal" "$action" "$path" "$target" dehydrated "" \
        "$(jq -nc --arg d "$dehydrated" '{dehydrated:($d | split("\n") | map(select(. != "")))}')"
    fi
    if [ "$action" = revert ]; then mkdir -p "$(dirname "$target")"; fi
    if ! wm_git --git-dir="$common" worktree move "$path" "$target" >> "$WM_LOG" 2>&1; then
      wm_rollback_move "$journal" "$action" "$path" "$target" "$common" "$release" 0 \
        "git worktree move failed: $(wm_log_tail)"
      return 1
    fi
    moved=1
    wm_journal "$journal" "$action" "$path" "$target" moved
    from=moved
  fi
  moved=1
  if [ "$from" = moved ]; then
    if ! wm_git -C "$target" worktree repair >> "$WM_LOG" 2>&1; then
      wm_rollback_move "$journal" "$action" "$path" "$target" "$common" "$release" "$moved" \
        "git worktree repair failed: $(wm_log_tail)"
      return 1
    fi
    wm_journal "$journal" "$action" "$path" "$target" repaired
  fi
  if [ -n "$release" ] && [ "$from" != attached ]; then
    if ! wm_attach_cmd attach "$target" "$release"; then
      wm_rollback_move "$journal" "$action" "$path" "$target" "$common" "$release" "$moved" \
        "attach at $release failed: $(wm_log_tail)"
      return 1
    fi
    wm_journal "$journal" "$action" "$path" "$target" attached "" "$(jq -nc --arg r "$release" '{release:$r}')"
  fi
  wm_deregister "$journal" "$action" "$path" "$target"
  wm_journal "$journal" "$action" "$path" "$target" "done" "" "$(jq -nc --argjson a "$after" '{after:$a}')"
}

# wm_apply_move WORK JOURNAL ROW — revalidate, then move one worktree.
wm_apply_move() {
  local work="$1" journal="$2" row="$3" fresh path
  path="$(printf '%s' "$row" | jq -r '.path')"
  if ! fresh="$(wm_revalidate "$work" "$row")"; then
    wm_journal "$journal" move "$path" "" failed "$fresh"
    return 1
  fi
  wm_move_steps "$work" "$journal" move "$fresh" start
}

# wm_apply_remove WORK JOURNAL ROW — revalidate (merge, covered head,
# cleanliness, handles), detach if attached, then `git worktree remove`: no
# --force and never rm, so git itself refuses a tree that turned dirty. A
# failure re-attaches the worktree where it is.
wm_apply_remove() {
  local work="$1" journal="$2" row="$3" fresh path common release
  path="$(printf '%s' "$row" | jq -r '.path')"
  if ! fresh="$(wm_revalidate "$work" "$row")"; then
    wm_journal "$journal" remove "$path" "" failed "$fresh"
    return 1
  fi
  common="$(printf '%s' "$fresh" | jq -r '.common')"
  release="$(printf '%s' "$fresh" | jq -r '.release // ""')"
  if [ -n "$release" ]; then
    if ! wm_attach_cmd detach "$path"; then
      wm_journal "$journal" remove "$path" "" failed "detach failed: $(wm_log_tail)"
      return 1
    fi
    wm_journal "$journal" remove "$path" "" detached "" "$(jq -nc --arg r "$release" '{release:$r}')"
  fi
  if ! wm_git --git-dir="$common" worktree remove "$path" >> "$WM_LOG" 2>&1; then
    wm_rollback_move "$journal" remove "$path" "" "$common" "$release" 0 \
      "git worktree remove refused: $(wm_log_tail)"
    return 1
  fi
  wm_journal "$journal" remove "$path" "" removed "" \
    "$(printf '%s' "$fresh" | jq -c '{branch, head}')"
  wm_deregister "$journal" remove "$path" ""
  wm_journal "$journal" remove "$path" "" "done"
}

# wm_resume WORK JOURNAL — finish entries a crashed run left between steps:
# detached or dehydrated (still at the old path), moved, or repaired. Their
# remaining steps run from the journal's own record (release, target), never
# from a fresh plan, which would no longer see them as attached.
wm_resume() {
  local work="$1" journal="$2" id last action old new release common from row failed=0
  WM_LOG="$work/attach.log"
  : >> "$WM_LOG"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    last="$(jq -c --arg id "$id" 'select(.id == $id)' "$journal" | jq -s 'last')"
    case "$(printf '%s' "$last" | jq -r '.step')" in
      detached|dehydrated) from=start ;;
      moved) from=moved ;;
      repaired) from=repaired ;;
      attached) from=attached ;;
      *) continue ;;
    esac
    action="$(printf '%s' "$last" | jq -r '.action')"
    old="$(printf '%s' "$last" | jq -r '.old')"
    new="$(printf '%s' "$last" | jq -r '.new // ""')"
    release="$(jq -r --arg id "$id" 'select(.id == $id and .step == "detached") | .release' "$journal" | tail -n 1)"
    if [ "$from" = start ]; then
      common="$(wm_git -C "$old" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || common=""
    else
      common="$(wm_git -C "$new" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || common=""
    fi
    if [ -z "$common" ]; then
      wm_journal "$journal" "$action" "$old" "$new" failed "resume: the worktree is at neither $old nor $new"
      failed=1
      continue
    fi
    row="$(jq -nc --arg p "$old" --arg t "$new" --arg c "$common" --arg r "$release" \
      '{path:$p, target:$t, common:$c, release:(if $r == "" then null else $r end), dehydrate:[], after:[]}')"
    if [ "$action" = remove ]; then
      wm_rollback_move "$journal" remove "$old" "" "$common" "$release" 0 "interrupted after detach"
      failed=1
    else
      wm_move_steps "$work" "$journal" "$action" "$row" "$from" || failed=1
    fi
  done <<EOF
$(jq -r '.id' "$journal" | awk '!seen[$0]++')
EOF
  [ "$failed" -eq 0 ]
}

# wm_apply_entry WORK JOURNAL ROW — dispatch one non-prune row.
wm_apply_entry() {
  local work="$1" journal="$2" row="$3" class path
  class="$(printf '%s' "$row" | jq -r '.class')"
  path="$(printf '%s' "$row" | jq -r '.path')"
  case "$class" in
    move) wm_apply_move "$work" "$journal" "$row" ;;
    remove) wm_apply_remove "$work" "$journal" "$row" ;;
    preserve) wm_apply_preserve "$work" "$journal" "$row" ;;
    *)
      wm_journal "$journal" "$class" "$path" "" failed "no apply step for class $class in this build"
      return 1 ;;
  esac
}

# wm_revert WORK JOURNAL REVERT-JOURNAL — undo JOURNAL's finished moves, last
# first, with the same detach, move, repair, attach sequence (A.8, spec
# rollback). Removals and prunes cannot be undone and are listed; preserve
# commits and pushed branches stay where they are.
wm_revert() {
  local work="$1" journal="$2" out="$3" id last old new common release after failed=0 row
  WM_LOG="$work/attach.log"
  : >> "$WM_LOG"
  wm_owner_index "$work"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    last="$(jq -c --arg id "$id" 'select(.id == $id)' "$journal" | jq -s 'last')"
    [ "$(printf '%s' "$last" | jq -r '.step')" = "done" ] || continue
    old="$(printf '%s' "$last" | jq -r '.old')"
    case "$(printf '%s' "$last" | jq -r '.action')" in
      remove) printf 'not revertible: removed %s\n' "$old"; continue ;;
      prune) printf 'not revertible: pruned %s (it was already missing)\n' "$old"; continue ;;
    esac
    new="$(printf '%s' "$last" | jq -r '.new')"
    if [ -e "$old" ] || ! common="$(wm_git -C "$new" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
      wm_journal "$out" revert "$new" "$old" failed "cannot revert: $old exists or $new is not a worktree"
      failed=1
      continue
    fi
    release="$(jq -r --arg p "$new" 'select(.root == $p) | .release' "$work/owners.jsonl" | head -n 1)"
    after="$(printf '%s' "$last" | jq -c '.after // []')"
    row="$(jq -nc --arg p "$new" --arg t "$old" --arg c "$common" --arg r "$release" --argjson a "$after" \
      '{path:$p, target:$t, common:$c, release:(if $r == "" then null else $r end), dehydrate:[], after:$a}')"
    wm_move_steps "$work" "$out" revert "$row" start || failed=1
    printf '%s\n' "$(wm_report_entry "$out" "$new")"
  done <<EOF
$(jq -r '.id' "$journal" | awk '!seen[$0]++' | sed '1!G;h;$!d')
EOF
  jq -r 'select(.step == "committed") | "kept: preserve commit \(.sha) on \(.branch) (\(.old))"' "$journal"
  jq -r 'select(.step == "pushed") | "kept: pushed \(.pushed_ref) at \(.sha)"' "$journal"
  [ "$failed" -eq 0 ] || return 4
}

# wm_report_entry JOURNAL PATH — the last journal line for PATH, as a status line.
wm_report_entry() {
  jq -r --arg id "$(wm_id "$2")" 'select(.id == $id)' "$1" | jq -rs '
    last | "\(.step | if . == "done" then "done  " else "HELD  " end) \(.action) \(.old)"
      + (if .new then " -> \(.new)" else "" end)
      + (if .error then "  (\(.error))" else "" end)'
}

# wm_apply WORK ROWS JOURNAL — run every actionable row; 4 when any failed.
wm_apply() {
  local work="$1" rows="$2" journal="$3" failed=0 common row path class moved
  WM_LOG="$work/attach.log"
  : > "$WM_LOG"
  # A worktree moved by hand is re-linked first (its old entry is held), so
  # git lists it where it is; the next plan classifies it there.
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    path="$(printf '%s' "$row" | jq -r '.path')"
    moved="$(printf '%s' "$row" | jq -r '.moved_to')"
    if wm_git -C "$moved" worktree repair >> "$WM_LOG" 2>&1; then
      wm_journal "$journal" relink "$path" "$moved" relinked
    else
      wm_journal "$journal" relink "$path" "$moved" failed "git worktree repair failed: $(wm_log_tail)"
      failed=1
    fi
  done <<EOF
$(jq -c 'select(.moved_to != null)' "$rows")
EOF
  while IFS= read -r common; do
    [ -n "$common" ] || continue
    wm_apply_prune "$work" "$journal" "$rows" "$common" || failed=1
  done <<EOF
$(jq -r 'select(.class == "prune") | .common' "$rows" | sort -u)
EOF
  for class in remove preserve move; do
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      wm_apply_entry "$work" "$journal" "$row" || failed=1
    done <<EOF
$(jq -c --arg c "$class" 'select(.class == $c)' "$rows")
EOF
  done
  jq -r 'select(.class == "prune" or .class == "remove" or .class == "preserve" or .class == "move" or .moved_to != null) | .path' "$rows" |
    while IFS= read -r path; do wm_report_entry "$journal" "$path"; done
  [ "$failed" -eq 0 ] || return 4
}

# wm_lock — one migrate (apply or revert) at a time per TRELLIS_HOME.
# A lock whose recorded pid is gone (a crash) is taken over.
wm_lock() {
  local dir pid
  dir="$(wm_state_dir)"
  mkdir -p "$dir" && chmod 700 "$dir" || return 1
  if ! mkdir "$dir/.lock" 2>/dev/null; then
    pid="$(cat "$dir/.lock/pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      wm_err "another migrate (pid $pid) holds $dir/.lock"
      return 3
    fi
  fi
  printf '%s\n' "$$" > "$dir/.lock/pid"
}

wm_unlock() {
  rm -f "$(wm_state_dir)/.lock/pid"
  rmdir "$(wm_state_dir)/.lock" 2>/dev/null || true
}

# wm_confirm WHAT — 0 on an interactive yes. A non-interactive run needs --yes.
wm_confirm() {
  local answer
  if [ ! -t 0 ]; then
    wm_err "$1 changes worktrees; re-run with --yes when stdin is not a terminal"
    return 2
  fi
  printf '%s? [y/N] ' "$1" >&2
  read -r answer || answer=""
  case "$answer" in y|Y|yes|YES) return 0 ;; esac
  wm_err "not confirmed; nothing changed"
  return 2
}
