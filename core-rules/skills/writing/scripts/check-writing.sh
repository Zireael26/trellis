#!/usr/bin/env bash
set -u

usage() {
  echo "usage: $0 --blog <file.md> | --thread <file.txt>" >&2
}

if [ "$#" -ne 2 ]; then
  usage
  exit 2
fi

mode="$1"
file="$2"

if [ ! -f "$file" ]; then
  usage
  exit 2
fi

SLOP_TERMS="delve delves delving leverage leverages leveraging robust seamless seamlessly tapestry testament pivotal crucial foster fosters fostering elevate elevates unlock unlocks harness harnessing holistic vibrant realm journey journeys comprehensive landscape landscapes"

check_blog() {
  awk -v terms="$SLOP_TERMS" -v apos="'" '
    BEGIN {
      split(terms, slop, " ")
      anti = "not (just |only |merely )?.{3,40}(, |; |\\. )(it|this|that)(" apos "s| is)"
    }

    /^[[:space:]]*```/ {
      in_fence = !in_fence
      next
    }

    !in_fence {
      raw = $0
      low = tolower(raw)
      lines_checked++

      if (index(raw, "—") > 0 || index(raw, "–") > 0) {
        print NR ": dash: em dash or en dash outside fenced code"
        failures++
      }

      slop_hits = ""
      for (i = 1; i in slop; i++) {
        term = slop[i]
        pattern = "(^|[^[:alnum:]_])" term "([^[:alnum:]_]|$)"
        if (low ~ pattern) {
          if (slop_hits == "") {
            slop_hits = term
          } else {
            slop_hits = slop_hits ", " term
          }
        }
      }
      if (low ~ /navigat(e|es|ing|ed) the /) {
        if (slop_hits == "") {
          slop_hits = "navigate-the"
        } else {
          slop_hits = slop_hits ", navigate-the"
        }
      }
      if (slop_hits != "") {
        print NR ": slop vocab: " slop_hits
        failures++
      }

      if (raw ~ /^[[:space:]]*[-*] \*\*/) {
        print NR ": bold lead-in bullet"
        failures++
      }

      scan = low
      while (match(scan, anti)) {
        anti_count++
        anti_line[anti_count] = NR
        scan = substr(scan, RSTART + RLENGTH)
      }
    }

    END {
      if (anti_count > 3) {
        for (i = 1; i <= anti_count; i++) {
          print anti_line[i] ": antithesis pattern"
          failures++
        }
      }

      if (failures > 0) {
        exit 1
      }

      print "blog: checked " lines_checked " non-fenced lines; 0 offenses"
    }
  ' "$file"
}

check_thread() {
  awk '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }

    function finish_block() {
      block_count++
      text = trim(block)
      length_by_block[block_count] = length(text)
      start_by_block[block_count] = block_start
      block = ""
      block_start = NR + 1
    }

    BEGIN {
      block_start = 1
    }

    /^---$/ {
      finish_block()
      next
    }

    {
      if (block == "") {
        block = $0
      } else {
        block = block "\n" $0
      }

      if ($0 ~ /https?:\/\//) {
        link_count++
        link_line[link_count] = NR
      }
    }

    END {
      finish_block()

      if (block_count < 4 || block_count > 8) {
        print "1: thread count: " block_count " blocks, expected 4-8"
        failures++
      }

      for (i = 1; i <= block_count; i++) {
        if (length_by_block[i] > 280) {
          print start_by_block[i] ": thread length: block " i " is " length_by_block[i] " chars"
          failures++
        }
      }

      for (i = 1; i <= link_count; i++) {
        print link_line[i] ": thread link: http:// or https:// is not allowed"
        failures++
      }

      if (failures > 0) {
        exit 1
      }

      print "thread: checked " block_count " blocks; 0 offenses"
    }
  ' "$file"
}

case "$mode" in
  --blog)
    check_blog
    ;;
  --thread)
    check_thread
    ;;
  *)
    usage
    exit 2
    ;;
esac
