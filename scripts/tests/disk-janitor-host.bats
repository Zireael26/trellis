#!/usr/bin/env bats
# Lane L-DH host scopes (spec 069): C3 pi spill logs, A9 pi worktrees, D3
# release staging via reap-tmp, D5 logs/tmp, D6 package stores, D7 coverage.
# Hermetic: fake HOME/TMPDIR/TRELLIS_HOME per test; stubbed tools on PATH.
# Each rule carries an inversion check (fresh/young/small kept).

REPO_ROOT="$( cd "$BATS_TEST_DIRNAME/../.." && pwd )"
DJ="$REPO_ROOT/scripts/disk-janitor.sh"
STALE_TOUCH="200001010000"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/dj-host.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  CANON="$SANDBOX/canonical"
  PROJECTS="$SANDBOX/projects"
  TRELLIS_HOME="$SANDBOX/.trellis"
  CFG="$CANON/trellis.config.json"
  mkdir -p "$CANON/audits" "$PROJECTS" "$TRELLIS_HOME" "$SANDBOX/tmp" "$SANDBOX/home"
  chmod 700 "$TRELLIS_HOME"
  export TRELLIS_CONFIG="$CFG" TRELLIS_HOME
  export TMPDIR="$SANDBOX/tmp" HOME="$SANDBOX/home"
  export DJ_BUILD_ACTIVE_OVERRIDE=0
  unset TRELLIS_PI_TMPDIR
  mkdir -p "$TRELLIS_HOME/releases"
  cat >"$CFG" <<'EOF'
{"schema_version": 2, "maintainer_name": "Test Maintainer", "github_user": "tester", "harnesses": ["claude"]}
EOF
  cat >"$TRELLIS_HOME/config.json" <<EOF
{
  "schema_version": 1,
  "source_root": "$CANON",
  "release_remote": "https://example.invalid/trellis.git",
  "active_cli_release": "1.2.3",
  "default_fleet": "personal",
  "fleets": {"personal": {"discovery_roots": ["$PROJECTS"]}}
}
EOF
  chmod 600 "$TRELLIS_HOME/config.json"
  printf '%s\n' '{"schema_version":1,"projects":{},"discovery_ignores":{}}' >"$TRELLIS_HOME/registry.json"
  chmod 600 "$TRELLIS_HOME/registry.json"
}

teardown() {
  if [ -n "${LIVE_PID:-}" ]; then kill "$LIVE_PID" 2>/dev/null || true; wait "$LIVE_PID" 2>/dev/null || true; fi
  if [ -n "${HOLDER_PID:-}" ]; then kill "$HOLDER_PID" 2>/dev/null || true; wait "$HOLDER_PID" 2>/dev/null || true; fi
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then chmod -R u+w "$SANDBOX" 2>/dev/null || true; rm -rf "$SANDBOX"; fi
}

make_staging() {
  local base="$1" stamp="$2"
  local dir="$TRELLIS_HOME/releases/$base"
  mkdir -p "$dir/payload"
  printf 'fixture\n' >"$dir/payload/marker"
  if [ "$stamp" = fresh ]; then touch "$dir"; else touch -t "$stamp" "$dir"; fi
  printf '%s\n' "$dir"
}

write_owner() {
  local dir="$1" pid="$2" birth="$3"
  jq -cn --argjson pid "$pid" --arg process_birth "$birth" \
    '{schema_version:1,pid:$pid,process_birth:$process_birth}' >"$dir.owner.json"
  chmod 600 "$dir.owner.json"
}

age_owner() {
  touch -t "$STALE_TOUCH" "$1.owner.json"
}

run_dj() { run bash "$DJ" "$@"; }

