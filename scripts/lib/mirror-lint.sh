#!/usr/bin/env bash
# Pure, sourceable lint for the public Trellis mirror.
#
# The mirror must contain portable policy and tools only. It must never contain
# private TRELLIS_HOME state or an operator's absolute home path. All traversal
# is lexical or `find -P` over regular files, so neither validation nor content
# scans dereference a hostile mirror link. Unknown operator paths fail closed
# on their own bytes.

# lint_mirror MIRROR_DIR
#   Prints "relative-path: reason" per offender to stdout.
#   Returns 0 when clean, 1 for policy violations, 2 for bad arguments.

# mirror_find_path_escape LITERAL_PATH
#   Escapes a literal path for use inside a `find -path` pattern. `-path`
#   matches with shell-glob semantics, so an unescaped `*`, `?`, `[`, `]` or
#   `\` anywhere in the mirror's own absolute path is read as pattern syntax
#   instead of as itself. That fails open, not closed: the whole structural
#   scan silently matches nothing and a dirty mirror lints clean. Escape the
#   root once and interpolate the escaped form into every `-path` term.
mirror_find_path_escape() {
  local out="${1:-}"
  out="${out//\\/\\\\}"
  out="${out//\*/\\*}"
  out="${out//\?/\\?}"
  out="${out//\[/\\[}"
  out="${out//\]/\\]}"
  printf '%s' "$out"
}

