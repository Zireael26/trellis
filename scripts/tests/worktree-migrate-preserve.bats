#!/usr/bin/env bats
# Spec 069 owner directive 2026-10-09: migrate --apply preserves uncommitted work.
#
# Hermetic: HOME, TRELLIS_HOME, the worktree root, the policy file, `gh`,
# `lsof` and the origin remotes are sandboxed under BATS_TEST_TMPDIR; the
# operator's registry, worktrees and GitHub account are never read.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/worktree.sh"
load helpers/worktree-migrate

setup() {
  wm_fixture_setup
}

teardown() {
  wm_fixture_teardown
}

# ---------------------------------------------------------------------------
# preserve (owner directive 2026-10-09: no work is lost)
# ---------------------------------------------------------------------------

# wip_wt NAME — a worktree with a modified file, an untracked file and an
# ignored .env.local.
wip_wt() {
  local wt="$HOME/projects/alpha-wt/$1"
  wm_wt "$HOME/projects/alpha" "feat/$1" "$wt"
  printf 'changed\n' >> "$wt/seed.txt"
  printf 'new\n' > "$wt/new.py"
  printf 'TOKEN=1\n' > "$wt/.env.local"
}

@test "preserve: commits on the branch, pushes to an allowed origin, archives ignored files, then moves" {
  alpha
  wip_wt wip
  wt="$HOME/projects/alpha-wt/wip"
  wm_policy '{"worktrees":{"push_owners":["Zireael26"]}}'
  migrate --apply --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  target="$WT_ROOT/alpha/feat-wip"
  [ ! -e "$wt" ]
  [ -z "$(git -C "$target" status --porcelain)" ]
  [ "$(git -C "$target" symbolic-ref --short HEAD)" = feat/wip ]
  [ "$(git -C "$target" log -1 --format=%s)" = "chore: wip: preserve $wt before worktree migration" ]
  [ "$(cat "$target/new.py")" = new ] && [ "$(cat "$target/.env.local")" = "TOKEN=1" ]
  sha="$(git -C "$target" rev-parse HEAD)"
  # Pushed to a preserve/ ref only, never over the feature branch itself.
  [ "$(git --git-dir="$SANDBOX/remotes/Zireael26/alpha.git" rev-parse refs/heads/preserve/feat-wip)" = "$sha" ]
  ! git --git-dir="$SANDBOX/remotes/Zireael26/alpha.git" show-ref --verify --quiet refs/heads/feat/wip
  j="$(journal)"
  jq -se --arg p "$wt" '[.[] | select(.old == $p) | .step]
    == ["archived", "committed", "pushed", "moved", "repaired", "done"]' "$j"
  jq -se --arg p "$wt" --arg s "$sha" 'map(select(.old == $p and .step == "pushed")) | .[0]
    | .pushed_ref == "origin/preserve/feat-wip" and .sha == $s' "$j"
  archive="$(jq -sr --arg p "$wt" 'map(select(.old == $p and .step == "archived")) | .[0].archive' "$j")"
  cmp "$archive/.env.local" "$target/.env.local"
  local mode
  mode="$(stat -f %Lp "${j%.jsonl}.archive" 2>/dev/null)" || mode="$(stat -c %a "${j%.jsonl}.archive")"
  [ "$mode" = 700 ]
  ! git -C "$target" show HEAD --name-only | grep -q '.env.local'
}

@test "preserve: a detached head gets preserve/<dir>, never a commit on main" {
  alpha
  main_sha="$(git -C "$HOME/projects/alpha" rev-parse main)"
  git -C "$HOME/projects/alpha" worktree add -q --detach "$HOME/projects/alpha-wt/det" main
  printf 'x\n' > "$HOME/projects/alpha-wt/det/untracked.txt"
  migrate --apply --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git -C "$HOME/projects/alpha" rev-parse main)" = "$main_sha" ]
  target="$WT_ROOT/alpha/preserve-det"
  [ "$(git -C "$target" symbolic-ref --short HEAD)" = preserve/det ]
  [ "$(git -C "$target" rev-parse HEAD~1)" = "$main_sha" ]
  jq -se 'map(select(.step == "local-only")) | length == 1' "$(journal)"
}

@test "preserve: a partner origin is committed locally and never pushed" {
  alpha
  wm_repo "$HOME/projects/partner-console" "$SANDBOX/remotes/PartnerOrg/partner-console.git"
  wm_wt "$HOME/projects/partner-console" partner "$HOME/projects/cb-wt/partner"
  printf 'x\n' > "$HOME/projects/cb-wt/partner/u.txt"
  wm_policy '{"worktrees":{"known_parents":["~/projects/cb-wt"],"push_owners":["Zireael26"]}}'
  migrate --apply --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  target="$WT_ROOT/_unregistered/partner-console/partner"
  [ "$(git -C "$target" log -1 --format=%s)" = "chore: wip: preserve $HOME/projects/cb-wt/partner before worktree migration" ]
  ! git --git-dir="$SANDBOX/remotes/PartnerOrg/partner-console.git" show-ref --verify --quiet refs/heads/partner
  jq -se 'map(select(.step == "pushed")) | length == 0' "$(journal)"
}

