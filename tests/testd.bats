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
