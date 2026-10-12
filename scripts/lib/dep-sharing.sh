#!/usr/bin/env bash
# dep-sharing.sh — doctor rows for dependency sharing across worktrees (spec
# 069 B1-B3). Owned by lane L-B (tasks B.1-B.3); L-0 ships the empty stub.
#
# hc_dep_sharing_rows USER_HOME TRELLIS_HOME FIX_MODE
#
# Follows the row contract documented in worktree-layout.sh: `STATUS<TAB>MESSAGE`
# lines on stdout, FIX_MODE off|dry-run|apply, never exits the caller, returns 0.
#
# This library reports the pnpm global virtual store (user-level
# enableGlobalVirtualStore:true, honoured by every fleet pin per EVIDENCE.md
# P1), registered projects pinned below pnpm 10.12.1, project-level opt-outs
# that block the user-level setting, dependency build scripts that write into
# shared package dirs (spec B2), uv link-mode copy overrides and whether the
# uv cache shares a volume with the projects. Under FIX_MODE dry-run it prints
# the repair plan; under apply it runs `pnpm config set --location=global
# enableGlobalVirtualStore true` and reports the resulting state. A
# project-scoped doctor run (ONLY_PROJECT set) never writes the global setting.
#
# Tool lookup honours the sanitized doctor PATH: pnpm and uv are resolved from
# TRELLIS_ATTACH_CALLER_PATH, then the disk-janitor tool-path file under
# TRELLIS_HOME, then PATH. Every pnpm and uv invocation runs with PATH set to
# the caller PATH (the resolved binary's dir prepended) so env-shebang tools
# find their runtime, without exporting it into the doctor process. Every pnpm
# invocation runs with --dir at a neutral temp dir so a project's packageManager
# pin cannot switch versions during detection. All home-relative paths come from USER_HOME, never the ambient
# environment, so fixtures stay hermetic.
#
# bash 3.2 compatible: no [[ ]], no associative arrays, no mapfile.

if [ -z "${HC_OK:-}" ]; then
  HC_OK=0
fi
if [ -z "${HC_ERROR:-}" ]; then
  HC_ERROR=1
fi
if [ -z "${HC_WARN:-}" ]; then
  HC_WARN=2
fi
if [ -z "${HC_INFO:-}" ]; then
  HC_INFO=3
fi

# Floor for user-level enableGlobalVirtualStore:true (EVIDENCE.md P1: honoured
# by 11.9.0, 11.17.0 and 11.23.0; below 10.12.1 it does not exist).
DEP_SHARING_PNPM_EGVS_MIN='10.12.1'
DEP_SHARING_PNPM_SETTING='enableGlobalVirtualStore'
DEP_SHARING_PNPM_VALUE='true'

# _dep_sharing_cmp <left> <right> — compare dotted X.Y.Z numerically.
# Prints -1, 0 or 1. Non-numeric cores compare as -1 (unsupported).
_dep_sharing_cmp() {
  local left="${1:-}" right="${2:-}" lmaj lmin lpat rmaj rmin rpat
  left="${left#v}"
  right="${right#v}"
  left="${left%%[-+]*}"
  right="${right%%[-+]*}"
  case "$left" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) printf '%s' '-1'; return 0 ;;
  esac
  case "$right" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) printf '%s' '-1'; return 0 ;;
  esac
  lmaj="${left%%.*}"; left="${left#*.}"
  lmin="${left%%.*}"; lpat="${left#*.}"; lpat="${lpat%%.*}"
  rmaj="${right%%.*}"; right="${right#*.}"
  rmin="${right%%.*}"; rpat="${right#*.}"; rpat="${rpat%%.*}"
  if [ "$lmaj" -lt "$rmaj" ] 2>/dev/null; then printf '%s' '-1'; return 0; fi
  if [ "$lmaj" -gt "$rmaj" ] 2>/dev/null; then printf '%s' '1'; return 0; fi
  if [ "$lmin" -lt "$rmin" ] 2>/dev/null; then printf '%s' '-1'; return 0; fi
  if [ "$lmin" -gt "$rmin" ] 2>/dev/null; then printf '%s' '1'; return 0; fi
  if [ "$lpat" -lt "$rpat" ] 2>/dev/null; then printf '%s' '-1'; return 0; fi
  if [ "$lpat" -gt "$rpat" ] 2>/dev/null; then printf '%s' '1'; return 0; fi
  printf '%s' '0'
}

