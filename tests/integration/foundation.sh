#!/usr/bin/env bash
# shellcheck disable=SC2016  # the single-quoted commands expand inside the container
# End-to-end on real podman: attach a fixture project whose name has a space,
# bring the container up, and check the isolation promises from the spec.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
C="$ROOT/bin/cradle"
T=$(mktemp -d); P="$T/fixture proj"
cleanup() {
  (cd "$P" 2>/dev/null && "$C" down >/dev/null 2>&1)
  # shellcheck disable=SC2046  # one id per word
  podman rm -f $(podman ps -aq --filter "label=devcontainer.local_folder=$P") >/dev/null 2>&1
  podman volume ls -q --filter name=cradle-fixture-proj- | xargs -r podman volume rm -f >/dev/null 2>&1
  rm -rf "$T"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }

mkdir -p "$P/.personal"; echo 'pw: hunter2' > "$P/.personal/personal.md"
echo '{"name":"fixture"}' > "$P/package.json"
git -C "$P" init -q; git -C "$P" -c user.name=t -c user.email=t@localhost commit -q --allow-empty -m init
cd "$P"

"$C" init >/dev/null || fail "init"; ok "init"
"$C" up >/dev/null || fail "up"; ok "up"
in_c() { devcontainer exec --docker-path podman --workspace-folder "$P" bash -lc "$1"; }
# check NAME COMMAND...: ok when COMMAND succeeds, otherwise fail.
check() { local name=$1; shift; if "$@"; then ok "$name"; else fail "$name"; fi; }
absent() { ! "$@"; }
eq() { [[ $1 == "$2" ]]; }

check "user is dev"              eq "$(in_c 'id -un')" dev
check "claude pinned"            eq "$(in_c 'claude --version')" "2.1.283 (Claude Code)"
check "node feature"             in_c 'node --version >/dev/null'
check ".personal masked"         eq "$(in_c 'ls -A "$CRADLE_WORKSPACE/.personal"')" ""
check "no container socket"      absent in_c 'ls /run/podman/podman.sock /run/user/*/podman/podman.sock /var/run/docker.sock 2>/dev/null'
check "no capabilities"          eq "$(in_c 'grep CapEff /proc/self/status | tr -d "[:space:]"')" "CapEff:0000000000000000"
check "hooks path in volume"     eq "$(in_c 'git config core.hooksPath')" /home/dev/.local/share/cradle/hooks
check "host .git/hooks untouched" absent test -e "$P/.git/hooks/pre-commit"
check ".git/hooks read-only"      absent in_c 'touch "$CRADLE_WORKSPACE/.git/hooks/pre-commit" 2>/dev/null'
check ".git/config read-only"     absent in_c 'git config core.fsmonitor /tmp/x 2>/dev/null'
check "config volume mounted"    in_c 'test -f ~/.claude/CLAUDE.md && test -f ~/.claude/cradle-rules/orchestrator.md'
check "punt tools answer"        in_c 'bd --version && ethos version && punt version && quarry status >/dev/null'
in_c 'touch "$CRADLE_WORKSPACE/made-in-container"'
check "bind-mount ownership"     eq "$(stat -c %U "$P/made-in-container")" "$(id -un)"

id1=$(podman ps -q --filter "label=devcontainer.local_folder=$P")
jq '.memory = "2g"' .devcontainer/cradle.json > c.tmp && mv c.tmp .devcontainer/cradle.json
"$C" up >/dev/null || fail "up after a config change"
id2=$(podman ps -q --filter "label=devcontainer.local_folder=$P")
check "config change recreates"  absent eq "$id1" "$id2"
check "new memory limit applies" eq "$(podman inspect -f '{{.HostConfig.Memory}}' "$id2")" 2147483648

"$C" down >/dev/null || fail "down"; ok "down"
echo "foundation: all checks passed"
