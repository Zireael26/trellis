#!/usr/bin/env bats
# Tests for stop-verify's pass reuse and concurrent checks (spec 072 U8), on
# both Stop adapters. Every test drives counting fake tools:
# a reuse is proven by a call count that did NOT grow, a rerun by one that did.

load helpers

setup() {
  # Never read or write the operator's ~/.trellis or HOME.
  export HOME="$BATS_TEST_TMPDIR/home"
  export TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis-home"
  mkdir -p "$HOME"
  setup_project_dir
  PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd -P)"
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
  # Fake tools live in an ignored directory inside the worktree: reuse binds
  # only programs whose whole closure it can see (the ignored digest covers
  # them). Their call log lives outside, so logging never changes the tree.
  FAKE_BIN="$PROJECT_DIR/.fakebin"
  FAKE_STATE="$BATS_TEST_TMPDIR/fake-state"
  mkdir -p "$FAKE_BIN" "$FAKE_STATE"
  printf '/.fakebin/\n' >> "$PROJECT_DIR/.git/info/exclude"
  # bats exports its own functions (bats_readlinkf); an exported function
  # refuses reuse, so the hooks must not inherit them.
  local f
  for f in $(declare -Fx | awk '{ print $3 }'); do export -fn "${f?}"; done
  # Runners export variables that refuse reuse by design (_se_env_moves_code,
  # _se_pm_config): the Git fence's GIT_CONFIG_GLOBAL, GIT_CONFIG_NOSYSTEM and
  # GIT_OPTIONAL_LOCKS, XDG_CONFIG_HOME and XDG_CACHE_HOME, COREPACK_*. Inherited,
  # they fail every reuse test and pass every refusal test for the wrong reason,
  # so the hooks run without those families; tests below prove each refuses.
  HOOK_ENV_UNSET=()
  for f in $(compgen -e); do
    case "$f" in
      (GIT_*|XDG_CONFIG_HOME|XDG_CACHE_HOME|LOCALAPPDATA|APPDATA|COREPACK_*|NODE_*|PYTHON*|VIRTUAL_ENV|\
       PYTEST_*|MYPY*|PERL*|RUBY*|GEM_*|TS_NODE_*|JAVA_*|_JAVA_*|JDK_*|LD_*|DYLD_*|CARGO_*|*RUSTFLAGS|\
       RUSTDOCFLAGS|RUSTC*|GO*|CLASSPATH|BASH_ENV|ENV|ZDOTDIR|[Nn][Pp][Mm]_[Cc][Oo][Nn][Ff][Ii][Gg]_*|\
       [Pp][Nn][Pp][Mm]_[Cc][Oo][Nn][Ff][Ii][Gg]_*)
        HOOK_ENV_UNSET+=(-u "$f") ;;
    esac
  done
}

teardown() {
  teardown_project_dir
}

# make_fake_tool <name> [version] [dir] — logs "<name> <args>" to calls,
# replays <name>.out, exits with <name>.exit (default 0) after <name>.sleep
# seconds. --version answers without logging.
make_fake_tool() {
  # perl, not a shell script: reuse binds a #! node, python* or perl* program
  # and never parses shell.
  cat > "${3:-$FAKE_BIN}/$1" <<EOF
#!/usr/bin/perl
# version ${2:-1}
my (\$n, \$s) = ("$1", \$ENV{FAKE_STATE});
if (@ARGV && \$ARGV[0] eq "--version") { print "\$n ${2:-1}\n"; exit 0 }
sub slurp { open(my \$f, "<", \$_[0]) or return undef; local \$/; my \$c = <\$f>; \$c }
open(my \$c, ">>", "\$s/calls") or die; print \$c "\$n @ARGV\n"; close \$c;
if (defined(my \$t = slurp("\$s/\$n.sleep"))) { select(undef, undef, undef, \$t) }
if (defined(my \$o = slurp("\$s/\$n.out"))) { print \$o }
if (\$ENV{FAKE_DONE}) { open(my \$d, ">", "\$s/\$n.done"); close \$d }
my \$e = slurp("\$s/\$n.exit") // 0;
exit(\$e + 0);
EOF
  chmod +x "${3:-$FAKE_BIN}/$1"
}

# fake_script <path> <log name> <perl code> — a #!/usr/bin/perl program that
# logs "<log name> <args>" to calls, then runs <perl code>.
fake_script() {
  {
    printf '#!/usr/bin/perl\n'
    printf 'open(my $c, ">>", "$ENV{FAKE_STATE}/calls") or die; print $c "%s @ARGV\\n"; close $c;\n' "$2"
    printf '%s\n' "$3"
  } > "$1"
  chmod +x "$1"
}

calls() {
  [ -f "$FAKE_STATE/calls" ] || { printf 0; return; }
  awk -v p="$1 " 'index($0, p) == 1 { n++ } END { print n + 0 }' "$FAKE_STATE/calls"
}

# A Python project with ruff (argv form) and a dirty code file.
seed_ruff() {
  make_fake_tool ruff
  printf '' > "$PROJECT_DIR/ruff.toml"
  echo 'x = 1' > "$PROJECT_DIR/app.py"
}

# A package.json test script run through a fake npm (shell form).
seed_npm_test() {
  make_fake_tool npm
  cat > "$PROJECT_DIR/package.json" <<'EOF'
{"name":"fixture","scripts":{"test":"true"}}
EOF
  echo 'x = 1' > "$PROJECT_DIR/app.js"
}

hook_for() {
  if [ "$1" = codex ]; then printf '%s' "$CODEX_HOOKS_DIR/stop-verify.sh"; else printf '%s' "$HOOKS_DIR/stop-verify.sh"; fi
}

# run_stop <claude|codex> [VAR=value...]
run_stop() {
  local hook; hook="$(hook_for "$1")"; shift
  run env ${HOOK_ENV_UNSET[@]+"${HOOK_ENV_UNSET[@]}"} PATH="$FAKE_BIN:$PATH" CLAUDE_PROJECT_DIR="$PROJECT_DIR" \
    CODEX_PROJECT_DIR="$PROJECT_DIR" PROCESS_GATE_NO_RECEIPTS=1 \
    FAKE_STATE="$FAKE_STATE" "$@" bash "$hook" <<< '{}'
}

reused() { printf '%s' "$output" | grep -q 'checks reused, not re-run'; }

receipt_files() {
  local f
  for f in "$TRELLIS_HOME/state/stop-receipts/"*; do
    [ ! -e "$f" ] || printf '%s\n' "${f##*/}"
  done
}

@test "an unchanged tree reuses the pass and says so (claude)" {
  seed_ruff
  run_stop claude
  [ "$status" -eq 0 ]
  [ "$(calls ruff)" -eq 1 ]
  [ -z "$output" ]
  run_stop claude
  [ "$status" -eq 0 ]
  [ "$(calls ruff)" -eq 1 ]
  printf '%s' "$output" | jq -e '.additionalContext | test("checks reused, not re-run: pass receipt [0-9a-f]{12}")' >/dev/null
}

@test "an unchanged tree reuses the pass and says so (codex)" {
  seed_ruff
  run_stop codex
  [ "$status" -eq 0 ]
  run_stop codex
  [ "$status" -eq 0 ]
  [ "$(calls ruff)" -eq 1 ]
  printf '%s' "$output" | jq -e '.systemMessage | test("checks reused, not re-run")' >/dev/null
}