# _dep_sharing_resolve_tool NAME TRELLIS_HOME — print the absolute path of the
# tool, searching TRELLIS_ATTACH_CALLER_PATH first (the caller's toolchain,
# forwarded by the launcher for the doctor route), then the installer's
# tool-path file, then PATH. Returns 1 when not found.
_dep_sharing_resolve_tool() {
  local name="${1:-}" trellis_home="${2:-}" dir path saved_ifs
  if [ -z "$name" ]; then
    return 1
  fi
  if [ -n "${TRELLIS_ATTACH_CALLER_PATH:-}" ]; then
    saved_ifs="$IFS"
    IFS=:
    for dir in $TRELLIS_ATTACH_CALLER_PATH; do
      IFS="$saved_ifs"
      case "$dir" in
        ''|*:*) ;;
        *)
          if [ -f "$dir/$name" ] && [ -x "$dir/$name" ]; then
            printf '%s\n' "$dir/$name"
            IFS="$saved_ifs"
            return 0
          fi
          ;;
      esac
      IFS=:
    done
    IFS="$saved_ifs"
  fi
  if [ -n "$trellis_home" ] && [ -f "$trellis_home/state/disk-janitor/tool-path" ]; then
    while IFS= read -r dir || [ -n "$dir" ]; do
      case "$dir" in
        /*:*|'') continue ;;
        /*)
          if [ -f "$dir/$name" ] && [ -x "$dir/$name" ]; then
            printf '%s\n' "$dir/$name"
            return 0
          fi
          ;;
      esac
    done <"$trellis_home/state/disk-janitor/tool-path"
  fi
  if path="$(command -v "$name" 2>/dev/null)"; then
    case "$path" in
      */*)
        printf '%s\n' "$path"
        return 0
        ;;
    esac
  fi
  return 1
}

