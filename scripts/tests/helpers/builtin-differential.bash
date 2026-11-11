#!/usr/bin/env bash
# Differential check of the fork-free path and byte helpers against the real
# tools they replace. Usage: builtin-differential.bash <repo-root>
# Runs every corpus entry through the helper and through dirname, basename,
# grep in the C locale and in a UTF-8 locale, printing each
# mismatch; exits 1 on any. Run it under every Bash you support.
#
# GNU dirname/basename take --help, --version and their prefixes as options
# that succeed; no Trellis path starts with those, and the helpers fail every
# non-`--` operand that starts with `-`, so the corpus leaves them out.
set -u
root=$1
. "$root/scripts/lib/trellis-home.sh"
. "$root/scripts/lib/attachment.sh"

# attachment.sh carries its own copies of the helpers (it is sourced alone);
# they must stay byte-identical. Sourced last, its copies are the ones run.
for fn in trellis_dirname_to trellis_basename_to trellis_is_sha256_hex trellis_read_nul_fields; do
  body() { sed -n "/^$fn() {/,/^}/p" "$1"; }
  [ -n "$(body "$root/scripts/lib/trellis-home.sh")" ] &&
    [ "$(body "$root/scripts/lib/trellis-home.sh")" = "$(body "$root/scripts/lib/attachment.sh")" ] || {
      printf 'MISMATCH %s differs between trellis-home.sh and attachment.sh\n' "$fn"
      exit 1
    }
done

corpus=()
# shellcheck disable=SC2088  # a literal leading tilde is one of the inputs
for s in '' / // /// //// . .. ./ ../ .// a a/ a// /a //a ///a/ a//b a/b// /a/b/ a/./b a/../b \
  /a/b/c /a/b/c/ - -- -n -a/b --x/y -/ /- a/-b -/- ' ' ' /' '/ ' 'a b/c d' $'a\tb/c' \
  $'a\nb/c' $'a/b\n' $'\n/x' $'a\n' $'\n' $'\n\n' $'/\n' $'\n/' $'a/\n/' $'x/\n\n' $'a/b\n/' \
  $'/\n\n/' $'\001/a' $'a/\177' $'\377/\376' $'\303\251/\303\250' $'\342\200\250/x' $'a/\302\205' \
  $'\302\200' $'\377\001' '*/?' '[a]/b' 'a\/b' '~/x' '$HOME/x' 'a/b c/' "'/\"" '!/!'; do
  corpus+=("$s")
done
i=1
while [ "$i" -le 255 ]; do
  printf -v b "\\$(printf '%03o' "$i")"
  corpus+=("a$b/c$b/" "$b" $'\377'"$b")
  i=$((i + 1))
done

h=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
for s in "$h" "${h%?}" "${h}0" "$(printf '%s' "$h" | tr a-f A-F)" "$h"$'\n' $'x\n'"$h" "$h"$'\nx' \
  $'\n'"$h"$'\n' "$h"$'\r' "$h " " $h" "$h"$'\n'"$h" "${h%?}g" "${h%?}"$'\377' "$h$h"; do
  corpus+=("$s")
done

utf8=''
for candidate in C.UTF-8 en_US.UTF-8 C.utf8 en_US.utf8; do
  if locale -a 2>/dev/null | grep -qx "$candidate"; then utf8=$candidate; break; fi
done

bad=0
miss() {
  bad=$((bad + 1))
  printf 'MISMATCH bash=%s locale=%s %s input=%q real=%q(%s) helper=%q(%s)\n' \
    "$BASH_VERSION" "${LC_ALL:-}" "$1" "$2" "$3" "$4" "$5" "$6"
}

for loc in C $utf8; do
  export LC_ALL=$loc
  for s in "${corpus[@]}"; do
    for tool in dirname basename; do
      real=$("$tool" "$s" 2>/dev/null); rs=$?
      "trellis_${tool}_to" got "$s"; hs=$?
      [ "$real" = "$got" ] && [ "$rs" = "$hs" ] || miss "$tool" "$s" "$real" "$rs" "$got" "$hs"
      real=$("$tool" -- "$s" 2>/dev/null); rs=$?
      "trellis_${tool}_to" got -- "$s"; hs=$?
      [ "$real" = "$got" ] && [ "$rs" = "$hs" ] || miss "$tool --" "$s" "$real" "$rs" "$got" "$hs"
    done
    # The control-byte check is pinned to the C locale, the locale every
    # production caller (launcher env -i, managed hooks LC_ALL=C) runs in.
    LC_ALL=C printf '%s' "$s" | LC_ALL=C grep '[[:cntrl:]]' >/dev/null 2>&1; rs=$?
    _attachment_has_controls "$s"; hs=$?
    [ "$rs" = "$hs" ] || miss _attachment_has_controls "$s" '' "$rs" '' "$hs"
    printf '%s' "$s" | LC_ALL=C grep -Eq '^[a-f0-9]{64}$'; rs=$?
    trellis_is_sha256_hex "$s"; hs=$?
    [ "$rs" = "$hs" ] || miss trellis_is_sha256_hex "$s" '' "$rs" '' "$hs"
  done
