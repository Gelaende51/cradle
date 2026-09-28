setup() { load test_helper; setup_isolated_path; }

@test "builds with every pinned version as a build arg and retags on success" {
  stub podman
  run cradle image build
  [ "$status" -eq 0 ]
  grep -q "podman build .*--build-arg CLAUDE_CODE_VERSION=2.1.283" "$STUB_LOG"
  grep -q "podman build .*--build-arg GH_SHA256=" "$STUB_LOG"
  grep -q "podman tag cradle-base:building-[0-9]* cradle-base:$(cat "$CRADLE_ROOT/VERSION")" "$STUB_LOG"
}

@test "a failed build leaves the old tag alone" {
  stub_script podman '[[ $1 == build ]] && exit 1; exit 0'
  run cradle image build
  [ "$status" -eq 1 ]
  [[ "$output" == *"left unchanged"* ]]
  run ! grep -q "podman tag" "$STUB_LOG"
}

@test "unknown subcommand prints usage" {
  stub podman
  run cradle image frob
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage: cradle image build"* ]]
}
