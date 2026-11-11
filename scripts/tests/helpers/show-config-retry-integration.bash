#!/usr/bin/env bash
# Exercise the actual retry orchestration with real tokens, but small test-only
# body/audit stubs. Full real-payload coverage remains in show-config-batch.bats.
set -u
repo=$1
base=$(mktemp -d "$TMPDIR/t12-retry-integration.XXXXXX") || exit 1
program=$(python3 -I - "$repo/scripts/show-config.sh" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
print(source[source.index('_show_config_token_delta() {\n'):])
PY
) || exit 1
run_case() {
  local mode=$1 expected=$2 expected_attempts=$3 expected_text=$4 sandbox="$base/$1" rc=0 output
  local checkout=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  mkdir -p "$sandbox/home/state/attachments/$checkout" "$sandbox/scripts" || return 1
  chmod 700 "$sandbox/home" "$sandbox/home/state"
  printf '%s\n' '{"source_root":"/fixture","active_cli_release":"1.0.0","default_fleet":"personal","fleets":{"personal":{}}}' > "$sandbox/home/config.json"
  printf '{}\n' > "$sandbox/home/registry.json"
  printf '{"primary":true}\n' > "$sandbox/home/state/attachments/$checkout/primary.json"
  printf '{"secondary":true}\n' > "$sandbox/home/state/attachments/$checkout/secondary.json"
  printf '{}\n' > "$sandbox/trellis.config.json"
  chmod 600 "$sandbox/home/config.json" "$sandbox/home/registry.json" "$sandbox/home/state/attachments/$checkout/"*.json
  : > "$sandbox/attempts"
  output=$(env _SC_RETRY_SAFE=0 _SC_LEDGER_PATHS=/forged _SC_LEDGER_TOKENS=/forged \
    T12_TEST_MODE="$mode" T12_TEST_BASE="$sandbox" T12_TEST_REPO="$repo" T12_TEST_CHECKOUT="$checkout" \
    /bin/bash -c '
      set -u
      TRELLIS_EX_STATE=4 TRELLIS_EX_UNAVAILABLE=5 TRELLIS_EX_USAGE=2
      SELECTED_HOME="$T12_TEST_BASE/home" FLEET_OPT="" SCRIPT_DIR="$T12_TEST_BASE/scripts"
      . "$T12_TEST_REPO/scripts/lib/attachment.sh"
      eval "$(declare -f _local_registry_file_token | sed '"'"'1s/_local_registry_file_token/_test_real_file_token/'"'"')"
      _local_registry_file_token() {
        case "$T12_TEST_MODE:$2" in
          coarse-config*:*/config.json|coarse-secondary:*/secondary.json) return 1 ;;
        esac
        _test_real_file_token "$@"
      }
      eval "$(declare -f _attachment_hash | sed '"'"'1s/_attachment_hash/_test_real_hash/'"'"')"
      _attachment_hash() {
        [ "$T12_TEST_MODE" != coarse-config-hash-unavailable ] || return 1
        _test_real_hash "$@"
      }
      trellis_home_resolve() { printf "%s\n" "$1"; }
      hc_portable_machine_config() { printf "valid\n"; }
      show_config_tracked_policy_is_usable() { return 0; }
      trellis_home_require_fleet_name() { return 0; }
      trellis_home_require_source_root() { printf "%s\n" "$1"; }
      _release_stamp_matches() {
        case "$T12_TEST_MODE" in mixed-release|late-release) return 1 ;; esac
        return 0
      }
      _hc_portable_guarded_release_run() {
        local home="$1" callback="$3" rc=0 current count
        printf "attempt\n" >> "$T12_TEST_BASE/attempts"
        count=$(wc -l < "$T12_TEST_BASE/attempts" | tr -d " ")
        _HC_DIAG_AUDIT_ACTIVE=1 _HC_DIAG_EXTRA_ACTIVE=0 _HC_DIAG_EXTRA_INVALID=0
        [ "$T12_TEST_MODE" != late-no-proof ] || _HC_DIAG_AUDIT_ACTIVE=0
        _HC_DIAG_AUDIT_PATHS=(fixture) _HC_DIAG_AUDIT_KINDS=(fixture) _HC_DIAG_AUDIT_ROWS=(fixture)
        _HC_DIAG_EXTRA_PATHS=() _HC_DIAG_EXTRA_KINDS=() _HC_DIAG_EXTRA_ROWS=()
        _HC_DIAG_OWNER_HOME="$home" _HC_DIAG_OWNER_PATH="$home/state/attachments/$T12_TEST_CHECKOUT/primary.json"
        _HC_DIAG_OWNER_TOKEN=$(_local_registry_file_token "${_HC_DIAG_OWNER_PATH%/*}" "$_HC_DIAG_OWNER_PATH" "$home") || return 4
        _HC_DIAG_OWNER_ACTIVE=1
        show_config_render_body() {
          REGISTRY_GUARD_MODE=token
          REGISTRY_GUARD_TOKEN=$(_local_registry_diagnostic_token "$home") || return 4
          REGISTRY_GUARD_STATE="{}"
          _SC_REGISTRY_ACTIVE=1 _SC_REGISTRY_TOKEN="$REGISTRY_GUARD_TOKEN"
          OWNER="$_HC_DIAG_OWNER_PATH" ATTACHMENT_RELEASE=1.0.0
          if [ "$T12_TEST_MODE" != no-ledger ]; then
            _show_config_record_checkout_owners_for_retry "$home" "$T12_TEST_CHECKOUT" "$OWNER"
          fi
          case "$T12_TEST_MODE:$count" in
            once-state:1|continuous:*|mixed-config:*|mixed-release:*|coarse-config:*|coarse-secondary:*)
              printf x > "$home/state/lane-availability.next"
              mv -f "$home/state/lane-availability.next" "$home/state/lane-availability" ;;
            once-home:1)
              printf x > "$home/unrelated.next"
              mv -f "$home/unrelated.next" "$home/unrelated" ;;
            rename-state:1)
              mv "$home/state" "$home/state.saved"
              mkdir "$home/state"
              mv "$home/state" "$home/state.fake"
              mv "$home/state.saved" "$home/state" ;;
          esac
          case "$T12_TEST_MODE" in
            registry) chmod 644 "$home/registry.json"; chmod 600 "$home/registry.json" ;;
            owner) chmod 644 "$OWNER"; chmod 600 "$OWNER" ;;
            secondary) chmod 644 "$home/state/attachments/$T12_TEST_CHECKOUT/secondary.json"; chmod 600 "$home/state/attachments/$T12_TEST_CHECKOUT/secondary.json" ;;
            mixed-config|unavailable-config) chmod 644 "$home/config.json"; chmod 600 "$home/config.json" ;;
            coarse-config-change) printf " " >> "$home/config.json" ;;
          esac
          echo VALID-SENTINEL
          return 0
        }
        "$callback" > "$T12_TEST_BASE/callback-output" || rc=$?
        current=$(_local_registry_file_token "${_HC_DIAG_OWNER_PATH%/*}" "$_HC_DIAG_OWNER_PATH" "$home") || rc=4
        if [ "$current" != "$_HC_DIAG_OWNER_TOKEN" ]; then
          echo "show-config: release or owner changed during diagnostic" >&2
          rc=4
        else
          cat "$T12_TEST_BASE/callback-output"
        fi
        if { [ "$T12_TEST_MODE" = late-home ] || [ "$T12_TEST_MODE" = late-release ] ||
             [ "$T12_TEST_MODE" = late-no-proof ] || [ "$T12_TEST_MODE" = late-unavailable ]; } && [ "$count" -eq 1 ]; then
          printf x > "$home/late-unrelated.next"
          mv -f "$home/late-unrelated.next" "$home/late-unrelated"
        fi
        if [ "$T12_TEST_MODE" = unavailable-config ] || [ "$T12_TEST_MODE" = late-unavailable ]; then rc=5; fi
        return "$rc"
      }
      eval "$1"
    ' retry-integration "$program" 2>&1) || rc=$?
  printf '%s status=%s attempts=%s output=%s\n' "$mode" "$rc" \
    "$(wc -l < "$sandbox/attempts" | tr -d ' ')" "$output"
  [ "$rc" -eq "$expected" ] &&
    [ "$(wc -l < "$sandbox/attempts" | tr -d ' ')" -eq "$expected_attempts" ] &&
    [[ "$output" == *"$expected_text"* ]] || return 1
  case "$expected" in 0) ;; *) [[ "$output" != *VALID-SENTINEL* ]] || return 1 ;; esac
}
run_case clean 0 1 VALID-SENTINEL || exit 11
run_case no-ledger 0 1 VALID-SENTINEL || exit 11
run_case once-state 0 2 VALID-SENTINEL || exit 12
run_case once-home 0 2 VALID-SENTINEL || exit 13
run_case late-home 0 2 VALID-SENTINEL || exit 13
run_case late-release 4 1 'guarded input changed' || exit 13
run_case late-no-proof 4 1 'guarded input changed' || exit 13
run_case late-unavailable 5 1 'guarded input changed' || exit 13
run_case rename-state 0 2 VALID-SENTINEL || exit 14
run_case continuous 4 3 'state directory kept changing' || exit 15
run_case registry 4 1 'guarded input changed' || exit 16
run_case owner 4 1 'guarded input changed' || exit 17
run_case secondary 4 1 'guarded input changed' || exit 18
run_case mixed-config 4 1 'guarded input changed' || exit 19
run_case unavailable-config 5 1 'guarded input changed' || exit 19
run_case mixed-release 4 1 'release or owner changed' || exit 20
run_case coarse-config-clean 0 1 VALID-SENTINEL || exit 21
run_case coarse-config-hash-unavailable 5 0 'could not capture machine config' || exit 21
run_case coarse-config 4 1 'release or owner changed' || exit 21
run_case coarse-config-change 4 1 'guarded input changed' || exit 21
run_case coarse-secondary 4 1 'release or owner changed' || exit 22
