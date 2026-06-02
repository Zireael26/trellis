#!/usr/bin/env bash
# Recreate ("mirror") the gitignored Trellis inheritance symlinks from a
# project's MAIN git working tree into a linked worktree.
#
# git worktree add does not recreate gitignored files, so worktrees lose all
# .claude/ and .agents/ inheritance symlinks. This script restores them.
#
# Usage: seed-inheritance-symlinks.sh [--target <dir>] [--root <dir>]
#                                     [--quiet] [--verify-only] [--help]
#
# Options:
#   --target <dir>   The worktree to seed. Default: $PWD.
#   --root   <dir>   Explicit TRELLIS_ROOT override (skips resolution).
#   --quiet          Suppress per-symlink "linked"/"skip" lines; still print
#                    WARN/ERROR.
#   --verify-only    Create nothing; report missing/wrong-target symlinks;
#                    exit 1 if any are missing, else 0.
#   --help           Print usage to stdout and exit 0.

set -euo pipefail

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [--target <dir>] [--root <dir>] [--quiet] [--verify-only] [--help]

Recreate gitignored Trellis inheritance symlinks from a project's MAIN git
working tree into a linked worktree.

Options:
  --target <dir>   Worktree to seed. Default: \$PWD.
  --root   <dir>   Explicit TRELLIS_ROOT override (skips auto-resolution).
  --quiet          Suppress per-symlink linked/skip lines; WARNs still printed.
  --verify-only    Check only; exit 1 if any symlinks are missing/wrong-target.
  --help           Show this message and exit 0.
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
TARGET=""
ROOT_OVERRIDE=""
QUIET=0
VERIFY_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --target)
      [ $# -ge 2 ] || { echo "error: --target requires an argument" >&2; usage >&2; exit 2; }
      TARGET="$2"; shift 2 ;;
    --root)
      [ $# -ge 2 ] || { echo "error: --root requires an argument" >&2; usage >&2; exit 2; }
      ROOT_OVERRIDE="$2"; shift 2 ;;
    --quiet)
      QUIET=1; shift ;;
    --verify-only)
      VERIFY_ONLY=1; shift ;;
    --help)
      usage; exit 0 ;;
    -*)
      echo "error: unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *)
      echo "error: unexpected argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Step 1: Resolve TARGET
# ---------------------------------------------------------------------------
if [ -z "$TARGET" ]; then
  TARGET="$PWD"
fi

# Resolve to absolute real path (handles macOS /var vs /private/var)
if [ ! -d "$TARGET" ]; then
  echo "error: target is not a directory: $TARGET" >&2
  exit 1
fi
TARGET="$(cd "$TARGET" && pwd -P)"

# Must be inside a git repo
if ! git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1; then
  echo "error: target is not inside a git repo: $TARGET" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 2: Find the MAIN working tree
# ---------------------------------------------------------------------------
# Parse the first 'worktree <path>' line from the porcelain output.
# We parse in pure bash to avoid SIGPIPE under pipefail (head -1 closes early).
wt_porcelain="$(git -C "$TARGET" worktree list --porcelain)"
# Extract path from the first 'worktree <path>' line
main_line=""
while IFS= read -r line; do
  case "$line" in
    "worktree "*)
      main_line="$line"
      break ;;
  esac
done <<< "$wt_porcelain"

if [ -z "$main_line" ]; then
  echo "error: could not determine main worktree path" >&2
  exit 1
fi

MAIN="${main_line#worktree }"

# Canonicalize MAIN real path (macOS /var -> /private/var)
if [ ! -d "$MAIN" ]; then
  echo "error: main worktree directory does not exist: $MAIN" >&2
  exit 1
fi
MAIN="$(cd "$MAIN" && pwd -P)"

# If TARGET is the main checkout, nothing to mirror
if [ "$MAIN" = "$TARGET" ]; then
  if [ "$QUIET" -eq 0 ]; then
    echo "info: target is the main checkout — nothing to mirror"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 3: Resolve ROOT (TRELLIS_ROOT)
# ---------------------------------------------------------------------------
ROOT=""

if [ -n "$ROOT_OVERRIDE" ]; then
  # Normalize: strip trailing slash
  ROOT="${ROOT_OVERRIDE%/}"
  if [ ! -d "$ROOT" ]; then
    echo "error: --root is not a directory: $ROOT" >&2
    exit 1
  fi
fi

if [ -z "$ROOT" ]; then
  # 3b: readlink of .claude/rules/trellis.md in MAIN
  trellis_link="$MAIN/.claude/rules/trellis.md"
  if [ -L "$trellis_link" ]; then
    link_target="$(readlink "$trellis_link")"
    # Strip trailing /core-rules/CLAUDE.md to get ROOT
    candidate="${link_target%/core-rules/CLAUDE.md}"
    if [ "$candidate" != "$link_target" ] && [ -d "$candidate" ]; then
      ROOT="${candidate%/}"
    fi
  fi
fi

if [ -z "$ROOT" ]; then
  # 3c: $TRELLIS_ROOT env var
  if [ -n "${TRELLIS_ROOT:-}" ] && [ -d "$TRELLIS_ROOT" ]; then
    ROOT="${TRELLIS_ROOT%/}"
  fi
