#!/usr/bin/env bats
# The shell Stop gate's verdict fast path (core-rules/hooks/lib/attach-verdict.sh,
# byte-identical in the Codex twin) under the GNU stat dialect, and a lint that
# keeps the BSD-first chained `stat -f … || stat -c …` shape out of product
# shell. GNU `stat -f` is --file-system: it prints a filesystem block on stdout
# and then fails, so a chained `||` inside one capture appends the GNU answer to
# that block. In attach-verdict.sh that meant the 0600 check never matched on
# Linux and every Stop skipped the fast path for the full checks gate.
#
# HERMETIC: a private TRELLIS_HOME and Git repository under `mktemp -d`. The
# gate copy below lives in a payload with no scripts/lib/attach-postjob.sh, so
# a missed fast path shows as the "no checks gate" refusal instead of running
# any release code.

REPO_ROOT="$( cd "$BATS_TEST_DIRNAME/../.." && pwd )"

setup() {
  SANDBOX="$(mktemp -d)"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/home" GIT_CONFIG_GLOBAL="$SANDBOX/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$HOME"
  : > "$GIT_CONFIG_GLOBAL"
  TH="$SANDBOX/trellis-home"
  mkdir -p "$TH"
  chmod 700 "$TH"
  PROJECT="$SANDBOX/project"
  git init -q "$PROJECT"
  PROJECT="$(cd "$PROJECT" && pwd -P)"
  GATE_LIB="$SANDBOX/payload/core-rules/hooks/lib/attach-verdict.sh"
  mkdir -p "$(dirname "$GATE_LIB")"
  cp "$REPO_ROOT/core-rules/hooks/lib/attach-verdict.sh" "$GATE_LIB"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "${SANDBOX:?}"
}

sha_text() { printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1; }

# write_verdict <state>: a private owner record and a schema-2 verdict bound to it.
write_verdict() {
  local common checkout worktree owner_dir status_dir owner
  common="$(cd "$PROJECT/.git" && pwd -P)"
  checkout="$(sha_text "$common")"
  worktree="$(sha_text "$PROJECT")"
  owner_dir="$TH/state/attachments/$checkout"
  status_dir="$TH/state/attachment-status/$checkout"
  mkdir -p "$owner_dir" "$status_dir"
  owner="$owner_dir/$worktree.json"
  jq -n --arg root "$PROJECT" '{attachment_id:"a1",release:"1.5.0",worktree_root:$root}' > "$owner"
  chmod 600 "$owner"
  jq -n --arg state "$1" --arg checkout "$checkout" --arg worktree "$worktree" --arg root "$PROJECT" \
    --arg sha "$(shasum -a 256 "$owner" | cut -d' ' -f1)" '
      {schema_version:2,state:$state,checkout_id:$checkout,worktree_id:$worktree,
       attachment_id:"a1",release:"1.5.0",worktree_root:$root,owner_sha256:$sha,
       failure:null}' > "$status_dir/$worktree.json"
  chmod 600 "$status_dir/$worktree.json"
}

# A `stat` that behaves like GNU coreutils for the two forms the gate uses:
# `-f FMT FILE` reports on every operand on stdout and fails; `-c %a` answers.
# It delegates `-c` to the BSD binary, so it is a Darwin-host simulation.
install_gnu_stat_shim() {
  GNU_BIN="$SANDBOX/gnu-bin"
  mkdir -p "$GNU_BIN"
  cat > "$GNU_BIN/stat" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "-f" ]; then
  shift
  printf 'stat: cannot read file system information for %s\n' "${1:-}" >&2
  shift
  for operand in "$@"; do
    printf '  File: "%s"\n' "$operand"
    printf '    ID: 0 Namelen: 255 Type: apfs\n'
  done
  exit 1
fi
if [ "$1" = "-c" ] && [ "$2" = "%a" ]; then
  exec /usr/bin/stat -f %Lp "$3"
fi
exit 2
SH
  chmod 755 "$GNU_BIN/stat"
}

run_gate() {
  run env PATH="$1" TRELLIS_HOME="$TH" HOME="$HOME" /bin/bash --noprofile --norc -c \
    '. "$1"; trellis_attach_verdict_stop "$2"' _ "$GATE_LIB" "$PROJECT"
}

@test "a bound ok verdict passes the Stop gate's fast path under the GNU stat dialect" {
  [ "$(uname -s)" = Darwin ] || skip "the GNU shim delegates to BSD /usr/bin/stat"
  install_gnu_stat_shim
  write_verdict ok

  # The shim is GNU-shaped: the old chained capture is multi-line, not 600.
  run env PATH="$GNU_BIN:$PATH" bash -c \
    'stat -f "%Lp" "$1" 2>/dev/null || stat -c "%a" "$1" 2>/dev/null' _ "$GATE_LIB"
  [ "${#lines[@]}" -gt 1 ] || { echo "$output"; false; }

  run_gate "$GNU_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -z "$output" ] || { echo "$output"; false; }

  run_gate "/usr/bin:/bin:/usr/sbin:/sbin"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -z "$output" ] || { echo "$output"; false; }
}

@test "a failed verdict still misses the fast path under either stat dialect" {
  [ "$(uname -s)" = Darwin ] || skip "the GNU shim delegates to BSD /usr/bin/stat"
  install_gnu_stat_shim
  write_verdict failed
  for path in "$GNU_BIN:/usr/bin:/bin:/usr/sbin:/sbin" "/usr/bin:/bin:/usr/sbin:/sbin"; do
    run_gate "$path"
    [ "$status" -eq 1 ] || { echo "$output"; false; }
    [[ "$output" == *"has no checks gate"* ]] || { echo "$output"; false; }
  done
}

@test "no product shell chains a BSD stat -f probe into GNU stat -c in one command" {
  local files hits
  # Without Git (an exported tree) list the files directly; an empty list
  # would make the lint pass vacuously, so it refuses instead.
  files="$(cd "$REPO_ROOT" && { git ls-files -- '*.sh' '*.bash' 'scripts/trellis' 2>/dev/null ||
    find core-rules scripts -type f \( -name '*.sh' -o -name '*.bash' -o -path scripts/trellis \); } |
    grep -v -e '^scripts/tests/' -e '/tests/')"
  [ "$(printf '%s\n' "$files" | grep -c .)" -gt 50 ] || { echo "too few shell files: $files"; false; }
  hits="$(cd "$REPO_ROOT" && printf '%s\n' "$files" | tr '\n' '\0' |
    xargs -0 grep -nE "stat -f[^|;]*[|][|][[:space:]]*stat -c" |
    grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
  [ -z "$hits" ] || { printf '%s\n' "$hits"; false; }
}
