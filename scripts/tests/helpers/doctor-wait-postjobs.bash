#!/usr/bin/env bash
# Fixture launcher children can spawn detached attach checks after env -i
# strips TRELLIS_ATTACH_POSTJOB. Wait only for this private machine's jobs
# before taking a read-only filesystem snapshot; never signal any process.
doctor_wait_postjobs() {
  local home="$1" attempts=0 rc=0 escaped=""
  [ -n "$home" ] || return 1
  command -v pgrep >/dev/null 2>&1 || return 1
  escaped="$(printf '%s' "$home" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"
  while :; do
    rc=0
    pgrep -f "$escaped/releases/.*/attach-postjob\\.sh" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 1 ]; then
      return 0
    fi
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 1200 ]; then
      printf 'fixture attach postjobs did not exit for %s (last pgrep rc=%s)\n' "$home" "$rc" >&2
      return 1
    fi
    sleep 0.25
  done
}
