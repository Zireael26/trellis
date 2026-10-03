#!/usr/bin/env bash
# R1 equivalence evidence for Bats suites (spec 057 §4 R1, amendment A1 F1).
#
# A "pure move" splits one .bats file into parts without touching a single test.
# This tool proves that, or names what moved. It never runs a test: the only
# Bats invocation is `bats --count`, which sources each file's top-level code.
#
# Usage:
#   test-equivalence.sh emit --tree TREE [--map FILE | --infer] [FILE...]
#   test-equivalence.sh diff --base TREE --split TREE [--map FILE] [--review FILE]
#                            [--emit-dir DIR] [ORIGINAL...]
#
# TREE is a directory, or else a git ref resolved in the repository that holds
# the current directory (extracted read-only with `git archive`). FILE,
# ORIGINAL and every mapped path are relative to the tree root.
#
# Exit: 0 equivalent (or emitted), 1 at least one difference, 2 usage, input or
# parse error. Exit 2 means nothing was proven either way.
#
# emit prints a TSV with the columns original, file, kind, seq, name, value:
#   count      bats --count of the file (cross-checked against the @test headers)
#   lifecycle  setup, setup_file, teardown, teardown_file: sha256 of the whole
#              definition, header to closing brace
#   function   every other column-0 function, the same way; a name defined twice
#              is keyed name#2
#   helper     every file brought in by `load` (resolved as Bats does: relative to
#              the test file's directory, `.bash` first), and every `.`/`source`
#              of a literal path inside the test file's directory; nested loads in
#              helpers are followed. name is the tree-relative path, value its
#              sha256 (or `missing` / `unresolved`)
#   toplevel   every top-level statement line outside functions and @test blocks
#              (variables, export, load, traps, `# bats` directives other than
#              test_tags), in file order. name is the line, with `\` and TAB
#              escaped as `\\` and `\t`; value is sha256 of the line
#   test       one row per @test in file order: name is the description as Bats
#              reads it, value is sha256 of the body (any `# bats test_tags=`
#              lines above it, the rest of the header line after `{`, and every
#              line to the closing brace)
# Blank lines and comments outside blocks are not items; comments inside a block
# are part of its hash. Rows are grouped by original (LC_ALL=C order), then by
# file in declared part order; lifecycle, function and helper rows are sorted.
#
# diff compares the base tree's originals with the split tree's parts and fails
# unless, for every original:
#   - its parts, concatenated in declared order, list exactly the original's
#     tests in the original's order; no test is dropped, added, renamed or
#     reordered, and no name appears in two parts (or twice in one);
#   - the parts' `bats --count` values sum to the original's;
#   - every test body hash matches (never waivable: R1.1);
#   - every part carries every lifecycle, function, helper and top-level
#     statement of the original, byte-identical and nothing more (setup_file and
#     teardown_file run once per file, so each part needs its own copy),
#     except where a review entry names the difference (R1.2).
# A review entry that matches no difference is itself a failure.
#
# The diff report is a TSV: status, original, part, kind, name, detail. status
# is FAIL, REVIEWED (a difference a review entry covers), or one summary row per
# original, OK or NOT-OK. --emit-dir DIR also writes base.tsv, split.tsv and
# report.tsv there, for receipts.
#
# Split mapping. Either --map FILE, one line per original:
#     scripts/tests/doctor.bats -> scripts/tests/doctor-part1.bats scripts/tests/doctor-part2.bats
# (`#` comments and blank lines allowed; parts are listed in run order), or the
# naming convention, used when --map is absent: an original DIR/STEM.bats splits
# into DIR/STEM-part1.bats, DIR/STEM-part2.bats, ... numbered from 1 with no
# gaps and no leading zeros, and DIR/STEM.bats must no longer exist in the
# split tree. When no parts exist and DIR/STEM.bats is still present, the file
# maps to itself (an unsplit or moved-whole file).
#
# Review file (R1.2), TAB-separated, `#` comments allowed, seven fields:
#     original  part  kind  key  reviewer_family  what_changed  why_preserved
# part is a part path or `*`; kind is lifecycle, function, helper or toplevel;
# key is the function name, the helper path, or for toplevel the sha256 of the
# line that is added, removed or changed (a changed line needs both hashes).
#
# The parser is line based and heredoc and quote aware. It refuses (exit 2) a
# file it cannot prove it read correctly: an unterminated block, heredoc or
# quote; a block that `bash -n` rejects; a static @test count that differs from
# `bats --count`; or dynamic registration via bats_test_function.

set -euo pipefail

PROG="test-equivalence"

usage() {
  sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"
}

die() {
  printf '%s: %s\n' "$PROG" "$*" >&2
  exit 2
}

sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

# sha256 of each named file, as "<basename>\t<hash>" lines.
sha256_files() {
  local out
  if command -v shasum >/dev/null 2>&1; then
    out="$(shasum -a 256 "$@")"
  else
    out="$(sha256sum "$@")"
  fi
  printf '%s\n' "$out" | awk '{ h = $1; sub(/^[^ ]+ [ *]/, ""); n = split($0, p, "/"); print p[n] "\t" h }'
}

WORK=""
cleanup() {
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

TREE_DIR=""
TREE_LABEL=""
TREE_SEQ=0

# tree_prepare SPEC: sets TREE_DIR (physical path) and TREE_LABEL.
tree_prepare() {
  local spec="$1" commit
  if [ -d "$spec" ]; then
    TREE_DIR="$(CDPATH='' cd "$spec" && pwd -P)"
    TREE_LABEL="directory"
    return 0
  fi
  commit="$(git rev-parse --verify --quiet "$spec^{commit}")" ||
    die "not a directory or a git ref here: $spec"
  TREE_SEQ=$((TREE_SEQ + 1))
  TREE_DIR="$WORK/tree.$TREE_SEQ"
  mkdir -p "$TREE_DIR"
  git archive --format=tar "$commit" | tar -xf - -C "$TREE_DIR" ||
    die "could not extract $spec ($commit)"
  TREE_DIR="$(CDPATH='' cd "$TREE_DIR" && pwd -P)"
  TREE_LABEL="$commit"
}

# Line-based parser. Prints an index on stdout and writes one segment file per
# hashed item under segdir:
#   T <seq> <seg> <name> <line>    @test
#   F <key> <seg> <line>           column-0 function
#   L <seq> <seg> <text> <line>    top-level statement line
#   D <word> <line>                load argument
#   S <word> <line>                ./source argument
#   E <line> <message>             parse error
# segdir/top.all collects every top-level line for one `bash -n`.
equiv_parse() {
  LC_ALL=C awk -v segdir="$1" '
    BEGIN {
      SQ = "\047"; DQ = "\""
      ctx = ""; q = 0; inhd = 0; hd_n = 0; hd_cur = 0
      tseq = 0; topseq = 0; segn = 0; tags = ""
      topall = segdir "/top.all"
      printf "" > topall
    }
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/\t/, "\\t", s); return s }
    function err(m) { print "E\t" NR "\t" m }
    function newseg() { segn++; curid = sprintf("%05d", segn); curseg = segdir "/" curid }
    function put(s) { printf "%s\n", s > curseg }
    function endseg() { close(curseg) }
    function top(s) {
      topseq++; newseg(); put(s); endseg()
      printf "%s\n", s > topall
      print "L\t" topseq "\t" curid "\t" esc(s) "\t" NR
    }
    # Bats: ^[[:blank:]]*@test[[:blank:]]+(.*[^[:blank:]])[[:blank:]]+\{(.*)$
    # The name group is greedy, so the header splits at the last blank-then-{.
    function test_header(s,   t, k, pre, c) {
      if (s !~ /^[ \t]*@test[ \t]+/) return 0
      t = s; sub(/^[ \t]*@test[ \t]+/, "", t)
      for (k = length(t); k > 1; k--) {
        if (substr(t, k, 1) == "{" && substr(t, k - 1, 1) ~ /[ \t]/) {
          pre = substr(t, 1, k - 1); sub(/[ \t]+$/, "", pre)
          if (pre == "") continue
          c = substr(pre, 1, 1); if (c == SQ || c == DQ) pre = substr(pre, 2)
          c = substr(pre, length(pre), 1); if (c == SQ || c == DQ) pre = substr(pre, 1, length(pre) - 1)
          TNAME = pre; TREM = substr(t, k + 1)
          return 1
        }
      }
      return 0
    }
    function func_header(s,   t) {
      if (s ~ /^function[ \t]+[A-Za-z_][A-Za-z0-9_:.-]*[ \t]*(\(\)[ \t]*)?\{/ ||
          s ~ /^[A-Za-z_][A-Za-z0-9_:.-]*[ \t]*\(\)[ \t]*\{/) {
        t = s; sub(/^function[ \t]+/, "", t)
        match(t, /^[A-Za-z_][A-Za-z0-9_:.-]*/)
        FNAME = substr(t, 1, RLENGTH)
        FREM = substr(s, index(s, "{") + 1)
        return 1
      }
      return 0
    }
    function single_line(rem) { return rem ~ /;[ \t]*\}[ \t]*$/ || rem ~ /^[ \t]*\}[ \t]*$/ }
    function word(t,   c) {
      c = substr(t, 1, 1)
      if (c == DQ && match(t, /^"[^"]*"/)) return substr(t, 1, RLENGTH)
      if (c == SQ && match(t, "^" SQ "[^" SQ "]*" SQ)) return substr(t, 1, RLENGTH)
      match(t, /^[^ \t;&|)]+/)
      return substr(t, 1, RLENGTH)
    }
    function loads(s,   t) {
      if (s ~ /^[ \t]*load[ \t]+[^ \t;]/) {
        t = s; sub(/^[ \t]*load[ \t]+/, "", t); print "D\t" word(t) "\t" NR
      } else if (s ~ /^[ \t]*(\.|source)[ \t]+[^ \t;]/) {
        t = s; sub(/^[ \t]*(\.|source)[ \t]+/, "", t); print "S\t" word(t) "\t" NR
      }
    }
    # Carries quote state across lines and queues heredoc delimiters.
    function scan(s,   i, n, c, j, strip, rest, d, adv) {
      n = length(s); i = 1
      while (i <= n) {
        c = substr(s, i, 1)
        if (q == 1) { if (c == SQ) q = 0; i++; continue }
        if (q == 2 || q == 3) {
          if (c == "\\") { i += 2; continue }
          if ((q == 2 && c == DQ) || (q == 3 && c == SQ)) q = 0
          i++; continue
        }
        if (c == "\\") { i += 2; continue }
        if (c == SQ) { q = 1; i++; continue }
        if (c == DQ) { q = 2; i++; continue }
        if (c == "$" && substr(s, i + 1, 1) == SQ) { q = 3; i += 2; continue }
        if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t;(|&]/)) break
        if (c == "<" && substr(s, i + 1, 1) == "<") {
          if (substr(s, i + 2, 1) == "<") { i += 3; continue }
          j = i + 2; strip = 0
          if (substr(s, j, 1) == "-") { strip = 1; j++ }
          while (substr(s, j, 1) ~ /[ \t]/) j++
          rest = substr(s, j)
          if (match(rest, "^" SQ "[^" SQ "]+" SQ) || match(rest, /^"[^"]+"/)) {
            d = substr(rest, 2, RLENGTH - 2); adv = RLENGTH
          } else if (match(rest, /^\\?[A-Za-z_][A-Za-z0-9_]*/)) {
            d = substr(rest, 1, RLENGTH); sub(/^\\/, "", d); adv = RLENGTH
          } else { i += 2; continue }
          hd_n++; hd_word[hd_n] = d; hd_strip[hd_n] = strip
          i = j + adv; continue
        }
        i++
      }
    }
    {
      line = $0
      if (inhd) {
        if (ctx != "") put(line); else top(line)
        w = line; if (hd_strip[hd_cur]) sub(/^\t+/, "", w)
        if (w == hd_word[hd_cur]) { hd_cur++; if (hd_cur > hd_n) { inhd = 0; hd_n = 0; hd_cur = 0 } }
        next
      }
      if (ctx == "") {
        if (q == 0 && test_header(line)) {
          tseq++; newseg(); ctx = "test"; start = NR
          if (tags != "") { printf "%s", tags > curseg; tags = "" }
          put(TREM)
          print "T\t" tseq "\t" curid "\t" esc(TNAME) "\t" NR
          scan(TREM)
          if (single_line(TREM)) { endseg(); ctx = "" }
        } else if (q == 0 && func_header(line)) {
          newseg(); ctx = "function"; start = NR; put(line)
          fcount[FNAME]++
          key = FNAME; if (fcount[FNAME] > 1) key = FNAME "#" fcount[FNAME]
          print "F\t" key "\t" curid "\t" NR
          scan(FREM)
          if (single_line(FREM)) { endseg(); ctx = "" }
        } else if (q == 0 && line ~ /^[ \t]*#[ \t]*bats[ \t]+test_tags=/) {
          tags = tags line "\n"
        } else if (q == 0 && (line ~ /^[ \t]*$/ || (line ~ /^[ \t]*#/ && line !~ /^[ \t]*#[ \t]*bats[ \t]/))) {
          # blank line or comment: not a file-level item
        } else {
          top(line); loads(line); scan(line)
        }
      } else if (q == 0 && line ~ /^\}/) {
        put(line); endseg(); ctx = ""; scan(line)
      } else {
        if (q == 0 && test_header(line)) err("@test header inside the " ctx " block opened at line " start)
        put(line); loads(line); scan(line)
      }
      if (!inhd && hd_n > 0) { inhd = 1; hd_cur = 1 }
    }
    END {
      if (ctx != "") err("unterminated " ctx " block opened at line " start)
      if (inhd) err("unterminated heredoc, expecting " hd_word[hd_cur])
      if (q != 0) err("unterminated quote at end of file")
      if (tags != "") err("bats test_tags directive with no @test after it")
      close(topall)
    }
  ' "$2"
}