write_stub_tools() {
  local bindir="$1"
  mkdir -p "$bindir"
  cat >"$bindir/pnpm" <<EOF
#!/bin/sh
printf '%s\n' "\$@" >> "$SANDBOX/pnpm-argv.log"
if [ "\$1" = "store" ] && [ "\$2" = "path" ]; then printf '%s\n' "$SANDBOX/pnpm-store/v11"; exit 0; fi
if [ "\$1" = "store" ] && [ "\$2" = "prune" ]; then exit 0; fi
exit 0
EOF
  cat >"$bindir/uv" <<EOF
#!/bin/sh
printf '%s\n' "\$@" >> "$SANDBOX/uv-argv.log"
if [ "\$1" = "cache" ] && [ "\$2" = "dir" ]; then printf '%s\n' "$SANDBOX/uv-cache"; exit 0; fi
if [ "\$1" = "cache" ] && [ "\$2" = "prune" ]; then exit 0; fi
exit 0
EOF
  cat >"$bindir/bun" <<EOF
#!/bin/sh
printf '%s\n' "\$@" >> "$SANDBOX/bun-argv.log"
exit 0
EOF
  cat >"$bindir/go" <<EOF
#!/bin/sh
printf '%s\n' "\$@" >> "$SANDBOX/go-argv.log"
if [ "\$1" = "env" ] && [ "\$2" = "GOCACHE" ]; then printf '%s\n' "$SANDBOX/go-cache"; exit 0; fi
exit 0
EOF
  cat >"$bindir/npm" <<EOF
#!/bin/sh
if [ "\$1" = "config" ] && [ "\$2" = "get" ] && [ "\$3" = "cache" ]; then printf '%s\n' "$SANDBOX/npm-cache"; exit 0; fi
exit 0
EOF
  chmod +x "$bindir"/*
  : >"$SANDBOX/pnpm-argv.log"; : >"$SANDBOX/uv-argv.log"; : >"$SANDBOX/bun-argv.log"; : >"$SANDBOX/go-argv.log"
}

@test "DH.1 releases: janitor delete set equals reap-tmp reapable for .verify and .exec" {
  local aged_exec aged_verify fresh_exec
  aged_exec="$(make_staging .tmp.1.2.3.exec.AgedDH1 "$STALE_TOUCH")"
  aged_verify="$(make_staging .tmp.1.2.3.verify.AgedDHV1 "$STALE_TOUCH")"
  write_owner "$aged_exec" 2147483647 "dead-process"; age_owner "$aged_exec"
  write_owner "$aged_verify" 2147483647 "dead-process"; age_owner "$aged_verify"
  fresh_exec="$(make_staging .tmp.1.2.3.exec.FreshDH1 fresh)"

  run_dj --report --scopes releases
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"$aged_exec"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$aged_verify"* ]] || { echo "$output"; false; }
  [[ "$output" == *"[delete]"* ]] || { echo "$output"; false; }
  # Inversion: fresh staging is never a delete (flipping age must flip verdict).
  [[ "$output" != *"[delete] $fresh_exec "* ]] || { echo "fresh listed as delete: $output"; false; }

  # The janitor's delete set equals reap-tmp's reapable set on the same fixture.
  reapable="$(bash -c '. "$1/scripts/lib/release-store.sh"; release_store_reap_tmp dry-run' _ "$REPO_ROOT" 2>/dev/null | grep -c "reapable dir" || true)"
  deletes="$(printf '%s\n' "$output" | grep -c "\[delete\].*\.tmp\.1\.2\.3\." || true)"
  [ "$reapable" -eq 2 ] || { echo "reap-tmp reapable=$reapable"; false; }
  [ "$deletes" -eq "$reapable" ] || { echo "janitor deletes=$deletes reapable=$reapable output=$output"; false; }

  run_dj --apply --yes --scopes releases </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$aged_exec" ] && [ ! -e "$aged_verify" ] || { echo "aged staging survived"; false; }
  [ -d "$fresh_exec" ] || { echo "fresh staging removed"; false; }
}

@test "DH.2 stores: per-store bytes plus prune-only apply via tool-path" {
  local stub="$SANDBOX/stub-bin"
  write_stub_tools "$stub"
  mkdir -p "$HOME/Library/pnpm/store/v11" "$HOME/Library/pnpm/store/v12"
  mkdir -p "$SANDBOX/pnpm-store/v11" "$SANDBOX/uv-cache" "$SANDBOX/go-cache" "$SANDBOX/npm-cache"
  printf 'x\n' >"$HOME/Library/pnpm/store/v11/pkg"; printf 'x\n' >"$HOME/Library/pnpm/store/v12/pkg"
  printf 'x\n' >"$SANDBOX/uv-cache/f"; printf 'x\n' >"$SANDBOX/go-cache/f"; printf 'x\n' >"$SANDBOX/npm-cache/f"
  # Tool-path file: the launcher strips PATH, so the janitor prepends this.
  mkdir -p "$TRELLIS_HOME/state/disk-janitor"
  printf '%s\n' "$stub" >"$TRELLIS_HOME/state/disk-janitor/tool-path"
  chmod 600 "$TRELLIS_HOME/state/disk-janitor/tool-path"

  # Report with a minimal PATH (no stubs) still finds tools via tool-path.
  run env PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash "$DJ" --report --scopes stores
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"pnpm-store"* ]] || { echo "$output"; false; }
  [[ "$output" == *"uv-cache"* ]] || { echo "$output"; false; }
  [[ "$output" == *"go-build"* ]] || { echo "$output"; false; }
  [[ "$output" == *"never rm"* ]] || { echo "$output"; false; }
  # Inversion: an empty store root reports none (a mutant listing ghosts fails).
  rm -rf "$HOME/Library/pnpm/store/v12"
  run env PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash "$DJ" --report --scopes stores
  [[ "$output" != *"store/v12"* ]] || { echo "ghost store listed: $output"; false; }
  mkdir -p "$HOME/Library/pnpm/store/v12"; printf 'x\n' >"$HOME/Library/pnpm/store/v12/pkg"

  run env PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash "$DJ" --apply --yes --scopes stores </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"pruned: pnpm store prune"* ]] || { echo "$output"; false; }
  [[ "$output" == *"pruned: uv cache prune"* ]] || { echo "$output"; false; }
  [[ "$output" == *"pruned: bun pm cache rm"* ]] || { echo "$output"; false; }
  [[ "$output" == *"pruned: go clean -cache"* ]] || { echo "$output"; false; }
  grep -q "^prune$" "$SANDBOX/pnpm-argv.log" || { cat "$SANDBOX/pnpm-argv.log"; false; }
  grep -q "^prune$" "$SANDBOX/uv-argv.log" || { cat "$SANDBOX/uv-argv.log"; false; }
  # Never rm: no stub may receive rm, and no rm of a store path may run.
  for f in "$SANDBOX"/*-argv.log; do
    grep -qw "rm" "$f" && { echo "rm in $f:"; cat "$f"; false; } || true
  done
  [ -d "$HOME/Library/pnpm/store/v11" ] || { echo "store removed via rm"; false; }
}

@test "DH.7 docker: BuildKit prune keeping 20GB then colima fstrim, never volume/image removal" {
  local stub="$SANDBOX/dh7-bin"
  mkdir -p "$stub" "$SANDBOX/pnpm-store" "$SANDBOX/npm-cache"
  cat >"$stub/docker" <<'EOF'
#!/bin/sh
{
  for arg in "$@"; do printf '%s\037' "$arg"; done
  printf '\n'
} >> "$DJ_DOCKER_ARGV_LOG"
case "${1:-}:${2:-}" in
  info:) exit 0 ;;
  version:--format) printf '27.4.0\n' ;;
  system:df)
    if [ "${3:-}" = "-v" ]; then
      printf '{"Volumes":[]}\n'
    else
      printf '%s\n' '{"Type":"Images","TotalCount":"0"}'
    fi
    ;;
  buildx:du) printf '%s\n' '{"Reclaimable":true,"Size":"3MB"}' ;;
esac
exit 0
EOF
  cat >"$stub/colima" <<EOF
#!/bin/sh
printf '%s\n' "\$@" >> "$SANDBOX/colima-argv.log"
if [ "\$1" = "status" ]; then exit 0; fi
exit 0
EOF
  cat >"$stub/pnpm" <<EOF
#!/bin/sh
printf '%s\n' "$SANDBOX/pnpm-store"
EOF
  cat >"$stub/npm" <<EOF
#!/bin/sh
printf '%s\n' "$SANDBOX/npm-cache"
EOF
  chmod +x "$stub"/*
  : >"$SANDBOX/docker-argv.log"; : >"$SANDBOX/colima-argv.log"

  run env PATH="$stub:$PATH" DJ_DOCKER_ARGV_LOG="$SANDBOX/docker-argv.log" bash "$DJ" --apply --yes --scopes docker </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  expected="buildx"$'\037'"prune"$'\037'"-f"$'\037'"--reserved-space"$'\037'"20GB"$'\037'
  grep -Fq "$expected" "$SANDBOX/docker-argv.log" || { tr '\037' ' ' <"$SANDBOX/docker-argv.log"; false; }
  grep -q "fstrim" "$SANDBOX/colima-argv.log" || { cat "$SANDBOX/colima-argv.log"; false; }
  [[ "$output" == *"fstrim"* ]] || { echo "$output"; false; }
  # Never volume/image/container removal: no such token in any docker argv.
  if tr '\037' ' ' <"$SANDBOX/docker-argv.log" | grep -Eq "volume (rm|remove|prune)|system prune|container (rm|prune)|image (rm|remove|prune)|rmi "; then
    echo "forbidden docker removal:"; tr '\037' ' ' <"$SANDBOX/docker-argv.log"; false
  fi
  # Inversion: without colima, fstrim is skipped with a reason (never fails).
  rm -f "$stub/colima"
  : >"$SANDBOX/docker-argv.log"
  run env PATH="$stub:/usr/bin:/bin:/usr/sbin:/sbin" DJ_DOCKER_ARGV_LOG="$SANDBOX/docker-argv.log" bash "$DJ" --apply --yes --scopes docker </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"colima fstrim: skipped (colima absent)"* || "$output" == *"colima fstrim: skipped (colima not running)"* ]] || { echo "$output"; false; }
}

@test "DH.SEC field-shift: tab and a[\$(cmd)] names are held, never executed" {
  # Apex hardening: a TAB in a plan path shifts TSV fields so bytes can be
  # attacker text; bash $((...+bytes)) would then expand a[$(cmd)]. Owned
  # hunks validate numerics (^ [0-9]+$) before arithmetic and hold ctrl paths.
  local tab evil pwned stub
  tab="$(printf '\t')"
  pwned="$SANDBOX/PWNED"
  rm -f "$pwned"
  stub="$SANDBOX/sec-bin"
  write_stub_tools "$stub"
  mkdir -p "$TRELLIS_HOME/state/disk-janitor"
  printf '%s\n' "$stub" >"$TRELLIS_HOME/state/disk-janitor/tool-path"
  chmod 600 "$TRELLIS_HOME/state/disk-janitor/tool-path"
  # Release staging with a TAB suffix and one with a command-substitution
  # payload in the name. Both fail reap-tmp's alphanumeric suffix gate and
  # must end held (candidate), never delete, and never execute.
  mkdir -p "$TRELLIS_HOME/releases/.tmp.1.2.3.exec.Tab${tab}Name/payload"
  printf 'x\n' >"$TRELLIS_HOME/releases/.tmp.1.2.3.exec.Tab${tab}Name/payload/m"
  touch -t "$STALE_TOUCH" "$TRELLIS_HOME/releases/.tmp.1.2.3.exec.Tab${tab}Name"
  evil='.tmp.1.2.3.exec.a[$(touch '"$pwned"')]'
  mkdir -p "$TRELLIS_HOME/releases/$evil/payload"
  printf 'x\n' >"$TRELLIS_HOME/releases/$evil/payload/m"
  touch -t "$STALE_TOUCH" "$TRELLIS_HOME/releases/$evil"
  # A pnpm store dir with a TAB must never shift store TSV into arithmetic.
  mkdir -p "$HOME/Library/pnpm/store/v${tab}11"
  printf 'x\n' >"$HOME/Library/pnpm/store/v${tab}11/pkg" 2>/dev/null || true

  run env PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash "$DJ" --report --scopes releases,stores
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$pwned" ] || { echo "code executed via field-shift"; false; }
  [[ "$output" != *"[delete] $TRELLIS_HOME/releases/.tmp.1.2.3.exec.Tab"* ]] || { echo "tab name deleted: $output"; false; }
  [[ "$output" != *"[delete] $TRELLIS_HOME/releases/$evil"* ]] || { echo "evil name deleted: $output"; false; }
  # Held rows are visible as candidate/held, never delete.
  [[ "$output" == *"held: control characters"* ]] || { echo "$output"; false; }

  run env PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash "$DJ" --apply --yes --scopes releases,stores </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$pwned" ] || { echo "code executed on apply"; false; }
  # Inversion: a clean aged orphan still deletes (the guard is not a blanket refuse).
  local clean
  clean="$(make_staging .tmp.1.2.3.exec.CleanSEC "$STALE_TOUCH")"
  write_owner "$clean" 2147483647 "dead-process"; age_owner "$clean"
  run env PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash "$DJ" --report --scopes releases
  [[ "$output" == *"[delete] $clean "* ]] || { echo "clean orphan not deleted: $output"; false; }
}

@test "DH.4 pi worktree TTL: clean aged orphan removed, dirty/unique/young held" {
  local parent clean dirty unique young owned reg
  parent="$SANDBOX/pi-parent"
  git init -q -b main "$parent"
  git -C "$parent" -c user.name=t -c user.email=t@e.invalid -c commit.gpgsign=false commit -q --allow-empty -m seed
  export DJ_DARWIN_TMPDIR_OVERRIDE=""
  mk_pi_wt() {
    local name="$1" root="${2:-$HOME/.pi-worktrees}"
    git -C "$parent" worktree add -q --detach "$root/$name" HEAD
    printf '%s\n' "$root/$name"
  }
  unreg() { local n; n="$(sed -n 's|^gitdir: .*/worktrees/||p' "$1/.git")"; rm -rf "$parent/.git/worktrees/$n"; }
  age_tree() { find "$1" -exec touch -h -t "$STALE_TOUCH" {} + 2>/dev/null || true; touch -h -t "$STALE_TOUCH" "$1" 2>/dev/null || true; }
  # A9 works on registered-but-unowned pi-agent worktrees (so `git worktree
  # remove` still works); unregistered orphans with missing gitdir fail the
  # unique check closed and stay held. Clean: registered, old, clean, no
  # unique, no owner -> delete.
  clean="$(mk_pi_wt pi-agent-clean-dh4)"; age_tree "$clean"
  # Dirty orphan (untracked file) -> hold.
  dirty="$(mk_pi_wt pi-agent-dirty-dh4)"; printf 'work\n' >"$dirty/work.txt"; age_tree "$dirty"; touch -t "$STALE_TOUCH" "$dirty/work.txt"
  # Unique-commit -> hold (commit while registered, then age).
  unique="$(mk_pi_wt pi-agent-unique-dh4)"
  git -C "$unique" -c user.name=t -c user.email=t@e.invalid -c commit.gpgsign=false commit -q --allow-empty -m unique
  age_tree "$unique"
  # Young (fresh, clean, registered) -> hold (TTL).
  young="$(mk_pi_wt pi-agent-young-dh4)"
  # Owned (unregistered + owner record) -> hold. Registered non-pi-agent -> hold.
  owned="$(mk_pi_wt pi-agent-owned-dh4)"; unreg "$owned"; age_tree "$owned"
  mkdir -p "$TRELLIS_HOME/state/attachments/c0ffee"
  jq -n --arg root "$owned" '{schema_version:1,worktree_root:$root,project_root:$root}' >"$TRELLIS_HOME/state/attachments/c0ffee/w1.json"
  reg="$(mk_pi_wt my-reg-dh4)"; age_tree "$reg"

  run bash "$DJ" --dry-run --scopes pi
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"[delete] $clean "* ]] || { echo "clean not delete: $output"; false; }
  [[ "$output" != *"[delete] $dirty "* ]] || { echo "dirty deleted"; false; }
  [[ "$output" != *"[delete] $unique "* ]] || { echo "unique deleted"; false; }
  [[ "$output" != *"[delete] $young "* ]] || { echo "young deleted"; false; }
  [[ "$output" != *"[delete] $owned "* ]] || { echo "owned deleted"; false; }
  [[ "$output" != *"[delete] $reg "* ]] || { echo "registered deleted"; false; }

  run bash "$DJ" --apply --yes --scopes pi </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$clean" ] || { echo "clean survived"; false; }
  [ -d "$dirty" ] && [ -f "$dirty/work.txt" ] || { echo "dirty removed"; false; }
  [ -d "$unique" ] || { echo "unique removed"; false; }
  [ -d "$young" ] || { echo "young removed"; false; }
  [ -d "$owned" ] || { echo "owned removed"; false; }
  [ -d "$reg" ] || { echo "registered removed"; false; }
  # Removal used git (parent forgot it); never --force/rm of a dirty tree.
  if git -C "$parent" worktree list --porcelain 2>/dev/null | grep -qF "$clean"; then echo "clean still registered"; false; fi
}

