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

# mirror_fleet_identity_tokens
#   Prints the lowercased project identifiers of the local fleet, one per line.
#
# The token set is READ FROM PRIVATE LOCAL STATE, never hardcoded. A hardcoded
# list would publish, inside this very file, the names it exists to suppress —
# and would go stale the moment a project is onboarded, which is precisely how
# a leak returns after being cleaned once. Reading the machine-local registry
# means the guard covers every project the operator has now and every one they
# add later, with nothing to remember.
#
# Fails (non-zero) when the source is unreadable so the caller can refuse to
# certify rather than certify blind.
mirror_fleet_identity_tokens() {
  local source="${TRELLIS_MIRROR_IDENTITY_SOURCE:-${TRELLIS_HOME:-$HOME/.trellis}/registry.json}"
  local public_tokens
  [ -f "$source" ] && [ ! -L "$source" ] || return 1
  public_tokens="$(mirror_fleet_public_identity_tokens "$source")" || return 1
  # Deliberately parsed with grep/sed rather than jq. `trellis mirror` re-execs
  # through `env -i` with PATH=/usr/bin:/bin:/usr/sbin:/sbin, so a jq-dependent
  # guard resolves "unreadable" on every real publish — it would fail closed
  # forever and be ripped out as broken, which is worse than no guard. The
  # fields read here are flat string values written by this repo's own
  # local-registry writer, so a full JSON parser buys nothing.
  {
    grep -oE '"project_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$source" 2>/dev/null
    grep -oE '"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+"[[:space:]]*:[[:space:]]*\{' "$source" 2>/dev/null
  } |
    sed -E 's/.*"([^"]*)"[[:space:]]*:?[[:space:]]*\{?$/\1/; s#.*/##' |
    LC_ALL=C tr '[:upper:]' '[:lower:]' |
    sed -E 's/\.(com|org|net|money|live|dev|in|ai|site)$//' |
    grep -vE '^.{0,2}$' |
    sort -u |
    { if [ -n "$public_tokens" ]; then grep -vxF -- "$public_tokens"; else cat; fi; }
}

# mirror_fleet_public_identity_tokens SOURCE
#   Prints the normalized identifiers of projects the operator has declared
#   already public, one per line, for subtraction from the guard's token set.
#
# Some project identifiers ARE public by construction: a personal site's own
# domain is the thing it publishes under, and it legitimately appears in this
# repository's README as a link and a maintainer byline. Without this list the
# guard reports that byline as a fleet-identity leak and the mirror can never
# be certified, which ends one of two ways — the byline gets deleted, or the
# check gets deleted. Neither is the right answer, so the distinction is made
# explicit and operator-owned instead.
#
# The declaration lives in machine-local registry metadata, set with
# `trellis registry annotate --metadata-json '{"public_identity": true}'`, for
# the same reason the token set itself is read rather than hardcoded: an
# allowlist written into this file would publish, in the mirror, a list of the
# operator's projects. Default is closed — a row says nothing, it is private.
#
# Parsed by indentation rather than by brace depth. `metadata.legacy` notes
# carry literal braces inside JSON strings, so a depth counter that cannot see
# string boundaries miscounts on real rows; the writer emits `jq -S` output at a
# fixed two-space indent, which those strings cannot forge. A source whose shape
# does not match yields no public tokens, so a formatting change fails toward
# flagging more rather than fewer.
#
# The short-token filter is `sed -E '/^.{0,2}$/d'`, not `grep -vE`. Having no
# annotated rows at all is the ordinary case, and `grep` exits 1 on empty input.
# `sync-to-template.sh` runs under `set -o pipefail`, so that 1 propagates out
# of the pipeline, the caller reads it as `return 1`, and the guard announces
# "fleet identity source unreadable" for a registry it read perfectly well —
# turning the common case into a hard publication failure. `sed` deletes the
# same lines and exits 0 whether or not it matched.
mirror_fleet_public_identity_tokens() {
  local source="${1:-}"
  [ -f "$source" ] && [ ! -L "$source" ] || return 1
  awk '
    /^    "[^"]+"[[:space:]]*:[[:space:]]*\{[[:space:]]*$/ { inproj = 1; pid = ""; pub = 0; next }
    inproj && /^        "public_identity"[[:space:]]*:[[:space:]]*true/ { pub = 1; next }
    inproj && /^      "project_id"[[:space:]]*:[[:space:]]*"/ {
      pid = $0
      sub(/^[^:]*:[[:space:]]*"/, "", pid)
      sub(/".*$/, "", pid)
      next
    }
    inproj && /^    \}/ { if (pub && pid != "") print pid; inproj = 0; pid = ""; pub = 0; next }
  ' "$source" 2>/dev/null |
    LC_ALL=C tr '[:upper:]' '[:lower:]' |
    sed -E 's#.*/##; s/\.(com|org|net|money|live|dev|in|ai|site)$//' |
    sed -E '/^.{0,2}$/d' |
    sort -u
}

