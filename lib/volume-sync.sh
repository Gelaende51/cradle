#!/usr/bin/env bash
# volume-sync.sh MODE SRC DST: runs inside a throwaway container that sees only
# the kit (SRC, read-only) and the cradle-claude volume (DST). Dev containers can
# write DST, so a symlink planted there resolves inside this container, never on
# the host.
#   sync:  stdin = files the last sync wrote; removes those gone from SRC, copies
#          SRC's files, merges settings.json into the existing one, prints the
#          new file list (the host keeps it as the manifest).
#   check: exits 0 when DST holds every kit file (settings.json: the kit's keys).
set -euo pipefail
mode=$1 src=$2 dst=$3
kit_files() { (cd "$src" && find . -type f -printf '%P\n' | sort); }

case $mode in
  sync)
    rm -f -- "$dst/.cradle-manifest"   # left by cradle 0.1.0 before the host kept it
    while IFS= read -r f; do
      [[ -z $f || $f == /* || $f == *..* ]] && continue
      [[ -e $src/$f ]] || rm -f -- "$dst/$f"
    done
    while IFS= read -r f; do
      mkdir -p -- "$dst/$(dirname -- "$f")"
      if [[ $f == settings.json && -f $dst/$f && ! -L $dst/$f ]] \
         && jq -e 'type == "object"' "$dst/$f" >/dev/null 2>&1; then
        jq -s '.[0] * .[1]' "$dst/$f" "$src/$f" > "$dst/$f.tmp"
        mv -f -- "$dst/$f.tmp" "$dst/$f"
      else
        cp --remove-destination -- "$src/$f" "$dst/$f"
      fi
    done < <(kit_files)
    kit_files ;;
  check)
    while IFS= read -r f; do
      [[ -f $dst/$f && ! -L $dst/$f ]] || exit 1
      if [[ $f == settings.json ]]; then
        jq -e --slurpfile k "$src/$f" '. * $k[0] == .' "$dst/$f" >/dev/null 2>&1 || exit 1
      else
        cmp -s -- "$src/$f" "$dst/$f" || exit 1
      fi
    done < <(kit_files) ;;
  *) echo "usage: volume-sync.sh sync|check SRC DST" >&2; exit 2 ;;
esac
