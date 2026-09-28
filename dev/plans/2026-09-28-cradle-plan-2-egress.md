# cradle Plan 2: Egress proxy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A project's dev container reaches the outside world only through a per-project allowlist proxy; everything else is unreachable and blocked requests are visible with `cradle net log`.

**Architecture:** `cradle up` creates an internal podman network `cradle-<key>` (no route out) and a squid container `cradle-proxy-<key>` that sits on that network (alias `proxy`) and on podman's default network. The dev container joins only the internal network and gets `HTTP(S)_PROXY=http://proxy:3128`. The allowlist is the kit's default plus `allowedDomains` from `cradle.json`, written on the host and mounted read-only; a changed allowlist recreates the proxy.

**Tech Stack:** squid on Alpine (image `cradle-proxy:<version>`), rootless podman 6 networks (netavark, aardvark-dns), bash, jq, bats.

**Spec:** `dev/specs/2026-09-28-cradle-design.md` §3.5 (plus §2 network sketch, §3.7 `net log` and `image build`, §5 doctor, §6 security tests).

## Global Constraints

- Default allowlist: Anthropic API and auth, GitHub (including `*.githubusercontent.com`), npm, PyPI and `files.pythonhosted.org`, the Go proxy and sum DB, crates.io and `static.crates.io`, Debian repos.
- Per-project additions come from `cradle.json` (`allowedDomains`).
- The dev container has no route out except the proxy; `NO_PROXY` covers localhost only.
- Blocked requests are logged; `cradle net log` shows them.
- `cradle image build` rebuilds `cradle-base` and the proxy image; a failed build leaves the previous tag in place.
- Every shell file passes `shellcheck -x`; every command has bats tests with podman stubbed (`tests/test_helper.bash`).
- Long podman runs (integration, image builds) go through `systemd-run --user --collect --setenv=PATH="$PATH" --setenv=XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" --setenv=HOME="$HOME"`, never a background shell of Claude Code (low-memory kill, Plan 1 takeaway). Delete the log before starting a run and wait for its `EXIT=` line.

## Review Focus

1. `allowedDomains` holding `*.example.com`, capitals, a URL (`https://x.org/path`), a space or a newline → wildcard and case are normalised; anything that is not a domain is refused naming the entry, never written into squid's file (Task 2 test "allowedDomains entries are normalised or refused").
2. An entry already covered by a wildcard (`api.github.com` next to `.github.com`) → dropped before squid sees it; squid refuses to start on some overlaps (Task 2 test "entries covered by a wildcard are dropped").
3. The proxy container stopped or crashed while the project is attached → the next `cradle up` starts it again (Task 2 test "up restarts a stopped proxy").
4. Two projects attached at once, including two with the same folder name → separate networks and proxies, no name clash (Task 2 test "network and proxy names carry the project key").
5. A request to an IP address or on a port other than 80/443 for an allowed domain → refused (Task 1 smoke checks "IP literal refused", "port 22 refused").

---

### Task 1: Proxy image and a standalone smoke test

This task is also the spike: it proves that squid filters CONNECT by domain on a rootless internal network with a dual-homed proxy. If the smoke test cannot pass, stop and report (fallback to evaluate: tinyproxy with `FilterDefaultDeny`).

**Files:**
- Create: `proxy/Containerfile`, `proxy/squid.conf`, `proxy/allowlist.txt`, `tests/integration/proxy.sh`
- Modify: `image/versions.env` (add `PROXY_BASE`), `lib/image.sh` (build both images), `tests/image.bats`, `Makefile` (lint the new script)

**Interfaces:**
- Produces: image `localhost/cradle-proxy:<VERSION>`; squid listens on 3128, reads `/etc/squid/allowlist` (squid `dstdomain` syntax: `.example.com` = domain and subdomains), logs one line per request to stdout as `<ISO time> <squid status> <method> <url>` (e.g. `2026-09-28T16:00:00 TCP_DENIED CONNECT example.com:443`).
- Produces: `image_build` builds `cradle-base` then `cradle-proxy`, each via `_build_one NAME DIR` (tag switched only on success).