@test "receipt store is private: directory 0700, receipt 0600, one per worktree and harness" {
  seed_ruff
  run_stop claude
  run_stop codex
  local dir="$TRELLIS_HOME/state/stop-receipts"
  [ "$(stat -c '%a' "$dir" 2>/dev/null || stat -f '%Lp' "$dir")" = 700 ]
  [ "$(receipt_files | wc -l | tr -d ' ')" -eq 2 ]
  local f
  for f in "$dir"/*.claude "$dir"/*.codex; do
    [ "$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f")" = 600 ]
    head -1 "$f" | grep -Eq '^trellis-stop-pass v1 [0-9a-f]{64}$'
  done
}

@test "a changed tracked file forces a rerun" {
  seed_ruff
  git -C "$PROJECT_DIR" add app.py
  git -C "$PROJECT_DIR" commit -qm app
  echo 'x = 2' > "$PROJECT_DIR/app.py"
  run_stop claude
  [ "$(calls ruff)" -eq 1 ]
  echo 'x = 3' > "$PROJECT_DIR/app.py"
  run_stop claude
  [ "$status" -eq 0 ]
  [ "$(calls ruff)" -eq 2 ]
  run reused
  [ "$status" -eq 1 ]
}

@test "a new untracked file forces a rerun" {
  seed_ruff
  run_stop claude
  echo 'y = 1' > "$PROJECT_DIR/other.py"
  run_stop claude
  [ "$(calls ruff)" -eq 2 ]
}

@test "an index-only change forces a rerun" {
  seed_ruff
  git -C "$PROJECT_DIR" add app.py
  git -C "$PROJECT_DIR" commit -qm app
  echo 'x = 2' > "$PROJECT_DIR/app.py"
  run_stop claude
  [ "$(calls ruff)" -eq 1 ]
  # Same bytes on disk, now staged: only the index moved.
  git -C "$PROJECT_DIR" add app.py
  run_stop claude
  [ "$(calls ruff)" -eq 2 ]
}

@test "a HEAD change forces a rerun" {
  seed_ruff
  run_stop claude
  git -C "$PROJECT_DIR" commit -q --allow-empty -m moved
  run_stop claude
  [ "$(calls ruff)" -eq 2 ]
}

@test "a check-argv change forces a rerun" {
  seed_ruff
  make_fake_tool mypy
  make_fake_tool pytest
  printf '[tool.mypy]\n' > "$PROJECT_DIR/pyproject.toml"
  printf '.venv/\n' > "$PROJECT_DIR/.gitignore"
  run_stop claude
  [ "$(calls mypy)" -eq 1 ]
  # An ignored project venv takes precedence: the tree fingerprint is
  # unchanged, the planned mypy command is not.
  mkdir -p "$PROJECT_DIR/.venv/bin"
  fake_script "$PROJECT_DIR/.venv/bin/mypy" venv-mypy ''
  run_stop claude
  [ "$status" -eq 0 ]
  [ "$(calls venv-mypy)" -eq 1 ]
  [ "$(calls ruff)" -eq 2 ]
}

@test "a tool-version change forces a rerun" {
  seed_ruff
  run_stop claude
  [ "$(calls ruff)" -eq 1 ]
  make_fake_tool ruff 2
  run_stop claude
  [ "$(calls ruff)" -eq 2 ]
}

@test "a steering environment change forces a rerun" {
  seed_ruff
  run_stop claude
  run_stop claude PROCESS_GATE_FORCE_ROOT=1
  [ "$(calls ruff)" -eq 2 ]
}

@test "a failure is never reused: it blocks again and writes no receipt" {
  seed_ruff
  printf 3 > "$FAKE_STATE/ruff.exit"
  printf 'boom' > "$FAKE_STATE/ruff.out"
  run_stop claude
  [ "$status" -eq 2 ]
  [ "$(printf '%s' "$output" | jq -r '.reason')" = "lint (ruff): boom" ]
  [ -z "$(receipt_files)" ]
  run_stop claude
  [ "$status" -eq 2 ]
  [ "$(calls ruff)" -eq 2 ]
  [ -z "$(receipt_files)" ]
}

@test "a failure on the Codex adapter is never reused either" {
  seed_ruff
  printf 3 > "$FAKE_STATE/ruff.exit"
  run_stop codex
  [ "$(printf '%s' "$output" | jq -r '.decision')" = block ]
  run_stop codex
  [ "$(printf '%s' "$output" | jq -r '.decision')" = block ]
  [ "$(calls ruff)" -eq 2 ]
  [ -z "$(receipt_files)" ]
}

@test "a receipt with group/other bits, a symlinked receipt or a wrong key is ignored" {
  seed_ruff
  run_stop claude
  local f; f="$TRELLIS_HOME/state/stop-receipts/$(receipt_files)"
  chmod 644 "$f"
  run_stop claude
  [ "$(calls ruff)" -eq 2 ]
  # The rerun replaced it with a private receipt.
  run_stop claude
  [ "$(calls ruff)" -eq 2 ]
  cp "$f" "$BATS_TEST_TMPDIR/copy"
  rm "$f"
  ln -s "$BATS_TEST_TMPDIR/copy" "$f"
  run_stop claude
  [ "$(calls ruff)" -eq 3 ]
  run_stop claude
  [ "$(calls ruff)" -eq 3 ]
  # Rewrite in place (same inode, still 0600) with another key.
  { printf 'trellis-stop-pass v1 %064d\n' 0; tail -n +2 "$f"; } > "$BATS_TEST_TMPDIR/forged"
  cat "$BATS_TEST_TMPDIR/forged" > "$f"
  [ "$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f")" = 600 ]
  run_stop claude
  [ "$(calls ruff)" -eq 4 ]
}

@test "the first planned failure blocks even when a later check fails sooner" {
  seed_ruff
  seed_npm_test
  printf 1 > "$FAKE_STATE/ruff.sleep"
  printf 1 > "$FAKE_STATE/ruff.exit"
  printf 'RUFF' > "$FAKE_STATE/ruff.out"
  printf 1 > "$FAKE_STATE/npm.exit"
  printf 'TEST' > "$FAKE_STATE/npm.out"
  run_stop claude
  [ "$status" -eq 2 ]
  [ "$(printf '%s' "$output" | jq -r '.reason')" = "lint (ruff): RUFF" ]
}

@test "a decisive failure stops the checks still running; none outlives the hook" {
  seed_ruff
  seed_npm_test
  printf 1 > "$FAKE_STATE/ruff.exit"
  printf 30 > "$FAKE_STATE/npm.sleep"
  local start=$SECONDS
  run_stop claude FAKE_DONE=1
  [ "$status" -eq 2 ]
  [ $((SECONDS - start)) -lt 20 ]
  printf '%s' "$output" | jq -e '.reason | startswith("lint (ruff)")' >/dev/null
  sleep 1
  [ ! -e "$FAKE_STATE/npm.done" ]
  run pgrep -f "$FAKE_BIN/npm"
  [ "$status" -eq 1 ]
}

@test "independent checks run concurrently" {
  seed_ruff
  seed_npm_test
  printf 4 > "$FAKE_STATE/ruff.sleep"
  printf 4 > "$FAKE_STATE/npm.sleep"
  local start=$SECONDS
  run_stop claude
  [ "$status" -eq 0 ]
  [ "$(calls ruff)" -eq 1 ]
  [ "$(calls npm)" -eq 1 ]
  # One after the other would take at least 8 seconds.
  [ $((SECONDS - start)) -lt 8 ]
}

@test "a stop_checks.fast value in .trellis.json has no effect on the test step" {
  seed_npm_test
  make_fake_tool fasttest
  # Committed, on a fetched origin/main, and in the working tree: none of it
  # can swap the detected suite for an agent-chosen command.
  printf '%s\n' '{"schema_version":1,"project_id":"fixture","stop_checks":{"fast":"fasttest"}}' > "$PROJECT_DIR/.trellis.json"
  # The host config names another project only; the repo cannot add one.
  write_host_fast fasttest /elsewhere/project
  git -C "$PROJECT_DIR" add .trellis.json
  git -C "$PROJECT_DIR" commit -qm manifest
  git init -q --bare "$BATS_TEST_TMPDIR/origin.git"
  git -C "$PROJECT_DIR" remote add origin "$BATS_TEST_TMPDIR/origin.git"
  git --git-dir="$BATS_TEST_TMPDIR/origin.git" fetch -q "$PROJECT_DIR" +HEAD:refs/heads/main
  git -C "$PROJECT_DIR" fetch -q origin
  run_stop claude
  [ "$status" -eq 0 ]
  [ "$(calls fasttest)" -eq 0 ]
  [ "$(calls npm)" -eq 1 ]
  printf 4 > "$FAKE_STATE/npm.exit"
  echo 'x = 2' > "$PROJECT_DIR/app.js"
  run_stop claude
  [ "$status" -eq 2 ]
  printf '%s' "$output" | jq -e '.reason | startswith("test (npm run test)")' >/dev/null
  [ "$(calls fasttest)" -eq 0 ]
}

# write_host_fast <command> [root] [mode] — projects.<root>.stop_checks.fast in
# the sandbox TRELLIS_HOME config.json, inside a private 0700 directory.
write_host_fast() {
  write_host_config "$(jq -nc --arg r "${2:-$PROJECT_DIR}" --arg c "$1" '{projects: {($r): {stop_checks: {fast: $c}}}}')" "${3:-600}"
}

# write_host_config <json text> [mode]
write_host_config() {
  mkdir -p "$TRELLIS_HOME"
  chmod 700 "$TRELLIS_HOME"
  printf '%s\n' "$1" > "$TRELLIS_HOME/config.json"
  chmod "${2:-600}" "$TRELLIS_HOME/config.json"
}

note() {
  printf '%s' "$output" | jq -r '.additionalContext // .systemMessage // empty'
}

@test "a host stop_checks.fast replaces the test step and its failure still blocks (both adapters)" {
  seed_npm_test
  make_fake_tool fasttest
  write_host_fast fasttest
  run_stop claude
  [ "$status" -eq 0 ]
  run_stop codex
  [ "$status" -eq 0 ]
  [ "$(calls fasttest)" -eq 2 ]
  [ "$(calls npm)" -eq 0 ]
  note | grep -q 'ran stop_checks.fast from TRELLIS_HOME config.json (fasttest)'
  printf 4 > "$FAKE_STATE/fasttest.exit"
  run_stop claude
  [ "$status" -eq 2 ]
  printf '%s' "$output" | jq -e '.reason | startswith("test (stop_checks.fast: fasttest)")' >/dev/null
  run_stop codex
  printf '%s' "$output" | jq -e '.decision == "block" and (.reason | startswith("test (stop_checks.fast: fasttest)"))' >/dev/null
  [ "$(calls npm)" -eq 0 ]
}

@test "the host entry is keyed by the main checkout: a linked worktree uses it, another root's does not apply" {
  seed_npm_test
  make_fake_tool fasttest
  write_host_fast fasttest /elsewhere/project
  run_stop claude
  [ "$status" -eq 0 ]
  [ "$(calls fasttest)" -eq 0 ]
  [ "$(calls npm)" -eq 1 ]
  write_host_fast fasttest
  git -C "$PROJECT_DIR" add package.json app.js
  git -C "$PROJECT_DIR" commit -qm seed
  local wt="$BATS_TEST_TMPDIR/linked"
  git -C "$PROJECT_DIR" worktree add -q "$wt"
  wt="$(cd "$wt" && pwd -P)"
  echo 'x = 2' > "$wt/app.js"
  run env ${HOOK_ENV_UNSET[@]+"${HOOK_ENV_UNSET[@]}"} PATH="$FAKE_BIN:$PATH" CLAUDE_PROJECT_DIR="$wt" PROCESS_GATE_NO_RECEIPTS=1 \
    FAKE_STATE="$FAKE_STATE" bash -c 'cd "$1" && bash "$2" <<< "{}"' _ "$wt" "$HOOKS_DIR/stop-verify.sh"
  [ "$status" -eq 0 ]
  [ "$(calls fasttest)" -eq 1 ]
  [ "$(calls npm)" -eq 1 ]
}

@test "a host config that is loose, symlinked or in a writable directory is ignored and says so" {
  seed_npm_test
  make_fake_tool fasttest
  local case_ n=0
  for case_ in mode:644 mode:620 mode:700 dir:770 dir:702 symlink; do
    write_host_fast fasttest
    case "$case_" in
      mode:*) chmod "${case_#mode:}" "$TRELLIS_HOME/config.json" ;;
      dir:*) chmod "${case_#dir:}" "$TRELLIS_HOME" ;;
      symlink)
        mkdir -p "$BATS_TEST_TMPDIR/real" && chmod 700 "$BATS_TEST_TMPDIR/real"
        mv "$TRELLIS_HOME/config.json" "$BATS_TEST_TMPDIR/real/config.json"
        ln -s "$BATS_TEST_TMPDIR/real/config.json" "$TRELLIS_HOME/config.json" ;;
    esac
    n=$((n + 1))
    echo "x = $n" > "$PROJECT_DIR/app.js"
    run_stop claude
    [ "$status" -eq 0 ] || { echo "$case_: $output"; false; }
    [ "$(calls fasttest)" -eq 0 ] || { echo "$case_ ran the fast suite"; false; }
    [ "$(calls npm)" -eq "$n" ] || { echo "$case_ skipped the detected suite"; false; }
    note | grep -q 'stop_checks.fast ignored: TRELLIS_HOME config.json must be a regular file you own with mode 0600 or stricter' \
      || { echo "$case_: $output"; false; }
    rm -f "$TRELLIS_HOME/config.json"
    chmod 700 "$TRELLIS_HOME"
  done
  write_host_fast fasttest
  chmod 644 "$TRELLIS_HOME/config.json"
  echo 'x = codex' > "$PROJECT_DIR/app.js"
  run_stop codex
  [ "$(calls fasttest)" -eq 0 ]
  note | grep -q 'stop_checks.fast ignored'
  # A reused pass keeps the note beside its own.
  run_stop codex
  reused
  note | grep -q 'stop_checks.fast ignored'
}

@test "a host config owned by another uid is ignored; an inherited EUID changes nothing" {
  write_host_fast fasttest
  local lib uid
  uid="$(id -u)"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    run bash -c '. "$1"; _se_stop_fast_config "$2" "$3"' _ "$lib" "$PROJECT_DIR" "$((uid + 1))"
    [ "$status" -eq 2 ] && [ -z "$output" ] || { echo "$lib foreign: $status $output"; false; }
    run bash -c '. "$1"; _se_stop_fast_config "$2" "$3"' _ "$lib" "$PROJECT_DIR" "$uid"
    [ "$status" -eq 0 ] && [ "$output" = fasttest ] || { echo "$lib own: $status $output"; false; }
  done
  # The hook passes no uid, so perl's $> decides. A spoofed EUID in the
  # environment (bash would honour it) neither grants nor revokes trust.
  seed_npm_test
  make_fake_tool fasttest
  run_stop claude EUID=0
  [ "$status" -eq 0 ]
  echo 'x = 2' > "$PROJECT_DIR/app.js"
  run_stop codex EUID="$((uid + 1))"
  [ "$(calls fasttest)" -eq 2 ]
  [ "$(calls npm)" -eq 0 ]
}

@test "a malformed host value or unreadable config runs the full test step and says so" {
  seed_npm_test
  make_fake_tool fasttest
  local r="$PROJECT_DIR" cfg n=0
  for cfg in \
    "{\"projects\":{\"$r\":{\"stop_checks\":{\"fast\":3}}}}" \
    "{\"projects\":{\"$r\":{\"stop_checks\":{\"fast\":\"\"}}}}" \
    "{\"projects\":{\"$r\":{\"stop_checks\":{\"fast\":\"a\\nb\"}}}}" \
    "{\"projects\":{\"$r\":{\"stop_checks\":\"fasttest\"}}}" \
    "{\"projects\":[{\"stop_checks\":{\"fast\":\"fasttest\"}}]}" \
    "{stop_checks: not json"; do
    write_host_config "$cfg"
    n=$((n + 1))
    echo "x = $n" > "$PROJECT_DIR/app.js"
    run_stop claude
    [ "$status" -eq 0 ] || { echo "$cfg: $output"; false; }
    [ "$(calls fasttest)" -eq 0 ] || { echo "$cfg ran the fast suite"; false; }
    [ "$(calls npm)" -eq "$n" ] || { echo "$cfg skipped the detected suite"; false; }
    note | grep -q 'stop_checks.fast in TRELLIS_HOME config.json is unreadable or malformed' || { echo "$cfg: $output"; false; }
  done
}

@test "a fast run is never reused and writes no pass receipt (both adapters)" {
  seed_npm_test
  make_fake_tool fasttest
  write_host_fast fasttest
  run_stop claude
  run_stop claude
  run_stop codex
  run_stop codex
  [ "$status" -eq 0 ]
  [ "$(calls fasttest)" -eq 4 ]
  local out="$output"
  run grep -q 'checks reused, not re-run' <<< "$out"
  [ "$status" -eq 1 ]
  [ -z "$(receipt_files)" ]
}

@test "a change to a gitignored file or a new ignored directory forces a rerun" {
  seed_ruff
  printf '.env\nbuild/\n' > "$PROJECT_DIR/.gitignore"
  git -C "$PROJECT_DIR" add .gitignore
  git -C "$PROJECT_DIR" commit -qm ignore
  echo 'TOKEN=a' > "$PROJECT_DIR/.env"
  run_stop claude
  run_stop claude
  [ "$(calls ruff)" -eq 1 ]
  echo 'TOKEN=b' > "$PROJECT_DIR/.env"
  run_stop claude
  [ "$(calls ruff)" -eq 2 ]
  # Git lists no empty directory, so the new ignored directory holds a file.
  mkdir "$PROJECT_DIR/build"
  echo generated > "$PROJECT_DIR/build/out.py"
  run_stop claude
  [ "$(calls ruff)" -eq 3 ]
  # A file one level inside the ignored directory counts too.
  echo regenerated > "$PROJECT_DIR/build/out.py"
  run_stop claude
  [ "$(calls ruff)" -eq 4 ]
  run_stop claude
  [ "$(calls ruff)" -eq 4 ]
}

@test "a cache-named directory is an input: a change inside it forces a rerun (both adapters)" {
  seed_ruff
  printf '.ruff_cache/\n.mypy_cache/\n__pycache__/\n' > "$PROJECT_DIR/.gitignore"
  local h d
  for h in claude codex; do
    for d in .ruff_cache .mypy_cache __pycache__; do
      : > "$FAKE_STATE/calls"
      mkdir -p "$PROJECT_DIR/$d"
      printf 'ok\n' > "$PROJECT_DIR/$d/input"
      run_stop "$h"
      run_stop "$h"
      [ "$(calls ruff)" -eq 1 ] || { echo "$h $d: no reuse"; false; }
      printf 'bad\n' > "$PROJECT_DIR/$d/input"
      run_stop "$h"
      [ "$(calls ruff)" -eq 2 ] || { echo "$h $d: a cache input change was reused"; false; }
    done
  done
}

@test "a check that rewrites a cache earns no receipt until the cache settles" {
  seed_ruff
  printf '.ruff_cache/\n' > "$PROJECT_DIR/.gitignore"
  fake_script "$FAKE_BIN/ruff" ruff 'mkdir ".ruff_cache";
unless (-f "$ENV{FAKE_STATE}/settled") { my $r = int rand 1e9; open(my $f, ">", ".ruff_cache/run-$r") or die; print $f "$r\n" }'
  run_stop claude
  [ -z "$(receipt_files)" ]
  touch "$FAKE_STATE/settled"
  run_stop claude
  run_stop claude
  [ "$(calls ruff)" -eq 2 ]
  reused
}

@test "a .pytest_cache rewritten with the same content keeps reuse; new content does not" {
  seed_ruff
  printf '.pytest_cache/\n' > "$PROJECT_DIR/.gitignore"
  fake_script "$FAKE_BIN/ruff" ruff 'mkdir $_ for ".pytest_cache", ".pytest_cache/v", ".pytest_cache/v/cache";
open(my $f, ">", ".pytest_cache/v/cache/nodeids") or die; print $f "[]\n";'
  run_stop claude
  run_stop claude
  run_stop claude
  [ "$(calls ruff)" -eq 2 ]
  reused
  printf '{"t::x": true}\n' > "$PROJECT_DIR/.pytest_cache/v/cache/lastfailed"
  run_stop claude
  [ "$(calls ruff)" -eq 3 ]
}

# fake_reads_input <file> [perl code] — ruff passes only while the ignored
# input it reads holds "ok", like a test that loads configuration from it,
# then runs [perl code].
fake_reads_input() {
  fake_script "$FAKE_BIN/ruff" ruff "open(my \$f, '<', '$1') or exit 7; exit 7 unless <\$f> eq \"ok\\n\"; ${2:-}"
}

@test "an in-place edit deep inside an ignored directory forces a rerun (both adapters)" {
  local h
  for h in claude codex; do
    : > "$FAKE_STATE/calls"
    seed_ruff
    printf 'build/\n' > "$PROJECT_DIR/.gitignore"
    mkdir -p "$PROJECT_DIR/build/deep"
    printf 'ok\n' > "$PROJECT_DIR/build/deep/input"
    fake_reads_input "$PROJECT_DIR/build/deep/input"
    run_stop "$h"
    run_stop "$h"
    [ "$(calls ruff)" -eq 1 ]
    printf 'no\n' > "$PROJECT_DIR/build/deep/input"
    run_stop "$h"
    [ "$(calls ruff)" -eq 2 ]
    printf '%s' "$output" | jq -e '.decision == "block"' >/dev/null
    printf 'ok\n' > "$PROJECT_DIR/build/deep/input"
  done
}

@test "an ignored input changed while the checks run earns no receipt (both adapters)" {
  local h
  for h in claude codex; do
    : > "$FAKE_STATE/calls"
    rm -rf "$TRELLIS_HOME/state/stop-receipts"
    seed_ruff
    printf '.env\n' > "$PROJECT_DIR/.gitignore"
    printf 'ok\n' > "$PROJECT_DIR/.env"
    # The check consumes .env, then something rewrites it.
    fake_reads_input "$PROJECT_DIR/.env" "open(my \$w, '>', '$PROJECT_DIR/.env') or die; print \$w 'no';"
    run_stop "$h"
    [ "$status" -eq 0 ]
    [ -z "$(receipt_files)" ]
    run_stop "$h"
    [ "$(calls ruff)" -eq 2 ]
    run reused
    [ "$status" -eq 1 ]
  done
}

@test "an application environment variable change forces a rerun (both adapters)" {
  local h
  for h in claude codex; do
    : > "$FAKE_STATE/calls"
    seed_ruff
    run_stop "$h" FEATURE_SWITCH=ok
    run_stop "$h" FEATURE_SWITCH=ok
    [ "$(calls ruff)" -eq 1 ]
    run_stop "$h" FEATURE_SWITCH=bad
    [ "$(calls ruff)" -eq 2 ]
  done
}

@test "harness and agent variables are bound too: SSH_AUTH_SOCK, CLAUDE_CODE_*, CODEX_*, HC_* (both adapters)" {
  local h v
  for h in claude codex; do
    for v in SSH_AUTH_SOCK SSH_AGENT_PID CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID HC_TERMINAL_ID CLAUDE_EFFORT; do
      : > "$FAKE_STATE/calls"
      seed_ruff
      run_stop "$h" "$v=ok"
      run_stop "$h" "$v=ok"
      [ "$(calls ruff)" -eq 1 ] || { echo "$h $v: no reuse"; false; }
      run_stop "$h" "$v=bad"
      [ "$(calls ruff)" -eq 2 ] || { echo "$h $v: a change was reused"; false; }
    done
  done
}

@test "a launcher outside the worktree that is not a package manager is never reused (both adapters)" {
  local h outside="$BATS_TEST_TMPDIR/outside-bin" impl="$BATS_TEST_TMPDIR/impl"
  mkdir -p "$outside"
  printf 'pass\n' > "$impl"
  # A stable launcher whose behavior lives in an implementation it cannot be
  # seen to depend on (a console script, a version-manager shim).
  cat > "$outside/ruff" <<EOF
#!/usr/bin/env bash
printf 'ruff %s\n' "\$*" >> "\$FAKE_STATE/calls"
[ "\$(cat "$impl")" = pass ] || exit 7
EOF
  chmod +x "$outside/ruff"
  printf '' > "$PROJECT_DIR/ruff.toml"
  echo 'x = 1' > "$PROJECT_DIR/app.py"
  for h in claude codex; do
    : > "$FAKE_STATE/calls"
    printf 'pass\n' > "$impl"
    run_stop "$h" PATH="$outside:$PATH"
    run_stop "$h" PATH="$outside:$PATH"
    [ "$status" -eq 0 ]
    [ "$(calls ruff)" -eq 2 ]
    printf 'fail\n' > "$impl"
    run_stop "$h" PATH="$outside:$PATH"
    [ "$(calls ruff)" -eq 3 ]
    printf '%s' "$output" | jq -e '.decision == "block"' >/dev/null
  done
  [ -z "$(receipt_files)" ]
}

# make_pm <install root> <package dir> <name> <bin name> <script> — an installed
# package manager: <bin name> on <install root>/bin links to <script> inside
# the package, which logs a call and sources lib/deep/a/b/implementation.
make_pm() {
  local pkg="$2"
  mkdir -p "$1/bin" "$pkg/bin" "$pkg/lib/deep/a/b"
  printf '{"name":"%s","version":"1.0.0"}\n' "$3" > "$pkg/package.json"
  printf 'return 0\n' > "$pkg/lib/deep/a/b/implementation"
  cat > "$pkg/bin/$5" <<'EOF'
#!/usr/bin/perl
use Cwd "abs_path";
(my $n = $0) =~ s{.*/}{};
open(my $c, ">>", "$ENV{FAKE_STATE}/calls") or die; print $c "$n @ARGV\n"; close $c;
(my $here = abs_path($0)) =~ s{/[^/]*$}{};
open(my $i, "<", "$here/../lib/deep/a/b/implementation") or die;
exit(<$i> =~ /(\d+)/ ? $1 : 0);
EOF
  chmod +x "$pkg/bin/$5"
  ln -s "$pkg/bin/$5" "$1/bin/$4"
}

