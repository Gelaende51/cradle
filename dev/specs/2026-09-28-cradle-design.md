# cradle — design

Date: 2026-09-28 · Status: draft for review · License: AGPL-3.0 ·
Remote: `github.com/Gelaende51/cradle`

## 1. Purpose

cradle is a reusable kit that turns any local software project into a
containerized, AI-assisted development setup on one Linux PC:

- development, including Claude Code, runs inside a per-project dev container;
- tests that start the built software run in separate, disposable containers
  that never share a filesystem, socket or credential with the dev container;
- tests run on GitHub Actions wherever possible, which is also the only route
  to Windows and macOS;
- it works for any project type, not only Obsidian plugins.

### Decisions taken (by the operator)

| Topic | Decision |
|---|---|
| Location | Local only. No Claude Code cloud sessions. |
| Shape | A reusable kit (this repo). Projects stay where they are and are attached with `cradle init`. |
| Interaction | Terminal plus any host editor; the project folder is bind-mounted. No IDE dependency. |
| Test isolation | Two tiers: unit tests, lint and build run in the dev container; everything that runs the built software runs in isolated test containers or on GitHub Actions. |
| Local test runner | `act`, running the project's own GitHub Actions workflows on podman. |
| Container engine | Rootless podman. |
| Container definition | Dev Container spec plus the official `devcontainer` CLI; cradle is a thin wrapper around it. |
| Claude config | One podman volume shared by all project containers, separate from the host `~/.claude`. |
| Rules | Kit is the source; general rules are installed as user-level rules in the shared volume. Project-specific rules stay in the project repo. |
| punt-labs tools in v1 | punt-kit (`punt pii`), beads (`bd`), quarry, ethos. |
| GitHub access | A fine-grained token per repo in the container, **without** the `workflows` permission. Workflow changes are pushed from the host. |
| Egress | Allowlist proxy sidecar in v1. |
| Localization | CLI messages through gettext, shipped in English and German; README in English plus `docs/i18n/README.de.md`. |
| Pilot | cradle itself: once the base works, cradle is developed inside its own container. |
| Name, license, remote | `cradle`, AGPL-3.0, GitHub account `Gelaende51`. |

### Success criteria

1. `cradle init && cradle claude` in any project folder opens Claude Code
   inside that project's dev container, with one command after the first
   setup.
2. The same workflow file drives local tier-2 tests (`act`) and GitHub Actions.
3. From inside the dev container, the podman socket, the host home, `.personal/`
   and domains outside the allowlist are unreachable (checked by tests).
4. Claude inside the container can request local tier-2 tests and read their
   results without any container privilege.
5. On this PC (12 threads, 7 GB RAM, ~47 GB free disk) one dev container plus
   one tier-2 run fit at the same time.

### Non-goals (v1)

- Cloud sessions, self-hosted runners, remote hosts.
- Local Windows or macOS test VMs (GitHub Actions covers them; RAM rules them
  out here).
- IDE integration (the spec keeps VS Code possible later, untested).
- lux, vox, biff, beadle, z-spec, circuit (possible later modules).
- Translating into more than English and German.

## 2. Architecture

