#!/usr/bin/env bash
# cradle secret: per-repo secrets (API tokens) in the host keyring, handed to the
# dev container's sessions as environment variables. A project names the ones it
# uses in cradle.json "secrets"; values never reach a file or a command line.
# shellcheck source=lib/token.sh
. "$CRADLE_ROOT/lib/token.sh"

# A shell variable name; GH_TOKEN and GITHUB_TOKEN belong to cradle token.
secret_name_ok() { [[ $1 =~ ^[A-Z][A-Z0-9_]*$ && $1 != GH_TOKEN && $1 != GITHUB_TOKEN ]]; }

secret_lookup() { secret-tool lookup service cradle-secret repo "$1" name "$2" 2>/dev/null; }

# secret_names [DIR]: the names the project's cradle.json declares, one per line.
secret_names() {
  local n
  while IFS= read -r n; do
    secret_name_ok "$n" && printf '%s\n' "$n"
  done < <(jq -r '.secrets[]?' "${1:-$PWD}/.devcontainer/cradle.json" 2>/dev/null)
  return 0
}

_secret_declared() { secret_names | grep -qx "$1"; }

_secret_set() {
  local repo=$1 name=$2 v
  if [[ -t 0 ]]; then read -rsp "$(_t "value of") $name ($repo): " v; echo; else read -r v; fi
  [[ -n $v ]] || die "empty value"
  printf '%s' "$v" | secret-tool store --label="cradle secret $name $repo" service cradle-secret repo "$repo" name "$name"
  msg "stored %s for %s" "$name" "$repo"
  _secret_declared "$name" || warn "%s is not in \"secrets\" in .devcontainer/cradle.json; sessions get it once it is" "$name"
}

_secret_list() {
  local repo=$1 n any=0
  while IFS= read -r n; do
    any=1
    if secret_lookup "$repo" "$n" >/dev/null; then msg "%s: stored" "$n"; else msg "%s: missing; run: cradle secret set %s" "$n" "$n"; fi
  done < <(secret_names)
  (( any )) || msg "no secrets declared in .devcontainer/cradle.json"
}

cmd_secret() {
  local sub=${1:-} name=${2:-} repo=${3:-}
  [[ $sub == list ]] && repo=${2:-}
  [[ -n $repo ]] || repo=$(repo_slug "$PWD") || die "no GitHub origin remote here; pass owner/repo"
  need secret-tool
  case $sub in
    set|unset) secret_name_ok "$name" || die "not a usable variable name: %s" "$name" ;;
  esac
  case $sub in
    set) _secret_set "$repo" "$name" ;;
    unset) secret-tool clear service cradle-secret repo "$repo" name "$name"; msg "removed %s for %s" "$name" "$repo" ;;
    list) _secret_list "$repo" ;;
    *) die "usage: cradle secret set|unset NAME [owner/repo] | list" ;;
  esac
}
