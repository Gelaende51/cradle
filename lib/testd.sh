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

# _rm_tree PATH: remove PATH without following a symlink, even where the
# container left a directory read-only.
_rm_tree() {
  if [[ -d $1 && ! -L $1 ]]; then chmod -R u+rwx -- "$1" 2>/dev/null || true; fi
  rm -rf -- "$1" 2>/dev/null || true
}

# request_take KEY: new/ → processing/; prints the ids of plausible requests.
request_take() {
  local key=$1 d b n=0 name why
  d=$(testd_dir "$key"); b="$d/processing/.batch"
  # Take new/ as a whole: a rename moves new/ itself, or whatever the container
  # planted in its place, never what a symlink points to. The batch is then
  # host-private, so nothing below resolves a path the container can swap.
  if [[ ! -e $b && ! -L $b ]]; then
    mv -T -- "$d/req/new" "$b" 2>/dev/null || true
    mkdir -- "$d/req/new" 2>/dev/null || true
  fi
  [[ -e $b || -L $b ]] || return 0
  if [[ -L $b || ! -d $b ]]; then
    rm -f -- "$b"
    result_write "$key" "invalid-$(date +%s)-0" rejected "requests/new was not a directory" >/dev/null
    return 0
  fi
  while IFS= read -r -d '' name; do
    why="not a request: entries in requests/new must be regular files named <id>.json ([A-Za-z0-9_-], at most 64)"
    if [[ $name =~ ^[A-Za-z0-9_-]{1,64}\.json$ ]]; then
      if [[ -e $d/processing/$name || -L $d/processing/$name ]]; then
        why="request id ${name%.json} is already queued"
      elif mv -T -- "$b/$name" "$d/processing/$name" 2>/dev/null; then
        if [[ -f $d/processing/$name && ! -L $d/processing/$name ]]; then printf '%s\n' "${name%.json}"; continue; fi
        _rm_tree "$d/processing/$name"
      fi
    fi
    n=$((n + 1))
    result_write "$key" "invalid-$(date +%s)-$n" rejected "$why" >/dev/null
  done < <(find "$b" -mindepth 1 -maxdepth 1 -printf '%P\0')
  _rm_tree "$b"
}

# The shared .git is writable by the container, which can rewrite an object's
# content under its name. Everything tier 2 reads from a commit comes from a
# host-private mirror instead: fetching re-hashes every object it receives, so
# a rewritten object breaks the fetch rather than reaching act.
_mirror() { printf '%s' "$(testd_dir "$1")/mirror.git"; }
_mirror_init() { [[ -d $1 ]] || _git_host init -q --bare "$1"; }

# _fetch DIR REF: REF (a full SHA) and everything it reaches, into the mirror.
_fetch() {
  local m; m=$(_mirror "$(project_key "$1")")
  _mirror_init "$m" || return 1
  _git_host -C "$m" cat-file -e "$2^{commit}" 2>/dev/null && return 0
  _git_host -C "$m" fetch -q --no-tags --no-write-fetch-head "$1" "+$2:refs/cradle/$2" >/dev/null 2>&1
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
  _fetch "$dir" "$ref" || { echo "commit $ref is not in the repository, or its objects are damaged"; return 1; }
  jq -e --arg j "$job" '[.testJobs[]?.job] | index($j) != null' "$dir/.devcontainer/cradle.json" >/dev/null \
    || { echo "job $job is not listed in cradle.json testJobs"; return 1; }
  printf '%s %s\n' "$ref" "$job"
}

_yaml_json() { python3 -c 'import json, sys, yaml; json.dump(yaml.safe_load(sys.stdin), sys.stdout)'; }

github_tree() { _fetch "$1" "$2" && _git_host -C "$(_mirror "$(project_key "$1")")" rev-parse -q --verify "$2:.github" 2>/dev/null; }
approved_add() { local d; d=$(testd_dir "$1"); grep -qs "^$2 " "$d/approved" || printf '%s %s\n' "$2" "$3" >> "$d/approved"; }
is_approved() { grep -qs "^$2 " "$(testd_dir "$1")/approved"; }

