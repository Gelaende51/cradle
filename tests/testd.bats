setup() {
  load test_helper; setup_isolated_path
  . "$CRADLE_ROOT/lib/common.sh"; . "$CRADLE_ROOT/lib/render.sh"; . "$CRADLE_ROOT/lib/testd.sh"
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  P="$BATS_TEST_TMPDIR/proj"; mkdir -p "$P/.devcontainer"; git -C "$P" init -q
  git -C "$P" -c user.name=t -c user.email=t@x commit -q --allow-empty -m one
  SHA=$(git -C "$P" rev-parse HEAD)
  echo '{"languages":[],"features":{},"maskPaths":[],"memory":"3g","allowedDomains":[],"testJobs":[{"workflow":"ci.yml","job":"test","network":false}]}' > "$P/.devcontainer/cradle.json"
  testd_prepare "$P"; K=$(project_key "$P"); D=$(testd_dir "$K")
}
req() { printf '%s' "$2" > "$D/req/new/$1"; }

@test "prepare creates the maildir, results and records the project" {
  for d in req/tmp req/new results processing done; do [ -d "$D/$d" ]; done
  [ "$(cat "$D/project")" = "$P" ]
}

@test "a well-formed request passes the check" {
  req a.json "{\"ref\":\"$SHA\",\"job\":\"test\"}"
  [ "$(request_take "$K")" = a ]
  [ "$(request_check "$P" "$D/processing/a.json")" = "$SHA test" ]
}

@test "extra fields, a short ref, an unknown commit or an unlisted job are rejected" {
  for body in "{\"ref\":\"$SHA\",\"job\":\"test\",\"x\":1}" '{"ref":"abc123","job":"test"}' \
              "{\"ref\":\"$(printf 'f%.0s' {1..40})\",\"job\":\"test\"}" "{\"ref\":\"$SHA\",\"job\":\"deploy\"}" 'not json'; do
    printf '%s' "$body" > "$BATS_TEST_TMPDIR/r.json"
    run request_check "$P" "$BATS_TEST_TMPDIR/r.json"
    [ "$status" -eq 1 ]; [ -n "$output" ]
  done
}

@test "an oversized request is rejected" {
  head -c 5000 /dev/zero | tr '\0' ' ' > "$BATS_TEST_TMPDIR/r.json"
  run request_check "$P" "$BATS_TEST_TMPDIR/r.json"
  [ "$status" -eq 1 ]; [[ "$output" == *"4 KB"* ]]
}

@test "a symlinked request is rejected, its target untouched" {
  echo secret > "$BATS_TEST_TMPDIR/target"
  ln -s "$BATS_TEST_TMPDIR/target" "$D/req/new/evil.json"
  run request_take "$K"
  [ -z "$output" ]
  [ "$(cat "$BATS_TEST_TMPDIR/target")" = secret ]
  run grep -l rejected "$D"/results/invalid-*/status.json
  [ "$status" -eq 0 ]
  run ! grep -rq secret "$D/results"
}

@test "unsafe names and non-json entries get a rejected result" {
  req 'a b.json' '{}'; mkdir "$D/req/new/dir.json"; req x.txt '{}'
  run request_take "$K"
  [ -z "$output" ]
  [ "$(ls "$D/results" | grep -c '^invalid-')" -eq 3 ]
  [ -z "$(ls -A "$D/req/new")" ]
}

@test "a swapped req/new is not followed" {
  mkdir "$BATS_TEST_TMPDIR/elsewhere"; echo keep > "$BATS_TEST_TMPDIR/elsewhere/x.json"
  rm -r "$D/req/new"; ln -s "$BATS_TEST_TMPDIR/elsewhere" "$D/req/new"
  run request_take "$K"
  [ "$(cat "$BATS_TEST_TMPDIR/elsewhere/x.json")" = keep ]
}

@test "an id that already has a result gets a fresh one" {
  result_write "$K" r1 passed "ok" test "$SHA" >/dev/null
  id=$(result_write "$K" r1 rejected "again")
  [ "$id" != r1 ]
  [ "$(jq -r .status "$D/results/r1/status.json")" = passed ]
  [ "$(jq -r .status "$D/results/$id/status.json")" = rejected ]
}

wf() {  # wf CONTENT [PATH]: commit a workflow (default .github/workflows/ci.yml), print the sha
  local path=${2:-.github/workflows/ci.yml}
  mkdir -p "$P/$(dirname "$path")"; printf '%s\n' "$1" > "$P/$path"
  git -C "$P" add -A && git -C "$P" -c user.name=t -c user.email=t@x commit -q -m wf && git -C "$P" rev-parse HEAD
}
SAFE='on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: echo --privileged is fine inside a run step'

@test "an unapproved .github tree is refused, an approved one passes" {
  s=$(wf "$SAFE")
  run job_check "$P" "$s" test
  [ "$status" -eq 1 ]; [[ "$output" == *"approve-workflows"* ]]
  approved_add "$K" "$(github_tree "$P" "$s")" "$s"
  [ "$(job_check "$P" "$s" test)" = ci.yml ]
}

@test "changing a local action needs a new approval" {
  s=$(wf "$SAFE"); approved_add "$K" "$(github_tree "$P" "$s")" "$s"
  s2=$(wf 'runs: {using: composite, steps: []}' .github/actions/x/action.yml)
  run job_check "$P" "$s2" test
  [ "$status" -eq 1 ]
}

