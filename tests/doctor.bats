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
  export CRADLE_CONFIG_DIR="$BATS_TEST_TMPDIR/kitcfg"; mkdir -p "$CRADLE_CONFIG_DIR"
  echo new > "$CRADLE_CONFIG_DIR/CLAUDE.md"
  mkdir -p "$BATS_TEST_TMPDIR/vol"; echo old > "$BATS_TEST_TMPDIR/vol/CLAUDE.md"
  stub_script podman 'case "$1 $2" in "info "*) echo true ;; "volume inspect") echo '"$BATS_TEST_TMPDIR/vol"' ;; esac; exit 0'
  run cradle doctor
  [[ "$output" == *"warn"*"config"*"cradle config sync"* ]]
}
