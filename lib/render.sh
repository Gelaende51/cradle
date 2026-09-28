#!/usr/bin/env bash
# Generate .devcontainer/devcontainer.json from .devcontainer/cradle.json,
# the single editable source. A stored hash detects hand edits.

FEATURES_JSON='{
  "node":   {"ghcr.io/devcontainers/features/node:1":   {"version": "lts"}},
  "python": {"ghcr.io/devcontainers/features/python:1": {"version": "3.13"}},
  "go":     {"ghcr.io/devcontainers/features/go:1":     {}},
  "rust":   {"ghcr.io/devcontainers/features/rust:1":   {}},
  "java":   {"ghcr.io/devcontainers/features/java:1":   {}}
}'

project_slug() {
  local b; b=$(basename "$1"); b=${b,,}
  b=$(printf '%s' "$b" | LC_ALL=C tr -c 'a-z0-9' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//')
  printf '%s' "${b:-project}"
}

# project_key DIR: slug plus a hash of the absolute path, so two projects with the
# same folder name keep apart (volumes, networks, proxies).
project_key() {
  printf '%s-%s' "$(project_slug "$1")" "$(printf '%s' "$1" | sha256sum | cut -c1-8)"
}

# testd_dir KEY: the host state of a project's tier-2 test queue.
testd_dir() { printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/cradle/testd/$1"; }

# _mask_args DIR WORKSPACE: one podman run argument per existing mask path.
_mask_args() {
  local dir=$1 ws=$2 m
  while IFS= read -r m; do
    if [[ -d $dir/$m ]]; then printf '%s\n' "--tmpfs=$ws/$m:size=1k,mode=0500"
    elif [[ -f $dir/$m ]]; then printf '%s\n' "--volume=/dev/null:$ws/$m:ro"
    fi
  done < <(jq -r '.maskPaths[]?' "$dir/.devcontainer/cradle.json")
}

# _git_args DIR WORKSPACE: the host runs .git/hooks and reads .git/config (fsmonitor,
# hooksPath), and renders its next container from .devcontainer, so the container
# sees all three read-only.
_git_args() {
  local dir=$1 ws=$2
  printf '%s\n' "--volume=$dir/.devcontainer:$ws/.devcontainer:ro"
  [[ -d $dir/.git ]] || return 0
  mkdir -p "$dir/.git/hooks"
  printf '%s\n' "--volume=$dir/.git/hooks:$ws/.git/hooks:ro"
  [[ -f $dir/.git/config ]] && printf '%s\n' "--volume=$dir/.git/config:$ws/.git/config:ro"
  return 0
}

# _check_features CFG: features may only set options of the features cradle maps;
# any other feature can declare privileged, capAdd or mounts.
_check_features() {
  local bad
  bad=$(jq -r --argjson fmap "$FEATURES_JSON" \
    '[$fmap[] | keys[]] as $ok | (.features // {}) | keys[] | select(. as $k | $ok | index($k) | not)' "$1")
  [[ -z $bad ]] || die "feature %s is not on cradle's allowlist (FEATURES_JSON in lib/render.sh)" "${bad%%$'\n'*}"
}

# render_id DIR: the configuration hash the container carries as label cradle.render.
render_id() {
  tail -n +2 "$1/.devcontainer/devcontainer.json" \
    | jq -r '.runArgs[] | select(startswith("--label=cradle.render=")) | ltrimstr("--label=cradle.render=")'
}

render_devcontainer() {
  local dir=$1 cfg out hashf slug ws extra vol obj id
  cfg="$dir/.devcontainer/cradle.json"
  out="$dir/.devcontainer/devcontainer.json"
  hashf="$dir/.devcontainer/.cradle-hash"
  [[ -f $cfg ]] || die "no .devcontainer/cradle.json in %s; run: cradle init" "$dir"
  if [[ -f $out ]]; then
    [[ -f $hashf && $(sha256sum < "$out" | cut -d' ' -f1) == "$(cat "$hashf")" ]] \
      || die "%s was edited by hand; move the change into cradle.json, then delete devcontainer.json" "$out"
  fi
  slug=$(project_slug "$dir")
  ws="/home/dev/src/$slug"   # quarry only indexes directories under $HOME
  _check_features "$cfg"
  extra=$({ _mask_args "$dir" "$ws"; _git_args "$dir" "$ws"; } | jq -R . | jq -s .)
  vol="cradle-$(project_key "$dir")-data"
  # shellcheck disable=SC2016  # ${localWorkspaceFolder} and ${localEnv:…} are devcontainer variables
  obj=$(jq -n --slurpfile cfg "$cfg" --argjson fmap "$FEATURES_JSON" --argjson masks "$extra" \
      --arg slug "$slug" --arg key "$(project_key "$dir")" --arg ws "$ws" --arg vol "$vol" --arg image "localhost/cradle-base:$(cradle_version)" '
      $cfg[0] as $c | {
        name: ("cradle-" + $slug),
        image: $image,
        features: ((reduce ($c.languages // [])[] as $l ({}; . + ($fmap[$l] // {}))) + ($c.features // {})),
        remoteUser: "dev",
        containerUser: "dev",
        updateRemoteUserUID: false,
        workspaceFolder: $ws,
        workspaceMount: ("source=${localWorkspaceFolder},target=" + $ws + ",type=bind"),
        runArgs: (["--userns=keep-id:uid=1000,gid=1000", "--security-opt=no-new-privileges",
                   "--cap-drop=ALL", ("--memory=" + ($c.memory // "3g")),
                   ("--network=cradle-" + $key)] + $masks),
        mounts: ["source=cradle-claude,target=/home/dev/.claude,type=volume",
                 "source=cradle-punt,target=/home/dev/.punt-labs,type=volume",
                 ("source=" + $vol + ",target=/home/dev/.local/share/cradle,type=volume")],
        containerEnv: {
          CLAUDE_CONFIG_DIR: "/home/dev/.claude",
          CRADLE_WORKSPACE: $ws,
          QUARRY_ROOT: "/home/dev/.local/share/cradle/quarry",
          HF_HUB_OFFLINE: "1",
          HTTP_PROXY: "http://proxy:3128", HTTPS_PROXY: "http://proxy:3128",
          http_proxy: "http://proxy:3128", https_proxy: "http://proxy:3128",
          NO_PROXY: "localhost,127.0.0.1,::1", no_proxy: "localhost,127.0.0.1,::1",
          GIT_CONFIG_COUNT: "1",
          GIT_CONFIG_KEY_0: "core.hooksPath",
          GIT_CONFIG_VALUE_0: "/home/dev/.local/share/cradle/hooks"
        },
        remoteEnv: {GH_TOKEN: "${localEnv:GH_TOKEN}"},
        postCreateCommand: "/usr/local/share/cradle/postcreate.sh",
        postStartCommand: "/usr/local/share/cradle/poststart.sh"
      }')
  # the label lets "cradle up" see that an existing container was created from another config
  id=$(printf '%s' "$obj" | sha256sum | cut -d' ' -f1)
  {
    printf '// generated by cradle %s from cradle.json; edit cradle.json, not this file\n' "$(cradle_version)"
    jq --arg l "--label=cradle.render=$id" '.runArgs += [$l]' <<< "$obj"
  } > "$out.tmp"
  mv "$out.tmp" "$out"
  sha256sum < "$out" | cut -d' ' -f1 > "$hashf"
}
