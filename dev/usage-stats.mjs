#!/usr/bin/env node
// Prints (or with --write, puts into both READMEs) the AI-usage bullet, counted
// from this machine's Claude Code transcripts: the session that designed and
// built cradle, plus every session run in the cradle folder on the host.
// Sessions inside cradle containers keep their transcripts in the cradle-claude
// volume and are not counted yet (said in the README).
import { readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
const { responses, projectFolder } = await import(join(homedir(), "building_stuff/scripts/token-cost.mjs"));

const SESSIONS = new Set(["22e14035-439c-43de-afaa-0d76b06a3f97"]);
const FOLDER = projectFolder(join(homedir(), "building_stuff/cradle"));
let n = 0, gen = 0, sent = 0, read = 0, first = null, last = null;
const sessions = new Set();
for await (const r of responses({ headless: false })) {
  if (!(SESSIONS.has(r.session) || r.project === FOLDER)) continue;
  n++; sessions.add(r.session);
  gen += r.tokens.output; sent += r.tokens.input + r.tokens.write1h + r.tokens.write5m; read += r.tokens.read;
  if (!first || r.at < first) first = r.at;
  if (!last || r.at > last) last = r.at;
}
const M = (x) => `\\~${(x / 1e6).toFixed(1)} M`;
const day = (d, lang) => d.toLocaleDateString(lang, { day: "numeric", month: "short", year: "numeric" });
const en = `- **Usage** — ${day(first, "en-GB")} – ${day(last, "en-GB")}, ${sessions.size} session(s), \\~${n.toLocaleString("en")} responses: ${M(gen)} tokens generated, ${M(sent)} sent, ${M(read)} cached re-reads. Sessions inside cradle's own container are not counted yet.`;
const de = `- **Nutzung** — ${day(first, "de-DE")} – ${day(last, "de-DE")}, ${sessions.size} Sitzung(en), \\~${n.toLocaleString("de")} Antworten: ${M(gen).replace(".", ",")} Tokens erzeugt, ${M(sent).replace(".", ",")} gesendet, ${M(read).replace(".", ",")} aus dem Cache erneut gelesen. Sitzungen im eigenen cradle-Container sind noch nicht mitgezählt.`;
if (!process.argv.includes("--write")) { console.log(en); console.log(de); process.exit(0); }
for (const [file, prefix, line] of [["README.md", "- **Usage** — ", en], ["docs/i18n/README.de.md", "- **Nutzung** — ", de]]) {
  const text = readFileSync(file, "utf8").split("\n").map((l) => (l.startsWith(prefix) ? line : l)).join("\n");
  writeFileSync(file, text);
}
