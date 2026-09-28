#!/usr/bin/env bash
# cradle init: attach the current project (writes .devcontainer/cradle.json).
# shellcheck source=lib/render.sh
. "$CRADLE_ROOT/lib/render.sh"

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

cmd_init() {
  local force=0 dir=$PWD cfg
  [[ ${1:-} == --force ]] && force=1
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: %s" "$dir"
  cfg="$dir/.devcontainer/cradle.json"
  if [[ -f $cfg ]] && (( ! force )); then
    die "%s exists; use --force to regenerate it" "$cfg"
  fi
  mkdir -p "$dir/.devcontainer"
  jq -n --argjson langs "$(detect_languages "$dir")" \
    '{languages: $langs, features: {}, maskPaths: [".personal"], memory: "3g", allowedDomains: [], testJobs: []}' > "$cfg"
  _add_gitignore_block "$dir"
  msg "attached %s (languages: %s); next: cradle claude" "$dir" "$(jq -r '.languages | join(", ")' "$cfg")"
}
