# cradle Plan 3: Tier-2 test service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude inside a dev container can ask the host to run one job of an approved GitHub Actions workflow with act, in disposable job containers with no network and no container socket, and read the result — without any container privilege.

**Architecture:** Each attached project has a host state directory `~/.local/state/cradle/testd/<key>/`. Its `req/` subdirectory (maildir style: `tmp/` then rename into `new/`) is mounted read-write into the container; its `results/` is mounted read-only. A systemd user path unit per project starts `cradle-testd <key>`, which moves requests into host-private `processing/`, validates them (schema, commit, listed job, approved `.github` tree, safe job definition), runs `act` on a `git worktree` of the commit under a global lock, and writes `results/<id>/status.json` plus the log. `cradle-request` (in the container) and `cradle test` (host) are the same script.

**Tech Stack:** bash, jq, python3 + PyYAML (YAML → JSON), git worktrees, act 0.2.89 on the rootless podman socket, systemd user path/service template units, bats.

**Spec:** `dev/specs/2026-09-28-cradle-design.md` §3.6 (plus §3.2 CI template and `.actrc`, §3.7 `init --detach`, `test`, `approve-workflows`, `cradle-request`, §5 doctor, §6 security tests).

## Global Constraints

- Request: `{"ref": "<commit sha>", "job": "<job id>"}` — exactly these two fields; `ref` a full SHA in the repo; `job` listed in `cradle.json`.
- The workflow must be **approved**: approved set = the remote default branch (fetched on the host) plus `cradle approve-workflows` (host, after operator review).
- The job definition has no `container.options`, no `volumes`, no `--privileged`, no host paths, and no `services` with mounts.
- act runs with `--container-daemon-socket -`, no `--bind`, network `none` unless the job is marked `network: allowed` in `cradle.json`, and a 2 GB memory limit.
- One run at a time; the rest queue. Timeout 30 minutes (configurable).
- Result: `status.json` (`passed`, `failed`, `rejected`, `timeout` or `aborted`, plus the reason), the act log, and artifacts.
- Crash safety: requests move `new/` → `processing/` → `done/`; leftovers are cleaned up and reported as `aborted` at start. A request never disappears silently.
- `DOCKER_HOST` points act at the rootless podman socket, on the host only.
- Every shell file passes `shellcheck -x`; bats tests stub podman, act, systemctl; real podman runs go through `systemd-run --user --collect --setenv=PATH="$PATH" --setenv=XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" --setenv=HOME="$HOME"` (Plan 1 takeaway), deleting the log before starting and waiting for its `EXIT=` line.

## Clarifications of the spec made while planning

- **Requests and results live outside the workspace** (spec: `.cradle/requests/`, `.cradle/results/` in the project). The container can write the whole workspace, so a host service writing results there, or reading requests there, would follow symlinks the container planted. Instead the host directory `testd/<key>/req` is mounted at `/home/dev/.cradle/requests` and `testd/<key>/results` read-only at `/home/dev/.cradle/results`. The host moves a request into its private `processing/` before reading it and refuses anything that is not a regular file.
- **Approval covers the `.github` tree, not one workflow file.** A job can use local actions (`uses: ./.github/actions/x`) whose files a workflow-file hash would not cover. The approved unit is the git tree id of `.github` at the commit (content-addressed), and local actions outside `.github/` are refused.
- **`testJobs` entries are objects**: `{"workflow": "ci.yml", "job": "test", "network": false}`; `network: true` means act's `--network podman` (bridge with internet, never `host`). Optional top-level `testTimeout` (minutes, default 30).

## Review Focus

1. The container plants a symlink, a directory, a FIFO or a 1 GB file as a request, or swaps `req/new` for a symlink → nothing outside the state directory is read, moved or written; the request is rejected with a result (Task 1 tests "a symlinked request is rejected, its target untouched", "an oversized request is rejected").
2. A request whose id collides with an existing result, or has characters outside `[A-Za-z0-9_-]` → a result under a fresh safe id, never an overwrite (Task 1 test "an id that already has a result gets a fresh one").
3. A job that passes validation but whose commit changes `.github/actions/*` → refused until approved again (Task 2 test "changing a local action needs a new approval").
4. testd killed mid-run (power loss, `systemctl stop`) → at the next start the request is reported `aborted` and its worktree removed (Task 3 test "leftovers are reported aborted and cleaned").
5. A request written while the runner is finishing → still processed (the runner re-scans after each job, and the path unit uses `DirectoryNotEmpty`) (Task 4 test "the path unit watches req/new for any entry").

---

### Task 1: Request intake and validation

**Files:**
- Create: `lib/testd.sh`, `tests/testd.bats`
- Modify: `lib/common.sh` (move `_git_host` here from `lib/session.sh`), `lib/session.sh`, `lib/render.sh` (add `testd_dir`)