# mirror_link_target_is_contained RELATIVE_LINK_PATH TARGET
#   Validates a relative symlink target by lexical resolution. It never follows
#   the link, so a hostile mirror cannot turn validation into filesystem access.
mirror_link_target_is_contained() {
  local rel="${1:-}" target="${2:-}" parent rest component resolved=""
  [ "$#" -eq 2 ] || return 1
  case "$rel" in
    ''|/*|*'//'|*'/./'*|*'/../'*|*/.|*/..|*$'\t'*|*$'\n'*|*$'\r'*) return 1 ;;
  esac
  case "$target" in
    ''|/*|*'//'|*$'\t'*|*$'\n'*|*$'\r'*) return 1 ;;
  esac
  case "$rel" in
    */*) parent="${rel%/*}" ;;
    *) parent="" ;;
  esac
  if [ -n "$parent" ]; then rest="$parent/$target"; else rest="$target"; fi
  while [ -n "$rest" ]; do
    case "$rest" in
      */*) component="${rest%%/*}"; rest="${rest#*/}" ;;
      *) component="$rest"; rest="" ;;
    esac
    case "$component" in
      ''|.) ;;
      ..)
        [ -n "$resolved" ] || return 1
        case "$resolved" in */*) resolved="${resolved%/*}" ;; *) resolved="" ;; esac
        ;;
      *)
        case "$component" in *$'\t'*|*$'\n'*|*$'\r'*) return 1 ;; esac
        if [ -n "$resolved" ]; then resolved="$resolved/$component"; else resolved="$component"; fi
        ;;
    esac
  done
  [ -n "$resolved" ]
}

# mirror_validate_symlinks MIRROR_DIR
#   Rejects absolute or relative links that escape the mirror. Safe relative
#   links may remain as leaf artifacts, but callers must never use a link as a
#   destination parent for a mutation.
mirror_validate_symlinks() {
  local mirror_dir="${1:-}" mirror_pat link rel target rc=0
  [ "$#" -eq 1 ] || return 2
  [ -d "$mirror_dir" ] && [ ! -L "$mirror_dir" ] || return 2
  mirror_pat="$(mirror_find_path_escape "$mirror_dir")"
  while IFS= read -r link; do
    [ -n "$link" ] || continue
    rel="${link#"$mirror_dir"/}"
    target="$(readlink "$link" 2>/dev/null || true)"
    case "$target" in
      /*)
        printf '%s: symlink target leaks absolute path\n' "$rel"
        rc=1
        ;;
      *)
        if ! mirror_link_target_is_contained "$rel" "$target"; then
          printf '%s: symlink target escapes mirror\n' "$rel"
          rc=1
        fi
        ;;
    esac
  done < <(find -P "$mirror_dir" -path "$mirror_pat/.git" -prune -o -type l -print 2>/dev/null)
  return "$rc"
}

lint_mirror() {
  local mirror_dir="${1:-}" mirror_pat rc=0 f rel hit path username
  [ "$#" -eq 1 ] || { printf 'mirror-lint: usage: lint_mirror MIRROR_DIR\n' >&2; return 2; }
  [ -d "$mirror_dir" ] && [ ! -L "$mirror_dir" ] || {
    printf 'mirror-lint: not an ordinary directory: %s\n' "$mirror_dir" >&2
    return 2
  }
  mirror_pat="$(mirror_find_path_escape "$mirror_dir")"

  # Local machine state is never a public template payload. Keep the list
  # structural rather than content-based: it catches a future sync allowlist
  # mistake before a path-redaction scheme has a chance to hide it.
  #
  # Every term is a top-level TRELLIS_HOME child, anchored at exactly one depth
  # (`$mirror_pat/NAME` plus `$mirror_pat/NAME/*`) so the group stays readable
  # as an inventory of private roots. A deeper or unanchored `-name` term would
  # be redundant with its own root and, being a glob rather than a path, could
  # not be paired with a `delist_prune` entry in `sync-to-template.sh`. That
  # pairing is a hard invariant: a path this lint rejects but the sync cannot
  # prune is a mirror that can never be published clean again.
  #
  # `tasks` and `locks` are distinct roots, not sub-cases of the ones above
  # them. `tasks` holds materialized task state — a local-registry snapshot and
  # private backlog — and is *not* covered by `scheduled-tasks`, which is the
  # repository's own source directory. `locks` is the TRELLIS_HOME lock root
  # and is not covered by `state`, which has its own separate `state/locks`.
  #
  # KNOWN GAP, deliberately not covered: TRELLIS_HOME also holds transient
  # atomic-write temporaries as *siblings* of the artifacts above —
  # `.config.json.tmp.XXXXXX` (scripts/lib/trellis-home.sh) and
  # `.registry.json.tmp.XXXXXX` (scripts/lib/local-registry.sh). Their names
  # end in an `mktemp` suffix, so no exact relative path can ever name them,
  # and `delist_prune` in `sync-to-template.sh` deletes exact literal paths
  # only — `mirror_remove_pruned_paths` builds `$root/$path` and never expands
  # a glob. Adding a reject term for them without first teaching the prune side
  # to match a prefix would therefore manufacture the exact permanently
  # unpublishable mirror the pairing invariant exists to prevent, so the term
  # is withheld rather than unpairable. Residual exposure is bounded: any
  # directory-granularity allowlist mistake that copies a temp also copies its
  # committed sibling, and the anchored `config.json` / `registry.json` terms
  # below reject that and block the publish. What stays uncovered is only an
  # allowlist naming a dot-prefixed temp pattern with no committed sibling
  # present. Closing it is a `delist_prune` prefix-matching change, tracked as
  # such, not a lint-only edit.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$mirror_dir"/}"
    printf '%s: private Trellis machine state must not publish\n' "$rel"
    rc=1
  done < <(find -P "$mirror_dir" \
    \( -path "$mirror_pat/.trellis" -o -path "$mirror_pat/.trellis/*" \
       -o -path "$mirror_pat/config.json" \
       -o -path "$mirror_pat/registry.json" \
       -o -path "$mirror_pat/releases" -o -path "$mirror_pat/releases/*" \
       -o -path "$mirror_pat/state" -o -path "$mirror_pat/state/*" \
       -o -path "$mirror_pat/tasks" -o -path "$mirror_pat/tasks/*" \
       -o -path "$mirror_pat/locks" -o -path "$mirror_pat/locks/*" \
       -o -path "$mirror_pat/scheduled-tasks" -o -path "$mirror_pat/scheduled-tasks/*" \
       -o -path "$mirror_pat/local" -o -path "$mirror_pat/local/*" \) \
    -not -path '*/.git/*' -print 2>/dev/null)

  # A public symlink may be relative only when lexical resolution remains
  # inside the mirror. This rejects both absolute targets and ../ escapes
  # without dereferencing a potentially hostile target.
  if ! mirror_validate_symlinks "$mirror_dir"; then
    return 1
  fi
  # Any non-generic home path is an operator path, including one copied from
  # a different machine.
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    rel="${hit%%:*}"
    rel="${rel#"$mirror_dir"/}"
    path="${hit#*:}"
    while IFS= read -r username; do
      [ -n "$username" ] || continue
      username="${username#/Users/}"
      username="${username#/home/}"
      username="${username%%/*}"
      case "$username" in
        me|example|user|you|test|jane|helios|alex|'...') ;;
        *)
          printf '%s: absolute-path leak\n' "$rel"
          rc=1
          break
          ;;
      esac
    done < <(printf '%s\n' "$path" | grep -oE '/(Users|home)/[[:alnum:]_.-]+/' 2>/dev/null)
  done < <(find -P "$mirror_dir" -path "$mirror_pat/.git" -prune -o -type f \
    -exec grep -HnE -- '/(Users|home)/[[:alnum:]_.-]+/' {} + 2>/dev/null)

  # Preserve the historical-record boundary for retired private integrations.
  # The lint implementation itself is allowed to name the tokens it detects.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$mirror_dir"/}"
    case "$rel" in
      docs/adr/*|docs/specs/*|CHANGELOG.md|scripts/lib/mirror-lint.sh|scripts/tests/mirror-lint.bats|scripts/sync-to-template.sh) ;;
      *) printf "%s: stale 'antigravity' in current operator surface\n" "$rel"; rc=1 ;;
    esac
  done < <(find -P "$mirror_dir" -path "$mirror_pat/.git" -prune -o -type f \
    -exec grep -IliF -- 'antigravity' {} + 2>/dev/null)

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$mirror_dir"/}"
    case "$rel" in
      docs/adr/*|docs/specs/*|CHANGELOG.md|scripts/lib/mirror-lint.sh|scripts/tests/mirror-lint.bats) ;;
      *) printf "%s: instance-private proxy token must not publish\n" "$rel"; rc=1 ;;
    esac
  done < <(find -P "$mirror_dir" -path "$mirror_pat/.git" -prune -o -type f \
    -exec grep -IliE -- 'claudex|cliproxy|cli-proxy-api' {} + 2>/dev/null)

  return "$rc"
}
