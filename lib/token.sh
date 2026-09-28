#!/usr/bin/env bash
# cradle token: per-repo fine-grained GitHub tokens in the host keyring.

repo_slug() {
  local url
  url=$(git -C "${1:-$PWD}" remote get-url origin 2>/dev/null) || return 1
  [[ $url =~ github\.com[:/]([^/]+)/([^/]+)$ ]] || return 1
  printf '%s/%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]%.git}"
}

token_lookup() { secret-tool lookup service cradle repo "$1" 2>/dev/null; }

_token_set() {
  local repo=$1 t
  if [[ -t 0 ]]; then read -rsp "$(_t "GitHub token for") $repo: " t; echo; else read -r t; fi
  [[ -n $t ]] || die "empty token"
  printf '%s' "$t" | secret-tool store --label="cradle GitHub token $repo" service cradle repo "$repo"
  msg "stored token for %s" "$repo"
}

token_expiry_date() {
  local t
  t=$(token_lookup "$1") || return 1
  printf 'Authorization: Bearer %s\n' "$t" \
    | curl -fsSI -H @- https://api.github.com/rate_limit \
    | tr -d '\r' | awk -F': ' 'tolower($1) == "github-authentication-token-expiration" {print $2}'
}

_token_expiry() {
  local repo=$1 h days
  token_lookup "$repo" >/dev/null || die "no token stored for %s; run: cradle token set %s" "$repo" "$repo"
  h=$(token_expiry_date "$repo") || die "could not read the token's expiry from GitHub"
  if [[ -z $h ]]; then msg "token for %s has no expiry date" "$repo"; return 0; fi
  days=$(( ($(date -d "$h" +%s) - $(date +%s)) / 86400 ))
  msg "token for %s expires %s" "$repo" "$h"
  (( days >= 7 )) || warn "token for %s expires in %s days; renew it" "$repo" "$days"
}

cmd_token() {
  local sub=${1:-} repo=${2:-}
  [[ -n $repo ]] || repo=$(repo_slug "$PWD") || die "no GitHub origin remote here; pass owner/repo"
  need secret-tool
  case $sub in
    set) _token_set "$repo" ;;
    show-expiry) _token_expiry "$repo" ;;
    *) die "usage: cradle token set|show-expiry [owner/repo]" ;;
  esac
}
