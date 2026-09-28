#!/usr/bin/env bash
# cradle image build: build cradle-base and cradle-proxy, switching each tag only on success.

_build_args() {
  local k v
  while IFS='=' read -r k v; do
    [[ -z $k || $k == \#* ]] && continue
    printf '%s\n' --build-arg "$k=$v"
  done < "$CRADLE_ROOT/image/versions.env"
}

# _build_one NAME DIR: build DIR/Containerfile as NAME:<version>; the tag moves only on success.
_build_one() {
  local name=$1 dir=$2 tag tmp args=()
  tag="$name:$(cradle_version)"
  tmp="$name:building-$$"
  mapfile -t args < <(_build_args)
  if ! podman build "${args[@]}" -t "$tmp" -f "$dir/Containerfile" "$dir"; then
    podman rmi -f "$tmp" >/dev/null 2>&1 || true
    die "image build failed; %s left unchanged" "$tag"
  fi
  podman tag "$tmp" "$tag"
  podman rmi "$tmp" >/dev/null
  msg "built %s" "$tag"
}

image_build() {
  need podman
  _build_one cradle-base "$CRADLE_ROOT/image"
  _build_one cradle-proxy "$CRADLE_ROOT/proxy"
}

cmd_image() {
  case ${1:-} in
    build) image_build ;;
    *) die "usage: cradle image build" ;;
  esac
}
