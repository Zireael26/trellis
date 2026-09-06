#!/usr/bin/env bats
# Tests for block-destructive.sh — Claude PreToolUse hook.
# Covers Phase 1 fixes:
#   P1.1 (rm-rf rule covers absolute paths outside cwd)
#   P1.2 (DELETE-without-WHERE handles terminated SQL)
#   P1.5 (jq-missing fails closed)

load helpers

HOOK="$HOOKS_DIR/block-destructive.sh"
CODEX_HOOK="$CODEX_HOOKS_DIR/block-destructive.sh"

# Helper: run with a Bash tool envelope carrying $1 as the command.
run_with_cmd() {
  local cmd="$1"
  local input
  input="$(jq -nc --arg c "$cmd" '{tool_input: {command: $c}}')"
  printf '%s' "$input" | bash "$HOOK"
}

run_codex_with_cmd() {
  local cmd="$1"
  local input
  input="$(jq -nc --arg c "$cmd" '{tool_input: {command: $c}}')"
  printf '%s' "$input" | bash "$CODEX_HOOK"
}

# --- P1.1 rm-rf rule (D3 semantics: any absolute path or .. outside cwd) ---

@test "P1.1: blocks rm -rf /" {
  out="$(run_with_cmd 'rm -rf /')"
  [[ "$out" == *deny* ]]
}

@test "P1.1: blocks rm -rf /Users/me/foo" {
  out="$(run_with_cmd 'rm -rf /Users/me/foo')"
  [[ "$out" == *deny* ]]
}

@test "P1.1: blocks rm -rf ~/work" {
  out="$(run_with_cmd 'rm -rf ~/work')"
  [[ "$out" == *deny* ]]
}

@test "P1.1: blocks rm -rf \$HOME/cache" {
  out="$(run_with_cmd 'rm -rf $HOME/cache')"
  [[ "$out" == *deny* ]]
}

@test "P1.1: blocks rm -rf .." {
  out="$(run_with_cmd 'rm -rf ..')"
  [[ "$out" == *deny* ]]
}

@test "P1.1: blocks rm -rf ../foo/bar" {
  out="$(run_with_cmd 'rm -rf ../foo/bar')"
  [[ "$out" == *deny* ]]
}

@test "P1.1: allows rm -rf . (relative cwd)" {
  out="$(run_with_cmd 'rm -rf .')"
  [[ "$out" != *deny* ]]
}

@test "P1.1: allows rm -rf ./build" {
  out="$(run_with_cmd 'rm -rf ./build')"
  [[ "$out" != *deny* ]]
}

@test "P1.1: allows rm -rf node_modules" {
  out="$(run_with_cmd 'rm -rf node_modules')"
  [[ "$out" != *deny* ]]
}

@test "P1.1: allows rm -rf dist" {
  out="$(run_with_cmd 'rm -rf dist')"
  [[ "$out" != *deny* ]]
}

# --- P1.2 DELETE-without-WHERE (covers terminated SQL) ---

@test "P1.2: blocks DELETE FROM users (no WHERE, no semicolon)" {
  out="$(run_with_cmd 'DELETE FROM users')"
  [[ "$out" == *deny* ]]
}

@test "P1.2: blocks DELETE FROM users; (terminated, no WHERE)" {
  out="$(run_with_cmd 'DELETE FROM users;')"
  [[ "$out" == *deny* ]]
}

@test "P1.2: blocks delete from users (lowercase)" {
  out="$(run_with_cmd 'delete from users')"
  [[ "$out" == *deny* ]]
}

@test "P1.2: blocks DELETE FROM with backtick-quoted table" {
  out="$(run_with_cmd 'DELETE FROM `users`')"
  [[ "$out" == *deny* ]]
}

@test "P1.2: blocks DELETE FROM with double-quote-quoted table" {
  out="$(run_with_cmd 'DELETE FROM "users"')"
  [[ "$out" == *deny* ]]
}

