# cradle Plan 1: Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A working `cradle` CLI that sets up the host, builds the `cradle-base` image, attaches any project, and runs Claude Code inside that project's rootless-podman dev container with the shared config volume, per-repo token and masked secret paths.

**Architecture:** A bash CLI (`bin/cradle`) dispatches to one library file per command group under `lib/`. The dev container is described by the Dev Container spec: `cradle.json` is the single editable source per project, and `lib/render.sh` generates `devcontainer.json` from it on every `cradle up`. The official `devcontainer` CLI runs it on podman. The kit's `config/` is copied into the podman volume `cradle-claude`, which is mounted as `~/.claude` in every container.

**Tech Stack:** bash 5, jq, bats-core 1.14, shellcheck 0.11, podman 6.1 (rootless), `@devcontainers/cli` 0.89.0, act 0.2.89 (spike only), secret-tool (libsecret), gettext.

**Spec:** `dev/specs/2026-09-28-cradle-design.md`

## Scope of this plan and the ones after it

The spec has four parts that can each ship working software. This plan is the
first. The later plans are written after this one lands, because Tasks 2 and 3
here are spikes whose results decide their shape.

| Plan | Delivers | Spec sections |
|---|---|---|
| **1 Foundation (this)** | host setup, doctor, base image, config volume, `init`, render, token, `up/down/claude/shell/push`, foundation integration test | §2, §3.1–3.4, §3.7 (except test, net and approve commands), §5 (doctor), §6 (unit and part of integration) |
| 2 Egress proxy | proxy image, internal network per project (render adds `--network`), allowlist, `cradle net log`, doctor proxy check, proxy security tests | §3.5 |
| 3 Tier-2 tests | cradle-testd, request and validation, act runner (or the fallback from Spike B), `cradle test`, `cradle approve-workflows`, `cradle-request`, `init --detach`, CI template and `.actrc` from `init`, doctor checks for testd | §3.6, §3.2 (CI template) |
| 4 Ship | README (+ German), docs, gettext German catalogue and check, GitHub repo `Gelaende51/cradle` (confirmed first), cradle's own Actions CI, usage scripts reading the volume, pilot (develop cradle in cradle) | §3.3 (usage scripts), §6 (CI and pilot), §7 |

Until Plan 2 lands, the dev container has **open egress**. Don't use it on
untrusted repositories before then.

## Clarifications of the spec made while planning

- A second shared volume, `cradle-punt`, holds `~/.punt-labs`. ethos keeps
  identities there, and they must survive container rebuilds like the Claude
  config.
- `cradle init` writes `.devcontainer/cradle.json` only. `devcontainer.json` is
  regenerated from it on every `cradle up`, and a stored hash detects hand edits.
  This keeps one editable source.
- Git hooks written inside the container go to a per-project directory in the
  data volume (`core.hooksPath` through `GIT_CONFIG_*` environment variables).
  The project's `.git/` is shared with the host, where ethos, bd and punt are
  not installed. Hooks in `.git/hooks` would break host commits.
- User-level rules are loaded through `@`-imports from the kit's `CLAUDE.md`
  (`config/cradle-rules/*.md`), not through a `~/.claude/rules/` directory.
  Imports are documented behaviour.
- The host's desktop notification hook (`~/.claude/hooks/notify.sh`) isn't
  carried into containers (no D-Bus there). A replacement is outside this plan.

## Global Constraints

- Host: EndeavourOS, podman 6.1.2 rootless, user `niemand` uid 1000 / gid 1001, 7 GB RAM.
- All scripts: `#!/usr/bin/env bash`, `set -euo pipefail`, shellcheck-clean (`shellcheck -x`).
- Every user-facing string goes through `msg`, `warn` or `die` in `lib/common.sh` (gettext domain `cradle`, catalogue in `locale/`).
- Pinned versions live only in `image/versions.env`. Nothing else hard-codes a version.
- No container ever gets the podman socket, the host `$HOME` or `.personal/`. Tokens exist only in the host keyring and in process environments.
- Dev container memory limit: `3g` by default (`cradle.json` → `memory`).
- The in-container user is `dev`, uid/gid 1000, home `/home/dev`.
- Kit version: `VERSION` file, starting at `0.1.0`. The image tag is `cradle-base:<VERSION>`.
- Commits: repo-local identity `Vault51 <Gelaende51@users.noreply.github.com>`. Every commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Specs and plans live in `dev/specs/` and `dev/plans/`. Library quirks go into `dev/takeaways.md`.
- License AGPL-3.0 (`LICENSE` in the repo root).

## Review Focus

1. **A project folder with spaces or non-ASCII in its name** (e.g. `file path edit`): the slug must be clean (`file-path-edit`), every path stays quoted, and the container must still start. Pinned in Task 8 (render test) and Task 11 (integration fixture named with a space).
2. **A hand-edited `devcontainer.json`:** `cradle up` must refuse and explain, never overwrite silently. Pinned in Task 8.
3. **A project without a GitHub `origin`** (no remote, GitLab, or a local-only repo): `cradle up` and `claude` must work without a token and without errors. Pinned in Task 10.
4. **A mask path that is missing, a file, or a directory:** a directory gets a tmpfs, a file gets `/dev/null`, and a missing path is skipped, never created on the host. Pinned in Task 8.
5. **Re-running `init` and `config sync`:** no duplicate `.gitignore` block; files the kit dropped are removed from the volume while the user's own files (credentials, transcripts) survive. Pinned in Tasks 7 and 8.

---

## File Structure

| Path | Responsibility |
|---|---|
| `VERSION` | kit version |
| `LICENSE` | AGPL-3.0 text |
| `Makefile` | `check` (`lint` + `test`), `integration` |
| `bin/cradle` | dispatcher |
| `lib/common.sh` | kit root, gettext `msg`/`warn`/`die`, `have`/`need`, version |
| `lib/doctor.sh` | host checks |
| `lib/setup.sh` | one-time host setup (non-sudo actions; prints sudo commands) |
| `lib/image.sh` | `cradle image build` |
| `lib/config.sh` | `cradle config sync` |
| `lib/render.sh` | slug, feature map, generation of `devcontainer.json` |
| `lib/init.sh` | language detection, `cradle.json`, `.gitignore` block |
| `lib/token.sh` | repo slug, keyring access, expiry |
| `lib/session.sh` | `up`, `down`, `claude`, `shell`, `push` |
| `image/versions.env` | pinned versions and sha256 sums |
| `image/Containerfile` | `cradle-base` |
| `image/postcreate.sh` | in-container, once per container: ethos, bd, punt pii hook |
| `image/poststart.sh` | in-container, every start: quarryd, quarry enable, plugins |
| `config/CLAUDE.md` | user-level instructions for the containers, imports rules |
| `config/cradle-rules/*.md` | general rules moved out of the projects |
| `config/settings.json` | user-level Claude settings |
| `config/cradle/plugins.txt` | plugins installed in containers |
| `config/cradle/ethos-identity.yaml` | operator identity for `ethos setup --file` |
| `tests/test_helper.bash` | isolated PATH, stubs |
| `tests/*.bats` | unit tests per library file |
| `tests/integration/foundation.sh` | real podman end-to-end test |
| `dev/takeaways.md` | quirks and findings |
| `dev/spikes/` | Spike A and Spike B fixtures and notes |

---

### Task 0: Operator prerequisites (manual, needs sudo)

The executor can't run sudo. Hand these to the operator and wait until they confirm.

- [ ] **Step 1: Ask the operator to run**

```bash
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 niemand
podman system migrate
sudo pacman -S --needed bats shellcheck act
```

- [ ] **Step 2: Verify**

Run: `grep '^niemand:' /etc/subuid /etc/subgid; bats --version; shellcheck --version | head -2; act --version`
Expected: one line each in subuid and subgid; `Bats 1.14.0`; shellcheck `0.11.0`; `act version 0.2.89`.

---

### Task 1: Repository skeleton, dispatcher, test harness

**Files:**
- Create: `VERSION`, `LICENSE`, `.gitignore`, `Makefile`, `bin/cradle`, `lib/common.sh`, `image/versions.env`, `tests/test_helper.bash`, `tests/cli.bats`, `dev/takeaways.md`

**Interfaces:**
- Produces: `CRADLE_ROOT` (exported); `msg FMT [ARGS]` → stdout; `warn FMT [ARGS]` → stderr prefixed `cradle: `; `die FMT [ARGS]` → warn and exit 1; `_t STRING` → translated string; `have CMD` → 0/1; `need CMD` → dies if missing; `cradle_version` → prints `VERSION`. Test helpers: `setup_isolated_path`, `stub NAME [EXIT] [STDOUT]`, `stub_script NAME LINE...`, `$STUB_LOG`.
- Dispatcher contract: `lib/<group>.sh` defines `cmd_<command>` functions. Groups: doctor→doctor, setup→setup, image→image, config→config, init→init, token→token, up/down/claude/shell/push→session.

- [ ] **Step 1: Create the fixed files**

```bash
cd ~/building_stuff/cradle
echo 0.1.0 > VERSION
cp "$HOME/building_stuff/obsidian_plugins/file path edit/LICENSE" LICENSE   # AGPL-3.0 text
head -1 LICENSE    # expect: GNU AFFERO GENERAL PUBLIC LICENSE (indented)
printf '%s\n' '.cradle/' '*.tmp' > .gitignore
mkdir -p bin lib image config tests/integration dev/spikes locale
```

`image/versions.env` (host-side tool versions for now; Task 6 adds image versions):

```bash
# Pinned versions. The only place versions live. KEY=VALUE, no spaces.
DEVCONTAINER_CLI_VERSION=0.89.0
ACT_VERSION=0.2.89
```

`dev/takeaways.md`:

```markdown
# Takeaways

Distinct challenges, oddities and insights met while building cradle, kept
for reference and for bug reports, feature requests or pull requests upstream.
```

`Makefile`:

```make
SHELL := bash
SH_FILES := bin/cradle $(wildcard lib/*.sh) $(wildcard image/*.sh) $(wildcard tests/integration/*.sh)

.PHONY: check lint test integration
check: lint test
lint:
	shellcheck -x $(SH_FILES)
test:
	bats tests
integration:
	bash tests/integration/foundation.sh
```

- [ ] **Step 2: Write the test harness `tests/test_helper.bash`**

```bash
bats_require_minimum_version 1.5.0

# Shared bats helpers: an isolated PATH whose only commands are basic tools
# plus stubs that log their calls to $STUB_LOG.
CRADLE_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
export CRADLE_ROOT
BASE_TOOLS=(bash env cat grep sed awk jq mkdir rm cp mv ls dirname basename
  readlink realpath tr cut sort head tail wc mktemp date find cmp touch chmod
  id gettext git sha256sum xargs tee)

setup_isolated_path() {
  STUB_BIN="$BATS_TEST_TMPDIR/stubs"
  SYS_BIN="$BATS_TEST_TMPDIR/sys"
  mkdir -p "$STUB_BIN" "$SYS_BIN"
  local t p
  for t in "${BASE_TOOLS[@]}"; do
    p=$(command -v "$t") || continue
    [[ $p == /* ]] && ln -sf "$p" "$SYS_BIN/$t"
  done
  export STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  : > "$STUB_LOG"
  export PATH="$STUB_BIN:$SYS_BIN"
}

# stub NAME [EXIT_CODE] [STDOUT]: a fake command that logs "NAME args".
stub() {
  local name=$1 code=${2:-0} out=${3-}
  {
    printf '#!%s\n' "$SYS_BIN/bash"
    printf 'echo "%s $*" >> "$STUB_LOG"\n' "$name"
    printf 'printf "%%s" %q\n' "$out"
    printf 'exit %d\n' "$code"
  } > "$STUB_BIN/$name"
  chmod +x "$STUB_BIN/$name"
}

# stub_script NAME LINE...: a fake command with a custom body (after logging).
stub_script() {
  local name=$1; shift
  {
    printf '#!%s\n' "$SYS_BIN/bash"
    printf 'echo "%s $*" >> "$STUB_LOG"\n' "$name"
    printf '%s\n' "$@"
  } > "$STUB_BIN/$name"
  chmod +x "$STUB_BIN/$name"
}

cradle() { "$CRADLE_ROOT/bin/cradle" "$@"; }
```

- [ ] **Step 3: Write the failing test `tests/cli.bats`**

```bash
setup() { load test_helper; setup_isolated_path; }

@test "version prints the VERSION file" {
  run cradle version
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$CRADLE_ROOT/VERSION")" ]
}

@test "unknown command exits 2 and prints usage" {
  run cradle frobnicate
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: cradle"* ]]
}

@test "help lists every command" {
  run cradle help
  [ "$status" -eq 0 ]
  for c in doctor setup image config init token up down claude shell push; do
    [[ "$output" == *"$c"* ]]
  done
}
```

- [ ] **Step 4: Run it and see it fail**

Run: `bats tests/cli.bats`
Expected: FAIL, `bin/cradle: No such file or directory`.

- [ ] **Step 5: Implement `lib/common.sh` and `bin/cradle`**

`lib/common.sh`:

```bash
#!/usr/bin/env bash
# Shared helpers for every cradle subcommand.
set -euo pipefail

CRADLE_ROOT=${CRADLE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
export CRADLE_ROOT
export TEXTDOMAIN=cradle
export TEXTDOMAINDIR="$CRADLE_ROOT/locale"

# _t STRING: the translation of STRING, or STRING itself.
_t() { if command -v gettext >/dev/null 2>&1; then gettext "$1"; else printf '%s' "$1"; fi; }

# msg/warn/die FORMAT [ARGS...]: printf-style with a translated format.
# shellcheck disable=SC2059
msg()  { local f; f=$(_t "$1"); shift; printf "$f\n" "$@"; }
# shellcheck disable=SC2059
warn() { local f; f=$(_t "$1"); shift; printf "cradle: $f\n" "$@" >&2; }
die()  { warn "$@"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }
need() { have "$1" || die "missing command: %s" "$1"; }

cradle_version() { cat "$CRADLE_ROOT/VERSION"; }
```

`bin/cradle`:

```bash
#!/usr/bin/env bash
# cradle: containerized development kit. Dispatches to lib/<group>.sh.
set -euo pipefail
CRADLE_ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
export CRADLE_ROOT
# shellcheck source=../lib/common.sh
. "$CRADLE_ROOT/lib/common.sh"

usage() {
  msg "usage: cradle <command> [args]"
  msg "commands: version help doctor setup image config init token up down claude shell push"
}

cmd=${1:-help}
[[ $# -gt 0 ]] && shift
case $cmd in
  version) cradle_version ;;
  help|-h|--help) usage ;;
  doctor|setup|image|config|init|token) group=$cmd ;;
  up|down|claude|shell|push) group=session ;;
  *) usage >&2; exit 2 ;;
esac
if [[ -n ${group:-} ]]; then
  # shellcheck source=/dev/null
  . "$CRADLE_ROOT/lib/$group.sh"
  "cmd_$cmd" "$@"
fi
```

```bash
chmod +x bin/cradle
```

- [ ] **Step 6: Run the tests and lint**

Run: `bats tests/cli.bats && shellcheck -x bin/cradle lib/common.sh`
Expected: `3 tests, 0 failures`; no shellcheck output.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Add the cradle skeleton, dispatcher and test harness" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Spike A: devcontainer CLI on rootless podman

This answers one question: do the spec's `runArgs` work with the devcontainer
CLI on this host? That covers file ownership on the bind mount, dropped
capabilities, the memory limit and the container label that `cradle down` uses.
The output is a note, not code.

**Files:**
- Create: `dev/spikes/devcontainer/.devcontainer/devcontainer.json`, `dev/spikes/devcontainer/NOTES.md`
- Modify: `dev/takeaways.md`

**Interfaces:**
- Produces, for Task 8: the working `--userns` value and the label key that identifies a project's container (expected `devcontainer.local_folder`).

- [ ] **Step 1: Install the devcontainer CLI without sudo and enable the podman socket**

```bash
npm install --prefix ~/.local @devcontainers/cli@0.89.0
devcontainer --version     # expect 0.89.0
systemctl --user enable --now podman.socket
```

- [ ] **Step 2: Write the fixture `dev/spikes/devcontainer/.devcontainer/devcontainer.json`**

```json
{
  "name": "cradle-spike-a",
  "image": "mcr.microsoft.com/devcontainers/base:debian",
  "features": { "ghcr.io/devcontainers/features/node:1": { "version": "lts" } },
  "remoteUser": "vscode",
  "containerUser": "vscode",
  "updateRemoteUserUID": false,
  "runArgs": [
    "--userns=keep-id:uid=1000,gid=1000",
    "--security-opt=no-new-privileges",
    "--cap-drop=ALL",
    "--memory=3g"
  ]
}
```

- [ ] **Step 3: Bring it up and probe**

```bash
cd ~/building_stuff/cradle/dev/spikes/devcontainer
devcontainer up --docker-path podman --workspace-folder "$PWD"
devcontainer exec --docker-path podman --workspace-folder "$PWD" bash -c '
  id; node --version
  grep CapEff /proc/self/status
  cat /sys/fs/cgroup/memory.max
  touch "$PWD/owned-by-container"; ls -ln "$PWD/owned-by-container"
  ls -l /run/podman /run/user/*/podman 2>&1 | head -3'
stat -c '%U:%G %n' owned-by-container        # on the host
podman ps --format '{{.ID}} {{.Labels}}' | grep spike -i
```

Expected:
- `uid=1000(vscode) gid=1000(vscode)`, and a Node version is printed.
- `CapEff: 0000000000000000`
- `memory.max` is `3221225472`. If it prints `max`, memory delegation is missing; record that.
- On the host, the file is owned by `niemand:niemand` or `niemand:<gid 1001 group>`, not by a subuid number.
- No podman socket inside the container.
- The labels include `devcontainer.local_folder=<this dir>`.

- [ ] **Step 4: If ownership is wrong, try the alternative and record which one works**

If the host owner in Step 3 is a number like `100999`, change the `runArgs`
entry to `"--userns=keep-id"`, remove the container
(`podman rm -f $(podman ps -aq --filter label=devcontainer.local_folder="$PWD")`)
and repeat Step 3.

- [ ] **Step 5: Tear down and write the notes**

```bash
podman rm -f $(podman ps -aq --filter label=devcontainer.local_folder="$PWD")
rm -f owned-by-container
```

Write `dev/spikes/devcontainer/NOTES.md` with the command outputs and a
**Result** line naming the working `--userns` value, whether the memory limit
applied, and the label key. Add one entry per surprise to `dev/takeaways.md`
(format: `## <tool>: <one-line finding>`, then 2–4 lines of what happened, the
workaround, and whether it is worth an upstream report).

- [ ] **Step 6: Commit**

```bash
cd ~/building_stuff/cradle
git add dev/spikes/devcontainer dev/takeaways.md
git commit -m "Record Spike A: devcontainer CLI on rootless podman" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

If Step 3 fails in a way Step 4 doesn't fix (the CLI can't talk to podman at
all), stop and report to the operator. The spec's approach A depends on this.

---

### Task 3: Spike B: act on podman

This decides Plan 3's runner. The question: does act run a job on podman with
no socket inside the job and no network?

**Files:**
- Create: `dev/spikes/act/.github/workflows/spike.yml`, `dev/spikes/act/NOTES.md`
- Modify: `dev/takeaways.md`

**Interfaces:**
- Produces, for Plan 3: act works or doesn't, plus the exact flags that worked.

- [ ] **Step 1: Write the fixture workflow**

```yaml
name: spike
on: push
jobs:
  hello:
    runs-on: ubuntu-latest
    steps:
      - run: |
          echo "kernel: $(uname -r)"; id
          if [ -S /var/run/docker.sock ]; then echo SOCKET; else echo NOSOCKET; fi
          if curl -sS -m 5 https://example.com >/dev/null 2>&1; then echo NET; else echo NONET; fi
