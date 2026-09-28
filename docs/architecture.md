# Architecture

cradle is a bash CLI (`bin/cradle`, `lib/*.sh`) around rootless podman, the Dev Container CLI and act. Everything below runs on one Linux PC as the operator's user.

## Per attached project

Each project gets a key `<slug>-<8 hex of the path's sha256>`. With it:

| Piece | Name | Purpose |
|---|---|---|
| Dev container | created by `devcontainer up` from `.devcontainer/devcontainer.json` (rendered from `cradle.json`, never edited by hand) | Claude Code and the project's tools; user `dev`, no capabilities, no new privileges, a memory limit |
| Internal network | `cradle-<key>` | the dev container's only network; it has no route out |
| Egress proxy | `cradle-proxy-<key>` (squid, alias `proxy`) on `cradle-<key>` and `cradle-egress` | the only way out; allows the kit's default domains plus the project's `allowedDomains` |
| Data volume | `cradle-<key>-data` → `/home/dev/.local/share/cradle` | git hooks path, quarry data, logs |
| Test state | `~/.local/state/cradle/testd/<key>/` | `req/` (mounted read-write at `/home/dev/.cradle/requests`), `results/` (mounted read-only at `/home/dev/.cradle/results`), host-private `processing/`, `done/`, `approved`, `mirror.git` |
| Test units | `cradle-testd@<key>.path` / `.service` (systemd user) | start `bin/cradle-testd <key>` when a request arrives |

## Shared by all projects

- `cradle-claude` volume → `/home/dev/.claude`: Claude's config and login. `cradle config sync` copies the kit's `config/` into it through a throwaway container and merges `settings.json`.
- `cradle-punt` volume → `/home/dev/.punt-labs`: ethos identities.
- Images `localhost/cradle-base:<version>` (Debian, Claude Code, gh, uv, punt tools, bats, shellcheck) and `localhost/cradle-proxy:<version>` (alpine + squid), built by `cradle image build`.

## A tier-2 test run

1. In the container, `cradle-request <job> [ref]` writes `{"ref": "<sha>", "job": "<job>"}` into `requests/tmp/` and renames it into `requests/new/`.
2. The path unit starts `cradle-testd`. It takes `req/new/` as a whole into `processing/` (a rename, so nothing the container swaps in is followed), then checks each request: the exact two fields, a listed job, the commit fetched into the host-private `mirror.git` (git re-hashes every object, so a rewritten object fails), the `.github` tree approved, the job's definition safe, no symlink leading out of the tree.
3. It runs `act -C <worktree> … --container-daemon-socket - --network none` (or podman's bridge for a job marked `network: true`) from an empty directory, with `/dev/null` for act's env, secret, var and input files, under a global lock and a time limit.
4. The result is `results/<id>/status.json` (`passed`, `failed`, `rejected`, `timeout` or `aborted` with a reason), `act.log` and `artifacts/`. The request moves to `done/`.

## Commands

| Command | Does |
|---|---|
| `cradle setup [--yes]` | one-time host checks; installs the Dev Container CLI, enables the podman socket, prints sudo steps |
| `cradle doctor` | checks the host and the current project |
| `cradle image build` | builds both images; a failed build keeps the old tag |
| `cradle config sync` | syncs the kit's config into `cradle-claude` |
| `cradle init [--force]` / `--detach` | attaches the project / removes its test unit, proxy and network (volumes and results stay) |
| `cradle up` / `down` | starts or stops the proxy and the dev container |
| `cradle claude [args]` / `shell` | `up`, then Claude Code or a shell in the container |
| `cradle token set\|show-expiry [owner/repo]` | the per-repo token in the keyring |
| `cradle push [--yes]` | pushes with the host's gh credentials (for workflow changes) |
| `cradle approve-workflows [--yes] [ref]` | shows the `.github` diff and approves it for tier-2 runs |
| `cradle test <job> [ref]` | a tier-2 request from the host |
| `cradle net log` | the proxy's refused requests |