@test "P1.2: blocks DELETE FROM schema.users" {
  out="$(run_with_cmd 'DELETE FROM schema.users')"
  [[ "$out" == *deny* ]]
}

@test "P1.1: blocks rm -rf with quoted absolute path (audit M6a)" {
  out="$(run_with_cmd 'rm -rf "/tmp/a b"')"
  [[ "$out" == *deny* ]]
}

@test "force-push: blocks --force-with-lease=<value> (audit M6b)" {
  out="$(run_with_cmd 'git push --force-with-lease=main origin main')"
  [[ "$out" == *deny* ]]
}

@test "git-reset: bare --hard is denied by both Claude and Codex hooks" {
  out="$(run_with_cmd 'git reset --hard')"
  [[ "$out" == *deny* ]]

  set +e
  out="$(run_codex_with_cmd 'git reset --hard')"
  rc=$?
  set -e
  [ "$rc" -eq 2 ]
  [[ "$out" == *'"decision":"block"'* ]]
}

@test "git-reset: Claude denies HEAD with suffix options" {
  for suffix in '--quiet' '--'; do
    run run_with_cmd "git reset --hard HEAD $suffix"
    [ "$status" -eq 0 ]
    [[ "$output" == *deny* ]]
  done
}

@test "git-reset: Codex denies HEAD with suffix options" {
  for suffix in '--quiet' '--'; do
    run run_codex_with_cmd "git reset --hard HEAD $suffix"
    [ "$status" -eq 2 ]
    [[ "$output" == *'"decision":"block"'* ]]
  done
}

@test "git-reset: both hooks retain target and command boundaries" {
  for cmd in 'git reset --hard HEAD' 'git reset --hard HEAD~2 --quiet' 'git reset --hard origin/main --' 'git reset --hard; git status'; do
    run run_with_cmd "$cmd"
    [ "$status" -eq 0 ]
    [[ "$output" == *deny* ]]
    run run_codex_with_cmd "$cmd"
    [ "$status" -eq 2 ]
    [[ "$output" == *'"decision":"block"'* ]]
  done
  for cmd in 'git reset --soft HEAD' 'git reset --harder HEAD' 'git reset --hard HEADnotes --quiet' 'git reset --hard feature/topic'; do
    run run_with_cmd "$cmd"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run run_codex_with_cmd "$cmd"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

@test "git-reset: similarly prefixed option remains outside the --hard rule" {
  out="$(run_with_cmd 'git reset --harder')"
  [[ "$out" != *deny* ]]

  set +e
  out="$(run_codex_with_cmd 'git reset --harder')"
  rc=$?
  set -e
  [ "$rc" -eq 0 ]
  [ -z "$out" ]
}

@test "P1.2: blocks unbounded DELETE shielded by an unrelated WHERE (audit M7)" {
  out="$(run_with_cmd 'SELECT * FROM audit WHERE id=1; DELETE FROM users;')"
  [[ "$out" == *deny* ]]
}

@test "P1.2: allows DELETE FROM users WHERE id=1;" {
  out="$(run_with_cmd 'DELETE FROM users WHERE id=1;')"
  [[ "$out" != *deny* ]]
}

@test "P1.2: allows SELECT * FROM users" {
  out="$(run_with_cmd 'SELECT * FROM users')"
  [[ "$out" != *deny* ]]
}

@test "P1.2: blocks psql -c \"DELETE FROM users;\"" {
  out="$(run_with_cmd 'psql -c "DELETE FROM users;"')"
  [[ "$out" == *deny* ]]
}

# --- codex hatch + max/ultra compound ---

@test "hatch: blocks codex bypass-sandbox + ultra" {
  out="$(run_with_cmd 'codex exec --dangerously-bypass-approvals-and-sandbox -c model_reasoning_effort="ultra" "task"')"
  [[ "$out" == *deny* ]]
}

@test "hatch: blocks codex -s danger-full-access + max" {
  out="$(run_with_cmd 'codex exec -s danger-full-access -c model_reasoning_effort=max "task"')"
  [[ "$out" == *deny* ]]
}

@test "hatch: allows sandboxed ultra (workspace-write)" {
  out="$(run_with_cmd 'codex exec --json -s workspace-write -c model_reasoning_effort="ultra" "task" </dev/null')"
  [[ "$out" != *deny* ]]
}

@test "hatch: allows bypass-sandbox at xhigh" {
  out="$(run_with_cmd 'codex exec --dangerously-bypass-approvals-and-sandbox -c model_reasoning_effort="xhigh" "task"')"
  [[ "$out" != *deny* ]]
}

# --- P1.5 jq-missing fails closed ---

@test "P1.5: jq missing without env → exit 1 + install help on stderr" {
  jq_free_path="$(make_jq_free_path)"
  run_with_stderr "$HOOK" '{}'
  rc_normal=$status
  PATH_BACKUP="$PATH"; export PATH="$jq_free_path"
  run_with_stderr "$HOOK" '{}'
  PATH="$PATH_BACKUP"
  rm -rf "$jq_free_path"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"install jq"* ]]
}

