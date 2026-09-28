#!/usr/bin/env bash
# shellcheck disable=SC2016  # the single-quoted commands expand inside the container
# End-to-end on real podman: tier-2 runs through the host's cradle-testd, from
# the host (cradle test) and from the container (cradle-request), and the
# refusals the spec promises (unlisted job, host volume, --privileged,
# unapproved workflow change, malformed request, read-only results).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
C="$ROOT/bin/cradle"
export CRADLE_ROOT=$ROOT
T=$(mktemp -d); P="$T/testd fixture"
K=$(. "$ROOT/lib/common.sh"; . "$ROOT/lib/render.sh"; project_key "$P")
D=$(. "$ROOT/lib/common.sh"; . "$ROOT/lib/render.sh"; testd_dir "$K")
cleanup() {
  set +e   # best effort: one failed removal must not skip the rest or turn a pass into a failure
  (cd "$P" 2>/dev/null && { "$C" down >/dev/null 2>&1; "$C" init --detach >/dev/null 2>&1; })
  podman ps -aq --filter "label=devcontainer.local_folder=$P" | xargs -r podman rm -f >/dev/null 2>&1
  podman ps -aq --filter "name=cradle-proxy-$K" | xargs -r podman rm -f >/dev/null 2>&1
  podman network ls -q --filter "name=cradle-$K" | xargs -r podman network rm -f >/dev/null 2>&1
  podman volume ls -q --filter "name=cradle-$K" | xargs -r podman volume rm -f >/dev/null 2>&1
  rm -rf "$D" "${XDG_CACHE_HOME:-$HOME/.cache}/cradle/runs/$K"-* "$T"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
# check NAME COMMAND...: ok when COMMAND succeeds, otherwise fail.
check() { local name=$1; shift; if "$@"; then ok "$name"; else fail "$name"; fi; }
absent() { ! "$@"; }
eq() { [[ $1 == "$2" ]]; }
# wait_status ID: the status of results/ID once it exists (60 s at most).
wait_status() {
  local i; for ((i = 0; i < 60; i++)); do [[ -f $D/results/$1/status.json ]] && break; sleep 1; done
  jq -r .status "$D/results/$1/status.json" 2>/dev/null
}
# passed_log_ok: some passed run's act.log reports the job succeeded.
passed_log_ok() {
  local f
  for f in "$D"/results/*/status.json; do
    [[ $(jq -r .status "$f") == passed ]] && grep -qs "Job succeeded" "${f%status.json}act.log" && return 0
  done
  return 1
}

mkdir -p "$P/.github/workflows"; echo fixture > "$P/README"
cat > "$P/.github/workflows/ci.yml" <<'YML'
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: test -f README && test ! -S /var/run/docker.sock && ! curl -sf -m 5 https://example.com
  hostvol:
    runs-on: ubuntu-latest
    container: {image: alpine, volumes: ["/:/host"]}
    steps:
      - run: ls /host
  priv:
    runs-on: ubuntu-latest
    container: {image: alpine, options: --privileged}
    steps:
      - run: "true"
YML
# a hostile .actrc in the commit: were act to read it, the job would run on the
# host (where curl reaches example.com) and fail
echo '-P ubuntu-latest=-self-hosted' > "$P/.actrc"
git -C "$P" init -q; git -C "$P" add -A; git -C "$P" -c user.name=t -c user.email=t@localhost commit -q -m init
cd "$P"

"$C" init >/dev/null || fail "init"; ok "init"
jq '.testJobs = [{workflow: "ci.yml", job: "test", network: false},
                 {workflow: "ci.yml", job: "hostvol", network: false},
                 {workflow: "ci.yml", job: "priv", network: false}] | .testTimeout = 10' \
  .devcontainer/cradle.json > c.tmp && mv c.tmp .devcontainer/cradle.json
"$C" approve-workflows --yes >/dev/null || fail "approve"; ok "approve"

check "path unit active"           systemctl --user is-active --quiet "cradle-testd@$K.path"
check "host: cradle test passes"   "$C" test test
check "unknown job rejected"       absent "$C" test deploy
check "host volume job rejected"   absent "$C" test hostvol
check "privileged job rejected"    absent "$C" test priv
echo '# changed' >> .github/workflows/ci.yml
git -c user.name=t -c user.email=t@localhost commit -qam "change workflow"
check "unapproved change rejected" absent "$C" test test
git reset -q --hard HEAD~1
printf '{"ref":"%s","job":"test","x":1}' "$(git rev-parse HEAD)" > "$D/req/new/extra.json"
check "extra field rejected"       eq "$(wait_status extra)" rejected
ln -s /etc/passwd "$D/req/new/evil.json"
for _ in {1..60}; do [[ -L $D/req/new/evil.json ]] || break; sleep 1; done
check "symlinked request refused"  eq "$(find "$D/results" -maxdepth 1 -name 'invalid-*' | wc -l)" 1

"$C" up >/dev/null || fail "up"; ok "up"
in_c() { devcontainer exec --docker-path podman --workspace-folder "$P" bash -lc "$1"; }
check "container: cradle-request passes" in_c 'cd "$CRADLE_WORKSPACE" && cradle-request test'
check "container cannot write results"   absent in_c 'touch ~/.cradle/results/x 2>/dev/null'
last=$(jq -rs 'map(select(.status == "passed")) | sort_by(.finished) | last | .job' "$D"/results/*/status.json)
check "a passed run was the test job"    eq "$last" test
check "act log shows the job succeeded"  passed_log_ok
check "no worktree left behind"          eq "$(find "${XDG_CACHE_HOME:-$HOME/.cache}/cradle/runs" -maxdepth 1 -name "$K-*" 2>/dev/null | wc -l)" 0

"$C" down >/dev/null || fail "down"; ok "down"
echo "testd: all checks passed"
