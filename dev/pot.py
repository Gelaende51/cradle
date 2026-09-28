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

# Any other call of a message function (single quotes, a message on the next
# line, ...) would silently stay English: refuse it instead.
LOOSE = re.compile(r'(?:^|[;&|{(]|\bthen|\belse|\bdo)\s*(?:msg|warn|die|_t|_report)(?=\s)')  # in command position
STRINGS = re.compile(r'"(?:[^"\\]|\\.)*"|\'[^\']*\'')

def unread_calls(line):
    code = re.sub(r'(^|\s)#.*$', '', STRINGS.sub('""', line))
    strict = sum(len(rx.findall(line)) for rx in CALLS)
    return len(LOOSE.findall(code)) > strict

seen = {}
for path in sys.argv[1:]:
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        if line.lstrip().startswith("#"):
            continue
        if unread_calls(line):
            sys.exit(f"{path}:{n}: a message call pot.py cannot read (use a double-quoted literal on the same line): {line.strip()}")
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
