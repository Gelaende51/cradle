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
