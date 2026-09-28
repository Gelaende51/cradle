setup() {
  load test_helper; setup_isolated_path
  P="$BATS_TEST_TMPDIR/my proj"; mkdir -p "$P"; git -C "$P" init -q; cd "$P"
  "$CRADLE_ROOT/bin/cradle" init >/dev/null
  stub podman
  stub_script devcontainer 'echo "GH_TOKEN=${GH_TOKEN-unset}" >> "$STUB_LOG"'
}

@test "up renders devcontainer.json and runs devcontainer up on podman" {
  stub secret-tool 1
  run cradle up
  [ "$status" -eq 0 ]
  [ -f .devcontainer/devcontainer.json ]
  grep -q "devcontainer up --docker-path podman --workspace-folder $P" "$STUB_LOG"
}

@test "up without a GitHub origin runs without a token" {
  run cradle up
  [ "$status" -eq 0 ]
  grep -q "GH_TOKEN=unset" "$STUB_LOG"
}

@test "up passes the stored token through the environment, never as an argument" {
  git remote add origin https://github.com/Gelaende51/cradle.git
  stub secret-tool 0 ghp_secret
  run cradle up
  grep -q "GH_TOKEN=ghp_secret" "$STUB_LOG"
  run ! grep -q "devcontainer .*ghp_secret" "$STUB_LOG"
}

@test "claude execs claude with its arguments inside the container" {
  run cradle claude --resume
  grep -q "devcontainer exec --docker-path podman --workspace-folder $P claude --resume" "$STUB_LOG"
}

@test "down stops the container labelled with this folder" {
  stub_script podman '[[ $1 == ps ]] && echo abc123; exit 0'
  run cradle down
  [ "$status" -eq 0 ]
  grep -q "podman ps -q --filter label=devcontainer.local_folder=$P" "$STUB_LOG"
  grep -q "podman stop abc123" "$STUB_LOG"
}

@test "push needs confirmation" {
  stub_script git 'exec '"$(command -v git)"' "$@"'
  run bash -c 'echo n | "$CRADLE_ROOT/bin/cradle" push'
  [ "$status" -eq 1 ]
  [[ "$output" == *"push cancelled"* ]]
  run ! grep -q "^git push" "$STUB_LOG"
}

@test "devcontainer runs with podman's file events backend" {
  stub_script devcontainer 'echo "EVENTS_CONF=${CONTAINERS_CONF_OVERRIDE-unset}" >> "$STUB_LOG"'
  run cradle up
  [ "$status" -eq 0 ]
  grep -q "EVENTS_CONF=$CRADLE_ROOT/lib/podman-events.conf" "$STUB_LOG"
  grep -q 'events_logger = "file"' "$CRADLE_ROOT/lib/podman-events.conf"
}
