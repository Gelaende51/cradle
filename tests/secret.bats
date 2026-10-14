setup() {
  load test_helper; setup_isolated_path
  P="$BATS_TEST_TMPDIR/proj"; mkdir -p "$P"; git -C "$P" init -q; cd "$P"
  git remote add origin https://github.com/Gelaende51/handdown.git
  stub systemctl; "$CRADLE_ROOT/bin/cradle" init >/dev/null; : > "$STUB_LOG"
}

declare_secrets() {
  jq --argjson s "$1" '.secrets = $s' .devcontainer/cradle.json > c.json && mv c.json .devcontainer/cradle.json
}

@test "set stores the value read from stdin under the repo and the name" {
  declare_secrets '["CLOUDFLARE_API_TOKEN"]'
  stub secret-tool
  run bash -c 'echo cf_x | "$CRADLE_ROOT/bin/cradle" secret set CLOUDFLARE_API_TOKEN'
  [ "$status" -eq 0 ]
  grep -q "secret-tool store --label=cradle secret CLOUDFLARE_API_TOKEN Gelaende51/handdown service cradle-secret repo Gelaende51/handdown name CLOUDFLARE_API_TOKEN" "$STUB_LOG"
  run ! grep -q "cf_x" "$STUB_LOG"
  [[ "$output" != *"is not in"* ]]
}

@test "set warns when cradle.json does not declare the name" {
  stub secret-tool
  run bash -c 'echo v | "$CRADLE_ROOT/bin/cradle" secret set OTHER_TOKEN'
  [ "$status" -eq 0 ]
  [[ "$output" == *"OTHER_TOKEN is not in"* ]]
}

@test "names that are not variables, and the GitHub token, are refused" {
  stub secret-tool
  for n in GH_TOKEN GITHUB_TOKEN lower 'A B' ''; do
    run cradle secret set "$n"
    [ "$status" -ne 0 ]
  done
  run ! grep -q "secret-tool store" "$STUB_LOG"
}

@test "list says which declared secrets are stored" {
  declare_secrets '["CLOUDFLARE_API_TOKEN","OTHER_KEY"]'
  stub_script secret-tool '[[ "$*" == *CLOUDFLARE_API_TOKEN* ]] && { printf v; exit 0; }; exit 1'
  run cradle secret list
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLOUDFLARE_API_TOKEN: stored"* ]]
  [[ "$output" == *"OTHER_KEY: missing"* ]]
}

@test "unset clears only that name" {
  stub secret-tool
  run cradle secret unset CLOUDFLARE_API_TOKEN
  [ "$status" -eq 0 ]
  grep -q "secret-tool clear service cradle-secret repo Gelaende51/handdown name CLOUDFLARE_API_TOKEN" "$STUB_LOG"
}