```
Host (EndeavourOS)                        ~/building_stuff/cradle (this repo)
│  cradle CLI (bash)                      ├─ bin/cradle, lib/*.sh
│  podman rootless · devcontainer CLI     ├─ image/Containerfile      → cradle-base:<version>
│  act · gh · secret-tool                 ├─ proxy/ (allowlist proxy image + default allowlist)
│                                         ├─ config/ (user-level rules, CLAUDE.md, settings, hooks, plugins)
│                                         ├─ templates/ (devcontainer.json, cradle.json, ci.yml, .actrc)
│                                         ├─ testd/ (cradle-testd + systemd units)
│                                         └─ tests/ (bats, integration), locale/ (gettext)
│
├── per project: podman network "cradle-<project>" (internal, no route out)
│     ├── dev container (devcontainer up)
│     │     user "dev"; project at /home/dev/src/<project> (quarry indexes only under $HOME)
│     │     Claude Code (pinned) · punt · bd + dolt · quarry + quarryd · ethos · language features
│     │     volume cradle-claude → /home/dev/.claude (CLAUDE_CONFIG_DIR)
│     │     volume cradle-<project>-data → quarry index, beads/dolt caches
│     │     tmpfs over .personal/ and other configured secret paths
│     │     env: GH_TOKEN (per-repo), HTTPS_PROXY/HTTP_PROXY/NO_PROXY
│     └── proxy container: the only member with a second, routed network
│
├── cradle-testd (systemd user service, host)
│     watches <project>/.cradle/requests/ → validates → git worktree of the ref
│     → act (podman socket, host only) → disposable job containers
│     → <project>/.cradle/results/<id>/
│
└── GitHub Actions: same workflows; full OS matrix incl. Windows and macOS
```

## 3. Components

### 3.1 `cradle-base` image (`image/Containerfile`)

- Base: `mcr.microsoft.com/devcontainers/base:debian` (so standard features
  apply).
- Non-root user `dev`; `sudo` removed.
- Tools: Claude Code at a pinned version (npm, `DISABLE_AUTOUPDATER=1`), git,
  gh, ripgrep, fd, jq, shellcheck, uv, gettext.
- punt-labs tools, installed at pinned commits and versions: `punt-kit` (uv
  tool), `bd` and `dolt` binaries, `punt-quarry` (uv tool; the embedding model
  is downloaded at build time), `ethos` binary.
- Language toolchains are **not** in the base; projects add them as dev
  container features (`node`, `python`, `go`, `rust`, `java`, …).
- Tagged `cradle-base:<kit-version>`; `cradle image build` retags only after
  a successful build.

### 3.2 Project attachment (`cradle init`)

Detects languages from marker files (`package.json`, `pyproject.toml`,
`go.mod`, `Cargo.toml`, `pom.xml`/`build.gradle`, …) and writes, never
overwriting existing files without `--force`:

- `.devcontainer/devcontainer.json`: the image, features for detected
  languages, `runArgs` (`--userns=keep-id`, `--security-opt=no-new-privileges`,
  `--cap-drop=ALL`, `--memory=3g`, `--network=cradle-<project>`), mounts
  (shared config volume, project data volume, tmpfs over secret paths),
  `containerEnv` (`CLAUDE_CONFIG_DIR`, proxy variables), `postStartCommand`
  (start quarryd).
- `.devcontainer/cradle.json`: extra allowed domains, extra secret paths to
  mask, the tier-2 job names, and memory limits.
- `.github/workflows/ci.yml` (template with tier-2 Linux jobs and an OS
  matrix), `.actrc`.
