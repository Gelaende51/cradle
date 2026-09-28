setup() {
  load test_helper; setup_isolated_path
  export CRADLE_ETC="$BATS_TEST_TMPDIR/etc"; mkdir -p "$CRADLE_ETC"
  u=$(id -un)
  echo "$u:100000:65536" > "$CRADLE_ETC/subuid"; echo "$u:100000:65536" > "$CRADLE_ETC/subgid"
  stub podman; stub npm; stub bats; stub shellcheck; stub act
  stub_script systemctl 'exit 0'
}

@test "installs the devcontainer CLI into ~/.local with --yes" {
  run cradle setup --yes
  [ "$status" -eq 0 ]
  grep -q "npm install -g --prefix $HOME/.local @devcontainers/cli@0.89.0" "$STUB_LOG"
}

@test "without --yes it only prints the command" {
  run cradle setup
  [ "$status" -eq 0 ]
  [[ "$output" == *"npm install -g --prefix"* ]]
  run ! grep -q "^npm install" "$STUB_LOG"
}

@test "prints but never runs sudo commands" {
  : > "$CRADLE_ETC/subuid"; rm "$STUB_BIN/act"
  run cradle setup --yes
  [[ "$output" == *"sudo usermod --add-subuids"* ]]
  [[ "$output" == *"sudo pacman -S --needed"*"act"* ]]
  run ! grep -q "^sudo" "$STUB_LOG"
}

@test "enables the podman socket when it is inactive" {
  stub_script systemctl '[[ "$*" == *is-active* ]] && exit 3; exit 0'
  run cradle setup --yes
  grep -q "systemctl --user enable --now podman.socket" "$STUB_LOG"
}

@test "a missing PyYAML is listed for pacman" {
  stub python3 1
  run cradle setup --yes
  [[ "$output" == *"sudo pacman -S --needed"*"python-yaml"* ]]
}
