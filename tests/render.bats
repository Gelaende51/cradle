setup() {
  load test_helper; setup_isolated_path
  . "$CRADLE_ROOT/lib/common.sh"; . "$CRADLE_ROOT/lib/render.sh"
  P="$BATS_TEST_TMPDIR/file path edit"; mkdir -p "$P/.devcontainer"
  echo '{"languages":["node"],"features":{},"maskPaths":[".personal","secret.env","absent"],"memory":"3g","allowedDomains":[],"testJobs":[]}' > "$P/.devcontainer/cradle.json"
}
dc_json() { tail -n +2 "$P/.devcontainer/devcontainer.json"; }

@test "slug of a name with spaces and capitals" {
  [ "$(project_slug "/x/File Path  Edit")" = "file-path-edit" ]
  [ "$(project_slug "/x/Größe")" = "gr-e" ]
}

@test "renders image, node feature, workspace and volumes" {
  render_devcontainer "$P"
  [ "$(dc_json | jq -r .image)" = "localhost/cradle-base:$(cat "$CRADLE_ROOT/VERSION")" ]
  dc_json | jq -e '.features["ghcr.io/devcontainers/features/node:1"].version == "lts"'
  [ "$(dc_json | jq -r .workspaceFolder)" = "/home/dev/src/file-path-edit" ]
  h=$(printf '%s' "$P" | sha256sum | cut -c1-8)
  dc_json | jq -e --arg v "source=cradle-file-path-edit-$h-data,target=/home/dev/.local/share/cradle,type=volume" '.mounts | index($v)'
  dc_json | jq -e '.runArgs | index("--memory=3g") and index("--cap-drop=ALL")'
  [ "$(dc_json | jq -r .remoteEnv.GH_TOKEN)" = '${localEnv:GH_TOKEN}' ]
}

@test "masks a directory with tmpfs, a file with /dev/null, skips a missing path" {
  mkdir "$P/.personal"; touch "$P/secret.env"
  render_devcontainer "$P"
  dc_json | jq -e '.runArgs | index("--tmpfs=/home/dev/src/file-path-edit/.personal:size=1k,mode=0500")'
  dc_json | jq -e '.runArgs | index("--volume=/dev/null:/home/dev/src/file-path-edit/secret.env:ro")'
  [ "$(dc_json | jq '[.runArgs[] | select(test("absent"))] | length')" -eq 0 ]
  [ ! -e "$P/absent" ]
}

@test "re-rendering an untouched file works, a hand-edited one is refused" {
  render_devcontainer "$P"
  render_devcontainer "$P"
  echo ' ' >> "$P/.devcontainer/devcontainer.json"
  run render_devcontainer "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *"edited by hand"* ]]
}

@test "missing cradle.json tells the user to run init" {
  rm "$P/.devcontainer/cradle.json"
  run render_devcontainer "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cradle init"* ]]
}

@test "mounts the host's .git/hooks and .git/config read-only" {
  git -C "$P" init -q; rm -rf "$P/.git/hooks"
  render_devcontainer "$P"
  [ -d "$P/.git/hooks" ]
  dc_json | jq -e --arg a "--volume=$P/.git/hooks:/home/dev/src/file-path-edit/.git/hooks:ro" '.runArgs | index($a)'
  dc_json | jq -e --arg a "--volume=$P/.git/config:/home/dev/src/file-path-edit/.git/config:ro" '.runArgs | index($a)'
}

@test "features outside the allowlist are refused" {
  jq '.features = {"ghcr.io/devcontainers/features/docker-in-docker:2": {}}' "$P/.devcontainer/cradle.json" > "$P/c" && mv "$P/c" "$P/.devcontainer/cradle.json"
  run render_devcontainer "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *"docker-in-docker"*"allowlist"* ]]
}

@test "an allowlisted feature takes options from cradle.json" {
  jq '.features = {"ghcr.io/devcontainers/features/node:1": {"version": "22"}}' "$P/.devcontainer/cradle.json" > "$P/c" && mv "$P/c" "$P/.devcontainer/cradle.json"
  render_devcontainer "$P"
  dc_json | jq -e '.features["ghcr.io/devcontainers/features/node:1"].version == "22"'
}

@test "the render id is stable and changes with the configuration" {
  render_devcontainer "$P"; a=$(render_id "$P")
  render_devcontainer "$P"; [ "$(render_id "$P")" = "$a" ]
  [ ${#a} -eq 64 ]
  dc_json | jq -e --arg a "--label=cradle.render=$a" '.runArgs | index($a)'
  jq '.memory = "4g"' "$P/.devcontainer/cradle.json" > "$P/c" && mv "$P/c" "$P/.devcontainer/cradle.json"
  render_devcontainer "$P"; [ "$(render_id "$P")" != "$a" ]
}
