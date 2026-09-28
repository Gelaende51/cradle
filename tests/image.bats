setup() { load test_helper; setup_isolated_path; }

@test "builds both images with every pinned version and retags on success" {
  stub podman
  run cradle image build
  [ "$status" -eq 0 ]
  grep -q "podman build .*--build-arg CLAUDE_CODE_VERSION=2.1.283 .*-f $CRADLE_ROOT/image/Containerfile" "$STUB_LOG"
  grep -q "podman build .*--build-arg PROXY_BASE=.*-f $CRADLE_ROOT/proxy/Containerfile" "$STUB_LOG"
  grep -q "podman tag cradle-base:building-[0-9]* cradle-base:$(cat "$CRADLE_ROOT/VERSION")" "$STUB_LOG"
  grep -q "podman tag cradle-proxy:building-[0-9]* cradle-proxy:$(cat "$CRADLE_ROOT/VERSION")" "$STUB_LOG"
}

@test "a failed proxy build leaves the proxy tag alone" {
  stub_script podman '[[ $1 == build && $* == *proxy/Containerfile* ]] && exit 1; exit 0'
  run cradle image build
  [ "$status" -eq 1 ]
  [[ "$output" == *"cradle-proxy"*"left unchanged"* ]]
  run ! grep -q "podman tag cradle-proxy" "$STUB_LOG"
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