- [ ] **Step 1: Pin the base.** Check the newest Alpine stable tag (`podman search --list-tags docker.io/library/alpine | tail`), add to `image/versions.env`:

```
PROXY_BASE=docker.io/library/alpine:3.22
```
(use the tag found; record it in the ledger as a ruling).

- [ ] **Step 2: Write `proxy/allowlist.txt`**

```
# cradle default egress allowlist (squid dstdomain syntax: a leading dot also
# allows every subdomain). Projects add domains in cradle.json "allowedDomains".
# Claude Code: API, login, telemetry
.anthropic.com
.claude.ai
.claude.com
# GitHub: git, API, release assets, raw content
.github.com
.githubusercontent.com
# npm
registry.npmjs.org
# PyPI and uv
pypi.org
files.pythonhosted.org
# Go module proxy and checksum DB
proxy.golang.org
sum.golang.org
# Rust
crates.io
static.crates.io
index.crates.io
# Debian
deb.debian.org
```

- [ ] **Step 3: Write `proxy/squid.conf`**

```
# cradle egress proxy: allow only allowlisted domains, on 80 and 443 (CONNECT on 443 only).
http_port 3128
pid_filename none
coredump_dir /tmp
cache deny all
via off
forwarded_for delete
cache_log stdio:/dev/stderr
logformat cradle %{%Y-%m-%dT%H:%M:%S}tl %Ss %rm %ru
access_log stdio:/dev/stdout cradle

acl allowed dstdomain -n "/etc/squid/allowlist"
acl web_ports port 80 443
acl tls_port port 443
acl CONNECT method CONNECT
http_access deny !web_ports
http_access deny CONNECT !tls_port
http_access allow allowed
http_access deny all
```

- [ ] **Step 4: Write `proxy/Containerfile`**

```
ARG PROXY_BASE
FROM ${PROXY_BASE}
RUN apk add --no-cache squid
COPY squid.conf /etc/squid/squid.conf
USER squid
EXPOSE 3128
CMD ["squid", "-N", "-f", "/etc/squid/squid.conf"]
```

- [ ] **Step 5: Write the failing image tests** — replace the first test in `tests/image.bats` and add one:

```bash
@test "builds both images with every pinned version and retags on success" {
  stub podman
  run cradle image build
  [ "$status" -eq 0 ]
  grep -q "podman build .*--build-arg CLAUDE_CODE_VERSION=2.1.283 .*-f $CRADLE_ROOT/image/Containerfile" "$STUB_LOG"
  grep -q "podman build .*--build-arg PROXY_BASE=.*-f $CRADLE_ROOT/proxy/Containerfile" "$STUB_LOG"
  grep -q "podman tag cradle-base:building-[0-9]* cradle-base:$(cat "$CRADLE_ROOT/VERSION")" "$STUB_LOG"
  grep -q "podman tag cradle-proxy:building-[0-9]* cradle-proxy:$(cat "$CRADLE_ROOT/VERSION")" "$STUB_LOG"
}

@test "a failed proxy build leaves the proxy tag alone" {
  stub_script podman '[[ $1 == build && $* == *proxy/Containerfile* ]] && exit 1; exit 0'
  run cradle image build
  [ "$status" -eq 1 ]
  [[ "$output" == *"cradle-proxy"*"left unchanged"* ]]
  run ! grep -q "podman tag cradle-proxy" "$STUB_LOG"
}
```
Run: `bats tests/image.bats` — Expected: the two new tests FAIL (no proxy build).

- [ ] **Step 6: Implement in `lib/image.sh`** — replace `image_build`:

```bash
# _build_one NAME DIR: build DIR/Containerfile as NAME:<version>; the tag moves only on success.
_build_one() {
  local name=$1 dir=$2 tag tmp args=()
  tag="$name:$(cradle_version)"
  tmp="$name:building-$$"
  mapfile -t args < <(_build_args)
  if ! podman build "${args[@]}" -t "$tmp" -f "$dir/Containerfile" "$dir"; then
    podman rmi -f "$tmp" >/dev/null 2>&1 || true
    die "image build failed; %s left unchanged" "$tag"
  fi
  podman tag "$tmp" "$tag"
  podman rmi "$tmp" >/dev/null
  msg "built %s" "$tag"
}

image_build() {
  need podman
  _build_one cradle-base "$CRADLE_ROOT/image"
  _build_one cradle-proxy "$CRADLE_ROOT/proxy"
}
```
Update the header comment to "build cradle-base and cradle-proxy". Run `bats tests/image.bats` — Expected: PASS.

- [ ] **Step 7: Write `tests/integration/proxy.sh`** (the smoke test; needs both images built):

```bash
#!/usr/bin/env bash
# Smoke test of the egress design on real podman: a client on an internal network
# reaches only allowlisted domains, and only through the dual-homed proxy.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
V=$(cat "$ROOT/VERSION"); NET=cradle-smoke-net; PX=cradle-smoke-proxy
T=$(mktemp -d)
trap 'podman rm -f "$PX" >/dev/null 2>&1; podman network rm -f "$NET" >/dev/null 2>&1; rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
check() { local name=$1; shift; if "$@"; then ok "$name"; else fail "$name"; fi; }
absent() { ! "$@"; }

grep -Ev '^\s*(#|$)' "$ROOT/proxy/allowlist.txt" > "$T/allowlist"
podman network create --internal "$NET" >/dev/null
podman run -d --name "$PX" --network podman --network "$NET:alias=proxy" \
  --cap-drop=ALL --security-opt=no-new-privileges --read-only --memory=128m \
  -v "$T/allowlist:/etc/squid/allowlist:ro" "localhost/cradle-proxy:$V" >/dev/null
sleep 2
client() { podman run --rm --network "$NET" --pull=never "localhost/cradle-base:$V" bash -c "$1"; }
code() { client "curl -s -o /dev/null -w '%{http_code}' --max-time 15 -x http://proxy:3128 $1 || true"; }

check "allowed domain via proxy"   eq "$(code https://api.github.com/zen)" 200
check "other domain refused"       eq "$(code http://example.com/)" 403
check "IP literal refused"         eq "$(code http://140.82.112.3/)" 403
check "port 22 refused"            eq "$(code http://github.com:22/)" 403
code https://example.com/ >/dev/null   # a refused CONNECT, for the log check (curl reports 000)
check "no direct route"            absent client 'curl -s --max-time 5 --noproxy "*" https://github.com >/dev/null'
check "no external DNS"            absent client 'getent hosts github.com >/dev/null'
check "denied request logged"      bash -c "podman logs $PX 2>/dev/null | grep -q 'TCP_DENIED CONNECT example.com:443'"
echo "proxy smoke: all checks passed"
```
Define `eq() { [[ $1 == "$2" ]]; }` next to `absent`. Refusals are checked over plain HTTP, where squid answers 403 itself; a refused HTTPS CONNECT makes curl report 000. Add the script to the Makefile `lint` list and a target `proxy-smoke: ; bash tests/integration/proxy.sh`.

- [ ] **Step 8: Build and run for real** (systemd-run, see Global Constraints): `bin/cradle image build`, then `make proxy-smoke`. Expected: all 7 checks ok. If "no external DNS" fails (aardvark forwarding names on an internal network), record it as a finding and ask the operator: DNS is an exfiltration channel. If squid refuses to start, read `podman logs cradle-smoke-proxy` (config errors go to stderr), fix `squid.conf`, record the quirk in `dev/takeaways.md`. If `--network podman --network <internal>` is rejected, try `podman network connect` after `run`; record which worked.

- [ ] **Step 9: Commit** — `git add proxy image/versions.env lib/image.sh tests/image.bats tests/integration/proxy.sh Makefile dev/takeaways.md && git commit -m "Add the squid egress proxy image and its smoke test"`

---

### Task 2: `lib/proxy.sh` — allowlist, proxy lifecycle, `cradle net log`

**Files:**
- Create: `lib/proxy.sh`, `tests/proxy.bats`
- Modify: `lib/render.sh` (add `project_key`, use it for the volume name), `bin/cradle` (`net` group and usage line)

