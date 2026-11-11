#!/usr/bin/env bash
# Local-only gitlink fixture. Never clones, uses the network, or configures a
# global Git file. The caller's project and the child repository are private.
t28_seed_submodule() {
  local project="$1" setting="$2" sub="$1/sub"
  mkdir "$sub" || return 1
  git -C "$sub" init -q || return 1
  git -C "$sub" config user.name 'T28 fixture' || return 1
  git -C "$sub" config user.email t28@example.invalid || return 1
  printf 'x = 1\n' > "$sub/lib.py" || return 1
  git -C "$sub" add lib.py && git -C "$sub" commit -qm initial || return 1
  git -C "$project" -c advice.addEmbeddedRepo=false add sub || return 1
  git config -f "$project/.gitmodules" submodule.sub.path sub || return 1
  git config -f "$project/.gitmodules" submodule.sub.url ./unused || return 1
  case "$setting" in
    dirty) git config -f "$project/.gitmodules" submodule.sub.ignore dirty || return 1 ;;
    all|all-head) git config -f "$project/.gitmodules" submodule.sub.ignore all || return 1 ;;
    config) git -C "$project" config diff.ignoreSubmodules dirty || return 1 ;;
    *) return 1 ;;
  esac
  git -C "$project" add .gitmodules && git -C "$project" commit -qm 'add local gitlink'
}

t28_mutate_submodule() {
  local project="$1" setting="$2"
  printf 'x = 2\n' > "$project/sub/lib.py" || return 1
  if [ "$setting" = all-head ]; then
    git -C "$project/sub" add lib.py && git -C "$project/sub" commit -qm 'advance gitlink' || return 1
  fi
}
