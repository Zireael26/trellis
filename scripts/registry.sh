#!/usr/bin/env bash
# Local machine registry CLI. Bash 3.2 compatible.

set -u

SCRIPT_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/local-registry.sh
. "$SCRIPT_DIR/lib/local-registry.sh"

usage() {
  cat <<'EOF'
Usage:
  registry.sh import --fleet NAME --registry FILE [--blacklist FILE]
                     [--projects-root PATH] [--home PATH]
  registry.sh list [--fleet NAME] [--json] [--home PATH]
  registry.sh rebuild --fleet NAME ROOT... [--apply] [--max-depth N]
                      [--progress|--no-progress] [--home PATH]
  registry.sh annotate --fleet NAME --project NAME --metadata-json JSON
                       [--home PATH]

`import` preserves legacy Markdown sources and writes only machine-local
registry.json. It requires --fleet NAME to already exist in this machine's
config; create it first with `trellis fleet add NAME --discovery-root PATH`.
`rebuild` scans only explicit roots for valid .trellis.json files, prints a
deterministic preview by default, and writes only with --apply. `annotate` sets
machine-local metadata on one already-registered project row.

Import options:
  --projects-root PATH  Resolve every legacy row path that is not an existing
                        absolute path against PATH (PATH + the recorded row
                        path). Historical registries record a portable
                        shorthand such as /personal/<name>; this is the
                        explicit, operator-supplied way to say where that
                        shorthand lives on this machine. The resolved absolute
                        path becomes the registry row root, the recorded
                        shorthand is retained as legacy.legacy_path metadata,
                        and a resolved path that does not exist imports as a
                        visible unavailable row at the resolved path. Blacklist
                        section 2 discovery ignores resolve through the same
                        flag, by the same rule, retaining their shorthand as
                        legacy_path on the ignore record. Without the flag every
                        recorded path is used exactly as recorded.

Rebuild options:
  --max-depth N         Maximum directory depth below each selected root at
                        which a .trellis.json manifest is discovered
                        (default 6, range 1-64). The scan never descends into
                        .git, node_modules, or vendor directories, so a bound
                        scan of a working projects root stays fast.
  --progress            Stream per-root scan progress to stderr. On by default
                        when stderr is a terminal; --no-progress silences it.
                        Preview JSON always goes to stdout, unaffected.

Annotate options:
  --project NAME        The registered project ID to annotate.
  --metadata-json JSON  A JSON object whose top-level keys are merged into the
                        row's metadata, replacing same-named keys and retaining
                        every other key. It never creates a row: an unregistered
                        project is exit class 5.

One metadata key is read by tooling rather than by people:

  public_identity       `true` declares that this project's identifier is
                        already public, and exempts it from the public-mirror
                        identity guard. Set it only for a project whose name is
                        the thing it publishes under — a personal site's own
                        domain, which appears legitimately in a README link or
                        maintainer byline. Absent or false means private, so the
                        guard defaults closed and an unannotated row can never
                        leak by omission.

A legacy Notes cell may contain a literal pipe written as \|. One ambiguous row
is rejected on its own, named by line and cell; a missing Active projects
section or header fails the whole file.

Exit classes: 0 success, 2 usage, 3 identity/path conflict, 4 corrupt state or
input, 5 unavailable path.
EOF
}

usage_error() {
  printf 'trellis registry: %s\n\n' "$*" >&2
  usage >&2
  exit "$TRELLIS_EX_USAGE"
}

highest_exit() {
  local current="${1:-0}" candidate="${2:-0}"
  if [ "$candidate" -gt "$current" ]; then printf '%s\n' "$candidate"; else printf '%s\n' "$current"; fi
}

render_table() {
  local json="${1:-}" rows rc=0
  rows="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.table.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  if ! jq -r '
    (.entries[]
      | [.fleet, .project_id,
         (if .availability == "identity_error" then "identity-error" else .status end),
         (.excluded // false), .kind,
         (.checkout_id // "-"), (.worktree_id // "-"), (.root // "-")]),
    (.discovery_ignores | to_entries[] as $fleet | $fleet.value[]
      | [$fleet.key, "-", "excluded", true, "discovery-ignore", "-", "-", .path])
    | @tsv
  ' "$json" > "$rows"; then
    rm -f "$rows"
    return "$TRELLIS_EX_STATE"
  fi
  printf 'FLEET\tPROJECT\tSTATUS\tEXCLUDED\tKIND\tCHECKOUT_ID\tWORKTREE_ID\tROOT\n'
  LC_ALL=C sort "$rows" || rc="$TRELLIS_EX_UNAVAILABLE"
  rm -f "$rows"
  return "$rc"
}

cmd_list() {
  local home_opt="" fleet="" json=0 home snapshot rc drifted
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --home) [ "$#" -ge 2 ] || usage_error "--home requires PATH"; home_opt="$2"; shift 2 ;;
      --fleet) [ "$#" -ge 2 ] || usage_error "--fleet requires NAME"; fleet="$2"; shift 2 ;;
      --json) json=1; shift ;;
      -h|--help) usage; return 0 ;;
      *) usage_error "unknown list option: $1" ;;
    esac
  done
  home="$(local_registry_home "$home_opt")" || return "$?"
  snapshot="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.list.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  local_registry_list_json "$home" "$fleet" > "$snapshot"
  rc="$?"
  if [ "$rc" -eq 0 ]; then
    if [ "$json" -eq 1 ]; then jq -S . "$snapshot"; else render_table "$snapshot"; fi
    rc="$?"
    # Rows that failed identity validation stay in the emitted listing and are
    # already reported per row; the exit class follows once every row rendered.
    # `jq -e` cannot carry this decision: it exits 1 for a false result and 2-5
    # for its own errors, so a broken jq would read exactly like "no drift".
    # Capture the answer as text instead and treat anything that is not a
    # literal `false` as a state error.
    if [ "$rc" -eq 0 ]; then
      if drifted="$(jq -r '[.entries[] | select(.availability == "identity_error")] | length > 0' "$snapshot" 2>/dev/null)"; then
        case "$drifted" in
          false) ;;
          true) rc="$TRELLIS_EX_STATE" ;;
          *)
            local_registry_err "could not classify registry identity state from the listing"
            rc="$TRELLIS_EX_STATE"
            ;;
        esac
      else
        local_registry_err "could not inspect the registry listing for identity-drift rows"
        rc="$TRELLIS_EX_STATE"
      fi
    fi
  fi
  rm -f "$snapshot"
  return "$rc"
}

