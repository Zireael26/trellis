#!/usr/bin/env bash
# Strict SemVer 2.0.0 validation and precedence helpers for Trellis shell tools.
#
# Public functions:
#   semver_is_valid <version>       accepts an optional leading "v"
#   semver_compare <left> <right>   prints -1, 0, or 1
#   semver_max                      reads versions on stdin, prints the maximum
#
# Build metadata is ignored for precedence. Numeric prerelease identifiers are
# compared numerically, numeric identifiers sort before non-numeric ones, a
# shorter equal prerelease sorts first, and a stable release sorts after every
# prerelease of the same core version.
#
# Bash 3.2 compatible; sourcing this file has no side effects.

semver_is_valid() {
  local version="${1:-}" no_build prerelease identifier
  local -a identifiers=()
  case "$version" in
    v*) version="${version#v}" ;;
  esac

  [ -n "$version" ] || return 1
  printf '%s' "$version" | LC_ALL=C grep -Eq \
    '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$' \
    || return 1

  no_build="${version%%+*}"
  case "$no_build" in
    *-*) prerelease="${no_build#*-}" ;;
    *) return 0 ;;
  esac

  IFS='.' read -r -a identifiers <<< "$prerelease"
  for identifier in "${identifiers[@]}"; do
    case "$identifier" in
      *[!0-9]*) ;;
      0|[1-9]|[1-9][0-9]*) ;;
      *) return 1 ;; # numeric prerelease identifiers cannot have leading zeroes
    esac
  done
  return 0
}

_semver_compare_numeric() {
  local left="$1" right="$2" LC_ALL=C
  if [ "${#left}" -lt "${#right}" ]; then
    printf '%s' '-1'
  elif [ "${#left}" -gt "${#right}" ]; then
    printf '%s' '1'
  elif [ "$left" = "$right" ]; then
    printf '%s' '0'
  elif [ "x$left" \< "x$right" ]; then
    printf '%s' '-1'
  else
    printf '%s' '1'
  fi
}

_semver_compare_lexical() {
  local left="$1" right="$2" LC_ALL=C
  if [ "$left" = "$right" ]; then
    printf '%s' '0'
  elif [ "x$left" \< "x$right" ]; then
    printf '%s' '-1'
  else
    printf '%s' '1'
  fi
}

semver_compare() {
  local left="${1:-}" right="${2:-}"
  local left_clean right_clean left_core right_core left_pre="" right_pre=""
  local left_major left_minor left_patch right_major right_minor right_patch
  local comparison left_rest right_rest left_id right_id left_more right_more
  local left_numeric right_numeric

  semver_is_valid "$left" || return 1
  semver_is_valid "$right" || return 1

  left_clean="${left#v}"
  right_clean="${right#v}"
  left_clean="${left_clean%%+*}"
  right_clean="${right_clean%%+*}"

  case "$left_clean" in
    *-*) left_pre="${left_clean#*-}"; left_core="${left_clean%%-*}" ;;
    *) left_core="$left_clean" ;;
  esac
  case "$right_clean" in
    *-*) right_pre="${right_clean#*-}"; right_core="${right_clean%%-*}" ;;
    *) right_core="$right_clean" ;;
  esac

  IFS='.' read -r left_major left_minor left_patch <<< "$left_core"
  IFS='.' read -r right_major right_minor right_patch <<< "$right_core"
  for comparison in \
    "$(_semver_compare_numeric "$left_major" "$right_major")" \
    "$(_semver_compare_numeric "$left_minor" "$right_minor")" \
    "$(_semver_compare_numeric "$left_patch" "$right_patch")"; do
    if [ "$comparison" -ne 0 ]; then
      printf '%s' "$comparison"
      return 0
    fi
  done

  # A normal release has higher precedence than a prerelease with the same core.
  if [ -z "$left_pre" ] && [ -z "$right_pre" ]; then
    printf '%s' '0'
    return 0
  elif [ -z "$left_pre" ]; then
    printf '%s' '1'
    return 0
  elif [ -z "$right_pre" ]; then
    printf '%s' '-1'
    return 0
  fi

  left_rest="$left_pre"
  right_rest="$right_pre"
  while :; do
    case "$left_rest" in
      *.*) left_id="${left_rest%%.*}"; left_rest="${left_rest#*.}"; left_more=1 ;;
      *) left_id="$left_rest"; left_rest=""; left_more=0 ;;
    esac
    case "$right_rest" in
      *.*) right_id="${right_rest%%.*}"; right_rest="${right_rest#*.}"; right_more=1 ;;
      *) right_id="$right_rest"; right_rest=""; right_more=0 ;;
    esac

    case "$left_id" in *[!0-9]*) left_numeric=0 ;; *) left_numeric=1 ;; esac
    case "$right_id" in *[!0-9]*) right_numeric=0 ;; *) right_numeric=1 ;; esac

    if [ "$left_numeric" -eq 1 ] && [ "$right_numeric" -eq 1 ]; then
      comparison=$(_semver_compare_numeric "$left_id" "$right_id")
    elif [ "$left_numeric" -eq 1 ]; then
      comparison=-1
    elif [ "$right_numeric" -eq 1 ]; then
      comparison=1
    else
      comparison=$(_semver_compare_lexical "$left_id" "$right_id")
    fi
    if [ "$comparison" -ne 0 ]; then
      printf '%s' "$comparison"
      return 0
    fi

    if [ "$left_more" -eq 0 ] && [ "$right_more" -eq 0 ]; then
      printf '%s' '0'
      return 0
    elif [ "$left_more" -eq 0 ]; then
      printf '%s' '-1'
      return 0
    elif [ "$right_more" -eq 0 ]; then
      printf '%s' '1'
      return 0
    fi
  done
}

semver_max() {
  local candidate="" latest="" comparison=""
  while IFS= read -r candidate || [ -n "$candidate" ]; do
    candidate="${candidate%$'\r'}"
    semver_is_valid "$candidate" || continue
    if [ -z "$latest" ]; then
      latest="$candidate"
      continue
    fi
    comparison=$(semver_compare "$candidate" "$latest") || continue
    if [ "$comparison" -gt 0 ]; then
      latest="$candidate"
    fi
  done
  [ -n "$latest" ] || return 1
  printf '%s\n' "$latest"
}