done
# Stop-hook baseline selection and state (nonce membership), each hook
# tree's copy against the grep forms it replaced. ref_select reads as text
# (-a): GNU grep in a UTF-8 locale takes an invalid byte such as \377 as a
# binary file and prints "binary file matches" instead of the line, which
# macOS grep does not; the selection the hooks rely on is the line.
ref_select() {
  if printf '%s\n' "$1" | grep -aq '^trellis-turn-baseline '; then
    printf '%s\n' "$1" | grep -a '^trellis-turn-baseline '
  else
    printf '%s\n' "$1"
  fi
}
ref_state() {
  local lines="$1" now="$2" nonces="$3" n
  [ -n "$lines" ] && [ -n "$now" ] && [ -n "$nonces" ] || { echo unknown; return; }
  if printf '%s\n' "$lines" \
       | grep -Evq '^trellis-turn-(baseline|carry) v2 [0-9a-f]{32} (unborn|[0-9a-f]{40}|[0-9a-f]{64}) [0-9a-f]{64}$'; then
    echo unknown
    return
  fi
  for n in $(printf '%s\n' "$lines" | awk '{ print $3 }'); do
    printf '%s\n' "$nonces" | grep -qxF "$n" || { echo unknown; return; }
  done
  if ref_select "$lines" | awk '{ print $4, $5 }' | grep -vqxF "$now"; then
    echo changed
  else
    echo same
  fi
}
n1=0123456789abcdef0123456789abcdef
n2=fedcba9876543210fedcba9876543210
f=$h
b="trellis-turn-baseline v2 $n1 unborn $f"
c="trellis-turn-carry v2 $n2 unborn $f"
lines=('' $'\n' "$b" "$c" "$b"$'\n'"$c" "$c"$'\n'"$b" "$c"$'\n'"$c" "$b"$'\n' $'\n'"$b" \
  'trellis-turn-baseline ' 'trellis-turn-baseline' 'xtrellis-turn-baseline y' ' trellis-turn-baseline y' \
  $'trellis-turn-baseline \377\001' $'\377trellis-turn-baseline y' "$b"$'\r' $'a\n\ntrellis-turn-baseline q\n' \
  "$c"$'\n''trellis-turn-baseline' "$c"$'\n''trellis-turn-baselinex y' "$b"$'\n''trellis-turn-baseline')
nonces=('' "$n1" "$n2" "$n1"$'\n'"$n2" "$n2"$'\n' $'\n'"$n1" "${n1}x" "x$n1" "$n1 " $'\377'"$n1" "$n1"$'\r')
for tree in core-rules/hooks core-rules/codex/hooks; do
  eval "$(sed -n '/^_se_turn_baseline_select()/,/^}/p;/^_se_turn_baseline_state()/,/^}/p' "$root/$tree/lib/deps.sh")"
  for loc in C $utf8; do
    export LC_ALL=$loc
    for l in "${lines[@]}"; do
      real=$(ref_select "$l"; printf .); got=$(_se_turn_baseline_select "$l"; printf .)
      [ "$real" = "$got" ] || miss "$tree _se_turn_baseline_select" "$l" "$real" 0 "$got" 0
    done
    for l in "${lines[@]}"; do
      for v in "${nonces[@]}"; do
        for now in "unborn $f" "unborn $n1" ''; do
          real=$(ref_state "$l" "$now" "$v"); got=$(_se_turn_baseline_state "$l" "$now" "$v")
          [ "$real" = "$got" ] || miss "$tree _se_turn_baseline_state now=$now nonces=$v" "$l" "$real" 0 "$got" 0
        done
      done
    done
  done
done

printf 'checked %s inputs, locales C %s, bash %s: %s mismatches\n' "${#corpus[@]}" "${utf8:-<none>}" "$BASH_VERSION" "$bad"
[ "$bad" -eq 0 ]
