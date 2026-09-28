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
  [ "$(dc_json | jq -r .workspaceFolder)" = "/workspaces/file-path-edit" ]
  dc_json | jq -e '.mounts | index("source=cradle-file-path-edit-data,target=/home/dev/.local/share/cradle,type=volume")'
  dc_json | jq -e '.runArgs | index("--memory=3g") and index("--cap-drop=ALL")'
  [ "$(dc_json | jq -r .remoteEnv.GH_TOKEN)" = '${localEnv:GH_TOKEN}' ]
}

@test "masks a directory with tmpfs, a file with /dev/null, skips a missing path" {
  mkdir "$P/.personal"; touch "$P/secret.env"
  render_devcontainer "$P"
  dc_json | jq -e '.runArgs | index("--tmpfs=/workspaces/file-path-edit/.personal:size=1k,mode=0500")'
  dc_json | jq -e '.runArgs | index("--volume=/dev/null:/workspaces/file-path-edit/secret.env:ro")'
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
