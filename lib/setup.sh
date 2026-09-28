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
  python3 -c 'import yaml' >/dev/null 2>&1 || missing_pkgs+=(python-yaml)
  ((${#missing_pkgs[@]})) && sudo_needed+=("sudo pacman -S --needed ${missing_pkgs[*]}")

  if ! have devcontainer; then
    _act "$yes" "install the devcontainer CLI" npm install -g --prefix "$HOME/.local" "@devcontainers/cli@$DEVCONTAINER_CLI_VERSION"
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