fi

if [ -z "$ROOT" ]; then
  # 3d: $TRELLIS_CONFIG or trellis.config.json walk-up
  cfg_file=""
  if [ -n "${TRELLIS_CONFIG:-}" ] && [ -f "$TRELLIS_CONFIG" ]; then
    cfg_file="$TRELLIS_CONFIG"
  else
    # Walk up from TARGET
    walk="$TARGET"
    while [ "$walk" != "/" ]; do
      if [ -f "$walk/trellis.config.json" ]; then
        cfg_file="$walk/trellis.config.json"
        break
      fi
      walk="$(dirname "$walk")"
    done
  fi
  if [ -n "$cfg_file" ] && command -v jq >/dev/null 2>&1; then
    candidate="$(jq -r '.trellis_root // empty' "$cfg_file" 2>/dev/null || true)"
    if [ -n "$candidate" ] && [ -d "$candidate" ]; then
      ROOT="${candidate%/}"
    fi
  fi
fi

if [ -z "$ROOT" ]; then
  echo "error: could not resolve TRELLIS_ROOT — run: <root>/scripts/onboard-project.sh $TARGET" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 4: Enumerate source symlinks from MAIN
# ---------------------------------------------------------------------------
# Collect (relpath, link_target) pairs where link_target starts with $ROOT/
RELPATHS=()
TARGETS=()

collect_symlinks() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    return 0
  fi
  while IFS= read -r link; do
    local link_target
    link_target="$(readlink "$link")"
    # Keep only symlinks whose target begins with $ROOT/
    case "$link_target" in
      "$ROOT"/*)
        local relpath="${link#"$MAIN"/}"
        RELPATHS+=("$relpath")
        TARGETS+=("$link_target")
        ;;
    esac
    # -maxdepth 2: every Trellis inheritance symlink lives at exactly
    # .claude/<subdir>/<entry> or .agents/<subdir>/<entry> (depth 2). Bounding
    # the search here also prunes nested git worktrees (e.g. Claude session
    # worktrees under .claude/worktrees/<x>/.claude/...) whose own seeded
    # symlinks must NOT be re-mirrored into this target.
  done < <(find "$dir" -maxdepth 2 -type l)
}

collect_symlinks "$MAIN/.claude"
collect_symlinks "$MAIN/.agents"

if [ ${#RELPATHS[@]} -eq 0 ]; then
  echo "info: main checkout has no Trellis inheritance symlinks to mirror"
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 5 & 6: Seed or verify
# ---------------------------------------------------------------------------
seeded_count=0
already_correct_count=0
problem_count=0
total_count=${#RELPATHS[@]}

# In verify-only mode, collect problem paths for reporting
problem_paths=()

i=0
while [ "$i" -lt "$total_count" ]; do
  relpath="${RELPATHS[$i]}"
  link_target="${TARGETS[$i]}"
  dest="$TARGET/$relpath"

  if [ "$VERIFY_ONLY" -eq 1 ]; then
    # Verify mode: check existence and target correctness
    if [ -L "$dest" ]; then
      cur="$(readlink "$dest")"
      if [ "$cur" = "$link_target" ]; then
        already_correct_count=$((already_correct_count + 1))
      else
        problem_count=$((problem_count + 1))
        problem_paths+=("$relpath (wrong target: '$cur', expected '$link_target')")
      fi
    elif [ -e "$dest" ]; then
      problem_count=$((problem_count + 1))
      problem_paths+=("$relpath (exists but is not a symlink)")
    else
      problem_count=$((problem_count + 1))
      problem_paths+=("$relpath (missing)")
    fi
  else
    # Normal seed mode — mirror seed_symlink semantics exactly
    mkdir -p "$(dirname "$dest")"
    if [ -L "$dest" ]; then
      cur="$(readlink "$dest")"
      if [ "$cur" = "$link_target" ]; then
        already_correct_count=$((already_correct_count + 1))
        if [ "$QUIET" -eq 0 ]; then
          echo "skip (correct symlink): $relpath"
        fi
      else
        echo "WARN: $relpath symlinks to '$cur', expected '$link_target' — leaving as-is" >&2
      fi
    elif [ -e "$dest" ]; then
      echo "WARN: $relpath exists and is not a symlink — leaving as-is" >&2
    else
      ln -s "$link_target" "$dest"
      seeded_count=$((seeded_count + 1))
      if [ "$QUIET" -eq 0 ]; then
        echo "linked: $relpath → $link_target"
      fi
    fi
  fi

  i=$((i + 1))
done

# Summary
if [ "$VERIFY_ONLY" -eq 1 ]; then
  if [ $problem_count -gt 0 ]; then
    echo "verify: $problem_count missing/wrong of $total_count inheritance symlinks"
    for p in "${problem_paths[@]}"; do
      echo "  - $p"
    done
    exit 1
  else
    if [ "$QUIET" -eq 0 ]; then
      echo "verify: all $total_count inheritance symlink(s) correct"
    fi
    exit 0
  fi
else
  if [ "$QUIET" -eq 0 ]; then
    echo "seeded $seeded_count symlink(s) into $TARGET ($already_correct_count already correct)"
  fi
fi