# _symlink_check MIRROR REF: act copies the tree into the job container and
# reads the workflow and local actions on the host, so no symlink may lead out
# of the tree, and none may sit under .github.
_symlink_check() {
  _git_host -C "$1" ls-tree -r -z "$2" | python3 -c '
import posixpath, subprocess, sys
git = ["git", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-C", sys.argv[1]]
for e in sys.stdin.buffer.read().split(b"\0"):
    if not e:
        continue
    meta, path = e.split(b"\t", 1)
    mode, _, oid = meta.split()
    if mode != b"120000":
        continue
    p = path.decode("utf-8", "replace")
    t = subprocess.run(git + ["cat-file", "blob", oid.decode()], capture_output=True, check=True).stdout.decode("utf-8", "replace")
    if p.startswith(".github/"):
        sys.exit(f"symlink {p}: symlinks under .github are not allowed")
    n = posixpath.normpath(posixpath.join(posixpath.dirname(p), t))
    if t.startswith("/") or n == ".." or n.startswith("../"):
        sys.exit(f"symlink {p} leads out of the repository")
' "$1" 2>&1
}

# job_check DIR REF JOB: prints the workflow file, or a reason and returns 1.
job_check() {
  local dir=$1 ref=$2 job=$3 key m wf tree json bad
  key=$(project_key "$dir"); m=$(_mirror "$key")
  wf=$(jq -r --arg j "$job" '[.testJobs[] | select(.job == $j)][0].workflow // empty' "$dir/.devcontainer/cradle.json")
  [[ $wf =~ ^[A-Za-z0-9._-]+\.ya?ml$ ]] || { echo "testJobs entry for $job needs a workflow file name like ci.yml"; return 1; }
  tree=$(github_tree "$dir" "$ref") || { echo "commit $ref has no .github directory"; return 1; }
  is_approved "$key" "$tree" || { echo ".github at ${ref:0:12} is not approved; run on the host: cradle approve-workflows ${ref:0:12}"; return 1; }
  bad=$(_symlink_check "$m" "$ref") || { echo "${bad:-cannot list the tree of ${ref:0:12}}"; return 1; }
  json=$(_git_host -C "$m" show "$ref:.github/workflows/$wf" 2>/dev/null | _yaml_json 2>/dev/null) \
    || { echo "cannot read .github/workflows/$wf at ${ref:0:12}"; return 1; }
  # an allowlist of shapes; any jq error (an unexpected type) refuses the job
  bad=$(jq -r --arg j "$job" '
    def expr: tostring | test("\\$\\{\\{");
    def localuse: startswith("./");
    def safelocal: test("^\\./\\.github/[A-Za-z0-9._/-]+$") and (test("(^|/)\\.\\.(/|$)") | not);
    if type != "object" or (.jobs | type) != "object" then "the workflow has no jobs mapping"
    else .jobs[$j] as $d
    | if ($d | type) != "object" then "job \($j) is not in the workflow"
      elif ($d | has("uses")) then "reusable workflows (jobs.<id>.uses) are not allowed"
      elif $d["runs-on"] != "ubuntu-latest" then "runs-on must be ubuntu-latest, the only platform cradle maps"
      elif [$d.container, $d.services] | map(select(. != null) | expr) | any then "expressions in container or services are not allowed"
      elif ($d.container | type) == "object" and (($d.container.options // null) != null or ($d.container.volumes // null) != null)
        then "container.options and container.volumes are not allowed"
      elif [($d.services // {})[] | select(type != "object" or (.volumes // null) != null or (.options // null) != null)] | length > 0
        then "services with volumes or options are not allowed"
      elif [$d | del(.steps[]?.run) | .. | strings | select(test("--privileged|--volume|(^|\\s)-v\\s|docker\\.sock|podman\\.sock"))] | length > 0
        then "--privileged, volumes and container sockets are not allowed"
      elif [($d.steps // [])[] | (.uses // "") | select(localuse and (safelocal | not))] | length > 0
        then "local actions outside .github are not allowed"
      else empty end
    end' <<< "$json" 2>/dev/null) || bad="the job definition has an unexpected shape"
  [[ -z $bad ]] || { echo "$bad"; return 1; }
  printf '%s\n' "$wf"
}

cmd_approve_workflows() {
  local yes=0 ref key m tree prev a url base
  [[ ${1:-} == --yes ]] && { yes=1; shift; }
  ref=$(_git_host rev-parse --verify "${1:-HEAD}^{commit}") || die "no commit %s" "${1:-HEAD}"
  key=$(project_key "$PWD"); testd_prepare "$PWD"; m=$(_mirror "$key"); _mirror_init "$m"
  # The remote default branch counts as reviewed. It is read from the remote
  # itself: the local refs/remotes/* are writable by the container.
  if url=$(_git_host remote get-url origin 2>/dev/null) \
     && GIT_TERMINAL_PROMPT=0 _git_host -C "$m" fetch -q --no-tags --no-write-fetch-head "$url" "+HEAD:refs/cradle/origin-head" >/dev/null 2>&1 \
     && base=$(_git_host -C "$m" rev-parse -q --verify "refs/cradle/origin-head^{commit}") \
     && tree=$(_git_host -C "$m" rev-parse -q --verify "$base:.github"); then
    approved_add "$key" "$tree" "$base"
  fi
  tree=$(github_tree "$PWD" "$ref") || die "commit %s has no .github directory (or its objects are damaged)" "${ref:0:12}"
  is_approved "$key" "$tree" && { msg ".github at %s is already approved" "${ref:0:12}"; return 0; }
  prev=$(sed -n '$s/.* //p' "$(testd_dir "$key")/approved" 2>/dev/null) || prev=""
  [[ -n $prev ]] && _git_host -C "$m" cat-file -e "$prev^{commit}" 2>/dev/null || prev=$(_git_host hash-object -t tree /dev/null)
  _git_host -C "$m" --no-pager diff "$prev" "$ref" -- .github
  if (( ! yes )); then
    read -rp "$(_t "approve .github at this commit for tier-2 runs? [y/N] ")" a || a=""
    [[ $a == [yYjJ] ]] || die "not approved"
  fi
  approved_add "$key" "$tree" "$ref"
  msg "approved .github at %s" "${ref:0:12}"
}

_runs_dir() { printf '%s' "${XDG_CACHE_HOME:-$HOME/.cache}/cradle/runs"; }

# result_reserve KEY ID: claim results/<id>/ for a run; prints the id (a fresh
# one when ID already has results, which are never overwritten).
result_reserve() {
  local d id=$2; d=$(testd_dir "$1")
  mkdir -- "$d/results/$id" 2>/dev/null || { id="$id-$(date +%s)-$RANDOM"; mkdir -- "$d/results/$id"; }
  printf '%s\n' "$id"
}

# _recover KEY: a previous runner died; report and clean what it left.
_recover() {
  local key=$1 d f id w m; d=$(testd_dir "$key"); m=$(_mirror "$key")
  for f in "$d"/processing/*.json; do
    [[ -e $f ]] || continue
    id=$(basename "$f" .json)
    result_write "$key" "$id" aborted "the test runner stopped before this request finished" >/dev/null
    mv -- "$f" "$d/done/"
  done
  for w in "$(_runs_dir)/$key"-*; do
    [[ -e $w ]] || continue
    _git_host -C "$m" worktree remove --force "$w" 2>/dev/null || _rm_tree "$w"
  done
  [[ ! -d $m ]] || _git_host -C "$m" worktree prune
}

# _run_job KEY DIR ID REF JOB WF: act in a worktree of REF; prints the status.
_run_job() {
  local key=$1 dir=$2 id=$3 ref=$4 job=$5 wf=$6 d m res run cwd net mins rc
  d=$(testd_dir "$key"); m=$(_mirror "$key"); res="$d/results/$id"; run="$(_runs_dir)/$key-$id"
  mkdir -p "$res/artifacts" "$(_runs_dir)"
  net=none
  [[ $(jq -r --arg j "$job" '[.testJobs[] | select(.job == $j)][0].network // false' "$dir/.devcontainer/cradle.json") == true ]] && net=podman
  mins=$(jq -r '.testTimeout // 30' "$dir/.devcontainer/cradle.json")
  [[ $mins =~ ^[0-9]{1,3}$ ]] || mins=30
  _git_host -C "$m" worktree add -q --detach "$run" "$ref" >/dev/null 2>&1 || { echo "failed cannot create a worktree of ${ref:0:12}"; return 0; }
  # act reads .actrc from its working directory and .env, .secrets, .vars and
  # .input from -C: run it from an empty directory and give it none of those.
  cwd=$(mktemp -d)
  rc=0
  ( cd "$cwd" && timeout "${mins}m" act -C "$run" -W ".github/workflows/$wf" -j "$job" -P "ubuntu-latest=$ACT_IMAGE" \
      --container-daemon-socket - --network "$net" --container-options "--memory=2g" --rm \
      --artifact-server-path "$res/artifacts" \
      --env-file /dev/null --secret-file /dev/null --var-file /dev/null --input-file /dev/null ) > "$res/act.log" 2>&1 || rc=$?
  rm -rf -- "$cwd"
  _git_host -C "$m" worktree remove --force "$run" 2>/dev/null || _rm_tree "$run"
  case $rc in
    0) echo "passed job $job passed" ;;
    124) echo "timeout job $job ran longer than $mins minutes" ;;
    *) echo "failed job $job failed (act exit $rc); see act.log" ;;
  esac
}

testd_run() {
  local key=$1 d dir id rid out ref job wf status reason
  d=$(testd_dir "$key"); dir=$(cat "$d/project")
  # shellcheck source=image/versions.env
  . "$CRADLE_ROOT/image/versions.env"
  exec 9> "${XDG_STATE_HOME:-$HOME/.local/state}/cradle/testd/run.lock"
  flock 9   # one run at a time, across projects
  _recover "$key"
  while :; do
    request_take "$key" >/dev/null
    id=$(find "$d/processing" -maxdepth 1 -name '*.json' -printf '%f\n' | sort | head -n 1)
    [[ -n $id ]] || break
    id=${id%.json}
    rid=$(result_reserve "$key" "$id")
    if out=$(request_check "$dir" "$d/processing/$id.json") && read -r ref job <<< "$out" \
       && out=$(job_check "$dir" "$ref" "$job"); then
      wf=$out
      read -r status reason <<< "$(_run_job "$key" "$dir" "$rid" "$ref" "$job" "$wf")"
      result_write "$key" "$rid" "$status" "$reason" "$job" "$ref" >/dev/null
    else
      result_write "$key" "$rid" rejected "$out" "${job:-}" "${ref:-}" >/dev/null
    fi
    mv -- "$d/processing/$id.json" "$d/done/"
    ref=""; job=""
  done
}

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