**Interfaces:**
- Consumes: `project_key DIR` (render.sh), `die`, `msg`, `warn`.
- Produces:
  - `_git_host ARGS…` (common.sh): `git -c core.hooksPath=/dev/null -c core.fsmonitor=false ARGS…`.
  - `testd_dir KEY` (render.sh) → `${XDG_STATE_HOME:-$HOME/.local/state}/cradle/testd/KEY`.
  - `testd_prepare DIR` → creates `req/tmp`, `req/new`, `results`, `processing`, `done` under `testd_dir`, writes `project` (the absolute project path).
  - `request_take KEY` → moves every entry of `req/new` into `processing/`; prints one id per line for entries named `<id>.json` with a safe id; other entries get a `rejected` result under `invalid-<epoch>-<n>`.
  - `request_check DIR FILE` → prints `<ref> <job>` or prints a reason and returns 1.
  - `result_write KEY ID STATUS REASON [JOB] [REF]` → writes `results/<id>/status.json` atomically; returns the id actually used (a fresh one if `results/<id>/status.json` exists).

- [ ] **Step 1: Write the failing tests `tests/testd.bats`**

```bash
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
```
`ln`, `stat` and `find` must be in `BASE_TOOLS` (`tests/test_helper.bash`); add `ln stat` if missing.

Run: `bats tests/testd.bats` — Expected: FAIL (`lib/testd.sh` missing).

- [ ] **Step 2: Move `_git_host` to `lib/common.sh`** (delete it from `lib/session.sh`; comment kept):

```bash
# Host git on a tree a container wrote to: never run its hooks or fsmonitor.
_git_host() { git -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"; }
```

- [ ] **Step 3: Add `testd_dir` to `lib/render.sh`** (after `project_key`):

```bash
# testd_dir KEY: the host state of a project's tier-2 test queue.
testd_dir() { printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/cradle/testd/$1"; }
```

- [ ] **Step 4: Write `lib/testd.sh`**

```bash
#!/usr/bin/env bash
# Tier-2 test queue, host side. Everything under req/ is written by the dev
# container and untrusted: entries are moved into the host-private processing/
# before anything reads them, and only regular files are ever read.
# shellcheck source=lib/render.sh
. "$CRADLE_ROOT/lib/render.sh"

testd_prepare() {
  local dir=$1 d; d=$(testd_dir "$(project_key "$dir")")
  mkdir -p "$d/req/tmp" "$d/req/new" "$d/results" "$d/processing" "$d/done"
  printf '%s\n' "$dir" > "$d/project"
}

_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# result_write KEY ID STATUS REASON [JOB] [REF]: prints the id used.
result_write() {
  local d id=$2 r; d=$(testd_dir "$1")
  # an id is taken once it has a status (the runner creates results/<id>/ for the log first)
  [[ -e $d/results/$id/status.json ]] && id="$id-$(date +%s)-$RANDOM"
  r="$d/results/$id"; mkdir -p "$r"
  jq -n --arg s "$3" --arg why "$4" --arg job "${5:-}" --arg ref "${6:-}" --arg at "$(_now)" \
    '{status: $s, reason: $why, job: $job, ref: $ref, finished: $at}' > "$r/status.json.tmp"
  mv "$r/status.json.tmp" "$r/status.json"
  printf '%s\n' "$id"
}

# request_take KEY: new/ → processing/; prints the ids of plausible requests.
request_take() {
  local key=$1 d n=0 name
  d=$(testd_dir "$key")
  # work inside the real new/ (a symlink planted in its place is refused)
  [[ -d $d/req/new && ! -L $d/req/new ]] || { warn "%s is not a directory; refusing it" "$d/req/new"; return 0; }
  ( cd "$d/req/new" && [[ $(pwd -P) == "$(cd "$d/req" && pwd -P)/new" ]] ) || return 0
  while IFS= read -r -d '' name; do
    name=${name#./}
    if [[ $name =~ ^[A-Za-z0-9_-]{1,64}\.json$ ]]; then
      mv -- "$d/req/new/$name" "$d/processing/$name"
      if [[ -f $d/processing/$name && ! -L $d/processing/$name ]]; then printf '%s\n' "${name%.json}"; continue; fi
      rm -rf -- "${d:?}/processing/$name"
    else
      rm -rf -- "${d:?}/req/new/$name"
    fi
    n=$((n + 1))
    result_write "$key" "invalid-$(date +%s)-$n" rejected "not a request: entries in requests/new must be regular files named <id>.json ([A-Za-z0-9_-], at most 64)" >/dev/null
  done < <(cd "$d/req/new" && find . -mindepth 1 -maxdepth 1 -print0)
}

# request_check DIR FILE: prints "<ref> <job>", or a reason and returns 1.
request_check() {
  local dir=$1 f=$2 ref job
  [[ $(wc -c < "$f") -le 4096 ]] || { echo "request larger than 4 KB"; return 1; }
  jq -e 'type == "object" and (keys == ["job", "ref"]) and (.ref | type) == "string" and (.job | type) == "string"' \
    "$f" >/dev/null 2>&1 || { echo 'a request is exactly {"ref": "<commit sha>", "job": "<job id>"}'; return 1; }
  ref=$(jq -r .ref "$f"); job=$(jq -r .job "$f")
  [[ $ref =~ ^[0-9a-f]{40}$ ]] || { echo "ref must be a full 40-character commit SHA"; return 1; }
  [[ $job =~ ^[A-Za-z0-9_-]{1,64}$ ]] || { echo "job ids are [A-Za-z0-9_-]"; return 1; }
  _git_host -C "$dir" cat-file -e "$ref^{commit}" 2>/dev/null || { echo "commit $ref is not in the repository"; return 1; }
  jq -e --arg j "$job" '[.testJobs[]?.job] | index($j) != null' "$dir/.devcontainer/cradle.json" >/dev/null \
    || { echo "job $job is not listed in cradle.json testJobs"; return 1; }
  printf '%s %s\n' "$ref" "$job"
}
```

