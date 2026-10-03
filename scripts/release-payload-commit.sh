#!/usr/bin/env bash
# Build and verify a release payload commit (spec 055 Unit 3).
#
# A release tag names a payload commit, never the release commit itself. The
# payload commit's sole parent is the approved release commit on main; its tree
# is that commit's tree minus the directories listed in
# core-rules/payload-exclude.txt; its author and committer are copied from the
# release commit and its message is a fixed template, so rebuilding it gives
# the same SHA. Installers are unchanged: they extract the tag's tree, so every
# installer, old or new, delivers the filtered payload.
#
# Usage:
#   release-payload-commit.sh <release-commit>
#       Build the payload commit and print its SHA. Plumbing only: the working
#       tree, the index and every ref are left untouched.
#   release-payload-commit.sh --verify-candidate <payload-commit> <approved-release-commit> <version>
#       Before tagging. Needs no tag.
#   release-payload-commit.sh --verify-tag <tag> <approved-release-commit>
#       After tagging: the tag is annotated, named v<VERSION>, and its commit
#       passes --verify-candidate.
#
# Runs against the repository of the current directory. The ancestry check
# reads refs/remotes/origin/main as it stands, so run `git fetch origin main`
# first (release cut step 1). Exit 0 verified or built, 1 refused, 2 usage.

set -euo pipefail

RPC_LIST=core-rules/payload-exclude.txt
RPC_VERSION_FILE=core-rules/VERSION
RPC_MAIN_REF=refs/remotes/origin/main
# The release version shape, as trellis_home_is_valid_semver (lib/trellis-home.sh)
# accepts it for `release install`. Matched with [[ =~ ]], so ^ and $ anchor the
# whole string and a value with an embedded newline never matches.
RPC_VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
RPC_SCRATCH=""

rpc_refuse() {
  printf 'release-payload-commit: refused: %s\n' "$*" >&2
  exit 1
}

rpc_usage() {
  sed -n '12,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

rpc_commit() {
  git rev-parse -q --verify "$1^{commit}" 2>/dev/null
}

# rpc_blob_is_line <commit> <path> <value>: the blob holds exactly "<value>\n",
# the bytes both installers compare core-rules/VERSION against.
rpc_blob_is_line() {
  local content
  content="$(git cat-file blob "$1:$2" 2>/dev/null && printf x)" || return 1
  [ "$content" = "$3"$'\n'x ]
}

# rpc_entries <commit>: the exclusion list read from <commit>'s own tree, one
# validated directory prefix per line. Every entry must exist in that commit.
rpc_entries() {
  local commit="$1" content line entries=""
  content="$(git cat-file blob "$commit:$RPC_LIST" 2>/dev/null)" ||
    rpc_refuse "$RPC_LIST is absent from $commit"
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in
      /*|./*|../*|*//*|*/./*|*/../*|*[[:space:]]*|*[\*\?\[\\]*)
        rpc_refuse "unsafe exclusion entry: $line" ;;
      */) ;;
      *) rpc_refuse "exclusion entry must name a directory with a trailing slash: $line" ;;
    esac
    case "$RPC_VERSION_FILE" in "$line"*) rpc_refuse "exclusion entry would drop $RPC_VERSION_FILE: $line" ;; esac
    case "$RPC_LIST" in "$line"*) rpc_refuse "exclusion entry would drop $RPC_LIST: $line" ;; esac
    [ "$(git cat-file -t "$commit:${line%/}" 2>/dev/null)" = tree ] ||
      rpc_refuse "listed path is absent from $commit: $line"
    entries="$entries$line"$'\n'
  done <<EOF
$content
EOF
  [ -n "$entries" ] || rpc_refuse "$RPC_LIST in $commit lists no paths"
  printf '%s' "$entries"
}

# rpc_listed_files <commit> <entries>: every file under the listed prefixes,
# NUL-terminated and sorted.
rpc_listed_files() {
  local commit="$1" entries="$2" entry
  local -a paths=()
  while IFS= read -r entry; do
    [ -n "$entry" ] && paths+=("$entry")
  done <<EOF
$entries
EOF
  git ls-tree -r -z --name-only "$commit" -- "${paths[@]}" | LC_ALL=C sort -z
}

# rpc_ident <commit> <author|committer> <NAME|EMAIL|DATE>: read the raw commit
# header, so no log/show configuration can reshape the identity.
rpc_ident() {
  local header line ident date
  header="$(git cat-file commit "$1" | sed -n "/^$2 /{p;q;}")"
  line="${header#"$2" }"
  date="${line##*> }"
  ident="${line%" $date"}"
  case "$3" in
    NAME) printf '%s' "${ident% <*}" ;;
    EMAIL) ident="${ident##*<}"; printf '%s' "${ident%>}" ;;
    DATE) printf '@%s' "$date" ;;
  esac
}

rpc_cleanup() {
  [ -z "$RPC_SCRATCH" ] || rm -rf "$RPC_SCRATCH"
}

