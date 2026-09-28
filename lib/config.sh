#!/usr/bin/env bash
# cradle config sync: copy the kit's config into the shared volume cradle-claude.
# Dev containers can write that volume, so the host never touches its files:
# lib/volume-sync.sh does the work in a throwaway container, and the manifest of
# files the kit owns stays on the host.

_config_manifest() { printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/cradle/config-manifest"; }

# _volume_sync MODE: run lib/volume-sync.sh on the volume; stdin and stdout pass through.
_volume_sync() {
  local src=${CRADLE_CONFIG_DIR:-$CRADLE_ROOT/config}
  podman run --rm -i --pull=never --network=none --cap-drop=ALL --security-opt=no-new-privileges \
    --user=0:0 -v cradle-claude:/dst -v "$src:/src:ro" \
    -v "$CRADLE_ROOT/lib/volume-sync.sh:/volume-sync.sh:ro" \
    "localhost/cradle-base:$(cradle_version)" bash /volume-sync.sh "$1" /src /dst
}

config_sync() {
  need podman
  local manifest; manifest=$(_config_manifest)
  podman volume exists cradle-claude || podman volume create cradle-claude >/dev/null
  mkdir -p "$(dirname "$manifest")"; touch "$manifest"
  _volume_sync sync < "$manifest" > "$manifest.new" || { rm -f "$manifest.new"; die "config sync failed"; }
  mv "$manifest.new" "$manifest"
  msg "synced %s files into volume cradle-claude" "$(wc -l < "$manifest")"
}

# config_is_current: 0 when the volume holds every kit file (settings.json: the kit's keys).
config_is_current() {
  podman volume exists cradle-claude || return 1
  _volume_sync check </dev/null
}

cmd_config() {
  case ${1:-} in
    sync) config_sync ;;
    *) die "usage: cradle config sync" ;;
  esac
}
