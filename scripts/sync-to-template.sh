#!/usr/bin/env bash
# Sync canonical content from this live Trellis clone to the public Trellis mirror.
#
# Reads trellis.config.json for paths.
# Substitutes user-specific values back to placeholders so the template
# remains shareable.
#
# Default mode: --dry-run (show diff, don't write).
# To actually write: --apply
# To commit + push: --push (requires gh CLI access to the template remote).
#
# Usage:
#   sync-to-template.sh                         # dry-run
#   sync-to-template.sh --apply                 # write to template working tree
#   sync-to-template.sh --apply --push          # also commit + push
#
# On --apply the mirror is PRUNED of de-listed paths (DELIST_PRUNE) then LINTED
# for forbidden content — absolute-path leaks and stale antigravity outside the
# historical record (docs/adr/, docs/specs/, CHANGELOG.md). A lint failure
# ABORTS before any commit/push, so a drifted public-only file (README/SETUP/
# AGENT_SETUP) cannot ship stale content.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/config-load.sh
. "$SCRIPT_DIR/lib/config-load.sh"
# shellcheck source=lib/sed-portable.sh
. "$SCRIPT_DIR/lib/sed-portable.sh"
# shellcheck source=lib/sync-coverage.sh
. "$SCRIPT_DIR/lib/sync-coverage.sh"
# shellcheck source=lib/mirror-lint.sh
. "$SCRIPT_DIR/lib/mirror-lint.sh"

# --- Args ------------------------------------------------------------------
APPLY=false
PUSH=false
TEMPLATE_DIR="${TRELLIS_TEMPLATE_DIR:-$USER_HOME/projects/trellis}"

for arg in "$@"; do
  case "$arg" in
    --apply)        APPLY=true ;;
    --push)         APPLY=true; PUSH=true ;;
    --template-dir=*) TEMPLATE_DIR="${arg#--template-dir=}" ;;
    --dry-run)      APPLY=false; PUSH=false ;;
    --help|-h)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

[ -e "$TEMPLATE_DIR/.git" ] || {
  echo "template repo not found at $TEMPLATE_DIR" >&2
  echo "set TRELLIS_TEMPLATE_DIR or pass --template-dir=<path>" >&2
  exit 1
}

# Files / dirs to sync from live → template
SYNC_PATHS=(
  "engineering-process.md"
  "AGENT_ONBOARD_PROJECT.md"
  "CHANGELOG.md"
  # Public bootstrap shells only. The private source files are copied into the
  # staging area and replaced below before leak checks or mirror writes.
  "dependency-baseline.json"
  "audits/fleet-remediation-ledger.json"
  "core-rules/CLAUDE.md"
  "core-rules/AGENTS.md"
  "core-rules/agents/"
  "core-rules/VERSION"
  "core-rules/codex/"
  "core-rules/hooks.md"
  "core-rules/inheritance.md"
  "core-rules/deferred.md"
  "core-rules/hooks/"
  "core-rules/husky/"
  "core-rules/githooks/"
  "core-rules/skills/"
  "core-rules/commands/"
  "core-rules/templates/"
  "core-rules/references/"
  "docs/adr/"
  "docs/primers/"
  "docs/references/"
  "docs/UPGRADING.md"
  # NOTE: scheduled-tasks/ is NOT synced — it is operator-specific automation
  # whose targets.md / prompt.md files name the private fleet (conductor backlog,
  # dep-watch versions, audit target lists). Published verbatim it leaked named
  # infra ops (audit 2026-07-13 H1/M2). See NEVER_SYNC + DELIST_PRUNE below. A
  # genericized public example set may be re-added deliberately later.
  "scripts/"
  "trellis.config.json"
  # Public-mirror parity (v0.6.0) — formerly instance-only, published on
  # maintainer decision so the public template reaches full feature parity.
  # The 2026-05-08 meta-audit stays private (security-gap detail); its example
  # citation in references/secrets.md was genericized to avoid a dangling ref.
  "recon.md"
  "core-rules/autonomy.md"
  # published because 13 synced files reference it (CLAUDE.md § Loops, references/loops.md, orchestrate skill+recipes) — spec 009 D9.
  "core-rules/loop-safety.md"
  "core-rules/presets/"
  "docs/opus-4.8-steering.md"
  "docs/gpt-5.x-steering.md"
  "docs/codex-routing.md"
  "docs/specs/2026-05-20-trellis-autonomy-design.md"
  "docs/specs/2026-06-02-trellis-process-enforcement-design.md"
  "docs/specs/2026-06-09-loop-safety-contract-design.md"
  "docs/specs/2026-07-21-reference-token-handoff-spike.md"
  "docs/specs/2026-07-21-public-dependency-bootstrap-design.md"
)

