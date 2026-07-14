#!/usr/bin/env bash
# Pure parser for blacklist.md project names.
#
# Usage: read_blacklist_names /path/to/blacklist.md
#
# Prints registry-compatible project names from both current blacklist sections:
#   1. the Project column under "Temporarily excluded"
#   2. the basename of the Path column under "Permanently excluded"
# Missing files and placeholder rows produce no output.

read_blacklist_names() {
  local blacklist_file="${1-}"
  [ -n "$blacklist_file" ] || return 0
  [ -f "$blacklist_file" ] || return 0

  awk '
    /^## 1\. Temporarily excluded/ { sec=1; next }
    /^## 2\. Permanently excluded/ { sec=2; next }
    /^## Semantics/                { sec=0 }
    sec==1 && /^\| [a-zA-Z0-9._-]+ \|/ {
      name=$0
      gsub(/^\| /, "", name); gsub(/ \|.*$/, "", name)
      if (name == "Project" || name ~ /^-+$/) next
      print name
      next
    }
    sec==2 && /^\| `\/[A-Za-z0-9._\/-]+` \|/ {
      path=$0
      gsub(/^\| `/, "", path); gsub(/` \|.*$/, "", path)
      n=split(path, parts, "/")
      base=parts[n]
      if (base != "" && base != "Path") print base
    }
  ' "$blacklist_file"
}
