setup() {
  load test_helper; setup_isolated_path
  P="$BATS_TEST_TMPDIR/proj"; mkdir -p "$P"; git -C "$P" init -q
  cd "$P"
  stub systemctl; stub podman
}

@test "detects node and go and writes cradle.json" {
  echo '{}' > package.json; echo 'module x' > go.mod
  run cradle init
  [ "$status" -eq 0 ]
  [ "$(jq -c .languages .devcontainer/cradle.json)" = '["node","go"]' ]
  [ "$(jq -c .maskPaths .devcontainer/cradle.json)" = '[".personal"]' ]
}

@test "the gitignore block is added once, even without a trailing newline" {
  printf 'node_modules' > .gitignore
  cradle init; cradle init --force
  [ "$(grep -c '^# >>> cradle$' .gitignore)" -eq 1 ]
  grep -qx 'node_modules' .gitignore
  grep -qx '.cradle/' .gitignore
}

@test "an existing cradle.json is kept without --force" {
  cradle init
  echo '{"languages":["rust"]}' > .devcontainer/cradle.json
  run cradle init
  [ "$status" -eq 1 ]
  [ "$(jq -c .languages .devcontainer/cradle.json)" = '["rust"]' ]
}

@test "refuses outside a git repository" {
  cd "$BATS_TEST_TMPDIR"; mkdir plain; cd plain
  run cradle init
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a git repository"* ]]
}