# Files NEVER synced (private / instance-specific) — informational; the
# actual exclusion is implemented via SYNC_PATHS being a positive allowlist.
# shellcheck disable=SC2034  # documents intent; not consumed
NEVER_SYNC=(
  "registry.md"
  "blacklist.md"
  # audits/ stays private except for the exact sanitized empty ledger shell in
  # SYNC_PATHS. No source report or private finding row is ever published.
  "audits/"
  "scheduled-tasks/"   # operator-specific automation; names the private fleet (audit 2026-07-13 H1/M2)
  "conductor/"         # conductor slate/state — private fleet inventory
  "research/"          # instance research outputs
  "local/"             # instance-private local tooling — MUST stay private
)

# De-listed / removed paths to PRUNE from the mirror on --apply (Workstream D2).
# The per-subtree `rsync --delete` below only prunes WITHIN wholesale-synced
# dirs; a file removed from SYNC_PATHS or deleted upstream (e.g. a renamed or
# retired doc) lingers in the mirror forever otherwise — docs/antigravity-
# steering.md did exactly that until a manual git rm. This is an explicit
# append-and-forget register, NOT a blanket "delete anything unsynced" (that
# would nuke legit public-only files: README.md, SETUP.md, AGENT_SETUP.md,
# LICENSE, .github/). Add a path here when you de-list or rename it.
DELIST_PRUNE=(
  "docs/antigravity-steering.md"   # retired in RC.4 (AntiGravity strip)
  "docs/gpt-5.5-steering.md"       # renamed → docs/gpt-5.x-steering.md in RC.5
  "scheduled-tasks"                # de-listed 2026-07-13 (audit H1/M2): named private-fleet leak
)

delist_prune_path_safe() {
  case "$1" in
    ""|"."|".."|/*|"~"*|*..*) return 1 ;;
    *) return 0 ;;
  esac
}

# core-rules/ subdirs deliberately kept instance-private — the explicit
# "do not publish" register that the sync-coverage pre-flight checks against.
# Each bare basename here is a core-rules/<name>/ subdir that must NEVER reach
# the public template. Document WHY for every entry:
#   evals — per-project eval suites; subdirs identify registered private
#           projects. Instance-private, intentionally never published.
# shellcheck disable=SC2034  # consumed via "${CORE_RULES_NO_SYNC[@]}" below
CORE_RULES_NO_SYNC=(
  "evals"
)

# Placeholder substitutions: live values → template placeholders
declare -a SUB_FROM=("$TRELLIS_ROOT" "$SOURCE_ROOT" "$PROJECTS_ROOT" "$USER_HOME" "$MAINTAINER_NAME" "$GITHUB_USER")
declare -a SUB_TO=("__TRELLIS_PATH__" "__TRELLIS_PATH__" "__PROJECTS_ROOT__" "__USER_HOME__" "__MAINTAINER_NAME__" "__GITHUB_USER__")

sync_path_covers_ref() {
  local ref sync_path
  ref="$1"
  for sync_path in "${SYNC_PATHS[@]+"${SYNC_PATHS[@]}"}"; do
    if [ "$sync_path" = "$ref" ]; then
      return 0
    fi
    case "$sync_path" in
      */)
        case "$ref" in
          "$sync_path"*) return 0 ;;
        esac
        ;;
    esac
  done
  return 1
}

