@test "bare" {
  run true
  [[ "$output" == *x* ]]
  [ "$status" -eq 0 ]
}
helper() {
  [[ -n "$1" ]]   # trailing comment
  echo ok
}