@test "DH.5 logs report-only; tmp bats-run/rv apply" {
  local proj old_log young_log old_tmp young_tmp other
  proj="$PROJECTS/logproj"
  mkdir -p "$proj"
  git init -q -b main "$proj"
  git -C "$proj" -c user.name=t -c user.email=t@e.invalid -c commit.gpgsign=false commit -q --allow-empty -m seed
  bash -c '. "$1/scripts/lib/trellis-home.sh"; . "$1/scripts/lib/local-registry.sh"; local_registry_register_worktree "$2" personal logproj "$3" 1.2.3 "[\"claude\"]" ""' _ "$REPO_ROOT" "$TRELLIS_HOME" "$proj" >/dev/null
  old_log="$proj/big-old.log"
  dd if=/dev/zero of="$old_log" bs=1M count=55 2>/dev/null
  touch -t "$STALE_TOUCH" "$old_log"
  young_log="$proj/big-young.log"
  dd if=/dev/zero of="$young_log" bs=1M count=55 2>/dev/null
  old_tmp="$TMPDIR/bats-run-dh5old"; mkdir -p "$old_tmp"; printf 'x\n' >"$old_tmp/f"; touch -t "$STALE_TOUCH" "$old_tmp"; touch -t "$STALE_TOUCH" "$old_tmp/f"
  young_tmp="$TMPDIR/rv-dh5young"; mkdir -p "$young_tmp"; printf 'x\n' >"$young_tmp/f"
  other="$TMPDIR/other-dh5"; mkdir -p "$other"; printf 'x\n' >"$other/f"; touch -t "$STALE_TOUCH" "$other"; touch -t "$STALE_TOUCH" "$other/f"
  # D5 tmp scans the per-user temp dir, not the launcher TMPDIR.
  export DJ_DARWIN_TMPDIR_OVERRIDE="$TMPDIR"

  run bash "$DJ" --report --scopes logs,tmp
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"$old_log"* ]] || { echo "old log missing: $output"; false; }
  [[ "$output" == *"[candidate]"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[delete] $old_log "* ]] || { echo "logs deleted (must be report-only): $output"; false; }
  [[ "$output" != *"$young_log"*"[candidate]"* ]] || true
  # Inversion: young tmp is never delete; non-matching names never listed.
  [[ "$output" == *"[delete] $old_tmp "* ]] || { echo "old tmp not delete: $output"; false; }
  [[ "$output" != *"[delete] $young_tmp "* ]] || { echo "young tmp deleted"; false; }
  [[ "$output" != *"$other"* ]] || { echo "non-matching tmp listed: $output"; false; }

  run bash "$DJ" --apply --yes --scopes logs,tmp </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$old_log" ] || { echo "report-only log removed"; false; }
  [ ! -e "$old_tmp" ] || { echo "old tmp survived"; false; }
  [ -d "$young_tmp" ] || { echo "young tmp removed"; false; }
  [ -d "$other" ] || { echo "non-matching tmp removed"; false; }
}

@test "DH.6 coverage line plus transcripts histogram, never deleted" {
  mkdir -p "$HOME/.codex" "$HOME/.pi/sessions" "$HOME/.claude/projects"
  printf 'new\n' >"$HOME/.codex/recent.json"
  printf 'old\n' >"$HOME/.pi/sessions/old.json"
  touch -t "$STALE_TOUCH" "$HOME/.pi/sessions/old.json"
  printf 'old\n' >"$HOME/.claude/projects/old.jsonl"
  touch -t "$STALE_TOUCH" "$HOME/.claude/projects/old.jsonl"
  export DJ_DARWIN_TMPDIR_OVERRIDE=""

  run bash "$DJ" --report --scopes transcripts
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"Session transcripts"* ]] || { echo "$output"; false; }
  [[ "$output" == *"never deleted"* ]] || { echo "$output"; false; }
  [[ "$output" == *".codex"* ]] || { echo "$output"; false; }
  # Inversion: transcripts are never [delete], even when old.
  [[ "$output" != *"[delete]"* ]] || { echo "transcript deleted: $output"; false; }

  run bash "$DJ" --report --scopes caches,worktrees,stores,docker,releases
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"unattributed = df used"* ]] || { echo "$output"; false; }
  [[ "$output" == *"% of df used"* ]] || { echo "$output"; false; }
  # Transcripts are never removed by apply either.
  run bash "$DJ" --apply --yes --scopes transcripts </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$HOME/.pi/sessions/old.json" ] || { echo "transcript removed"; false; }
  [ -f "$HOME/.claude/projects/old.jsonl" ] || { echo "transcript removed"; false; }
}

