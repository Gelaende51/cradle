# cradle Plan 4: Ship — i18n, CI, pilot, docs, repository

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** cradle becomes a published, documented, bilingual (en/de) kit on `github.com/Gelaende51/cradle` whose own CI is green and which is developed inside its own container.

**Architecture:** CLI messages go through gettext with a committed German catalog and a `make i18n-check` gate. One workflow file (`.github/workflows/ci.yml`) is cradle's GitHub CI *and* its tier-2 job, proven locally first by attaching cradle to itself (the pilot). README (en + de) and four docs pages describe what exists; the AI-usage figure is counted by a script, not written by hand. The public repository is created last, after a secret scan, and only on explicit confirmation.

**Tech Stack:** GNU gettext (xgettext, msginit, msgmerge, msgfmt, msgcmp, msgunfmt), python3, bats, GitHub Actions (`ubuntu-latest`), act, node (usage figure via `~/building_stuff/scripts/token-cost.mjs`), gh.

**Spec:** `dev/specs/2026-09-28-cradle-design.md` §1 (success criteria 1–2, pilot), §6 (GitHub Actions for cradle, pilot), §7 (documentation and localization), §8 (repo created only at its step, confirmed then).

## Global Constraints

- Operator decisions (2026-09-28): **no donation link** for now; README features = one-command start, isolation promises, tier-2 tests, shared config and tokens; CI = lint, unit tests and image build on `ubuntu-latest` (the podman integration suites stay local); repository **public**.
- Creating `Gelaende51/cradle` and the first push are outward-facing: ask the operator with AskUserQuestion immediately before, even though the plan was approved.
- Never commit or push a secret or the operator's email; commits carry `Gelaende51@users.noreply.github.com` (already so).
- English is the msgid language (no `en` catalog); German is `locale/de/LC_MESSAGES/cradle.mo`, compiled from `po/de.po` and committed.
- German style: neutral, no "du"/"Sie" where avoidable; command names, file names, JSON keys, environment variables and printf conversions (`%s`, `%d`) stay verbatim and in order.
- README per project rules: description, then AI disclosure (agent + author bullets, model and provider, counted token figure) above all other headings; features; installation; license; links (docs, repository, issues); integrating software; similar projects with differences; contributions. German translation at `docs/i18n/README.de.md`.
- Every shell file passes `shellcheck -x`; `make check` stays green; real podman runs go through `systemd-run --user --collect` with the log deleted first (Plan 1 takeaway).

## Review Focus

1. A message added later without a German entry → `make check` fails (i18n-check runs inside `check`), not a silent English fallback (Task 1 test "every message has a German translation…").
2. A German translation that drops or reorders a `%s` → printf prints garbage or fails; the checker refuses it (Task 1 test "a translation that loses a conversion is refused").
3. The rendered `devcontainer.json` holds absolute host paths (state dir, kit path, user name): it must never be committed or pushed (Task 3 test "the gitignore block covers the rendered devcontainer.json").
4. The CI workflow must pass cradle's own tier-2 job check (ubuntu-latest, no container options) so the same file runs locally and on GitHub (Task 3 pilot step, `cradle test test`).
5. The public push must carry no secret, no `.personal/`, no host-absolute path in tracked files (Task 5 scan).

---

### Task 1: gettext catalogs and the i18n gate

**Files:**
- Modify: `lib/common.sh` (TEXTDOMAIN), `Makefile` (`pot`, `po`, `mo`, `i18n-check`; `check` depends on `i18n-check`)
- Create: `po/cradle.pot`, `po/de.po`, `locale/de/LC_MESSAGES/cradle.mo`, `dev/po-check.py`, `tests/i18n.bats`

**Interfaces:**
- Produces: `make i18n-check` (exit 0 only when the pot is current, `po/de.po` translates every msgid without fuzzy entries, conversions match, and the committed `.mo` equals a fresh compile); `TEXTDOMAIN=cradle`, `TEXTDOMAINDIR=$CRADLE_ROOT/locale` exported by `lib/common.sh`.

- [ ] **Step 1: Write the failing tests `tests/i18n.bats`**

```bash
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
```
Run: `bats tests/i18n.bats` — Expected: FAIL (no `i18n-check` target, no `dev/po-check.py`).