@test "a package manager is bound by its whole installation tree: a deep edit forces a rerun (both adapters)" {
  local root="$BATS_TEST_TMPDIR/node" pkg h
  pkg="$root/lib/node_modules/npm"
  seed_npm_test
  rm "$FAKE_BIN/npm"
  make_pm "$root" "$pkg" npm npm npm-cli.js
  for h in claude codex; do
    : > "$FAKE_STATE/calls"
    printf 'return 0\n' > "$pkg/lib/deep/a/b/implementation"
    run_stop "$h" PATH="$root/bin:$PATH"
    run_stop "$h" PATH="$root/bin:$PATH"
    [ "$status" -eq 0 ]
    [ "$(calls npm)" -eq 1 ] || { echo "$h: a bound package manager refused reuse"; false; }
    reused
    # Same manifest, same launcher: only code deep in the package changes.
    printf 'return 7\n' > "$pkg/lib/deep/a/b/implementation"
    run_stop "$h" PATH="$root/bin:$PATH"
    [ "$(calls npm)" -eq 2 ] || { echo "$h: a deep package edit was reused"; false; }
    printf '%s' "$output" | jq -e '.decision == "block"' >/dev/null
  done
}

@test "a package manager with no package root, a foreign root name, an escaping link or over 20000 entries is never reused" {
  local root="$BATS_TEST_TMPDIR/node" pkg case_ n=0
  pkg="$root/lib/node_modules/npm"
  seed_npm_test
  rm "$FAKE_BIN/npm"
  for case_ in no-root wrong-name escape huge; do
    rm -rf "$root"
    make_pm "$root" "$pkg" npm npm npm-cli.js
    case "$case_" in
      no-root) rm "$pkg/package.json" ;;
      wrong-name) printf '{"name":"left-pad"}\n' > "$pkg/package.json" ;;
      escape) ln -s "$BATS_TEST_TMPDIR" "$pkg/lib/out" ;;
      huge) perl -e 'for (1 .. 20001) { open my $f, ">", "$ARGV[0]/f$_" or die }' "$pkg/lib/deep" ;;
    esac
    : > "$FAKE_STATE/calls"
    run_stop claude PATH="$root/bin:$PATH"
    run_stop claude PATH="$root/bin:$PATH"
    [ "$status" -eq 0 ] || { echo "$case_: $output"; false; }
    [ "$(calls npm)" -eq 2 ] || { echo "$case_ was reused"; false; }
  done
  [ -z "$(receipt_files)" ]
}

@test "a corepack shim binds corepack and the corepack home it dispatches into" {
  local root="$BATS_TEST_TMPDIR/node" pkg home="$BATS_TEST_TMPDIR/corepack-home"
  pkg="$root/lib/node_modules/corepack"
  seed_npm_test
  rm "$FAKE_BIN/npm"
  printf '{"name":"fixture","packageManager":"pnpm@9.0.0","scripts":{"test":"true"}}\n' > "$PROJECT_DIR/package.json"
  printf 'lockfileVersion: 9\n' > "$PROJECT_DIR/pnpm-lock.yaml"
  make_pm "$root" "$pkg" corepack pnpm pnpm.js
  mkdir -p "$home/v1/pnpm/9.0.0/dist"
  printf 'pnpm\n' > "$home/v1/pnpm/9.0.0/dist/pnpm.cjs"
  run_stop claude PATH="$root/bin:$PATH" COREPACK_HOME="$home"
  run_stop claude PATH="$root/bin:$PATH" COREPACK_HOME="$home"
  [ "$(calls pnpm)" -eq 1 ] || { cat "$FAKE_STATE/calls"; false; }
  reused
  printf 'pnpm, patched\n' > "$home/v1/pnpm/9.0.0/dist/pnpm.cjs"
  run_stop claude PATH="$root/bin:$PATH" COREPACK_HOME="$home"
  [ "$(calls pnpm)" -eq 2 ]
  # No corepack home to bind: corepack would fetch one; never reused.
  run_stop claude PATH="$root/bin:$PATH" COREPACK_HOME="$BATS_TEST_TMPDIR/absent"
  run_stop claude PATH="$root/bin:$PATH" COREPACK_HOME="$BATS_TEST_TMPDIR/absent"
  [ "$(calls pnpm)" -eq 4 ]
}

@test "npm and pnpm config files are bound: an .npmrc or pnpm rc change reruns; a code-moving key refuses reuse" {
  seed_npm_test
  # pnpm's rc lives under ~/.config with XDG_CONFIG_HOME unset (setting it
  # at all refuses reuse).
  local f n=0 h sep
  for f in "$PROJECT_DIR/.npmrc" "$HOME/.npmrc" "$PROJECT_DIR/pnpm-workspace.yaml" "$HOME/.config/pnpm/rc" "$HOME/.config/pnpm/auth.ini"; do
    for h in claude codex; do
      : > "$FAKE_STATE/calls"
      mkdir -p "${f%/*}"
      sep='='; [ "${f%.yaml}" = "$f" ] || sep=': '
      printf 'fund%sfalse\n' "$sep" > "$f"
      run_stop "$h"
      run_stop "$h"
      [ "$(calls npm)" -eq 1 ] || { echo "$h ${f#$BATS_TEST_TMPDIR/}: no reuse"; false; }
      printf 'fund%strue\n' "$sep" > "$f"
      run_stop "$h"
      [ "$(calls npm)" -eq 2 ] || { echo "$h ${f#$BATS_TEST_TMPDIR/}: a config change was reused"; false; }
    done
    rm "$f"
  done
  for n in 'script-shell=/bin/bash' 'pnpmfile=../x.cjs' 'globalconfig=/tmp/x' 'node-options=--require x'; do
    printf '%s\n' "$n" > "$PROJECT_DIR/.npmrc"
    : > "$FAKE_STATE/calls"
    run_stop claude
    run_stop claude
    [ "$(calls npm)" -eq 2 ] || { echo "$n was reused"; false; }
  done
}