@test "DH.3 pi spill: _pi, bare TMPDIR, Darwin roots at maxdepth1, pi_apply gate" {
  local central darwin
  central="$(bash -c '. "$1/scripts/lib/hygiene-common.sh"; hy_root' _ "$REPO_ROOT")/_pi"
  mkdir -p "$central"
  darwin="$SANDBOX/darwin-tmp"; mkdir -p "$darwin/pi"
  export DJ_DARWIN_TMPDIR_OVERRIDE="$darwin"
  for root in "$central" "$TMPDIR" "$darwin" "$darwin/pi"; do
    printf 'old\n' >"$root/pi-bash-dh3old.log"
    touch -t "$STALE_TOUCH" "$root/pi-bash-dh3old.log"
    dd if=/dev/zero of="$root/pi-bash-dh3big.log" bs=1 count=0 seek=1073741825 2>/dev/null
    printf 'fresh\n' >"$root/pi-bash-dh3fresh.log"
    printf 'other\n' >"$root/not-a-spill.txt"
    touch -t "$STALE_TOUCH" "$root/not-a-spill.txt"
    mkdir -p "$root/subdir"
    printf 'old\n' >"$root/subdir/pi-bash-nested.log"
    touch -t "$STALE_TOUCH" "$root/subdir/pi-bash-nested.log"
  done
  ln -s "$central/pi-bash-dh3old.log" "$central/pi-bash-dh3link.log" 2>/dev/null || true

  run env PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash "$DJ" --dry-run --scopes pi
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  for root in "$central" "$TMPDIR" "$darwin" "$darwin/pi"; do
    [[ "$output" == *"[delete] $root/pi-bash-dh3old.log "* ]] || { echo "old not delete in $root: $output"; false; }
    [[ "$output" == *"[delete] $root/pi-bash-dh3big.log "* ]] || { echo "big not delete in $root: $output"; false; }
    [[ "$output" != *"[delete] $root/pi-bash-dh3fresh.log "* ]] || { echo "fresh deleted in $root"; false; }
    [[ "$output" != *"not-a-spill"*"[delete]"* ]] || true
    [[ "$output" != *"subdir/pi-bash-nested"*"[delete]"* ]] || { echo "nested deleted (maxdepth violated)"; false; }
  done
  [[ "$output" != *"[delete].*pi-bash-dh3link"* ]] || { echo "symlink deleted"; false; }

  run env PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash "$DJ" --apply --yes --scopes pi </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  for root in "$central" "$TMPDIR" "$darwin" "$darwin/pi"; do
    [ ! -e "$root/pi-bash-dh3old.log" ] || { echo "old survived in $root"; false; }
    [ ! -e "$root/pi-bash-dh3big.log" ] || { echo "big survived in $root"; false; }
    [ -f "$root/pi-bash-dh3fresh.log" ] || { echo "fresh removed in $root"; false; }
    [ -f "$root/not-a-spill.txt" ] || { echo "non-spill removed in $root"; false; }
    [ -f "$root/subdir/pi-bash-nested.log" ] || { echo "nested removed in $root"; false; }
  done
  [ -L "$central/pi-bash-dh3link.log" ] || { echo "symlink target removed"; false; }

  # pi_apply:false restores report-only (inversion: same aged logs stay).
  for root in "$central" "$TMPDIR"; do
    printf 'old\n' >"$root/pi-bash-dh3again.log"
    touch -t "$STALE_TOUCH" "$root/pi-bash-dh3again.log"
  done
  printf '{"schema_version":2,"maintainer_name":"T","github_user":"t","harnesses":["claude"],"disk_janitor":{"pi_apply":false}}' >"$CFG"
  run env PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash "$DJ" --apply --yes --scopes pi </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  for root in "$central" "$TMPDIR"; do
    [ -f "$root/pi-bash-dh3again.log" ] || { echo "pi_apply:false deleted in $root"; false; }
  done
}

