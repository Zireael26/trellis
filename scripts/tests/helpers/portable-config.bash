#!/usr/bin/env bash
# The sanctioned Spec 036 portable-configuration fixture, in ONE place.
#
# Spec 036 split configuration in two: tracked policy (trellis.config.json)
# carries no machine paths, and every machine path — discovery roots and the
# optional per-fleet shared_infra_root — lives in $TRELLIS_HOME/config.json.
# onboard-project.bats and shared-infra.bats both need that pair, and a second
# hand-written copy of it drifts silently: a suite whose fixture no longer
# matches the schema stops testing the loader and starts testing its own typo.
#
# Usage (bats):
#   load helpers/portable-config
#   portable_config_write "$CFG" "$POLICY_SOURCE" "$LOCAL_HOME/config.json" \
#     "$PROJECTS" "$SHARED"
#
# SHARED_ROOT of `__ABSENT__` omits the optional key entirely — that is the
# "shared infrastructure is not configured" case, which is NOT the same as an
# empty string (the machine schema rejects an empty path).

portable_config_write() {
  local policy="$1" policy_source="$2" machine="$3" discovery="$4" shared="$5"
  local harnesses="${6:-\"claude\"}"

  cat > "$policy" <<EOF
{
  "schema_version": 2,
  "maintainer_name": "Test Maintainer",
  "github_user": "tester",
  "harnesses": [$harnesses]
}
EOF
  cp "$policy" "$policy_source/trellis.config.json"

  if [ "$shared" = "__ABSENT__" ]; then
    jq -n --arg source "$policy_source" --arg projects "$discovery" '{
      schema_version: 1,
      source_root: $source,
      release_remote: "https://example.invalid/trellis.git",
      active_cli_release: "1.2.3",
      default_fleet: "personal",
      fleets: {personal: {discovery_roots: [$projects]}}
    }' > "$machine"
  else
    jq -n --arg source "$policy_source" --arg projects "$discovery" --arg shared "$shared" '{
      schema_version: 1,
      source_root: $source,
      release_remote: "https://example.invalid/trellis.git",
      active_cli_release: "1.2.3",
      default_fleet: "personal",
      fleets: {personal: {discovery_roots: [$projects], shared_infra_root: $shared}}
    }' > "$machine"
  fi
  chmod 600 "$machine"
}