@test "npm and pnpm config is read only in a strict simple grammar: any other shape refuses reuse" {
  local lib f body
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    # The shapes real projects write: read and bound.
    printf '%s\n' 'registry=https://r.example/' '//registry.npmjs.org/:_authToken=${NPM_TOKEN}' '# c' '@s:registry=https://x/' \
      > "$PROJECT_DIR/.npmrc"
    printf '%s\n' 'packages:' "  - 'packages/*'" '  - "apps/*"' 'nodeLinker: hoisted' > "$PROJECT_DIR/pnpm-workspace.yaml"
    run bash -c '. "$1"; _se_pm_config "$2"' _ "$lib" "$PROJECT_DIR"
    [ "$status" -eq 0 ] || { echo "${lib#"$BATS_TEST_DIRNAME"/}: plain config refused"; false; }
    for body in '.npmrc registry=a\b' '.npmrc "registry"=x' '.npmrc [sec]' '.npmrc   registry=x' '.npmrc ${X}=1' \
                'pnpm-workspace.yaml "nodeLinker": hoisted' 'pnpm-workspace.yaml ? nodeLinker' \
                'pnpm-workspace.yaml catalog: {a: 1}' 'pnpm-workspace.yaml packages: [a]' 'pnpm-workspace.yaml x: &a 1' \
                'pnpm-workspace.yaml y: *a' 'pnpm-workspace.yaml <<: *a' $'pnpm-workspace.yaml x: |\n  a' \
                $'pnpm-workspace.yaml x: a\n  b' $'pnpm-workspace.yaml onlyBuiltDependencies:\n  - esbuild' \
                'pnpm-workspace.yaml x: "a\tb"' 'pnpm-workspace.yaml x: !!str a' 'pnpm-workspace.yaml ${X}: 1'; do
      f=${body%% *}
      printf '' > "$PROJECT_DIR/.npmrc"
      printf '' > "$PROJECT_DIR/pnpm-workspace.yaml"
      printf '%s\n' "${body#* }" > "$PROJECT_DIR/$f"
      run bash -c '. "$1"; _se_pm_config "$2"' _ "$lib" "$PROJECT_DIR"
      [ "$status" -ne 0 ] || { echo "${lib#"$BATS_TEST_DIRNAME"/}: admitted $body"; false; }
    done
  done
}

@test "npm/pnpm reuse only runs a package.json script: exec, dlx, pnpx, npx and unknown subcommands refuse" {
  local lib cmd
  mkdir -p "$PROJECT_DIR/node_modules/.bin"
  make_fake_tool vitest 1 "$PROJECT_DIR/node_modules/.bin"
  make_fake_tool npm
  make_fake_tool pnpm
  printf '{"scripts":{"test":"vitest run","lint":"pnpm exec eslint","sub":"vitest $(cat x)","redir":"vitest > out"}}\n' > "$PROJECT_DIR/package.json"
  export PATH="$FAKE_BIN:$PATH"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    for cmd in "npm run test" "npm run-script test" "npm test" "pnpm run test"; do
      run bash -c '. "$1"; shift; _se_pm_progs "$@"' _ "$lib" "$PROJECT_DIR" "$PROJECT_DIR" $cmd
      [ "$status" -eq 0 ] && [[ "$output" == *"/node_modules/.bin/vitest"* ]] || { echo "$cmd: $status $output"; false; }
    done
    for cmd in "pnpm exec vitest" "pnpm dlx vitest" "npm exec vitest" "npm x vitest" "pnpm create x" "pnpm install" \
               "npm run" "npm run -s test" "pnpm run lint" "npm run test npx" "pnpm vitest" \
               "npm run sub" "npm run redir" "npm run missing"; do
      run bash -c '. "$1"; shift; _se_pm_progs "$@"' _ "$lib" "$PROJECT_DIR" "$PROJECT_DIR" $cmd
      [ "$status" -ne 0 ] || { echo "$cmd was admitted: $output"; false; }
    done
  done
  # Through the hook: the test script itself reaches for a fetching launcher.
  seed_npm_test
  for cmd in "pnpm dlx vitest" "pnpm exec vitest" "pnpx vitest" "npm exec vitest" "npx vitest"; do
    jq --arg c "$cmd" '.scripts.test = $c' "$PROJECT_DIR/package.json" > "$PROJECT_DIR/p.json"
    mv "$PROJECT_DIR/p.json" "$PROJECT_DIR/package.json"
    : > "$FAKE_STATE/calls"
    run_stop claude
    run_stop claude
    [ "$(calls npm)" -eq 2 ] || { echo "a test script running '$cmd' was reused"; false; }
  done
}

# pm_script_admitted <script>... — runs _se_pm_progs on `npm run t` for each
# script body as "t", on both deps copies; prints the bodies it admitted.
pm_script_admitted() {
  local body lib
  for body in "$@"; do
    jq -n --arg b "$body" '{scripts: {t: $b, unit: "vitest run"}}' > "$PROJECT_DIR/package.json"
    for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
      if bash -c '. "$1"; shift; _se_pm_progs "$@"' _ "$lib" "$PROJECT_DIR" "$PROJECT_DIR" npm run t >/dev/null 2>&1; then
        printf '%s\n' "$body"
      fi
    done
  done
}

# setup_pm_scripts — fake npm and an in-tree vitest the scripts can name.
setup_pm_scripts() {
  mkdir -p "$PROJECT_DIR/node_modules/.bin" "$PROJECT_DIR/sub"
  make_fake_tool vitest 1 "$PROJECT_DIR/node_modules/.bin"
  make_fake_tool npm
  export PATH="$FAKE_BIN:$PATH"
}

# reuse_with_test_script <body> — 0 when a second Stop with that test script
# reused the first.
reuse_with_test_script() {
  jq -n --arg b "$1" '{name: "fixture", scripts: {test: $b, unit: "vitest run"}}' > "$PROJECT_DIR/package.json"
  echo "x = $RANDOM" > "$PROJECT_DIR/app.js"
  : > "$FAKE_STATE/calls"
  run_stop claude
  run_stop claude
  [ "$(calls npm)" -eq 1 ]
}

@test "pm scripts: a leading assignment, cd, export, set, source or . refuses reuse; plain vitest run keeps it" {
  setup_pm_scripts
  [ "$(pm_script_admitted 'vitest run' 'true && vitest run' | wc -l | tr -d ' ')" -eq 4 ]
  [ -z "$(pm_script_admitted 'NODE_ENV=test vitest run' 'cd sub && vitest run' 'export A=1; vitest run' \
       'set -e; vitest run' 'source sub/x; vitest run' '. sub/x; vitest run' 'exit 0')" ]
  reuse_with_test_script 'vitest run'
  run reuse_with_test_script 'cd sub && vitest run'
  [ "$status" -ne 0 ]
  run reuse_with_test_script 'NODE_ENV=test vitest run'
  [ "$status" -ne 0 ]
}

@test "pm scripts: a flag after a nested run's script name refuses reuse unless past --" {
  setup_pm_scripts
  [ "$(pm_script_admitted 'npm run unit' 'npm run unit -- --watch=false' 'npm run unit -- -u' | wc -l | tr -d ' ')" -eq 6 ]
  [ -z "$(pm_script_admitted 'npm run unit --script-shell=/bin/bash' 'npm run unit --prefix=../x' \
       'npm run unit -s' 'npm run unit x --silent')" ]
  # The planned command takes the same rule.
  local lib
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    run bash -c '. "$1"; shift; _se_pm_progs "$@"' _ "$lib" "$PROJECT_DIR" "$PROJECT_DIR" npm run unit --script-shell=/bin/sh
    [ "$status" -ne 0 ]
  done
  reuse_with_test_script 'npm run unit -- --watch=false'
  run reuse_with_test_script 'npm run unit --script-shell=/bin/bash'
  [ "$status" -ne 0 ]
}

@test "pm scripts: arguments a nested run forwards reach the script's last command and take its rules" {
  setup_pm_scripts
  make_fake_tool node 1 "$PROJECT_DIR/node_modules/.bin"
  local body lib
  # npm appends them to the script, so `node --require=preload` is what runs.
  # Forwarded into another npm run, a second reading of -- and flags would
  # follow: refused outright, however plain the words.
  for body in 'npm run base -- --require=preload' 'npm run base -- -e 1' 'npm run base -- --import=x' \
              'npm run base preload -- -c' 'npm run chain -- -r preload' 'npm run unit -- --eval=1' \
              'npm run nest -- --watch=false' 'npm run nest -- -- -e 1' 'npm run nest x'; do
    jq -n --arg b "$body" '{scripts: {t: $b, base: "node", chain: "true && node", unit: "vitest run", nest: "npm run unit"}}' > "$PROJECT_DIR/package.json"
    for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
      run bash -c '. "$1"; shift; _se_pm_progs "$@"' _ "$lib" "$PROJECT_DIR" "$PROJECT_DIR" npm run t
      [ "$status" -eq 1 ] || { echo "${lib#"$BATS_TEST_DIRNAME"/}: admitted $body ($status)"; false; }
    done
  done
  # Plain forwarded words to a tool outside the option families stay admitted,
  # and npm consumes the first --: node receives app.js as its first operand.
  [ "$(pm_script_admitted 'npm run unit -- --watch=false app.test.ts' | wc -l | tr -d ' ')" -eq 2 ]
  jq -n '{scripts: {t: "npm run base -- app.js", base: "node"}}' > "$PROJECT_DIR/package.json"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    run bash -c '. "$1"; shift; _se_pm_progs "$@"' _ "$lib" "$PROJECT_DIR" "$PROJECT_DIR" npm run t
    [ "$status" -eq 0 ] || { echo "${lib#"$BATS_TEST_DIRNAME"/}: node app.js refused ($status)"; false; }
  done
}

