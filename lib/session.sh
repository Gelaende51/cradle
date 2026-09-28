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
