setup() {
  load test_helper; setup_isolated_path
  P="$BATS_TEST_TMPDIR/my proj"; mkdir -p "$P"; git -C "$P" init -q; cd "$P"
  stub systemctl; "$CRADLE_ROOT/bin/cradle" init >/dev/null; : > "$STUB_LOG"
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
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

@test "claude runs through podman exec with the token only in the environment" {
  git remote add origin https://github.com/Gelaende51/cradle.git
  stub secret-tool 0 ghp_secret
  stub_script podman '[[ $1 == ps ]] && echo abc123; [[ $1 == exec ]] && echo "EXEC_TOKEN=${GH_TOKEN-unset}" >> "$STUB_LOG"; exit 0'
  run cradle claude --resume
  [ "$status" -eq 0 ]
  grep -q "^podman exec -i -e GH_TOKEN -u dev -w /home/dev/src/my-proj abc123 claude --resume$" "$STUB_LOG"
  grep -q "EXEC_TOKEN=ghp_secret" "$STUB_LOG"
  run ! grep -q "^podman .*ghp_secret" "$STUB_LOG"
  run ! grep -q "devcontainer exec" "$STUB_LOG"
}

@test "declared secrets reach the session by name, from the repo's keyring only" {
  git remote add origin https://github.com/Gelaende51/cradle.git
  jq '.secrets = ["CLOUDFLARE_API_TOKEN"]' .devcontainer/cradle.json > c.json && mv c.json .devcontainer/cradle.json
  stub_script secret-tool '[[ "$*" == *cradle-secret* ]] && { printf cf_secret; exit 0; }; printf ghp_secret'
  stub_script podman '[[ $1 == ps ]] && echo abc123; [[ $1 == exec ]] && echo "EXEC_CF=${CLOUDFLARE_API_TOKEN-unset}" >> "$STUB_LOG"; exit 0'
  CLOUDFLARE_API_TOKEN=host_value run cradle claude
  [ "$status" -eq 0 ]
  grep -q "^podman exec -i -e GH_TOKEN -e CLOUDFLARE_API_TOKEN -u dev -w /home/dev/src/my-proj abc123 claude$" "$STUB_LOG"
  grep -q "EXEC_CF=cf_secret" "$STUB_LOG"
  run ! grep -q "^podman .*cf_secret" "$STUB_LOG"
}

@test "a declared secret without a stored value is not taken from the host" {
  git remote add origin https://github.com/Gelaende51/cradle.git
  jq '.secrets = ["CLOUDFLARE_API_TOKEN"]' .devcontainer/cradle.json > c.json && mv c.json .devcontainer/cradle.json
  stub secret-tool 1
  stub_script podman '[[ $1 == ps ]] && echo abc123; [[ $1 == exec ]] && echo "EXEC_CF=${CLOUDFLARE_API_TOKEN-unset}" >> "$STUB_LOG"; exit 0'
  CLOUDFLARE_API_TOKEN=host_value run cradle claude
  [ "$status" -eq 0 ]
  grep -q "EXEC_CF=unset" "$STUB_LOG"
}

@test "a host GH_TOKEN never reaches the container" {
  GH_TOKEN=host_tok GITHUB_TOKEN=host_tok2 run cradle up
  [ "$status" -eq 0 ]
  grep -q "GH_TOKEN=unset" "$STUB_LOG"
}

@test "up syncs the config volume when it is stale" {
  stub_script podman '[[ $* == *"volume-sync.sh check"* ]] && exit 1; exit 0'
  run cradle up
  [ "$status" -eq 0 ]
  grep -q "volume-sync.sh sync" "$STUB_LOG"
}

@test "up recreates the container when the configuration changed" {
  stub_script podman '[[ $1 == ps ]] && echo abc123; [[ $1 == inspect ]] && echo stale-id; exit 0'
  run cradle up
  [ "$status" -eq 0 ]
  grep -q "^devcontainer up .* --remove-existing-container" "$STUB_LOG"
}

@test "up keeps a container whose configuration is current" {
  cradle up
  id=$(tail -n +2 .devcontainer/devcontainer.json | jq -r '.runArgs[] | select(startswith("--label=cradle.render=")) | ltrimstr("--label=cradle.render=")')
  stub_script podman "[[ \$1 == ps ]] && echo abc123; [[ \$1 == inspect ]] && echo $id; exit 0"
  : > "$STUB_LOG"
  run cradle up
  [ "$status" -eq 0 ]
  run ! grep -q "remove-existing-container" "$STUB_LOG"
}

@test "push runs host git with hooks and fsmonitor switched off" {
  stub_script git 'for a; do [[ $a == push ]] && exit 0; done; exec '"$(command -v git)"' "$@"'
  run cradle push --yes origin main
  [ "$status" -eq 0 ]
  grep -q "^git -c core.hooksPath=/dev/null -c core.fsmonitor=false push origin main$" "$STUB_LOG"
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

@test "up starts the proxy before the dev container" {
  run cradle up
  [ "$status" -eq 0 ]
  p=$(grep -n "podman run -d --name cradle-proxy-" "$STUB_LOG" | cut -d: -f1)
  d=$(grep -n "^devcontainer up" "$STUB_LOG" | cut -d: -f1)
  [ -n "$p" ] && [ "$p" -lt "$d" ]
}

@test "down also removes the proxy" {
  stub_script podman '[[ $1 == ps ]] && echo abc123; exit 0'
  run cradle down
  grep -q "podman rm -f cradle-proxy-" "$STUB_LOG"
}
