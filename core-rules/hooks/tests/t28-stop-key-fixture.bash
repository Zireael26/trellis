#!/usr/bin/env bash
# Drive the real extracted _se_stop_key with isolated, independently variable
# helper outputs. Shell locals are deliberately not exported: changing a key
# input cannot be accidentally detected by the full-environment digest instead.
# The test supplies the canonical deps path and extracted key-function path;
# that dynamically sourced function reads the globals assigned below.
# shellcheck disable=SC1090,SC2034
set -o pipefail
source "$1"
# Load deps-heavy.sh now: its first-call stubs would source it again and
# replace the helper seams below with the real definitions.
_se_load_heavy || exit 1
source "$2"
PROJECT_DIR="$3" FIXTURE="$4" FIELD="$5" KEY_SOURCE="$2"
export HOME="$FIXTURE/home" RUSTUP_HOME="$FIXTURE/rustup"
mkdir -p "$HOME/.pyenv" "$RUSTUP_HOME" "$FIXTURE/files" "$PROJECT_DIR/child"
ln -s "$PROJECT_DIR/child" "$FIXTURE/child-link"
__se_lib="$FIXTURE/files/deps.sh"
__se_vr_lib="$FIXTURE/files/verification-receipt.sh"
__se_pm_lib="$FIXTURE/files/pm.sh"
for file in "$__se_lib" "$__se_vr_lib" "$__se_pm_lib" "$PROJECT_DIR/.trellis.json" \
  "$HOME/.pyenv/version" "$RUSTUP_HOME/settings.toml"; do
  printf 'original\n' > "$file"
done
ESLINT_PROBE_NOTE='' ESLINT_VERSION='eslint-one' CHECKS_RUN=2
__se_ck_id=('id-one' 'id-later') __se_ck_form=('argv' 'argv') __se_ck_dir=("$PROJECT_DIR" "$PROJECT_DIR")
__se_ck_cmd=('/usr/bin/npm run test' '/usr/bin/npm run later')
T28_CLOSURE='tool-one' T28_SHELL='shell-one' T28_PKG='package-one'
T28_PMARG='argument-one' T28_PMCFG='config-one' T28_IGNORED='ignored-one'
T28_PKGROOT='package-root'
export -n T28_CLOSURE T28_SHELL T28_PKG T28_PMARG T28_PMCFG T28_IGNORED T28_PKGROOT
_se_pm_progs() { printf 'arg\t%s\n' "$T28_PMARG"; }
_se_pm_config() { printf '%s\n' "$T28_PMCFG"; }
_se_tool_closure() {
  if [ "$2" = '--shell' ]; then
    printf 'native\t%s\t1\t1\t1\n' "$T28_SHELL"
  else
    printf 'pm\t%s\t1\t1\t1\t%s\n' "$T28_CLOSURE" "$T28_PKGROOT"
  fi
}
_se_pkg_digest() { printf '%s\n' "$T28_PKG"; }
_se_env_moves_code() { return 1; }
_se_ignored_digest() { printf '%s\n' "$T28_IGNORED"; }
cd "$PROJECT_DIR" || exit 1
if [ "$FIELD" = cwd-logical ]; then cd "$PROJECT_DIR/child" || exit 1; fi
if [ "$FIELD" = env ]; then export T28_KEY_FIXTURE_ENV=before; fi
fingerprint='fingerprint-one'
before=$(_se_stop_key "$fingerprint") || { echo "$FIELD: first key failed"; exit 1; }
case "$FIELD" in
  fingerprint) fingerprint='fingerprint-two' ;;
  cwd-physical) cd "$PROJECT_DIR/child" || exit 1; PWD="$PROJECT_DIR" ;;
  cwd-logical) cd "$FIXTURE/child-link" || exit 1 ;;
  check-id) __se_ck_id[0]='id-two' ;;
  check-form) __se_ck_form[0]='shell' ;;
  check-dir) __se_ck_dir[0]="$PROJECT_DIR/child" ;;
  check-command) __se_ck_cmd[0]='/usr/bin/npm run other' ;;
  check2-id) __se_ck_id[1]='id-changed' ;;
  check2-form) __se_ck_form[1]='shell' ;;
  check2-dir) __se_ck_dir[1]="$PROJECT_DIR/child" ;;
  check2-command) __se_ck_cmd[1]='/usr/bin/npm run other' ;;
  tool-closure) T28_CLOSURE='tool-two' ;;
  shell-closure) T28_SHELL='shell-two' ;;
  package-digest) T28_PKG='package-two' ;;
  package-argument) T28_PMARG='argument-two' ;;
  package-config) T28_PMCFG='config-two' ;;
  eslint-version) ESLINT_VERSION='eslint-two' ;;
  env) export T28_KEY_FIXTURE_ENV=after ;;
  ignored) T28_IGNORED='ignored-two' ;;
  stat-wrapper) printf '# changed\n' >> "$KEY_SOURCE" ;;
  stat-deps) printf 'changed\n' >> "$__se_lib" ;;
  stat-receipt) printf 'changed\n' >> "$__se_vr_lib" ;;
  stat-pm) printf 'changed\n' >> "$__se_pm_lib" ;;
  stat-policy) printf 'changed\n' >> "$PROJECT_DIR/.trellis.json" ;;
  stat-pyenv) printf 'changed\n' >> "$HOME/.pyenv/version" ;;
  stat-rustup) printf 'changed\n' >> "$RUSTUP_HOME/settings.toml" ;;
  *) echo "unknown key field: $FIELD"; exit 2 ;;
esac
after=$(_se_stop_key "$fingerprint") || { echo "$FIELD: second key failed"; exit 1; }
[ "$before" != "$after" ] || { echo "$FIELD: changed input did not change the reuse key"; exit 1; }
