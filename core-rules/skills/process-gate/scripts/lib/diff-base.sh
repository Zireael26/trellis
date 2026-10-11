#!/usr/bin/env bash
# diff-base.sh — shared diff-base resolver (spec 067 6.1.1-6.1.5).
# Bash 3.2 compatible, sourced or executed. Only operator sync calls gh.
# Sourced: db_resolve [--ref X] [--head S] [--mode push|merge] [--base R]
#   [--range R] sets DB_BASE_SHA/REF/SOURCE/REASON/RANGE/HEAD_SHA/REF.
case "${BASH_SOURCE[0]:-$0}" in "$0") set -u ;; esac
DB_BASE_SHA=""; DB_BASE_REF=""; DB_SOURCE=""; DB_REASON=""
DB_RANGE=""; DB_HEAD_SHA=""; DB_HEAD_REF=""; DB_POLICY_OVERRIDE=""
db_short() { printf '%s' "$1" | cut -c1-12; }
db_sref() {
  case "$1" in
    refs/remotes/*) printf '%s' "${1#refs/remotes/}" ;;
    refs/heads/*) printf '%s' "${1#refs/heads/}" ;;
    *) printf '%s' "$1" ;;
  esac
}
db_rev() { git rev-parse --verify -q "$1^{commit}" 2>/dev/null; }
db_anc() { git merge-base --is-ancestor "$1" "$2" 2>/dev/null; }
db_cbranch() {
  local s
  s="$(git symbolic-ref -q HEAD 2>/dev/null)" || return 1
  case "$s" in refs/heads/*) printf '%s' "${s#refs/heads/}" ;; *) return 1 ;; esac
}
db_cfg() { git config --get "$1" 2>/dev/null || true; }
# template.branch as the base declares it: the remote default's tree, else local
# main/master's. Never the checkout under test, whose range could set it.
db_base_policy() {
  local rm sym c ref f b
  command -v jq >/dev/null 2>&1 || return 0
  rm="$(db_remote)"; ref=""
  if [ -n "$rm" ]; then
    sym="$(git symbolic-ref -q "refs/remotes/$rm/HEAD" 2>/dev/null)" || sym=""
    for c in "$sym" "refs/remotes/$rm/main" "refs/remotes/$rm/master"; do
      if [ -n "$c" ] && db_rev "$c" >/dev/null; then ref="$c"; break; fi
    done
  fi
  if [ -z "$ref" ]; then
    for c in refs/heads/main refs/heads/master; do
      if db_rev "$c" >/dev/null; then ref="$c"; break; fi
    done
  fi
  [ -n "$ref" ] || return 0
  for f in .trellis.json .trellis.config.json; do
    b="$(git show "$ref:$f" 2>/dev/null | jq -r '.template.branch // empty' 2>/dev/null)" || continue
    if [ -n "$b" ]; then printf '%s' "$b"; return; fi
  done
  return 0
}
db_policy() {
  if [ -n "$DB_POLICY_OVERRIDE" ]; then printf '%s' "$DB_POLICY_OVERRIDE"; return; fi
  local b
  b="$(db_base_policy)"
  if [ -n "$b" ]; then printf '%s' "$b"; return; fi
  command -v jq >/dev/null 2>&1 || return 0
  if [ -n "${TRELLIS_ROOT:-}" ] && [ -f "$TRELLIS_ROOT/trellis.config.json" ]; then
    b="$(jq -r '.template.branch // empty' "$TRELLIS_ROOT/trellis.config.json" 2>/dev/null)" || return 0
    [ -n "$b" ] && printf '%s' "$b"
  fi
  return 0
}
db_remote() {
  local r
  if git rev-parse --verify -q refs/remotes/origin/HEAD >/dev/null 2>&1; then printf 'origin'; return; fi
  if git for-each-ref --format='%(refname)' refs/remotes/origin 2>/dev/null | grep -q . 2>/dev/null; then printf 'origin'; return; fi
  r="$(git remote 2>/dev/null | head -n 1)" || r=""
  printf '%s' "$r"
}
# Print the branch refname policy $1 names: refs/remotes/<remote $2>/<name>, or
# refs/heads/<name> with no remote. HEAD, @, a revision expression, an object
# name, an option or a non-branch ref names none (return 1).
db_polname() {
  local pol="$1" rm="$2" name
  case "$pol" in ""|-*|HEAD|@|*@\{*|*..*|*[~^:?*\[\\]*) return 1 ;; esac
  case "$pol" in
    refs/remotes/*/HEAD) return 1 ;;
    refs/remotes/?*/?*) git check-ref-format "$pol" || return 1; printf '%s' "$pol"; return 0 ;;
    refs/heads/?*) name="${pol#refs/heads/}" ;;
    refs/*) return 1 ;;
    *) name="$pol" ;;
  esac
  git check-ref-format --branch "$name" >/dev/null 2>&1 || return 1
  [ -z "$(git rev-parse --disambiguate="$name" 2>/dev/null)" ] || return 1
  if [ -n "$rm" ]; then printf 'refs/remotes/%s/%s' "$rm" "$name"; else printf 'refs/heads/%s' "$name"; fi
}
# Sets _dd_ref/_dd_reason/_dd_tip. Returns 1 when unresolvable, 2 when a declared
# template.branch names no existing branch: the caller refuses, never guesses.
db_defbranch() {
  _dd_ref=""; _dd_reason=""; _dd_tip=""
  local rm pol sym c ref
  rm="$(db_remote)"; pol="$(db_policy)"
  if [ -n "$pol" ]; then
    if ref="$(db_polname "$pol" "$rm")" && git show-ref --verify -q "$ref" &&
       _dd_tip="$(db_rev "$ref")" && [ -n "$_dd_tip" ]; then
      _dd_ref="$ref"
      if [ -z "$rm" ]; then _dd_reason="no remote"; else _dd_reason="policy $pol"; fi
      return 0
    fi
    _dd_tip=""
    # Only the runtime's default (the template's own branch, declared by
    # neither the base nor the caller) may be an absent branch, and is ignored.
    if [ -n "$DB_POLICY_OVERRIDE" ] || [ -n "$(db_base_policy)" ] || ! db_polname "$pol" "$rm" >/dev/null; then
      return 2
    fi
  fi
  if [ -n "$rm" ]; then
    sym="$(git symbolic-ref -q "refs/remotes/$rm/HEAD" 2>/dev/null)" || sym=""
    if [ -n "$sym" ] && _dd_tip="$(db_rev "$sym")" && [ -n "$_dd_tip" ]; then
      _dd_ref="$sym"; _dd_reason="default $(db_sref "$sym")"; return 0
    fi
    for c in main master; do
      if _dd_tip="$(db_rev "refs/remotes/$rm/$c")" && [ -n "$_dd_tip" ]; then
        _dd_ref="refs/remotes/$rm/$c"; _dd_reason="default $(db_sref "$_dd_ref")"; return 0
      fi
    done
  fi
  for c in main master; do
    if _dd_tip="$(db_rev "$c")" && [ -n "$_dd_tip" ]; then
      _dd_ref="$c"
      if [ -z "$rm" ]; then _dd_reason="no remote"; else _dd_reason="default $c (no remote-tracking)"; fi
      return 0
    fi
  done
  return 1
}
# Sets _rl_p/_rl_b. Empty _rl_p means no reflog tier.
db_reflog() {
  _rl_p=""; _rl_b=""
  local b cm log line new raw hl hline y
  b="$1"; [ -n "$b" ] || return 0
  cm="$(git rev-parse --git-common-dir 2>/dev/null)" || return 0
  case "$cm" in /*) ;; *) cm="$(git rev-parse --show-toplevel 2>/dev/null)/$cm" ;; esac
  log="$cm/logs/refs/heads/$b"; [ -f "$log" ] || return 0
  line="$(grep "branch: Created from " "$log" 2>/dev/null | head -n 1)" || return 0
  [ -n "$line" ] || return 0
  new="$(printf '%s' "$line" | awk '{print $2}')"
  raw="$(printf '%s' "$line" | sed -n 's/.*branch: Created from //p' | tr -d '\r\n')"
  [ -n "$raw" ] || return 0
  if [ "$raw" != "HEAD" ]; then _rl_p="$raw"; _rl_b="$new"; return 0; fi
  hl="$cm/logs/HEAD"; [ -f "$hl" ] || return 0
  hline="$(grep "checkout: moving from .* to $b$" "$hl" 2>/dev/null | head -n 1)" || return 0
  [ -n "$hline" ] || return 0
  y="$(printf '%s' "$hline" | sed -n 's/.*checkout: moving from //p' | sed -n "s| to $b$||p" | awk '{print $1}')"
  if [ -z "$y" ]; then y="$(printf '%s' "$hline" | sed -n 's/.*moving from //p' | sed 's/ to .*//')"; fi
  [ -n "$y" ] || return 0
  _rl_p="$y"; _rl_b="$new"
}
# Sets _up_ref/_up_name. Empty means unusable.
db_upstream() {
  _up_ref=""; _up_name=""
  local b f s br
  b="$1"; [ -n "$b" ] || return 0
  f="$(git rev-parse --symbolic-full-name "$b@{u}" 2>/dev/null)" || return 0
  case "$f" in
    refs/heads/*) br="${f#refs/heads/}"; [ "$br" != "$b" ] || return 0; _up_ref="$f"; _up_name="$br" ;;
    refs/remotes/*) s="${f#refs/remotes/}"; br="${s#*/}"; [ "$br" != "$b" ] || return 0; _up_ref="$f"; _up_name="$s" ;;
    *) return 0 ;;
  esac
}
db_receipt() {
  local b12 bref rng head
  if [ -n "$DB_BASE_SHA" ]; then b12="$(db_short "$DB_BASE_SHA")"; else b12="-"; fi
  if [ -n "$DB_BASE_REF" ]; then bref="$DB_BASE_REF"; else bref="-"; fi
  case "$DB_SOURCE" in
    explicit)
      rng="$DB_RANGE"
      case "$DB_REASON" in explicit|explicit\;*) ;; *) rng="$(db_short "$DB_BASE_SHA")..$(db_short "$DB_HEAD_SHA")" ;; esac
      ;;
    refused) rng="-" ;;
    *) rng="$(db_short "$DB_BASE_SHA")..$(db_short "$DB_HEAD_SHA")" ;;
  esac
  if [ -n "$DB_HEAD_REF" ]; then head="$DB_HEAD_REF"; else head="detached"; fi
  printf 'diff-base: %s %s via %s (%s) range=%s head=%s\n' "$b12" "$bref" "$DB_SOURCE" "$DB_REASON" "$rng" "$head"
}
# Refine parent P with recorded R into DB_*. $3=source, $4=recorded parent
# for pr-cache dual print. Returns 0 on use, 2 on skip, 1 on unusable.
db_refine() {
  local P R SRC PRECP Pt Ps mb fp ok rec stale
  P="$1"; R="$2"; SRC="$3"; PRECP="$4"
  case "$P" in refs/heads/*) Ps="${P#refs/heads/}" ;; refs/remotes/*) Ps="${P#refs/remotes/}" ;; *) Ps="$P" ;; esac
  if [ "$P" = "$_b" ] || [ "$P" = "refs/heads/$_b" ]; then return 2; fi
  if Pt="$(db_rev "$P")" && [ -n "$Pt" ]; then
    if [ "$Pt" = "$_h" ]; then return 2; fi
    if [ -n "$_dd_tip" ] && db_anc "$Pt" "$_dd_tip"; then
      if mb="$(git merge-base "$_dd_ref" "$_h" 2>/dev/null)" && [ -n "$mb" ]; then DB_BASE_SHA="$mb"; else DB_BASE_SHA="$_dd_tip"; fi
      DB_BASE_REF="$(db_sref "$_dd_ref")"; DB_SOURCE="default"; DB_REASON="parent $Ps merged → default"
      DB_RANGE="$DB_BASE_SHA..$_h"; DB_HEAD_SHA="$_h"; return 0
    fi
    fp=""; ok=0
    if fp="$(git merge-base --fork-point "$P" "$_h" 2>/dev/null)" && [ -n "$fp" ] && db_rev "$fp" >/dev/null 2>&1 && db_anc "$fp" "$_h"; then ok=1; else fp=""; fi
    mb="$(git merge-base "$P" "$_h" 2>/dev/null)" || return 1
    [ -n "$mb" ] || return 1
    if [ "$ok" -eq 1 ]; then DB_BASE_SHA="$fp"; else DB_BASE_SHA="$mb"; fp=""; fi
    stale=0; rec=""
    if [ -n "$R" ]; then
      if db_anc "$R" "$_h"; then
        if [ "$R" != "$DB_BASE_SHA" ] && db_anc "$mb" "$R"; then
          if [ "$ok" -eq 1 ] && db_anc "$R" "$fp"; then :; else DB_BASE_SHA="$R"; rec=1; fi
        fi
      else stale=1; fi
    fi
    DB_BASE_REF="$Ps"; DB_HEAD_SHA="$_h"; DB_RANGE="$DB_BASE_SHA..$_h"; DB_SOURCE="$SRC"
    if [ "$stale" -eq 1 ]; then DB_REASON="recorded base stale (branch rebased)";
    elif [ -n "$rec" ]; then DB_REASON="parent $Ps (recorded base; parent rebased)";
    elif [ -n "$fp" ] && [ "$fp" != "$mb" ]; then DB_REASON="parent $Ps; fork-point";
    else DB_REASON="parent $Ps"; fi
    if [ "$SRC" = "pr-cache" ] && [ -n "$PRECP" ] && [ "$PRECP" != "$P" ] && [ "$PRECP" != "$Ps" ]; then
      DB_REASON="pr-cache $Ps (recorded: $PRECP); $DB_REASON"
    fi
    return 0
  fi
  [ -n "$_dd_ref" ] || return 1
  if [ -n "$R" ] && db_anc "$R" "$_h"; then
    if db_anc "$R" "$_dd_tip"; then
      if mb="$(git merge-base "$_dd_ref" "$_h" 2>/dev/null)" && [ -n "$mb" ]; then DB_BASE_SHA="$mb"; else DB_BASE_SHA="$_dd_tip"; fi
      DB_BASE_REF="$(db_sref "$_dd_ref")"; DB_SOURCE="default"; DB_REASON="parent $Ps merged → default"
      DB_RANGE="$DB_BASE_SHA..$_h"; DB_HEAD_SHA="$_h"; return 0
    fi
    DB_BASE_SHA="$R"; DB_BASE_REF="$Ps"; DB_SOURCE="recorded"; DB_REASON="parent $Ps gone; recorded sha"
    DB_RANGE="$R..$_h"; DB_HEAD_SHA="$_h"; return 0
  fi
  if mb="$(git merge-base "$_dd_ref" "$_h" 2>/dev/null)" && [ -n "$mb" ]; then DB_BASE_SHA="$mb"; else DB_BASE_SHA="$_dd_tip"; fi
  DB_BASE_REF="$(db_sref "$_dd_ref")"; DB_SOURCE="default"; DB_REASON="parent $Ps deleted; no record"
  DB_RANGE="$DB_BASE_SHA..$_h"; DB_HEAD_SHA="$_h"; return 0
}
db_resolve() {
  DB_BASE_SHA=""; DB_BASE_REF=""; DB_SOURCE=""; DB_REASON=""; DB_RANGE=""; DB_HEAD_SHA=""; DB_HEAD_REF=""
  local ref head mode base range pol
  ref=""; head=""; mode="push"; base=""; range=""; pol=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --ref=*) ref="${1#--ref=}" ;; --ref) ref="${2:-}"; shift ;;
      --head=*) head="${1#--head=}" ;; --head) head="${2:-}"; shift ;;
      --mode=*) mode="${1#--mode=}" ;; --mode) mode="${2:-}"; shift ;;
      --base=*) base="${1#--base=}" ;; --base) base="${2:-}"; shift ;;
      --range=*) range="${1#--range=}" ;; --range) range="${2:-}"; shift ;;
      --policy=*) pol="${1#--policy=}" ;; --policy) pol="${2:-}"; shift ;;
      --format=*) ;; --format) shift ;;
      *) break ;;
    esac
    shift
  done
  case "$mode" in push|merge) ;; *) mode="push" ;; esac
  DB_POLICY_OVERRIDE="$pol"
  _b=""; _h=""; _det=0
  if [ -n "$head" ]; then
    _h="$(db_rev "$head")" || _h=""
    if [ -z "$_h" ] && ! _h="$(git rev-parse --verify -q "$head^{commit}" 2>/dev/null)" && [ -z "$_h" ]; then
      DB_SOURCE="refused"; DB_REASON="no diff base resolvable; pass --base"; DB_BASE_REF="-"; return 1
    fi
    [ -n "$_h" ] || { DB_SOURCE="refused"; DB_REASON="no diff base resolvable; pass --base"; DB_BASE_REF="-"; return 1; }
  else
    _h="$(git rev-parse --verify -q "HEAD^{commit}" 2>/dev/null)" || _h=""
    if [ -z "$_h" ]; then DB_SOURCE="refused"; DB_REASON="no diff base resolvable; pass --base"; DB_BASE_REF="-"; return 1; fi
  fi
  DB_HEAD_SHA="$_h"
  if [ -n "$ref" ]; then
    case "$ref" in refs/heads/*) _b="${ref#refs/heads/}" ;; *) _b="$ref" ;; esac
  else
    _b="$(db_cbranch)" || _b=""
  fi
  if [ -z "$_b" ]; then _det=1; DB_HEAD_REF=""; else DB_HEAD_REF="$_b"; fi
  if [ -n "$range" ]; then
    local st en three ss es
    three=0
    case "$range" in
      *...*) st="${range%%...*}"; en="${range##*...}"; three=1 ;;
      *..*) st="${range%%..*}"; en="${range##*..}" ;;
      *) DB_SOURCE="refused"; DB_REASON="explicit range invalid; pass --range=<start>..<end>"; DB_BASE_REF="-"; return 1 ;;
    esac
    if [ -z "$st" ] || [ -z "$en" ]; then DB_SOURCE="refused"; DB_REASON="explicit range invalid; pass --range=<start>..<end>"; DB_BASE_REF="-"; return 1; fi
    ss="$(db_rev "$st")" || ss=""; es="$(db_rev "$en")" || es=""
    if [ -z "$ss" ] || [ -z "$es" ]; then DB_SOURCE="refused"; DB_REASON="explicit range unresolvable; pass --base"; DB_BASE_REF="-"; return 1; fi
    DB_BASE_SHA="$ss"; DB_HEAD_SHA="$es"; DB_BASE_REF="-"; DB_SOURCE="explicit"; DB_RANGE="$range"
    if [ "$three" -eq 1 ]; then DB_REASON="explicit";
    elif db_anc "$ss" "$es"; then DB_REASON="explicit";
    else DB_REASON="explicit; start not ancestor of head (tree diff)"; fi
    return 0
  fi
  if [ -n "$base" ]; then
    local bc m2
    bc="$(db_rev "$base")" || bc=""
    if [ -z "$bc" ]; then DB_SOURCE="refused"; DB_REASON="explicit base unresolvable; pass --base"; DB_BASE_REF="-"; return 1; fi
    if m2="$(git merge-base "$bc" "$_h" 2>/dev/null)" && [ -n "$m2" ]; then DB_BASE_SHA="$m2"; DB_REASON="explicit --base $base";
    else DB_BASE_SHA="$bc"; DB_REASON="explicit --base $base (no merge-base)"; fi
    if [ "$base" = "$bc" ]; then DB_BASE_REF="-"; else DB_BASE_REF="$base"; fi
    DB_HEAD_SHA="$_h"; DB_SOURCE="explicit"; DB_RANGE="$DB_BASE_SHA..$_h"
    return 0
  fi
  if [ "$mode" = "merge" ]; then
    DB_SOURCE="refused"; DB_REASON="merge mode requires --range/--base"; DB_BASE_REF="-"; return 1
  fi
  _dd_ref=""; _dd_reason=""; _dd_tip=""
  local ddrc=0
  db_defbranch || ddrc=$?
  if [ "$ddrc" -eq 2 ]; then
    DB_SOURCE="refused"; DB_REASON="template.branch names no branch; no diff base resolvable; pass --range"; DB_BASE_REF="-"; return 1
  fi
  if [ "$_det" -eq 1 ]; then
    if [ -z "$_dd_ref" ]; then DB_SOURCE="refused"; DB_REASON="no diff base resolvable; pass --base"; DB_BASE_REF="-"; return 1; fi
    if DB_BASE_SHA="$(git merge-base "$_dd_ref" "$_h" 2>/dev/null)" && [ -n "$DB_BASE_SHA" ]; then :; else DB_BASE_SHA="$_dd_tip"; fi
    DB_BASE_REF="$(db_sref "$_dd_ref")"; DB_SOURCE="default"; DB_REASON="detached HEAD"; DB_RANGE="$DB_BASE_SHA..$_h"
    return 0
  fi
  local prec rrec prb rc
  prec="$(db_cfg "branch.$_b.trellisParent")"; rrec="$(db_cfg "branch.$_b.trellisBase")"; prb="$(db_cfg "branch.$_b.trellisPrBase")"
  db_reflog "$_b"; db_upstream "$_b"
  if [ -n "$prb" ] && db_refine "$prb" "$rrec" "pr-cache" "$prec"; then return 0; else rc=$?; [ "$rc" -eq 0 ] && return 0; fi
  if [ -n "$prec" ] && db_refine "$prec" "$rrec" "recorded" ""; then return 0; else rc=$?; [ "$rc" -eq 0 ] && return 0; fi
  if [ -n "$_rl_p" ] && db_refine "$_rl_p" "$_rl_b" "reflog" ""; then return 0; else rc=$?; [ "$rc" -eq 0 ] && return 0; fi
  if [ -n "$_up_ref" ] && db_refine "$_up_ref" "" "upstream" ""; then return 0; else rc=$?; [ "$rc" -eq 0 ] && return 0; fi
  if [ -z "$_dd_ref" ]; then DB_SOURCE="refused"; DB_REASON="no diff base resolvable; pass --base"; DB_BASE_REF="-"; return 1; fi
  if DB_BASE_SHA="$(git merge-base "$_dd_ref" "$_h" 2>/dev/null)" && [ -n "$DB_BASE_SHA" ]; then :; else DB_BASE_SHA="$_dd_tip"; fi
  DB_BASE_REF="$(db_sref "$_dd_ref")"; DB_SOURCE="default"; DB_HEAD_SHA="$_h"; DB_RANGE="$DB_BASE_SHA..$_h"
  case "$_dd_reason" in no\ remote*) DB_REASON="no remote" ;; policy*) DB_REASON="$_dd_reason" ;; *) DB_REASON="no recorded parent" ;; esac
  return 0
}
db_resolve_cmd() {
  local fmt prev a
  fmt="kv"; prev=""
  for a in "$@"; do
    if [ "$prev" = "--format" ]; then fmt="$a"; fi
    case "$a" in --format=kv) fmt="kv" ;; --format=receipt) fmt="receipt" ;; esac
    prev="$a"
  done
  if db_resolve "$@"; then
    if [ "$fmt" = "receipt" ]; then db_receipt; else
      printf 'DB_BASE_SHA=%s\nDB_BASE_REF=%s\nDB_SOURCE=%s\nDB_REASON=%s\nDB_RANGE=%s\nDB_HEAD_SHA=%s\nDB_HEAD_REF=%s\n' "$DB_BASE_SHA" "$DB_BASE_REF" "$DB_SOURCE" "$DB_REASON" "$DB_RANGE" "$DB_HEAD_SHA" "$DB_HEAD_REF"
    fi
    return 0
  fi
  if [ "$fmt" = "receipt" ]; then db_receipt; else
    printf 'DB_BASE_SHA=%s\nDB_BASE_REF=%s\nDB_SOURCE=%s\nDB_REASON=%s\nDB_RANGE=%s\nDB_HEAD_SHA=%s\nDB_HEAD_REF=%s\n' "$DB_BASE_SHA" "$DB_BASE_REF" "$DB_SOURCE" "$DB_REASON" "$DB_RANGE" "$DB_HEAD_SHA" "$DB_HEAD_REF"
  fi
  case "$DB_REASON" in
    merge\ mode*) printf 'merge mode requires --range/--base\n' >&2 ;;
    template.branch*) printf '%s\n' "$DB_REASON" >&2 ;;
    *) printf 'no diff base resolvable; pass --base\n' >&2 ;;
  esac
  return 1
}
db_export() {
  if db_resolve "$@"; then printf -- '--range=%s..%s\n' "$DB_BASE_SHA" "$DB_HEAD_SHA"; return 0; fi
  return 1
}
db_show() {
  if db_resolve "$@"; then db_receipt; return 0; fi
  db_receipt; return 1
}
db_set() {
  local par ref br bs dd a
  par=""; ref=""; dd=0
  for a in "$@"; do
    if [ "$dd" -eq 1 ]; then if [ -z "$par" ]; then par="$a"; elif [ "$ref" = "__n__" ]; then ref="$a"; fi; continue; fi
    if [ "$ref" = "__n__" ]; then ref="$a"; continue; fi
    case "$a" in
      --) dd=1 ;; --ref=*) ref="${a#--ref=}" ;; --ref) ref="__n__" ;;
      --*) printf 'unknown flag %s\n' "$a" >&2; return 1 ;;
      *) if [ -z "$par" ]; then par="$a"; fi ;;
    esac
  done
  if [ -z "$par" ]; then printf 'usage: diff-base.sh set <parent-ref> [--ref <branch>]\n' >&2; return 1; fi
  if [ -n "$ref" ] && [ "$ref" != "__n__" ]; then
    case "$ref" in refs/heads/*) br="${ref#refs/heads/}" ;; *) br="$ref" ;; esac
  else
    br="$(db_cbranch)" || br=""
    if [ -z "$br" ]; then printf 'cannot determine branch; pass --ref\n' >&2; return 1; fi
  fi
  if ! bs="$(git merge-base "$par" HEAD 2>/dev/null)" || [ -z "$bs" ]; then
    bs="$(db_rev "$par")" || bs=""
    if [ -z "$bs" ]; then printf 'unknown parent ref %s\n' "$par" >&2; return 1; fi
  fi
  git config "branch.$br.trellisParent" "$par" || return 1
  git config "branch.$br.trellisBase" "$bs" || return 1
  git config "branch.$br.trellisSource" "manual" || return 1
  printf 'recorded %s -> parent %s base %s\n' "$br" "$par" "$(db_short "$bs")"
}
db_clear() {
  local ref br k
  ref=""
  for a in "$@"; do
    case "$a" in --ref=*) ref="${a#--ref=}" ;; --ref) ref="__n__" ;; *) if [ "$ref" = "__n__" ]; then ref="$a"; fi ;; esac
  done
  if [ -n "$ref" ] && [ "$ref" != "__n__" ]; then
    case "$ref" in refs/heads/*) br="${ref#refs/heads/}" ;; *) br="$ref" ;; esac
  else
    br="$(db_cbranch)" || br=""
    if [ -z "$br" ]; then printf 'cannot determine branch; pass --ref\n' >&2; return 1; fi
  fi
  for k in trellisParent trellisBase trellisSource trellisPrBase trellisPrBaseOid trellisPrNumber trellisPrCheckedAt; do
    git config --unset "branch.$br.$k" 2>/dev/null || true
  done
  printf 'cleared %s\n' "$br"
}
# Operator-only writer: validate gh's status and complete JSON before any write.
db_sync() {
  local br json vals base oid number checked
  command -v gh >/dev/null 2>&1 || { printf 'diff-base: sync: gh not found; install gh and authenticate with gh auth login\n' >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { printf 'diff-base: sync: jq not found; install jq\n' >&2; return 1; }
  br="$(db_cbranch)" || { printf 'diff-base: sync: cannot determine current branch\n' >&2; return 1; }
  json="$(gh pr view --json number,baseRefName,baseRefOid 2>/dev/null)" || {
    printf 'diff-base: sync: gh pr view failed; authenticate with gh auth login and retry\n' >&2; return 1
  }
  vals="$(printf '%s' "$json" | jq -er '
    [.baseRefName, .baseRefOid, .number] |
    select((.[0] | type) == "string" and (.[0] | length) > 0 and
           (.[1] | type) == "string" and (.[1] | length) > 0 and
           (.[2] | type) == "number" and .[2] > 0) | @tsv
  ' 2>/dev/null)" || {
    printf 'diff-base: sync: invalid PR data from gh pr view\n' >&2; return 1
  }
  IFS=$'\t' read -r base oid number <<EOF
$vals
EOF
  checked="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
  git config --local "branch.$br.trellisPrBase" "$base" || return 1
  git config --local "branch.$br.trellisPrBaseOid" "$oid" || return 1
  git config --local "branch.$br.trellisPrNumber" "$number" || return 1
  git config --local "branch.$br.trellisPrCheckedAt" "$checked" || return 1
  printf 'synced %s -> PR #%s base %s\n' "$br" "$number" "$base"
}
db_usage() {
  cat <<'EOF'
usage: diff-base.sh resolve [--ref X] [--head S] [--mode push|merge] [--base R] [--range R] [--format=kv|receipt]
       diff-base.sh export [--ref X] [--head S] [--mode MODE] [--base R] [--range R]
       diff-base.sh show [--ref X] [--head S] [--mode MODE]
       diff-base.sh set <parent-ref> [--ref <branch>]
       diff-base.sh clear [--ref <branch>]
       diff-base.sh sync
EOF
}
db_main() {
  local c
  c="${1:-}"
  case "$c" in
    resolve) shift; db_resolve_cmd "$@" ;; export) shift; db_export "$@" ;;
    show) shift; db_show "$@" ;; set) shift; db_set "$@" ;; clear) shift; db_clear "$@" ;;
    sync) shift; db_sync "$@" ;;
    -h|--help|help) db_usage ;; *) db_usage >&2; return 1 ;;
  esac
}
if [ -n "${BASH_SOURCE:-}" ]; then
  if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then db_main "$@"; fi
else
  if [ "${0##*/}" = "diff-base.sh" ]; then db_main "$@"; fi
fi
