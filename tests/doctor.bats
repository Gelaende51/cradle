setup() {
  load test_helper; setup_isolated_path
  cd "$BATS_TEST_TMPDIR"   # outside any git repo, so the token check (Task 9) stays quiet
  export CRADLE_ETC="$BATS_TEST_TMPDIR/etc" CRADLE_PROC="$BATS_TEST_TMPDIR/proc" CRADLE_CGROUP="$BATS_TEST_TMPDIR/cg"
  mkdir -p "$CRADLE_ETC" "$CRADLE_PROC"
  u=$(id -un); uid=$(id -u)
  echo "$u:100000:65536" > "$CRADLE_ETC/subuid"; echo "$u:100000:65536" > "$CRADLE_ETC/subgid"
  echo "MemAvailable:    6000000 kB" > "$CRADLE_PROC/meminfo"
  mkdir -p "$CRADLE_CGROUP/user.slice/user-$uid.slice/user@$uid.service"
  echo "cpu memory pids" > "$CRADLE_CGROUP/user.slice/user-$uid.slice/user@$uid.service/cgroup.controllers"
  stub_script podman 'case "$1" in info) echo true ;; image) exit 0 ;; esac'
  stub devcontainer 0 "0.89.0"
  stub gh; stub secret-tool; stub act
  stub df 0 $'Avail\n20000000'
}

@test "all checks pass on a healthy host" {
  run cradle doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *fail* ]]
}

@test "missing subuid range fails with the usermod command" {
  : > "$CRADLE_ETC/subuid"
  run cradle doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"fail"*"subuid"*"usermod --add-subuids"* ]]
}

@test "missing act only warns" {
  rm "$STUB_BIN/act"
  run cradle doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"warn"*"act"* ]]
}

@test "low disk space warns" {
  stub df 0 $'Avail\n1000000'
  run cradle doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"warn"*"disk"* ]]
}

@test "devcontainer version mismatch warns" {
  stub devcontainer 0 "0.70.0"
  run cradle doctor
  [[ "$output" == *"warn"*"devcontainer-version"* ]]
}

@test "missing memory delegation warns" {
  echo "cpu pids" > "$CRADLE_CGROUP/user.slice/user-$uid.slice/user@$uid.service/cgroup.controllers"
  run cradle doctor
  [[ "$output" == *"warn"*"cgroup-memory"* ]]
}

@test "stale config volume warns" {
  # the check container (lib/volume-sync.sh check) reports a difference
  stub_script podman 'case "$1 $2" in "info "*) echo true ;; "run "*) exit 1 ;; esac; exit 0'
  run cradle doctor
  [[ "$output" == *"warn"*"config"*"cradle config sync"* ]]
}

@test "a GitHub repo without a stored token warns" {
  git init -q repo && cd repo && git remote add origin https://github.com/Gelaende51/cradle.git
  stub secret-tool 1
  run cradle doctor
  [[ "$output" == *"warn"*"token"*"cradle token set"* ]]
}

@test "a token that expires soon warns" {
  git init -q repo && cd repo && git remote add origin https://github.com/Gelaende51/cradle.git
  stub secret-tool 0 ghp_x
  soon=$(date -u -d '+3 days' '+%Y-%m-%d %H:%M:%S UTC')
  stub curl 0 $'HTTP/2 200\r\ngithub-authentication-token-expiration: '"$soon"$'\r\n'
  run cradle doctor
  [[ "$output" == *"warn"*"token"*"renew it"* ]]
}

@test "a missing proxy image warns" {
  stub_script podman 'case "$1 $2" in "info "*) echo true ;; "image exists") [[ $3 == cradle-proxy:* ]] && exit 1 ;; esac; exit 0'
  run cradle doctor
  [[ "$output" == *"warn"*"cradle-proxy"*"cradle image build"* ]]
}
