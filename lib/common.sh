#!/usr/bin/env bash
# Shared helpers for every cradle subcommand.
set -euo pipefail

CRADLE_ROOT=${CRADLE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
export CRADLE_ROOT
export TEXTDOMAIN=cradle
export TEXTDOMAINDIR="$CRADLE_ROOT/locale"

# _t STRING: the translation of STRING, or STRING itself.
_t() { if command -v gettext >/dev/null 2>&1; then gettext "$1"; else printf '%s' "$1"; fi; }

# msg/warn/die FORMAT [ARGS...]: printf-style with a translated format.
# shellcheck disable=SC2059
msg()  { local f; f=$(_t "$1"); shift; printf "$f\n" "$@"; }
# shellcheck disable=SC2059
warn() { local f; f=$(_t "$1"); shift; printf "cradle: $f\n" "$@" >&2; }
die()  { warn "$@"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }
need() { have "$1" || die "missing command: %s" "$1"; }

cradle_version() { cat "$CRADLE_ROOT/VERSION"; }
