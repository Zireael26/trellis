#!/bin/sh
# Seeded into a project by scripts/onboard-project.sh. The project name marker
# is replaced during seeding so the shared registry key is never guessed later.
set -eu

CONFIGURED_SHARED_INFRA_ROOT="__TRELLIS_SHARED_INFRA_ROOT__"
SHARED_INFRA_ROOT="${SHARED_INFRA_ROOT:-$CONFIGURED_SHARED_INFRA_ROOT}"
PROJECT_NAME="__TRELLIS_PROJECT_NAME__"

if [ "$CONFIGURED_SHARED_INFRA_ROOT" = "__TRELLIS_SHARED_INFRA_ROOT__" ]; then
  echo "local-infra-preflight: configured shared infrastructure path was not rendered" >&2
  exit 2
fi
if [ "$PROJECT_NAME" = "__TRELLIS_PROJECT_NAME__" ]; then
  echo "local-infra-preflight: project registry name was not rendered" >&2
  exit 2
fi
if [ ! -d "$SHARED_INFRA_ROOT" ]; then
  echo "local-infra-preflight: shared infrastructure directory not found: $SHARED_INFRA_ROOT" >&2
  exit 1
fi
if [ ! -f "$SHARED_INFRA_ROOT/Makefile" ]; then
  echo "local-infra-preflight: shared infrastructure Makefile not found: $SHARED_INFRA_ROOT/Makefile" >&2
  exit 1
fi

exec make --no-print-directory -C "$SHARED_INFRA_ROOT" preflight "PROJECT=$PROJECT_NAME"