- [ ] **Step 2: `dev/po-check.py`** — completeness and printf-conversion parity (xgettext's Shell parser does not mark `c-format`, so `msgfmt -c` cannot do this):

```python
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
```

- [ ] **Step 3: Wire the domain** in `lib/common.sh`, directly after `set -euo pipefail`:

```bash
# gettext: the kit ships its catalogs in locale/<lang>/LC_MESSAGES/cradle.mo
export TEXTDOMAIN=cradle TEXTDOMAINDIR="$CRADLE_ROOT/locale"
```

- [ ] **Step 4: Makefile targets** (`XGETTEXT` extracts `msg`, `warn`, `die` and `_t` first arguments):

```make
SRC_I18N := bin/cradle bin/cradle-testd $(wildcard lib/*.sh)
XGETTEXT := xgettext -L Shell -k -kmsg:1 -kwarn:1 -kdie:1 -k_t:1 --from-code=UTF-8 --add-location=file --package-name=cradle

pot:
	$(XGETTEXT) -o po/cradle.pot $(SRC_I18N)
po: pot
	msgmerge -q -U --backup=none po/de.po po/cradle.pot
mo:
	mkdir -p locale/de/LC_MESSAGES && msgfmt -o locale/de/LC_MESSAGES/cradle.mo po/de.po
# one recipe, so the temporary directory is made and removed by the same shell
i18n-check:
	@t=$$(mktemp -d); trap 'rm -rf "$$t"' EXIT; \
	$(XGETTEXT) -o "$$t/cradle.pot" $(SRC_I18N) \
	&& { msgcmp po/de.po "$$t/cradle.pot" || { echo "i18n: po/de.po misses messages; run: make po, translate, make mo"; exit 1; }; } \
	&& python3 dev/po-check.py po/de.po \
	&& msgfmt -o "$$t/de.mo" po/de.po \
	&& { cmp -s <(msgunfmt "$$t/de.mo") <(msgunfmt locale/de/LC_MESSAGES/cradle.mo) || { echo "i18n: cradle.mo is stale; run: make mo"; exit 1; }; }
check: lint i18n-check test
```
(`.PHONY` gets `pot po mo i18n-check`; `SHELL := bash` is already set, which the process substitution needs.)

- [ ] **Step 5: Create and translate the catalog**: `make pot && msginit --no-translator -l de_DE.UTF-8 -i po/cradle.pot -o po/de.po`, set `Language: de`, then translate every msgid under the Global Constraints' German style. Fixed choices: "usage: cradle <command> [args]" → "Aufruf: cradle <Befehl> [Argumente]"; "commands:" → "Befehle:"; "approve .github at this commit for tier-2 runs? [y/N] " → "`.github` in diesem Commit für Tier-2-Läufe freigeben? [j/N] " **and** `cmd_approve_workflows` accepts `[yYjJ]` (add a bats case in `tests/testd.bats`: `echo j |` approves). Then `make mo`.

- [ ] **Step 6: Run** `bats tests/i18n.bats` — Expected: PASS (4, the locale test runs on this host); `make check` — Expected: all green.

- [ ] **Step 7: Commit** — `git add -A lib Makefile po locale dev/po-check.py tests && git commit -m "Translate the CLI into German and gate every message on a translation"`

---

### Task 2: cradle's own CI workflow

**Files:**
- Create: `.github/workflows/ci.yml`
- Modify: `tests/cli.bats` (workflow shape test)

**Interfaces:**
- Produces: job `test` (the tier-2 job for the pilot) and job `image` (GitHub only).

- [ ] **Step 1: Failing test** in `tests/cli.bats`:

```bash
@test "cradle's CI test job passes cradle's own tier-2 job check" {
  . "$CRADLE_ROOT/lib/common.sh"
  run python3 -c 'import json, sys, yaml; d = yaml.safe_load(open(sys.argv[1]))["jobs"]["test"]; sys.exit(0 if d["runs-on"] == "ubuntu-latest" and "container" not in d and "services" not in d else 1)' "$CRADLE_ROOT/.github/workflows/ci.yml"
  [ "$status" -eq 0 ]
}
```
Expected: FAIL (file missing).

- [ ] **Step 2: Write `.github/workflows/ci.yml`**

```yaml
# cradle's CI. The "test" job is also cradle's tier-2 job (cradle test test).
name: ci
on: [push, pull_request]
permissions:
  contents: read
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Tools
        run: |
          sudo apt-get update -q
          sudo apt-get install -y -q --no-install-recommends bats shellcheck jq gettext python3-yaml locales make
          sudo locale-gen de_DE.UTF-8
      - name: Lint, i18n and unit tests
        run: make check
  image:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build cradle-base and cradle-proxy with podman
        run: bin/cradle image build
```

- [ ] **Step 3: Run** `bats tests/cli.bats` — Expected: PASS; `make check` green.

- [ ] **Step 4: Commit** — `git add .github tests/cli.bats && git commit -m "Add cradle's CI: lint, i18n, unit tests and image build"`

---

### Task 3: Pilot — cradle attached to itself

**Files:**
- Modify: `image/Containerfile` (tier-1 tools: `bats make python3 python3-yaml`), `lib/init.sh` (gitignore block also covers `.devcontainer/devcontainer.json`), `tests/init.bats`, `tests/integration/foundation.sh` (tier-1 tools check), `dev/takeaways.md`
- Create (by `cradle init`, committed): `.devcontainer/cradle.json`, `.actrc`, `.gitignore`

**Interfaces:**
- Consumes: Plans 1–3, Tasks 1–2.

- [ ] **Step 1: Failing test** in `tests/init.bats`:

```bash
@test "the gitignore block covers the rendered devcontainer.json" {
  cradle init
  grep -qx '.devcontainer/devcontainer.json' .gitignore
}
```
Expected: FAIL. Then add `.devcontainer/devcontainer.json` to `GITIGNORE_BLOCK` in `lib/init.sh` (it holds absolute host paths and is regenerated from cradle.json) and re-run: PASS.

- [ ] **Step 2: Tier-1 tools in the image**: add `bats make python3 python3-yaml` to the apt line in `image/Containerfile`; add to `tests/integration/foundation.sh` after "punt tools answer":
  `check "tier-1 tools"            in_c 'bats --version && make --version >/dev/null && shellcheck --version >/dev/null && python3 -c "import yaml"'`
  Run `bin/cradle image build` via systemd-run (log first deleted, wait for `EXIT=`). Expected: EXIT=0. Then `make integration` via systemd-run — Expected: all foundation checks ok, including "tier-1 tools".

- [ ] **Step 3: Attach cradle**: in the repo root `bin/cradle init`, then set `testJobs` to `[{"workflow":"ci.yml","job":"test","network":true}]` (the job installs packages with apt, so it needs the bridge network) with jq; `git status` must show only `.devcontainer/cradle.json`, `.actrc`, `.gitignore` as new/changed.

- [ ] **Step 4: Tier 2 from the host**: `bin/cradle approve-workflows` (review the shown diff of `.github`, which is Task 2's file, then `--yes`), commit Step 3's files first so the ref contains them, then `bin/cradle test test`. Expected: `passed: job test passed`. If the job fails inside act (root user, missing tool, shellcheck version), fix the cause in the workflow or the tests, re-approve, re-run; record act differences in takeaways.

- [ ] **Step 5: Tier 1 and tier 2 from inside**: `bin/cradle up`, then through `devcontainer exec --docker-path podman --workspace-folder "$PWD" bash -lc 'cd "$CRADLE_WORKSPACE" && make check && cradle-request test'`. Expected: `make check` green inside the container (the German-locale test skips there), `passed: job test passed`. `bin/cradle down`.

- [ ] **Step 6: Commit** — `git add -A image lib tests .devcontainer/cradle.json .actrc .gitignore dev/takeaways.md && git commit -m "Develop cradle inside its own container"`

---

### Task 4: Documentation, German README, counted AI usage

**Files:**
- Create: `dev/usage-stats.mjs`, `README.md`, `docs/i18n/README.de.md`, `docs/architecture.md`, `docs/security.md`, `docs/attaching.md`, `docs/troubleshooting.md`
- Modify: `tests/cli.bats` (docs test)

**Interfaces:**
- Produces: `node dev/usage-stats.mjs` (prints the usage bullet), `--write` (replaces the line starting `- **Usage** —` in README.md and the one starting `- **Nutzung** —` in the German README).

- [ ] **Step 1: Failing test** in `tests/cli.bats`:

```bash
@test "the READMEs link each other and every docs page exists" {
  for f in README.md docs/i18n/README.de.md docs/architecture.md docs/security.md docs/attaching.md docs/troubleshooting.md; do
    [ -s "$CRADLE_ROOT/$f" ]
  done
  grep -q 'docs/i18n/README.de.md' "$CRADLE_ROOT/README.md"
  grep -q '../../README.md' "$CRADLE_ROOT/docs/i18n/README.de.md"
  grep -q '^- \*\*Usage\*\* — ' "$CRADLE_ROOT/README.md"
  run grep -rn '~' "$CRADLE_ROOT/README.md" "$CRADLE_ROOT/docs"
  [ "$status" -eq 1 ]
}
```
Expected: FAIL.

- [ ] **Step 2: `dev/usage-stats.mjs`** — counts responses once each through `token-cost.mjs`:

```js
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
```
Run `node dev/usage-stats.mjs` — Expected: two plausible lines (millions of cached re-reads, one or more sessions).

- [ ] **Step 3: Write `README.md`** with exactly these sections, in this order (content fixed here; wording may be tightened, facts not changed):
  1. Title `# cradle`, language line `**English** · [Deutsch](docs/i18n/README.de.md)`, one-paragraph description: a kit that runs Claude Code and a project's development inside a per-project rootless-podman dev container on one Linux PC; tests that run the built software go to disposable act containers or GitHub Actions; any project type.
  2. `## AI disclosure` — bullets: **Agent** — Claude Opus 5.5 (Anthropic, via Claude Code): wrote the shell code, tests, images, CI, German catalog and documentation, reviewed by a separate Claude Opus reviewer; German texts are machine translations. **Usage** — the line from `dev/usage-stats.mjs`. **Upstream** — the model learned from open source code and documentation published by others; most credit goes there. **Author** — Vault51: set the goals and every design decision, approved the spec and plans, directed the work.
  3. `## Features` — the four operator-chosen features, one bullet each: one-command start (`cradle init && cradle claude`); isolation promises (no podman socket, no host home, `.personal/` masked, egress only through an allowlist proxy with `cradle net log`, host git hooks and config read-only); tier-2 tests (`cradle-request <job>` in the container → the host runs the approved workflow's job with act, no network unless the job is marked, no socket; results read-only; `cradle approve-workflows`); shared config and tokens (one `cradle-claude` volume, kit rules synced by `cradle config sync`; a fine-grained per-repo token without the workflows permission from the keyring; workflow changes pushed from the host with `cradle push`).
  4. `## Installation` — requirements (Linux, rootless podman ≥ 5, act, devcontainer CLI 0.89.0 — `cradle setup` installs/prints what is missing, systemd user session, python-yaml); `git clone https://github.com/Gelaende51/cradle`, put `bin/` on PATH or symlink `bin/cradle` into `~/.local/bin`; `cradle setup`, `cradle image build`, `cradle doctor`; first project: `cd project && cradle init && cradle token set <owner/repo> && cradle claude`.
  5. `## Documentation` — links to the four docs pages and `dev/takeaways.md` (quirks found in podman, act, devcontainer CLI, squid).
  6. `## Works with` — punt-labs tools in the image (punt-kit, beads, quarry, ethos), act, the Dev Container CLI, podman, GitHub Actions.
  7. `## Similar projects` — DevPod (multi-provider dev environments; no egress allowlist or tier-2 act split), the plain devcontainer CLI (cradle wraps it and adds the proxy, masks, token and test service), toolbx/distrobox (integrate with the host on purpose: shared home — the opposite of cradle's isolation), Anthropic's reference Claude Code dev container (a firewall script inside one container; cradle keeps the firewall outside the dev container and adds tests in separate containers).
  8. `## Contributing` — issues and pull requests at `https://github.com/Gelaende51/cradle/issues`; `make check` before a PR; donations: none yet.
  9. `## License` — AGPL-3.0-only, see `LICENSE`.
  Then run `node dev/usage-stats.mjs --write`.

- [ ] **Step 4: `docs/`** — each page states only what the code does (read the code, don't recall):
  - `architecture.md`: the host/containers diagram in text (dev container on `cradle-<key>` internal network → proxy on `cradle-egress`; config volume; data volume; testd state dir with `req/` rw and `results/` ro mounts; cradle-testd path/service units; act job containers); the commands table from `bin/cradle help`.
  - `security.md`: threat model (Claude in the container is untrusted); each promise with the mechanism and the test that checks it (foundation.sh, proxy.sh, testd.sh, the bats files); what is not protected (a job marked `network: true` has internet; approved workflows are trusted; docker actions build with network; job containers may outlive a killed runner).
  - `attaching.md`: `cradle init` outputs (`cradle.json` keys: languages, features, maskPaths, memory, allowedDomains, testJobs, testTimeout), `--force`, `--detach`, tokens, approving workflows, `cradle test`.
  - `troubleshooting.md`: `cradle doctor` lines and their fixes; `cradle net log`; a refused tier-2 request (read `status.json` reasons); start-limit and `systemctl --user reset-failed cradle-testd@<key>.path`; stale config volume.

- [ ] **Step 5: `docs/i18n/README.de.md`** — German translation of the whole README (language line `[English](../../README.md) · **Deutsch**`, relative links adjusted with `../../`), then `node dev/usage-stats.mjs --write` again.

- [ ] **Step 6: Run** `bats tests/cli.bats` — Expected: PASS; `make check` green.

- [ ] **Step 7: Commit** — `git add -A README.md docs dev/usage-stats.mjs tests/cli.bats && git commit -m "Document cradle in English and German, with counted AI usage"`

---

### Task 5: Publish — secret scan, repository, green CI

**Files:** none new (unless CI needs fixes; each fix is a normal commit with its test).

- [ ] **Step 1: Scan what will be public**:

```bash
git ls-files | grep -E '(^|/)\.personal/|\.env$|credentials' && echo "FOUND tracked sensitive file"
git log -p --all | grep -nE 'johannes|krischke|web\.de|ghp_[A-Za-z0-9]{20,}|github_pat_|sk-ant-|BEGIN [A-Z ]*PRIVATE KEY' && echo "FOUND secret-like text"
git grep -n '~' -- ':!dev/plans' ':!dev/takeaways.md' && echo "FOUND host path"
git log --format='%an <%ae>%n%cn <%ce>' | sort -u
```
Expected: no "FOUND" lines; authors only `Vault51 <Gelaende51@users.noreply.github.com>`. Host paths in plans/takeaways are allowed only as examples of the operator's layout; if any appear elsewhere, replace them with `~` or `$HOME` and commit.

- [ ] **Step 2: Confirm** with AskUserQuestion: create public `Gelaende51/cradle` and push `main` (show the scan result and the commit count).

- [ ] **Step 3: Create and push** (only on "yes"):

```bash
gh auth status 2>&1 | grep -q 'account Gelaende51' || exit 1
gh repo create Gelaende51/cradle --public --description "Containerized, AI-assisted development on one Linux PC: rootless podman, Dev Containers, Claude Code, act" --source . --remote origin --push
gh run list -R Gelaende51/cradle -L 1
```

- [ ] **Step 4: Watch CI**: `gh run watch <id> -R Gelaende51/cradle --exit-status`. Expected: `test` and `image` succeed. On failure: read the log (`gh run view --log-failed`), fix with a test where the cause is in cradle, record runner differences (shellcheck 0.9 vs 0.11, docker vs podman) in `dev/takeaways.md`, push, repeat.

- [ ] **Step 5: Link check**: `gh repo view Gelaende51/cradle --web` is not needed; `curl -sI https://github.com/Gelaende51/cradle | head -1` → 200.

---

## Out of scope here

- Donation link (operator: none for now).
- Integration on GitHub runners (operator: local only); tier-1 fixture projects for Python and Go (spec §6) — the foundation suite covers Node; Python/Go fixtures come with the next plan that touches features.
- The security check "pushing a workflow change with the container token" needs a real fine-grained token; it is a manual step documented in `docs/security.md`.
- Translating `bin/cradle-request` (runs inside the container without the kit's catalog); its few messages stay English.
- Plans 2–3 deferred minors (network create race, proxy label vs image rebuild, digest pins, SELinux `:z`, punycode TLDs, proxy restart policy, act containers outliving the runner, docker actions building with network).