# resolve_helper TREE_DIR TEST_DIR KIND WORD: prints "<key>\t<path-or-empty>".
# KIND D resolves like Bats `load`; KIND S admits only literal paths inside the
# test file's directory and prints nothing for anything else.
resolve_helper() {
  local tree="$1" testdir="$2" kind="$3" arg="$4" p rel
  case "$arg" in
    \"*\") arg="${arg#\"}"; arg="${arg%\"}" ;;
    \'*\') arg="${arg#\'}"; arg="${arg%\'}" ;;
  esac
  arg="${arg//\$\{BATS_TEST_DIRNAME\}/$testdir}"
  arg="${arg//\$BATS_TEST_DIRNAME/$testdir}"
  if [ "$kind" = S ]; then
    arg="${arg//\$\{REPO_ROOT\}/$tree}"
    arg="${arg//\$REPO_ROOT/$tree}"
  fi
  case "$arg" in
    *'$'* | *'`'*)
      [ "$kind" = D ] && printf 'unresolved:%s\t\n' "$4"
      return 0
      ;;
  esac
  case "$arg" in /*) ;; *) arg="$testdir/$arg" ;; esac
  if [ "$kind" = D ] && [ -f "$arg.bash" ]; then
    p="$arg.bash"
  elif [ -f "$arg" ]; then
    p="$arg"
  else
    [ "$kind" = D ] && printf 'missing:%s\t\n' "$4"
    return 0
  fi
  p="$(CDPATH='' cd "$(dirname "$p")" && pwd -P)/$(basename "$p")"
  if [ "$kind" = S ]; then
    case "$p" in "$testdir"/*) ;; *) return 0 ;; esac
  fi
  rel="${p#"$tree"/}"
  [ "$rel" = "$p" ] && rel="outside-tree:$p"
  printf '%s\t%s\n' "$rel" "$p"
}

FILE_SEQ=0

# emit_file TREE_DIR ORIGINAL FILE: the rows for one file.
emit_file() {
  local tree="$1" orig="$2" rel="$3" path d testdir count static
  local tag a b c id key sha kind
  path="$tree/$rel"
  [ -f "$path" ] || die "no such file in tree: $rel"
  if grep -q 'bats_test_function' "$path"; then
    die "$rel registers tests dynamically (bats_test_function); R1 cannot prove its identity"
  fi
  FILE_SEQ=$((FILE_SEQ + 1))
  d="$WORK/file.$FILE_SEQ"
  mkdir -p "$d/seg"
  testdir="$(CDPATH='' cd "$(dirname "$path")" && pwd -P)"

  equiv_parse "$d/seg" "$path" > "$d/index"
  if grep -q '^E' "$d/index"; then
    awk -F '\t' -v f="$rel" '$1 == "E" { printf "%s: %s:%s: %s\n", "test-equivalence", f, $2, $3 }' \
      "$d/index" >&2
    exit 2
  fi

  : > "$d/hashes"
  set -- "$d"/seg/[0-9]*
  if [ -e "$1" ]; then
    sha256_files "$@" > "$d/hashes"
  fi

  # Every block must parse on its own. A body cut at the wrong brace, or code
  # swept into the wrong block, does not.
  while IFS=$'\t' read -r tag a id b c; do
    case "$tag" in
      T)
        { printf '__equiv_probe() {\n'; cat "$d/seg/$id"; } > "$d/probe"
        bash -n "$d/probe" 2>/dev/null ||
          die "$rel:$c: @test body does not parse on its own; refusing"
        ;;
      F)
        bash -n "$d/seg/$id" 2>/dev/null ||
          die "$rel:$b: function $a does not parse on its own; refusing"
        ;;
    esac
  done < "$d/index"
  bash -n "$d/seg/top.all" 2>/dev/null ||
    die "$rel: the top-level statements do not parse together; refusing"

  static="$(grep -c '^T' "$d/index" || true)"
  mkdir -p "$d/bats-tmp"
  count="$(TMPDIR="$d/bats-tmp" bats --count "$path" 2>"$d/bats.err")" || {
    cat "$d/bats.err" >&2
    die "bats --count failed for $rel"
  }
  [ "$count" = "$static" ] ||
    die "$rel: bats --count is $count but the parser found $static @test headers; refusing"

  printf '%s\t%s\tcount\t-\tbats --count\t%s\n' "$orig" "$rel" "$count"

  # Functions and lifecycle functions, sorted by kind then name.
  awk -F '\t' 'NR == FNR { h[$1] = $2; next }
    $1 == "F" {
      base = $2; sub(/#.*/, "", base)
      kind = (base == "setup" || base == "setup_file" || base == "teardown" || base == "teardown_file") ? "lifecycle" : "function"
      print kind "\t" $2 "\t" h[$3]
    }' "$d/hashes" "$d/index" | LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2 |
    while IFS=$'\t' read -r kind key sha; do
      printf '%s\t%s\t%s\t-\t%s\t%s\n' "$orig" "$rel" "$kind" "$key" "$sha"
    done

  # Helpers: every load (and in-directory source), followed into helpers.
  : > "$d/helpers"
  local queue="$path" visited="" cur resolved rkey rpath
  while [ -n "$queue" ]; do
    cur="${queue%%$'\n'*}"
    if [ "$cur" = "$queue" ]; then queue=""; else queue="${queue#*$'\n'}"; fi
    if [ "$cur" = "$path" ]; then
      cp "$d/index" "$d/loads"
    else
      mkdir -p "$d/hseg"
      equiv_parse "$d/hseg" "$cur" > "$d/loads"
    fi
    while IFS=$'\t' read -r tag a b; do
      case "$tag" in D | S) ;; *) continue ;; esac
      resolved="$(resolve_helper "$tree" "$testdir" "$tag" "$a")"
      [ -n "$resolved" ] || continue
      rkey="${resolved%%$'\t'*}"
      rpath="${resolved#*$'\t'}"
      case "$visited" in *$'\n'"$rkey"$'\n'*) continue ;; esac
      visited="$visited"$'\n'"$rkey"$'\n'
      if [ -n "$rpath" ]; then
        printf '%s\t%s\n' "$rkey" "$(sha256_stdin < "$rpath")" >> "$d/helpers"
        queue="${queue:+$queue$'\n'}$rpath"
      else
        printf '%s\t%s\n' "$rkey" "${rkey%%:*}" >> "$d/helpers"
      fi
    done < "$d/loads"
  done
  LC_ALL=C sort -u "$d/helpers" | while IFS=$'\t' read -r key sha; do
    printf '%s\t%s\thelper\t-\t%s\t%s\n' "$orig" "$rel" "$key" "$sha"
  done

  awk -F '\t' -v o="$orig" -v f="$rel" 'NR == FNR { h[$1] = $2; next }
    $1 == "L" { print o "\t" f "\ttoplevel\t" $2 "\t" $4 "\t" h[$3] }
    $1 == "T" { t[++n] = o "\t" f "\ttest\t" $2 "\t" $4 "\t" h[$3] }
    END { for (i = 1; i <= n; i++) print t[i] }' "$d/hashes" "$d/index"
}

