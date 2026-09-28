#!/usr/bin/env bash
# Per-project egress proxy: an internal network cradle-<key> with no route out,
# and a squid container on it (alias "proxy") whose second leg is the shared
# network cradle-egress (podman's default network has DNS off, see takeaways).
# The dev container joins only the internal network.
# shellcheck source=lib/render.sh
. "$CRADLE_ROOT/lib/render.sh"

_proxy_dir() { printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/cradle/proxy/$(project_key "$1")"; }

# _drop_covered: stdin sorted unique entries; drops those a ".wildcard" entry already allows.
_drop_covered() {
  awk '{ d[NR] = $0; if (substr($0, 1, 1) == ".") w[$0] = 1 }
    END { for (i = 1; i <= NR; i++) {
      s = d[i]; t = (substr(s, 1, 1) == "." ? substr(s, 2) : s); n = split(t, p, "."); c = 0
      for (j = 1; j < n; j++) { suf = ""; for (k = j; k <= n; k++) suf = suf "." p[k]
        if ((suf in w) && suf != s) c = 1 }
      if (!c) print s } }'
}

# allowlist_merge DIR: the kit's default list plus cradle.json allowedDomains,
# normalised (lower case, "*.x" → ".x"), validated and without covered entries.
allowlist_merge() {
  local dir=$1 extra bad
  extra=$(jq -r '(.allowedDomains // []) | if type == "array" then .[] else error("not a list") end' \
    "$dir/.devcontainer/cradle.json" 2>/dev/null) || die "allowedDomains in cradle.json must be a list of domains"
  extra=$(printf '%s\n' "$extra" | tr '[:upper:]' '[:lower:]' | sed 's/^\*\././')
  bad=$(printf '%s\n' "$extra" | grep -Ev '^$|^\.?([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$' | head -n1 || true)
  [[ -z $bad ]] || die "allowedDomains: %s is not a domain (write example.com, or .example.com for its subdomains too)" "$bad"
  # names that resolve to the host, the LAN or other containers (squid also refuses private addresses)
  bad=$(printf '%s\n' "$extra" | grep -E '\.(internal|local|localhost|podman|arpa|lan|home)$' | head -n1 || true)
  [[ -z $bad ]] || die "allowedDomains: %s names a local host; the proxy only reaches the internet" "$bad"
  { grep -Ev '^[[:space:]]*(#|$)' "$CRADLE_ROOT/proxy/allowlist.txt"; printf '%s\n' "$extra"; } \
    | awk 'NF' | sort -u | _drop_covered
}

proxy_up() {
  local dir=$1 key net name list id cur running
  key=$(project_key "$dir"); net="cradle-$key"; name="cradle-proxy-$key"
  list="$(_proxy_dir "$dir")/allowlist"
  mkdir -p "$(dirname "$list")"
  allowlist_merge "$dir" > "$list.new"
  chmod 644 "$list.new"   # squid runs as its own user and must read it
  mv "$list.new" "$list"
  podman network exists "$net" || podman network create --internal "$net" >/dev/null
  podman network exists cradle-egress || podman network create cradle-egress >/dev/null
  id=$(sha256sum < "$list" | cut -c1-16)
  cur=$(podman inspect --format '{{index .Config.Labels "cradle.allowlist"}}' "$name" 2>/dev/null) || cur=""
  running=$(podman inspect --format '{{.State.Running}}' "$name" 2>/dev/null) || running=""
  [[ $cur == "$id" && $running == true ]] && return 0
  podman rm -f "$name" >/dev/null 2>&1 || true
  podman run -d --name "$name" --label "cradle.allowlist=$id" \
    --network cradle-egress --network "$net:alias=proxy" \
    --cap-drop=ALL --security-opt=no-new-privileges --read-only --memory=128m \
    -v "$list:/etc/squid/allowlist:ro" "localhost/cradle-proxy:$(cradle_version)" >/dev/null
  _proxy_wait "$name"
}

# _proxy_wait NAME: until squid accepts connections; stops with its log when it exited.
_proxy_wait() {
  local name=$1 i
  for ((i = 0; i < ${CRADLE_PROXY_WAIT:-20}; i++)); do
    podman logs "$name" 2>&1 | grep -q 'Accepting HTTP' && return 0
    if [[ $(podman inspect --format '{{.State.Running}}' "$name" 2>/dev/null) == false ]]; then
      die "the egress proxy %s did not start; its log ends with:\n%s" "$name" "$(podman logs "$name" 2>&1 | tail -n 5)"
    fi
    sleep 0.25
  done
  warn "the egress proxy %s has not reported ready yet" "$name"
}

proxy_down() { podman rm -f "cradle-proxy-$(project_key "$1")" >/dev/null 2>&1 || true; }

cmd_net() {
  case ${1:-} in
    log)
      need podman
      local name; name="cradle-proxy-$(project_key "$PWD")"
      podman container exists "$name" || die "no proxy for %s; run: cradle up" "$PWD"
      podman logs "$name" 2>/dev/null | awk '$2 == "TCP_DENIED"' ;;
    *) die "usage: cradle net log" ;;
  esac
}
