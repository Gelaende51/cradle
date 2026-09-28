setup() {
  load test_helper; setup_isolated_path
  VOL="$BATS_TEST_TMPDIR/vol"; mkdir -p "$VOL"
  export CRADLE_CONFIG_DIR="$BATS_TEST_TMPDIR/config"
  mkdir -p "$CRADLE_CONFIG_DIR/cradle-rules"
  echo "top" > "$CRADLE_CONFIG_DIR/CLAUDE.md"
  echo "rule" > "$CRADLE_CONFIG_DIR/cradle-rules/a.md"
  stub_script podman \
    'case "$1 $2" in "volume exists") exit 0 ;; "volume inspect") echo '"$VOL"' ;; esac'
}

@test "sync copies every kit file and writes a manifest" {
  run cradle config sync
  [ "$status" -eq 0 ]
  [ "$(cat "$VOL/CLAUDE.md")" = top ]
  [ "$(cat "$VOL/cradle-rules/a.md")" = rule ]
  [ "$(sort "$VOL/.cradle-manifest")" = "$(printf 'CLAUDE.md\ncradle-rules/a.md')" ]
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
    'case "$1 $2" in "volume exists") exit 1 ;; "volume create") exit 0 ;; "volume inspect") echo '"$VOL"' ;; esac'
  run cradle config sync
  [ "$status" -eq 0 ]
  grep -q "podman volume create cradle-claude" "$STUB_LOG"
}
