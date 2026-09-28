#!/usr/bin/env bash
# cradle up/down/claude/shell/push: the project's dev container session.
# shellcheck source=lib/render.sh
. "$CRADLE_ROOT/lib/render.sh"
# shellcheck source=lib/token.sh
. "$CRADLE_ROOT/lib/token.sh"
# shellcheck source=lib/config.sh
. "$CRADLE_ROOT/lib/config.sh"

# The file events backend avoids a lost start event (see lib/podman-events.conf).
_dc() {
  CONTAINERS_CONF_OVERRIDE="$CRADLE_ROOT/lib/podman-events.conf" \
    devcontainer "$1" --docker-path podman --workspace-folder "$PWD" "${@:2}"
}

# Export GH_TOKEN for the devcontainer CLI (remoteEnv reads it); silent without one.
# Only the repo's own keyring token goes in, never one the host shell happens to have.
_session_token() {
  local r t
  unset GH_TOKEN GITHUB_TOKEN
  r=$(repo_slug) || return 0
  t=$(token_lookup "$r") || return 0
  [[ -n $t ]] && export GH_TOKEN=$t
  return 0
}

cmd_up() {
  need podman; need devcontainer
  render_devcontainer "$PWD"
  config_is_current || config_sync >/dev/null
  _session_token
  local id cur flags=()
  # masks, memory and features only apply when the container is created
  id=$(podman ps -aq --filter "label=devcontainer.local_folder=$PWD" | head -n1)
  [[ -n $id ]] && cur=$(podman inspect --format '{{index .Config.Labels "cradle.render"}}' "$id")
  if [[ -n $id && ${cur:-} != "$(render_id "$PWD")" ]]; then
    msg "the configuration changed; recreating the dev container"
    flags=(--remove-existing-container)
  fi
  _dc up "${flags[@]}" >/dev/null
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

# _exec CMD...: run CMD as dev in the workspace. podman exec, not devcontainer exec:
# the CLI would put the token on podman's command line (-e GH_TOKEN=value).
_exec() {
  local id tty=()
  id=$(podman ps -q --filter "label=devcontainer.local_folder=$PWD" | head -n1)
  [[ -n $id ]] || die "no running dev container for %s" "$PWD"
  [[ -t 0 && -t 1 ]] && tty=(-t)
  podman exec -i "${tty[@]}" -e GH_TOKEN -u dev \
    -w "$(tail -n +2 .devcontainer/devcontainer.json | jq -r .workspaceFolder)" "$id" "$@"
}

cmd_claude() { cmd_up >/dev/null; _exec claude "$@"; }
cmd_shell()  { cmd_up >/dev/null; _exec bash -l; }

# Host git on a tree a container wrote to: never run its hooks or fsmonitor.
_git_host() { git -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"; }

cmd_push() {
  local yes=0 up a
  [[ ${1:-} == --yes ]] && { yes=1; shift; }
  up=$(_git_host rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || up=""
  [[ -n $up ]] && _git_host --no-pager diff --stat "$up..HEAD" -- .github/workflows
  if (( ! yes )); then
    read -rp "$(_t "push with your host credentials? [y/N] ")" a || a=""
    [[ $a == [yY] ]] || die "push cancelled"
  fi
  _git_host push "$@"
}