**Interfaces:**
- Consumes: `project_slug DIR` (render.sh), `cradle_version`, `die`, `msg`, `need` (common.sh).
- Produces:
  - `project_key DIR` → `<slug>-<first 8 hex of sha256(DIR)>` (render.sh; the data volume becomes `cradle-$(project_key DIR)-data`, unchanged value).
  - `allowlist_merge DIR` → prints the merged, normalised, deduplicated allowlist on stdout; dies on an invalid entry.
  - `proxy_up DIR` → ensures network `cradle-<key>` (internal) and a running container `cradle-proxy-<key>` with label `cradle.allowlist=<sha256 of the list, 16 hex>`; recreates it when the label differs or it is not running.
  - `proxy_down DIR` → removes `cradle-proxy-<key>` (the network stays).
  - `cmd_net log` → prints the proxy's `TCP_DENIED` lines for the current project.

- [ ] **Step 1: Write the failing tests `tests/proxy.bats`**

```bash
setup() {
  load test_helper; setup_isolated_path
  . "$CRADLE_ROOT/lib/common.sh"; . "$CRADLE_ROOT/lib/render.sh"; . "$CRADLE_ROOT/lib/proxy.sh"
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  stub podman
  P="$BATS_TEST_TMPDIR/my proj"; mkdir -p "$P/.devcontainer"
  set_domains '[]'
}
set_domains() { printf '{"languages":[],"features":{},"maskPaths":[],"memory":"3g","allowedDomains":%s,"testJobs":[]}' "$1" > "$P/.devcontainer/cradle.json"; }

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
}

@test "entries covered by a wildcard are dropped" {
  set_domains '["api.github.com","github.com","sub.docs.rs",".docs.rs"]'
  run allowlist_merge "$P"
  run ! grep -qx 'api.github.com' <<< "$output"
  run ! grep -qx 'github.com' <<< "$output"
  run ! grep -qx 'sub.docs.rs' <<< "$output"
  [ "$(grep -cx '.docs.rs' <<< "$(allowlist_merge "$P")")" -eq 1 ]
}

@test "network and proxy names carry the project key" {
  stub_script podman '[[ $1 == network && $2 == exists ]] && exit 1; [[ $1 == inspect ]] && exit 1; exit 0'
  proxy_up "$P"
  k=$(project_key "$P")
  [[ $k == my-proj-???????? ]]
  grep -q "podman network create --internal cradle-$k" "$STUB_LOG"
  grep -q "podman run -d --name cradle-proxy-$k .*--network podman --network cradle-$k:alias=proxy .*--cap-drop=ALL .*--read-only .*localhost/cradle-proxy:" "$STUB_LOG"
  grep -q -- "-v $XDG_STATE_HOME/cradle/proxy/$k/allowlist:/etc/squid/allowlist:ro" "$STUB_LOG"
}

@test "a running proxy with the same allowlist is kept" {
  proxy_up "$P" 2>/dev/null || true   # writes the allowlist
  id=$(sha256sum < "$XDG_STATE_HOME/cradle/proxy/$(project_key "$P")/allowlist" | cut -c1-16)
  stub_script podman "[[ \$1 == inspect && \$* == *Labels* ]] && echo $id; [[ \$1 == inspect && \$* == *Running* ]] && echo true; exit 0"
  : > "$STUB_LOG"
  proxy_up "$P"
  run ! grep -q "podman run" "$STUB_LOG"
}

@test "up restarts a stopped proxy" {
  proxy_up "$P" 2>/dev/null || true
  id=$(sha256sum < "$XDG_STATE_HOME/cradle/proxy/$(project_key "$P")/allowlist" | cut -c1-16)
  stub_script podman "[[ \$1 == inspect && \$* == *Labels* ]] && echo $id; [[ \$1 == inspect && \$* == *Running* ]] && echo false; exit 0"
  : > "$STUB_LOG"
  proxy_up "$P"
  grep -q "podman rm -f cradle-proxy-" "$STUB_LOG"
  grep -q "podman run -d" "$STUB_LOG"
}

@test "a changed allowlist recreates the proxy" {
  stub_script podman '[[ $1 == inspect && $* == *Labels* ]] && echo 0000000000000000; [[ $1 == inspect ]] && echo true; exit 0'
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
```
Run: `bats tests/proxy.bats` — Expected: FAIL (`lib/proxy.sh` missing).