- [ ] **Step 5: Run** `make check` — Expected: all green (the session tests still pass with `_git_host` in common.sh).

- [ ] **Step 6: Commit** — `git add lib tests && git commit -m "Add the tier-2 request intake and validation"`

---

### Task 2: Workflow approval and job safety

**Files:**
- Modify: `lib/testd.sh`, `bin/cradle` (`approve-workflows` → group `testd`, usage), `tests/testd.bats`, `tests/cli.bats`, `lib/setup.sh` + `tests/setup.bats` (PyYAML check), `lib/doctor.sh` (PyYAML check)

**Interfaces:**
- Consumes: `testd_dir`, `project_key`, `_git_host`, `request_check` output.
- Produces:
  - `github_tree DIR REF` → the tree id of `.github` at REF (fails when absent).
  - `approved_add KEY TREE COMMIT`; `is_approved KEY TREE` (file `testd/<key>/approved`, lines `<tree> <commit>`).
  - `job_check DIR REF JOB` → prints the workflow file name (`ci.yml`) or a reason and returns 1.
  - `cmd_approve_workflows [--yes] [REF]` (host command `cradle approve-workflows`).

- [ ] **Step 1: Write the failing tests** (append to `tests/testd.bats`; helper `wf` commits a workflow):

```bash
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
```
Add `python3` to `BASE_TOOLS`. Run: `bats tests/testd.bats` — Expected: the five new tests FAIL.

- [ ] **Step 2: Implement** (append to `lib/testd.sh`):