legacy_blacklist_records() {
  local blacklist="${1:-}" names_output="${2:-}" ignores_output="${3:-}" records kind value reason added review_after normalized
  [ "$#" -eq 3 ] || return "$TRELLIS_EX_USAGE"
  : > "$names_output" || return "$TRELLIS_EX_UNAVAILABLE"
  : > "$ignores_output" || return "$TRELLIS_EX_UNAVAILABLE"
  [ -n "$blacklist" ] || return 0
  if [ -L "$blacklist" ] || [ ! -f "$blacklist" ]; then
    local_registry_err "legacy blacklist source must be a regular file: $blacklist"
    return "$TRELLIS_EX_STATE"
  fi
  records="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.blacklist-records.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  if ! awk '
    function trim(value) { sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+$/, "", value); return value }
    /^## 1\. Temporarily excluded \(registered projects\)[[:space:]]*$/ { section=1; temporary_seen++; next }
    /^## 2\. Permanently excluded from management[[:space:]]*$/ { section=2; permanent_seen++; next }
    /^## / { section=0; next }
    section == 0 || !/^\|/ { next }
    {
      if (index($0, "\t") > 0) { bad=1; next }
      line=$0; sub(/^\|/, "", line); sub(/\|[[:space:]]*$/, "", line)
      count=split(line, fields, /[|]/)
      for (i=1; i<=count; i++) fields[i]=trim(fields[i])
      if (section == 1) {
        if (count == 4 && fields[1] == "Project" && fields[2] == "Reason" && fields[3] == "Added" && fields[4] == "Review after") { temporary_header=1; next }
        if (count == 4 && fields[1] ~ /^-+$/ && fields[2] ~ /^-+$/ && fields[3] ~ /^-+$/ && fields[4] ~ /^-+$/) next
        if (count != 4 || fields[1] !~ /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/ ||
            fields[2] == "" || fields[3] !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/ ||
            fields[4] !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/ || temporary[fields[1]]++) { bad=1; next }
        print "temporary\t" fields[1] "\t" fields[2] "\t" fields[3] "\t" fields[4]
      } else {
        if (count == 2 && fields[1] == "Path" && fields[2] == "Reason") { permanent_header=1; next }
        if (count == 2 && fields[1] ~ /^-+$/ && fields[2] ~ /^-+$/) next
        if (count != 2 || fields[1] !~ /^`\/[^`]+`$/ || fields[2] == "") { bad=1; next }
        path=substr(fields[1], 2, length(fields[1]) - 2)
        if (permanent[path]++) { bad=1; next }
        print "permanent\t" path "\t" fields[2]
      }
    }
    END {
      if (temporary_seen != 1 || permanent_seen != 1 || !temporary_header || !permanent_header || bad) exit 1
    }
  ' "$blacklist" > "$records"; then
    rm -f "$records"
    local_registry_err "legacy blacklist Markdown is malformed: $blacklist"
    return "$TRELLIS_EX_STATE"
  fi
  while IFS=$'\t' read -r kind value reason added review_after; do
    case "$kind" in
      temporary)
        jq -cnS --arg project_id "$value" --arg reason "$reason" --arg added "$added" --arg review_after "$review_after" \
          '{project_id: $project_id, reason: $reason, added: $added, review_after: $review_after}' >> "$names_output" || {
          rm -f "$records"
          return "$TRELLIS_EX_STATE"
        }
        ;;
      permanent)
        normalized="$(local_registry_normalize_absolute_safe_path "legacy discovery-ignore path" "$value")" || {
          rm -f "$records"
          local_registry_err "legacy blacklist Markdown is malformed: $blacklist"
          return "$TRELLIS_EX_STATE"
        }
        jq -cnS --arg path "$normalized" --arg reason "$reason" '{path: $path, reason: $reason}' >> "$ignores_output" || {
          rm -f "$records"
          return "$TRELLIS_EX_STATE"
        }
        ;;
      *)
        rm -f "$records"
        local_registry_err "legacy blacklist parser produced an invalid record"
        return "$TRELLIS_EX_STATE"
        ;;
    esac
  done < "$records"
  rm -f "$records"
}

legacy_metadata() {
  local source="$1" line="$2" class="$3" services="$4" infra="$5" ports="$6" notes="$7" exclusion="$8" legacy_path="${9:-}"
  local_registry_legacy_metadata "$source" "$line" "$class" "$services" "$infra" "$ports" "$notes" "$exclusion" "$legacy_path"
}

# Import writes fleet-scoped rows, so the fleet has to be a fleet this machine
# knows about. Without this an import into a typo'd name exits 0 and leaves
# rows that `doctor --fleet NAME` then refuses to inspect at all.
require_configured_fleet() {
  local home="$1" fleet="$2" cfg configured
  cfg="$(trellis_home_config_path "$home")"
  if [ -L "$cfg" ] || [ ! -f "$cfg" ]; then
    local_registry_err "machine config not found: $cfg; run trellis fleet add $fleet --discovery-root PATH first"
    return "$TRELLIS_EX_USAGE"
  fi
  configured="$(jq -r --arg fleet "$fleet" 'if .fleets[$fleet] != null then "yes" else "no" end' "$cfg" 2>/dev/null)" || {
    local_registry_err "could not read fleets from machine config: $cfg"
    return "$TRELLIS_EX_STATE"
  }
  case "$configured" in
    yes) return 0 ;;
    no)
      local_registry_err "fleet is not configured on this machine: $fleet; run trellis fleet add $fleet --discovery-root PATH first"
      return "$TRELLIS_EX_USAGE"
      ;;
    *)
      local_registry_err "could not classify fleet membership from machine config: $cfg"
      return "$TRELLIS_EX_STATE"
      ;;
  esac
}

# True when a recorded row path is usable exactly as written. Everything else is
# shorthand as far as --projects-root is concerned.
import_row_path_is_present() {
  local path="$1"
  case "$path" in
    /*) [ -e "$path" ] ;;
    *) return 1 ;;
  esac
}

# The single answer to "does --projects-root apply to this recorded path?".
# Registry rows and blacklist §2 discovery ignores are the same kind of legacy
# record and must resolve identically, so both ask this predicate rather than
# repeating the test.
import_row_path_is_shorthand() {
  local projects_root="$1" path="$2"
  [ -n "$projects_root" ] || return 1
  ! import_row_path_is_present "$path"
}

import_resolve_recorded_path() {
  local projects_root="$1" path="$2"
  if import_row_path_is_shorthand "$projects_root" "$path"; then
    case "$path" in
      /*) path="$projects_root$path" ;;
      *) path="$projects_root/$path" ;;
    esac
  fi
  printf '%s\n' "$path"
}

# Resolves blacklist §2 discovery ignores through --projects-root exactly as the
# row loop resolves a registry row, retaining the recorded shorthand as
# `legacy_path`. Without this an import that resolved every row left its ignores
# pointing at a shorthand no scan can ever match: inert state that reads like
# working exclusion.
import_resolve_discovery_ignores() {
  local projects_root="$1" ignores_file="$2" resolved_file record path legacy resolved rc
  [ -n "$projects_root" ] || return 0
  resolved_file="$ignores_file.resolved"
  : > "$resolved_file" || return "$TRELLIS_EX_UNAVAILABLE"
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    path="$(printf '%s\n' "$record" | jq -r '.path')" || { rm -f "$resolved_file"; return "$TRELLIS_EX_STATE"; }
    legacy=""
    if import_row_path_is_shorthand "$projects_root" "$path"; then legacy="$path"; fi
    resolved="$(import_resolve_recorded_path "$projects_root" "$path")"
    resolved="$(local_registry_normalize_absolute_safe_path "legacy discovery-ignore path" "$resolved")" || {
      rc="$?"; rm -f "$resolved_file"; return "$rc"
    }
    printf '%s\n' "$record" | jq -cS --arg path "$resolved" --arg legacy "$legacy" \
      '.path = $path | if $legacy != "" then .legacy_path = $legacy else . end' >> "$resolved_file" || {
      rm -f "$resolved_file"; return "$TRELLIS_EX_STATE"
    }
  done < "$ignores_file"
  mv "$resolved_file" "$ignores_file" || { rm -f "$resolved_file"; return "$TRELLIS_EX_UNAVAILABLE"; }
}

# True when CANDIDATE is the path some legacy registry row resolves to. The
# comparison happens AFTER resolution on both sides: an ignore and a row that
# both name the same shorthand, and an ignore that resolves onto a row already
# recorded as an absolute present path, are the same contradiction and both have
# to be caught.
import_resolved_row_path_exists() {
  local projects_root="$1" candidate="$2" rows="$3" project_id path rest resolved
  while IFS=$'\t' read -r project_id path rest; do
    [ -n "$project_id" ] || continue
    resolved="$(import_resolve_recorded_path "$projects_root" "$path")"
    resolved="$(local_registry_normalize_absolute_safe_path "legacy project path" "$resolved" 2>/dev/null)" || continue
    [ "$resolved" = "$candidate" ] || continue
    return 0
  done < "$rows"
  return 1
}

cmd_import() {
  local home_opt="" fleet="" legacy="" blacklist="" projects_root="" home rows rejects blacklisted_names discovery_ignores base proposal result_file
  local project_id path legacy_path class services infra ports notes line blacklisted metadata rc=0 result_rc any_success=0 excluded ignored_path ignores_json
  local identity checkout_root common checkout_id worktree_root worktree_id reject_line reject_reason reject_rc=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --home) [ "$#" -ge 2 ] || usage_error "--home requires PATH"; home_opt="$2"; shift 2 ;;
      --fleet) [ "$#" -ge 2 ] || usage_error "--fleet requires NAME"; fleet="$2"; shift 2 ;;
      --registry) [ "$#" -ge 2 ] || usage_error "--registry requires FILE"; legacy="$2"; shift 2 ;;
      --blacklist) [ "$#" -ge 2 ] || usage_error "--blacklist requires FILE"; blacklist="$2"; shift 2 ;;
      --projects-root) [ "$#" -ge 2 ] || usage_error "--projects-root requires PATH"; projects_root="$2"; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) usage_error "unknown import option: $1" ;;
    esac
  done
  [ -n "$fleet" ] || usage_error "import requires --fleet NAME"
  [ -n "$legacy" ] || usage_error "import requires --registry FILE"
  trellis_home_require_fleet_name "$fleet" || return "$?"
  if [ -n "$projects_root" ]; then
    projects_root="$(local_registry_normalize_absolute_safe_path "projects root" "$projects_root")" || return "$?"
  fi
  home="$(local_registry_home "$home_opt")" || return "$?"
  require_configured_fleet "$home" "$fleet" || return "$?"
  rows="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.legacy.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  rejects="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.legacy-rejects.XXXXXX")" || { rm -f "$rows"; return "$TRELLIS_EX_UNAVAILABLE"; }
  blacklisted_names="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.blacklist.XXXXXX")" || { rm -f "$rows" "$rejects"; return "$TRELLIS_EX_UNAVAILABLE"; }
  discovery_ignores="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.discovery-ignores.XXXXXX")" || { rm -f "$rows" "$rejects" "$blacklisted_names"; return "$TRELLIS_EX_UNAVAILABLE"; }
  result_file="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.results.XXXXXX")" || { rm -f "$rows" "$rejects" "$blacklisted_names" "$discovery_ignores"; return "$TRELLIS_EX_UNAVAILABLE"; }
  local_registry_parse_legacy_markdown "$legacy" "$rows" "$rejects" || {
    rc="$?"; rm -f "$rows" "$rejects" "$blacklisted_names" "$discovery_ignores" "$result_file"; return "$rc"
  }
  # A rejected row is reported and costs the run its exit class, but it must not
  # abort the rows that parsed. The class is merged after the row loop so the
  # pre-loop bail-outs below keep meaning "nothing could be imported at all".
  while IFS=$'\t' read -r reject_line reject_reason; do
    [ -n "$reject_line" ] || continue
    printf 'error\t%s\t%s\n' "$legacy:$reject_line" "$reject_reason" >> "$result_file"
    reject_rc="$TRELLIS_EX_STATE"
  done < "$rejects"
  rm -f "$rejects"
  legacy_blacklist_records "$blacklist" "$blacklisted_names" "$discovery_ignores" || {
    rc="$?"; rm -f "$rows" "$blacklisted_names" "$discovery_ignores" "$result_file"; return "$rc"
  }
  import_resolve_discovery_ignores "$projects_root" "$discovery_ignores" || {
    rc="$?"; rm -f "$rows" "$blacklisted_names" "$discovery_ignores" "$result_file"; return "$rc"
  }
  while IFS= read -r excluded; do
    [ -n "$excluded" ] || continue
    project_id="$(printf '%s\n' "$excluded" | jq -r '.project_id')" || {
      rm -f "$rows" "$blacklisted_names" "$discovery_ignores" "$result_file"; return "$TRELLIS_EX_STATE"
    }
    if ! awk -F '\t' -v project="$project_id" '$1 == project { found=1 } END { exit(found ? 0 : 1) }' "$rows"; then
      local_registry_err "blacklisted project is absent from legacy registry: $project_id"
      rm -f "$rows" "$blacklisted_names" "$discovery_ignores" "$result_file"
      return "$TRELLIS_EX_STATE"
    fi
  done < "$blacklisted_names"
  while IFS= read -r metadata; do
    ignored_path="$(printf '%s\n' "$metadata" | jq -r '.path')" || {
      rm -f "$rows" "$blacklisted_names" "$discovery_ignores" "$result_file"; return "$TRELLIS_EX_STATE"
    }
    if import_resolved_row_path_exists "$projects_root" "$ignored_path" "$rows"; then
      local_registry_err "permanent discovery ignore is also present in legacy registry: $ignored_path"
      rm -f "$rows" "$blacklisted_names" "$discovery_ignores" "$result_file"
      return "$TRELLIS_EX_STATE"
    fi
  done < "$discovery_ignores"
  trellis_home_prepare_home "$home" || {
    rc="$?"; rm -f "$rows" "$blacklisted_names" "$discovery_ignores" "$result_file"; return "$rc"
  }
  trellis_home_lock_acquire "$home" registry 30 || {
    rc="$?"; rm -f "$rows" "$blacklisted_names" "$discovery_ignores" "$result_file"; return "$rc"
  }
  base="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.base.XXXXXX")" || {
    trellis_home_lock_release >/dev/null 2>&1 || true
    rm -f "$rows" "$blacklisted_names" "$discovery_ignores" "$result_file"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  proposal="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.import.XXXXXX")" || {
    rm -f "$base" "$rows" "$blacklisted_names" "$discovery_ignores" "$result_file"
    trellis_home_lock_release >/dev/null 2>&1 || true
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  local_registry_load "$home" "$base" || rc="$?"
  if [ "$rc" -eq 0 ] && [ -n "$blacklist" ]; then
    ignores_json="$(jq -scS '.' "$discovery_ignores")" || rc="$TRELLIS_EX_STATE"
    if [ "$rc" -eq 0 ]; then
      local_registry_propose_discovery_ignores "$base" "$proposal" "$fleet" "$ignores_json" || rc="$?"
    fi
    [ "$rc" -ne 0 ] || any_success=1
  elif [ "$rc" -eq 0 ]; then
    cp "$base" "$proposal" || rc="$TRELLIS_EX_UNAVAILABLE"
  fi
  if [ "$rc" -ne 0 ]; then
    trellis_home_lock_release >/dev/null 2>&1
    result_rc="$?"
    rc="$(highest_exit "$rc" "$result_rc")"
    rm -f "$rows" "$blacklisted_names" "$discovery_ignores" "$result_file" "$base" "$proposal"
    return "$rc"
  fi
  while IFS=$'\t' read -r project_id path class services infra ports notes line; do
    local_registry_require_project_id "$project_id" || { result_rc="$?"; printf 'error\t%s\t%s\n' "$project_id" "$path" >> "$result_file"; rc="$(highest_exit "$rc" "$result_rc")"; continue; }
    legacy_path=""
    if import_row_path_is_shorthand "$projects_root" "$path"; then legacy_path="$path"; fi
    path="$(import_resolve_recorded_path "$projects_root" "$path")"
    path="$(local_registry_normalize_absolute_safe_path "legacy project path" "$path")" || { result_rc="$?"; printf 'error\t%s\t%s\n' "$project_id" "$path" >> "$result_file"; rc="$(highest_exit "$rc" "$result_rc")"; continue; }
    blacklisted="$(jq -sc --arg project "$project_id" 'map(select(.project_id == $project))[0] // null' "$blacklisted_names")" || {
      result_rc="$TRELLIS_EX_STATE"; printf 'error\t%s\t%s\n' "$project_id" "$path" >> "$result_file"; rc="$(highest_exit "$rc" "$result_rc")"; continue
    }
    metadata="$(legacy_metadata "$legacy" "$line" "$class" "$services" "$infra" "$ports" "$notes" "$blacklisted" "$legacy_path")" || { result_rc="$?"; printf 'error\t%s\t%s\n' "$project_id" "$path" >> "$result_file"; rc="$(highest_exit "$rc" "$result_rc")"; continue; }
    if [ -d "$path" ]; then
      identity="$(local_registry_identity_for_root "$path")"
      result_rc="$?"
      if [ "$result_rc" -eq 0 ]; then
        checkout_root="$(printf '%s\n' "$identity" | jq -r '.checkout_root')"
        common="$(printf '%s\n' "$identity" | jq -r '.git_common_dir')"
        checkout_id="$(printf '%s\n' "$identity" | jq -r '.checkout_id')"
        worktree_root="$(printf '%s\n' "$identity" | jq -r '.root')"
        worktree_id="$(printf '%s\n' "$identity" | jq -r '.worktree_id')"
        local_registry_propose_register_worktree "$proposal" "$proposal.next" "$fleet" "$project_id" "$checkout_root" "$common" "$checkout_id" "$worktree_root" "$worktree_id" "" '[]' "" "$metadata"
        result_rc="$?"
        if [ "$result_rc" -eq 0 ]; then mv "$proposal.next" "$proposal"; fi
      fi
    else
      local_registry_propose_unavailable_root "$proposal" "$proposal.next" "$fleet" "$project_id" "$path" "$metadata"
      result_rc="$?"
      if [ "$result_rc" -eq 0 ]; then mv "$proposal.next" "$proposal"; fi
    fi
    if [ "$result_rc" -eq 0 ]; then
      printf 'ok\t%s\t%s\n' "$project_id" "$path" >> "$result_file"
      any_success=1
    else
      rm -f "$proposal.next"
      printf 'error\t%s\t%s\n' "$project_id" "$path" >> "$result_file"
      rc="$(highest_exit "$rc" "$result_rc")"
    fi
  done < "$rows"
  rc="$(highest_exit "$rc" "$reject_rc")"
  if [ "$any_success" -eq 1 ]; then
    local_registry_write_locked "$home" "$proposal" || rc="$(highest_exit "$rc" "$?")"
  fi
  trellis_home_lock_release >/dev/null 2>&1
  result_rc="$?"
  rc="$(highest_exit "$rc" "$result_rc")"
  LC_ALL=C sort "$result_file" || rc="$(highest_exit "$rc" "$TRELLIS_EX_UNAVAILABLE")"
  rm -f "$rows" "$blacklisted_names" "$discovery_ignores" "$result_file" "$base" "$proposal" "$proposal.next"
  return "$rc"
}

find_path_literal_pattern() {
  local pattern="${1:-}"
  pattern="${pattern//\\/\\\\}"
  pattern="${pattern//\*/\\*}"
  pattern="${pattern//\?/\\?}"
  pattern="${pattern//\[/\\[}"
  pattern="${pattern//\]/\\]}"
  printf '%s\n' "$pattern"
}

# Directory names a rebuild scan never descends into. They are dependency and
# version-control payload, never a place a portable project manifest can be the
# manifest OF a project: a `.trellis.json` under one of these belongs to a
# vendored copy, not to an inventory row. Pruning them is what keeps the scan
# bounded on a real tree — an unpruned full-tree find over a working projects
# root walks every node_modules on the machine and was measured timing out.
REBUILD_PRUNE_NAMES=( .git node_modules vendor )

# Maximum directory depth BELOW a selected root at which a manifest is
# discovered, when --max-depth is not given. `<root>/<project>/.trellis.json` is
# depth 1 and `<root>/<group>/<project>/.claude/worktrees/<name>/.trellis.json`
# is depth 5, so the default covers the layouts this migration documents while
# still refusing an unbounded walk.
REBUILD_MAX_DEPTH_DEFAULT=6

rebuild_progress() {
  local progress="$1"
  shift
  [ "$progress" = on ] || return 0
  printf 'trellis registry: %s\n' "$*" >&2
}

rebuild_candidates() {
  local output="$1" state="$2" fleet="$3" max_depth="$4" progress="$5"
  shift 5
  local root manifest project_root project_id identity checkout_root common checkout_id worktree_id metadata
  local found safe sorted ignores ignore ignore_pattern skip rc name count
  local -a prune_args=()
  trellis_home_require_fleet_name "$fleet" || return "$?"
  case "$max_depth" in
    ''|*[!0-9]*) local_registry_err "rebuild max depth must be a positive integer: $max_depth"; return "$TRELLIS_EX_USAGE" ;;
  esac
  if [ "$max_depth" -lt 1 ] || [ "$max_depth" -gt 64 ]; then
    local_registry_err "rebuild max depth must be between 1 and 64: $max_depth"
    return "$TRELLIS_EX_USAGE"
  fi
  case "$progress" in on|off) ;; *) local_registry_err "invalid rebuild progress mode: $progress"; return "$TRELLIS_EX_USAGE" ;; esac
  ignores="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.rebuild-ignores.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  if ! jq -r --arg fleet "$fleet" '.discovery_ignores[$fleet] // [] | .[].path' "$state" > "$ignores"; then
    rm -f "$ignores"
    local_registry_err "could not read discovery ignores for rebuild fleet: $fleet"
    return "$TRELLIS_EX_STATE"
  fi
  : > "$output" || { rm -f "$ignores"; return "$TRELLIS_EX_UNAVAILABLE"; }
  for root in "$@"; do
    root="$(local_registry_real_directory "rebuild root" "$root")" || { rc="$?"; rm -f "$ignores"; return "$rc"; }
    found="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.found.XXXXXX")" || { rm -f "$ignores"; return "$TRELLIS_EX_UNAVAILABLE"; }
    safe="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.safe.XXXXXX")" || { rm -f "$ignores" "$found"; return "$TRELLIS_EX_UNAVAILABLE"; }
    sorted="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.sorted.XXXXXX")" || { rm -f "$ignores" "$found" "$safe"; return "$TRELLIS_EX_UNAVAILABLE"; }
    # One prune group holds both bounds: the fixed dependency/VCS directory
    # names and this fleet's discovery ignores that fall under this root.
    prune_args=( '(' )
    for name in "${REBUILD_PRUNE_NAMES[@]}"; do
      if [ "${#prune_args[@]}" -gt 1 ]; then prune_args+=( -o ); fi
      prune_args+=( -name "$name" )
    done
    while IFS= read -r ignore; do
      case "$ignore/" in
        "$root/"*)
          ignore_pattern="$(find_path_literal_pattern "$ignore")" || {
            rm -f "$ignores" "$found" "$safe" "$sorted"; return "$TRELLIS_EX_STATE"
          }
          prune_args+=( -o -path "$ignore_pattern" )
          ;;
      esac
    done < "$ignores"
    prune_args+=( ')' -prune -o )
    rc=0
    rebuild_progress "$progress" "scanning $root (max depth $max_depth)"
    # `-mindepth 1` keeps the selected root itself out of the prune group: a
    # root that is legitimately named `vendor` would otherwise prune itself and
    # report an empty, entirely believable scan. A manifest is a file, so it can
    # never sit at depth 0 and nothing discoverable is lost. The file lives one
    # level below its project directory, hence max_depth + 1.
    find -P "$root" -mindepth 1 -maxdepth "$((max_depth + 1))" \
      "${prune_args[@]}" -type f -name .trellis.json -print0 > "$found" || rc="$?"
    if [ "$rc" -ne 0 ]; then
      rm -f "$ignores" "$found" "$safe" "$sorted"
      local_registry_err "could not scan selected rebuild root: $root"
      return "$TRELLIS_EX_UNAVAILABLE"
    fi
    while IFS= read -r -d '' manifest; do
      skip=0
      while IFS= read -r ignore; do
        case "$manifest" in "$ignore"|"$ignore"/*) skip=1; break ;; esac
      done < "$ignores"
      [ "$skip" -eq 0 ] || continue
      local_registry_require_absolute_safe_path "discovered project manifest" "$manifest" || {
        rc="$?"; rm -f "$ignores" "$found" "$safe" "$sorted"; return "$rc"
      }
      printf '%s\n' "$manifest" >> "$safe" || { rm -f "$ignores" "$found" "$safe" "$sorted"; return "$TRELLIS_EX_UNAVAILABLE"; }
      rebuild_progress "$progress" "found $manifest"
    done < "$found"
    count="$(LC_ALL=C awk 'END { print NR }' "$safe")" || count="?"
    rebuild_progress "$progress" "scanned $root: $count manifest(s)"
    if ! LC_ALL=C sort "$safe" > "$sorted"; then
      rm -f "$ignores" "$found" "$safe" "$sorted"
      local_registry_err "could not sort selected rebuild candidates: $root"
      return "$TRELLIS_EX_UNAVAILABLE"
    fi
    while IFS= read -r manifest; do
      project_root="$(dirname "$manifest")"
      project_id="$(local_registry_manifest_project_id "$manifest")" || { rc="$?"; rm -f "$ignores" "$found" "$safe" "$sorted"; return "$rc"; }
      identity="$(local_registry_identity_for_root "$project_root")" || { rc="$?"; rm -f "$ignores" "$found" "$safe" "$sorted"; return "$rc"; }
      checkout_root="$(printf '%s\n' "$identity" | jq -r '.checkout_root')"
      common="$(printf '%s\n' "$identity" | jq -r '.git_common_dir')"
      checkout_id="$(printf '%s\n' "$identity" | jq -r '.checkout_id')"
      worktree_id="$(printf '%s\n' "$identity" | jq -r '.worktree_id')"
      metadata="$(jq -n -cS --arg manifest "$manifest" '{rebuild: {manifest: $manifest}}')" || {
        rm -f "$ignores" "$found" "$safe" "$sorted"; return "$TRELLIS_EX_STATE"
      }
      jq -n -cS --arg project_id "$project_id" --arg checkout_root "$checkout_root" --arg common "$common" --arg checkout_id "$checkout_id" --arg worktree_root "$project_root" --arg worktree_id "$worktree_id" --argjson metadata "$metadata" '{project_id: $project_id, checkout_root: $checkout_root, git_common_dir: $common, checkout_id: $checkout_id, worktree_root: $worktree_root, worktree_id: $worktree_id, metadata: $metadata}' >> "$output" || {
        rm -f "$ignores" "$found" "$safe" "$sorted"; return "$TRELLIS_EX_STATE"
      }
    done < "$sorted"
    rm -f "$found" "$safe" "$sorted"
  done
  rm -f "$ignores"
}

cmd_rebuild() {
  local home_opt="" fleet="" apply=0 home state candidates filtered preview base proposal candidate project_id checkout_root common checkout_id worktree_root worktree_id metadata rc=0 result_rc
  local max_depth="$REBUILD_MAX_DEPTH_DEFAULT" progress=auto
  local -a roots=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --home) [ "$#" -ge 2 ] || usage_error "--home requires PATH"; home_opt="$2"; shift 2 ;;
      --fleet) [ "$#" -ge 2 ] || usage_error "--fleet requires NAME"; fleet="$2"; shift 2 ;;
      --max-depth) [ "$#" -ge 2 ] || usage_error "--max-depth requires N"; max_depth="$2"; shift 2 ;;
      --progress) progress=on; shift ;;
      --no-progress) progress=off; shift ;;
      --apply) apply=1; shift ;;
      -h|--help) usage; return 0 ;;
      --) shift; while [ "$#" -gt 0 ]; do roots+=("$1"); shift; done ;;
      --*) usage_error "unknown rebuild option: $1" ;;
      *) roots+=("$1"); shift ;;
    esac
  done
  # A scan long enough to need progress is exactly the one whose output an
  # operator is watching, so the default follows the terminal. Machine consumers
  # of the preview JSON read stdout and are never affected either way; a logged
  # unattended run asks for `--progress` explicitly.
  if [ "$progress" = auto ]; then
    if [ -t 2 ]; then progress=on; else progress=off; fi
  fi
  [ -n "$fleet" ] || usage_error "rebuild requires --fleet NAME"
  [ "${#roots[@]}" -gt 0 ] || usage_error "rebuild requires one or more selected ROOT values"
  trellis_home_require_fleet_name "$fleet" || return "$?"
  home="$(local_registry_home "$home_opt")" || return "$?"
  state="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.state.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  local_registry_read_state "$home" > "$state" || { rc="$?"; rm -f "$state"; return "$rc"; }
  candidates="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.rebuild.XXXXXX")" || { rm -f "$state"; return "$TRELLIS_EX_UNAVAILABLE"; }
  filtered="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.rebuild-filtered.XXXXXX")" || { rm -f "$state" "$candidates"; return "$TRELLIS_EX_UNAVAILABLE"; }
  rebuild_candidates "$candidates" "$state" "$fleet" "$max_depth" "$progress" "${roots[@]}" || { rc="$?"; rm -f "$state" "$candidates" "$filtered"; return "$rc"; }
  if ! jq -c --arg fleet "$fleet" --slurpfile state "$state" '
    .worktree_root as $root
    | ($state[0].discovery_ignores[$fleet] // [] | map(.path)) as $ignored
    | select(($ignored | index($root)) == null)
  ' "$candidates" > "$filtered"; then
    rm -f "$state" "$candidates" "$filtered"
    local_registry_err "could not apply discovery ignores to rebuild candidates"
    return "$TRELLIS_EX_STATE"
  fi
  mv "$filtered" "$candidates" || { rm -f "$state" "$candidates" "$filtered"; return "$TRELLIS_EX_UNAVAILABLE"; }
  if ! jq -s -e '([.[].project_id] | length) == ([.[].project_id] | unique | length)' "$candidates" >/dev/null; then
    rm -f "$state" "$candidates"; local_registry_err "rebuild found duplicate project IDs in selected roots"; return "$TRELLIS_EX_CONFLICT"
  fi
  preview="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.preview.XXXXXX")" || { rm -f "$state" "$candidates"; return "$TRELLIS_EX_UNAVAILABLE"; }
  jq -s -S --arg fleet "$fleet" '{action: "rebuild", fleet: $fleet, apply_required: true, candidates: sort_by(.project_id, .worktree_root)}' "$candidates" > "$preview" || {
    rm -f "$state" "$candidates" "$preview"; return "$TRELLIS_EX_STATE"
  }
  if [ "$apply" -eq 0 ]; then
    jq -S . "$preview"
    rc="$?"
    rm -f "$state" "$candidates" "$preview"
    return "$rc"
  fi
  trellis_home_prepare_home "$home" || { rc="$?"; rm -f "$state" "$candidates" "$preview"; return "$rc"; }
  trellis_home_lock_acquire "$home" registry 30 || { rc="$?"; rm -f "$state" "$candidates" "$preview"; return "$rc"; }
  base="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.base.XXXXXX")" || {
    trellis_home_lock_release >/dev/null 2>&1 || true
    rm -f "$state" "$candidates" "$preview"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  proposal="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.rebuild.apply.XXXXXX")" || {
    rm -f "$base" "$state" "$candidates" "$preview"
    trellis_home_lock_release >/dev/null 2>&1 || true
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  local_registry_load "$home" "$base" || rc="$?"
  if [ "$rc" -eq 0 ]; then cp "$base" "$proposal" || rc="$TRELLIS_EX_UNAVAILABLE"; fi
  while IFS= read -r candidate; do
    [ "$rc" -eq 0 ] || break
    project_id="$(printf '%s\n' "$candidate" | jq -r '.project_id')"
    checkout_root="$(printf '%s\n' "$candidate" | jq -r '.checkout_root')"
    common="$(printf '%s\n' "$candidate" | jq -r '.git_common_dir')"
    checkout_id="$(printf '%s\n' "$candidate" | jq -r '.checkout_id')"
    worktree_root="$(printf '%s\n' "$candidate" | jq -r '.worktree_root')"
    worktree_id="$(printf '%s\n' "$candidate" | jq -r '.worktree_id')"
    metadata="$(printf '%s\n' "$candidate" | jq -c '.metadata')"
    local_registry_propose_register_worktree "$proposal" "$proposal.next" "$fleet" "$project_id" "$checkout_root" "$common" "$checkout_id" "$worktree_root" "$worktree_id" "" '[]' "" "$metadata" || rc="$?"
    if [ "$rc" -eq 0 ]; then mv "$proposal.next" "$proposal"; else rm -f "$proposal.next"; fi
  done < "$candidates"
  if [ "$rc" -eq 0 ]; then local_registry_write_locked "$home" "$proposal" || rc="$?"; fi
  trellis_home_lock_release >/dev/null 2>&1
  result_rc="$?"
  rc="$(highest_exit "$rc" "$result_rc")"
  if [ "$rc" -eq 0 ]; then jq -S '. + {applied: true}' "$preview"; fi
  rm -f "$state" "$candidates" "$preview" "$base" "$proposal" "$proposal.next"
  return "$rc"
}

# Machine-local metadata setter for an already-registered row. It exists because
# machine-local facts a migrated project can no longer track — per-project gptx
# routing being the case that forced it — need a home that survives migration,
# and registry row metadata is that home: private, mode-0600, and never tracked.
cmd_annotate() {
  local home_opt="" fleet="" project="" metadata="" home
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --home) [ "$#" -ge 2 ] || usage_error "--home requires PATH"; home_opt="$2"; shift 2 ;;
      --fleet) [ "$#" -ge 2 ] || usage_error "--fleet requires NAME"; fleet="$2"; shift 2 ;;
      --project) [ "$#" -ge 2 ] || usage_error "--project requires NAME"; project="$2"; shift 2 ;;
      --metadata-json) [ "$#" -ge 2 ] || usage_error "--metadata-json requires JSON"; metadata="$2"; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) usage_error "unknown annotate option: $1" ;;
    esac
  done
  [ -n "$fleet" ] || usage_error "annotate requires --fleet NAME"
  [ -n "$project" ] || usage_error "annotate requires --project NAME"
  [ -n "$metadata" ] || usage_error "annotate requires --metadata-json JSON"
  trellis_home_require_fleet_name "$fleet" || return "$?"
  local_registry_require_project_id "$project" || return "$?"
  if ! printf '%s\n' "$metadata" | jq -e 'type == "object"' >/dev/null 2>&1; then
    usage_error "--metadata-json must be a JSON object"
  fi
  home="$(local_registry_home "$home_opt")" || return "$?"
  require_configured_fleet "$home" "$fleet" || return "$?"
  local_registry_set_metadata "$home" "$fleet" "$project" "$metadata"
}

main() {
  local command="${1:-}"
  case "$command" in
    import) shift; cmd_import "$@" ;;
    list) shift; cmd_list "$@" ;;
    rebuild) shift; cmd_rebuild "$@" ;;
    annotate) shift; cmd_annotate "$@" ;;
    -h|--help|help|'') usage ;;
    *) usage_error "unknown command: $command" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
