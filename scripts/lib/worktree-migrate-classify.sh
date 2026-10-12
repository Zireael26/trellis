#!/usr/bin/env bash
# worktree-migrate-classify.sh — the risk-first classifier (A.4).
#
# Part of `trellis worktree migrate` (spec 069); sourced by worktree-migrate.sh,
# which defines wm_git, wm_err and the inventory. Function-only.

# ---------------------------------------------------------------------------
# Classification (A.4). Risk-first: every hold rule is evaluated before a row
# may be remove, and remove needs every one of the A3 conditions plus a
# covered head. Classes:
#   prune     registered but missing, unlocked, no owner record names it
#   remove    clean, only regenerable ignored content, merged PR (gh only),
#             head covered (it is the merged PR head or on origin's default),
#             idle >= 1 day, no live handle
#   preserve  outside the sanctioned roots with uncommitted, untracked or
#             non-regenerable ignored work: commit and push it, then move
#   move      any other healthy worktree outside the sanctioned roots
#   keep      already in a sanctioned root
#   hold      anything uncertain; the reasons say why
# ---------------------------------------------------------------------------

WM_IDLE_SECONDS=86400

# wm_extend_path — the launcher hands migrate the control PATH and carries the
# operator's PATH in TRELLIS_ATTACH_CALLER_PATH. Append its absolute entries
# so gh (merge checks) and the hooks a preserve commit runs can be found,
# while the control directories still win.
wm_extend_path() {
  local entry rest="${TRELLIS_ATTACH_CALLER_PATH:-}"
  [ -n "$rest" ] || return 0
  while [ -n "$rest" ]; do
    entry="${rest%%:*}"
    case "$rest" in *:*) rest="${rest#*:}" ;; *) rest="" ;; esac
    case "$entry" in /*) ;; *) continue ;; esac
    case ":$PATH:" in *":$entry:"*) ;; *) PATH="$PATH:$entry" ;; esac
  done
  export PATH
}

# _wm_under PATH ROOT — PATH is ROOT or below it (canonical spellings).
_wm_under() {
  local path root
  path="$(_hy_canon "$1")" || return 1
  root="$(_hy_canon "$2")" || return 1
  case "$path" in "$root"|"$root"/*) return 0 ;; esac
  return 1
}

# wm_foreign_root PATH — print the tool whose managed root holds PATH.
wm_foreign_root() {
  if _wm_under "$1" "$HOME/.cursor/worktrees"; then printf 'Cursor\n'; return 0; fi
  if _wm_under "$1" "${CODEX_HOME:-$HOME/.codex}/worktrees"; then printf 'Codex\n'; return 0; fi
  return 1
}

# wm_ignored WT KEPT REGEN [OWNER] — split WT's ignored content: regenerable
# directories (hy_regenerable_kind) to REGEN, every other regular file to
# KEPT, both relative to WT. Symlinks hold no data and are skipped, which
# also skips the Trellis attachment links. Files the attachment owner record
# OWNER lists as its own artifacts (rendered settings, primers) are not kept:
# detach removes them and attach renders them again.
wm_ignored() {
  local wt="$1" kept="$2" regen="$3" owner="${4:-}" entry abs
  : > "$kept"; : > "$regen"
  wm_git -C "$wt" ls-files -z --others --ignored --exclude-standard --directory 2>/dev/null |
    tr '\0' '\n' > "$kept.list" || return 1
  # ls-files can list a directory and entries inside it; nothing below a
  # regenerable directory is examined, and the kept list is de-duplicated.
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    entry="${entry%/}"
    abs="$wt/$entry"
    if awk -v e="$entry" 'index(e, $0 "/") == 1 { found = 1 } END { exit !found }' "$regen"; then
      continue
    elif [ -L "$abs" ]; then
      continue
    elif [ -d "$abs" ]; then
      if hy_regenerable_kind "$abs" >/dev/null; then
        printf '%s\n' "$entry" >> "$regen"
        continue
      fi
      (cd "$wt" && find "./$entry" \( -type d \( -name node_modules -o -name .venv -o -name __pycache__ \
        -o -name .next -o -name .turbo -o -name .mypy_cache -o -name .pytest_cache -o -name .ruff_cache \) -prune \) \
        -o -type f -print | sed 's|^\./||') >> "$kept"
    elif [ -f "$abs" ]; then
      printf '%s\n' "$entry" >> "$kept"
    fi
  done < "$kept.list"
  rm -f "$kept.list"
  sort -u "$kept" > "$kept.sorted" && mv "$kept.sorted" "$kept"
  if [ -n "$owner" ] && [ -f "$owner" ]; then
    jq -r '.artifacts[]? | select(.kind == "file" or .kind == "symlink") | .path' "$owner" \
      > "$kept.owned" 2>/dev/null || : > "$kept.owned"
    awk 'NR == FNR { owned[$0] = 1; next } !($0 in owned)' "$kept.owned" "$kept" > "$kept.filtered"
    mv "$kept.filtered" "$kept"
    rm -f "$kept.owned"
  fi
}

# wm_nested_repo WT — the first directory below WT (relative) that holds its
# own `.git`: an initialised submodule or an embedded repository. Regenerable
# dependency trees are not searched.
wm_nested_repo() {
  (cd "$1" 2>/dev/null && find . -mindepth 2 \( -name node_modules -o -name .venv \) -prune \
    -o -name .git -print -prune 2>/dev/null) | sed -n '1{s|^\./||;s|/\.git$||;p;}'
}

# wm_origin_owner REPO — the owner segment of origin's URL
# (git@host:owner/repo.git, https://host/owner/repo, /path/owner/repo.git).
wm_origin_owner() {
  local url
  url="$(wm_git -C "$1" remote get-url origin 2>/dev/null)" || return 1
  url="${url%/}"; url="${url%.git}"
  url="$(printf '%s' "$url" | tr ':' '/')"
  url="${url%/*}"
  printf '%s\n' "${url##*/}"
}