lint_mirror() {
  local mirror_dir="${1:-}" mirror_pat rc=0 f rel hit path username
  local identity_tokens identity_token address
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
  # Record the failure and keep going. Returning here would let one unresolvable
  # symlink short-circuit every content check below, so a mirror could carry an
  # operator path or a fleet identifier and still be reported only as a symlink
  # problem. The verdict is the same either way; what changes is that the
  # operator sees the whole picture in one run.
  if ! mirror_validate_symlinks "$mirror_dir"; then
    rc=1
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

  # Preserve the historical-record boundary for the retired AntiGravity
  # harness. Three tokens name LIVE, publishable things and are stripped before
  # the stale-reference check: `google-antigravity` (the OMP provider id),
  # `pi-antigravity` (the pi provider extension package on npm), and the bare
  # lowercase `antigravity` (the pi provider id, as used in `/login antigravity`
  # and `--list-models antigravity`). Each is stripped only as a whole token —
  # adjacent identifier characters still mark it stale.
  #
  # Case is the discriminator that makes this safe: the retired harness was
  # always written `AntiGravity`/`Antigravity` in prose, so anything left after
  # stripping the three lowercase tokens still fails, including every
  # capitalised form. Public docs must therefore name the live provider by its
  # lowercase id rather than in prose caps.
  #
  # Spec 047 ships a live, public, antigravity-backed web-search adapter whose
  # public contract is unavoidably capitalised: the environment-variable names
  # it reads, its exported transport symbol, the provider host fragment, the
  # wire `ideType` value, and the provider's own spelling in error text and
  # attribution. Lower-casing any of them breaks the shipped feature.
  #
  # The allowance is PATH-SCOPED to the adapter, its runner and its one public
  # guide, which documents the same env contract, and every extra
  # token is an exact whole string, never a prefix class. A global allowance was
  # rejected: it would let a retired-harness reference through anywhere in the
  # tree. `AntiGravity` still fails everywhere, including inside the scope, and
  # the private-path, fleet-identity and proxy-token rules are untouched. This
  # is an allowance, not a skip — the check still runs on these files.

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$mirror_dir"/}"
    case "$rel" in
      docs/adr/*|docs/specs/*|CHANGELOG.md|scripts/lib/mirror-lint.sh|scripts/tests/mirror-lint.bats|scripts/sync-to-template.sh) ;;
      *)
        # Path-scoped extra tokens for the Spec 047 adapter's public contract.
        mirror_allowed_tokens='google-antigravity pi-antigravity antigravity'
        case "$rel" in
          core-rules/pi/web-search/*|scripts/pi-web-search-tests.sh|docs/pi-web-search.md)
            mirror_allowed_tokens="ANTIGRAVITY_RUNTIME_MODEL ANTIGRAVITY_USER_AGENT \
ANTIGRAVITY_HUB_VERSION ANTIGRAVITY_PROJECT_ID ANTIGRAVITY_HUB_ARCH \
ANTIGRAVITY_BASE_URL createAntigravityTransport ANTIGRAVITY_HUB_OS \
ANTIGRAVITY_HUB_CL ANTIGRAVITY_API antigravity-api Antigravity-backed \
ANTIGRAVITY_ ANTIGRAVITY Antigravity $mirror_allowed_tokens"
            ;;
        esac
        if awk -v allowed_tokens="$mirror_allowed_tokens" '
          {
            line = $0
            # Longest first: pi-/google- prefixes must be consumed before the
            # bare id, or the bare-id pass would see their suffix as a match
            # with an identifier character before it and call it stale.
            n = split(allowed_tokens, allowed, /[ \t\n]+/)
            for (i = 1; i <= n; i++) {
              if (allowed[i] == "") continue
              token = allowed[i]
              while ((pos = index(line, token)) != 0) {
                before = pos == 1 ? "" : substr(line, pos - 1, 1)
                after = substr(line, pos + length(token), 1)
                if (before ~ /[[:alnum:]_-]/ || after ~ /[[:alnum:]_-]/) {
                  stale = 1
                  exit
                }
                line = substr(line, 1, pos - 1) substr(line, pos + length(token))
              }
            }
            if (index(tolower(line), "antigravity")) {
              stale = 1
              exit
            }
          }
          END { exit stale ? 0 : 1 }
        ' "$f"; then
          printf "%s: stale 'antigravity' in current operator surface\n" "$rel"
          rc=1
        fi
        ;;
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
    -exec grep -IliE -- 'claudex|cli-proxy-api|cliproxy' {} + 2>/dev/null)

  # Fleet project identifiers must never reach a public mirror. Deliberately NO
  # historical-record exemption: unlike the retired-integration tokens above,
  # `docs/adr/*`, `docs/specs/*` and `CHANGELOG.md` are exactly where project
  # names accumulated unnoticed, because narrative prose is written long after
  # the allowlist decision and nothing re-checked it. A name is as public in a
  # two-year-old ADR as in today's README, so the boundary does not apply here.
  if ! identity_tokens="$(mirror_fleet_identity_tokens)" || [ -z "$identity_tokens" ]; then
    printf 'mirror-lint: fleet identity source unreadable — refusing to certify a mirror it cannot check\n'
    rc=1
  else
    while IFS= read -r identity_token; do
      [ -n "$identity_token" ] || continue
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        rel="${f#"$mirror_dir"/}"
        case "$rel" in
          scripts/lib/mirror-lint.sh|scripts/tests/mirror-lint.bats) ;;
          *) printf '%s: local fleet project identifier must not publish\n' "$rel"; rc=1 ;;
        esac
      done < <(find -P "$mirror_dir" -path "$mirror_pat/.git" -prune -o -type f \
        -exec grep -IliwF -- "$identity_token" {} + 2>/dev/null)
    done <<IDENTITY_TOKENS
$identity_tokens
IDENTITY_TOKENS
  fi

  # Routable IPv4 literals are operator infrastructure — origin hosts, VPS
  # addresses, tunnel endpoints. Private, loopback, link-local and the three
  # RFC 5737 documentation ranges stay allowed so examples and fixtures work.
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    rel="${hit%%:*}"
    rel="${rel#"$mirror_dir"/}"
    case "$rel" in
      scripts/lib/mirror-lint.sh|scripts/tests/mirror-lint.bats) continue ;;
    esac
    path="${hit#*:}"
    while IFS= read -r address; do
      [ -n "$address" ] || continue
      case "$address" in
        10.*|127.*|169.254.*|0.0.0.0|255.255.255.255) continue ;;
        192.168.*|192.0.2.*|198.51.100.*|203.0.113.*) continue ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) continue ;;
      esac
      printf '%s: routable IP literal must not publish\n' "$rel"
      rc=1
      break
    done < <(printf '%s\n' "$path" | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' 2>/dev/null)
  done < <(find -P "$mirror_dir" -path "$mirror_pat/.git" -prune -o -type f \
    -exec grep -HnE -- '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' {} + 2>/dev/null)

  return "$rc"
}