core_rules_private_ref() {
  local ref private_dir
  ref="$1"
  for private_dir in "${CORE_RULES_NO_SYNC[@]+"${CORE_RULES_NO_SYNC[@]}"}"; do
    case "$ref" in
      "core-rules/$private_dir/"*) return 0 ;;
    esac
  done
  return 1
}

ref_integrity_check() {
  local failed refs_tmp files_tmp sync_path src md_file rel ref
  failed=0
  refs_tmp="$(mktemp)"
  files_tmp="$(mktemp)"

  for sync_path in "${SYNC_PATHS[@]+"${SYNC_PATHS[@]}"}"; do
    src="${SOURCE_ROOT}/${sync_path%/}"
    if [ -f "$src" ]; then
      case "$src" in
        *.md) ;;
        *) continue ;;
      esac
      grep -oE 'core-rules/[A-Za-z0-9._/-]*\.md' "$src" 2>/dev/null | sort -u > "$refs_tmp" || true
      while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        core_rules_private_ref "$ref" && continue
        if ! sync_path_covers_ref "$ref"; then
          echo "ref-integrity: $sync_path -> $ref" >&2
          failed=1
        fi
      done < "$refs_tmp"
    elif [ -d "$src" ]; then
      find "$src" -type f -name '*.md' -print > "$files_tmp"
      while IFS= read -r md_file; do
        rel="${md_file#$SOURCE_ROOT/}"
        grep -oE 'core-rules/[A-Za-z0-9._/-]*\.md' "$md_file" 2>/dev/null | sort -u > "$refs_tmp" || true
        while IFS= read -r ref; do
          [ -n "$ref" ] || continue
          core_rules_private_ref "$ref" && continue
          if ! sync_path_covers_ref "$ref"; then
            echo "ref-integrity: $rel -> $ref" >&2
            failed=1
          fi
        done < "$refs_tmp"
      done < "$files_tmp"
    fi
  done

  rm -f "$refs_tmp" "$files_tmp"
  [ "$failed" -eq 0 ]
}

# --- Pre-flight: core-rules/ sync coverage ---------------------------------
# Fail closed if any core-rules/<name>/ subdir is neither published
# (SYNC_PATHS) nor explicitly kept private (CORE_RULES_NO_SYNC). Runs in ALL
# modes (including the default dry-run) so the gap is caught before any work.
# The helper returns 1 by design when uncovered subdirs exist; `|| true` keeps
# pipefail from killing the script before we can print the actionable message.
echo "==> Checking core-rules/ sync coverage"
uncovered="$(check_core_rules_coverage "$SOURCE_ROOT" \
  "$(printf '%s\n' "${SYNC_PATHS[@]+"${SYNC_PATHS[@]}"}")" \
  "$(printf '%s\n' "${CORE_RULES_NO_SYNC[@]+"${CORE_RULES_NO_SYNC[@]}"}")" )" || true
if [ -n "$uncovered" ]; then
  echo "  ERROR: core-rules/ subdir(s) neither in SYNC_PATHS nor CORE_RULES_NO_SYNC:" >&2
  printf '%s\n' "$uncovered" | sed 's|^|    |' >&2
  echo "  Decide for each: add to SYNC_PATHS (publish to the template) or to CORE_RULES_NO_SYNC (keep instance-private)." >&2
  echo "  This guard prevents the PR #78 class of silent omission. Aborting." >&2
  exit 1
fi
echo "  all core-rules/ subdirs classified."

echo "==> Checking synced markdown references"
if ! ref_integrity_check; then
  exit 1
fi
echo "  all synced markdown refs covered."

# --- Workspace -------------------------------------------------------------
TMP_STAGE="$(mktemp -d)"
trap 'rm -rf "$TMP_STAGE"' EXIT