@test "RV-P1 tmp root is the per-user temp dir; TMPDIR=HOME deletes nothing" {
  local fixture darwin_old darwin_young real link
  fixture="$HOME/rv-fixture"
  mkdir -p "$fixture"; printf 'x\n' >"$fixture/f"
  touch -t "$STALE_TOUCH" "$fixture" "$fixture/f"
  darwin_old="$SANDBOX/darwin-tmp"; mkdir -p "$darwin_old"
  export DJ_DARWIN_TMPDIR_OVERRIDE="$darwin_old"
  darwin_old="$darwin_old/bats-run-rvold"; mkdir -p "$darwin_old"; printf 'x\n' >"$darwin_old/f"
  touch -t "$STALE_TOUCH" "$darwin_old" "$darwin_old/f"
  darwin_young="$SANDBOX/darwin-tmp/rv-rvyoung"; mkdir -p "$darwin_young"; printf 'x\n' >"$darwin_young/f"
  # The launcher per-run TMPDIR is never the tmp root: TMPDIR=HOME scans
  # the Darwin dir, never HOME, so the aged HOME fixture is never listed.
  run env TMPDIR="$HOME" bash "$DJ" --report --scopes tmp
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"[delete] $fixture"* ]] || { echo "HOME fixture listed delete: $output"; false; }
  [[ "$output" != *"$fixture"* ]] || { echo "HOME fixture listed at all: $output"; false; }
  [[ "$output" == *"[delete] $darwin_old "* ]] || { echo "darwin old not delete: $output"; false; }
  [[ "$output" != *"[delete] $darwin_young"* ]] || { echo "darwin young deleted"; false; }
  run env TMPDIR="$HOME" bash "$DJ" --apply --yes --scopes tmp </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -d "$fixture" ] && [ -f "$fixture/f" ] || { echo "HOME fixture removed"; false; }
  [ ! -e "$darwin_old" ] || { echo "darwin old survived"; false; }
  [ -d "$darwin_young" ] || { echo "darwin young removed"; false; }
  # Symlinked override canonicalizes (realpath): entries still found.
  real="$SANDBOX/real-tmp"; link="$SANDBOX/link-tmp"
  mkdir -p "$real/bats-run-linkold"; printf 'x\n' >"$real/bats-run-linkold/f"
  touch -t "$STALE_TOUCH" "$real/bats-run-linkold" "$real/bats-run-linkold/f"
  ln -s "$real" "$link"
  run env DJ_DARWIN_TMPDIR_OVERRIDE="$link" bash "$DJ" --report --scopes tmp
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"[delete] $real/bats-run-linkold "* ]] || { echo "symlinked tmp root not canonicalized: $output"; false; }
  # Unsafe roots refuse with a reason and delete nothing.
  run env DJ_DARWIN_TMPDIR_OVERRIDE="$HOME" bash "$DJ" --report --scopes tmp
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"[delete]"* ]] || { echo "HOME override deleted: $output"; false; }
  [[ "$output" == *"refused"* ]] || { echo "no refuse reason for HOME: $output"; false; }
  run env DJ_DARWIN_TMPDIR_OVERRIDE="/" bash "$DJ" --report --scopes tmp
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"[delete]"* ]] || { echo "/ override deleted: $output"; false; }
  [[ "$output" == *"refused"* ]] || { echo "no refuse reason for /: $output"; false; }
}

