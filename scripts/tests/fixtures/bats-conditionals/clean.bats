@test "clean" {
  [[ "$output" == *x* ]] || false
  [[ "$output" == *"a ]] b"* ]] || { echo "$output"; false; }
  if [[ -f x ]]; then
    :
  fi
  true &&
    [[ -z "" ]]
  [[ a == a && "]]" == "]]" ]] && echo both
  run bash -c '
[[ -n "inside a quoted script" ]]
echo done'
  cat > "$BATS_TEST_TMPDIR/s.sh" <<'SH'
[[ -n "inside a heredoc" ]]
SH
  [ -n x ]
}
[[ -n "top level, outside any test" ]]