echo "==> Staging in $TMP_STAGE"
for p in "${SYNC_PATHS[@]}"; do
  src="${SOURCE_ROOT}/${p%/}"
  if [ ! -e "$src" ]; then
    echo "skip (missing in live): $p"
    continue
  fi
  dst="${TMP_STAGE}/${p%/}"
  if [ -d "$src" ]; then
    mkdir -p "$dst"
    # check-secrets.bats carries literal secret-pattern fixtures (fake
    # sk_live_… keys) that trip GitHub push protection for anyone cloning
    # the public template. Keep it instance-only; the public skill ships the
    # detector + its other tests without the fixture footgun.
    # scripts/workflows/*.js and scripts/full-audit-sweep-ledger.mjs are
    # operator one-off execution artifacts (per-project redis/audit/sweep runs)
    # with hardcoded instance paths + github user. They are not framework, and
    # the placeholder pass below does not cover .js/.mjs, so they would leak
    # live values into the public mirror. Keep them instance-only.
    rsync -a --delete \
      --exclude='__pycache__/' --exclude='.DS_Store' --exclude='*.swp' \
      --exclude='check-secrets.bats' \
      --exclude='/workflows/' --exclude='/full-audit-sweep-ledger.mjs' \
      "${src}/" "${dst}/"
  else
    mkdir -p "$(dirname "$dst")"
    cp -P "$src" "$dst"
  fi
done

# Substitute placeholders in every text file we just staged
echo "==> Substituting placeholders"
find "$TMP_STAGE" -type f \( -name '*.md' -o -name '*.sh' -o -name '*.json' -o -name '*.yaml' -o -name '*.yml' -o -name '*.toml' \) -print0 \
  | while IFS= read -r -d '' f; do
      for i in "${!SUB_FROM[@]}"; do
        from="${SUB_FROM[$i]}"
        to="${SUB_TO[$i]}"
        # Treat configured values as literals. The search side must escape
        # basic-regex metacharacters; the replacement side must escape '&'
        # and backslashes as well as the '/' delimiter.
        from_esc="$(printf '%s\n' "$from" | sed -e 's/[][\/.^$*\\]/\\&/g')"
        to_esc="$(printf '%s\n' "$to" | sed -e 's/[\/&\\]/\\&/g')"
        sed_inplace -e "s/$from_esc/$to_esc/g" "$f"
      done
    done

# Reset trellis.config.json to placeholder shape
if [ -f "$TMP_STAGE/trellis.config.json" ]; then
  cat > "$TMP_STAGE/trellis.config.json" <<'EOF'
{
  "$schema": "./scripts/lib/trellis.config.schema.json",
  "comment": "Edit this file after cloning. Replace placeholders with absolute paths and your details before invoking onboard-project.sh, sync-hooks.sh, sync-codex-hooks.sh, or sync-to-template.sh. Keep harnesses as [\"claude\"] for Claude-only installs; add \"codex\" when opting into Codex parity. Multiple harnesses may be enabled together.",

  "trellis_root": "__TRELLIS_PATH__",
  "projects_root": "__PROJECTS_ROOT__",
  "user_home": "__USER_HOME__",

  "maintainer_name": "__MAINTAINER_NAME__",
  "github_user": "__GITHUB_USER__",

  "harnesses": ["claude"],

  "template": {
    "remote": "git@github.com:__GITHUB_USER__/trellis.git",
    "branch": "main",
    "redact_paths": [
      "audits/",
      "blacklist.md",
      "registry.md"
    ]
  },

  "sed_flavor": "auto"
}
EOF
fi

# Publish schema-valid bootstrap shells, never the instance's fleet policy or
# finding receipts. A public clone can run `trellis deps check` immediately;
# maintainers populate their own baseline with `trellis deps snapshot` after
# registering projects. Keep these deterministic so repeated syncs are clean.
if [ -f "$TMP_STAGE/dependency-baseline.json" ]; then
  cat > "$TMP_STAGE/dependency-baseline.json" <<'EOF'
{
  "$schema": "./scripts/lib/fleet-dependency-baseline.schema.json",
  "schema_version": 1,
  "source_ref": "origin/main",
  "policy": {
    "shared_project_minimum": 2,
    "direct_versions": "exact-per-lane",
    "peer_versions": "compatible-range",
    "expired_exceptions": "fail"
  },
  "toolchains": [],
  "packages": [],
  "security_floors": [],
  "exceptions": []
}
EOF
fi

