#!/usr/bin/env bash
# cradle doctor: host health checks, one line per check.
# shellcheck source=image/versions.env
. "$CRADLE_ROOT/image/versions.env"
# shellcheck source=lib/config.sh
. "$CRADLE_ROOT/lib/config.sh"
# shellcheck source=lib/token.sh
. "$CRADLE_ROOT/lib/token.sh"
# shellcheck source=lib/render.sh
. "$CRADLE_ROOT/lib/render.sh"
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
  local n tag
  for n in cradle-base cradle-proxy; do
    tag="$n:$(cradle_version)"
    if podman image exists "$tag"; then _report ok image "%s" "$tag"
    else _report warn image "%s not built; run: cradle image build" "$tag"; fi
  done
}

check_config() {
  have podman || return 0
  if config_is_current; then _report ok config "config volume matches the kit"
  else _report warn config "config volume is missing or stale; run: cradle config sync"; fi
}

# check_proxy: in an attached project, its egress proxy should be running.
check_proxy() {
  have podman || return 0
  [[ -f .devcontainer/cradle.json ]] || return 0
  local name; name="cradle-proxy-$(project_key "$PWD")"
  if [[ $(podman inspect --format '{{.State.Running}}' "$name" 2>/dev/null) == true ]]; then
    _report ok proxy "%s is running" "$name"
  else _report warn proxy "%s is not running; run: cradle up" "$name"; fi
}

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
  check_config
  check_proxy
  check_token
  check_disk
  check_ram
  return "$DOCTOR_FAIL"
}