```bash
_yaml_json() { python3 -c 'import json, sys, yaml; json.dump(yaml.safe_load(sys.stdin), sys.stdout)'; }

github_tree() { _git_host -C "$1" rev-parse -q --verify "$2:.github" 2>/dev/null; }
approved_add() { local d; d=$(testd_dir "$1"); grep -qs "^$2 " "$d/approved" || printf '%s %s\n' "$2" "$3" >> "$d/approved"; }
is_approved() { grep -qs "^$2 " "$(testd_dir "$1")/approved"; }

# job_check DIR REF JOB: prints the workflow file, or a reason and returns 1.
job_check() {
  local dir=$1 ref=$2 job=$3 key wf tree json bad
  key=$(project_key "$dir")
  wf=$(jq -r --arg j "$job" '[.testJobs[] | select(.job == $j)][0].workflow // empty' "$dir/.devcontainer/cradle.json")
  [[ $wf =~ ^[A-Za-z0-9._-]+\.ya?ml$ ]] || { echo "testJobs entry for $job needs a workflow file name like ci.yml"; return 1; }
  tree=$(github_tree "$dir" "$ref") || { echo "commit $ref has no .github directory"; return 1; }
  is_approved "$key" "$tree" || { echo ".github at ${ref:0:12} is not approved; run on the host: cradle approve-workflows ${ref:0:12}"; return 1; }
  json=$(_git_host -C "$dir" show "$ref:.github/workflows/$wf" 2>/dev/null | _yaml_json 2>/dev/null) \
    || { echo "cannot read .github/workflows/$wf at ${ref:0:12}"; return 1; }
  bad=$(jq -r --arg j "$job" '
    .jobs[$j] as $d
    | if $d == null then "job \($j) is not in the workflow"
      elif ($d.container | type) == "object" and (($d.container.options // null) != null or ($d.container.volumes // null) != null)
        then "container.options and container.volumes are not allowed"
      elif [($d.services // {})[] | select(type == "object" and ((.volumes // null) != null or (.options // null) != null))] | length > 0
        then "services with volumes or options are not allowed"
      elif [$d | del(.steps[]?.run) | .. | strings | select(test("--privileged|--volume|(^|\\s)-v\\s|docker\\.sock|podman\\.sock"))] | length > 0
        then "--privileged, volumes and container sockets are not allowed"
      elif [($d.steps // [])[] | (.uses? // "") | select(startswith("./") and (startswith("./.github/") | not))] | length > 0
        then "local actions outside .github are not allowed"
      else empty end' <<< "$json")
  [[ -z $bad ]] || { echo "$bad"; return 1; }
  printf '%s\n' "$wf"
}

cmd_approve_workflows() {
  local yes=0 ref key tree prev a base
  [[ ${1:-} == --yes ]] && { yes=1; shift; }
  ref=$(_git_host rev-parse --verify "${1:-HEAD}^{commit}") || die "no commit %s" "${1:-HEAD}"
  key=$(project_key "$PWD"); testd_prepare "$PWD"
  # the remote default branch counts as reviewed
  if _git_host remote get-url origin >/dev/null 2>&1 && _git_host fetch -q origin 2>/dev/null \
     && base=$(_git_host rev-parse -q --verify refs/remotes/origin/HEAD) && tree=$(github_tree "$PWD" "$base"); then
    approved_add "$key" "$tree" "$base"
  fi
  tree=$(github_tree "$PWD" "$ref") || die "commit %s has no .github directory" "${ref:0:12}"
  is_approved "$key" "$tree" && { msg ".github at %s is already approved" "${ref:0:12}"; return 0; }
  prev=$(tail -n 1 "$(testd_dir "$key")/approved" 2>/dev/null | cut -d' ' -f2)
  [[ -n $prev ]] || prev=$(_git_host hash-object -t tree /dev/null)
  _git_host --no-pager diff "$prev" "$ref" -- .github
  if (( ! yes )); then
    read -rp "$(_t "approve .github at this commit for tier-2 runs? [y/N] ")" a || a=""
    [[ $a == [yY] ]] || die "not approved"
  fi
  approved_add "$key" "$tree" "$ref"
  msg "approved .github at %s" "${ref:0:12}"
}
```
In `bin/cradle`: `approve-workflows) group=testd; cmd=approve_workflows ;;` — check how the dispatcher builds the function name (`cmd_$group` vs `cmd_$cmd`) and follow it; add usage lines for `approve-workflows` and (Task 4) `test`. Setup and doctor: `python3 -c 'import yaml'` must succeed; setup prints `sudo pacman -S --needed python-yaml` when it does not, doctor reports `fail python-yaml`. Extend `tests/setup.bats`/`tests/doctor.bats` with one test each in their existing style.

- [ ] **Step 3: Run** `make check` — Expected: all green.

- [ ] **Step 4: Commit** — `git commit -am "Approve .github trees and refuse unsafe tier-2 jobs"`

---

### Task 3: The runner `cradle-testd`

**Files:**
- Create: `bin/cradle-testd`, `tests/testd-run.bats`
- Modify: `lib/testd.sh`, `image/versions.env` (`ACT_IMAGE`)

**Interfaces:**
- Consumes: Tasks 1–2; `ACT_IMAGE` from `image/versions.env`.
- Produces: `testd_run KEY` (entry point of `bin/cradle-testd KEY`); worktrees under `${XDG_CACHE_HOME:-$HOME/.cache}/cradle/runs/<key>-<id>`; global lock `${XDG_STATE_HOME:-$HOME/.local/state}/cradle/testd/run.lock`; results `results/<id>/{status.json,act.log,artifacts/}`.

- [ ] **Step 1: Pin the runner image** in `image/versions.env`: `ACT_IMAGE=docker.io/catthehacker/ubuntu:act-latest` (the Spike B image; record its digest `podman image inspect --format '{{.Digest}}'` in the ledger).

- [ ] **Step 2: Write the failing tests `tests/testd-run.bats`**

```bash
setup() {
  load test_helper; setup_isolated_path
  . "$CRADLE_ROOT/lib/common.sh"; . "$CRADLE_ROOT/lib/testd.sh"
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
  P="$BATS_TEST_TMPDIR/proj"; mkdir -p "$P/.devcontainer" "$P/.github/workflows"; git -C "$P" init -q
  printf 'on: push\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n' > "$P/.github/workflows/ci.yml"
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
```
Add `flock timeout` to `BASE_TOOLS`. Run: `bats tests/testd-run.bats` — Expected: FAIL (`bin/cradle-testd` missing).

- [ ] **Step 3: Implement** (append to `lib/testd.sh`):

