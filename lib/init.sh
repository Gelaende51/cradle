#!/usr/bin/env bash
# cradle init: attach the current project (writes .devcontainer/cradle.json).
# shellcheck source=lib/render.sh
. "$CRADLE_ROOT/lib/render.sh"
# shellcheck source=lib/testd.sh
. "$CRADLE_ROOT/lib/testd.sh"
# shellcheck source=lib/proxy.sh
. "$CRADLE_ROOT/lib/proxy.sh"

GITIGNORE_BLOCK='# >>> cradle
.cradle/
.devcontainer/.cradle-hash
# <<< cradle'

detect_languages() {
  local d=$1 l=()
  [[ -f $d/package.json ]] && l+=(node)
  [[ -f $d/pyproject.toml || -f $d/requirements.txt || -f $d/setup.py ]] && l+=(python)
  [[ -f $d/go.mod ]] && l+=(go)
  [[ -f $d/Cargo.toml ]] && l+=(rust)
  [[ -f $d/pom.xml || -f $d/build.gradle || -f $d/build.gradle.kts ]] && l+=(java)
  if ((${#l[@]})); then printf '%s\n' "${l[@]}" | jq -R . | jq -sc .; else echo '[]'; fi
}

_add_gitignore_block() {
  local gi="$1/.gitignore"
  grep -qxF '# >>> cradle' "$gi" 2>/dev/null && return 0
  if [[ -s $gi && -n $(tail -c1 "$gi") ]]; then echo >> "$gi"; fi
  printf '%s\n' "$GITIGNORE_BLOCK" >> "$gi"
}

# cradle init [--force|--detach]
cmd_init() {
  local force=0 dir=$PWD cfg key jobs='[]'
  [[ ${1:-} == --force ]] && force=1
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: %s" "$dir"
  key=$(project_key "$dir")
  if [[ ${1:-} == --detach ]]; then
    testd_uninstall "$key"
    proxy_down "$dir"
    podman network rm -f "cradle-$key" >/dev/null 2>&1 || true
    msg "detached %s; its volumes and results are kept" "$dir"
    return 0
  fi
  cfg="$dir/.devcontainer/cradle.json"
  if [[ -f $cfg ]] && (( ! force )); then
    die "%s exists; use --force to regenerate it" "$cfg"
  fi
  mkdir -p "$dir/.devcontainer"
  if [[ ! -e $dir/.github/workflows/ci.yml ]]; then
    mkdir -p "$dir/.github/workflows"
    cp "$CRADLE_ROOT/templates/ci.yml" "$dir/.github/workflows/ci.yml"
    jobs='[{"workflow":"ci.yml","job":"test","network":false}]'
  fi
  [[ -e $dir/.actrc ]] || cp "$CRADLE_ROOT/templates/actrc" "$dir/.actrc"
  jq -n --argjson langs "$(detect_languages "$dir")" --argjson jobs "$jobs" \
    '{languages: $langs, features: {}, maskPaths: [".personal"], memory: "3g", allowedDomains: [], testJobs: $jobs}' > "$cfg"
  _add_gitignore_block "$dir"
  testd_prepare "$dir"
  testd_install "$key"
  msg "attached %s (languages: %s); next: cradle claude" "$dir" "$(jq -r '.languages | join(", ")' "$cfg")"
}
