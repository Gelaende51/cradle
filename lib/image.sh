#!/usr/bin/env bash
# cradle image build: build cradle-base, switching the tag only on success.

_build_args() {
  local k v
  while IFS='=' read -r k v; do
    [[ -z $k || $k == \#* ]] && continue
    printf '%s\n' --build-arg "$k=$v"
  done < "$CRADLE_ROOT/image/versions.env"
}

image_build() {
  need podman
  local tag tmp args=()
  tag="cradle-base:$(cradle_version)"
  tmp="cradle-base:building-$$"
  mapfile -t args < <(_build_args)
  if ! podman build "${args[@]}" -t "$tmp" -f "$CRADLE_ROOT/image/Containerfile" "$CRADLE_ROOT/image"; then
    podman rmi -f "$tmp" >/dev/null 2>&1 || true
    die "image build failed; %s left unchanged" "$tag"
  fi
  podman tag "$tmp" "$tag"
  podman rmi "$tmp" >/dev/null
  msg "built %s" "$tag"
}

cmd_image() {
  case ${1:-} in
    build) image_build ;;
    *) die "usage: cradle image build" ;;
  esac
}
