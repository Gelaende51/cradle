setup() {
  load test_helper; setup_isolated_path
  VOL="$BATS_TEST_TMPDIR/vol"; mkdir -p "$VOL"
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  export CRADLE_CONFIG_DIR="$BATS_TEST_TMPDIR/config"
  mkdir -p "$CRADLE_CONFIG_DIR/cradle-rules"
  echo "top" > "$CRADLE_CONFIG_DIR/CLAUDE.md"
  echo "rule" > "$CRADLE_CONFIG_DIR/cradle-rules/a.md"
  echo '{"model":"opus","permissions":{"defaultMode":"auto"}}' > "$CRADLE_CONFIG_DIR/settings.json"
  # "podman run" runs the in-container script directly on the test volume.
  stub_script podman \
    'case "$1 $2" in "volume exists") exit 0 ;; esac' \
    '[[ $1 == run ]] && exec bash "'"$CRADLE_ROOT"'/lib/volume-sync.sh" "${@: -3:1}" "'"$CRADLE_CONFIG_DIR"'" "'"$VOL"'"' \
    'exit 0'
}

@test "sync copies every kit file and keeps its manifest on the host" {
  run cradle config sync
  [ "$status" -eq 0 ]
  [ "$(cat "$VOL/CLAUDE.md")" = top ]
  [ "$(cat "$VOL/cradle-rules/a.md")" = rule ]
  [ "$(cat "$XDG_STATE_HOME/cradle/config-manifest")" = "$(printf 'CLAUDE.md\ncradle-rules/a.md\nsettings.json')" ]
  [ ! -e "$VOL/.cradle-manifest" ]
}

@test "files dropped from the kit are removed, user files survive" {
  cradle config sync
  echo secret > "$VOL/.credentials.json"
  rm "$CRADLE_CONFIG_DIR/cradle-rules/a.md"
  run cradle config sync
  [ "$status" -eq 0 ]
  [ ! -e "$VOL/cradle-rules/a.md" ]
  [ "$(cat "$VOL/.credentials.json")" = secret ]
}

@test "creates the volume when it does not exist" {
  stub_script podman \
    'case "$1 $2" in "volume exists") exit 1 ;; esac' 'exit 0'
  run cradle config sync
  [ "$status" -eq 0 ]
  grep -q "podman volume create cradle-claude" "$STUB_LOG"
}

@test "a manifest planted in the volume cannot remove files outside it" {
  echo keep > "$BATS_TEST_TMPDIR/victim"
  printf '../victim\n' > "$VOL/.cradle-manifest"
  mkdir -p "$XDG_STATE_HOME/cradle"; printf '../victim\n/etc/x\n' > "$XDG_STATE_HOME/cradle/config-manifest"
  run cradle config sync
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/victim")" = keep ]
}

@test "sync writes through a throwaway container, never the host mount point" {
  run cradle config sync
  [ "$status" -eq 0 ]
  grep -q "podman run --rm -i --pull=never --network=none --cap-drop=ALL --security-opt=no-new-privileges --user=0:0 -v cradle-claude:/dst " "$STUB_LOG"
  run ! grep -q "volume inspect" "$STUB_LOG"
}

@test "sync merges the kit's settings keys and keeps Claude's own" {
  echo '{"model":"sonnet","theme":"dark"}' > "$VOL/settings.json"
  run cradle config sync
  [ "$status" -eq 0 ]
  [ "$(jq -r .model "$VOL/settings.json")" = opus ]
  [ "$(jq -r .theme "$VOL/settings.json")" = dark ]
  [ "$(jq -r .permissions.defaultMode "$VOL/settings.json")" = auto ]
}

@test "the volume counts as current when Claude added its own settings" {
  cradle config sync
  jq '.enabledPlugins = {"x": true}' "$VOL/settings.json" > "$VOL/s" && mv "$VOL/s" "$VOL/settings.json"
  . "$CRADLE_ROOT/lib/common.sh"; . "$CRADLE_ROOT/lib/config.sh"
  config_is_current
  echo changed > "$VOL/CLAUDE.md"
  run ! config_is_current
}
