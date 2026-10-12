#!/usr/bin/env bash
# worktree-migrate-preserve.sh — the preserve step: no work is lost before a move.
#
# Part of `trellis worktree migrate` (spec 069); sourced by worktree-migrate.sh,
# which defines wm_git, wm_err and the inventory. Function-only.

# wm_apply_preserve WORK JOURNAL ROW — NO WORK IS LOST: before a worktree
# with uncommitted, untracked or non-regenerable ignored content is moved,
#   1. copy its non-regenerable ignored files into the journal's archive
#      (0700), never into a commit;
#   2. commit tracked and untracked changes on its branch, or on
#      preserve/<dir> when it is detached or on the default branch, with the
#      repository's hooks; a refused commit restores the index and HEAD and
#      holds the entry;
#   3. push that branch when origin's owner is in worktrees.push_owners, and
#      journal the pushed ref only once origin's ref equals the local sha;
#   4. move it like any other worktree. A preserved worktree is never
#      removed.
# wm_secret_files WT — staged files flagged by process-gate's path rules or
# added-line patterns. PATTERNS comes from check-secrets.sh so the two do not
# drift; scan errors fail closed and the caller commits nothing.
wm_secret_files() {
  local wt="$1" file added pattern tmp found scan_rc grep_rc
  local PATTERNS=()
  eval "$(sed -n '/^PATTERNS=(/,/^)$/p' "$_WM_LIB_DIR/../../core-rules/skills/process-gate/scripts/check-secrets.sh" 2>/dev/null)"
  [ "${#PATTERNS[@]}" -gt 0 ] || return 1
  # Preserve-only content rules for credential JSON the process gate does not flag.
  PATTERNS+=(
    "Google OAuth client secret|client_secret"
    "Private key field|private_key"
    "Service account type|\"type\"[[:space:]]*:[[:space:]]*\"service_account\""
  )
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/wm-secret-scan.XXXXXX")" || return 1
  if ! wm_git -C "$wt" diff --cached --name-only -z > "$tmp/files"; then
    rm -rf "$tmp"
    return 1
  fi
  scan_rc=0
  while IFS= read -r -d '' file; do
    if ! wm_git -C "$wt" diff --cached --no-color --unified=0 -- "$file" > "$tmp/diff"; then
      scan_rc=1
      break
    fi
    found=0
    case "$file" in
      *.env|*.env.*|*.pem|*.key|*.keystore|*.p12|*.pfx|*/secrets/*|*credentials*.json|*service[-_]account*.json|*id_rsa*|*id_ed25519*|*id_ecdsa*|*id_dsa*|*.ppk)
        case "$file" in
          *.example|*.sample|*.template) ;;
          *) found=1 ;;
        esac ;;
    esac
    if [ "$found" -eq 0 ]; then
      if ! added="$(sed -n '/^+++ /d; s/^+//p' "$tmp/diff")"; then
        scan_rc=1
        break
      fi
      for pattern in "${PATTERNS[@]}"; do
        if printf '%s\n' "$added" | grep -Eq -- "${pattern#*|}"; then
          found=1
          break
        else
          grep_rc=$?
          if [ "$grep_rc" -ne 1 ]; then
            scan_rc=1
            break
          fi
        fi
      done
    fi
    [ "$scan_rc" -eq 0 ] || break
    [ "$found" -eq 0 ] || printf '%s\n' "$file"
  done < "$tmp/files"
  rm -rf "$tmp" || scan_rc=1
  return "$scan_rc"
}

wm_apply_preserve() {
  local work="$1" journal="$2" row="$3" fresh path branch head pb push archive rel
  local work_count git_dir created=0 sha remote ok=1 kept target push_ref secrets
  # Put the index and HEAD back as they were before a preserve that stops.
  _wm_preserve_undo() {
    [ ! -f "$work/index.backup" ] || cp -p "$work/index.backup" "$git_dir/index"
    if [ "$created" -eq 1 ]; then
      if [ -n "$branch" ]; then
        wm_git -C "$path" symbolic-ref HEAD "refs/heads/$branch"
      else
        wm_git -C "$path" update-ref --no-deref HEAD "$head"
      fi
      wm_git -C "$path" branch -q -D "$pb" >> "$WM_LOG" 2>&1 || true
    fi
  }
  path="$(printf '%s' "$row" | jq -r '.path')"
  if ! fresh="$(wm_revalidate "$work" "$row")"; then
    wm_journal "$journal" preserve "$path" "" failed "$fresh"
    return 1
  fi
  branch="$(printf '%s' "$fresh" | jq -r '.branch // ""')"
  head="$(printf '%s' "$fresh" | jq -r '.head')"
  pb="$(printf '%s' "$fresh" | jq -r '.preserve_branch')"
  push="$(printf '%s' "$fresh" | jq -r '.push')"
  push_ref="$(printf '%s' "$fresh" | jq -r '.push_ref // ""')"
  archive="${journal%.jsonl}.archive/$(wm_id "$path" | cut -c1-16)"
  work_count="$(printf '%s' "$fresh" | jq -r '.modified + .untracked')"
  kept="$(printf '%s' "$fresh" | jq -r '.ignored_kept[]')"

  if [ -n "$kept" ]; then
    mkdir -p "$archive" && chmod 700 "${journal%.jsonl}.archive" "$archive" || ok=0
    while IFS= read -r rel; do
      [ "$ok" -eq 1 ] || break
      mkdir -p "$archive/$(dirname "$rel")" &&
        cp -p "$path/$rel" "$archive/$rel" && cmp -s "$path/$rel" "$archive/$rel" || ok=0
    done <<EOF
$kept
EOF
    if [ "$ok" -ne 1 ]; then
      wm_journal "$journal" preserve "$path" "" failed "archive copy of ignored files failed"
      return 1
    fi
    wm_journal "$journal" preserve "$path" "" archived "" \
      "$(printf '%s' "$fresh" | jq -c --arg a "$archive" '{archive:$a, files:.ignored_kept}')"
  fi

  if [ "$work_count" -gt 0 ]; then
    git_dir="$(wm_git -C "$path" rev-parse --absolute-git-dir)"
    [ ! -f "$git_dir/index" ] || cp -p "$git_dir/index" "$work/index.backup"
    if [ "$pb" != "$branch" ]; then
      if ! wm_git -C "$path" checkout -q -b "$pb" >> "$WM_LOG" 2>&1; then
        wm_journal "$journal" preserve "$path" "" failed "could not create $pb: $(wm_log_tail)"
        return 1
      fi
      created=1
    fi
    if ! wm_git -C "$path" add -A >> "$WM_LOG" 2>&1 || ! secrets="$(wm_secret_files "$path")"; then
      _wm_preserve_undo
      wm_journal "$journal" preserve "$path" "" failed "staging or the secrets scan failed: $(wm_log_tail)"
      return 1
    fi
    # A staged file the process gate's secrets scan flags is copied to the
    # archive and left uncommitted (it still moves with the tree).
    if [ -n "$secrets" ]; then
      mkdir -p "$archive" && chmod 700 "${journal%.jsonl}.archive" "$archive" || ok=0
      while IFS= read -r rel; do
        [ "$ok" -eq 1 ] || break
        mkdir -p "$archive/$(dirname "$rel")" && cp -p "$path/$rel" "$archive/$rel" &&
          cmp -s "$path/$rel" "$archive/$rel" && wm_git -C "$path" reset -q -- "$rel" || ok=0
      done <<EOF
$secrets
EOF
      if [ "$ok" -ne 1 ]; then
        _wm_preserve_undo
        wm_journal "$journal" preserve "$path" "" failed "could not withhold flagged files"
        return 1
      fi
      wm_journal "$journal" preserve "$path" "" secrets-withheld "" \
        "$(jq -nc --arg a "$archive" --arg f "$secrets" '{archive:$a, files:($f | split("\n") | map(select(. != "")))}')"
    fi
    # The commit-msg hook fleet-wide takes Conventional Commit types only, so
    # the owner's "wip: preserve ..." subject rides behind `chore:`.
    if wm_git -C "$path" diff --cached --quiet; then
      _wm_preserve_undo
      wm_journal "$journal" preserve "$path" "" nothing-to-commit
    elif wm_git -C "$path" commit -q -m "chore: wip: preserve $path before worktree migration" >> "$WM_LOG" 2>&1; then
      sha="$(wm_git -C "$path" rev-parse HEAD)"
      wm_journal "$journal" preserve "$path" "" committed "" \
        "$(jq -nc --arg b "$pb" --arg s "$sha" --arg base "$head" '{branch:$b, sha:$s, base:$base}')"
      # A new preserve/<dir> branch moves to that branch's convention path.
      if [ "$created" -eq 1 ] &&
         target="$(hy_convention_path "$(printf '%s' "$fresh" | jq -r '.repo')" "$pb")" && [ ! -e "$target" ]; then
        fresh="$(printf '%s' "$fresh" | jq -c --arg t "$target" '.target = $t')"
      fi
    else
      _wm_preserve_undo
      wm_journal "$journal" preserve "$path" "" failed "preserve commit refused: $(wm_log_tail)"
      return 1
    fi
  fi

  # Pushes go to a preserve/ ref only, never over a branch others may use.
  if [ "$push" = true ] && sha="$(wm_git -C "$path" rev-parse -q --verify "refs/heads/$pb")"; then
    remote=""
    if wm_git -C "$path" push -q origin "refs/heads/$pb:refs/heads/$push_ref" >> "$WM_LOG" 2>&1; then
      remote="$(wm_git -C "$path" ls-remote origin "refs/heads/$push_ref" 2>/dev/null | cut -f 1)"
    fi
    if [ "$remote" = "$sha" ]; then
      wm_journal "$journal" preserve "$path" "" pushed "" \
        "$(jq -nc --arg r "origin/$push_ref" --arg s "$sha" '{pushed_ref:$r, sha:$s}')"
    else
      wm_journal "$journal" preserve "$path" "" push-failed "push of $pb to $push_ref not verified on origin: $(wm_log_tail)"
    fi
  elif [ "$push" = true ]; then
    wm_journal "$journal" preserve "$path" "" local-only "nothing was committed on $pb"
  else
    wm_journal "$journal" preserve "$path" "" local-only "origin owner not in worktrees.push_owners"
  fi

  wm_move_steps "$work" "$journal" preserve "$fresh" start
}