# wm_push_allowed REPO — 0 when origin's owner (or owner/repo) is listed in
# worktrees.push_owners. Anything else preserves locally only.
wm_push_allowed() {
  local owner allowed url repo_name
  owner="$(wm_origin_owner "$1")" || return 1
  [ -n "$owner" ] || return 1
  url="$(wm_git -C "$1" remote get-url origin 2>/dev/null)"; url="${url%/}"; url="${url%.git}"
  repo_name="${url##*/}"
  while IFS= read -r allowed; do
    [ -n "$allowed" ] || continue
    allowed="$(printf '%s' "$allowed" | tr '[:upper:]' '[:lower:]')"
    case "$allowed" in
      "$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')") return 0 ;;
      "$(printf '%s/%s' "$owner" "$repo_name" | tr '[:upper:]' '[:lower:]')") return 0 ;;
    esac
  done <<EOF
$(wm_config_list push_owners)
EOF
  return 1
}

# wm_default_branch REPO — origin's HEAD branch, else main or master.
wm_default_branch() {
  local ref
  if ref="$(wm_git -C "$1" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"; then
    printf '%s\n' "${ref#origin/}"
  elif wm_git -C "$1" show-ref --verify --quiet refs/heads/main; then
    printf 'main\n'
  else
    printf 'master\n'
  fi
}

# wm_preserve_branch REPO WT BRANCH HEAD — the branch a preserve commit lands
# on: BRANCH itself, unless it is empty (detached) or the default branch;
# then preserve/<worktree-dir> (with -<shortsha> if that name is taken).
wm_preserve_branch() {
  local repo="$1" wt="$2" branch="$3" head="$4" default name
  default="$(wm_default_branch "$repo")"
  case "$branch" in
    ''|main|master|"$default") ;;
    *) printf '%s\n' "$branch"; return 0 ;;
  esac
  name="preserve/$(hy_slug "${wt##*/}")" || return 1
  if wm_git -C "$repo" show-ref --verify --quiet "refs/heads/$name"; then
    name="$name-$(printf '%s' "$head" | cut -c1-7)"
  fi
  printf '%s\n' "$name"
}

