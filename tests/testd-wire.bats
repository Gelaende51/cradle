setup() {
  load test_helper; setup_isolated_path
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config"
  P="$BATS_TEST_TMPDIR/proj"; mkdir -p "$P"; git -C "$P" init -q; cd "$P"
  stub systemctl; stub podman
}

@test "init writes the CI template, .actrc and a matching testJobs entry" {
  run "$CRADLE_ROOT/bin/cradle" init
  [ "$status" -eq 0 ]
  [ -f .github/workflows/ci.yml ]; [ -f .actrc ]
  [ "$(jq -c '.testJobs' .devcontainer/cradle.json)" = '[{"workflow":"ci.yml","job":"test","network":false}]' ]
}

@test "init keeps an existing workflow and lists no job for it" {
  mkdir -p .github/workflows; echo 'on: push' > .github/workflows/ci.yml
  "$CRADLE_ROOT/bin/cradle" init
  [ "$(cat .github/workflows/ci.yml)" = 'on: push' ]
  [ "$(jq -c '.testJobs' .devcontainer/cradle.json)" = '[]' ]
}

@test "init installs the units and enables this project's path unit" {
  "$CRADLE_ROOT/bin/cradle" init
  k=$(. "$CRADLE_ROOT/lib/common.sh"; . "$CRADLE_ROOT/lib/render.sh"; project_key "$P")
  grep -q "ExecStart=$CRADLE_ROOT/bin/cradle-testd %i" "$XDG_CONFIG_HOME/systemd/user/cradle-testd@.service"
  grep -q "DirectoryNotEmpty=%h/.local/state/cradle/testd/%i/req/new" "$XDG_CONFIG_HOME/systemd/user/cradle-testd@.path"
  grep -q "systemctl --user enable --now cradle-testd@$k.path" "$STUB_LOG"
}

@test "init --detach disables the unit and removes network and proxy" {
  "$CRADLE_ROOT/bin/cradle" init; : > "$STUB_LOG"
  run "$CRADLE_ROOT/bin/cradle" init --detach
  [ "$status" -eq 0 ]
  grep -q "systemctl --user disable --now cradle-testd@" "$STUB_LOG"
  grep -q "podman rm -f cradle-proxy-" "$STUB_LOG"
  grep -q "podman network rm -f cradle-proj-" "$STUB_LOG"
}

@test "the container gets the request maildir, read-only results and cradle-request" {
  "$CRADLE_ROOT/bin/cradle" init
  . "$CRADLE_ROOT/lib/common.sh"; . "$CRADLE_ROOT/lib/render.sh"
  render_devcontainer "$P"; d=$(testd_dir "$(project_key "$P")")
  j() { tail -n +2 .devcontainer/devcontainer.json; }
  j | jq -e --arg a "--volume=$d/req:/home/dev/.cradle/requests" '.runArgs | index($a)'
  j | jq -e --arg a "--volume=$d/results:/home/dev/.cradle/results:ro" '.runArgs | index($a)'
  j | jq -e --arg a "--volume=$CRADLE_ROOT/bin/cradle-request:/usr/local/bin/cradle-request:ro" '.runArgs | index($a)'
  [ "$(j | jq -r .containerEnv.CRADLE_RESULTS)" = /home/dev/.cradle/results ]
}

@test "cradle test queues through the same script and reports the result" {
  "$CRADLE_ROOT/bin/cradle" init
  git -c user.name=t -c user.email=t@x commit -q --allow-empty -m x
  . "$CRADLE_ROOT/lib/common.sh"; . "$CRADLE_ROOT/lib/render.sh"; d=$(testd_dir "$(project_key "$P")")
  # answer the request once it is queued (a slow machine may take longer than a second)
  ( for ((i = 0; i < 150; i++)); do f=$(ls "$d/req/new"); [[ -n $f ]] && break; sleep 0.2; done
    id=${f%.json}; mkdir -p "$d/results/$id"
    echo '{"status":"passed","reason":"job test passed"}' > "$d/results/$id/status.json" ) &
  CRADLE_REQUEST_WAIT=30 run "$CRADLE_ROOT/bin/cradle" test test
  [ "$status" -eq 0 ]; [[ "$output" == *"passed: job test passed"* ]]
}

@test "the path unit watches req/new for any entry" {
  grep -qx 'DirectoryNotEmpty=%h/.local/state/cradle/testd/%i/req/new' "$CRADLE_ROOT/testd/cradle-testd@.path"
}

@test "the runner's start limit lets a burst of requests through but stops a crash loop" {
  grep -qx 'StartLimitIntervalSec=60' "$CRADLE_ROOT/testd/cradle-testd@.service"
  grep -qx 'StartLimitBurst=30' "$CRADLE_ROOT/testd/cradle-testd@.service"
}

@test "request ids are not predictable" {
  "$CRADLE_ROOT/bin/cradle" init
  git -c user.name=t -c user.email=t@x commit -q --allow-empty -m x
  . "$CRADLE_ROOT/lib/common.sh"; . "$CRADLE_ROOT/lib/render.sh"; d=$(testd_dir "$(project_key "$P")")
  CRADLE_REQUEST_WAIT=0 run "$CRADLE_ROOT/bin/cradle" test test
  [ "$status" -eq 3 ]
  [[ "$(ls "$d/req/new")" =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{16}\.json$ ]]
}
