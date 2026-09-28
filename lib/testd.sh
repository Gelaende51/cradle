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