- A `.gitignore` block for `.cradle/`.
- Per-repo tool enablement: `bd init`, `ethos enable`, `quarry enable`, and a
  `punt pii --staged` pre-commit hook (chained with ethos's hooks).

### 3.3 Shared Claude config (`cradle config sync`)

- Volume `cradle-claude`, mounted at `/home/dev/.claude`, with
  `CLAUDE_CONFIG_DIR` pointing there, so `.claude.json` is persisted too.
- `config/` in the kit is the source for kit-owned files: user-level
  `CLAUDE.md`, `rules/` (the general rules now copied into every project:
  project guidelines, orchestrator, extension, UX), `settings.json` (hooks,
  permissions), skills, and the plugin list, which is installed with
  `claude plugin install`.
- Sync writes a manifest of the files it owns and only replaces those.
  Login, transcripts, memory and any file not in the manifest are never
  touched.
- The host's usage scripts (`claude-usage.mjs`, `headless-log.mjs`) get a
  second transcript root: the volume's mountpoint, read on the host through
  `podman volume inspect`.

### 3.4 Credentials

- `cradle token set <owner/repo>` stores a fine-grained GitHub token (this
  repo only: contents read/write, pull requests read/write, actions read,
  issues read/write; **no** `workflows`, no administration; with an expiry)
  in the host keyring (`secret-tool`).
- `cradle up` reads it and passes it as `GH_TOKEN` in the container's
  environment only; it is never written into a volume or the repo. git in the
  container uses it through `gh auth setup-git` (credential helper, no stored
  copy).
- Workflow changes: Claude commits them in the container. The push is rejected
  because the token lacks `workflows`, and `cradle push` on the host pushes
  them after the operator reviews the diff.
- The Claude login lives in the `cradle-claude` volume, created by `claude`
  login inside the first container.

### 3.5 Egress proxy (`proxy/`)

- A small image (tinyproxy or squid; chosen in the plan by a check of how well
  each filters CONNECT by domain) with a default allowlist: Anthropic API and
  auth, GitHub (including `*.githubusercontent.com`), npm, PyPI and
  `files.pythonhosted.org`, the Go proxy and sum DB, crates.io and
  `static.crates.io`, Debian repos.
- Per-project additions come from `cradle.json`.
- The dev container has no route out except the proxy; `NO_PROXY` covers
  localhost only.
- Blocked requests are logged; `cradle net log` shows them.

### 3.6 Tier-2 test service (`cradle-testd`)

- A systemd user service plus path units, one path unit per attached project;
  `cradle init` registers the unit and `cradle init --detach` removes it. act
  reaches podman through `DOCKER_HOST` set to the rootless podman socket, on
  the host only.
- **Request** (written by Claude in the container):
  `.cradle/requests/<id>.json` = `{"ref": "<commit sha>", "job": "<job id>"}`.
- **Validation:**
  1. Schema: exactly these two fields, `ref` is a full SHA reachable in the
     repo, `job` is listed in `cradle.json`.
  2. The workflow file at `ref` hashes to an **approved** hash. The approved
     set comes from the remote default branch (fetched on the host) plus
     `cradle approve-workflows` (host, after operator review).
  3. The job definition has no `container.options`, no `volumes`, no
     `--privileged`, no host paths, and no `services` with mounts.
- **Run:**
  - `git worktree add` of `ref` under `~/.cache/cradle/runs/<id>`, then
    `act -j <job>` with `--container-daemon-socket -`, no `--bind`, network
    `none` unless the job is marked `network: allowed` in `cradle.json`, and
    a 2 GB memory limit.
  - One run at a time; the rest queue. Timeout 30 minutes (configurable).
- **Result:** `.cradle/results/<id>/` with `status.json` (`passed`, `failed`,
  `rejected` or `timeout`, plus the reason), the act log, and any JUnit/JSON
  artifacts.
- **Crash safety:** requests move `requests/` → `processing/` → `done/`.
  Leftover worktrees and `processing/` entries are cleaned up and reported as
  `aborted` at start.

### 3.7 CLI surface (`bin/cradle`)

| Command | Runs on | Does |
|---|---|---|
| `cradle setup` | host | one-time: checks and (with confirmation) fixes subuid/subgid, enables the podman socket, installs the devcontainer CLI and act, builds images, installs cradle-testd |
| `cradle doctor` | host | checks everything in §5 |
| `cradle init [--force]` / `init --detach` | host | attach the current project (§3.2) / remove its testd unit and network |
| `cradle up` / `down` | host | start or stop the project network, proxy and dev container |
| `cradle claude [args]` / `shell` | host | `up`, then `claude` or a shell inside the container |
| `cradle test <job> [ref]` | host | enqueue a tier-2 run by hand (same path as a container request) |
| `cradle token set\|show-expiry <repo>` | host | manage the per-repo token |
| `cradle push` | host | push the current branch with the host's own gh auth (for workflow changes) |
| `cradle approve-workflows` | host | show the workflow diff against the approved set; approve on confirmation |
| `cradle config sync` | host | sync kit-owned config into the shared volume |
| `cradle image build` | host | rebuild `cradle-base` and the proxy image |
| `cradle net log` | host | show the proxy's blocked requests |

Inside the container, `cradle-request <job>` writes the request file for
`HEAD` and waits for `status.json` (it has no other power).

## 4. Data flow: one development cycle

1. `cradle claude` → doctor quick check → config sync if stale → token from
   the keyring → `devcontainer up` → quarryd starts → `claude`.
2. Tier 1 in the container: TDD with unit tests, lint and build. The
   pre-commit hook runs `punt pii --staged` and ethos's audit seal; commit-msg
   adds the ethos trailers; beads tracks the task.
3. Tier 2: `cradle-request gui-linux` → cradle-testd validates and runs act
   on a worktree of that commit → the result is read from
   `.cradle/results/<id>/`.
4. Tier 3: push the branch with `GH_TOKEN`, open a PR, `gh run watch`, fix
   failures. Windows and macOS jobs run only here.
5. Release: per project, unchanged (for example Lure's `publishing.md`);
   browser steps stay on the host.

## 5. Error handling

- `cradle doctor` checks: subuid/subgid entries, podman rootless and socket,
  devcontainer CLI and act versions, image tags against the kit version,
  config sync manifest, token presence and expiry (warns at 7 days), free
  disk (warns under 15 GB), free RAM, cradle-testd status, and proxy
  reachability.
- Every rejected request, timeout or crash produces a `status.json` with a
  reason; a request never disappears silently.
- A failed image build leaves the previous tag in place.
- Quirks found in podman, act, the devcontainer CLI or the punt tools go into
  `dev/takeaways.md` (for later bug reports).

## 6. Testing cradle

- **Unit:** bats for every subcommand, with podman, devcontainer, act, gh and
  secret-tool stubbed; shellcheck on all shell files.
- **Integration (local and CI):** build the images; `cradle init` on fixture
  projects (Node, Python, Go); tier 1 inside the container; one tier-2 run
  through cradle-testd with a fixture workflow.
- **Security (each must be refused or fail):** a workflow with a host volume,
  `--privileged` or `container.options`; an unapproved workflow hash; an
  unknown job; a request with extra fields; an outbound request to a domain
  outside the allowlist; reading `.personal/` inside the container; reaching
  the podman socket from the container; pushing a workflow change with the
  container token.
- **GitHub Actions for cradle:** shellcheck, bats, image build and the
  integration suite on `ubuntu-latest` (docker there, podman locally;
  differences go into takeaways).
- **Pilot:** once the base works, further cradle development happens inside
  cradle's own container.

## 7. Documentation and localization

- `README.md` (per project guidelines): description; AI disclosure (model,
  provider, approximate tokens) as a bullet list for agent and author;
  features; installation; license (AGPL-3.0); links to docs, issues and a
  donation option (designation: carbon offset for tokens, unless decided
  otherwise); software that integrates (punt-labs tools, act, devcontainer
  CLI); similar projects and their differences (DevPod, devcontainer CLI,
  toolbx/distrobox, Anthropic's reference dev container). German translation
  in `docs/i18n/README.de.md`.
- `docs/`: architecture, security model, attaching a project,
  troubleshooting.
- `dev/takeaways.md` from the start.
- CLI messages through gettext (`locale/{en,de}`), plus a check that every
  message id has a German entry.

## 8. Risks and open points for the plan

- act on podman: act targets the Docker API; the podman socket is compatible
  but has known gaps. To be verified first; if act turns out unusable, the
  fallback is cradle-testd running the job's steps in a plain podman container.
- The devcontainer CLI on rootless podman: user-ID mapping (`keep-id`) and
  feature installation need an early spike.
- Resources: quarryd's RAM inside a 3 GB container limit is unmeasured;
  measure it in the first spike and adjust the limits.
- The punt-labs tools are beta: pin commits and versions; run their installers
  at image build, never from inside a running session.
- The GitHub repo `Gelaende51/cradle` is created only when the plan reaches
  that step (it is an outward-facing action and is confirmed then).