rpc_build() {
  local release version entries scratch tree payload message
  [ "$#" -eq 1 ] || rpc_usage
  release="$(rpc_commit "$1")" || rpc_refuse "not a commit: $1"
  entries="$(rpc_entries "$release")"
  git cat-file -e "$release:$RPC_VERSION_FILE" 2>/dev/null ||
    rpc_refuse "$RPC_VERSION_FILE is absent from $release"
  version="$(git cat-file blob "$release:$RPC_VERSION_FILE")"
  [[ "$version" =~ $RPC_VERSION_RE ]] && rpc_blob_is_line "$release" "$RPC_VERSION_FILE" "$version" ||
    rpc_refuse "$RPC_VERSION_FILE in $release is not one version line"

  RPC_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/release-payload.XXXXXX")"
  scratch="$RPC_SCRATCH"
  trap rpc_cleanup EXIT
  GIT_INDEX_FILE="$scratch/index" git read-tree "$release"
  rpc_listed_files "$release" "$entries" |
    GIT_INDEX_FILE="$scratch/index" git update-index -z --force-remove --stdin
  tree="$(GIT_INDEX_FILE="$scratch/index" git write-tree)"
  git cat-file -e "$tree:$RPC_VERSION_FILE" 2>/dev/null ||
    rpc_refuse "payload tree lost $RPC_VERSION_FILE"

  message="chore(release): payload v$version"$'\n\n'"Tree: release commit $release minus the paths listed in $RPC_LIST."
  payload="$(
    GIT_AUTHOR_NAME="$(rpc_ident "$release" author NAME)" \
    GIT_AUTHOR_EMAIL="$(rpc_ident "$release" author EMAIL)" \
    GIT_AUTHOR_DATE="$(rpc_ident "$release" author DATE)" \
    GIT_COMMITTER_NAME="$(rpc_ident "$release" committer NAME)" \
    GIT_COMMITTER_EMAIL="$(rpc_ident "$release" committer EMAIL)" \
    GIT_COMMITTER_DATE="$(rpc_ident "$release" committer DATE)" \
    git -c i18n.commitEncoding=UTF-8 commit-tree --no-gpg-sign "$tree" -p "$release" -F - <<EOF
$message
EOF
  )"
  printf '%s\n' "$payload"
}

rpc_verify_candidate() {
  local payload approved version parents main entries expected actual status path
  [ "$#" -eq 3 ] || rpc_usage
  payload="$(rpc_commit "$1")" || rpc_refuse "payload commit does not resolve: $1"
  approved="$(rpc_commit "$2")" || rpc_refuse "approved release commit does not resolve: $2"
  version="$3"
  [[ "$version" =~ $RPC_VERSION_RE ]] || rpc_refuse "invalid version: $version"

  [ "$(git rev-list --first-parent -n2 "$payload")" = "$payload"$'\n'"$approved" ] ||
    rpc_refuse "the first parents of $payload are not $payload then $approved"
  parents="$(git rev-list --parents -n1 "$payload")"
  [ "$parents" = "$payload $approved" ] ||
    rpc_refuse "$payload does not have $approved as its sole parent"

  main="$(rpc_commit "$RPC_MAIN_REF")" ||
    rpc_refuse "$RPC_MAIN_REF is absent; run git fetch origin main first"
  git merge-base --is-ancestor "$approved" "$main" ||
    rpc_refuse "approved commit $approved is not on the fetched origin/main ($main)"

  entries="$(rpc_entries "$approved")"
  expected="$(rpc_listed_files "$approved" "$entries" | tr '\0' '\n')"
  actual=""
  while IFS= read -r -d '' status && IFS= read -r -d '' path; do
    [ "$status" = D ] || rpc_refuse "payload changes more than deletions: $status $path"
    actual="$actual$path"$'\n'
  done < <(git diff-tree -r -z --no-renames --name-status "$approved" "$payload")
  actual="$(printf '%s' "$actual" | LC_ALL=C sort)"
  if [ "$actual" != "$expected" ]; then
    path="$(LC_ALL=C comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | sed -n 1p)"
    [ -z "$path" ] || rpc_refuse "listed file is not deleted in the payload: $path"
    path="$(LC_ALL=C comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | sed -n 1p)"
    rpc_refuse "payload deletes a file outside the listed paths: $path"
  fi

  rpc_blob_is_line "$approved" "$RPC_VERSION_FILE" "$version" ||
    rpc_refuse "$RPC_VERSION_FILE in $approved is not $version"
  rpc_blob_is_line "$payload" "$RPC_VERSION_FILE" "$version" ||
    rpc_refuse "$RPC_VERSION_FILE in $payload is not $version"
  printf 'release-payload-commit: candidate %s verified against %s (v%s)\n' "$payload" "$approved" "$version"
}

rpc_verify_tag() {
  local tag approved header commit version
  [ "$#" -eq 2 ] || rpc_usage
  tag="$1"
  approved="$2"
  case "$tag" in v?*) ;; *) rpc_refuse "tag is not named v<VERSION>: $tag" ;; esac
  case "$tag" in */*|*[[:space:]]*) rpc_refuse "invalid tag name: $tag" ;; esac
  [ "$(git cat-file -t "refs/tags/$tag" 2>/dev/null)" = tag ] ||
    rpc_refuse "not an annotated tag: $tag"
  # Only the header counts: it ends at the first blank line, and the message
  # after it may say anything, including "tag <name>".
  header="$(git cat-file tag "refs/tags/$tag" | sed '/^$/,$d')"
  grep -qx 'type commit' <<<"$header" ||
    rpc_refuse "tag does not point at a commit: $tag"
  grep -Fqx "tag $tag" <<<"$header" ||
    rpc_refuse "tag object is not named $tag"
  commit="$(rpc_commit "refs/tags/$tag")" || rpc_refuse "tag does not resolve to a commit: $tag"
  version="$(git cat-file blob "$commit:$RPC_VERSION_FILE" 2>/dev/null)" ||
    rpc_refuse "$RPC_VERSION_FILE is absent from $tag"
  [ "$tag" = "v$version" ] || rpc_refuse "tag $tag is not named v$version"
  rpc_verify_candidate "$commit" "$approved" "$version"
  printf 'release-payload-commit: tag %s verified\n' "$tag"
}

case "${1:-}" in
  --verify-candidate) shift; rpc_verify_candidate "$@" ;;
  --verify-tag) shift; rpc_verify_tag "$@" ;;
  ''|-h|--help|-*) rpc_usage ;;
  *) rpc_build "$@" ;;
esac
