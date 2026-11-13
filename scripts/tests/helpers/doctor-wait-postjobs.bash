#!/usr/bin/env bash
# Fixture launcher children can spawn detached attach checks after env -i
# strips TRELLIS_ATTACH_POSTJOB. Wait only for this private machine's jobs
# before taking a read-only filesystem snapshot; never signal any process.
doctor_wait_postjobs() {
  local home="$1" attempts=0
  command -v pgrep >/dev/null 2>&1 || return 1
  while :; do
    if pgrep -f "$home/releases/.*/attach-postjob.sh" >/dev/null 2>&1; then
      attempts=$((attempts + 1))
      if [ "$attempts" -ge 1200 ]; then
        printf 'fixture attach postjobs did not exit for %s\n' "$home" >&2
        return 1
      fi
      sleep 0.25
    else
      [ "$?" -eq 1 ] || return 1
      return 0
    fi
  done
}