@test "preserve: a commit refused by a hook leaves index, HEAD and files as they were" {
  alpha
  git -C "$HOME/projects/alpha" worktree add -q --detach "$HOME/projects/alpha-wt/det" main
  wt="$HOME/projects/alpha-wt/det"
  printf 'staged\n' > "$wt/staged.txt"
  git -C "$wt" add staged.txt
  printf 'changed\n' >> "$wt/seed.txt"
  printf 'u\n' > "$wt/untracked.txt"
  mkdir -p "$SANDBOX/hooks"
  printf '#!/bin/sh\necho "pre-commit says no" >&2\nexit 1\n' > "$SANDBOX/hooks/pre-commit"
  chmod 755 "$SANDBOX/hooks/pre-commit"
  git -C "$HOME/projects/alpha" config core.hooksPath "$SANDBOX/hooks"
  status_before="$(git -C "$wt" status --porcelain)"
  head_before="$(git -C "$wt" rev-parse HEAD)"
  migrate --apply --yes
  [ "$status" -eq 4 ] || { echo "$output"; return 1; }
  [ "$(git -C "$wt" status --porcelain)" = "$status_before" ]
  [ "$(git -C "$wt" rev-parse HEAD)" = "$head_before" ]
  ! git -C "$wt" symbolic-ref -q HEAD
  ! git -C "$HOME/projects/alpha" show-ref --verify --quiet refs/heads/preserve/det
  jq -se 'last | .step == "failed" and (.error | test("pre-commit says no"))' "$(journal)"
}

@test "preserve: a refused push is journaled and the worktree still moves with its commit" {
  alpha
  wip_wt wip
  wm_policy '{"worktrees":{"push_owners":["Zireael26"]}}'
  printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/remotes/Zireael26/alpha.git/hooks/pre-receive"
  chmod 755 "$SANDBOX/remotes/Zireael26/alpha.git/hooks/pre-receive"
  migrate --apply --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  target="$WT_ROOT/alpha/feat-wip"
  [ "$(git -C "$target" log -1 --format=%s)" = "chore: wip: preserve $HOME/projects/alpha-wt/wip before worktree migration" ]
  jq -se 'map(.step) | index("push-failed") and index("done") and (index("pushed") | not)' "$(journal)"
}

@test "P1-b: preserve never commits or pushes an embedded repository; the worktree holds" {
  alpha
  wip_wt emb
  wt="$HOME/projects/alpha-wt/emb"
  git init -q "$wt/vendor/lib"
  printf 'x\n' > "$wt/vendor/lib/file"
  head_before="$(git -C "$wt" rev-parse HEAD)"
  wm_policy '{"worktrees":{"push_owners":["Zireael26"]}}'
  migrate --apply --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git -C "$wt" rev-parse HEAD)" = "$head_before" ]
  ! git --git-dir="$SANDBOX/remotes/Zireael26/alpha.git" show-ref --verify --quiet refs/heads/feat/emb
  ! git --git-dir="$SANDBOX/remotes/Zireael26/alpha.git" for-each-ref --format='%(refname)' | grep -q preserve
  [ -f "$wt/vendor/lib/file" ] && [ -f "$wt/new.py" ]
}

@test "P2: a staged secret is archived, never committed or pushed, and the plan warns" {
  alpha
  wip_wt sec
  wt="$HOME/projects/alpha-wt/sec"
  printf 'aws = "%s%s"\n' 'AKIA' 'ABCDEFGHIJKLMNOP' > "$wt/creds.py"
  wm_policy '{"worktrees":{"push_owners":["Zireael26"]}}'
  migrate --json
  row "$wt" | jq -e '.push_ref == "preserve/feat-sec"
    and (.reasons | index("the preserve commit is secret-scanned; flagged files are archived, not committed"))'
  migrate --apply --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  target="$WT_ROOT/alpha/feat-sec"
  ! git -C "$target" show --name-only --format= HEAD | grep -qx creds.py
  git -C "$target" show --name-only --format= HEAD | grep -qx new.py
  [ -f "$target/creds.py" ]
  ! git --git-dir="$SANDBOX/remotes/Zireael26/alpha.git" log --all --format=%H -- creds.py | grep -q .
  j="$(journal)"
  archive="$(jq -sr 'map(select(.step == "secrets-withheld")) | .[0].archive' "$j")"
  cmp "$archive/creds.py" "$target/creds.py"
  jq -se 'map(select(.step == "secrets-withheld")) | .[0].files == ["creds.py"]' "$j"
}