# wm_head_covered REPO BRANCH HEAD — 0 when HEAD's commits are all in a merge:
# a merged pull request's head is exactly HEAD (GitHub keeps PR heads after
# the branch is deleted, so squash merges pass), or HEAD is already contained
# in origin's default branch. A branch pushed with commits after its PR merged
# fails both: removing it would lose those commits from every working tree.
wm_head_covered() {
  local repo="$1" branch="$2" head="$3"
  if command -v gh >/dev/null 2>&1 &&
     (cd "$repo" && gh pr list --head "$branch" --state merged --json headRefOid 2>/dev/null) |
       jq -r '.[]?.headRefOid' 2>/dev/null | grep -Fxq "$head"; then
    return 0
  fi
  wm_git -C "$repo" merge-base --is-ancestor "$head" "refs/remotes/origin/$(wm_default_branch "$repo")" 2>/dev/null
}

# wm_detach_journal — the first attachment detach journal on the machine. A
# detach resumes any stale detach journal (memory: stale detach journals), so
# one blocks every migrate step that would detach.
wm_detach_journal() {
  local file
  for file in "${TRELLIS_HOME:-$HOME/.trellis}"/state/attachment-journals/detach-*.json; do
    [ -f "$file" ] && { printf '%s\n' "$file"; return 0; }
  done
  return 1
}