# _dep_sharing_exec_path BIN — print the PATH to use when executing BIN.
# The launcher sanitizes PATH to /usr/bin:/bin:/usr/sbin:/sbin, but a tool
# resolved from TRELLIS_ATTACH_CALLER_PATH (e.g. an nvm pnpm whose shebang is
# #!/usr/bin/env node) needs the caller's toolchain at exec time. Prepend the
# binary's dir to the caller PATH when set, else to the ambient PATH. Callers
# use it as a per-invocation prefix (PATH="..." HOME="..." "$bin" ...),
# so the doctor process itself keeps its sanitized PATH.
_dep_sharing_exec_path() {
  local bin="${1:-}" dir base_path
  dir="${bin%/*}"
  case "$bin" in
    */*) ;;
    *)
      dir=""
      ;;
  esac
  if [ -n "${TRELLIS_ATTACH_CALLER_PATH:-}" ]; then
    base_path="$TRELLIS_ATTACH_CALLER_PATH"
  else
    base_path="$PATH"
  fi
  if [ -z "$dir" ] || [ "$dir" = "$bin" ]; then
    printf '%s\n' "$base_path"
    return 0
  fi
  case ":$base_path:" in
    *":$dir:"*)
      printf '%s\n' "$base_path"
      ;;
    *)
      printf '%s\n' "$dir:$base_path"
      ;;
  esac
}

# _dep_sharing_pnpm_version PNPM_BIN NEUTRAL_DIR USER_HOME — print X.Y.Z.
_dep_sharing_pnpm_version() {
  local bin="$1" neutral="${2:-}" user_home="${3:-}" raw version exec_path
  if [ -z "$bin" ]; then
    return 1
  fi
  exec_path="$(_dep_sharing_exec_path "$bin")"
  if [ -n "$neutral" ]; then
    raw="$(PATH="$exec_path" HOME="$user_home" "$bin" --dir "$neutral" --version </dev/null 2>/dev/null)" || return 1
  else
    raw="$(PATH="$exec_path" HOME="$user_home" "$bin" --version </dev/null 2>/dev/null)" || return 1
  fi
  version="$(printf '%s\n' "$raw" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)" || return 1
  [ -n "$version" ] || return 1
  printf '%s\n' "$version"
}

# _dep_sharing_pnpm_get PNPM_BIN NEUTRAL_DIR USER_HOME — print the raw global
# value of enableGlobalVirtualStore (first line, whitespace stripped).
_dep_sharing_pnpm_get() {
  local bin="$1" neutral="${2:-}" user_home="${3:-}" raw exec_path
  if [ -z "$bin" ]; then
    return 1
  fi
  exec_path="$(_dep_sharing_exec_path "$bin")"
  if [ -n "$neutral" ]; then
    raw="$(PATH="$exec_path" HOME="$user_home" "$bin" --dir "$neutral" config get --location=global "$DEP_SHARING_PNPM_SETTING" </dev/null 2>/dev/null | head -n 1 | tr -d '[:space:]')" || raw=""
  else
    raw="$(PATH="$exec_path" HOME="$user_home" "$bin" config get --location=global "$DEP_SHARING_PNPM_SETTING" </dev/null 2>/dev/null | head -n 1 | tr -d '[:space:]')" || raw=""
  fi
  printf '%s\n' "$raw"
}

# _dep_sharing_uv_cache_dir UV_BIN USER_HOME — print `uv cache dir`.
_dep_sharing_uv_cache_dir() {
  local bin="$1" user_home="${2:-}" dir exec_path
  if [ -z "$bin" ]; then
    return 1
  fi
  exec_path="$(_dep_sharing_exec_path "$bin")"
  dir="$(PATH="$exec_path" HOME="$user_home" "$bin" cache dir </dev/null 2>/dev/null | head -n 1)" || return 1
  [ -n "$dir" ] || return 1
  printf '%s\n' "$dir"
}

# _dep_sharing_dev <path> — print the device number holding <path>.
_dep_sharing_dev() {
  local path="$1" dev
  if dev="$(stat -f %d "$path" 2>/dev/null)"; then
    printf '%s\n' "$dev"
    return 0
  fi
  if dev="$(stat -c %d "$path" 2>/dev/null)"; then
    printf '%s\n' "$dev"
    return 0
  fi
  return 1
}

# _dep_sharing_has_copy_link <file> — true when a uv config file sets
# link-mode to copy (any quoting, trailing comment tolerated).
_dep_sharing_has_copy_link() {
  local file="$1"
  [ -f "$file" ] || return 1
  grep -Eq '^[[:space:]]*link-mode[[:space:]]*=[[:space:]]*["'"'"']?copy["'"'"']?' "$file" 2>/dev/null
}

# _dep_sharing_ws_opt_out <worktree-root> — true when pnpm-workspace.yaml sets
# enableGlobalVirtualStore:false, which beats the user-level setting.
_dep_sharing_ws_opt_out() {
  local root="$1"
  [ -f "$root/pnpm-workspace.yaml" ] || return 1
  grep -Eq '^[[:space:]]*enableGlobalVirtualStore[[:space:]]*:[[:space:]]*false([[:space:]#]|$)' "$root/pnpm-workspace.yaml" 2>/dev/null
}

# _dep_sharing_has_dep_builds <worktree-root> — true when dependency build
# scripts may write into shared package dirs: package.json
# pnpm.onlyBuiltDependencies is a non-empty array, or pnpm-workspace.yaml
# names onlyBuiltDependencies/allowBuilds. Root lifecycle scripts
# (postinstall/prepare in the project's own package.json) are deliberately
# ignored: they write into the project, not into packages (EVIDENCE.md P2).
_dep_sharing_has_dep_builds() {
  local root="$1" pkg="$1/package.json" ws="$1/pnpm-workspace.yaml"
  if [ -f "$pkg" ] && command -v jq >/dev/null 2>&1; then
    if jq -e '.pnpm.onlyBuiltDependencies | type == "array" and length > 0' "$pkg" >/dev/null 2>&1; then
      return 0
    fi
  fi
  if [ -f "$ws" ]; then
    if grep -Eq '^[[:space:]]*onlyBuiltDependencies[[:space:]]*:' "$ws" 2>/dev/null; then
      return 0
    fi
    if grep -Eq '^[[:space:]]*allowBuilds' "$ws" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

# hc_dep_sharing_rows USER_HOME TRELLIS_HOME FIX_MODE — STATUS<TAB>message rows
# for doctor. Always returns 0. FIX_MODE off is read-only; dry-run prints the
# repair plan without changing anything; apply performs the bounded user-level
# pnpm write and reports the resulting state.
hc_dep_sharing_rows() {
  local user_home="${1:-}" trellis_home="${2:-}" fix_mode="${3:-off}"
  local tab neutral pnpm_bin uv_bin version current only_project exec_path
  local cache_dir dev_cache dev_projects project_rows proj_key proj_root pm pin pin_ver
  tab="$(printf '\t')"
  if [ -z "$user_home" ]; then
    user_home="${HOME:-}"
  fi
  case "$fix_mode" in
    off|dry-run|apply) ;;
    *)
      printf '%s\t%s\n' "$HC_WARN" "dep-sharing: bad FIX_MODE '$fix_mode' (want off|dry-run|apply)"
      return 0
      ;;
  esac
  only_project="${ONLY_PROJECT:-}"

  neutral="$(mktemp -d "${TMPDIR:-/tmp}/dep-sharing-pnpm.XXXXXX" 2>/dev/null)" || neutral=""

  if pnpm_bin="$(_dep_sharing_resolve_tool pnpm "$trellis_home")"; then
    :
  else
    pnpm_bin=""
  fi
  if uv_bin="$(_dep_sharing_resolve_tool uv "$trellis_home")"; then
    :
  else
    uv_bin=""
  fi

  # --- pnpm global virtual store (B1): always enableGlobalVirtualStore:true ---
  version=""
  current=""
  if [ -z "$pnpm_bin" ]; then
    printf '%s\t%s\n' "$HC_INFO" 'pnpm not found (searched TRELLIS_ATTACH_CALLER_PATH, the disk-janitor tool-path file and PATH); dependency sharing unverified'
  elif ! version="$(_dep_sharing_pnpm_version "$pnpm_bin" "$neutral" "$user_home")"; then
    printf '%s\t%s\n' "$HC_INFO" 'pnpm version unreadable; the global virtual store floor is unverified'
  elif [ "$(_dep_sharing_cmp "$version" "$DEP_SHARING_PNPM_EGVS_MIN")" = '-1' ]; then
    printf '%s\t%s\n' "$HC_WARN" "pnpm $version is below $DEP_SHARING_PNPM_EGVS_MIN; user-level $DEP_SHARING_PNPM_SETTING:true is unsupported (not shared, not upgraded)"
    version=""
  else
    current="$(_dep_sharing_pnpm_get "$pnpm_bin" "$neutral" "$user_home")" || current=""
    if [ "$current" = "$DEP_SHARING_PNPM_VALUE" ]; then
      : # on: silent, like the other healthy host rows.
    else
      printf '%s\t%s\n' "$HC_WARN" "pnpm global virtual store is off ($DEP_SHARING_PNPM_SETTING is '${current:-unset}', want '$DEP_SHARING_PNPM_VALUE'); remedy: trellis doctor --fix sets 'pnpm config set --location=global $DEP_SHARING_PNPM_SETTING $DEP_SHARING_PNPM_VALUE'"
    fi
  fi

  # --- bounded repair lives in this function (L-0 contract): dry-run plans,
  # apply writes, a project-scoped run never writes the global setting ---
  if [ "$fix_mode" = "dry-run" ] && [ -n "$version" ] && [ "$current" != "$DEP_SHARING_PNPM_VALUE" ]; then
    if [ -n "$only_project" ]; then
      printf '%s\t%s\n' "$HC_INFO" "dep-sharing fix deferred: project-scoped run (--project $only_project) does not write the user-level pnpm setting; run trellis doctor --fix without --project to apply it"
    else
      printf '%s\t%s\n' "$HC_INFO" "dep-sharing fix: would run: pnpm config set --location=global $DEP_SHARING_PNPM_SETTING $DEP_SHARING_PNPM_VALUE (pnpm $version)"
    fi
  fi
  if [ "$fix_mode" = "apply" ] && [ -n "$version" ] && [ "$current" != "$DEP_SHARING_PNPM_VALUE" ]; then
    if [ -n "$only_project" ]; then
      printf '%s\t%s\n' "$HC_INFO" "dep-sharing fix deferred: project-scoped run (--project $only_project) does not write the user-level pnpm setting; run trellis doctor --fix without --project to apply it"
    else
      if [ -n "$neutral" ]; then
        exec_path="$(_dep_sharing_exec_path "$pnpm_bin")"
        if PATH="$exec_path" HOME="$user_home" "$pnpm_bin" --dir "$neutral" config set --location=global "$DEP_SHARING_PNPM_SETTING" "$DEP_SHARING_PNPM_VALUE" </dev/null >/dev/null 2>&1; then
          current="$(_dep_sharing_pnpm_get "$pnpm_bin" "$neutral" "$user_home")" || current=""
          if [ "$current" = "$DEP_SHARING_PNPM_VALUE" ]; then
            printf '%s\t%s\n' "$HC_OK" "dep-sharing fix: enabled the pnpm global virtual store (pnpm config set --location=global $DEP_SHARING_PNPM_SETTING $DEP_SHARING_PNPM_VALUE, pnpm $version)"
          else
            printf '%s\t%s\n' "$HC_WARN" "dep-sharing fix: 'pnpm config set --location=global $DEP_SHARING_PNPM_SETTING $DEP_SHARING_PNPM_VALUE' did not take effect (pnpm $version); nothing was changed"
          fi
        else
          printf '%s\t%s\n' "$HC_WARN" "dep-sharing fix: 'pnpm config set --location=global $DEP_SHARING_PNPM_SETTING $DEP_SHARING_PNPM_VALUE' failed (pnpm $version); nothing was changed"
        fi
      else
        exec_path="$(_dep_sharing_exec_path "$pnpm_bin")"
        if PATH="$exec_path" HOME="$user_home" "$pnpm_bin" config set --location=global "$DEP_SHARING_PNPM_SETTING" "$DEP_SHARING_PNPM_VALUE" </dev/null >/dev/null 2>&1; then
          printf '%s\t%s\n' "$HC_OK" "dep-sharing fix: enabled the pnpm global virtual store (pnpm config set --location=global $DEP_SHARING_PNPM_SETTING $DEP_SHARING_PNPM_VALUE, pnpm $version)"
        else
          printf '%s\t%s\n' "$HC_WARN" "dep-sharing fix: 'pnpm config set --location=global $DEP_SHARING_PNPM_SETTING $DEP_SHARING_PNPM_VALUE' failed (pnpm $version); nothing was changed"
        fi
      fi
    fi
  fi

  # --- uv link mode (B3): env first, then config files under USER_HOME ---
  if [ "${UV_LINK_MODE:-}" = "copy" ]; then
    printf '%s\t%s\n' "$HC_WARN" 'UV_LINK_MODE=copy in the environment; uv copies instead of hardlinking — unset it so worktrees share bytes'
  else
    if [ -n "${UV_CONFIG_FILE:-}" ]; then
      if _dep_sharing_has_copy_link "$UV_CONFIG_FILE"; then
        printf '%s\t%s\n' "$HC_WARN" "uv link-mode is 'copy' in $UV_CONFIG_FILE; uv copies instead of hardlinking — remove it so worktrees share bytes"
      fi
    fi
    if [ -z "${UV_CONFIG_FILE:-}" ] || ! _dep_sharing_has_copy_link "${UV_CONFIG_FILE:-}"; then
      if _dep_sharing_has_copy_link "$user_home/.config/uv/uv.toml"; then
        printf '%s\t%s\n' "$HC_WARN" "uv link-mode is 'copy' in $user_home/.config/uv/uv.toml; uv copies instead of hardlinking — remove it so worktrees share bytes"
      elif _dep_sharing_has_copy_link "$user_home/.uv.toml"; then
        printf '%s\t%s\n' "$HC_WARN" "uv link-mode is 'copy' in $user_home/.uv.toml; uv copies instead of hardlinking — remove it so worktrees share bytes"
      fi
    fi
  fi

  # --- uv cache volume (B3): hardlinks cannot span devices ---
  if [ -n "$uv_bin" ]; then
    if cache_dir="$(_dep_sharing_uv_cache_dir "$uv_bin" "$user_home")" && [ -d "$cache_dir" ] && [ -d "$user_home/projects" ]; then
      if dev_cache="$(_dep_sharing_dev "$cache_dir")" && dev_projects="$(_dep_sharing_dev "$user_home/projects")"; then
        if [ "$dev_cache" != "$dev_projects" ]; then
          printf '%s\t%s\n' "$HC_WARN" "uv cache $cache_dir is on a different device than $user_home/projects; hardlinks cannot span volumes so worktrees re-pay the full venv cost"
        fi
      else
        printf '%s\t%s\n' "$HC_INFO" 'uv cache volume unverified (stat failed); sharing is assumed, not proven'
      fi
    fi
  fi

  # --- per-registered-project rows (B.3): INFO only, never upgraded ---
  if [ -n "$trellis_home" ] && [ -f "$trellis_home/registry.json" ] && command -v jq >/dev/null 2>&1; then
    if project_rows="$(jq -r '.projects // {} | to_entries[] | .key as $k | (.value.checkouts // {})[]?.root | "\($k)\t\(.)"' "$trellis_home/registry.json" 2>/dev/null)"; then
      if [ -n "$project_rows" ]; then
        while IFS="$tab" read -r proj_key proj_root; do
          [ -n "${proj_root:-}" ] || continue
          [ -f "$proj_root/package.json" ] || continue
          if pm="$(jq -r '.packageManager // empty' "$proj_root/package.json" 2>/dev/null)" && [ -n "$pm" ]; then
            case "$pm" in
              pnpm@*)
                pin="${pm#pnpm@}"
                if pin_ver="$(printf '%s\n' "$pin" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)" && [ -n "$pin_ver" ]; then
                  if [ "$(_dep_sharing_cmp "$pin_ver" "$DEP_SHARING_PNPM_EGVS_MIN")" = '-1' ]; then
                    printf '%s\t%s\n' "$HC_INFO" "project $proj_key ($proj_root): packageManager pins pnpm $pin_ver below $DEP_SHARING_PNPM_EGVS_MIN — cannot honour user-level $DEP_SHARING_PNPM_SETTING:true (not shared, not upgraded)"
                  fi
                fi
                ;;
            esac
          fi
          if _dep_sharing_ws_opt_out "$proj_root"; then
            printf '%s\t%s\n' "$HC_INFO" "project $proj_key ($proj_root): pnpm-workspace.yaml sets ${DEP_SHARING_PNPM_SETTING}:false — user-level sharing cannot reach it (needs a per-repo PR)"
          fi
          if _dep_sharing_has_dep_builds "$proj_root"; then
            printf '%s\t%s\n' "$HC_INFO" "project $proj_key ($proj_root): dependencies with build scripts (onlyBuiltDependencies/allowBuilds) write into shared package dirs — shared store at risk (native builds depend on the Node ABI; see spec 069 B2)"
          fi
        done <<< "$project_rows"
      fi
    fi
  fi

  if [ -n "$neutral" ]; then
    rm -rf "$neutral"
  fi
  return 0
}