```

```bash
cd ~/building_stuff/cradle/dev/spikes/act && git init -q && git add -A && git -c user.name=spike -c user.email=spike@localhost commit -qm spike
```

- [ ] **Step 2: Run act against the podman socket**

```bash
export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/podman/podman.sock"
act -W .github/workflows/spike.yml -j hello \
  -P ubuntu-latest=catthehacker/ubuntu:act-latest \
  --container-daemon-socket - --network none 2>&1 | tee act.log | tail -20
```

Expected: the job succeeds and prints `NOSOCKET` and `NONET`.

- [ ] **Step 3: Record**

Write `NOTES.md` with the tail of `act.log`, and a **Result** line: `works`,
`works with changes: <flags>`, or `fails: <reason>`. Add takeaways entries.
Delete `act.log` and the spike's `.git` directory
(`rm -rf act.log .git`); that `.git` is a scratch repo inside this repo, and
removing it is safe.

- [ ] **Step 4: Commit**

```bash
cd ~/building_stuff/cradle
git add dev/spikes/act dev/takeaways.md
git commit -m "Record Spike B: act on podman" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

A failure here does **not** block this plan. It only switches Plan 3 to the
spec's fallback (§8).

---

### Task 4: `cradle doctor`

**Files:**
- Create: `lib/doctor.sh`, `tests/doctor.bats`

**Interfaces:**
- Consumes: `lib/common.sh`; `image/versions.env` (`DEVCONTAINER_CLI_VERSION`).
- Produces: `cmd_doctor` → prints lines `LEVEL  NAME  DETAIL` (LEVEL is `ok`, `warn` or `fail`); exit 1 if any line is `fail`. Test overrides: `CRADLE_ETC` (default `/etc`), `CRADLE_PROC` (default `/proc`), `CRADLE_CGROUP` (default `/sys/fs/cgroup`).

- [ ] **Step 1: Write the failing tests `tests/doctor.bats`**

```bash
setup() {
  load test_helper; setup_isolated_path
  cd "$BATS_TEST_TMPDIR"   # outside any git repo, so the token check (Task 9) stays quiet
  export CRADLE_ETC="$BATS_TEST_TMPDIR/etc" CRADLE_PROC="$BATS_TEST_TMPDIR/proc" CRADLE_CGROUP="$BATS_TEST_TMPDIR/cg"
  mkdir -p "$CRADLE_ETC" "$CRADLE_PROC"
  u=$(id -un); uid=$(id -u)
  echo "$u:100000:65536" > "$CRADLE_ETC/subuid"; echo "$u:100000:65536" > "$CRADLE_ETC/subgid"
  echo "MemAvailable:    6000000 kB" > "$CRADLE_PROC/meminfo"
  mkdir -p "$CRADLE_CGROUP/user.slice/user-$uid.slice/user@$uid.service"
  echo "cpu memory pids" > "$CRADLE_CGROUP/user.slice/user-$uid.slice/user@$uid.service/cgroup.controllers"
  stub_script podman 'case "$1" in info) echo true ;; image) exit 0 ;; esac'
  stub devcontainer 0 "0.89.0"
  stub gh; stub secret-tool; stub act
  stub df 0 $'Avail\n20000000'
}

@test "all checks pass on a healthy host" {
  run cradle doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *fail* ]]
}

@test "missing subuid range fails with the usermod command" {
  : > "$CRADLE_ETC/subuid"
  run cradle doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"fail"*"subuid"*"usermod --add-subuids"* ]]
}

@test "missing act only warns" {
  rm "$STUB_BIN/act"
  run cradle doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"warn"*"act"* ]]
}

@test "low disk space warns" {
  stub df 0 $'Avail\n1000000'
  run cradle doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"warn"*"disk"* ]]
}

@test "devcontainer version mismatch warns" {
  stub devcontainer 0 "0.70.0"
  run cradle doctor
  [[ "$output" == *"warn"*"devcontainer-version"* ]]
}

@test "missing memory delegation warns" {
  echo "cpu pids" > "$CRADLE_CGROUP/user.slice/user-$uid.slice/user@$uid.service/cgroup.controllers"
  run cradle doctor
  [[ "$output" == *"warn"*"cgroup-memory"* ]]
}
```

- [ ] **Step 2: Run and see them fail**

Run: `bats tests/doctor.bats`
Expected: FAIL, `lib/doctor.sh: No such file or directory`.

- [ ] **Step 3: Implement `lib/doctor.sh`**

```bash
#!/usr/bin/env bash
# cradle doctor: host health checks, one line per check.
# shellcheck source=image/versions.env
. "$CRADLE_ROOT/image/versions.env"
DOCTOR_FAIL=0

# _report LEVEL NAME FORMAT [ARGS...]
_report() {
  local level=$1 name=$2 f; f=$(_t "$3"); shift 3
  # shellcheck disable=SC2059
  printf "%-4s  %-20s  $f\n" "$level" "$name" "$@"
  [[ $level == fail ]] && DOCTOR_FAIL=1
  return 0
}

check_subids() {
  local etc=${CRADLE_ETC:-/etc} u; u=$(id -un)
  if grep -q "^$u:" "$etc/subuid" 2>/dev/null && grep -q "^$u:" "$etc/subgid" 2>/dev/null; then
    _report ok subuid "subordinate id ranges configured"
  else
    _report fail subuid "no subuid/subgid range for %s; run: sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 %s && podman system migrate" "$u" "$u"
  fi
}

# check_cmd LEVEL_IF_MISSING COMMAND
check_cmd() {
  if have "$2"; then _report ok "$2" "installed"; else _report "$1" "$2" "not installed; run: cradle setup"; fi
}

check_rootless() {
  have podman || return 0
  if [[ $(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null) == true ]]; then
    _report ok rootless "podman runs rootless"
  else
    _report fail rootless "podman is not running rootless"
  fi
}

check_devcontainer_version() {
  have devcontainer || return 0
  local v; v=$(devcontainer --version 2>/dev/null)
  if [[ $v == "$DEVCONTAINER_CLI_VERSION" ]]; then
    _report ok devcontainer-version "%s" "$v"
  else
    _report warn devcontainer-version "found %s, cradle is tested with %s" "$v" "$DEVCONTAINER_CLI_VERSION"
  fi
}

check_image() {
  have podman || return 0
  local tag; tag="cradle-base:$(cradle_version)"
  if podman image exists "$tag"; then _report ok image "%s" "$tag"
  else _report warn image "%s not built; run: cradle image build" "$tag"; fi
}

check_cgroup_memory() {
  local uid; uid=$(id -u)
  local f="${CRADLE_CGROUP:-/sys/fs/cgroup}/user.slice/user-$uid.slice/user@$uid.service/cgroup.controllers"
  if grep -qw memory "$f" 2>/dev/null; then _report ok cgroup-memory "memory limits are enforced"
  else _report warn cgroup-memory "memory controller not delegated; container memory limits are ignored"; fi
}

check_disk() {
  local kb; kb=$(df --output=avail -k "$HOME" | tail -1 | tr -d ' ')
  if (( kb >= 15 * 1024 * 1024 )); then _report ok disk "%s GB free" "$(( kb / 1024 / 1024 ))"
  else _report warn disk "only %s GB free in \$HOME; images and test runs want 15" "$(( kb / 1024 / 1024 ))"; fi
}

check_ram() {
  local mb; mb=$(awk '/^MemAvailable:/ {print int($2 / 1024)}' "${CRADLE_PROC:-/proc}/meminfo")
  if (( mb >= 3072 )); then _report ok ram "%s MB available" "$mb"
  else _report warn ram "only %s MB available; a dev container is limited to 3072" "$mb"; fi
}

cmd_doctor() {
  check_subids
  check_cmd fail podman
  check_rootless
  check_cgroup_memory
  check_cmd fail devcontainer
  check_devcontainer_version
  check_cmd fail gh
  check_cmd fail secret-tool
  check_cmd fail jq
  check_cmd warn act
  check_image
  check_disk
  check_ram
  return "$DOCTOR_FAIL"
}
```

- [ ] **Step 4: Run the tests and lint**

Run: `bats tests/doctor.bats && shellcheck -x lib/doctor.sh`
Expected: `6 tests, 0 failures`; no shellcheck output.

- [ ] **Step 5: Run it for real**

Run: `bin/cradle doctor`
Expected: `ok` for subuid, podman, rootless, devcontainer, gh, secret-tool, jq and act; `warn image` (not built yet). Note the other results in the commit message body if they differ.

- [ ] **Step 6: Commit**

```bash
git add lib/doctor.sh tests/doctor.bats
git commit -m "Add cradle doctor" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: `cradle setup`

**Files:**
- Create: `lib/setup.sh`, `tests/setup.bats`

**Interfaces:**
- Consumes: `check_subids` and `_report` are not reused. Setup has its own flow, but reads the same `versions.env`.
- Produces: `cmd_setup [--yes]`: prints each missing piece with the command that fixes it. With `--yes` it runs the actions that need no sudo: installing the devcontainer CLI into `~/.local`, and enabling `podman.socket`. It never calls sudo.

- [ ] **Step 1: Write the failing tests `tests/setup.bats`**

```bash
setup() {
  load test_helper; setup_isolated_path
  export CRADLE_ETC="$BATS_TEST_TMPDIR/etc"; mkdir -p "$CRADLE_ETC"
  u=$(id -un)
  echo "$u:100000:65536" > "$CRADLE_ETC/subuid"; echo "$u:100000:65536" > "$CRADLE_ETC/subgid"
  stub podman; stub npm; stub bats; stub shellcheck; stub act
  stub_script systemctl 'exit 0'
}

@test "installs the devcontainer CLI into ~/.local with --yes" {
  run cradle setup --yes
  [ "$status" -eq 0 ]
  grep -q "npm install --prefix $HOME/.local @devcontainers/cli@0.89.0" "$STUB_LOG"
}