```bash
_runs_dir() { printf '%s' "${XDG_CACHE_HOME:-$HOME/.cache}/cradle/runs"; }

# _recover KEY DIR: a previous runner died; report and clean what it left.
_recover() {
  local key=$1 dir=$2 d f id w; d=$(testd_dir "$key")
  for f in "$d"/processing/*.json; do
    [[ -e $f ]] || continue
    id=$(basename "$f" .json)
    result_write "$key" "$id" aborted "the test runner stopped before this request finished" >/dev/null
    mv -- "$f" "$d/done/"
  done
  for w in "$(_runs_dir)/$key"-*; do
    [[ -e $w ]] || continue
    _git_host -C "$dir" worktree remove --force "$w" 2>/dev/null || rm -rf -- "$w"
  done
  _git_host -C "$dir" worktree prune
}

# _run_job KEY DIR ID REF JOB WF: act in a worktree of REF; prints the status.
_run_job() {
  local key=$1 dir=$2 id=$3 ref=$4 job=$5 wf=$6 d res run net mins rc
  d=$(testd_dir "$key"); res="$d/results/$id"; run="$(_runs_dir)/$key-$id"
  mkdir -p "$res/artifacts" "$(_runs_dir)"
  net=none
  [[ $(jq -r --arg j "$job" '[.testJobs[] | select(.job == $j)][0].network // false' "$dir/.devcontainer/cradle.json") == true ]] && net=podman
  mins=$(jq -r '.testTimeout // 30' "$dir/.devcontainer/cradle.json")
  [[ $mins =~ ^[0-9]{1,3}$ ]] || mins=30
  _git_host -C "$dir" worktree add -q --detach "$run" "$ref" >/dev/null 2>&1 || { echo "failed cannot create a worktree of ${ref:0:12}"; return 0; }
  rc=0
  ( cd "$run" && timeout "${mins}m" act -W ".github/workflows/$wf" -j "$job" -P "ubuntu-latest=$ACT_IMAGE" \
      --container-daemon-socket - --network "$net" --container-options "--memory=2g" --rm \
      --artifact-server-path "$res/artifacts" ) > "$res/act.log" 2>&1 || rc=$?
  _git_host -C "$dir" worktree remove --force "$run" 2>/dev/null || rm -rf -- "$run"
  case $rc in
    0) echo "passed job $job passed" ;;
    124) echo "timeout job $job ran longer than $mins minutes" ;;
    *) echo "failed job $job failed (act exit $rc); see act.log" ;;
  esac
}

testd_run() {
  local key=$1 d dir id out ref job wf status reason
  d=$(testd_dir "$key"); dir=$(cat "$d/project")
  # shellcheck source=image/versions.env
  . "$CRADLE_ROOT/image/versions.env"
  exec 9> "${XDG_STATE_HOME:-$HOME/.local/state}/cradle/testd/run.lock"
  flock 9   # one run at a time, across projects
  _recover "$key" "$dir"
  while :; do
    request_take "$key" >/dev/null
    id=$(find "$d/processing" -maxdepth 1 -name '*.json' -printf '%f\n' | sort | head -n 1)
    [[ -n $id ]] || break
    id=${id%.json}
    if out=$(request_check "$dir" "$d/processing/$id.json") && read -r ref job <<< "$out" \
       && out=$(job_check "$dir" "$ref" "$job"); then
      wf=$out
      read -r status reason <<< "$(_run_job "$key" "$dir" "$id" "$ref" "$job" "$wf")"
      result_write "$key" "$id" "$status" "$reason" "$job" "$ref" >/dev/null
    else
      result_write "$key" "$id" rejected "$out" "${job:-}" "${ref:-}" >/dev/null
    fi
    mv -- "$d/processing/$id.json" "$d/done/"
    ref=""; job=""
  done
}
```
`bin/cradle-testd`:

```bash
#!/usr/bin/env bash
# cradle-testd KEY: process a project's tier-2 test requests (started by cradle-testd@KEY.path).
set -euo pipefail
CRADLE_ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
export CRADLE_ROOT
# shellcheck source=lib/common.sh
. "$CRADLE_ROOT/lib/common.sh"
# shellcheck source=lib/testd.sh
. "$CRADLE_ROOT/lib/testd.sh"
[[ ${1:-} =~ ^[a-z0-9-]+$ ]] || die "usage: cradle-testd PROJECT-KEY"
[[ -f $(testd_dir "$1")/project ]] || die "unknown project key %s" "$1"
testd_run "$1"
```
Add `bin/cradle-testd` to the Makefile lint list.

- [ ] **Step 4: Run** `make check` — Expected: all green.

- [ ] **Step 5: Commit** — `git add -A bin lib tests image/versions.env Makefile && git commit -m "Add the tier-2 runner cradle-testd"`

---

### Task 4: Wiring — units, init, detach, render, cradle-request, cradle test, doctor

