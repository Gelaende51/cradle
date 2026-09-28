setup() {
  load test_helper; setup_isolated_path
  . "$CRADLE_ROOT/lib/common.sh"; . "$CRADLE_ROOT/lib/testd.sh"
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
  P="$BATS_TEST_TMPDIR/proj"; mkdir -p "$P/.devcontainer" "$P/.github/workflows"; git -C "$P" init -q
  printf 'on: push\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n  net:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n' > "$P/.github/workflows/ci.yml"
  echo '{"languages":[],"features":{},"maskPaths":[],"memory":"3g","allowedDomains":[],"testJobs":[{"workflow":"ci.yml","job":"test","network":false},{"workflow":"ci.yml","job":"net","network":true}],"testTimeout":1}' > "$P/.devcontainer/cradle.json"
  git -C "$P" add -A; git -C "$P" -c user.name=t -c user.email=t@x commit -q -m one
  SHA=$(git -C "$P" rev-parse HEAD)
  testd_prepare "$P"; K=$(project_key "$P"); D=$(testd_dir "$K")
  approved_add "$K" "$(github_tree "$P" "$SHA")" "$SHA"
  stub act 0 "job ok"
}
req() { printf '{"ref":"%s","job":"%s"}' "$SHA" "${2:-test}" > "$D/req/new/$1.json"; }
st() { jq -r .status "$D/results/$1/status.json"; }

@test "a valid request runs act sandboxed and passes" {
  req r1
  "$CRADLE_ROOT/bin/cradle-testd" "$K"
  [ "$(st r1)" = passed ]
  grep -q "^act -W .github/workflows/ci.yml -j test -P ubuntu-latest=docker.io/catthehacker/ubuntu:act-latest --container-daemon-socket - --network none --container-options --memory=2g --rm --artifact-server-path $D/results/r1/artifacts$" "$STUB_LOG"
  [ -f "$D/done/r1.json" ]; [ -z "$(ls -A "$D/processing")" ]
  grep -q "job ok" "$D/results/r1/act.log"
  [ -z "$(ls -A "$XDG_CACHE_HOME/cradle/runs" 2>/dev/null)" ]
}

@test "a job marked network true uses podman's bridge, never host" {
  req r2 net
  "$CRADLE_ROOT/bin/cradle-testd" "$K"
  grep -q -- "--network podman " "$STUB_LOG"
}

@test "a failing job and a rejected request are reported" {
  stub act 1 "boom"; req r3; printf '{"ref":"%s","job":"deploy"}' "$SHA" > "$D/req/new/r4.json"
  "$CRADLE_ROOT/bin/cradle-testd" "$K"
  [ "$(st r3)" = failed ]
  [ "$(st r4)" = rejected ]
  [[ "$(jq -r .reason "$D/results/r4/status.json")" == *"not listed"* ]]
}

@test "a job over its time limit is reported as timeout" {
  stub_script act 'exit 124'   # what timeout(1) returns
  req r5
  "$CRADLE_ROOT/bin/cradle-testd" "$K"
  [ "$(st r5)" = timeout ]
}

@test "leftovers are reported aborted and cleaned" {
  printf '{"ref":"%s","job":"test"}' "$SHA" > "$D/processing/old.json"
  mkdir -p "$XDG_CACHE_HOME/cradle/runs/$K-old"
  "$CRADLE_ROOT/bin/cradle-testd" "$K"
  [ "$(st old)" = aborted ]
  [ ! -e "$XDG_CACHE_HOME/cradle/runs/$K-old" ]
  [ -f "$D/done/old.json" ]
}
