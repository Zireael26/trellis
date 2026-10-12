#!/usr/bin/env bash
# scripts/pi-spill-watchdog.sh — truncate runaway pi-bash-*.log files (>2 GiB)
#
# Spec 069 AC C4: runs every 60s via launchd org.trellis.pi-spill-watchdog.
# Roots: ~/.pi-worktrees, $TMPDIR, $TMPDIR/pi, ~/.trellis/pi-worktrees (maxdepth 1).
# Truncates any pi-bash-*.log larger than 2 GiB to 0 using `truncate -s 0`,
# NEVER unlinks. Logs path, size in bytes, and open lsof PIDs.
#
# Usage: pi-spill-watchdog.sh [--dry-run] [--root <dir>]...

set -euo pipefail

DRY_RUN=false
ROOTS=()
TWO_GIB=2147483648

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --root)
      [ "$#" -ge 2 ] || {
        printf 'pi-spill-watchdog: --root requires a directory argument\n' >&2
        exit 2
      }
      ROOTS+=("$2")
      shift 2
      ;;
    --help|-h)
      printf 'Usage: pi-spill-watchdog.sh [--dry-run] [--root <dir>]...\n'
      exit 0
      ;;
    *)
      printf 'pi-spill-watchdog: unknown option: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [ "${#ROOTS[@]}" -eq 0 ]; then
  user_home="${HOME:-}"
  [ -n "$user_home" ] && ROOTS+=("$user_home/projects/worktrees/_pi")
  [ -n "$user_home" ] && ROOTS+=("$user_home/.pi-worktrees")

  darwin_temp="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
  darwin_temp="${darwin_temp%/}"
  [ -n "$darwin_temp" ] && ROOTS+=("$darwin_temp" "$darwin_temp/pi")

  tmp_clean="${TMPDIR:-}"
  tmp_clean="${tmp_clean%/}"
  if [ -n "$tmp_clean" ]; then
    is_launcher_scratch=false
    case "$tmp_clean" in
      */state/scratch/.cmd.*|*/state/scratch/*)
        is_launcher_scratch=true
        ;;
    esac
    if [ "$is_launcher_scratch" = false ]; then
      real_tmp="$(cd "$tmp_clean" 2>/dev/null && pwd -P || echo "$tmp_clean")"
      real_darwin=""
      [ -n "$darwin_temp" ] && real_darwin="$(cd "$darwin_temp" 2>/dev/null && pwd -P || echo "$darwin_temp")"
      if [ "$real_tmp" != "$real_darwin" ] && [ "$tmp_clean" != "$darwin_temp" ]; then
        ROOTS+=("$tmp_clean" "$tmp_clean/pi")
      fi
    fi
  elif [ -z "$darwin_temp" ]; then
    ROOTS+=("/tmp" "/tmp/pi")
  fi

  [ -n "$user_home" ] && ROOTS+=("$user_home/.trellis/pi-worktrees")
fi

for root in "${ROOTS[@]}"; do
  root="${root%/}"
  [ -n "$root" ] || continue
  [ "$root" != "/" ] || continue
  [ -d "$root" ] || continue
  [ ! -L "$root" ] || continue

  # Maxdepth 1: match pi-bash-*.log directly under root
  for file in "$root"/pi-bash-*.log; do
    [ -e "$file" ] || continue
    [ -f "$file" ] || continue
    [ ! -L "$file" ] || continue

    size="$(stat -f '%z' "$file" 2>/dev/null || stat -c '%s' "$file" 2>/dev/null || echo 0)"
    case "$size" in
      ''|*[!0-9]*) size=0 ;;
    esac

    if [ "$size" -gt "$TWO_GIB" ]; then
      pids="$(lsof -t "$file" 2>/dev/null | tr '\n' ' ' | sed -e 's/[[:space:]]*$//' 2>/dev/null || true)"
      if [ -z "$pids" ]; then
        pids="none"
      fi

      if [ "$DRY_RUN" = true ]; then
        printf 'pi-spill-watchdog: [dry-run] would truncate %s (%s bytes, pids: %s)\n' "$file" "$size" "$pids"
      else
        truncate -s 0 "$file" 2>/dev/null || : > "$file"
        printf 'pi-spill-watchdog: truncated %s (%s bytes, pids: %s)\n' "$file" "$size" "$pids"
      fi
    fi
  done
done

exit 0