**Files:**
- Create: `testd/cradle-testd@.path`, `testd/cradle-testd@.service`, `bin/cradle-request`, `templates/ci.yml`, `templates/actrc`, `tests/testd-wire.bats`
- Modify: `lib/testd.sh` (install/uninstall, `cmd_test`), `lib/init.sh` (templates, testJobs, register, `--detach`), `lib/render.sh` (mounts, env), `lib/doctor.sh` (testd check), `bin/cradle` (`test` command), `tests/init.bats`, `tests/render.bats`, `tests/doctor.bats`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: `testd_install KEY`, `testd_uninstall KEY`; container paths `/home/dev/.cradle/requests/{tmp,new}` (rw) and `/home/dev/.cradle/results` (ro), env `CRADLE_REQUESTS`, `CRADLE_RESULTS`; `/usr/local/bin/cradle-request JOB [REF]`; host `cradle test JOB [REF]`.

- [ ] **Step 1: Units** — `testd/cradle-testd@.path`:

```
[Unit]
Description=cradle tier-2 test requests for %i

[Path]
# any entry in new/ (cradle-request renames finished files into it from tmp/)
DirectoryNotEmpty=%h/.local/state/cradle/testd/%i/req/new

[Install]
WantedBy=default.target
```
`testd/cradle-testd@.service`:

```
[Unit]
Description=cradle tier-2 test runner for %i

[Service]
Type=oneshot
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin
Environment=DOCKER_HOST=unix://%t/podman/podman.sock
ExecStart=@CRADLE_ROOT@/bin/cradle-testd %i
```

- [ ] **Step 2: `bin/cradle-request`** (runs in the container; on the host `cradle test` runs it with the host paths):

```bash
#!/usr/bin/env bash
# cradle-request JOB [REF]: ask the host to run tier-2 job JOB on a commit
# (default HEAD) and wait for the result. Exit 0 only when the job passed.
set -euo pipefail
job=${1:?usage: cradle-request JOB [REF]}
q=${CRADLE_REQUESTS:-$HOME/.cradle/requests}; r=${CRADLE_RESULTS:-$HOME/.cradle/results}
ref=$(git rev-parse --verify "${2:-HEAD}^{commit}")
[[ -z $(git status --porcelain --untracked-files=no) ]] \
  || echo "cradle-request: uncommitted changes are not part of the run; testing ${ref:0:12}" >&2
id="$(date +%Y%m%d-%H%M%S)-$$"
jq -n --arg ref "$ref" --arg job "$job" '{ref: $ref, job: $job}' > "$q/tmp/$id.json"
mv "$q/tmp/$id.json" "$q/new/$id.json"
echo "cradle-request: $job at ${ref:0:12} queued as $id" >&2
for ((i = 0; i < ${CRADLE_REQUEST_WAIT:-1500}; i++)); do   # 2 s steps, 50 minutes
  [[ -f $r/$id/status.json ]] && break
  sleep 2
done
[[ -f $r/$id/status.json ]] || { echo "cradle-request: no result after waiting; is the host's cradle-testd running?" >&2; exit 3; }
jq -r '"\(.status): \(.reason)"' "$r/$id/status.json"
echo "log: $r/$id/act.log" >&2
[[ $(jq -r .status "$r/$id/status.json") == passed ]]
```

- [ ] **Step 3: Write the failing tests `tests/testd-wire.bats`**