@test "without --yes it only prints the command" {
  run cradle setup
  [ "$status" -eq 0 ]
  [[ "$output" == *"npm install --prefix"* ]]
  run ! grep -q "^npm install" "$STUB_LOG"
}

@test "prints but never runs sudo commands" {
  : > "$CRADLE_ETC/subuid"; rm "$STUB_BIN/act"
  run cradle setup --yes
  [[ "$output" == *"sudo usermod --add-subuids"* ]]
  [[ "$output" == *"sudo pacman -S --needed"*"act"* ]]
  run ! grep -q "^sudo" "$STUB_LOG"
}

@test "enables the podman socket when it is inactive" {
  stub_script systemctl '[[ "$*" == *is-active* ]] && exit 3; exit 0'
  run cradle setup --yes
  grep -q "systemctl --user enable --now podman.socket" "$STUB_LOG"
}
```

- [ ] **Step 2: Run and see them fail**

Run: `bats tests/setup.bats`
Expected: FAIL, `lib/setup.sh: No such file or directory`.

- [ ] **Step 3: Implement `lib/setup.sh`**

```bash
#!/usr/bin/env bash
# cradle setup: one-time host preparation. Runs only actions that need no sudo;
# prints the sudo commands for the operator.
# shellcheck source=image/versions.env
. "$CRADLE_ROOT/image/versions.env"

# _act YES DESCRIPTION COMMAND...: run COMMAND when YES=1, else print it.
_act() {
  local yes=$1 what=$2; shift 2
  if (( yes )); then msg "%s" "$what"; "$@"; else msg "%s: %s" "$what" "$*"; fi
}