- [ ] **Step 2: Add `project_key` to `lib/render.sh`** (after `project_slug`) and use it:

```bash
# project_key DIR: slug plus a hash of the absolute path, unique per project folder.
project_key() {
  printf '%s-%s' "$(project_slug "$1")" "$(printf '%s' "$1" | sha256sum | cut -c1-8)"
}
```
In `render_devcontainer` replace the `vol=` line with `vol="cradle-$(project_key "$dir")-data"` (same value as before; the comment "the path hash keeps two projects …" moves above `project_key`).

- [ ] **Step 3: Write `lib/proxy.sh`**

```bash
#!/usr/bin/env bash
# Per-project egress proxy: an internal network cradle-<key> with no route out,
# and a squid container on it (alias "proxy") that also sits on podman's default
# network. The dev container joins only the internal network.
# shellcheck source=lib/render.sh
. "$CRADLE_ROOT/lib/render.sh"

_proxy_dir() { printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/cradle/proxy/$(project_key "$1")"; }

# _drop_covered: stdin sorted unique entries; drops those a ".wildcard" entry already allows.
_drop_covered() {
  awk '{ d[NR] = $0; if (substr($0, 1, 1) == ".") w[$0] = 1 }
    END { for (i = 1; i <= NR; i++) {
      s = d[i]; t = (substr(s, 1, 1) == "." ? substr(s, 2) : s); n = split(t, p, "."); c = 0
      for (j = 1; j < n; j++) { suf = ""; for (k = j; k <= n; k++) suf = suf "." p[k]
        if ((suf in w) && suf != s) c = 1 }
      if (!c) print s } }'
}

allowlist_merge() {
  local dir=$1 extra bad
  extra=$(jq -r '(.allowedDomains // []) | if type == "array" then .[] else error("not a list") end' \
    "$dir/.devcontainer/cradle.json" 2>/dev/null) || die "allowedDomains in cradle.json must be a list of domains"
  extra=$(printf '%s\n' "$extra" | tr '[:upper:]' '[:lower:]' | sed 's/^\*\././')
  bad=$(printf '%s\n' "$extra" | grep -Ev '^$|^\.?([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$' | head -n1 || true)
  [[ -z $bad ]] || die "allowedDomains: %s is not a domain (write example.com, or .example.com for its subdomains too)" "$bad"
  { grep -Ev '^[[:space:]]*(#|$)' "$CRADLE_ROOT/proxy/allowlist.txt"; printf '%s\n' "$extra"; } \
    | awk 'NF' | sort -u | _drop_covered
}

proxy_up() {
  local dir=$1 key net name list id cur running
  key=$(project_key "$dir"); net="cradle-$key"; name="cradle-proxy-$key"
  list="$(_proxy_dir "$dir")/allowlist"
  mkdir -p "$(dirname "$list")"
  allowlist_merge "$dir" > "$list.new"
  mv "$list.new" "$list"
  podman network exists "$net" || podman network create --internal "$net" >/dev/null
  id=$(sha256sum < "$list" | cut -c1-16)
  cur=$(podman inspect --format '{{index .Config.Labels "cradle.allowlist"}}' "$name" 2>/dev/null) || cur=""
  running=$(podman inspect --format '{{.State.Running}}' "$name" 2>/dev/null) || running=""
  [[ $cur == "$id" && $running == true ]] && return 0
  podman rm -f "$name" >/dev/null 2>&1 || true
  podman run -d --name "$name" --label "cradle.allowlist=$id" \
    --network podman --network "$net:alias=proxy" \
    --cap-drop=ALL --security-opt=no-new-privileges --read-only --memory=128m \
    -v "$list:/etc/squid/allowlist:ro" "localhost/cradle-proxy:$(cradle_version)" >/dev/null
}

proxy_down() { podman rm -f "cradle-proxy-$(project_key "$1")" >/dev/null 2>&1 || true; }

cmd_net() {
  case ${1:-} in
    log)
      need podman
      local name; name="cradle-proxy-$(project_key "$PWD")"
      podman container exists "$name" || die "no proxy for %s; run: cradle up" "$PWD"
      podman logs "$name" 2>/dev/null | awk '$2 == "TCP_DENIED"' ;;
    *) die "usage: cradle net log" ;;
  esac
}
```