```bash
setup() {
  load test_helper; setup_isolated_path
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config"
  P="$BATS_TEST_TMPDIR/proj"; mkdir -p "$P"; git -C "$P" init -q; cd "$P"
  stub systemctl; stub podman
}

@test "init writes the CI template, .actrc and a matching testJobs entry" {
  run "$CRADLE_ROOT/bin/cradle" init
  [ "$status" -eq 0 ]
  [ -f .github/workflows/ci.yml ]; [ -f .actrc ]
  [ "$(jq -c '.testJobs' .devcontainer/cradle.json)" = '[{"workflow":"ci.yml","job":"test","network":false}]' ]
}

@test "init keeps an existing workflow and lists no job for it" {
  mkdir -p .github/workflows; echo 'on: push' > .github/workflows/ci.yml
  "$CRADLE_ROOT/bin/cradle" init
  [ "$(cat .github/workflows/ci.yml)" = 'on: push' ]
  [ "$(jq -c '.testJobs' .devcontainer/cradle.json)" = '[]' ]
}

@test "init installs the units and enables this project's path unit" {
  "$CRADLE_ROOT/bin/cradle" init
  k=$(. "$CRADLE_ROOT/lib/common.sh"; . "$CRADLE_ROOT/lib/render.sh"; project_key "$P")
  grep -q "ExecStart=$CRADLE_ROOT/bin/cradle-testd %i" "$XDG_CONFIG_HOME/systemd/user/cradle-testd@.service"
  grep -q "DirectoryNotEmpty=%h/.local/state/cradle/testd/%i/req/new" "$XDG_CONFIG_HOME/systemd/user/cradle-testd@.path"
  grep -q "systemctl --user enable --now cradle-testd@$k.path" "$STUB_LOG"
}

@test "init --detach disables the unit and removes network and proxy" {
  "$CRADLE_ROOT/bin/cradle" init; : > "$STUB_LOG"
  run "$CRADLE_ROOT/bin/cradle" init --detach
  [ "$status" -eq 0 ]
  grep -q "systemctl --user disable --now cradle-testd@" "$STUB_LOG"
  grep -q "podman rm -f cradle-proxy-" "$STUB_LOG"
  grep -q "podman network rm -f cradle-proj-" "$STUB_LOG"
}

@test "the container gets the request maildir, read-only results and cradle-request" {
  "$CRADLE_ROOT/bin/cradle" init
  . "$CRADLE_ROOT/lib/common.sh"; . "$CRADLE_ROOT/lib/render.sh"
  render_devcontainer "$P"; d=$(testd_dir "$(project_key "$P")")
  j() { tail -n +2 .devcontainer/devcontainer.json; }
  j | jq -e --arg a "--volume=$d/req:/home/dev/.cradle/requests" '.runArgs | index($a)'
  j | jq -e --arg a "--volume=$d/results:/home/dev/.cradle/results:ro" '.runArgs | index($a)'
  j | jq -e --arg a "--volume=$CRADLE_ROOT/bin/cradle-request:/usr/local/bin/cradle-request:ro" '.runArgs | index($a)'
  [ "$(j | jq -r .containerEnv.CRADLE_RESULTS)" = /home/dev/.cradle/results ]
}

@test "cradle test queues through the same script and reports the result" {
  "$CRADLE_ROOT/bin/cradle" init
  git -c user.name=t -c user.email=t@x commit -q --allow-empty -m x
  . "$CRADLE_ROOT/lib/common.sh"; . "$CRADLE_ROOT/lib/render.sh"; d=$(testd_dir "$(project_key "$P")")
  ( sleep 1; f=$(ls "$d/req/new"); id=${f%.json}; mkdir -p "$d/results/$id"
    echo '{"status":"passed","reason":"job test passed"}' > "$d/results/$id/status.json" ) &
  run "$CRADLE_ROOT/bin/cradle" test test
  [ "$status" -eq 0 ]; [[ "$output" == *"passed: job test passed"* ]]
}

@test "the path unit watches req/new for any entry" {
  grep -qx 'DirectoryNotEmpty=%h/.local/state/cradle/testd/%i/req/new' "$CRADLE_ROOT/testd/cradle-testd@.path"
}
```
Run: `bats tests/testd-wire.bats` — Expected: FAIL.

- [ ] **Step 4: Implement.**
  - `lib/testd.sh`:

```bash
_unit_dir() { printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"; }

testd_install() {
  local u; u=$(_unit_dir); mkdir -p "$u"
  cp "$CRADLE_ROOT/testd/cradle-testd@.path" "$u/"
  sed "s|@CRADLE_ROOT@|$CRADLE_ROOT|g" "$CRADLE_ROOT/testd/cradle-testd@.service" > "$u/cradle-testd@.service"
  systemctl --user daemon-reload
  systemctl --user enable --now "cradle-testd@$1.path" >/dev/null
}

testd_uninstall() { systemctl --user disable --now "cradle-testd@$1.path" >/dev/null 2>&1 || true; }

# cmd_test JOB [REF]: host-side request through the same script the container uses.
cmd_test() {
  local d; d=$(testd_dir "$(project_key "$PWD")")
  [[ -d $d/req/new ]] || die "this project is not attached; run: cradle init"
  CRADLE_REQUESTS="$d/req" CRADLE_RESULTS="$d/results" "$CRADLE_ROOT/bin/cradle-request" "$@"
}
```
  - `lib/init.sh`: source `lib/testd.sh` and `lib/proxy.sh`. In `cmd_init`: handle `--detach` first (`testd_uninstall "$key"; proxy_down "$dir"; podman network rm -f "cradle-$key" >/dev/null 2>&1 || true; msg "detached %s; its volumes and results are kept"`, return). Otherwise, before writing cradle.json: if `.github/workflows/ci.yml` is absent, copy `templates/ci.yml` there and set `jobs='[{"workflow":"ci.yml","job":"test","network":false}]'`, else `jobs='[]'`; copy `templates/actrc` to `.actrc` if absent; pass `--argjson jobs "$jobs"` into the jq that writes cradle.json (`testJobs: $jobs`); after writing: `testd_prepare "$dir"; testd_install "$(project_key "$dir")"`. Usage: `cradle init [--force|--detach]`.
  - `templates/ci.yml`:

