#!/usr/bin/env bash
# Runs on every container start: quarryd, per-project quarry enablement, plugins.
set -euo pipefail
state="$HOME/.local/share/cradle"
mkdir -p "$state/log"
cd "${CRADLE_WORKSPACE:?CRADLE_WORKSPACE not set}"

if ! pgrep -x quarryd >/dev/null; then
  nohup quarryd >"$state/log/quarryd.log" 2>&1 &
fi
for _ in $(seq 60); do quarry status >/dev/null 2>&1 && break; sleep 1; done
if [ ! -f "$state/quarry-enabled" ]; then
  quarry enable && touch "$state/quarry-enabled"
fi

list="$HOME/.claude/cradle/plugins.txt"
if [ -f "$list" ]; then
  claude plugin marketplace add anthropics/claude-plugins-official >>"$state/log/plugins.log" 2>&1 || true
  while read -r p; do
    case $p in ''|'#'*) continue ;; esac
    claude plugin install "$p" >>"$state/log/plugins.log" 2>&1 || echo "failed: $p" >>"$state/log/plugins.log"
  done < "$list"
fi