@test "pm scripts: inline interpreter code, a word with whitespace or an outside path argument refuses reuse" {
  setup_pm_scripts
  printf 'x\n' > "$PROJECT_DIR/sub/input"
  printf 'x\n' > "$BATS_TEST_TMPDIR/outside-input"
  # A sibling of the worktree, for a relative ../ escape.
  local sib="${PROJECT_DIR%/*}/sibling-$$-$BATS_TEST_NUMBER"
  printf 'x\n' > "$sib"
  local rel="$TRELLIS_HOME/releases/1.0.0"
  mkdir -p "$rel/payload"
  printf '{}\n' > "$rel/release.json"
  printf 'x\n' > "$rel/payload/data"
  [ "$(pm_script_admitted 'vitest run sub/input' "vitest run $(type -P true)" "vitest run $rel/payload/data" \
       'vitest run --reporter=dot' | wc -l | tr -d ' ')" -eq 8 ]
  [ -z "$(pm_script_admitted "sh -c 'vitest run'" 'bash -lc true' 'node -e 1' 'node --eval=1' 'node -pe 1' \
       'python3 -c 1' 'perl -e 1' 'ruby -e 1' "vitest 'a b'" "vitest run $BATS_TEST_TMPDIR/outside-input" \
       "vitest run ../${sib##*/}" "vitest run $rel/release.json" "vitest run $PROJECT_DIR/.git/config")" ]
  rm -f "$sib"
  reuse_with_test_script 'vitest run sub/input'
  # A payload argument binds that release: another release.json behind the
  # same path reruns.
  reuse_with_test_script "vitest run $rel/payload/data"
  printf '{"rebuilt":true}\n' > "$rel/release.json"
  run_stop claude
  [ "$(calls npm)" -eq 2 ] || { echo "a changed release behind a script argument was reused"; false; }
  run reuse_with_test_script "vitest run $BATS_TEST_TMPDIR/outside-input"
  [ "$status" -ne 0 ]
  run reuse_with_test_script 'node -e 1'
  [ "$status" -ne 0 ]
}

@test "pm scripts follow an allowlist grammar: globs, ~, escaping flag values, wrappers and loader options refuse" {
  setup_pm_scripts
  make_fake_tool tsc 1 "$PROJECT_DIR/node_modules/.bin"
  make_fake_tool eslint 1 "$PROJECT_DIR/node_modules/.bin"
  mkdir -p "$PROJECT_DIR/src"
  # A link inside the worktree that leads out of it.
  ln -s "$BATS_TEST_TMPDIR" "$PROJECT_DIR/out-link"
  [ "$(pm_script_admitted 'vitest run' 'tsc --noEmit && vitest run --reporter=dot' 'eslint src --max-warnings=0' \
       'vitest run --config=sub/vitest.config.ts' 'npm run unit -- src/a.test.ts' | wc -l | tr -d ' ')" -eq 10 ]
  local refused
  refused=$(pm_script_admitted 'vitest run src/*.test.ts' 'vitest run ~/x' 'vitest run --config=../x' 'eslint -c../x src' \
    'env node -e 1' 'nice tsc' 'timeout 5 vitest' 'node -r ./x src' 'python -m pytest' 'node --import=./x src' \
    'vitest run "src"' 'vitest run || true' 'vitest run; true' 'vitest run https://example.com/x' \
    'vitest run src/../../x' 'vitest run src/../src' 'npm run unit -- ../x' 'eval true' 'unset A' 'command vitest' \
    'exec vitest' 'xargs vitest' 'vitest run out-link/x' 'vitest run out-link' 'vitest run --dir=out-link/x')
  [ -z "$refused" ] || { echo "admitted: $refused"; false; }
  # Through the hook: a refused form reruns, an admitted chain reuses (with
  # no link out of the worktree left in it, which alone refuses reuse).
  mv "$PROJECT_DIR/out-link" "$BATS_TEST_TMPDIR/out-link.moved"
  reuse_with_test_script 'tsc --noEmit && vitest run --reporter=dot'
  run reuse_with_test_script 'vitest run src/*.test.ts'
  [ "$status" -ne 0 ]
  run reuse_with_test_script 'timeout 5 vitest'
  [ "$status" -ne 0 ]
}

@test "pm scripts: value-taking options only attached, every shell family, and a backstop on inline-code flags" {
  setup_pm_scripts
  make_fake_tool python3 1 "$PROJECT_DIR/node_modules/.bin"
  make_fake_tool fish 1 "$PROJECT_DIR/node_modules/.bin"
  make_fake_tool csh 1 "$PROJECT_DIR/node_modules/.bin"
  make_fake_tool mytool 1 "$PROJECT_DIR/node_modules/.bin"
  make_fake_tool busybox 1 "$PROJECT_DIR/node_modules/.bin"
  printf 'print(1)\n' > "$PROJECT_DIR/script.py"
  [ "$(pm_script_admitted 'python3 -Wignore script.py' 'python3 -u -Xdev script.py' 'mytool --check src' \
       | wc -l | tr -d ' ')" -eq 6 ]
  local refused
  refused=$(pm_script_admitted 'python3 -W ignore -c x' 'python3 -W ignore script.py' 'python3 -X dev script.py' \
    'python3 script.py -c x' 'python3 script.py -m x' 'python3 -Wignore -Ecode script.py' \
    'fish -c x' 'csh -c x' 'fish -lc x' 'mytool -e x' 'mytool -r x' 'mytool --eval=x' 'mytool --require x' \
    'mytool -p x' 'mytool --import=x' 'busybox sh -ec x' 'busybox sh -c x')
  [ -z "$refused" ] || { echo "admitted: $refused"; false; }
  reuse_with_test_script 'python3 -Wignore script.py'
  run reuse_with_test_script 'python3 -W ignore -c x'
  [ "$status" -ne 0 ]
}

@test "a script program outside the worktree must itself be bound: an outside script refuses, a tree one reuses" {
  seed_npm_test
  local outside="$BATS_TEST_TMPDIR/outside-bin"
  mkdir -p "$outside" "$PROJECT_DIR/node_modules/.bin"
  printf '#!/usr/bin/perl\nexit 0;\n' > "$outside/checker"
  chmod +x "$outside/checker"
  jq '.scripts.test = "checker --all"' "$PROJECT_DIR/package.json" > "$PROJECT_DIR/p.json"
  mv "$PROJECT_DIR/p.json" "$PROJECT_DIR/package.json"
  run_stop claude PATH="$FAKE_BIN:$outside:$PATH"
  run_stop claude PATH="$FAKE_BIN:$outside:$PATH"
  [ "$(calls npm)" -eq 2 ] || { echo "an outside script program was reused"; false; }
  cp "$outside/checker" "$PROJECT_DIR/node_modules/.bin/checker"
  : > "$FAKE_STATE/calls"
  run_stop claude PATH="$FAKE_BIN:$outside:$PATH"
  run_stop claude PATH="$FAKE_BIN:$outside:$PATH"
  [ "$(calls npm)" -eq 1 ] || { echo "a node_modules/.bin program refused reuse"; false; }
}

# pnpm_shim <9|11> <shim> <target> <NODE_PATH> — a node_modules/.bin shim
# byte for byte as pnpm writes it (8 writes the 9 shape), running <target>
# (relative to the shim's directory) through node.
pnpm_shim() {
  local cyg tail=""
  if [ "$1" = 9 ]; then
    cyg='    *CYGWIN*) basedir=`cygpath -w "$basedir"`;;'
  else
    cyg='    *CYGWIN*|*MINGW*|*MSYS*)
        if command -v cygpath > /dev/null 2>&1; then
            basedir=`cygpath -w "$basedir"`
        fi
    ;;'
    tail="# cmd-shim-target=$(cd "$(dirname "$2")/$(dirname "$3")" && pwd -P)/${3##*/}"$'\n'
  fi
  {
    printf '%s\n' '#!/bin/sh' 'basedir=$(dirname "$(echo "$0" | sed -e '"'"'s,\\,/,g'"'"')")' '' \
      'case `uname` in' "$cyg" 'esac' '' 'if [ -z "$NODE_PATH" ]; then'
    printf '  export NODE_PATH="%s"\nelse\n  export NODE_PATH="%s:$NODE_PATH"\nfi\n' "$4" "$4"
    printf 'if [ -x "$basedir/node" ]; then\n  exec "$basedir/node"  "$basedir/%s" "$@"\nelse\n  exec node  "$basedir/%s" "$@"\nfi\n' "$3" "$3"
    printf '%s' "$tail"
  } > "$2"
  chmod +x "$2"
}

# seed_pnpm_tsc — a TypeScript project whose tsc is pnpm's shim layout, and a
# native node (a copy of true) first on PATH as $SHIM_NODE_BIN/node.
seed_pnpm_tsc() {
  export SHIM_NODE_BIN="$BATS_TEST_TMPDIR/nodebin"
  PNPM_PKG="$PROJECT_DIR/node_modules/.pnpm/typescript@5.0.0/node_modules"
  mkdir -p "$SHIM_NODE_BIN" "$PROJECT_DIR/node_modules/.bin" "$PNPM_PKG/typescript/bin"
  printf 'node_modules/\n' > "$PROJECT_DIR/.gitignore"
  printf '{}\n' > "$PROJECT_DIR/tsconfig.json"
  echo 'export const x = 1;' > "$PROJECT_DIR/app.ts"
  printf '#!/usr/bin/env node\n' > "$PNPM_PKG/typescript/bin/tsc"
  cp "$(type -P true)" "$SHIM_NODE_BIN/node"
  PNPM_NP="$PNPM_PKG/typescript/node_modules:$PNPM_PKG:$PROJECT_DIR/node_modules/.pnpm/node_modules"
  make_fake_tool npx
}

@test "a real pnpm shim (pnpm 8 to 11) is bound whole: replacing node in place reruns" {
  local v h
  seed_pnpm_tsc
  for v in 9 11; do
    pnpm_shim "$v" "$PROJECT_DIR/node_modules/.bin/tsc" ../.pnpm/typescript@5.0.0/node_modules/typescript/bin/tsc "$PNPM_NP"
    for h in claude codex; do
      cp "$(type -P true)" "$SHIM_NODE_BIN/node.new" && mv "$SHIM_NODE_BIN/node.new" "$SHIM_NODE_BIN/node"
      run_stop "$h" PATH="$FAKE_BIN:$SHIM_NODE_BIN:$PATH"
      [ "$status" -eq 0 ]
      run_stop "$h" PATH="$FAKE_BIN:$SHIM_NODE_BIN:$PATH"
      [ "$status" -eq 0 ]
      reused || { echo "pnpm $v $h: the shim refused reuse: $output"; false; }
      # Same path, same bytes, a new file: what an in-place upgrade looks like.
      cp "$(type -P true)" "$SHIM_NODE_BIN/node.new" && mv "$SHIM_NODE_BIN/node.new" "$SHIM_NODE_BIN/node"
      run_stop "$h" PATH="$FAKE_BIN:$SHIM_NODE_BIN:$PATH"
      run reused
      [ "$status" -eq 1 ] || { echo "pnpm $v $h: a replaced node was reused"; false; }
    done
  done
  [ "$(calls npx)" -eq 0 ]
}

# never_reused <what> — two Stops per adapter, neither second one reused.
never_reused() {
  local h
  for h in claude codex; do
    run_stop "$h" PATH="$FAKE_BIN:$SHIM_NODE_BIN:$PATH"
    [ "$status" -eq 0 ] || { echo "$1 ($h) failed: $output"; return 1; }
    run_stop "$h" PATH="$FAKE_BIN:$SHIM_NODE_BIN:$PATH"
    [ "$status" -eq 0 ] || { echo "$1 ($h) failed: $output"; return 1; }
    if reused; then echo "$1 ($h) was reused"; return 1; fi
  done
}

# seed_bypass — seed_pnpm_tsc, the exact pnpm 9 shim as tsc (reused, as a
# control), and the outside inputs the bypass shapes below reach for.
seed_bypass() {
  seed_pnpm_tsc
  SHIM="$PROJECT_DIR/node_modules/.bin/tsc"
  SHIM_T=../.pnpm/typescript@5.0.0/node_modules/typescript/bin/tsc
  RUFF_IMPL=$(type -P true)
  export RUFF_LIB="$BATS_TEST_TMPDIR/lib.sh" RUFF_CMD=: RUFF_IMPL RUFF_DIR="$BATS_TEST_TMPDIR"
  printf ':\n' > "$RUFF_LIB"
  pnpm_shim 9 "$SHIM" "$SHIM_T" "$PNPM_NP"
  run_stop claude PATH="$FAKE_BIN:$SHIM_NODE_BIN:$PATH"
  run_stop claude PATH="$FAKE_BIN:$SHIM_NODE_BIN:$PATH"
  reused || { echo "the exact shim refused reuse: $output"; return 1; }
}

# shim_plus <line> — the exact shim with <line> before its exec block.
shim_plus() {
  pnpm_shim 9 "$SHIM" "$SHIM_T" "$PNPM_NP"
  LINE="$1" perl -0pi -e 's/^(if \[ -x )/$ENV{LINE}\n$1/m' "$SHIM"
  grep -qF "$1" "$SHIM"
}

@test "tree shell is never parsed: a shim with a sourced file, eval or a dynamic assignment is never reused" {
  local line
  seed_bypass
  for line in '. "$RUFF_LIB"' 'eval "$RUFF_CMD"' 'read -r x < "$RUFF_LIB"' 'printf -v x %s "$RUFF_CMD"'; do
    shim_plus "$line"
    never_reused "the shim plus $line"
  done
}

@test "tree shell is never parsed: a shell under a name no list knows is never reused" {
  seed_bypass
  ln -s /bin/sh "$SHIM_NODE_BIN/fakesh"
  printf '#!%s\nexit 0\n' "$SHIM_NODE_BIN/fakesh" > "$SHIM"
  never_reused 'an unlisted interpreter'
}

@test "tree shell is never parsed: a command word that is not a plain exec is never reused" {
  local body
  seed_bypass
  for body in '"$RUFF_IMPL" --version' '"exec" "$RUFF_IMPL"' 'ex\ec "$RUFF_IMPL"'; do
    printf '#!/bin/sh\n%s\n' "$body" > "$SHIM"
    never_reused "$body"
  done
}

@test "tree shell is never parsed: a cd before the exec, or the shim linked from another directory, is never reused" {
  seed_bypass
  shim_plus 'cd "$RUFF_DIR"'
  never_reused 'the shim plus a cd'
  mkdir -p "$PROJECT_DIR/node_modules/tools"
  rm "$SHIM"
  pnpm_shim 9 "$PROJECT_DIR/node_modules/tools/tsc" "$SHIM_T" "$PNPM_NP"
  ln -s ../tools/tsc "$SHIM"
  never_reused 'a shim linked from another directory'
}

@test "a pnpm shim is bound only through an absolute path in its own directory" {
  local lib
  seed_pnpm_tsc
  pnpm_shim 11 "$PROJECT_DIR/node_modules/.bin/tsc" ../.pnpm/typescript@5.0.0/node_modules/typescript/bin/tsc "$PNPM_NP"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    run bash -c '. "$1"; shift; PATH="$SHIM_NODE_BIN:$PATH" _se_tool_closure "$@" | cut -f1' _ "$lib" "$PROJECT_DIR" "$PROJECT_DIR/node_modules/.bin/tsc"
    [ "$output" = tree ]
    run bash -c 'cd "$2" && . "$1" && PATH="$SHIM_NODE_BIN:$PATH" _se_tool_closure "$2" node_modules/.bin/tsc | cut -f1' _ "$lib" "$PROJECT_DIR"
    [ "$output" = interpreter ]
    # A NODE_PATH entry outside the worktree is not bound code.
    pnpm_shim 11 "$PROJECT_DIR/node_modules/.bin/tsc" ../.pnpm/typescript@5.0.0/node_modules/typescript/bin/tsc "$BATS_TEST_TMPDIR"
    run bash -c '. "$1"; shift; PATH="$SHIM_NODE_BIN:$PATH" _se_tool_closure "$@" | cut -f1' _ "$lib" "$PROJECT_DIR" "$PROJECT_DIR/node_modules/.bin/tsc"
    [ "$output" = interpreter ]
    pnpm_shim 11 "$PROJECT_DIR/node_modules/.bin/tsc" ../.pnpm/typescript@5.0.0/node_modules/typescript/bin/tsc "$PNPM_NP"
  done
}

@test "a pnpm shim reached by a path with a byte outside the plain set is never bound" {
  local lib top="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$top/node_modules/.bin" "$top/node_modules/.pnpm/t@1/node_modules/t/bin" "$BATS_TEST_TMPDIR/nodebin"
  top=$(cd "$top" && pwd -P)
  cp "$(type -P true)" "$BATS_TEST_TMPDIR/nodebin/node"
  printf '#!/usr/bin/env node\n' > "$top/node_modules/.pnpm/t@1/node_modules/t/bin/t"
  pnpm_shim 11 "$top/node_modules/.bin/t" ../.pnpm/t@1/node_modules/t/bin/t "$top/node_modules/.pnpm/node_modules"
  # The shim turns \ into / when it computes $basedir; Perl would not.
  ln -s node_modules/.bin "$top/we\ird"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    run bash -c '. "$1"; shift; PATH="$BATS_TEST_TMPDIR/nodebin:$PATH" _se_tool_closure "$@" | cut -f1' _ "$lib" "$top" "$top/node_modules/.bin/t"
    [ "$output" = tree ] || { echo "${lib#"$BATS_TEST_DIRNAME"/}: the plain path is not bound: $output"; false; }
    run bash -c '. "$1"; shift; PATH="$BATS_TEST_TMPDIR/nodebin:$PATH" _se_tool_closure "$@" | cut -f1' _ "$lib" "$top" "$top/we\ird/t"
    [ "$output" = interpreter ] || { echo "${lib#"$BATS_TEST_DIRNAME"/}: $output"; false; }
  done
}

@test "an environment variable that selects code refuses reuse; memory and warning NODE_OPTIONS keep it" {
  seed_ruff
  local module="$BATS_TEST_TMPDIR/preload.cjs" empty="$BATS_TEST_TMPDIR/empty.sh" h e n=0
  printf 'module.exports = {};\n' > "$module"
  : > "$empty"
  for h in claude codex; do
    : > "$FAKE_STATE/calls"
    run_stop "$h" NODE_OPTIONS="--max-old-space-size=4096 --no-warnings"
    run_stop "$h" NODE_OPTIONS="--max-old-space-size=4096 --no-warnings"
    [ "$status" -eq 0 ]
    [ "$(calls ruff)" -eq 1 ] || { echo "$h: memory and warning flags refused reuse"; false; }
  done
  # Each names code outside the key: the same text could select new bytes.
  : > "$FAKE_STATE/calls"
  for e in "NODE_OPTIONS=--require=$module" "NODE_OPTIONS=--max-old-space-size=4096 -r $module" \
           "NODE_OPTIONS=--import=$module" "NODE_PATH=$BATS_TEST_TMPDIR" "PYTHONPATH=$BATS_TEST_TMPDIR" \
           "RUBYOPT=-r$module" "PERL5LIB=$BATS_TEST_TMPDIR" "LD_PRELOAD=$module" "BASH_ENV=$empty"; do
    for h in claude codex; do
      run_stop "$h" "$e"
      run_stop "$h" "$e"
      [ "$status" -eq 0 ]
      n=$((n + 2))
      [ "$(calls ruff)" -eq "$n" ] || { echo "$h: reused with $e"; false; }
    done
  done
}

@test "the Cargo, Rust, Go and Git variable families refuse reuse, but for a short list that selects no code" {
  seed_ruff
  local e n=0
  # Paths to trusted caches or code, wrappers and flags: never reused.
  for e in "GOPATH=$BATS_TEST_TMPDIR" "GOCACHE=$BATS_TEST_TMPDIR" "GOMODCACHE=$BATS_TEST_TMPDIR" "GOWORK=off" \
           "GOTOOLCHAIN=local" "CARGO_HOME=$BATS_TEST_TMPDIR" "CARGO_TARGET_DIR=$BATS_TEST_TMPDIR" \
           "CARGO_ENCODED_RUSTFLAGS=-Cx" "RUSTDOCFLAGS=-Zx" "RUSTC_BOOTSTRAP=1" "GIT_SSH_COMMAND=ssh" "GIT_EDITOR=vim" \
           "GIT_CONFIG_GLOBAL=$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1 GIT_OPTIONAL_LOCKS=0; do
    run_stop claude "$e"
    run_stop claude "$e"
    [ "$status" -eq 0 ]
    n=$((n + 2))
    [ "$(calls ruff)" -eq "$n" ] || { echo "reused with $e"; false; }
  done
  # Display, targets and modes, bound by their text: reused.
  for e in CARGO_TERM_COLOR=always GOOS=darwin GOPROXY=direct GIT_EDITOR=true GOOGLE_CLOUD_PROJECT=x; do
    run_stop claude "$e"
    run_stop claude "$e"
    [ "$status" -eq 0 ]
    n=$((n + 1))
    [ "$(calls ruff)" -eq "$n" ] || { echo "$e refused reuse"; false; }
  done
}

# seed_toolchain <cargo|go> — a project the hook checks with a fake cargo or go.
seed_toolchain() {
  make_fake_tool "$1"
  if [ "$1" = cargo ]; then printf '[package]\nname = "x"\n' > "$PROJECT_DIR/Cargo.toml"
  else printf 'module x\n' > "$PROJECT_DIR/go.mod"; fi
}

@test "a Rust or Go check is never reused, even as a script the closure could bind" {
  local tool
  for tool in cargo go; do
    seed_toolchain "$tool"
    : > "$FAKE_STATE/calls"
    run_stop claude
    run_stop claude
    [ "$status" -eq 0 ]
    [ "$(calls "$tool")" -ge 2 ] || { echo "$tool: no check ran"; false; }
    run reused
    [ "$status" -eq 1 ] || { echo "$tool was reused"; false; }
    [ -z "$(receipt_files)" ]
    rm -f "$PROJECT_DIR/Cargo.toml" "$PROJECT_DIR/go.mod"
  done
}

@test "a native program that is not a listed interpreter is never reused" {
  seed_ruff
  cp "$(type -P true)" "$FAKE_BIN/ruff"
  run_stop claude
  run_stop claude
  [ "$status" -eq 0 ]
  run reused
  [ "$status" -eq 1 ] || { echo "a native ruff was reused"; false; }
  [ -z "$(receipt_files)" ]
}

@test "npm settings in the environment that relocate config or code refuse reuse, in any case" {
  seed_npm_test
  local e n=0
  for e in "npm_config_userconfig=$HOME/other.npmrc" "NPM_CONFIG_GLOBALCONFIG=$HOME/g.npmrc" "Npm_Config_Prefix=$HOME/p" \
           "npm_config_script_shell=/bin/sh" "NPM_CONFIG_NODE_OPTIONS=--require=x" "pnpm_config_scriptshell=/bin/sh" \
           "npm_config_global-pnpmfile=x"; do
    run_stop claude "$e"
    run_stop claude "$e"
    [ "$status" -eq 0 ]
    n=$((n + 2))
    [ "$(calls npm)" -eq "$n" ] || { echo "reused with $e"; false; }
  done
  # A setting that moves nothing keeps reuse.
  run_stop claude npm_config_loglevel=warn
  run_stop claude npm_config_loglevel=warn
  [ "$(calls npm)" -eq $((n + 1)) ]
}

@test "the environment is read raw: a name bash cannot list is bound, an exported function refuses reuse" {
  seed_ruff
  run_stop claude 'a.b=1'
  run_stop claude 'a.b=1'
  [ "$(calls ruff)" -eq 1 ]
  run_stop claude 'a.b=2'
  [ "$(calls ruff)" -eq 2 ] || { echo "a change to a.b was reused"; false; }
  # Any exported function, whatever its name, could stand in for a program
  # some check runs.
  helper() { :; }
  export -f helper
  run_stop claude
  run_stop claude
  export -fn helper
  [ "$status" -eq 0 ]
  run reused
  [ "$status" -eq 1 ] || { echo "reused with an exported function"; false; }
}

@test "a #! line is read whole: past 256 bytes, or with no newline in 4096, a hidden word refuses reuse" {
  local pad
  seed_ruff
  pad=$(printf '%300s' '')
  { printf '#!/usr/bin/perl%s-w\n' "$pad"; tail -n +2 "$FAKE_BIN/ruff"; } > "$FAKE_BIN/ruff.new"
  mv "$FAKE_BIN/ruff.new" "$FAKE_BIN/ruff" && chmod +x "$FAKE_BIN/ruff"
  run_stop claude
  run_stop claude
  [ "$status" -eq 0 ]
  [ "$(calls ruff)" -eq 2 ] || { echo "a word past 256 bytes of the #! line was reused"; false; }
  # No newline in 4096 bytes: the line cannot be read whole (macOS will not
  # even run it, Linux reads its first 256 bytes), so it binds nothing.
  pad=$(printf '%5000s' '')
  { printf '#!/usr/bin/perl%s\n' "$pad"; tail -n +2 "$FAKE_BIN/ruff"; } > "$FAKE_BIN/ruff.new"
  mv "$FAKE_BIN/ruff.new" "$FAKE_BIN/ruff" && chmod +x "$FAKE_BIN/ruff"
  local lib
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    run bash -c '. "$1"; shift; _se_tool_closure "$@" | cut -f1' _ "$lib" "$PROJECT_DIR" "$FAKE_BIN/ruff"
    [ "$output" = interpreter ] || { echo "${lib#"$BATS_TEST_DIRNAME"/}: a #! line with no newline in 4096 bytes is $output"; false; }
  done
}

@test "vitest's results cache is bound by file list and failed flags, not durations" {
  seed_ruff
  printf 'node_modules/\n' > "$PROJECT_DIR/.gitignore"
  local d="$PROJECT_DIR/node_modules/.vite/vitest/da39a3ee5e6b4b0d3255bfef95601890afd80709" h
  mkdir -p "$d"
  results() { printf '{"version":"4.1.10","results":[%s]}' "$1" > "$d/results.json"; }
  local a='[":a.test.ts",{"duration":10.5,"failed":false}]' b='[":b.test.ts",{"duration":3,"failed":false}]'
  for h in claude codex; do
    : > "$FAKE_STATE/calls"
    results "$a,$b"
    run_stop "$h"
    run_stop "$h"
    [ "$(calls ruff)" -eq 1 ] || { echo "$h: no reuse"; false; }
    # Durations and order only: kept.
    results '[":b.test.ts",{"duration":4.25,"failed":false}],[":a.test.ts",{"duration":99,"failed":false}]'
    run_stop "$h"
    [ "$(calls ruff)" -eq 1 ] || { echo "$h: a duration change refused reuse"; false; }
    results '[":a.test.ts",{"duration":10.5,"failed":true}],'"$b"
    run_stop "$h"
    [ "$(calls ruff)" -eq 2 ] || { echo "$h: a failed flag change was reused"; false; }
    results "$a"
    run_stop "$h"
    [ "$(calls ruff)" -eq 3 ] || { echo "$h: a removed entry was reused"; false; }
    results "$a,$b,"'[":c.test.ts",{"duration":1,"failed":false}]'
    run_stop "$h"
    [ "$(calls ruff)" -eq 4 ] || { echo "$h: an added entry was reused"; false; }
  done
  for bad in 'not json' '{"version":"4","results":{}}' '{"version":"4","results":[[":a",{"failed":"no"}]]}' \
             '{"version":"4","results":[[":a",{"failed":false,"retry":1}]]}'; do
    printf '%s' "$bad" > "$d/results.json"
    : > "$FAKE_STATE/calls"
    run_stop claude
    run_stop claude
    [ "$(calls ruff)" -eq 2 ] || { echo "unrecognised results.json was reused: $bad"; false; }
  done
}

@test "vitest's file list cannot be forged by a name holding a record separator" {
  seed_ruff
  printf 'node_modules/\n' > "$PROJECT_DIR/.gitignore"
  local d="$PROJECT_DIR/node_modules/.vite/vitest/hash" h
  mkdir -p "$d"
  for h in claude codex; do
    : > "$FAKE_STATE/calls"
    printf '%s' '{"version":"4","results":[[":a",{"duration":1,"failed":false}],[":b",{"duration":1,"failed":false}]]}' > "$d/results.json"
    run_stop "$h"
    run_stop "$h"
    [ "$(calls ruff)" -eq 1 ] || { echo "$h: no reuse"; false; }
    # One entry whose name spells the two records above, joined by a tab and
    # a newline: another file list, so another key.
    printf '%s' '{"version":"4","results":[[":a\t0\n:b",{"duration":1,"failed":false}]]}' > "$d/results.json"
    run_stop "$h"
    [ "$(calls ruff)" -eq 2 ] || { echo "$h: a one-entry list that serialises like two entries was reused"; false; }
  done
  # A number for a name or version is not what vitest writes: refused.
  for bad in '{"version":"4","results":[[1,{"failed":false}]]}' '{"version":4,"results":[[":a",{"failed":false}]]}'; do
    printf '%s' "$bad" > "$d/results.json"
    : > "$FAKE_STATE/calls"
    run_stop claude
    run_stop claude
    [ "$(calls ruff)" -eq 2 ] || { echo "unrecognised results.json was reused: $bad"; false; }
  done
}

@test "an ignored link into a release payload binds that release; elsewhere under TRELLIS_HOME it refuses reuse" {
  seed_ruff
  local rel="$TRELLIS_HOME/releases/1.0.0" case_
  mkdir -p "$rel/payload/core-rules" "$rel/other" "$TRELLIS_HOME/state/x" "$TRELLIS_HOME/releases/2.0.0/payload"
  printf '{"version":"1.0.0"}\n' > "$rel/release.json"
  printf '.trellis/\n' > "$PROJECT_DIR/.gitignore"
  git -C "$PROJECT_DIR" add .gitignore
  git -C "$PROJECT_DIR" commit -qm ignore
  mkdir -p "$PROJECT_DIR/.trellis"
  ln -s "$rel/payload" "$PROJECT_DIR/.trellis/runtime"
  run_stop claude
  run_stop claude
  [ "$(calls ruff)" -eq 1 ] || { echo "a payload link refused reuse"; false; }
  # Another release.json behind the same link text: another release.
  printf '{"version":"1.0.0","rebuilt":true}\n' > "$rel/release.json"
  run_stop claude
  [ "$(calls ruff)" -eq 2 ] || { echo "a changed release.json was reused"; false; }
  for case_ in "$rel/other" "$rel" "$TRELLIS_HOME/state/x" "$TRELLIS_HOME/releases/2.0.0/payload"; do
    rm "$PROJECT_DIR/.trellis/runtime"
    ln -s "$case_" "$PROJECT_DIR/.trellis/runtime"
    : > "$FAKE_STATE/calls"
    run_stop claude
    run_stop claude
    [ "$(calls ruff)" -eq 2 ] || { echo "${case_#$TRELLIS_HOME/} was reused"; false; }
  done
}

@test "tsc and eslint run from node_modules/.bin with the npx argv, and reuse" {
  local real_npx
  real_npx=$(command -v npx) || skip "npx is not installed"
  printf 'node_modules/\n' > "$PROJECT_DIR/.gitignore"
  printf '{}\n' > "$PROJECT_DIR/tsconfig.json"
  printf 'export default [];\n' > "$PROJECT_DIR/eslint.config.js"
  echo 'export const x = 1;' > "$PROJECT_DIR/app.ts"
  mkdir -p "$PROJECT_DIR/node_modules/.bin"
  make_fake_tool tsc 1 "$PROJECT_DIR/node_modules/.bin"
  make_fake_tool eslint 9 "$PROJECT_DIR/node_modules/.bin"
  # npx itself must not run: a wrapper logs any call before handing over.
  printf '#!/usr/bin/env bash\nprintf "npx %%s\\n" "$*" >> "$FAKE_STATE/calls"\nexec %q "$@"\n' "$real_npx" > "$FAKE_BIN/npx"
  chmod +x "$FAKE_BIN/npx"
  printf 'app.ts(1,1): error TS1005\n' > "$FAKE_STATE/tsc.out"
  printf 2 > "$FAKE_STATE/tsc.exit"
  run_stop claude
  [ "$status" -eq 2 ]
  local direct="$output"
  [ "$(calls npx)" -eq 0 ]
  local direct_calls; direct_calls=$(grep '^tsc ' "$FAKE_STATE/calls")
  # The npx form, run by hand: same argv reaches tsc, same output.
  : > "$FAKE_STATE/calls"
  run bash -c 'cd "$1" && PATH="$2:$PATH" FAKE_STATE="$3" "$4" --no-install tsc --noEmit' _ "$PROJECT_DIR" "$FAKE_BIN" "$FAKE_STATE" "$real_npx"
  [ "$status" -eq 2 ]
  [ "$(grep '^tsc ' "$FAKE_STATE/calls")" = "$direct_calls" ]
  # npx adds its own "npm notice run ..." lines; the tool's output is the same.
  local tool_out; tool_out=$(printf '%s\n' "$output" | grep -v '^npm notice ')
  [ "$(printf '%s' "$direct" | jq -r .reason)" = "typecheck (tsc): $tool_out" ] \
    || { echo "direct: $direct"; echo "npx: $output"; false; }
  # Passing, the direct form reuses; eslint got the same argv as under npx.
  rm "$FAKE_STATE/tsc.exit" "$FAKE_STATE/tsc.out"
  : > "$FAKE_STATE/calls"
  run_stop claude
  run_stop claude
  [ "$status" -eq 0 ]
  reused
  [ "$(grep -c '^eslint \. --quiet$' "$FAKE_STATE/calls")" -eq 1 ]
  [ "$(calls npx)" -eq 0 ]
}

@test "with no node_modules/.bin copy inside the worktree, tsc keeps the npx form and is never reused" {
  printf 'node_modules/\n' > "$PROJECT_DIR/.gitignore"
  printf '{}\n' > "$PROJECT_DIR/tsconfig.json"
  echo 'export const x = 1;' > "$PROJECT_DIR/app.ts"
  # Dependencies are installed, but no tsc under node_modules/.bin here.
  mkdir -p "$PROJECT_DIR/node_modules/left-pad"
  make_fake_tool npx
  run_stop claude
  run_stop claude
  [ "$status" -eq 0 ]
  [ "$(grep -c '^npx --no-install tsc --noEmit$' "$FAKE_STATE/calls")" -eq 2 ]
  [ -z "$(receipt_files)" ]
}

@test "an outside program without a #! line, or a tree script with an outside script interpreter, is never reused" {
  local h outside="$BATS_TEST_TMPDIR/outside-bin" impl="$BATS_TEST_TMPDIR/impl"
  mkdir -p "$outside"
  printf '' > "$PROJECT_DIR/ruff.toml"
  echo 'x = 1' > "$PROJECT_DIR/app.py"
  # Executable text with no #!: bash runs it itself (ENOEXEC fallback).
  cat > "$outside/ruff" <<EOF
printf 'ruff %s\n' "\$*" >> "\$FAKE_STATE/calls"
. "$impl"
EOF
  chmod +x "$outside/ruff"
  for h in claude codex; do
    : > "$FAKE_STATE/calls"
    printf 'return 0\n' > "$impl"
    run_stop "$h" PATH="$outside:$PATH"
    run_stop "$h" PATH="$outside:$PATH"
    [ "$status" -eq 0 ]
    [ "$(calls ruff)" -eq 2 ] || { echo "$h: a no-#! outside program was reused"; false; }
    printf 'return 7\n' > "$impl"
    run_stop "$h" PATH="$outside:$PATH"
    printf '%s' "$output" | jq -e '.decision == "block"' >/dev/null
  done
  # A tree program whose #! interpreter has a listed name but is a script
  # outside the worktree.
  rm "$outside/ruff"
  printf '#!/bin/sh\nexec /usr/bin/perl "$@"\n' > "$outside/perl"
  chmod +x "$outside/perl"
  fake_script "$FAKE_BIN/ruff" ruff ''
  perl -pi -e 's{^#!/usr/bin/perl$}{#!/usr/bin/env perl} if $. == 1' "$FAKE_BIN/ruff"
  : > "$FAKE_STATE/calls"
  run_stop claude PATH="$FAKE_BIN:$outside:$PATH"
  run_stop claude PATH="$FAKE_BIN:$outside:$PATH"
  [ "$status" -eq 0 ]
  [ "$(calls ruff)" -eq 2 ] || { echo "a script-interpreted tree program was reused"; false; }
  [ -z "$(receipt_files)" ]
}

@test "ignored symlinks: a chain or .. escape to an outside file, an outside text file, a dangling link or .git/ refuses reuse" {
  seed_ruff
  local out="$BATS_TEST_TMPDIR/outside" case_ n=0
  mkdir -p "$out"
  printf 'ok\n' > "$out/input"
  printf '.alias\n.up\n.text\n.dangle\n.gitlink\n' > "$PROJECT_DIR/.gitignore"
  git -C "$PROJECT_DIR" add .gitignore
  git -C "$PROJECT_DIR" commit -qm ignore
  for case_ in chain dotdot text dangle git; do
    rm -f "$PROJECT_DIR/bridge" "$PROJECT_DIR/.alias" "$PROJECT_DIR/.up" "$PROJECT_DIR/.text" "$PROJECT_DIR/.dangle" "$PROJECT_DIR/.gitlink"
    case "$case_" in
      # An untracked in-worktree bridge to an outside directory, and an
      # ignored link through it: lexically inside, physically outside.
      chain) ln -s "$out" "$PROJECT_DIR/bridge"; ln -s bridge/input "$PROJECT_DIR/.alias" ;;
      dotdot) ln -s "../${out##*/}/input" "$PROJECT_DIR/.up"
              mv "$out" "${PROJECT_DIR%/*}/${out##*/}" && out="${PROJECT_DIR%/*}/${out##*/}" ;;
      text) ln -s "$out/input" "$PROJECT_DIR/.text" ;;
      dangle) ln -s "$out/missing" "$PROJECT_DIR/.dangle" ;;
      git) ln -s .git/config "$PROJECT_DIR/.gitlink" ;;
    esac
    : > "$FAKE_STATE/calls"
    run_stop claude
    run_stop claude
    [ "$status" -eq 0 ] || { echo "$case_: $output"; false; }
    [ "$(calls ruff)" -eq 2 ] || { echo "$case_ was reused"; false; }
    if [ "$case_" = dotdot ]; then mv "$out" "$BATS_TEST_TMPDIR/outside"; out="$BATS_TEST_TMPDIR/outside"; fi
  done
}

