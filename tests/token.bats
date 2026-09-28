setup() {
  load test_helper; setup_isolated_path
  . "$CRADLE_ROOT/lib/common.sh"; . "$CRADLE_ROOT/lib/token.sh"
  P="$BATS_TEST_TMPDIR/proj"; mkdir -p "$P"; git -C "$P" init -q; cd "$P"
}

@test "repo slug from https and ssh remotes" {
  git remote add origin https://github.com/Gelaende51/cradle.git
  [ "$(repo_slug)" = "Gelaende51/cradle" ]
  git remote set-url origin git@github.com:Gelaende51/lure
  [ "$(repo_slug)" = "Gelaende51/lure" ]
}

@test "no slug for a non-GitHub remote or no remote" {
  run repo_slug
  [ "$status" -eq 1 ]
  git remote add origin https://gitlab.com/a/b.git
  run repo_slug
  [ "$status" -eq 1 ]
}

@test "set stores the token read from stdin under the repo" {
  stub secret-tool
  run bash -c 'echo ghp_x | "$CRADLE_ROOT/bin/cradle" token set Gelaende51/cradle'
  [ "$status" -eq 0 ]
  grep -q "secret-tool store --label=cradle GitHub token Gelaende51/cradle service cradle repo Gelaende51/cradle" "$STUB_LOG"
}

@test "show-expiry warns when fewer than 7 days are left" {
  stub secret-tool 0 ghp_x
  soon=$(date -u -d '+3 days' '+%Y-%m-%d %H:%M:%S UTC')
  stub curl 0 $'HTTP/2 200\r\ngithub-authentication-token-expiration: '"$soon"$'\r\n'
  run cradle token show-expiry Gelaende51/cradle
  [ "$status" -eq 0 ]
  [[ "$output" == *"expires in 2 days"* || "$output" == *"expires in 3 days"* ]]
}

@test "show-expiry fails clearly without a stored token" {
  stub secret-tool 1
  run cradle token show-expiry Gelaende51/cradle
  [ "$status" -eq 1 ]
  [[ "$output" == *"no token stored"* ]]
}