if [ -f "$TMP_STAGE/audits/fleet-remediation-ledger.json" ]; then
  cat > "$TMP_STAGE/audits/fleet-remediation-ledger.json" <<'EOF'
{
  "$schema": "../scripts/lib/fleet-remediation-ledger.schema.json",
  "schema_version": 1,
  "audit_date": "2026-07-21",
  "source_reports": [],
  "findings": []
}
EOF
fi

# Verify no live values leaked through
echo "==> Verifying no live values remain"
LEAK=0
for v in "${SUB_FROM[@]}"; do
  if grep -rq --binary-files=without-match "$v" "$TMP_STAGE" 2>/dev/null; then
    echo "  LEAK: '$v' still present in staged tree" >&2
    grep -rln "$v" "$TMP_STAGE" 2>/dev/null | head -5 | sed 's|^|    |'
    LEAK=1
  fi
done
[ "$LEAK" -eq 0 ] || { echo "redaction failed; aborting" >&2; exit 1; }
echo "  clean."

# --- Diff against template tree --------------------------------------------
echo "==> Diff vs $TEMPLATE_DIR"
DIFF_OUT="$(mktemp)"
{
  for p in "${SYNC_PATHS[@]}"; do
    src_stage="${TMP_STAGE}/${p%/}"
    dst_template="${TEMPLATE_DIR}/${p%/}"
    if [ -d "$src_stage" ] || [ -d "$dst_template" ]; then
      diff -urN --exclude='.git' "$dst_template" "$src_stage" 2>/dev/null || true
    elif [ -f "$src_stage" ] || [ -f "$dst_template" ]; then
      diff -uN "$dst_template" "$src_stage" 2>/dev/null || true
    fi
  done
} > "$DIFF_OUT"

if [ ! -s "$DIFF_OUT" ]; then
  echo "  no changes."
else
  echo "  $(wc -l <"$DIFF_OUT") diff lines"
  if ! $APPLY; then
    echo
    echo "===== DIFF (first 200 lines) ====="
    head -200 "$DIFF_OUT"
    echo "===== END DIFF ====="
    echo
    echo "Re-run with --apply to write to $TEMPLATE_DIR (no commit)."
    echo "Re-run with --apply --push to commit + push to template remote."
  fi
fi

# --- Dry-run post-sync simulation + lint -----------------------------------
# Dry-run must validate the state that --apply would produce, not the stale
# mirror currently on disk. Build that state under TMP_STAGE: start from the
# full mirror working tree (including public-only files), overlay the staged
# SYNC_PATHS with apply-equivalent delete semantics, then remove only safe
# DELIST_PRUNE entries. The real mirror is never touched.
if ! $APPLY; then
  SIMULATED_MIRROR="$TMP_STAGE/.simulated-mirror"
  mkdir -p "$SIMULATED_MIRROR"
  echo "==> Building simulated post-sync mirror for dry-run lint"
  rsync -a --delete --exclude='.git/' "$TEMPLATE_DIR/" "$SIMULATED_MIRROR/"

  for p in "${SYNC_PATHS[@]}"; do
    src_stage="${TMP_STAGE}/${p%/}"
    dst_simulated="${SIMULATED_MIRROR}/${p%/}"
    [ -e "$src_stage" ] || continue
    if [ -d "$src_stage" ]; then
      mkdir -p "$dst_simulated"
      rsync -a --delete "${src_stage}/" "${dst_simulated}/"
    else
      mkdir -p "$(dirname "$dst_simulated")"
      cp -P "$src_stage" "$dst_simulated"
    fi
  done

  for dp in ${DELIST_PRUNE[@]+"${DELIST_PRUNE[@]}"}; do
    if ! delist_prune_path_safe "$dp"; then
      echo "  SKIP unsafe DELIST_PRUNE entry in simulation: '$dp'" >&2
      continue
    fi
    [ -e "$SIMULATED_MIRROR/$dp" ] || continue
    rm -rf "${SIMULATED_MIRROR:?}/$dp"
  done

  echo "==> Linting simulated post-sync mirror for forbidden content"
  if lint_out="$(lint_mirror "$SIMULATED_MIRROR" "$TRELLIS_ROOT" "$SOURCE_ROOT" "$PROJECTS_ROOT" "$USER_HOME")"; then
    echo "  simulated mirror clean."
  else
    echo "  MIRROR LINT FAILED — forbidden content in the simulated post-sync mirror:" >&2
    printf '%s\n' "$lint_out" | sed 's|^|    |' >&2
    echo "  Fix the offending files before publishing. Real mirror was not touched. Aborting." >&2
    exit 1
  fi