@test "ignored symlinks: an outside native binary is bound by identity, an inside target by its physical path" {
  seed_ruff
  local bin="$BATS_TEST_TMPDIR/bin" h
  mkdir -p "$bin"
  cp "$(command -v ls)" "$bin/py1"
  cp "$(command -v cat)" "$bin/py2"
  printf 'one\n' > "$PROJECT_DIR/a.txt"
  printf 'two\n' > "$PROJECT_DIR/b.txt"
  printf '.venv/\n' > "$PROJECT_DIR/.gitignore"
  mkdir -p "$PROJECT_DIR/.venv/bin"
  ln -s "$bin/py1" "$PROJECT_DIR/.venv/bin/python"
  # An ignored link that reaches a worktree file through an outside hop.
  ln -s "$bin/hop" "$PROJECT_DIR/.venv/bin/data"
  for h in claude codex; do
    : > "$FAKE_STATE/calls"
    rm -f "$bin/hop"
    ln -s "$PROJECT_DIR/a.txt" "$bin/hop"
    run_stop "$h"
    run_stop "$h"
    [ "$(calls ruff)" -eq 1 ] || { echo "$h: a native interpreter or inside link refused reuse"; false; }
    # The binary behind the same link text is replaced in place.
    cp "$bin/py2" "$bin/py1.new" && mv "$bin/py1.new" "$bin/py1"
    run_stop "$h"
    [ "$(calls ruff)" -eq 2 ] || { echo "$h: a replaced native target was reused"; false; }
    cp "$(command -v ls)" "$bin/py1.new" && mv "$bin/py1.new" "$bin/py1"
    run_stop "$h"
    run_stop "$h"
    [ "$(calls ruff)" -eq 3 ]
    # Same link text, another unchanged worktree file behind the outside hop.
    rm "$bin/hop" && ln -s "$PROJECT_DIR/b.txt" "$bin/hop"
    run_stop "$h"
    [ "$(calls ruff)" -eq 4 ] || { echo "$h: a retargeted chain was reused"; false; }
  done
}