@test "P2: process-gate secret paths are archived even without a matching secret line" {
  alpha
  printf 'safe placeholder\n' > "$HOME/projects/alpha/.env.local"
  git -C "$HOME/projects/alpha" add -f .env.local
  git -C "$HOME/projects/alpha" commit -q -m 'chore: seed sensitive-path fixture'
  wt="$HOME/projects/alpha-wt/env"
  wm_wt "$HOME/projects/alpha" feat/env "$wt"
  printf 'TOKEN=fixture-only\n' > "$wt/.env.local"
  printf 'new\n' > "$wt/new.py"
  wm_policy '{"worktrees":{"push_owners":["Zireael26"]}}'
  migrate --json
  row "$wt" | jq -e '.push_ref == "preserve/feat-env"
    and (.reasons | index("the preserve commit is secret-scanned; flagged files are archived, not committed"))'
  migrate --apply --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  target="$WT_ROOT/alpha/feat-env"
  [ "$(git -C "$target" show HEAD:.env.local)" = 'safe placeholder' ]
  [ "$(cat "$target/.env.local")" = 'TOKEN=fixture-only' ]
  [ "$(git --git-dir="$SANDBOX/remotes/Zireael26/alpha.git" show refs/heads/preserve/feat-env:.env.local)" = 'safe placeholder' ]
  j="$(journal)"
  archive="$(jq -sr 'map(select(.step == "secrets-withheld")) | .[0].archive' "$j")"
  cmp "$archive/.env.local" "$target/.env.local"
  jq -se 'map(select(.step == "secrets-withheld")) | .[0].files == [".env.local"]' "$j"
  local mode
  mode="$(stat -f %Lp "$archive" 2>/dev/null)" || mode="$(stat -c %a "$archive")"
  [ "$mode" = 700 ]
}

@test "P2: subdir env, credential JSON, SSH keys and JSON secret fields are withheld" {
  alpha
  # Subdir .env files are untracked here so the preserve commit stages them.
  printf 'node_modules/\n.venv/\n*.db\n*.sqlite\ndist/\n' > "$HOME/projects/alpha/.gitignore"
  git -C "$HOME/projects/alpha" commit -q -am 'chore: test fixture without env ignore'
  wt="$HOME/projects/alpha-wt/sec2"
  wm_wt "$HOME/projects/alpha" feat/sec2 "$wt"
  mkdir -p "$wt/config" "$wt/app"
  printf 'TOKEN=fixture-only\n' > "$wt/config/.env"
  printf 'TOKEN=fixture-only\n' > "$wt/app/.env.local"
  printf '{"note":"fixture-only"}\n' > "$wt/config/credentials.json"
  printf '{"note":"fixture-only"}\n' > "$wt/config/service-account.json"
  printf '{"note":"fixture-only"}\n' > "$wt/config/service_account.json"
  printf 'fixture-only-ssh-key\n' > "$wt/config/id_rsa"
  printf 'fixture-only-ssh-key\n' > "$wt/config/id_ed25519"
  printf 'fixture-only-ssh-key\n' > "$wt/config/id_ecdsa"
  printf 'fixture-only-ssh-key\n' > "$wt/config/id_dsa"
  printf 'fixture-only-putty-key\n' > "$wt/config/key.ppk"
  printf '{"client_secret":"GOCSPX-fixture"}\n' > "$wt/config/client.json"
  printf '{"private_key":"fixture-only-material"}\n' > "$wt/config/pk.json"
  printf '{"type":"service_account","project_id":"fixture-only"}\n' > "$wt/config/acct.json"
  printf 'new\n' > "$wt/new.py"
  wm_policy '{"worktrees":{"push_owners":["Zireael26"]}}'
  migrate --apply --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  target="$WT_ROOT/alpha/feat-sec2"
  git -C "$target" show --name-only --format= HEAD | grep -qx new.py
  for f in config/.env app/.env.local config/credentials.json config/service-account.json config/service_account.json config/id_rsa config/id_ed25519 config/id_ecdsa config/id_dsa config/key.ppk config/client.json config/pk.json config/acct.json; do
    ! git -C "$target" show --name-only --format= HEAD | grep -qx "$f" || { echo "committed $f"; return 1; }
    [ -f "$target/$f" ] || { echo "missing $f"; return 1; }
    ! git --git-dir="$SANDBOX/remotes/Zireael26/alpha.git" log --all --format=%H -- "$f" | grep -q . || { echo "pushed $f"; return 1; }
  done
  j="$(journal)"
  archive="$(jq -sr 'map(select(.step == "secrets-withheld")) | .[0].archive' "$j")"
  for f in config/.env app/.env.local config/credentials.json config/service-account.json config/service_account.json config/id_rsa config/id_ed25519 config/id_ecdsa config/id_dsa config/key.ppk config/client.json config/pk.json config/acct.json; do
    cmp "$archive/$f" "$target/$f" || { echo "archive mismatch $f"; return 1; }
  done
  local mode
  mode="$(stat -f %Lp "$archive" 2>/dev/null)" || mode="$(stat -c %a "$archive")"
  [ "$mode" = 700 ]
}
