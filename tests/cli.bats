setup() { load test_helper; setup_isolated_path; }

@test "version prints the VERSION file" {
  run cradle version
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$CRADLE_ROOT/VERSION")" ]
}

@test "unknown command exits 2 and prints usage" {
  run cradle frobnicate
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: cradle"* ]]
}

@test "help lists every command" {
  run cradle help
  [ "$status" -eq 0 ]
  for c in doctor setup image config init token up down claude shell push; do
    [[ "$output" == *"$c"* ]]
  done
}
