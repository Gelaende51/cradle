#!/usr/bin/env python3
"""pot.py FILE...: the gettext template of cradle's messages, on stdout.

xgettext's Shell parser does not see a command after `then`, `else` or `{` on
the same line, so it misses most `_report` calls and extracts stray words. The
message functions are few and always take a double-quoted literal, so a
pattern finds them reliably: msg/warn/die/_t FORMAT, and _report LEVEL NAME
FORMAT. The msgid is the string bash passes at run time (\\$ \\" \\\\ unescaped).
"""
import re, sys

Q = r'"((?:[^"\\]|\\.)*)"'
ARG = r'(?:"(?:[^"\\]|\\.)*"|\S+)'
CALLS = [re.compile(r'(?<![\w-])(?:msg|warn|die|_t)\s+' + Q),
         re.compile(r'(?<![\w-])_report\s+' + ARG + r'\s+' + ARG + r'\s+' + Q)]

def bash(s):  # what bash makes of a double-quoted literal without expansions
    return re.sub(r'\\([$`"\\])', r'\1', s)

def po(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'

seen = {}
for path in sys.argv[1:]:
    for line in open(path, encoding="utf-8"):
        if line.lstrip().startswith("#"):
            continue
        for rx in CALLS:
            for m in rx.finditer(line):
                raw = m.group(1)
                if re.fullmatch(r'\$(\{?\w+\}?|@|\*)', raw):  # a helper passing its argument on
                    continue
                if re.search(r'(?<!\\)\$', raw):
                    sys.exit(f"{path}: message with an expansion cannot be translated: {raw}")
                seen.setdefault(bash(raw), []).append(path)

print('msgid ""\nmsgstr ""\n"Project-Id-Version: cradle\\n"\n"MIME-Version: 1.0\\n"\n'
      '"Content-Type: text/plain; charset=UTF-8\\n"\n"Content-Transfer-Encoding: 8bit\\n"\n')
for msgid, paths in seen.items():
    print("#: " + " ".join(sorted(set(paths))))
    print("msgid " + po(msgid))
    print('msgstr ""\n')