cmd_setup() {
  local yes=0 u sudo_needed=()
  [[ ${1:-} == --yes ]] && yes=1
  u=$(id -un)
  local etc=${CRADLE_ETC:-/etc}
  if ! grep -q "^$u:" "$etc/subuid" 2>/dev/null || ! grep -q "^$u:" "$etc/subgid" 2>/dev/null; then
    sudo_needed+=("sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $u && podman system migrate")
  fi
  local missing_pkgs=() p
  for p in podman bats shellcheck act; do have "$p" || missing_pkgs+=("$p"); done
  ((${#missing_pkgs[@]})) && sudo_needed+=("sudo pacman -S --needed ${missing_pkgs[*]}")

  if ! have devcontainer; then
    _act "$yes" "install the devcontainer CLI" npm install --prefix "$HOME/.local" "@devcontainers/cli@$DEVCONTAINER_CLI_VERSION"
  fi
  if ! systemctl --user is-active --quiet podman.socket; then
    _act "$yes" "enable the podman socket (host only, used by act)" systemctl --user enable --now podman.socket
  fi

  if ((${#sudo_needed[@]})); then
    msg "run these yourself (they need sudo):"
    printf '  %s\n' "${sudo_needed[@]}"
  fi
  msg "then run: cradle image build && cradle doctor"
}
```

- [ ] **Step 4: Run the tests and lint**

Run: `bats tests/setup.bats && shellcheck -x lib/setup.sh`
Expected: `4 tests, 0 failures`; no shellcheck output.

- [ ] **Step 5: Commit**

```bash
git add lib/setup.sh tests/setup.bats
git commit -m "Add cradle setup" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: The `cradle-base` image and `cradle image build`

**Files:**
- Modify: `image/versions.env`
- Create: `image/Containerfile`, `image/postcreate.sh`, `image/poststart.sh`, `lib/image.sh`, `tests/image.bats`
- Modify: `dev/takeaways.md`

**Interfaces:**
- Consumes: `versions.env`.
- Produces: `cmd_image build` builds tag `cradle-base:<VERSION>` via the temporary tag `cradle-base:building-<pid>`, retagging only on success. In-image contract used by Task 8: user `dev` (1000:1000); `/usr/local/share/cradle/postcreate.sh` and `poststart.sh`; env var `CRADLE_WORKSPACE` expected from the container; tools `claude`, `gh`, `uv`, `punt`, `quarry`, `quarryd`, `bd`, `dolt`, `ethos` on PATH.

- [ ] **Step 1: Pin the image versions and their checksums**

Append to `image/versions.env`:

```bash
CLAUDE_CODE_VERSION=2.1.283
GH_VERSION=2.101.0
UV_VERSION=0.12.18
PYTHON_VERSION=3.13
PUNT_KIT_VERSION=0.17.5
QUARRY_VERSION=3.4.0
ETHOS_VERSION=4.19.1
BEADS_VERSION=1.3.0
DOLT_VERSION=2.3.5
```

Compute each download's sha256 and look at the archive layout:

```bash
. image/versions.env
declare -A U=(
  [GH]="https://github.com/cli/cli/releases/download/v$GH_VERSION/gh_${GH_VERSION}_linux_amd64.tar.gz"
  [UV]="https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-x86_64-unknown-linux-gnu.tar.gz"
  [ETHOS]="https://github.com/punt-labs/ethos/releases/download/v$ETHOS_VERSION/ethos-linux-amd64"
  [BEADS]="https://github.com/gastownhall/beads/releases/download/v$BEADS_VERSION/beads_${BEADS_VERSION}_linux_amd64.tar.gz"
  [DOLT]="https://github.com/dolthub/dolt/releases/download/v$DOLT_VERSION/dolt-linux-amd64.tar.gz")
for k in GH UV ETHOS BEADS DOLT; do
  f=$(mktemp); curl -fsSL "${U[$k]}" -o "$f"
  echo "${k}_SHA256=$(sha256sum "$f" | cut -d' ' -f1)" >> image/versions.env
  case ${U[$k]} in *.tar.gz) echo "--- $k"; tar -tzf "$f" | grep -E '(^|/)(gh|uv|uvx|bd|dolt)$' ;; esac
  rm -f "$f"
done
```

Expected: five `*_SHA256=` lines appended. The listing shows the binary paths.
The Containerfile below assumes `gh_<v>_linux_amd64/bin/gh`,
`uv-x86_64-unknown-linux-gnu/uv{,x}`, `bd` at the archive root and
`dolt-linux-amd64/bin/dolt`. If a listing differs, change that `install` path
in Step 2 to match, and add a takeaways entry.

- [ ] **Step 2: Write `image/Containerfile`**

```dockerfile
# cradle-base: the image every project's dev container starts from.
FROM mcr.microsoft.com/devcontainers/base:debian

ARG CLAUDE_CODE_VERSION GH_VERSION UV_VERSION PYTHON_VERSION PUNT_KIT_VERSION \
    QUARRY_VERSION ETHOS_VERSION BEADS_VERSION DOLT_VERSION
ARG GH_SHA256 UV_SHA256 ETHOS_SHA256 BEADS_SHA256 DOLT_SHA256
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# The devcontainers base ships user vscode (1000:1000); rename it to dev, drop sudo.
RUN usermod -l dev -d /home/dev -m vscode && groupmod -n dev vscode \
 && rm -f /etc/sudoers.d/vscode \
 && apt-get update \
 && apt-get install -y --no-install-recommends ripgrep fd-find jq shellcheck gettext procps ca-certificates curl git \
 && ln -s /usr/bin/fdfind /usr/local/bin/fd \
 && apt-get purge -y sudo && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*

RUN fetch() { curl -fsSL "$1" -o "$2" && echo "$3  $2" | sha256sum -c -; } \
 && fetch "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" /tmp/gh.tgz "$GH_SHA256" \
 && tar -xzf /tmp/gh.tgz -C /tmp && install -m755 "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh \
 && fetch "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz" /tmp/uv.tgz "$UV_SHA256" \
 && tar -xzf /tmp/uv.tgz -C /tmp && install -m755 /tmp/uv-x86_64-unknown-linux-gnu/uv /tmp/uv-x86_64-unknown-linux-gnu/uvx /usr/local/bin/ \
 && fetch "https://github.com/punt-labs/ethos/releases/download/v${ETHOS_VERSION}/ethos-linux-amd64" /tmp/ethos "$ETHOS_SHA256" \
 && install -m755 /tmp/ethos /usr/local/bin/ethos \
 && fetch "https://github.com/gastownhall/beads/releases/download/v${BEADS_VERSION}/beads_${BEADS_VERSION}_linux_amd64.tar.gz" /tmp/bd.tgz "$BEADS_SHA256" \
 && tar -xzf /tmp/bd.tgz -C /tmp && install -m755 /tmp/bd /usr/local/bin/bd \
 && fetch "https://github.com/dolthub/dolt/releases/download/v${DOLT_VERSION}/dolt-linux-amd64.tar.gz" /tmp/dolt.tgz "$DOLT_SHA256" \
 && tar -xzf /tmp/dolt.tgz -C /tmp && install -m755 /tmp/dolt-linux-amd64/bin/dolt /usr/local/bin/dolt \
 && rm -rf /tmp/*

COPY postcreate.sh poststart.sh /usr/local/share/cradle/
RUN chmod 755 /usr/local/share/cradle/*.sh

USER dev
ENV PATH=/home/dev/.local/bin:$PATH \
    UV_TOOL_BIN_DIR=/home/dev/.local/bin \
    DISABLE_AUTOUPDATER=1
RUN curl -fsSL https://claude.ai/install.sh | bash -s "${CLAUDE_CODE_VERSION}" \
 && uv python install "${PYTHON_VERSION}" \
 && uv tool install --python "${PYTHON_VERSION}" "punt-kit==${PUNT_KIT_VERSION}" \
 && uv tool install --python "${PYTHON_VERSION}" "punt-quarry==${QUARRY_VERSION}"
# quarry's embedding model, fetched at build time so runtime needs no Hugging Face access.
# Uses quarry's own download method (embeddings.py); pinned with QUARRY_VERSION.
RUN "$HOME/.local/share/uv/tools/punt-quarry/bin/python" -c \
    'from quarry.embeddings import OnnxEmbeddingBackend as B; print(B.download_model_files())'
ENV HF_HUB_OFFLINE=1
WORKDIR /home/dev
```

- [ ] **Step 3: Write `image/postcreate.sh` and `image/poststart.sh`**

`image/postcreate.sh`:

```bash
#!/usr/bin/env bash
# Runs once when a project's dev container is created: per-repo tool enablement.
# Hooks go to core.hooksPath in the data volume (set by the container env), never
# into the host-shared .git/hooks.
set -euo pipefail
cd "${CRADLE_WORKSPACE:?CRADLE_WORKSPACE not set}"
hooks=$(git config core.hooksPath)
mkdir -p "$hooks"

# git authenticates to GitHub through gh, which reads GH_TOKEN at call time (no stored copy).
git config --global credential.https://github.com.helper '!gh auth git-credential'

ethos whoami >/dev/null 2>&1 || ethos setup --file "$HOME/.claude/cradle/ethos-identity.yaml"
ethos enable
[ -d .beads ] || bd init

# punt pii runs first in pre-commit, so a later "exit 0" in a chained section cannot skip it.
pc="$hooks/pre-commit"
[ -f "$pc" ] || printf '#!/bin/sh\n' > "$pc"
if ! grep -q '# CRADLE PII BEGIN' "$pc"; then
  sed -i '1a # CRADLE PII BEGIN\npunt pii --staged || exit 1\n# CRADLE PII END' "$pc"
fi
chmod +x "$pc"
```

`image/poststart.sh`:

```bash
#!/usr/bin/env bash
# Runs on every container start: quarryd, per-project quarry enablement, plugins.
set -euo pipefail
state="$HOME/.local/share/cradle"
mkdir -p "$state/log"
cd "${CRADLE_WORKSPACE:?CRADLE_WORKSPACE not set}"

if ! pgrep -x quarryd >/dev/null; then
  nohup quarryd >"$state/log/quarryd.log" 2>&1 &
fi
for _ in $(seq 60); do quarry status >/dev/null 2>&1 && break; sleep 1; done
if [ ! -f "$state/quarry-enabled" ]; then
  quarry enable && touch "$state/quarry-enabled"
fi

list="$HOME/.claude/cradle/plugins.txt"
if [ -f "$list" ]; then
  claude plugin marketplace add anthropics/claude-plugins-official >>"$state/log/plugins.log" 2>&1 || true
  while read -r p; do
    case $p in ''|'#'*) continue ;; esac
    claude plugin install "$p" >>"$state/log/plugins.log" 2>&1 || echo "failed: $p" >>"$state/log/plugins.log"
  done < "$list"
fi
```

- [ ] **Step 4: Write the failing tests `tests/image.bats`**

```bash
setup() { load test_helper; setup_isolated_path; }

@test "builds with every pinned version as a build arg and retags on success" {
  stub podman
  run cradle image build
  [ "$status" -eq 0 ]
  grep -q "podman build .*--build-arg CLAUDE_CODE_VERSION=2.1.283" "$STUB_LOG"
  grep -q "podman build .*--build-arg GH_SHA256=" "$STUB_LOG"
  grep -q "podman tag cradle-base:building-[0-9]* cradle-base:$(cat "$CRADLE_ROOT/VERSION")" "$STUB_LOG"
}

@test "a failed build leaves the old tag alone" {
  stub_script podman '[[ $1 == build ]] && exit 1; exit 0'
  run cradle image build
  [ "$status" -eq 1 ]
  [[ "$output" == *"left unchanged"* ]]
  run ! grep -q "podman tag" "$STUB_LOG"
}

@test "unknown subcommand prints usage" {
  stub podman
  run cradle image frob
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage: cradle image build"* ]]
}
```

- [ ] **Step 5: Run and see them fail**

Run: `bats tests/image.bats`
Expected: FAIL, `lib/image.sh: No such file or directory`.

- [ ] **Step 6: Implement `lib/image.sh`**

```bash
#!/usr/bin/env bash
# cradle image build: build cradle-base, switching the tag only on success.

_build_args() {
  local k v
  while IFS='=' read -r k v; do
    [[ -z $k || $k == \#* ]] && continue
    printf '%s\n' --build-arg "$k=$v"
  done < "$CRADLE_ROOT/image/versions.env"
}

image_build() {
  need podman
  local tag tmp args=()
  tag="cradle-base:$(cradle_version)"
  tmp="cradle-base:building-$$"
  mapfile -t args < <(_build_args)
  if ! podman build "${args[@]}" -t "$tmp" -f "$CRADLE_ROOT/image/Containerfile" "$CRADLE_ROOT/image"; then
    podman rmi -f "$tmp" >/dev/null 2>&1 || true
    die "image build failed; %s left unchanged" "$tag"
  fi
  podman tag "$tmp" "$tag"
  podman rmi "$tmp" >/dev/null
  msg "built %s" "$tag"
}

cmd_image() {
  case ${1:-} in
    build) image_build ;;
    *) die "usage: cradle image build" ;;
  esac
}
```

- [ ] **Step 7: Run the tests and lint**

Run: `bats tests/image.bats && shellcheck -x lib/image.sh image/postcreate.sh image/poststart.sh`
Expected: `3 tests, 0 failures`; no shellcheck output.

- [ ] **Step 8: Build for real and verify the tools**

```bash
bin/cradle image build
podman run --rm localhost/cradle-base:0.1.0 bash -lc '
  id; claude --version; gh --version | head -1; uv --version
  punt version; quarry --version; bd --version; dolt version | head -1; ethos --version
  ls ~/.cache/huggingface/hub | head'
```

Expected: `uid=1000(dev) gid=1000(dev)`; `2.1.283 (Claude Code)`;
`gh version 2.101.0`; `uv 0.12.18`; punt `0.17.5`; quarry `3.4.0`; bd `1.3.0`;
dolt `2.3.5`; ethos `4.19.1`; a `models--…arctic-embed…` directory. If a tool
reports a different version flag (e.g. `ethos version`), use that one, and note
the form in takeaways.

- [ ] **Step 9: Measure quarryd in the image**

```bash
podman run --rm --memory=3g localhost/cradle-base:0.1.0 bash -lc '
  quarryd >/tmp/q.log 2>&1 & for i in $(seq 60); do quarry status >/dev/null 2>&1 && break; sleep 1; done
  quarry status; mkdir -p /tmp/p && cp -r /usr/share/doc/git /tmp/p/ && quarry register /tmp/p && quarry sync
  sleep 20; ps -o rss=,cmd= -C quarryd; tail -5 /tmp/q.log'
```

Expected: `quarry status` answers and RSS is printed. Record the RSS in
`dev/takeaways.md`. If it's above 1.5 GB, raise the default `memory` to `4g`
in Task 8's `cradle.json` default, and say so in the commit message. If
`quarry status` never answers, record `/tmp/q.log`'s tail in takeaways and stop
to consult the operator (quarry is then removed from `poststart.sh` for v1).

- [ ] **Step 10: Commit**

```bash
git add image lib/image.sh tests/image.bats dev/takeaways.md
git commit -m "Add the cradle-base image and cradle image build" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Kit configuration and `cradle config sync`

**Files:**
- Create: `config/CLAUDE.md`, `config/cradle-rules/{planning,project_guidelines,orchestrator,extension_guidelines,ux_guidelines}.md`, `config/settings.json`, `config/cradle/plugins.txt`, `config/cradle/ethos-identity.yaml`, `lib/config.sh`, `tests/config.bats`
- Modify: `lib/doctor.sh`, `tests/doctor.bats`

**Interfaces:**
- Consumes: podman volumes.
- Produces: `cmd_config sync`; `config_is_current` → 0 when every kit file equals its copy in the volume; `config_volume_path` → prints the host mountpoint of volume `cradle-claude`, creating it if absent. `CRADLE_CONFIG_DIR` (default `$CRADLE_ROOT/config`) is the source. The manifest is `<volume>/.cradle-manifest` (one relative path per line). Files in the volume: `CLAUDE.md`, `cradle-rules/*`, `settings.json`, `cradle/plugins.txt`, `cradle/ethos-identity.yaml`, which Task 6's scripts read.

- [ ] **Step 1: Create the configuration**

```bash
L="$HOME/building_stuff/obsidian_plugins/file path edit/.claude/rules"
mkdir -p config/cradle-rules config/cradle
cp "$L/project_guidelines.md" "$L/orchestrator.md" "$L/extension_guidelines.md" "$L/ux_guidelines.md" config/cradle-rules/
```

`config/cradle-rules/planning.md` (the planning bullets from the projects' `CLAUDE.md`, verbatim):

```markdown
# Planning
- Wenn im Plan Modus immer Rückfragen stellen bevor mit der Implementierung begeonnen wird
- always check if a solution for the problem already exists or if a solution for a similar problem can be adopted
```

`config/CLAUDE.md`:

```markdown
# cradle dev container

- You run inside a rootless podman dev container managed by cradle. The project is at `$CRADLE_WORKSPACE`.
- Host credentials are not available here: `.personal/` is masked. When a task needs an account or a secret, ask the operator.
- GitHub: `gh` and `git push` use a token for this repository only. It cannot change `.github/workflows/`: commit workflow changes and ask the operator to run `cradle push` on the host.
- Tests: unit tests, lint and build run here. Anything that starts the built software runs in isolated test containers or on GitHub Actions.
- Host-only tools (the usage scripts under `~/building_stuff/scripts`, Obsidian, browsers) are not reachable from here.

@cradle-rules/planning.md
@cradle-rules/project_guidelines.md
@cradle-rules/orchestrator.md
@cradle-rules/extension_guidelines.md
@cradle-rules/ux_guidelines.md
```

`config/settings.json`:

```json
{
  "model": "opus",
  "permissions": { "defaultMode": "auto" }
}
```

`config/cradle/plugins.txt`:

```text
# Plugins installed in every cradle container (claude-plugins-official).
superpowers@claude-plugins-official
feature-dev@claude-plugins-official
pr-review-toolkit@claude-plugins-official
code-review@claude-plugins-official
remember@claude-plugins-official
skill-creator@claude-plugins-official
```

`config/cradle/ethos-identity.yaml`:

```yaml
name: Vault51
handle: vault51
email: Gelaende51@users.noreply.github.com
github: Gelaende51
```

- [ ] **Step 2: Write the failing tests `tests/config.bats`**

```bash
setup() {
  load test_helper; setup_isolated_path
  VOL="$BATS_TEST_TMPDIR/vol"; mkdir -p "$VOL"
  export CRADLE_CONFIG_DIR="$BATS_TEST_TMPDIR/config"
  mkdir -p "$CRADLE_CONFIG_DIR/cradle-rules"
  echo "top" > "$CRADLE_CONFIG_DIR/CLAUDE.md"
  echo "rule" > "$CRADLE_CONFIG_DIR/cradle-rules/a.md"
  stub_script podman \
    'case "$1 $2" in "volume exists") exit 0 ;; "volume inspect") echo '"$VOL"' ;; esac'
}

@test "sync copies every kit file and writes a manifest" {
  run cradle config sync
  [ "$status" -eq 0 ]
  [ "$(cat "$VOL/CLAUDE.md")" = top ]
  [ "$(cat "$VOL/cradle-rules/a.md")" = rule ]
  [ "$(sort "$VOL/.cradle-manifest")" = "$(printf 'CLAUDE.md\ncradle-rules/a.md')" ]
}

@test "files dropped from the kit are removed, user files survive" {
  cradle config sync
  echo secret > "$VOL/.credentials.json"
  rm "$CRADLE_CONFIG_DIR/cradle-rules/a.md"
  run cradle config sync
  [ "$status" -eq 0 ]
  [ ! -e "$VOL/cradle-rules/a.md" ]
  [ "$(cat "$VOL/.credentials.json")" = secret ]
}

@test "creates the volume when it does not exist" {
  stub_script podman \
    'case "$1 $2" in "volume exists") exit 1 ;; "volume create") exit 0 ;; "volume inspect") echo '"$VOL"' ;; esac'
  run cradle config sync
  [ "$status" -eq 0 ]
  grep -q "podman volume create cradle-claude" "$STUB_LOG"
}
```

- [ ] **Step 3: Run and see them fail**

Run: `bats tests/config.bats`
Expected: FAIL, `lib/config.sh: No such file or directory`.

- [ ] **Step 4: Implement `lib/config.sh`**

```bash
#!/usr/bin/env bash
# cradle config sync: copy the kit's config into the shared volume cradle-claude.
# Only files listed in the manifest are ever replaced or removed.

config_volume_path() {
  podman volume exists cradle-claude || podman volume create cradle-claude >/dev/null
  podman volume inspect cradle-claude --format '{{.Mountpoint}}'
}

config_sync() {
  need podman
  local src=${CRADLE_CONFIG_DIR:-$CRADLE_ROOT/config} dst manifest f
  dst=$(config_volume_path)
  manifest="$dst/.cradle-manifest"
  if [[ -f $manifest ]]; then
    while IFS= read -r f; do
      [[ -e $src/$f ]] || rm -f "$dst/$f"
    done < "$manifest"
  fi
  (cd "$src" && find . -type f -printf '%P\n' | sort) > "$manifest.new"
  while IFS= read -r f; do
    mkdir -p "$dst/$(dirname "$f")"
    cp "$src/$f" "$dst/$f"
  done < "$manifest.new"
  mv "$manifest.new" "$manifest"
  msg "synced %s files into volume cradle-claude" "$(wc -l < "$manifest")"
}

# config_is_current: 0 when every kit file equals its copy in the volume.
config_is_current() {
  local src=${CRADLE_CONFIG_DIR:-$CRADLE_ROOT/config} dst f
  podman volume exists cradle-claude || return 1
  dst=$(podman volume inspect cradle-claude --format '{{.Mountpoint}}')
  while IFS= read -r f; do
    cmp -s "$src/$f" "$dst/$f" || return 1
  done < <(cd "$src" && find . -type f -printf '%P\n')
}

cmd_config() {
  case ${1:-} in
    sync) config_sync ;;
    *) die "usage: cradle config sync" ;;
  esac
}
```

- [ ] **Step 5: Run the tests and lint**

Run: `bats tests/config.bats && shellcheck -x lib/config.sh`
Expected: `3 tests, 0 failures`; no shellcheck output.

- [ ] **Step 6: Report config drift in `cradle doctor`**

Append to `tests/doctor.bats`:

```bash
@test "stale config volume warns" {
  export CRADLE_CONFIG_DIR="$BATS_TEST_TMPDIR/kitcfg"; mkdir -p "$CRADLE_CONFIG_DIR"
  echo new > "$CRADLE_CONFIG_DIR/CLAUDE.md"
  mkdir -p "$BATS_TEST_TMPDIR/vol"; echo old > "$BATS_TEST_TMPDIR/vol/CLAUDE.md"
  stub_script podman 'case "$1 $2" in "info "*) echo true ;; "volume inspect") echo '"$BATS_TEST_TMPDIR/vol"' ;; esac; exit 0'
  run cradle doctor
  [[ "$output" == *"warn"*"config"*"cradle config sync"* ]]
}
```

In `lib/doctor.sh`, add below the `versions.env` source line:

```bash
# shellcheck source=lib/config.sh
. "$CRADLE_ROOT/lib/config.sh"
```

add the check:

```bash
check_config() {
  have podman || return 0
  if config_is_current; then _report ok config "config volume matches the kit"
  else _report warn config "config volume is missing or stale; run: cradle config sync"; fi
}
```

and call `check_config` in `cmd_doctor` right after `check_image`.

Run: `bats tests/doctor.bats tests/config.bats && shellcheck -x lib/doctor.sh lib/config.sh`
Expected: `10 tests, 0 failures`; no shellcheck output.

- [ ] **Step 7: Sync for real**

Run: `bin/cradle config sync && ls "$(podman volume inspect cradle-claude --format '{{.Mountpoint}}')"`
Expected: `synced 9 files into volume cradle-claude`, and `CLAUDE.md cradle cradle-rules settings.json` listed.

- [ ] **Step 8: Commit**

```bash
git add config lib/config.sh lib/doctor.sh tests/config.bats tests/doctor.bats
git commit -m "Add the kit config and cradle config sync" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: `cradle init` and rendering `devcontainer.json`

**Files:**
- Create: `lib/render.sh`, `lib/init.sh`, `tests/render.bats`, `tests/init.bats`

**Interfaces:**
- Consumes: the Spike A result (the `--userns` value; replace `keep-id:uid=1000,gid=1000` below if Spike A chose `keep-id`), and the Task 6 RSS decision for the default memory.
- Produces:
  - `project_slug DIR` → prints the slug.
  - `render_devcontainer DIR` → writes `DIR/.devcontainer/devcontainer.json` (first line a `//` comment, then JSON) and `.cradle-hash`; dies if the file was hand-edited.
  - `detect_languages DIR` → JSON array.
  - `cmd_init [--force]`.
  - `cradle.json` schema: `{languages: [string], features: {}, maskPaths: [string], memory: string, allowedDomains: [], testJobs: []}`. The last two are read in Plans 2 and 3.

- [ ] **Step 1: Write the failing tests `tests/render.bats`**

```bash
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
```

- [ ] **Step 2: Write the failing tests `tests/init.bats`**

```bash
setup() {
  load test_helper; setup_isolated_path
  P="$BATS_TEST_TMPDIR/proj"; mkdir -p "$P"; git -C "$P" init -q
  cd "$P"
}

@test "detects node and go and writes cradle.json" {
  echo '{}' > package.json; echo 'module x' > go.mod
  run cradle init
  [ "$status" -eq 0 ]
  [ "$(jq -c .languages .devcontainer/cradle.json)" = '["node","go"]' ]
  [ "$(jq -c .maskPaths .devcontainer/cradle.json)" = '[".personal"]' ]
}

@test "the gitignore block is added once, even without a trailing newline" {
  printf 'node_modules' > .gitignore
  cradle init; cradle init --force
  [ "$(grep -c '^# >>> cradle$' .gitignore)" -eq 1 ]
  grep -qx 'node_modules' .gitignore
  grep -qx '.cradle/' .gitignore
}

@test "an existing cradle.json is kept without --force" {
  cradle init
  echo '{"languages":["rust"]}' > .devcontainer/cradle.json
  run cradle init
  [ "$status" -eq 1 ]
  [ "$(jq -c .languages .devcontainer/cradle.json)" = '["rust"]' ]
}

@test "refuses outside a git repository" {
  cd "$BATS_TEST_TMPDIR"; mkdir plain; cd plain
  run cradle init
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a git repository"* ]]
}
```

- [ ] **Step 3: Run and see them fail**

Run: `bats tests/render.bats tests/init.bats`
Expected: FAIL, `lib/render.sh` / `lib/init.sh`: `No such file or directory`.

- [ ] **Step 4: Implement `lib/render.sh`**

```bash
#!/usr/bin/env bash
# Generate .devcontainer/devcontainer.json from .devcontainer/cradle.json,
# the single editable source. A stored hash detects hand edits.

FEATURES_JSON='{
  "node":   {"ghcr.io/devcontainers/features/node:1":   {"version": "lts"}},
  "python": {"ghcr.io/devcontainers/features/python:1": {"version": "3.13"}},
  "go":     {"ghcr.io/devcontainers/features/go:1":     {}},
  "rust":   {"ghcr.io/devcontainers/features/rust:1":   {}},
  "java":   {"ghcr.io/devcontainers/features/java:1":   {}}
}'

project_slug() {
  local b; b=$(basename "$1"); b=${b,,}
  b=$(printf '%s' "$b" | LC_ALL=C tr -c 'a-z0-9' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//')
  printf '%s' "${b:-project}"
}

# _mask_args DIR WORKSPACE: one podman run argument per existing mask path.
_mask_args() {
  local dir=$1 ws=$2 m
  while IFS= read -r m; do
    if [[ -d $dir/$m ]]; then printf '%s\n' "--tmpfs=$ws/$m:size=1k,mode=0500"
    elif [[ -f $dir/$m ]]; then printf '%s\n' "--volume=/dev/null:$ws/$m:ro"
    fi
  done < <(jq -r '.maskPaths[]?' "$dir/.devcontainer/cradle.json")
}

render_devcontainer() {
  local dir=$1 cfg out hashf slug ws masks
  cfg="$dir/.devcontainer/cradle.json"
  out="$dir/.devcontainer/devcontainer.json"
  hashf="$dir/.devcontainer/.cradle-hash"
  [[ -f $cfg ]] || die "no .devcontainer/cradle.json in %s; run: cradle init" "$dir"
  if [[ -f $out ]]; then
    [[ -f $hashf && $(sha256sum < "$out" | cut -d' ' -f1) == "$(cat "$hashf")" ]] \
      || die "%s was edited by hand; move the change into cradle.json, then delete devcontainer.json" "$out"
  fi
  slug=$(project_slug "$dir")
  ws="/workspaces/$slug"
  masks=$(_mask_args "$dir" "$ws" | jq -R . | jq -s .)
  {
    printf '// generated by cradle %s from cradle.json; edit cradle.json, not this file\n' "$(cradle_version)"
    jq -n --slurpfile cfg "$cfg" --argjson fmap "$FEATURES_JSON" --argjson masks "$masks" \
      --arg slug "$slug" --arg ws "$ws" --arg image "localhost/cradle-base:$(cradle_version)" '
      $cfg[0] as $c | {
        name: ("cradle-" + $slug),
        image: $image,
        features: ((reduce ($c.languages // [])[] as $l ({}; . + ($fmap[$l] // {}))) + ($c.features // {})),
        remoteUser: "dev",
        containerUser: "dev",
        updateRemoteUserUID: false,
        workspaceFolder: $ws,
        workspaceMount: ("source=${localWorkspaceFolder},target=" + $ws + ",type=bind"),
        runArgs: (["--userns=keep-id:uid=1000,gid=1000", "--security-opt=no-new-privileges",
                   "--cap-drop=ALL", ("--memory=" + ($c.memory // "3g"))] + $masks),
        mounts: ["source=cradle-claude,target=/home/dev/.claude,type=volume",
                 "source=cradle-punt,target=/home/dev/.punt-labs,type=volume",
                 ("source=cradle-" + $slug + "-data,target=/home/dev/.local/share/cradle,type=volume")],
        containerEnv: {
          CLAUDE_CONFIG_DIR: "/home/dev/.claude",
          CRADLE_WORKSPACE: $ws,
          QUARRY_ROOT: "/home/dev/.local/share/cradle/quarry",
          HF_HUB_OFFLINE: "1",
          GIT_CONFIG_COUNT: "1",
          GIT_CONFIG_KEY_0: "core.hooksPath",
          GIT_CONFIG_VALUE_0: "/home/dev/.local/share/cradle/hooks"
        },
        remoteEnv: {GH_TOKEN: "${localEnv:GH_TOKEN}"},
        postCreateCommand: "/usr/local/share/cradle/postcreate.sh",
        postStartCommand: "/usr/local/share/cradle/poststart.sh"
      }'
  } > "$out.tmp"
  mv "$out.tmp" "$out"
  sha256sum < "$out" | cut -d' ' -f1 > "$hashf"
}
```

- [ ] **Step 5: Implement `lib/init.sh`**

```bash
#!/usr/bin/env bash
# cradle init: attach the current project (writes .devcontainer/cradle.json).
# shellcheck source=lib/render.sh
. "$CRADLE_ROOT/lib/render.sh"

GITIGNORE_BLOCK='# >>> cradle
.cradle/
.devcontainer/.cradle-hash
# <<< cradle'

detect_languages() {
  local d=$1 l=()
  [[ -f $d/package.json ]] && l+=(node)
  [[ -f $d/pyproject.toml || -f $d/requirements.txt || -f $d/setup.py ]] && l+=(python)
  [[ -f $d/go.mod ]] && l+=(go)
  [[ -f $d/Cargo.toml ]] && l+=(rust)
  [[ -f $d/pom.xml || -f $d/build.gradle || -f $d/build.gradle.kts ]] && l+=(java)
  if ((${#l[@]})); then printf '%s\n' "${l[@]}" | jq -R . | jq -sc .; else echo '[]'; fi
}

_add_gitignore_block() {
  local gi="$1/.gitignore"
  grep -qxF '# >>> cradle' "$gi" 2>/dev/null && return 0
  if [[ -s $gi && -n $(tail -c1 "$gi") ]]; then echo >> "$gi"; fi
  printf '%s\n' "$GITIGNORE_BLOCK" >> "$gi"
}

cmd_init() {
  local force=0 dir=$PWD cfg
  [[ ${1:-} == --force ]] && force=1
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: %s" "$dir"
  cfg="$dir/.devcontainer/cradle.json"
  if [[ -f $cfg ]] && (( ! force )); then
    die "%s exists; use --force to regenerate it" "$cfg"
  fi
  mkdir -p "$dir/.devcontainer"
  jq -n --argjson langs "$(detect_languages "$dir")" \
    '{languages: $langs, features: {}, maskPaths: [".personal"], memory: "3g", allowedDomains: [], testJobs: []}' > "$cfg"
  _add_gitignore_block "$dir"
  msg "attached %s (languages: %s); next: cradle claude" "$dir" "$(jq -r '.languages | join(", ")' "$cfg")"
}
```

- [ ] **Step 6: Run the tests and lint**

Run: `bats tests/render.bats tests/init.bats && shellcheck -x lib/render.sh lib/init.sh`
Expected: `9 tests, 0 failures`; no shellcheck output.

- [ ] **Step 7: Commit**

```bash
git add lib/render.sh lib/init.sh tests/render.bats tests/init.bats
git commit -m "Add cradle init and devcontainer.json rendering" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Per-repo tokens (`cradle token`)

**Files:**
- Create: `lib/token.sh`, `tests/token.bats`
- Modify: `lib/doctor.sh`, `tests/doctor.bats`

**Interfaces:**
- Produces: `repo_slug [DIR]` → prints `owner/repo` from a GitHub `origin`, returns 1 otherwise. `token_lookup REPO` → prints the token, returns non-zero if none is stored. `token_expiry_date REPO` → prints the expiry (`YYYY-MM-DD HH:MM:SS UTC`) or nothing for a token without expiry; returns non-zero if no token is stored or GitHub can't be reached. `cmd_token set|show-expiry [owner/repo]`. Keyring attributes: `service cradle repo <owner/repo>`.

- [ ] **Step 1: Write the failing tests `tests/token.bats`**

```bash
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
```

- [ ] **Step 2: Run and see them fail**

Run: `bats tests/token.bats`
Expected: FAIL, `lib/token.sh: No such file or directory`.

- [ ] **Step 3: Implement `lib/token.sh`**

```bash
#!/usr/bin/env bash
# cradle token: per-repo fine-grained GitHub tokens in the host keyring.

repo_slug() {
  local url
  url=$(git -C "${1:-$PWD}" remote get-url origin 2>/dev/null) || return 1
  [[ $url =~ github\.com[:/]([^/]+)/([^/]+)$ ]] || return 1
  printf '%s/%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]%.git}"
}

token_lookup() { secret-tool lookup service cradle repo "$1" 2>/dev/null; }

_token_set() {
  local repo=$1 t
  if [[ -t 0 ]]; then read -rsp "$(_t "GitHub token for") $repo: " t; echo; else read -r t; fi
  [[ -n $t ]] || die "empty token"
  printf '%s' "$t" | secret-tool store --label="cradle GitHub token $repo" service cradle repo "$repo"
  msg "stored token for %s" "$repo"
}

token_expiry_date() {
  local t
  t=$(token_lookup "$1") || return 1
  printf 'Authorization: Bearer %s\n' "$t" \
    | curl -fsSI -H @- https://api.github.com/rate_limit \
    | tr -d '\r' | awk -F': ' 'tolower($1) == "github-authentication-token-expiration" {print $2}'
}

_token_expiry() {
  local repo=$1 h days
  token_lookup "$repo" >/dev/null || die "no token stored for %s; run: cradle token set %s" "$repo" "$repo"
  h=$(token_expiry_date "$repo") || die "could not read the token's expiry from GitHub"
  if [[ -z $h ]]; then msg "token for %s has no expiry date" "$repo"; return 0; fi
  days=$(( ($(date -d "$h" +%s) - $(date +%s)) / 86400 ))
  msg "token for %s expires %s" "$repo" "$h"
  (( days >= 7 )) || warn "token for %s expires in %s days; renew it" "$repo" "$days"
}

cmd_token() {
  local sub=${1:-} repo=${2:-}
  [[ -n $repo ]] || repo=$(repo_slug) || die "no GitHub origin remote here; pass owner/repo"
  need secret-tool
  case $sub in
    set) _token_set "$repo" ;;
    show-expiry) _token_expiry "$repo" ;;
    *) die "usage: cradle token set|show-expiry [owner/repo]" ;;
  esac
}
```

- [ ] **Step 4: Run the tests and lint**

Run: `bats tests/token.bats && shellcheck -x lib/token.sh`
Expected: `5 tests, 0 failures`; no shellcheck output.

- [ ] **Step 5: Report the token in `cradle doctor`**

Append to `tests/doctor.bats`:

```bash
@test "a GitHub repo without a stored token warns" {
  git init -q repo && cd repo && git remote add origin https://github.com/Gelaende51/cradle.git
  stub secret-tool 1
  run cradle doctor
  [[ "$output" == *"warn"*"token"*"cradle token set"* ]]
}

@test "a token that expires soon warns" {
  git init -q repo && cd repo && git remote add origin https://github.com/Gelaende51/cradle.git
  stub secret-tool 0 ghp_x
  soon=$(date -u -d '+3 days' '+%Y-%m-%d %H:%M:%S UTC')
  stub curl 0 $'HTTP/2 200\r\ngithub-authentication-token-expiration: '"$soon"$'\r\n'
  run cradle doctor
  [[ "$output" == *"warn"*"token"*"renew it"* ]]
}
```

In `lib/doctor.sh`, add below the `config.sh` source line:

```bash
# shellcheck source=lib/token.sh
. "$CRADLE_ROOT/lib/token.sh"
```

add the check:

```bash
check_token() {
  local repo d days
  repo=$(repo_slug) || { _report ok token "no GitHub origin here; no token needed"; return 0; }
  have secret-tool || return 0
  token_lookup "$repo" >/dev/null || { _report warn token "no token for %s; run: cradle token set" "$repo"; return 0; }
  d=$(token_expiry_date "$repo") || { _report warn token "could not read the expiry of the token for %s" "$repo"; return 0; }
  [[ -n $d ]] || { _report ok token "token for %s has no expiry" "$repo"; return 0; }
  days=$(( ($(date -d "$d" +%s) - $(date +%s)) / 86400 ))
  if (( days >= 7 )); then _report ok token "token for %s is valid for %s days" "$repo" "$days"
  else _report warn token "token for %s expires in %s days; renew it" "$repo" "$days"; fi
}
```

and call `check_token` in `cmd_doctor` right after `check_config`.

Run: `bats tests/doctor.bats tests/token.bats && shellcheck -x lib/doctor.sh lib/token.sh`
Expected: `14 tests, 0 failures`; no shellcheck output.

- [ ] **Step 6: Commit**

```bash
git add lib/token.sh lib/doctor.sh tests/token.bats tests/doctor.bats
git commit -m "Add per-repo GitHub tokens in the host keyring" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Sessions: `up`, `down`, `claude`, `shell`, `push`

**Files:**
- Create: `lib/session.sh`, `tests/session.bats`

**Interfaces:**
- Consumes: `render_devcontainer DIR` (Task 8); `repo_slug`, `token_lookup` (Task 9); the label key from Spike A (`devcontainer.local_folder`).
- Produces: `cmd_up`, `cmd_down`, `cmd_claude [ARGS]`, `cmd_shell`, `cmd_push [--yes] [GIT PUSH ARGS]`. `GH_TOKEN` is exported to the devcontainer CLI's environment only (it reaches the container through `remoteEnv`).

- [ ] **Step 1: Write the failing tests `tests/session.bats`**

```bash
setup() {
  load test_helper; setup_isolated_path
  P="$BATS_TEST_TMPDIR/my proj"; mkdir -p "$P"; git -C "$P" init -q; cd "$P"
  "$CRADLE_ROOT/bin/cradle" init >/dev/null
  stub podman
  stub_script devcontainer 'echo "GH_TOKEN=${GH_TOKEN-unset}" >> "$STUB_LOG"'
}

@test "up renders devcontainer.json and runs devcontainer up on podman" {
  stub secret-tool 1
  run cradle up
  [ "$status" -eq 0 ]
  [ -f .devcontainer/devcontainer.json ]
  grep -q "devcontainer up --docker-path podman --workspace-folder $P" "$STUB_LOG"
}

@test "up without a GitHub origin runs without a token" {
  run cradle up
  [ "$status" -eq 0 ]
  grep -q "GH_TOKEN=unset" "$STUB_LOG"
}

@test "up passes the stored token through the environment, never as an argument" {
  git remote add origin https://github.com/Gelaende51/cradle.git
  stub secret-tool 0 ghp_secret
  run cradle up
  grep -q "GH_TOKEN=ghp_secret" "$STUB_LOG"
  run ! grep -q "devcontainer .*ghp_secret" "$STUB_LOG"
}

@test "claude execs claude with its arguments inside the container" {
  run cradle claude --resume
  grep -q "devcontainer exec --docker-path podman --workspace-folder $P claude --resume" "$STUB_LOG"
}

@test "down stops the container labelled with this folder" {
  stub_script podman '[[ $1 == ps ]] && echo abc123; exit 0'
  run cradle down
  [ "$status" -eq 0 ]
  grep -q "podman ps -q --filter label=devcontainer.local_folder=$P" "$STUB_LOG"
  grep -q "podman stop abc123" "$STUB_LOG"
}

@test "push needs confirmation" {
  stub_script git 'exec '"$(command -v git)"' "$@"'
  run bash -c 'echo n | "$CRADLE_ROOT/bin/cradle" push'
  [ "$status" -eq 1 ]
  [[ "$output" == *"push cancelled"* ]]
  run ! grep -q "^git push" "$STUB_LOG"
}
```

- [ ] **Step 2: Run and see them fail**

Run: `bats tests/session.bats`
Expected: FAIL, `lib/session.sh: No such file or directory`.

- [ ] **Step 3: Implement `lib/session.sh`**

```bash
#!/usr/bin/env bash
# cradle up/down/claude/shell/push: the project's dev container session.
# shellcheck source=lib/render.sh
. "$CRADLE_ROOT/lib/render.sh"
# shellcheck source=lib/token.sh
. "$CRADLE_ROOT/lib/token.sh"

_dc() { devcontainer "$1" --docker-path podman --workspace-folder "$PWD" "${@:2}"; }

# Export GH_TOKEN for the devcontainer CLI (remoteEnv reads it); silent without one.
_session_token() {
  local r t
  r=$(repo_slug) || return 0
  t=$(token_lookup "$r") || return 0
  [[ -n $t ]] && export GH_TOKEN=$t
  return 0
}

cmd_up() {
  need podman; need devcontainer
  render_devcontainer "$PWD"
  _session_token
  _dc up >/dev/null
  msg "dev container is up for %s" "$PWD"
}

cmd_down() {
  need podman
  local ids
  ids=$(podman ps -q --filter "label=devcontainer.local_folder=$PWD")
  if [[ -z $ids ]]; then msg "no running dev container for %s" "$PWD"; return 0; fi
  # shellcheck disable=SC2086  # one id per word
  podman stop $ids >/dev/null
  msg "stopped the dev container for %s" "$PWD"
}

cmd_claude() { cmd_up >/dev/null; _dc exec claude "$@"; }
cmd_shell()  { cmd_up >/dev/null; _dc exec bash -l; }

cmd_push() {
  local yes=0 up a
  [[ ${1:-} == --yes ]] && { yes=1; shift; }
  up=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || up=""
  [[ -n $up ]] && git --no-pager diff --stat "$up..HEAD" -- .github/workflows
  if (( ! yes )); then
    read -rp "$(_t "push with your host credentials? [y/N] ")" a || a=""
    [[ $a == [yY] ]] || die "push cancelled"
  fi
  git push "$@"
}
```

- [ ] **Step 4: Run the tests and lint**

Run: `bats tests/session.bats && shellcheck -x lib/session.sh`
Expected: `6 tests, 0 failures`; no shellcheck output.

- [ ] **Step 5: Run the whole suite**

Run: `make check`
Expected: shellcheck clean; `bats tests`, all green (cli 3, doctor 9, setup 4, image 3, config 3, render+init 9, token 5, session 6 = 42 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/session.sh tests/session.bats
git commit -m "Add cradle up, down, claude, shell and push" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Foundation integration test (real podman)

**Files:**
- Create: `tests/integration/foundation.sh`
- Modify: `dev/takeaways.md`

**Interfaces:**
- Consumes: everything above. Needs a built image (Task 6) and the synced config (Task 7).

- [ ] **Step 1: Write `tests/integration/foundation.sh`**

```bash
#!/usr/bin/env bash
# shellcheck disable=SC2016  # the single-quoted commands expand inside the container
# End-to-end on real podman: attach a fixture project whose name has a space,
# bring the container up, and check the isolation promises from the spec.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
C="$ROOT/bin/cradle"
T=$(mktemp -d); P="$T/fixture proj"
trap '(cd "$P" 2>/dev/null && "$C" down >/dev/null 2>&1); podman volume rm -f cradle-fixture-proj-data >/dev/null 2>&1; rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }

mkdir -p "$P/.personal"; echo 'pw: hunter2' > "$P/.personal/personal.md"
echo '{"name":"fixture"}' > "$P/package.json"
git -C "$P" init -q; git -C "$P" -c user.name=t -c user.email=t@localhost commit -q --allow-empty -m init
cd "$P"

"$C" init >/dev/null && ok "init"
"$C" up >/dev/null && ok "up"
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
check "config volume mounted"    in_c 'test -f ~/.claude/CLAUDE.md && test -f ~/.claude/cradle-rules/orchestrator.md'
check "punt tools answer"        in_c 'bd --version && ethos --version && punt version && quarry status >/dev/null'
in_c 'touch "$CRADLE_WORKSPACE/made-in-container"'
check "bind-mount ownership"     eq "$(stat -c %U "$P/made-in-container")" "$(id -un)"

"$C" down >/dev/null && ok "down"
echo "foundation: all checks passed"
```

```bash
chmod +x tests/integration/foundation.sh
```

- [ ] **Step 2: Run it**

Run: `bin/cradle image build && bin/cradle config sync && make integration`
Expected: every line `ok`, and last `foundation: all checks passed`. The first
run takes minutes (it builds the feature layer and creates volumes). On any
`FAIL`, debug with superpowers:systematic-debugging, and record library quirks
in `dev/takeaways.md`.

- [ ] **Step 3: Log in once, in the shared volume**

Ask the operator to run, from any attached project: `bin/cradle claude`, then
complete the browser sign-in (paste the code if the callback doesn't reach the
container). This is a one-time step for the `cradle-claude` volume.

- [ ] **Step 4: Commit**

```bash
git add tests/integration/foundation.sh dev/takeaways.md
git commit -m "Add the foundation integration test" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Done criteria for Plan 1

- `make check` is green and `make integration` passes on this host.
- `cradle doctor` shows no `fail`.
- The operator has used `cradle claude` in one real project.
- `dev/spikes/devcontainer/NOTES.md` and `dev/spikes/act/NOTES.md` carry a **Result** line, which is the input for Plans 2 and 3.
