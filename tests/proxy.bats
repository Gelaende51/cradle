setup() {
  load test_helper; setup_isolated_path
  . "$CRADLE_ROOT/lib/common.sh"; . "$CRADLE_ROOT/lib/render.sh"; . "$CRADLE_ROOT/lib/proxy.sh"
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  stub podman
  P="$BATS_TEST_TMPDIR/my proj"; mkdir -p "$P/.devcontainer"
  set_domains '[]'
}
set_domains() { printf '{"languages":[],"features":{},"maskPaths":[],"memory":"3g","allowedDomains":%s,"testJobs":[]}' "$1" > "$P/.devcontainer/cradle.json"; }
list_id() { sha256sum < "$XDG_STATE_HOME/cradle/proxy/$(project_key "$P")/allowlist" | cut -c1-16; }

@test "the default allowlist is used without comments" {
  run allowlist_merge "$P"
  [ "$status" -eq 0 ]
  [[ "$output" == *".github.com"* && "$output" == *"registry.npmjs.org"* ]]
  run ! grep -q '#' <<< "$output"
}

@test "allowedDomains entries are normalised or refused" {
  set_domains '["*.Example.org","docs.rs"]'
  run allowlist_merge "$P"
  [ "$status" -eq 0 ]
  grep -qx '.example.org' <<< "$output"; grep -qx 'docs.rs' <<< "$output"
  for bad in '"https://x.org/p"' '"a b.org"' '"x.org\nhttp_access allow all"' '"localhost"'; do
    set_domains "[$bad]"
    run allowlist_merge "$P"
    [ "$status" -eq 1 ]
    [[ "$output" == *"allowedDomains"* ]]
  done
  set_domains '"x.org"'
  run allowlist_merge "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be a list"* ]]
}

@test "entries covered by a wildcard are dropped" {
  set_domains '["api.github.com","github.com","sub.docs.rs",".docs.rs"]'
  run allowlist_merge "$P"
  run ! grep -qx 'api.github.com' <<< "$output"
  run ! grep -qx 'github.com' <<< "$output"
  run ! grep -qx 'sub.docs.rs' <<< "$output"
  [ "$(allowlist_merge "$P" | grep -cx '.docs.rs')" -eq 1 ]
}

@test "network and proxy names carry the project key" {
  stub_script podman '[[ $1 == network && $2 == exists ]] && exit 1; [[ $1 == inspect ]] && exit 1; exit 0'
  proxy_up "$P"
  k=$(project_key "$P")
  [[ $k == my-proj-???????? ]]
  grep -q "podman network create --internal cradle-$k" "$STUB_LOG"
  grep -q "podman network create cradle-egress" "$STUB_LOG"
  grep -q "podman run -d --name cradle-proxy-$k .*--network cradle-egress --network cradle-$k:alias=proxy .*--cap-drop=ALL .*--read-only .*localhost/cradle-proxy:" "$STUB_LOG"
  grep -q -- "-v $XDG_STATE_HOME/cradle/proxy/$k/allowlist:/etc/squid/allowlist:ro" "$STUB_LOG"
}

@test "a running proxy with the same allowlist is kept" {
  proxy_up "$P"
  id=$(list_id)
  stub_script podman "[[ \$1 == inspect && \$* == *Labels* ]] && echo $id; [[ \$1 == inspect && \$* == *Running* ]] && echo true; exit 0"
  : > "$STUB_LOG"
  proxy_up "$P"
  run ! grep -q "podman run" "$STUB_LOG"
}

@test "up restarts a stopped proxy" {
  proxy_up "$P"
  id=$(list_id)
  stub_script podman "[[ \$1 == inspect && \$* == *Labels* ]] && echo $id; [[ \$1 == inspect && \$* == *Running* ]] && echo false; exit 0"
  : > "$STUB_LOG"
  proxy_up "$P"
  grep -q "podman rm -f cradle-proxy-" "$STUB_LOG"
  grep -q "podman run -d" "$STUB_LOG"
}

@test "a changed allowlist recreates the proxy" {
  stub_script podman '[[ $1 == inspect && $* == *Labels* ]] && echo 0000000000000000; [[ $1 == inspect && $* == *Running* ]] && echo true; exit 0'
  proxy_up "$P"
  grep -q "podman run -d" "$STUB_LOG"
}

@test "net log shows only blocked requests" {
  cd "$P"
  stub_script podman '[[ $1 == logs ]] && printf "%s\n" "2026-09-28T16:00:00 TCP_TUNNEL CONNECT api.github.com:443" "2026-09-28T16:00:01 TCP_DENIED CONNECT example.com:443"; exit 0'
  run "$CRADLE_ROOT/bin/cradle" net log
  [ "$status" -eq 0 ]
  [ "$output" = "2026-09-28T16:00:01 TCP_DENIED CONNECT example.com:443" ]
  grep -q "podman logs cradle-proxy-$(project_key "$P")" "$STUB_LOG"
}
