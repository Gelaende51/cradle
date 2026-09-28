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
  for c in doctor setup image config init token up down claude shell push net test approve-workflows; do
    [[ "$output" == *"$c"* ]]
  done
}

@test "cradle's CI test job passes cradle's own tier-2 job check" {
  . "$CRADLE_ROOT/lib/common.sh"
  run python3 -c 'import json, sys, yaml; d = yaml.safe_load(open(sys.argv[1]))["jobs"]["test"]; sys.exit(0 if d["runs-on"] == "ubuntu-latest" and "container" not in d and "services" not in d else 1)' "$CRADLE_ROOT/.github/workflows/ci.yml"
  [ "$status" -eq 0 ]
}