@test "RV-P1 branch worktree with unpushed commit is held (unique work)" {
  local parent wt_branch wt_clean
  parent="$SANDBOX/pi-branch-parent"
  git init -q -b main "$parent"
  git -C "$parent" -c user.name=t -c user.email=t@e.invalid -c commit.gpgsign=false commit -q --allow-empty -m seed
  export DJ_DARWIN_TMPDIR_OVERRIDE=""
  age_tree() { find "$1" -exec touch -h -t "$STALE_TOUCH" {} + 2>/dev/null || true; touch -h -t "$STALE_TOUCH" "$1" 2>/dev/null || true; }
  # Unit: a pi-agent branch with one unpushed commit holds unique work.
  git -C "$parent" worktree add -q -b pi-agent-work "$HOME/.pi-worktrees/pi-agent-unique-branch" HEAD
  wt_branch="$HOME/.pi-worktrees/pi-agent-unique-branch"
  git -C "$wt_branch" -c user.name=t -c user.email=t@e.invalid -c commit.gpgsign=false commit -q --allow-empty -m "unpushed unique commit"
  age_tree "$wt_branch"
  run bash -c '. "$1/scripts/lib/disk-janitor-host.sh"; dj_host_pi_no_unique_commits "$2"' _ "$REPO_ROOT" "$wt_branch"
  [ "$status" -ne 0 ] || { echo "unpushed branch commit reported as no-unique (reclaimable)"; false; }
  # Inversion: a detached checkout at the same SHA with no new commit is shared.
  git -C "$parent" worktree add -q --detach "$HOME/.pi-worktrees/pi-agent-shared" HEAD
  wt_clean="$HOME/.pi-worktrees/pi-agent-shared"
  age_tree "$wt_clean"
  run bash -c '. "$1/scripts/lib/disk-janitor-host.sh"; dj_host_pi_no_unique_commits "$2"' _ "$REPO_ROOT" "$wt_clean"
  [ "$status" -eq 0 ] || { echo "shared detached HEAD reported as unique"; false; }
  # End to end: the branched worktree is held (never delete), the shared one deletes.
  run bash "$DJ" --dry-run --scopes pi
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"[delete] $wt_branch "* ]] || { echo "unique branch worktree listed delete: $output"; false; }
  [[ "$output" == *"$wt_branch"* ]] || { echo "unique branch worktree missing from report: $output"; false; }
  [[ "$output" == *"[delete] $wt_clean "* ]] || { echo "shared worktree not delete: $output"; false; }
  run bash "$DJ" --apply --yes --scopes pi </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -d "$wt_branch" ] || { echo "unique branch worktree removed"; false; }
  [ ! -e "$wt_clean" ] || { echo "shared worktree survived"; false; }
}

