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

@test "tests never run the git hooks of the machine they run on" {
  git init -q "$BATS_TEST_TMPDIR/r"
  [ "$(git -C "$BATS_TEST_TMPDIR/r" config core.hooksPath)" = /dev/null ]
}

@test "the READMEs link each other and every docs page exists" {
  for f in README.md docs/i18n/README.de.md docs/architecture.md docs/security.md docs/attaching.md docs/troubleshooting.md; do
    [ -s "$CRADLE_ROOT/$f" ]
  done
  grep -q 'docs/i18n/README.de.md' "$CRADLE_ROOT/README.md"
  grep -q '../../README.md' "$CRADLE_ROOT/docs/i18n/README.de.md"
  grep -q '^- \*\*Usage\*\* — ' "$CRADLE_ROOT/README.md"
  run grep -rn '/home/niemand' "$CRADLE_ROOT/README.md" "$CRADLE_ROOT/docs"
  [ "$status" -eq 1 ]
}