@test "P1.5: jq missing + TRELLIS_NO_JQ_DEGRADE=1 → exit 0 + breadcrumb" {
  jq_free_path="$(make_jq_free_path)"
  PATH_BACKUP="$PATH"; export PATH="$jq_free_path"
  export TRELLIS_NO_JQ_DEGRADE=1
  run_with_stderr "$HOOK" '{}'
  unset TRELLIS_NO_JQ_DEGRADE
  PATH="$PATH_BACKUP"
  rm -rf "$jq_free_path"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"TRELLIS_NO_JQ_DEGRADE=1"* ]]
}

# --- **/secrets/** reads: GCP/k8s resource identifiers are not file reads -----
# Upstreamed from the affected consumer 2026-09-04. GCP and Kubernetes resource names carry
# a literal "secrets/" segment, so the unnarrowed rule denied every pipeline that
# merely POST-PROCESSED gcloud/kubectl output. Nothing is read from disk there.

@test "secrets-path: allows grep over a gcloud resource identifier in output" {
  out="$(run_with_cmd 'gcloud secrets versions access latest --secret=x | grep projects/12345/secrets/db-password')"
  [[ "$out" != *deny* ]] || { echo "$out"; false; }
}

@test "secrets-path: allows sed over a kubernetes resource identifier in output" {
  out="$(run_with_cmd 'kubectl get secret -o name | sed -n "s#namespaces/prod/secrets/api-key##p"')"
  [[ "$out" != *deny* ]] || { echo "$out"; false; }
}

@test "secrets-path: allows awk over a gcloud resource identifier in output" {
  out="$(run_with_cmd 'gcloud secrets list --format=json | awk "/projects\/998877\/secrets\/token/ {print}"')"
  [[ "$out" != *deny* ]] || { echo "$out"; false; }
}

# The narrowing must not hollow out the rule: a real read of a file under a
# secrets/ directory is still a hard deny, including one whose path happens to
# contain a projects/ or namespaces/ segment elsewhere.

@test "secrets-path: still denies a real cat of a file under a secrets dir" {
  out="$(run_with_cmd 'cat config/secrets/production.yml')"
  [[ "$out" == *deny* ]] || { echo "$out"; false; }
}

@test "secrets-path: still denies a real grep of a file under a secrets dir" {
  out="$(run_with_cmd 'grep -r api_key ./secrets/')"
  [[ "$out" == *deny* ]] || { echo "$out"; false; }
}

@test "secrets-path: still denies a read under a secrets dir nested in a projects path" {
  out="$(run_with_cmd 'cat /Users/me/projects/app/secrets/creds.json')"
  [[ "$out" == *deny* ]] || { echo "$out"; false; }
}
