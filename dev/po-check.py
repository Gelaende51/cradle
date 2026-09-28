#!/usr/bin/env python3
"""po-check.py FILE.po: every entry translated, not fuzzy, same printf conversions."""
import re, sys

CONV = re.compile(r"%[-+ #0]*[0-9]*(?:\.[0-9]+)?[sdifxXc%]")

def entries(text):
    cur, key, fuzzy = {}, None, False
    for line in text.splitlines() + [""]:
        if not line.strip():
            if "msgid" in cur:
                yield cur.get("msgid", ""), cur.get("msgstr", ""), fuzzy
            cur, key, fuzzy = {}, None, False
        elif line.startswith("#,") and "fuzzy" in line:
            fuzzy = True
        elif line.startswith("#"):
            continue
        elif line.startswith(("msgid ", "msgstr ")):
            key, _, rest = line.partition(" ")
            cur[key] = eval(rest)  # a po string literal is a Python string literal
        elif line.startswith('"') and key:
            cur[key] += eval(line)

bad = []
for msgid, msgstr, fuzzy in entries(open(sys.argv[1], encoding="utf-8").read()):
    if msgid == "":
        continue
    if fuzzy or not msgstr:
        bad.append(f"untranslated or fuzzy: {msgid}")
    elif CONV.findall(msgid) != CONV.findall(msgstr):
        bad.append(f"conversions differ: {msgid} -> {msgstr}")
print("\n".join(bad))
sys.exit(1 if bad else 0)
