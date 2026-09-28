#!/usr/bin/env bash
# Runs once when a project's dev container is created: per-repo tool enablement.
# Hooks go to core.hooksPath in the data volume (set by the container env), never
# into the host-shared .git/hooks.
set -euo pipefail
cd "${CRADLE_WORKSPACE:?CRADLE_WORKSPACE not set}"
hooks=$(git config core.hooksPath)
mkdir -p "$hooks"

# git authenticates to GitHub through gh, which reads GH_TOKEN at call time (no stored copy).
git config --global credential.https://github.com.helper '!gh auth git-credential'

# ethos identities live in the shared cradle-punt volume; set them up once.
# (whoami resolves by git email, so the identity file is the reliable guard.)
id_file="$HOME/.claude/cradle/ethos-identity.yaml"
handle=$(awk '/^handle:/ {print $2}' "$id_file")
if [ ! -f "$HOME/.punt-labs/ethos/identities/$handle.yaml" ]; then
  ethos seed >/dev/null && ethos setup --file "$id_file"
fi
ethos enable
# beads keeps its data in the project but out of its git: no agent files, no hooks, no commit
[ -d .beads ] || bd init --non-interactive --skip-agents --skip-hooks --setup-exclude

# punt pii runs first in pre-commit, so a later "exit 0" in a chained section cannot skip it.
pc="$hooks/pre-commit"
[ -f "$pc" ] || printf '#!/bin/sh\n' > "$pc"
if ! grep -q '# CRADLE PII BEGIN' "$pc"; then
  sed -i '1a # CRADLE PII BEGIN\npunt pii --staged || exit 1\n# CRADLE PII END' "$pc"
fi
chmod +x "$pc"