- [ ] **Step 4: Dispatcher.** In `bin/cradle` add `net) group=proxy ;;` (the dispatcher sources `lib/<group>.sh`) and a usage line `  net log            show requests the egress proxy blocked`. Extend `tests/cli.bats` "help lists every command" with `net log` if it enumerates commands.

- [ ] **Step 5: Run** `make check` — Expected: all green, lint clean.

- [ ] **Step 6: Commit** — `git add lib/proxy.sh lib/render.sh bin/cradle tests/proxy.bats tests/cli.bats && git commit -m "Add the per-project egress proxy lifecycle and cradle net log"`

---

### Task 3: Wire the proxy into render, up/down and doctor

**Files:**
- Modify: `lib/render.sh`, `lib/session.sh`, `lib/doctor.sh`, `tests/render.bats`, `tests/session.bats`, `tests/doctor.bats`

**Interfaces:**
- Consumes: `project_key`, `proxy_up DIR`, `proxy_down DIR` (Task 2).
- Produces: devcontainer.json `runArgs` contains `--network=cradle-<key>`; `containerEnv` has `HTTP_PROXY`, `HTTPS_PROXY`, `http_proxy`, `https_proxy` = `http://proxy:3128` and `NO_PROXY`, `no_proxy` = `localhost,127.0.0.1,::1`.

- [ ] **Step 1: Write the failing tests.** Add to `tests/render.bats`:

```bash
@test "the container joins only the project's internal network and uses the proxy" {
  render_devcontainer "$P"
  dc_json | jq -e --arg n "--network=cradle-$(project_key "$P")" '.runArgs | index($n)'
  [ "$(dc_json | jq '[.runArgs[] | select(startswith("--network"))] | length')" -eq 1 ]
  [ "$(dc_json | jq -r .containerEnv.HTTPS_PROXY)" = http://proxy:3128 ]
  [ "$(dc_json | jq -r .containerEnv.https_proxy)" = http://proxy:3128 ]
  [ "$(dc_json | jq -r .containerEnv.NO_PROXY)" = "localhost,127.0.0.1,::1" ]
}
```
Add to `tests/session.bats`:

```bash
@test "up starts the proxy before the dev container" {
  run cradle up
  [ "$status" -eq 0 ]
  p=$(grep -n "podman run -d --name cradle-proxy-" "$STUB_LOG" | cut -d: -f1)
  d=$(grep -n "^devcontainer up" "$STUB_LOG" | cut -d: -f1)
  [ -n "$p" ] && [ "$p" -lt "$d" ]
}

@test "down also removes the proxy" {
  stub_script podman '[[ $1 == ps ]] && echo abc123; exit 0'
  run cradle down
  grep -q "podman rm -f cradle-proxy-" "$STUB_LOG"
}
```
The session setup stub `podman` exits 0 for everything, so `proxy_up` sees an existing network and an empty label and runs the proxy. Add to `tests/doctor.bats`:

```bash
@test "a missing proxy image warns" {
  stub_script podman 'case "$1 $2" in "info "*) echo true ;; "image exists") [[ $3 == cradle-proxy:* ]] && exit 1 ;; esac; exit 0'
  run cradle doctor
  [[ "$output" == *"warn"*"cradle-proxy"*"cradle image build"* ]]
}
```
Run: `bats tests/render.bats tests/session.bats tests/doctor.bats` — Expected: the new tests FAIL.