# wm_classify_row ROW SNAPSHOT WORK — ROW (one fact object) with class,
# reasons, target, dehydrate, after and the work facts filled in.
wm_classify_row() {
  local row="$1" snapshot="$2" work="$3"
  local path repo branch head missing orphan locked owner_count project_rc
  local class="" holds="" notes="" target="" trc=0 in_use status_out modified=0 untracked=0
  local kept_count=0 last now idle=0 unpushed=false merged=unchecked mrc tool
  local preserve_branch="" push=false push_ref="" journal moved_to nested

  path="$(printf '%s' "$row" | jq -r '.path')"
  repo="$(printf '%s' "$row" | jq -r '.repo // ""')"
  branch="$(printf '%s' "$row" | jq -r '.branch // ""')"
  head="$(printf '%s' "$row" | jq -r '.head // ""')"
  missing="$(printf '%s' "$row" | jq -r '.missing')"
  orphan="$(printf '%s' "$row" | jq -r '.orphan')"
  locked="$(printf '%s' "$row" | jq -r '.locked')"
  owner_count="$(printf '%s' "$row" | jq -r '.owner_count')"
  project_rc="$(printf '%s' "$row" | jq -r '.project_rc')"
  : > "$work/kept"; : > "$work/regen"

  if [ "$orphan" = true ]; then
    class=hold
    holds="orphan: its gitdir is gone; repair with git worktree repair from the main checkout or recover it by hand"
  elif [ "$missing" = true ]; then
    moved_to="$(printf '%s' "$row" | jq -r '.moved_to // ""')"
    if [ -n "$moved_to" ]; then
      class=hold
      holds="moved by hand to $moved_to; --apply re-links it (git worktree repair) and the next migrate plans it there"
    elif [ "$locked" = true ]; then
      class=hold; holds="locked"
    elif [ "$owner_count" -gt 0 ]; then
      class=hold
      holds="owner record names the missing path; archive it by hand (docs/UPGRADING.md, orphan owner records) before pruning"
    else
      class=prune; notes="registered but missing on disk"
    fi
  else
    [ "$locked" != true ] || holds="${holds}locked"$'\n'
    if tool="$(wm_foreign_root "$path")"; then
      holds="${holds}inside $tool's managed worktree root"$'\n'
    fi
    if in_use="$(dj_worktree_in_use "$path" "$snapshot")"; then
      holds="${holds}${in_use}"$'\n'
    fi
    [ "$owner_count" -le 1 ] || holds="${holds}ambiguous owner record ($owner_count records)"$'\n'
    case "$project_rc" in
      0) ;;
      3) holds="${holds}ambiguous project id (two registry projects claim the repository)"$'\n' ;;
      4) holds="${holds}local registry is unreadable"$'\n' ;;
      *) holds="${holds}unknown project"$'\n' ;;
    esac
    if status_out="$(wm_git -C "$path" status --porcelain=v1 --untracked-files=all 2>/dev/null)"; then
      untracked="$(printf '%s\n' "$status_out" | grep -c '^??' || true)"
      modified="$(printf '%s\n' "$status_out" | grep -c '^[^?]' || true)"
    else
      holds="${holds}command error: git status failed"$'\n'
    fi
    # git refuses to move or remove a worktree holding a submodule, and a
    # preserve commit would record an embedded repository as a bare gitlink.
    nested="$(wm_nested_repo "$path")"
    [ -z "$nested" ] ||
      holds="${holds}contains a nested git repository or submodule at $nested: git cannot move or remove it; move that repository out by hand"$'\n'
    wm_ignored "$path" "$work/kept" "$work/regen" "$(printf '%s' "$row" | jq -r '.owner_record // ""')" ||
      holds="${holds}command error: git ls-files failed"$'\n'
    kept_count="$(grep -c . "$work/kept" || true)"
    if last="$(hy_last_git_activity "$path")"; then
      now="$(date +%s)"
      [ $((now - last)) -lt "$WM_IDLE_SECONDS" ] || idle=1
    fi
    if [ -z "$branch" ] || ! wm_git -C "$path" rev-parse -q --verify '@{u}' >/dev/null 2>&1 ||
       [ "$(wm_git -C "$path" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 1)" != 0 ]; then
      unpushed=true
    fi

    if [ "$modified" -eq 0 ] && [ "$untracked" -eq 0 ] && [ "$kept_count" -eq 0 ] &&
       [ -n "$branch" ] && [ -z "$holds" ]; then
      mrc=0; dj_branch_merged "$repo" "$branch" || mrc=$?
      case "$mrc" in
        0) merged=merged ;;
        1) merged=unmerged ;;
        *) merged=unverified ;;
      esac
      if [ "$merged" = merged ] && [ "$idle" -eq 1 ] && wm_head_covered "$repo" "$branch" "$head"; then
        class=remove; notes="merged, clean, regenerable-only, idle, head is the merged PR head"
      elif [ "$merged" = merged ] && [ "$idle" -eq 0 ]; then
        notes="${notes}merged but active within a day"$'\n'
      elif [ "$merged" = merged ]; then
        notes="${notes}merged, but the local head is neither the merged PR head nor on the default branch"$'\n'
      fi
    fi
    if [ -z "$class" ]; then
      if hy_is_sanctioned "$path"; then
        class=keep; notes="${notes}at a sanctioned root"$'\n'
      elif [ "$modified" -gt 0 ] || [ "$untracked" -gt 0 ] || [ "$kept_count" -gt 0 ]; then
        class=preserve
        notes="${notes}$modified modified, $untracked untracked, $kept_count ignored file(s) to archive; then move"$'\n'
        preserve_branch="$(wm_preserve_branch "$repo" "$path" "$branch" "$head")" ||
          holds="${holds}command error: no preserve branch name"$'\n'
        notes="${notes}the preserve commit is secret-scanned; flagged files are archived, not committed"$'\n'
        case "$preserve_branch" in
          preserve/*) push_ref="$preserve_branch" ;;
          *) push_ref="preserve/$(hy_slug "$preserve_branch")" ;;
        esac
        if wm_push_allowed "$repo"; then
          push=true
          notes="${notes}pushes only to origin $push_ref"$'\n'
        else
          notes="${notes}origin owner not in worktrees.push_owners: the preserve commit stays local"$'\n'
        fi
      else
        class=move; notes="${notes}outside the sanctioned roots"$'\n'
      fi
    fi
    case "$merged" in
      unverified) notes="${notes}merge unverified (gh unavailable)"$'\n' ;;
    esac
    [ "$unpushed" != true ] || [ "$class" = remove ] || notes="${notes}unpushed commits or no upstream"$'\n'
    if [ "$class" = move ] || [ "$class" = preserve ]; then
      if [ -n "$branch" ]; then
        target="$(hy_convention_path "$repo" "$branch")" || trc=$?
      else
        target="$(hy_convention_path "$repo" --detached "$head")" || trc=$?
      fi
      if [ "$trc" -eq 3 ]; then
        holds="${holds}convention path $target is taken by another branch, clone or file"$'\n'
      elif [ "$trc" -ne 0 ]; then
        holds="${holds}convention path cannot be computed (hygiene status $trc)"$'\n'
      elif [ -e "$target" ]; then
        holds="${holds}convention path $target already exists"$'\n'
      fi
    fi
    case "$class" in
      move|preserve|remove)
        if [ "$owner_count" -gt 0 ] && journal="$(wm_detach_journal)"; then
          holds="${holds}stale detach journal $journal: archive it before migrating attached worktrees"$'\n'
        fi ;;
    esac
    [ -z "$holds" ] || class=hold
  fi

  printf '%s\n' "$row" | jq -c --arg class "$class" --arg holds "$holds" --arg notes "$notes" \
    --arg target "$target" --argjson modified "$modified" --argjson untracked "$untracked" \
    --argjson idle "$idle" --argjson unpushed "$unpushed" --arg merged "$merged" \
    --arg preserve_branch "$preserve_branch" --argjson push "$push" --arg push_ref "$push_ref" \
    --rawfile kept "$work/kept" --rawfile regen "$work/regen" '
      def lines($s): $s | split("\n") | map(select(. != ""));
      (lines($regen)) as $regen_dirs
      | .class = $class
      | .reasons = (lines($holds) + lines($notes))
      | .target = (if ($class == "move" or $class == "preserve") and $target != "" then $target else null end)
      | .modified = $modified | .untracked = $untracked
      | .ignored_kept = lines($kept) | .regenerable = $regen_dirs
      | .idle = ($idle == 1) | .unpushed = $unpushed | .merged = $merged
      | .preserve_branch = (if $preserve_branch == "" then null else $preserve_branch end)
      | .push = $push
      | .push_ref = (if $push_ref == "" then null else $push_ref end)
      | .dehydrate = (if $class == "move" or $class == "preserve"
                      then [$regen_dirs[] | select(split("/") | last == ".venv")] else [] end)
      | .after = ([.dehydrate[] | "uv sync (in " + (split("/") | .[:-1] | if length == 0 then "." else join("/") end) + ")"]
                  + (if ($class == "move" or $class == "preserve")
                        and ([$regen_dirs[] | select(split("/") | last == "node_modules")] | length) > 0
                     then ["pnpm install (node_modules was carried)"] else [] end))'
}

# wm_classify WORK FACTS — classify every fact row, then apply the rules that
# span rows:
#   * git worktree prune is per repository, so a repo prunes only when every
#     one of its missing entries is class prune (git never prunes a locked
#     entry, so a locked one does not block its siblings);
#   * attach refuses a whole checkout while an owner record names a missing
#     path (attach-project.sh orphan-owner-record), so every sibling holds;
#   * two rows bound for the same convention path both hold.
wm_classify() {
  local work="$1" facts="$2" snapshot row
  snapshot="$work/lsof"
  dj_capture_lsof_snapshot "$snapshot" 10 >/dev/null 2>&1 || true
  while IFS= read -r row; do
    wm_classify_row "$row" "$snapshot" "$work"
  done < "$facts" > "$work/classified.jsonl"
  jq -sc '
    def actionable: .class == "prune" or .class == "remove" or .class == "preserve" or .class == "move";
    (map(select(.missing and .class != "prune" and (.locked | not)) | .common) | unique) as $blocked
    | (map(select(.missing and .owner_count > 0) | {common, path})) as $orphaned
    | ([.[] | select(.class == "move" or .class == "preserve") | .target]
       | group_by(.) | map(select(length > 1) | .[0])) as $dup_targets
    | .[]
    | if .class == "prune" and (.common as $c | $blocked | index($c))
      then .class = "hold"
           | .reasons += ["another missing entry in this repository is held; git worktree prune is per repository"]
      else . end
    | . as $row
    | ([$orphaned[] | select(.common == $row.common and .path != $row.path) | .path] | first) as $orphan
    | if actionable and $orphan != null
      then .class = "hold"
           | .reasons += ["attach refuses this checkout until the owner record for \($orphan) is archived (docs/UPGRADING.md, orphan owner records)"]
      else . end
    | if (.class == "move" or .class == "preserve") and (.target as $t | $dup_targets | index($t))
      then .class = "hold"
           | .reasons += ["convention path \(.target) is also the target of another worktree"]
      else . end' "$work/classified.jsonl"
}