MAP_ORIGS=()
MAP_PARTS=()

# read_map FILE: fills MAP_ORIGS and MAP_PARTS (space-joined parts).
read_map() {
  local file="$1" line seen="" p i
  local -a words
  [ -r "$file" ] || die "cannot read map: $file"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    read -r -a words <<< "$line" || true
    [ "${#words[@]}" -gt 0 ] || continue
    [ "${#words[@]}" -ge 3 ] && [ "${words[1]}" = "->" ] ||
      die "map line must read 'original.bats -> part.bats [part.bats ...]': $line"
    for ((i = 2; i < ${#words[@]}; i++)); do
      p="${words[$i]}"
      case "$seen" in *" $p "*) die "map names part $p more than once" ;; esac
      seen="$seen $p "
    done
    case " ${MAP_ORIGS[*]-} " in *" ${words[0]} "*) die "map names original ${words[0]} twice" ;; esac
    MAP_ORIGS+=("${words[0]}")
    MAP_PARTS+=("${words[*]:2}")
  done < "$file"
  [ "${#MAP_ORIGS[@]}" -gt 0 ] || die "map is empty: $file"
}

# map_parts ORIGINAL: the mapped parts, space-joined.
map_parts() {
  local i
  for ((i = 0; i < ${#MAP_ORIGS[@]}; i++)); do
    if [ "${MAP_ORIGS[$i]}" = "$1" ]; then
      printf '%s\n' "${MAP_PARTS[$i]}"
      return 0
    fi
  done
  die "original not in the map: $1"
}

# infer_parts TREE_DIR ORIGINAL: parts by the -partN convention, space-joined.
infer_parts() {
  local tree="$1" orig="$2" dir stem f n max=0 i parts=""
  case "$orig" in */*) dir="${orig%/*}/" ;; *) dir="" ;; esac
  stem="${orig##*/}"
  stem="${stem%.bats}"
  for f in "$tree/$dir$stem"-part*.bats; do
    [ -e "$f" ] || continue
    n="${f##*-part}"
    n="${n%.bats}"
    case "$n" in '' | *[!0-9]* | 0*) continue ;; esac
    [ "$n" -gt "$max" ] && max="$n"
  done
  if [ "$max" -eq 0 ]; then
    [ -f "$tree/$orig" ] || die "split tree has neither $orig nor $dir$stem-part1.bats"
    printf '%s\n' "$orig"
    return 0
  fi
  [ ! -e "$tree/$orig" ] || die "split tree has both $orig and its -partN files"
  for ((i = 1; i <= max; i++)); do
    [ -f "$tree/$dir$stem-part$i.bats" ] || die "$dir$stem-part$i.bats is missing (parts must run 1..$max)"
    parts="${parts:+$parts }$dir$stem-part$i.bats"
  done
  printf '%s\n' "$parts"
}

emit_header() {
  printf '# test-equivalence v1 tree=%s\n' "$1"
  printf 'original\tfile\tkind\tseq\tname\tvalue\n'
}

# emit_tree TREE_DIR MODE ORIGINAL...: MODE is self, map or infer.
emit_tree() {
  local tree="$1" mode="$2" orig parts part
  shift 2
  for orig in "$@"; do
    case "$mode" in
      self) parts="$orig" ;;
      map) parts="$(map_parts "$orig")" ;;
      infer) parts="$(infer_parts "$tree" "$orig")" ;;
    esac
    for part in $parts; do
      emit_file "$tree" "$orig" "$part"
    done
  done
}

