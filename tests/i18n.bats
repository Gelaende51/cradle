setup() { load test_helper; }

@test "every message has a German translation and the catalog is compiled" {
  run make -s -C "$CRADLE_ROOT" i18n-check
  [ "$status" -eq 0 ]
}

@test "a translation that loses a conversion is refused" {
  printf 'msgid ""\nmsgstr "Content-Type: text/plain; charset=UTF-8\\n"\n\nmsgid "no commit %%s"\nmsgstr "kein Commit"\n' > "$BATS_TEST_TMPDIR/bad.po"
  run python3 "$CRADLE_ROOT/dev/po-check.py" "$BATS_TEST_TMPDIR/bad.po"
  [ "$status" -eq 1 ]; [[ "$output" == *"no commit %s"* ]]
}

@test "an untranslated entry is refused" {
  printf 'msgid ""\nmsgstr "Content-Type: text/plain; charset=UTF-8\\n"\n\nmsgid "attached"\nmsgstr ""\n' > "$BATS_TEST_TMPDIR/bad.po"
  run python3 "$CRADLE_ROOT/dev/po-check.py" "$BATS_TEST_TMPDIR/bad.po"
  [ "$status" -eq 1 ]
}

@test "cradle speaks German under a German locale and English otherwise" {
  locale -a 2>/dev/null | grep -qiE '^de_DE\.utf-?8$' || skip "no de_DE.UTF-8 locale on this system"
  run env LC_ALL= LANG=de_DE.UTF-8 LANGUAGE=de "$CRADLE_ROOT/bin/cradle" help
  [[ "$output" == *"Aufruf: cradle <Befehl> [Argumente]"* ]]
  run env LC_ALL= LANG=de_DE.UTF-8 LANGUAGE=en "$CRADLE_ROOT/bin/cradle" help
  [[ "$output" == *"usage: cradle <command> [args]"* ]]
}

@test "a message call the extractor cannot read fails the extraction" {
  for body in "die 'single quoted'" 'warn \' 'msg "%s" "$x"; die '"'"'x'"'"; do
    printf '%s\n' "$body" > "$BATS_TEST_TMPDIR/x.sh"
    run python3 "$CRADLE_ROOT/dev/pot.py" "$BATS_TEST_TMPDIR/x.sh"
    [ "$status" -ne 0 ]; [[ "$output" == *"x.sh"* ]]
  done
}