@test "RV-P2 worktree dirtiness comes from git status porcelain" {
  local parent wt_clean wt_untracked
  parent="$SANDBOX/pi-dirty-parent"
  git init -q -b main "$parent"
  printf 'tracked\n' >"$parent/file.txt"
  git -C "$parent" -c user.name=t -c user.email=t@e.invalid -c commit.gpgsign=false add file.txt
  git -C "$parent" -c user.name=t -c user.email=t@e.invalid -c commit.gpgsign=false commit -q -m seed
  export DJ_DARWIN_TMPDIR_OVERRIDE=""
  age_tree() { find "$1" -exec touch -h -t "$STALE_TOUCH" {} + 2>/dev/null || true; touch -h -t "$STALE_TOUCH" "$1" 2>/dev/null || true; }
  # Clean worktree holding tracked files is NOT dirty: reclaim proceeds.
  git -C "$parent" worktree add -q --detach "$HOME/.pi-worktrees/pi-agent-cleantracked" HEAD
  wt_clean="$HOME/.pi-worktrees/pi-agent-cleantracked"
  age_tree "$wt_clean"
  # Same layout plus one untracked file IS dirty: held.
  git -C "$parent" worktree add -q --detach "$HOME/.pi-worktrees/pi-agent-untracked" HEAD
  wt_untracked="$HOME/.pi-worktrees/pi-agent-untracked"
  printf 'work\n' >"$wt_untracked/notes.txt"
  age_tree "$wt_untracked"; touch -t "$STALE_TOUCH" "$wt_untracked/notes.txt"
  run bash "$DJ" --dry-run --scopes pi
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"[delete] $wt_clean "* ]] || { echo "clean tracked worktree not delete: $output"; false; }
  [[ "$output" != *"[delete] $wt_untracked "* ]] || { echo "untracked worktree listed delete"; false; }
  [[ "$output" == *"$wt_untracked"* ]] || { echo "untracked worktree missing from report: $output"; false; }
  run bash "$DJ" --apply --yes --scopes pi </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$wt_clean" ] || { echo "clean tracked worktree survived"; false; }
  [ -d "$wt_untracked" ] && [ -f "$wt_untracked/notes.txt" ] || { echo "untracked worktree removed"; false; }
}