@test "a tree that changes while the checks run earns no receipt" {
  seed_ruff
  # The fake rewrites a tracked-candidate file mid-run.
  fake_script "$FAKE_BIN/ruff" ruff 'open(my $f, ">", "generated.py") or die; print $f "z = ", int rand 1e9, "\n";'
  run_stop claude
  [ "$status" -eq 0 ]
  [ -z "$(receipt_files)" ]
}

# --- incremental fingerprint (turn-baseline / stop-verify) --------------------

fp() { bash -c '. "$1"; _se_tree_fingerprint "$2" "$3"' _ "$HOOKS_DIR/lib/deps.sh" "$PROJECT_DIR" "${1:-}"; }

@test "the cached fingerprint equals the uncached one and never hides a same-size edit" {
  local cache="$BATS_TEST_TMPDIR/fp-cache"
  echo 'aaaa' > "$PROJECT_DIR/a.txt"
  echo 'bbbb' > "$PROJECT_DIR/b.txt"
  # Back-date both files so they are old enough to be cached.
  touch -t 202001010000 "$PROJECT_DIR/a.txt" "$PROJECT_DIR/b.txt"
  sleep 3
  local plain cached
  plain=$(fp)
  cached=$(fp "$cache")
  [ "$plain" = "$cached" ]
  [ "$(grep -c $'\ta.txt$' "$cache")" -eq 1 ]
  [ "$(fp "$cache")" = "$plain" ]
  # Same size, same mtime: only ctime and content differ.
  echo 'cccc' > "$PROJECT_DIR/a.txt"
  touch -t 202001010000 "$PROJECT_DIR/a.txt"
  [ "$(fp "$cache")" = "$(fp)" ]
  [ "$(fp "$cache")" != "$plain" ]
}

@test "a matching cache entry is used, a cache with group/other bits is not" {
  local cache="$BATS_TEST_TMPDIR/fp-cache"
  echo 'aaaa' > "$PROJECT_DIR/a.txt"
  sleep 3
  local plain; plain=$(fp)
  fp "$cache" >/dev/null
  # Forge the cached blob id: a consulted cache now changes the hash.
  sed -i.bak $'s/\t[0-9a-f]*\ta.txt$/\t0000000000000000000000000000000000000000\ta.txt/' "$cache"
  rm -f "$cache.bak"
  [ "$(fp "$cache")" != "$plain" ]
  sed -i.bak $'s/\t[0-9a-f]*\ta.txt$/\t0000000000000000000000000000000000000000\ta.txt/' "$cache"
  rm -f "$cache.bak"
  chmod 644 "$cache"
  [ "$(fp "$cache")" = "$plain" ]
}

# --- round 4 ------------------------------------------------------------------

@test "a #! interpreter that is a script in the tree, named like a listed one, is never reused" {
  seed_ruff
  # A perl first on PATH, in the tree, that hands over to the real one.
  printf '#!/bin/sh\nexec /usr/bin/perl "$@"\n' > "$FAKE_BIN/perl"
  chmod +x "$FAKE_BIN/perl"
  perl -pi -e 's{^#!/usr/bin/perl$}{#!/usr/bin/env perl} if $. == 1' "$FAKE_BIN/ruff"
  run_stop claude
  run_stop claude
  [ "$status" -eq 0 ]
  [ "$(calls ruff)" -eq 2 ] || { echo "a script perl in the tree was reused"; false; }
}

@test "a pnpm shim whose \$basedir/node is a script is never reused" {
  seed_pnpm_tsc
  pnpm_shim 9 "$PROJECT_DIR/node_modules/.bin/tsc" ../.pnpm/typescript@5.0.0/node_modules/typescript/bin/tsc "$PNPM_NP"
  printf '#!/bin/sh\nexit 0\n' > "$PROJECT_DIR/node_modules/.bin/node"
  chmod +x "$PROJECT_DIR/node_modules/.bin/node"
  never_reused 'a script as $basedir/node'
}

