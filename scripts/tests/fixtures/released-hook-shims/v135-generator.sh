# Test fixture: unmodified released shim generator from v135.
# shellcheck shell=bash
_attachment_hooks_passthrough_shim_body() {
  local name=${1:-} body
  _attachment_hooks_is_passthrough_name "$name" || return 1
  body=$(cat <<'SHIM_EOF'
#!/bin/sh
# trellis-managed-passthrough: @TRELLIS_HOOK_NAME@
caller_path=${PATH-}
caller_home=${HOME-}
caller_tmpdir=${TMPDIR-}
shim_path=$0
if [ "${shim_path#/}" = "$shim_path" ]; then
  shim_path="$PWD/$shim_path"
fi
managed_dir=$(dirname "$shim_path") || exit 0
managed_dir=$(CDPATH= cd "$managed_dir" && pwd -P) || exit 0
previous=""
if [ -f "$managed_dir/previous-hooks-path" ] && [ ! -L "$managed_dir/previous-hooks-path" ]; then
  count=0
  line=""
  candidate=""
  while IFS= read -r candidate || [ -n "$candidate" ]; do
    count=$((count + 1))
    [ "$count" -eq 1 ] || exit 0
    line="$candidate"
    candidate=""
  done < "$managed_dir/previous-hooks-path"
  [ "$count" -eq 1 ] || exit 0
  previous="$line"
fi
[ -n "$previous" ] || exit 0
if [ "${previous#/}" != "$previous" ]; then
  prior_hook="$previous/@TRELLIS_HOOK_NAME@"
else
  project_root=$(CDPATH= cd . && pwd -P) || exit 0
  prior_hook="$project_root/$previous/@TRELLIS_HOOK_NAME@"
fi
if [ -n "$prior_hook" ] && { [ -f "$prior_hook" ] || [ -L "$prior_hook" ]; } && [ -x "$prior_hook" ]; then
  hook_argc=$#
  line=""
  git_name=""
  hook_arg=""
  hook_index=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      GIT_*=*@TRELLIS_RPAREN@ ;;
      *@TRELLIS_RPAREN@ continue ;;
    esac
    git_name=${line%%=*}
    case "$git_name" in
      GIT_*@TRELLIS_RPAREN@ ;;
      *@TRELLIS_RPAREN@ continue ;;
    esac
    case "$git_name" in
      *[!A-Za-z0-9_]*@TRELLIS_RPAREN@ continue ;;
    esac
    set -- "$@" "$line"
    line=""
  done <<TRELLIS_GIT_ENV_EOF
$(/usr/bin/env)
TRELLIS_GIT_ENV_EOF
  set -- "$@" "$prior_hook"
  hook_index=0
  while [ "$hook_index" -lt "$hook_argc" ]; do
    hook_arg=$1
    shift
    set -- "$@" "$hook_arg"
    hook_index=$((hook_index + 1))
  done
  exec /usr/bin/env -i PATH="$caller_path" HOME="$caller_home" TMPDIR="$caller_tmpdir" TMP="$caller_tmpdir" TEMP="$caller_tmpdir" LC_ALL=C "$@"
fi
exit 0
SHIM_EOF
) || return 1
  body=${body//@TRELLIS_RPAREN@/)}
  body=${body//@TRELLIS_HOOK_NAME@/$name}
  printf '%s\n' "$body"
}