fi

# --- Apply -----------------------------------------------------------------
if $APPLY; then
  echo "==> Writing to $TEMPLATE_DIR"
  for p in "${SYNC_PATHS[@]}"; do
    src_stage="${TMP_STAGE}/${p%/}"
    dst_template="${TEMPLATE_DIR}/${p%/}"
    if [ ! -e "$src_stage" ]; then
      continue
    fi
    if [ -d "$src_stage" ]; then
      mkdir -p "$dst_template"
      rsync -a --delete "${src_stage}/" "${dst_template}/"
    else
      mkdir -p "$(dirname "$dst_template")"
      cp -P "$src_stage" "$dst_template"
    fi
  done
  echo "  applied."

  # --- Prune de-listed paths (Workstream D2) --------------------------------
  echo "==> Pruning de-listed paths from mirror"
  pruned_any=false
  for dp in ${DELIST_PRUNE[@]+"${DELIST_PRUNE[@]}"}; do
    # Path-safety: a typo'd entry (empty, ., .., absolute, tilde, or any path
    # containing ..) must NEVER reach the destructive rm — it could delete the
    # mirror root or escape it. Skip loudly (cross-model review finding).
    if ! delist_prune_path_safe "$dp"; then
      echo "  SKIP unsafe DELIST_PRUNE entry: '$dp'" >&2
      continue
    fi
    if [ -e "$TEMPLATE_DIR/$dp" ]; then
      git -C "$TEMPLATE_DIR" rm -rf --ignore-unmatch --quiet -- "$dp" 2>/dev/null || rm -rf "${TEMPLATE_DIR:?}/$dp"
      echo "  pruned: $dp"
      pruned_any=true
    fi
  done
  $pruned_any || echo "  nothing to prune."

  # --- Post-apply denylist lint (Workstream D1) -----------------------------
  # Greps the WHOLE mirror — including public-only files the sync never touches
  # (README/SETUP/AGENT_SETUP/architecture.svg) — for absolute-path leaks and
  # stale antigravity outside the historical record. Fail-closed: abort before
  # any commit/push. This is the guard the RC.4 stale-antigravity regression
  # (in exactly those unsynced files) would have tripped.
  echo "==> Linting mirror for forbidden content"
  if lint_out="$(lint_mirror "$TEMPLATE_DIR" "$TRELLIS_ROOT" "$SOURCE_ROOT" "$PROJECTS_ROOT" "$USER_HOME")"; then
    echo "  mirror clean."
  else
    echo "  MIRROR LINT FAILED — forbidden content in the public mirror:" >&2
    printf '%s\n' "$lint_out" | sed 's|^|    |' >&2
    echo "  Fix the offending files before publishing. Aborting." >&2
    exit 1
  fi

  if $PUSH; then
    echo "==> Committing in template repo"
    cd "$TEMPLATE_DIR"
    git add -A
    if git diff --cached --quiet; then
      echo "  no staged changes — nothing to commit."
    else
      git status --short
      printf "Commit + push? [y/N] "
      read -r ans
      if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
        git commit -m "chore: sync from live Trellis clone ($(date +%Y-%m-%d))"
        git push origin "$TEMPLATE_BRANCH"
      else
        echo "  aborted before commit."
      fi
    fi
  fi
fi

rm -f "$DIFF_OUT"