@test "a symlink that leaves the worktree is never reused, untracked or tracked, nor one into left-out hook state" {
  local out="$BATS_TEST_TMPDIR/outside"
  seed_ruff
  mkdir -p "$out"
  printf 'x = 1\n' > "$out/target.py"
  ln -s "$out/target.py" "$PROJECT_DIR/linked.py"
  run_stop claude
  run_stop claude
  [ "$status" -eq 0 ]
  [ "$(calls ruff)" -eq 2 ] || { echo "an untracked link out of the worktree was reused"; false; }
  git -C "$PROJECT_DIR" add linked.py
  git -C "$PROJECT_DIR" commit -qm link
  run_stop claude
  run_stop claude
  [ "$(calls ruff)" -eq 4 ] || { echo "a tracked link out of the worktree was reused"; false; }
  git -C "$PROJECT_DIR" rm -q linked.py
  git -C "$PROJECT_DIR" commit -qm unlink
  mkdir -p "$PROJECT_DIR/.claude"
  # Hook state the hook itself leaves alone, so the link never dangles.
  printf '1\n' > "$PROJECT_DIR/.claude/spec-gate-audit.log"
  ln -s .claude/spec-gate-audit.log "$PROJECT_DIR/state-link"
  run_stop claude
  run_stop claude
  [ "$(calls ruff)" -eq 6 ] || { echo "a link into hook state the fingerprint leaves out was reused"; false; }
}

@test "a pm script program is judged by the binary it resolves to: a link named runner to perl, perl5.x, a link to npm" {
  local lib body
  setup_pm_scripts
  ln -s /usr/bin/perl "$PROJECT_DIR/node_modules/.bin/runner"
  ln -s /usr/bin/perl5.34 "$PROJECT_DIR/node_modules/.bin/perl5.34"
  mkdir -p "$PROJECT_DIR/node_modules/npm/bin"
  printf '#!/usr/bin/env node\n' > "$PROJECT_DIR/node_modules/npm/bin/npm-cli.js"
  chmod +x "$PROJECT_DIR/node_modules/npm/bin/npm-cli.js"
  ln -s ../npm/bin/npm-cli.js "$PROJECT_DIR/node_modules/.bin/tool"
  for body in 'runner -S ext_script' 'perl5.34 -S ext_script' 'tool run evil'; do
    jq -n --arg b "$body" '{scripts: {t: $b, evil: "true"}}' > "$PROJECT_DIR/package.json"
    for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
      run bash -c '. "$1"; shift; _se_pm_progs "$@"' _ "$lib" "$PROJECT_DIR" "$PROJECT_DIR" npm run t
      [ "$status" -eq 1 ] || { echo "${lib#"$BATS_TEST_DIRNAME"/}: admitted $body ($status)"; false; }
    done
  done
}

@test "pnpm run with a -- is refused: pnpm passes it on where npm consumes it" {
  local lib
  setup_pm_scripts
  make_fake_tool pnpm
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    jq -n '{scripts: {t: "vitest run"}}' > "$PROJECT_DIR/package.json"
    run bash -c '. "$1"; shift; _se_pm_progs "$@"' _ "$lib" "$PROJECT_DIR" "$PROJECT_DIR" pnpm run t -- --watch=false
    [ "$status" -eq 1 ] || { echo "${lib#"$BATS_TEST_DIRNAME"/}: pnpm run t -- admitted ($status)"; false; }
    run bash -c '. "$1"; shift; _se_pm_progs "$@"' _ "$lib" "$PROJECT_DIR" "$PROJECT_DIR" npm run t -- --watch=false
    [ "$status" -eq 0 ] || { echo "${lib#"$BATS_TEST_DIRNAME"/}: npm run t -- refused ($status)"; false; }
  done
}

@test "a program path outside the plain bytes, or an empty or relative PATH entry, is never reused" {
  local p
  seed_ruff
  mkdir -p "$FAKE_BIN/we\ird"
  mv "$FAKE_BIN/ruff" "$FAKE_BIN/we\ird/ruff"
  run_stop claude PATH="$FAKE_BIN/we\ird:$PATH"
  run_stop claude PATH="$FAKE_BIN/we\ird:$PATH"
  [ "$status" -eq 0 ]
  [ "$(calls ruff)" -eq 2 ] || { echo "a program path with a backslash was reused"; false; }
  mv "$FAKE_BIN/we\ird/ruff" "$FAKE_BIN/ruff"
  for p in ":$FAKE_BIN:$PATH" "$FAKE_BIN::$PATH" "$FAKE_BIN:$PATH:" "bin:$FAKE_BIN:$PATH" "$FAKE_BIN/./x:$FAKE_BIN:$PATH"; do
    : > "$FAKE_STATE/calls"
    run env ${HOOK_ENV_UNSET[@]+"${HOOK_ENV_UNSET[@]}"} PATH="$p" CLAUDE_PROJECT_DIR="$PROJECT_DIR" PROCESS_GATE_NO_RECEIPTS=1 FAKE_STATE="$FAKE_STATE" \
      /bin/bash "$HOOKS_DIR/stop-verify.sh" <<< '{}'
    run env ${HOOK_ENV_UNSET[@]+"${HOOK_ENV_UNSET[@]}"} PATH="$p" CLAUDE_PROJECT_DIR="$PROJECT_DIR" PROCESS_GATE_NO_RECEIPTS=1 FAKE_STATE="$FAKE_STATE" \
      /bin/bash "$HOOKS_DIR/stop-verify.sh" <<< '{}'
    [ "$status" -eq 0 ]
    [ "$(calls ruff)" -eq 2 ] || { echo "reused with PATH=$p"; false; }
  done
}

@test "relocating npm and pnpm settings refuse reuse: env outside a short safe list, workspace and dir keys, .corepack.env" {
  local lib e body
  seed_npm_test
  # The environment: anything but loglevel, color, fund, audit, progress,
  # yes and update-notifier.
  for e in "pnpm_config_dir=$BATS_TEST_TMPDIR" "npm_config_workspaces=true" "NPM_CONFIG_WORKSPACE=x" "npm_config_registry=x"; do
    : > "$FAKE_STATE/calls"
    run_stop claude "$e"
    run_stop claude "$e"
    [ "$(calls npm)" -eq 2 ] || { echo "reused with $e"; false; }
  done
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    for body in 'workspaces=true' 'dir=../x' 'include-workspace-root=true' 'recursive=true' 'virtual-store-dir=/x' 'node-gyp=/x'; do
      printf '%s\n' "$body" > "$PROJECT_DIR/.npmrc"
      run bash -c '. "$1"; _se_pm_config "$2"' _ "$lib" "$PROJECT_DIR"
      [ "$status" -ne 0 ] || { echo "${lib#"$BATS_TEST_DIRNAME"/}: admitted $body"; false; }
    done
    printf '' > "$PROJECT_DIR/.npmrc"
    printf 'COREPACK_HOME=/x\n' > "$PROJECT_DIR/.corepack.env"
    run bash -c '. "$1"; _se_pm_config "$2"' _ "$lib" "$PROJECT_DIR"
    [ "$status" -ne 0 ] || { echo "${lib#"$BATS_TEST_DIRNAME"/}: a .corepack.env was admitted"; false; }
    mv "$PROJECT_DIR/.corepack.env" "$BATS_TEST_TMPDIR/corepack.env.$RANDOM"
  done
}

@test "variables that relocate code or config refuse reuse, set even empty for the XDG homes; a short safe list keeps it" {
  local e n=0
  seed_ruff
  for e in XDG_CONFIG_HOME= XDG_CACHE_HOME=/x LOCALAPPDATA=/x COREPACK_HOME= COREPACK_ENV_FILE=/x \
           PYTHONPYCACHEPREFIX=/x PYTHONWARNINGS=ignore::x.W MYPY_CONFIG_FILE=/x MYPYPATH=/x PYTEST_ADDOPTS=-x \
           PYTEST_PLUGINS=x NODE_COMPILE_CACHE=/x NODE_EXTRA_CA_CERTS=/x ENV=/x ZDOTDIR=/x PERL_X=1 RUBYX=1 \
           TS_NODE_PROJECT=/x VIRTUAL_ENV=/x; do
    run_stop claude "$e"
    run_stop claude "$e"
    [ "$status" -eq 0 ]
    n=$((n + 2))
    [ "$(calls ruff)" -eq "$n" ] || { echo "reused with $e"; false; }
  done
  mkdir -p "$PROJECT_DIR/.venv"
  for e in NODE_ENV=test PYTHONUNBUFFERED=1 COREPACK_ENABLE_AUTO_PIN=0 "VIRTUAL_ENV=$PROJECT_DIR/.venv"; do
    run_stop claude "$e"
    run_stop claude "$e"
    n=$((n + 1))
    [ "$(calls ruff)" -eq "$n" ] || { echo "$e refused reuse"; false; }
  done
}

@test "an ignored path holding a tab or newline is never digested" {
  local lib
  printf 'build/\n' > "$PROJECT_DIR/.gitignore"
  mkdir -p "$PROJECT_DIR/build"
  printf 'x\n' > "$PROJECT_DIR/build/a"$'\t'"b"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    run bash -c '. "$1"; _se_ignored_digest "$2"' _ "$lib" "$PROJECT_DIR"
    [ "$status" -ne 0 ] || { echo "${lib#"$BATS_TEST_DIRNAME"/}: digested a path with a tab"; false; }
  done
}

@test "a perl setting refuses reuse before any perl runs, even one that makes the policing perl report clean" {
  local lib="$BATS_TEST_TMPDIR/perl-lib"
  seed_ruff
  mkdir -p "$lib"
  # Loaded into every perl: one with a single directory argument (the
  # environment check) exits 1, which reads as "nothing relocates".
  printf '%s\n' 'package Ex;' 'sub import { CORE::exit(1) if $0 eq "-e" && @ARGV == 1 && -d $ARGV[0] }' '1;' > "$lib/Ex.pm"
  run_stop claude PERL5OPT="-I$lib -MEx"
  run_stop claude PERL5OPT="-I$lib -MEx"
  [ "$status" -eq 0 ]
  [ "$(calls ruff)" -eq 2 ] || { echo "reused under a PERL5OPT that silences the check"; false; }
}

@test "a directory matched by a hook-state glob refuses reuse; a file it matches is left out" {
  seed_ruff
  mkdir -p "$PROJECT_DIR/.claude"
  printf 'x\n' > "$PROJECT_DIR/.claude/.review-done-abc"
  run_stop claude
  run_stop claude
  [ "$(calls ruff)" -eq 1 ] || { echo "a hook-state file refused reuse"; false; }
  mkdir -p "$PROJECT_DIR/.claude/.review-done-dir"
  printf 'x\n' > "$PROJECT_DIR/.claude/.review-done-dir/input"
  run_stop claude
  run_stop claude
  [ "$(calls ruff)" -eq 3 ] || { echo "a directory under a hook-state glob was reused"; false; }
}

@test "a tracked file replaced by a symlink and not staged refuses reuse" {
  local out="$BATS_TEST_TMPDIR/outside"
  seed_ruff
  mkdir -p "$out"
  printf 'y = 1\n' > "$out/mod.py"
  printf 'y = 1\n' > "$PROJECT_DIR/mod.py"
  git -C "$PROJECT_DIR" add mod.py
  git -C "$PROJECT_DIR" commit -qm mod
  mv "$PROJECT_DIR/mod.py" "$BATS_TEST_TMPDIR/mod.py.old"
  ln -s "$out/mod.py" "$PROJECT_DIR/mod.py"
  run_stop claude
  run_stop claude
  [ "$status" -eq 0 ]
  [ "$(calls ruff)" -eq 2 ] || { echo "an unstaged file-to-symlink change was reused"; false; }
}

@test "a symlink among hook state refuses reuse, under a glob entry or a literal one" {
  local out="$BATS_TEST_TMPDIR/outside"
  seed_ruff
  mkdir -p "$out/dir" "$PROJECT_DIR/.claude"
  printf 'x\n' > "$out/file"
  ln -s "$out/dir" "$PROJECT_DIR/.claude/.review-done-link"
  run_stop claude
  run_stop claude
  [ "$status" -eq 0 ]
  [ "$(calls ruff)" -eq 2 ] || { echo "a symlink under a hook-state glob was reused"; false; }
  mv "$PROJECT_DIR/.claude/.review-done-link" "$BATS_TEST_TMPDIR/review-done-link.moved"
  ln -s "$out/file" "$PROJECT_DIR/.claude/spec-gate-audit.log"
  run_stop claude
  run_stop claude
  [ "$(calls ruff)" -eq 4 ] || { echo "a symlink at a literal hook-state path was reused"; false; }
}

@test "a tree with a merge conflict refuses reuse" {
  seed_ruff
  printf 'a = 1\n' > "$PROJECT_DIR/c.py"
  git -C "$PROJECT_DIR" add c.py
  git -C "$PROJECT_DIR" commit -qm base
  git -C "$PROJECT_DIR" checkout -qb other
  printf 'a = 2\n' > "$PROJECT_DIR/c.py"
  git -C "$PROJECT_DIR" commit -qam other
  git -C "$PROJECT_DIR" checkout -q -
  printf 'a = 3\n' > "$PROJECT_DIR/c.py"
  git -C "$PROJECT_DIR" commit -qam main
  run git -C "$PROJECT_DIR" merge -q other
  [ "$status" -ne 0 ]
  git -C "$PROJECT_DIR" status --porcelain=v2 | grep -q '^u '
  run_stop claude
  run_stop claude
  [ "$(calls ruff)" -eq 2 ] || { echo "a conflicted tree was reused"; false; }
}
