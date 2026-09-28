#!/usr/bin/env bash
# Smoke test of the egress design on real podman: a client on an internal network
# reaches only allowlisted domains, and only through the dual-homed proxy.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
V=$(cat "$ROOT/VERSION"); NET=cradle-smoke-net; OUT=cradle-smoke-egress; PX=cradle-smoke-proxy
T=$(mktemp -d)
trap 'podman rm -f "$PX" >/dev/null 2>&1; podman network rm -f "$NET" "$OUT" >/dev/null 2>&1; rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
check() { local name=$1; shift; if "$@"; then ok "$name"; else fail "$name"; fi; }
absent() { ! "$@"; }
eq() { [[ $1 == "$2" ]]; }

grep -Ev '^\s*(#|$)' "$ROOT/proxy/allowlist.txt" > "$T/allowlist"
# allowlisted, yet host addresses: must stay refused (nip.io names resolve to the IP they spell)
printf '%s\n' host.containers.internal .nip.io >> "$T/allowlist"
podman network create --internal "$NET" >/dev/null
# the default "podman" network has DNS off, so the proxy would resolve only through
# the internal network's aardvark, which answers nothing outside: a network of its own
podman network create "$OUT" >/dev/null
podman run -d --name "$PX" --network "$OUT" --network "$NET:alias=proxy" \
  --cap-drop=ALL --security-opt=no-new-privileges --read-only --memory=128m \
  -v "$T/allowlist:/etc/squid/allowlist:ro" "localhost/cradle-proxy:$V" >/dev/null
sleep 2
client() { podman run --rm --network "$NET" --pull=never "localhost/cradle-base:$V" bash -c "$1"; }
code() { client "curl -s -o /dev/null -w '%{http_code}' --max-time 15 -x http://proxy:3128 $1 || true"; }

check "allowed domain via proxy"   eq "$(code https://api.github.com/zen)" 200
check "other domain refused"       eq "$(code http://example.com/)" 403
check "IP literal refused"         eq "$(code http://140.82.112.3/)" 403
check "host name not resolved"     absent eq "$(code http://host.containers.internal/)" 200
check "host address unreachable"   absent eq "$(code http://169-254-1-2.nip.io/)" 200
check "private address refused"    eq "$(code http://10-0-0-1.nip.io/)" 403
check "port 22 refused"            eq "$(code http://github.com:22/)" 403
code https://example.com/ >/dev/null   # a refused CONNECT, for the log check (curl reports 000)
check "no direct route"            absent client 'curl -s --max-time 5 --noproxy "*" https://github.com >/dev/null'
check "no external DNS"            absent client 'getent hosts github.com >/dev/null'
check "denied request logged"      bash -c "podman logs $PX 2>/dev/null | grep -q 'TCP_DENIED CONNECT example.com:443'"
echo "proxy smoke: all checks passed"