- [ ] **Step 2: Render.** In `render_devcontainer` pass `--arg key "$(project_key "$dir")"` to jq, append `("--network=cradle-" + $key)` to the `runArgs` array (after `--memory`), and add to `containerEnv`:

```
          HTTP_PROXY: "http://proxy:3128", HTTPS_PROXY: "http://proxy:3128",
          http_proxy: "http://proxy:3128", https_proxy: "http://proxy:3128",
          NO_PROXY: "localhost,127.0.0.1,::1", no_proxy: "localhost,127.0.0.1,::1",
```
(both cases: curl and git read the lower-case names, most other tools the upper-case ones).

- [ ] **Step 3: Session.** In `lib/session.sh` source `lib/proxy.sh` (with its `# shellcheck source=` line); in `cmd_up` call `proxy_up "$PWD"` right after `render_devcontainer "$PWD"` (so `need podman` has run and the allowlist is valid before anything starts); in `cmd_down` call `proxy_down "$PWD"` after stopping the dev container (also when no dev container was running).

- [ ] **Step 4: Doctor.** Generalise `check_image` to both images:

```bash
check_image() {
  have podman || return 0
  local n tag
  for n in cradle-base cradle-proxy; do
    tag="$n:$(cradle_version)"
    if podman image exists "$tag"; then _report ok image "%s" "$tag"
    else _report warn image "%s not built; run: cradle image build" "$tag"; fi
  done
}
```

- [ ] **Step 5: Run** `make check` — Expected: all green.

- [ ] **Step 6: Commit** — `git commit -am "Route the dev container through the project's egress proxy"`

---

### Task 4: Egress checks in the integration test

**Files:**
- Modify: `tests/integration/foundation.sh`, `dev/takeaways.md`, `dev/plans/2026-09-28-cradle-plan-1-foundation.md` (the "open egress" warning: say Plan 2 closed it)

**Interfaces:**
- Consumes: everything above; images `cradle-base` and `cradle-proxy` built.

- [ ] **Step 1: Extend the cleanup** in `foundation.sh`: after removing the dev container, also `podman rm -f` containers named `cradle-proxy-fixture-proj-*` and `podman network rm -f` networks named `cradle-fixture-proj-*` (`podman network ls -q --filter name=...`).

- [ ] **Step 2: Add the checks** (after "bind-mount ownership"):

```bash
check "allowed domain via proxy" eq "$(in_c 'curl -s -o /dev/null -w "%{http_code}" --max-time 20 https://api.github.com/zen')" 200
check "other domain blocked"     absent in_c 'curl -sf --max-time 20 https://example.com >/dev/null'
check "no direct route"          absent in_c 'curl -s --max-time 5 --noproxy "*" https://github.com >/dev/null'
check "net log names the block"  bash -c "'$C' net log | grep -q 'example.com:443'"
check "claude reaches its API"   in_c 'curl -s -o /dev/null --max-time 20 https://api.anthropic.com'
```

- [ ] **Step 3: Run for real** (systemd-run; delete the log first; wait for `EXIT=`): `make integration`. Expected: all checks ok, including the new five and the Plan 1 ones (postcreate's plugin install now goes through the proxy). If a tool fails behind the proxy (npm, uv, gh, claude plugin install), find the domain in `cradle net log`, add it to `proxy/allowlist.txt` only if it belongs to the spec's default set, otherwise note it in the takeaways.

- [ ] **Step 4: Takeaways and plan note.** Record in `dev/takeaways.md` what the smoke and integration runs showed (squid quirks, podman multi-network syntax, which tools needed which domains). In the Plan 1 file replace "Until Plan 2 lands, the dev container has **open egress** …" with "Plan 2 closed egress: the dev container reaches only allowlisted domains through its proxy."

- [ ] **Step 5: Commit** — `git add -A tests/integration dev && git commit -m "Check egress isolation in the integration test"`

---

## Out of scope here

- Removing a project's network on detach (`cradle init --detach`): Plan 3.
- Blocking requests of the tier-2 test runners (they run with `--network none` or on GitHub): Plan 3.
- A TLS-inspecting proxy (path-level rules): not planned; the filter works on domains.