```yaml
# Written by cradle init. Tier 2 runs the "test" job locally (cradle test test,
# or cradle-request test in the container); GitHub runs everything.
name: ci
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: echo "replace with the project's test command"
  os-matrix:
    needs: test
    strategy:
      matrix:
        os: [ubuntu-latest, windows-latest, macos-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - run: echo "replace with the project's test command"
```
  - `templates/actrc`: `-P ubuntu-latest=docker.io/catthehacker/ubuntu:act-latest`
  - `lib/render.sh`: in `render_devcontainer`, with `d=$(testd_dir "$(project_key "$dir")")`, `mkdir -p "$d/req/tmp" "$d/req/new" "$d/results"` and append to the extra runArgs: `--volume=$d/req:/home/dev/.cradle/requests`, `--volume=$d/results:/home/dev/.cradle/results:ro`, `--volume=$CRADLE_ROOT/bin/cradle-request:/usr/local/bin/cradle-request:ro`; containerEnv `CRADLE_REQUESTS: "/home/dev/.cradle/requests"`, `CRADLE_RESULTS: "/home/dev/.cradle/results"`.
  - `lib/doctor.sh` `check_testd`: in an attached project (`.devcontainer/cradle.json` exists), `systemctl --user is-active --quiet "cradle-testd@$key.path"` → ok, else warn "tier-2 runner not active; run: cradle init --force". Add a doctor test in the existing style.
  - `bin/cradle`: `test) group=testd ;;` and usage `test JOB [REF]   run a tier-2 job on the host`; add `cradle-request` to the Makefile lint list.
  - Existing tests: `tests/init.bats` needs `stub systemctl` and `XDG_CONFIG_HOME`/`XDG_STATE_HOME` in its setup; its schema test now expects `testJobs` from the template.

- [ ] **Step 5: Run** `make check` — Expected: all green.

- [ ] **Step 6: Commit** — `git add -A && git commit -m "Wire tier-2 tests into init, the container and the CLI"`

---

### Task 5: Integration and security tests on real podman

**Files:**
- Create: `tests/integration/testd.sh`
- Modify: `Makefile` (target `testd-integration`), `dev/takeaways.md`

**Interfaces:**
- Consumes: everything above; images `cradle-base`, `cradle-proxy`, `ACT_IMAGE` pulled.

- [ ] **Step 1: Write `tests/integration/testd.sh`** — fixture project in `mktemp -d` with a `.github/workflows/ci.yml` whose `test` job runs `test -f README && ! curl -sf -m 5 https://example.com` (no network), plus jobs `hostvol` (`container: {image: alpine, volumes: ["/:/host"]}`) and `priv` (`container: {image: alpine, options: --privileged}`); `cradle.json` testJobs lists `test`, `hostvol`, `priv`. Trap: `cradle init --detach`, `cradle down`, remove the fixture's volumes, networks, results dir and worktrees. Checks (same `check/absent/eq` helpers as `foundation.sh`):

```bash
"$C" init --force >/dev/null || fail init            # re-writes cradle.json with the fixture jobs afterwards
# (write the fixture cradle.json testJobs here, then:)
"$C" approve-workflows --yes >/dev/null || fail approve
check "path unit active"          systemctl --user is-active --quiet "cradle-testd@$K.path"
check "host: cradle test passes"  "$C" test test
check "unknown job rejected"      absent "$C" test deploy
check "host volume job rejected"  absent "$C" test hostvol
check "privileged job rejected"   absent "$C" test priv
git -c user.name=t -c user.email=t@x commit -qam "change workflow" # after editing ci.yml
check "unapproved change rejected" absent "$C" test test
git reset -q --hard HEAD~1
printf '{"ref":"%s","job":"test","x":1}' "$(git rev-parse HEAD)" > "$D/req/new/extra.json"
sleep 5
check "extra field rejected"      eq "$(jq -r .status "$D/results/extra/status.json")" rejected
"$C" up >/dev/null || fail up
check "container: cradle-request passes" in_c 'cd "$CRADLE_WORKSPACE" && cradle-request test'
check "container cannot write results"   absent in_c 'touch ~/.cradle/results/x'
check "no socket, no network in the job" grep -q "Job succeeded" "$D/results/$(ls -t "$D/results" | head -1)/act.log"
```
(The `test` job's `! curl …` step proves `--network none`; add `test ! -S /var/run/docker.sock` to prove no socket.)

- [ ] **Step 2: Run for real** (systemd-run; log deleted first; wait for `EXIT=`). Expected: every check ok. The first act run pulls nothing new (image from Spike B) but downloads `actions/checkout` on the host. Record act/podman quirks in `dev/takeaways.md`.

- [ ] **Step 3: Commit** — `git add -A tests/integration Makefile dev/takeaways.md && git commit -m "Check tier-2 runs and their refusals end to end"`

---

## Out of scope here

- A CI template per language (the template's steps are placeholders the project fills in).
- Windows and macOS jobs locally (spec non-goal; GitHub runs them).
- Cleaning old results (`results/` grows; a `cradle test --prune` can come later).