@test "unsafe job definitions are refused even when approved" {
  for job in \
    'container: {image: alpine, options: "--privileged"}' \
    'container: {image: alpine, volumes: ["/:/host"]}' \
    'services: {db: {image: postgres, volumes: ["/tmp:/x"]}}' \
    'services: {db: {image: postgres, options: "-v /:/host"}}' \
    'env: {X: "--privileged"}'; do
    s=$(wf "on: push
jobs:
  test:
    runs-on: ubuntu-latest
    $job
    steps:
      - run: true")
    approved_add "$K" "$(github_tree "$P" "$s")" "$s"
    run job_check "$P" "$s" test
    [ "$status" -eq 1 ]
  done
}

@test "a local action outside .github is refused" {
  s=$(wf 'on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: ./tools/evil')
  approved_add "$K" "$(github_tree "$P" "$s")" "$s"
  run job_check "$P" "$s" test
  [ "$status" -eq 1 ]; [[ "$output" == *"outside .github"* ]]
}

@test "approve-workflows shows the diff and records the tree on confirmation" {
  s=$(wf "$SAFE"); cd "$P"
  run bash -c 'echo n | "$CRADLE_ROOT/bin/cradle" approve-workflows'
  [ "$status" -eq 1 ]; [[ "$output" == *"actions/checkout"* ]]
  run "$CRADLE_ROOT/bin/cradle" approve-workflows --yes
  [ "$status" -eq 0 ]
  grep -q "^$(github_tree "$P" "$s") $s$" "$D/approved"
}

@test "a directory the container made read-only does not stop the intake" {
  mkdir -p "$D/req/new/x.json"; echo a > "$D/req/new/x.json/f"; chmod 0500 "$D/req/new/x.json"
  run request_take "$K"
  [ "$status" -eq 0 ]; [ -z "$output" ]
  [ "$(ls "$D/results" | grep -c '^invalid-')" -eq 1 ]
  [ -d "$D/req/new" ] && [ ! -L "$D/req/new" ] && [ -z "$(ls -A "$D/req/new")" ]
}

@test "new/ is a real directory again after a planted symlink is taken away" {
  mkdir "$BATS_TEST_TMPDIR/elsewhere"; rm -r "$D/req/new"; ln -s "$BATS_TEST_TMPDIR/elsewhere" "$D/req/new"
  request_take "$K"
  [ -d "$D/req/new" ] && [ ! -L "$D/req/new" ]
  [ -d "$BATS_TEST_TMPDIR/elsewhere" ]
}

@test "a workflow file that is a symlink is refused" {
  mkdir -p "$P/tools"; printf 'on: push\njobs:\n  test:\n    runs-on: ubuntu-latest\n    container: {image: alpine, volumes: ["/:/host"]}\n    steps:\n      - run: "true"\n' > "$P/tools/wf.yml"
  mkdir -p "$P/.github/workflows"; ln -s ../../tools/wf.yml "$P/.github/workflows/ci.yml"
  git -C "$P" add -A; git -C "$P" -c user.name=t -c user.email=t@x commit -q -m link; s=$(git -C "$P" rev-parse HEAD)
  approved_add "$K" "$(github_tree "$P" "$s")" "$s"
  run job_check "$P" "$s" test
  [ "$status" -eq 1 ]
}

@test "reusable workflows, .. paths, expressions in container and other runners are refused" {
  for job in \
    'test:
    uses: ./tools/x.yml' \
    'test:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/../tools/a' \
    'test:
    runs-on: ubuntu-latest
    container: ${{ fromJSON(vars.C) }}
    steps:
      - run: "true"' \
    'test:
    runs-on: ubuntu-22.04
    steps:
      - run: "true"'; do
    s=$(wf "on: push
jobs:
  $job")
    approved_add "$K" "$(github_tree "$P" "$s")" "$s"
    run job_check "$P" "$s" test
    [ "$status" -eq 1 ]
  done
}

@test "a symlink leading out of the tree is refused" {
  ln -s /etc/passwd "$P/data"
  s=$(wf "$SAFE"); approved_add "$K" "$(github_tree "$P" "$s")" "$s"
  run job_check "$P" "$s" test
  [ "$status" -eq 1 ]; [[ "$output" == *symlink* ]]
}

@test "objects rewritten in the shared repository are refused" {
  s=$(wf "$SAFE"); b=$(git -C "$P" rev-parse "$s:.github/workflows/ci.yml")
  o="$P/.git/objects/${b:0:2}/${b:2}"; chmod u+w "$o"
  python3 -c 'import sys, zlib; c = b"on: push\njobs: {}\n"; open(sys.argv[1], "wb").write(zlib.compress(b"blob %d\0" % len(c) + c))' "$o"
  run github_tree "$P" "$s"
  [ "$status" -ne 0 ]
}

@test "a planted origin/HEAD does not count as the reviewed default branch" {
  R="$BATS_TEST_TMPDIR/remote"; git init -q "$R"; mkdir -p "$R/.github/workflows"; printf '%s\n' "$SAFE" > "$R/.github/workflows/ci.yml"
  git -C "$R" add -A; git -C "$R" -c user.name=t -c user.email=t@x commit -q -m r
  git -C "$P" remote add origin "$R"
  e=$(wf 'on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: echo planted')
  git -C "$P" update-ref refs/remotes/origin/HEAD "$e"
  cd "$P"
  run bash -c 'echo n | "$CRADLE_ROOT/bin/cradle" approve-workflows'
  [ "$status" -eq 1 ]
  run ! grep -q "^$(git -C "$P" rev-parse "$e:.github") " "$D/approved"
  grep -q "^$(git -C "$R" rev-parse "HEAD:.github") " "$D/approved"
}

@test "approve-workflows takes the German yes" {
  s=$(wf "$SAFE"); cd "$P"
  run bash -c 'echo j | "$CRADLE_ROOT/bin/cradle" approve-workflows'
  [ "$status" -eq 0 ]
  grep -q "^$(github_tree "$P" "$s") $s$" "$D/approved"
}