sorted_originals() {
  printf '%s\n' "$@" | LC_ALL=C sort -u
}

cmd_emit() {
  local tree="" mode=self map="" o
  local -a files=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --tree) tree="${2:?--tree needs a value}"; shift 2 ;;
      --map) map="${2:?--map needs a value}"; mode=map; shift 2 ;;
      --infer) mode=infer; shift ;;
      -h | --help) usage; exit 0 ;;
      -*) die "unknown emit option: $1" ;;
      *) files+=("$1"); shift ;;
    esac
  done
  [ -n "$tree" ] || die "emit needs --tree"
  if [ "$mode" = map ]; then
    read_map "$map"
    [ "${#files[@]}" -gt 0 ] || files=("${MAP_ORIGS[@]}")
  fi
  [ "${#files[@]}" -gt 0 ] || die "emit needs at least one file"
  tree_prepare "$tree"
  local -a origs=()
  while IFS= read -r o; do origs+=("$o"); done < <(sorted_originals "${files[@]}")
  emit_header "$TREE_LABEL"
  emit_tree "$TREE_DIR" "$mode" "${origs[@]}"
}

# The comparison. Reads the base rows, the split rows and the review entries.
compare_rows() {
  LC_ALL=C awk -F '\t' -v OFS='\t' '
    function out(status, o, p, kind, name, detail) {
      print status, o, p, kind, name, detail
      if (status == "FAIL") fails++
    }
    function reviewed(o, p, kind, key,   k) {
      k = o SUBSEP p SUBSEP kind SUBSEP key
      if (k in rv) { rvused[k] = 1; return k }
      k = o SUBSEP "*" SUBSEP kind SUBSEP key
      if (k in rv) { rvused[k] = 1; return k }
      return ""
    }
    function item(o, p, kind, key, detail,   k) {
      k = reviewed(o, p, kind, key)
      if (k != "") out("REVIEWED", o, p, kind, key, detail "; " rv[k])
      else out("FAIL", o, p, kind, key, detail)
    }
    FILENAME == ARGV[1] && /^[^#]/ && $1 != "original" {
      o = $1
      if (!(o in bseen)) { bseen[o] = 1; borig[++nb] = o }
      if ($3 == "count") bcount[o] = $6
      else if ($3 == "test") { bt[o, ++btn[o]] = $5; bbody[o, $5] = $6; bhas[o, $5] = 1 }
      else if ($3 == "toplevel") { btop[o, ++btopn[o]] = $6; btext[o, $6] = $5 }
      else { bitem[o, ++bitn[o]] = $3 SUBSEP $5; bval[o, $3, $5] = $6 }
      next
    }
    FILENAME == ARGV[2] && /^[^#]/ && $1 != "original" {
      o = $1; p = $2
      if (!((o, p) in sseen)) { sseen[o, p] = 1; spart[o, ++spn[o]] = p; if (!(o in sorig)) sorig[o] = 1 }
      if ($3 == "count") scount[p] = $6
      else if ($3 == "test") { st[p, ++stn[p]] = $5; sbody[p, ++sbn[p]] = $6 }
      else if ($3 == "toplevel") { stop[p, ++stopn[p]] = $6; stext[p, $6] = $5 }
      else { sitem[p, ++sitn[p]] = $3 SUBSEP $5; sval[p, $3, $5] = $6 }
      next
    }
    FILENAME == ARGV[3] && /^[^#]/ && NF > 0 {
      if (NF != 7) { bad = bad "\n  review line " FNR ": needs 7 TAB-separated fields, has " NF; next }
      for (i = 1; i <= 7; i++) if ($i == "") { bad = bad "\n  review line " FNR ": field " i " is empty"; next }
      if ($3 !~ /^(lifecycle|function|helper|toplevel)$/) {
        bad = bad "\n  review line " FNR ": kind " $3 " cannot be reviewed (test bodies must be byte-identical, R1.1)"
        next
      }
      k = $1 SUBSEP $2 SUBSEP $3 SUBSEP $4
      rv[k] = $5 " review: " $6 " / " $7; rvline[k] = FNR
      if ($3 == "toplevel") waive[$1, $2, $4] = 1
      next
    }
    END {
      if (bad != "") { print "test-equivalence: malformed review file:" bad > "/dev/stderr"; exit 2 }
      for (i = 1; i <= nb; i++) {
        o = borig[i]; f0 = fails
        if (!(o in sorig)) { out("FAIL", o, "-", "part", "-", "no parts in the split tree"); continue }

        # Identity and order over the concatenated parts.
        n = 0; total = 0; delete where
        for (j = 1; j <= spn[o]; j++) {
          p = spart[o, j]; total += scount[p]
          for (k = 1; k <= stn[p]; k++) {
            name = st[p, k]
            if (name in where) {
              if (where[name] == p) out("FAIL", o, p, "test", name, "name appears twice in this part")
              else out("FAIL", o, p, "test", name, "name also appears in " where[name] " (a name may live in one part only)")
              continue
            }
            where[name] = p; cat[++n] = name
            if (!((o, name) in bhas)) out("FAIL", o, p, "test", name, "not in the original (added or renamed)")
            else if (sbody[p, k] != bbody[o, name]) out("FAIL", o, p, "test", name, "body differs from the original")
          }
        }
        for (k = 1; k <= btn[o]; k++) {
          name = bt[o, k]
          if (!(name in where)) out("FAIL", o, "-", "test", name, "dropped: in the original, in no part")
        }
        # Order: the common names must appear in the original order.
        m = 0
        for (k = 1; k <= n; k++) if ((o, cat[k]) in bhas) sub_s[++m] = cat[k]
        m2 = 0
        for (k = 1; k <= btn[o]; k++) if (bt[o, k] in where) sub_b[++m2] = bt[o, k]
        for (k = 1; k <= m && k <= m2; k++) {
          if (sub_s[k] != sub_b[k]) {
            out("FAIL", o, where[sub_s[k]], "order", sub_s[k], "position " k " of the concatenated parts; the original has " sub_b[k] " there")
            break
          }
        }
        if (total != bcount[o]) out("FAIL", o, "-", "count", "bats --count", "parts sum to " total ", original has " bcount[o])

        # File-level items, per part.
        for (j = 1; j <= spn[o]; j++) {
          p = spart[o, j]
          delete inbase
          for (k = 1; k <= bitn[o]; k++) {
            split(bitem[o, k], kv, SUBSEP); inbase[kv[1], kv[2]] = 1
            if (!((p, kv[1], kv[2]) in sval)) item(o, p, kv[1], kv[2], "missing from this part")
            else if (sval[p, kv[1], kv[2]] != bval[o, kv[1], kv[2]]) item(o, p, kv[1], kv[2], "differs from the original")
          }
          for (k = 1; k <= sitn[p]; k++) {
            split(sitem[p, k], kv, SUBSEP)
            if (!((kv[1], kv[2]) in inbase)) item(o, p, kv[1], kv[2], "not in the original")
          }
          # Top-level statements: the same sequence, less reviewed lines. A
          # reviewed line counts as used only where one side lacks it.
          a = 0; b = 0; delete la; delete lb; delete hasb; delete hass
          for (k = 1; k <= btopn[o]; k++) hasb[btop[o, k]] = 1
          for (k = 1; k <= stopn[p]; k++) hass[stop[p, k]] = 1
          for (k = 1; k <= btopn[o]; k++) {
            h = btop[o, k]
            if (((o, p, h) in waive) || ((o, "*", h) in waive)) {
              if (!(h in hass)) item(o, p, "toplevel", h, "reviewed removal of: " btext[o, h])
              continue
            }
            la[++a] = h
          }
          for (k = 1; k <= stopn[p]; k++) {
            h = stop[p, k]
            if (((o, p, h) in waive) || ((o, "*", h) in waive)) {
              if (!(h in hasb)) item(o, p, "toplevel", h, "reviewed addition of: " stext[p, h])
              continue
            }
            lb[++b] = h
          }
          for (k = 1; k <= a || k <= b; k++) {
            if (la[k] != lb[k]) {
              if (k > b) out("FAIL", o, p, "toplevel", btext[o, la[k]], "statement " k " is missing from this part")
              else if (k > a) out("FAIL", o, p, "toplevel", stext[p, lb[k]], "statement " k " is not in the original")
              else out("FAIL", o, p, "toplevel", stext[p, lb[k]], "statement " k " differs; the original has: " btext[o, la[k]])
              break
            }
          }
        }
        out(fails > f0 ? "NOT-OK" : "OK", o, "-", "summary", "-", btn[o] " tests, " spn[o] " part(s), bats --count " bcount[o])
      }
      for (k in rv) {
        if (!(k in rvused)) {
          split(k, kv, SUBSEP)
          out("FAIL", kv[1], kv[2], kv[3], kv[4], "review entry (line " rvline[k] ") matches no difference")
        }
      }
      exit (fails > 0 ? 1 : 0)
    }
  ' "$1" "$2" "$3"
}

