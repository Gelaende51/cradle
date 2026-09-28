bats_require_minimum_version 1.5.0

# Shared bats helpers: an isolated PATH whose only commands are basic tools
# plus stubs that log their calls to $STUB_LOG.
CRADLE_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
export CRADLE_ROOT
# tests match English messages; the i18n test sets its own language
export LANGUAGE=en
# fixture commits must not run the hooks of the machine (or container) running the tests
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null
BASE_TOOLS=(bash env cat grep sed awk jq mkdir rm cp mv ls dirname basename
  readlink realpath tr cut sort head tail wc mktemp date find cmp touch chmod
  id gettext git sha256sum xargs tee sleep ls ln stat python3 flock timeout od)

setup_isolated_path() {
  STUB_BIN="$BATS_TEST_TMPDIR/stubs"
  SYS_BIN="$BATS_TEST_TMPDIR/sys"
  mkdir -p "$STUB_BIN" "$SYS_BIN"
  local t p
  for t in "${BASE_TOOLS[@]}"; do
    p=$(command -v "$t") || continue
    [[ $p == /* ]] && ln -sf "$p" "$SYS_BIN/$t"
  done
  export STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  : > "$STUB_LOG"
  export PATH="$STUB_BIN:$SYS_BIN"
  export CRADLE_PROXY_WAIT=1   # one readiness probe per proxy start
  # never touch the real state, unit or cache directories
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config" XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
}

# stub NAME [EXIT_CODE] [STDOUT]: a fake command that logs "NAME args".
stub() {
  local name=$1 code=${2:-0} out=${3-}
  {
    printf '#!%s\n' "$SYS_BIN/bash"
    printf 'echo "%s $*" >> "$STUB_LOG"\n' "$name"
    printf 'printf "%%s" %q\n' "$out"
    printf 'exit %d\n' "$code"
  } > "$STUB_BIN/$name"
  chmod +x "$STUB_BIN/$name"
}

# stub_script NAME LINE...: a fake command with a custom body (after logging).
stub_script() {
  local name=$1; shift
  {
    printf '#!%s\n' "$SYS_BIN/bash"
    printf 'echo "%s $*" >> "$STUB_LOG"\n' "$name"
    printf '%s\n' "$@"
  } > "$STUB_BIN/$name"
  chmod +x "$STUB_BIN/$name"
}

cradle() { "$CRADLE_ROOT/bin/cradle" "$@"; }