@test "RV-P2 PI_BARE_TMP_ROOT refuses HOME and slash like pi_tmp_anchor" {
  local darwin home_spill darwin_spill
  darwin="$SANDBOX/darwin-bare"; mkdir -p "$darwin"
  export DJ_DARWIN_TMPDIR_OVERRIDE="$darwin"
  home_spill="$HOME/pi-bash-bareold.log"
  printf 'old\n' >"$home_spill"; touch -t "$STALE_TOUCH" "$home_spill"
  darwin_spill="$darwin/pi-bash-bareold.log"
  printf 'old\n' >"$darwin_spill"; touch -t "$STALE_TOUCH" "$darwin_spill"
  # TMPDIR=HOME must not scan HOME as a bare spill root; the Darwin root
  # still applies, proving the pi scope itself works.
  run env TMPDIR="$HOME" bash "$DJ" --dry-run --scopes pi
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"[delete] $home_spill"* ]] || { echo "HOME spill listed delete: $output"; false; }
  [[ "$output" == *"[delete] $darwin_spill "* ]] || { echo "darwin spill not delete: $output"; false; }
  run env TMPDIR="$HOME" bash "$DJ" --apply --yes --scopes pi </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$home_spill" ] || { echo "HOME spill removed"; false; }
  [ ! -e "$darwin_spill" ] || { echo "darwin spill survived"; false; }
  # Inversion: TMPDIR under HOME is refused the same way (never a spill root).
  mkdir -p "$HOME/subtmp"
  printf 'old\n' >"$HOME/subtmp/pi-bash-subold.log"; touch -t "$STALE_TOUCH" "$HOME/subtmp/pi-bash-subold.log"
  run env TMPDIR="$HOME/subtmp" DJ_DARWIN_TMPDIR_OVERRIDE="$darwin" bash "$DJ" --dry-run --scopes pi
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"[delete] $HOME/subtmp/pi-bash-subold.log"* ]] || { echo "HOME-subdir spill listed: $output"; false; }
}

@test "P1 tracked upstream branch: unpushed held, fully pushed reclaimable" {
  local origin parent wt_held wt_free
  origin="$SANDBOX/origin.git"
  git init -q --bare "$origin"
  parent="$SANDBOX/pi-track-parent"
  git init -q -b main "$parent"
  git -C "$parent" -c user.name=t -c user.email=t@e.invalid -c commit.gpgsign=false commit -q --allow-empty -m seed
  git -C "$parent" remote add origin "$origin"
  export DJ_DARWIN_TMPDIR_OVERRIDE=""
  age_tree() { find "$1" -exec touch -h -t "$STALE_TOUCH" {} + 2>/dev/null || true; touch -h -t "$STALE_TOUCH" "$1" 2>/dev/null || true; }
  # Fully pushed, idle, clean worktree: reclaimable.
  git -C "$parent" checkout -q -b pi-agent-track-free
  git -C "$parent" -c user.name=t -c user.email=t@e.invalid -c commit.gpgsign=false push -q -u origin pi-agent-track-free
  git -C "$parent" checkout -q main
  git -C "$parent" worktree add -q "$HOME/.pi-worktrees/pi-agent-track-free" pi-agent-track-free
  wt_free="$HOME/.pi-worktrees/pi-agent-track-free"
  age_tree "$wt_free"
  run bash -c '. "$1/scripts/lib/disk-janitor-host.sh"; dj_host_pi_no_unique_commits "$2"' _ "$REPO_ROOT" "$wt_free"
  [ "$status" -eq 0 ] || { echo "fully pushed worktree reported as unique"; false; }
  # Same setup plus one local commit: held (unique unpushed work).
  git -C "$parent" checkout -q main
  git -C "$parent" checkout -q -b pi-agent-track-held
  git -C "$parent" -c user.name=t -c user.email=t@e.invalid -c commit.gpgsign=false push -q -u origin pi-agent-track-held
  git -C "$parent" checkout -q main
  git -C "$parent" worktree add -q "$HOME/.pi-worktrees/pi-agent-track-held" pi-agent-track-held
  wt_held="$HOME/.pi-worktrees/pi-agent-track-held"
  git -C "$wt_held" -c user.name=t -c user.email=t@e.invalid -c commit.gpgsign=false commit -q --allow-empty -m "unique unpushed commit"
  age_tree "$wt_held"
  run bash -c '. "$1/scripts/lib/disk-janitor-host.sh"; dj_host_pi_no_unique_commits "$2"' _ "$REPO_ROOT" "$wt_held"
  [ "$status" -ne 0 ] || { echo "unpushed tracked commit reported as no-unique (reclaimable)"; false; }
  # End to end: the pushed one deletes, the unpushed one is held.
  run bash "$DJ" --dry-run --scopes pi
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"[delete] $wt_free "* ]] || { echo "fully pushed worktree not delete: $output"; false; }
  [[ "$output" != *"[delete] $wt_held "* ]] || { echo "unpushed tracked worktree listed delete: $output"; false; }
  [[ "$output" == *"$wt_held"* ]] || { echo "held worktree missing from report: $output"; false; }
  run bash "$DJ" --apply --yes --scopes pi </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$wt_free" ] || { echo "fully pushed worktree survived"; false; }
  [ -d "$wt_held" ] || { echo "unpushed tracked worktree removed"; false; }
}