cmd_diff() {
  local base="" split="" map="" review="" emit_dir="" mode=infer o rc
  local -a files=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --base) base="${2:?--base needs a value}"; shift 2 ;;
      --split) split="${2:?--split needs a value}"; shift 2 ;;
      --map) map="${2:?--map needs a value}"; mode=map; shift 2 ;;
      --review) review="${2:?--review needs a value}"; shift 2 ;;
      --emit-dir) emit_dir="${2:?--emit-dir needs a value}"; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      -*) die "unknown diff option: $1" ;;
      *) files+=("$1"); shift ;;
    esac
  done
  [ -n "$base" ] && [ -n "$split" ] || die "diff needs --base and --split"
  if [ "$mode" = map ]; then
    read_map "$map"
    [ "${#files[@]}" -gt 0 ] || files=("${MAP_ORIGS[@]}")
  fi
  [ "${#files[@]}" -gt 0 ] || die "diff needs originals, or a --map"
  if [ -n "$review" ]; then
    [ -r "$review" ] || die "cannot read review file: $review"
  fi
  local -a origs=()
  while IFS= read -r o; do origs+=("$o"); done < <(sorted_originals "${files[@]}")

  local base_label split_label
  tree_prepare "$base"
  base_label="$TREE_LABEL"
  { emit_header "$base_label"; emit_tree "$TREE_DIR" self "${origs[@]}"; } > "$WORK/base.tsv"
  tree_prepare "$split"
  split_label="$TREE_LABEL"
  { emit_header "$split_label"; emit_tree "$TREE_DIR" "$mode" "${origs[@]}"; } > "$WORK/split.tsv"
  if [ -n "$emit_dir" ]; then
    mkdir -p "$emit_dir"
    cp "$WORK/base.tsv" "$emit_dir/base.tsv"
    cp "$WORK/split.tsv" "$emit_dir/split.tsv"
  fi

  rc=0
  compare_rows "$WORK/base.tsv" "$WORK/split.tsv" "${review:-/dev/null}" > "$WORK/report" || rc=$?
  {
    printf '# test-equivalence diff base=%s split=%s\n' "$base_label" "$split_label"
    printf 'status\toriginal\tpart\tkind\tname\tdetail\n'
    # Unordered review leftovers come last; sort them so the report is stable.
    awk -F '\t' '!/matches no difference$/' "$WORK/report"
    awk -F '\t' '/matches no difference$/' "$WORK/report" | LC_ALL=C sort
  } > "$WORK/report.tsv"
  cat "$WORK/report.tsv"
  [ -z "$emit_dir" ] || cp "$WORK/report.tsv" "$emit_dir/report.tsv"
  case "$rc" in
    0) ;;
    1) printf '%s: %s difference(s)\n' "$PROG" "$(grep -c '^FAIL' "$WORK/report")" >&2 ;;
    *) exit 2 ;;
  esac
  return "$rc"
}

main() {
  local cmd="${1:-}"
  [ -n "$cmd" ] || { usage >&2; exit 2; }
  shift
  command -v bats >/dev/null 2>&1 || die "bats is not on PATH"
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-equivalence.XXXXXX")"
  case "$cmd" in
    emit) cmd_emit "$@" ;;
    diff) cmd_diff "$@" ;;
    -h | --help) usage ;;
    *) die "unknown command: $cmd (emit or diff)" ;;
  esac
}

main "$@"
