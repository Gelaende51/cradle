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
  prev=$(sed -n '$s/.* //p' "$(testd_dir "$key")/approved" 2>/dev/null) || prev=""
  [[ -n $prev ]] || prev=$(_git_host hash-object -t tree /dev/null)
  _git_host --no-pager diff "$prev" "$ref" -- .github
  if (( ! yes )); then
    read -rp "$(_t "approve .github at this commit for tier-2 runs? [y/N] ")" a || a=""
    [[ $a == [yY] ]] || die "not approved"
  fi
  approved_add "$key" "$tree" "$ref"
  msg "approved .github at %s" "${ref:0:12}"
}

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
