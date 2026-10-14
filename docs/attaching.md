# Attaching a project

## `cradle init`

Run in the project's git root. It writes `.devcontainer/cradle.json`, adds a block to `.gitignore` (`.cradle/`, the render hash and the rendered `devcontainer.json`), copies `.actrc` and — when the project has no `.github/workflows/ci.yml` — a CI template with a `test` job, and installs the project's tier-2 units. `--force` rewrites `cradle.json`; `--detach` removes the test unit, the proxy and the network and keeps volumes and results.

## `cradle.json`

| Key | Meaning |
|---|---|
| `languages` | detected from the project (node, python, go, rust, java); each adds its Dev Container feature |
| `features` | extra Dev Container features, only from cradle's allowlist (`FEATURES_JSON` in `lib/render.sh`) |
| `maskPaths` | paths hidden inside the container (default `.personal`) |
| `memory` | the container's memory limit (default `3g`) |
| `secrets` | names of environment variables the sessions get from the keyring, e.g. `["CLOUDFLARE_API_TOKEN"]` (see *Secrets*) |
| `allowedDomains` | domains the proxy allows in addition to the kit's list; `.example.com` includes subdomains |
| `testJobs` | `[{"workflow": "ci.yml", "job": "test", "network": false}]` — jobs the container may request |
| `testTimeout` | minutes per tier-2 run (default 30) |

`devcontainer.json` is rendered from this file on every `cradle up`; a hand edit is refused.

## Tokens

`cradle token set owner/repo` stores a fine-grained GitHub token in the keyring (secret-tool). Give it the repository's contents, pull requests and issues permissions, **not** *workflows*. `cradle token show-expiry` tells how long it is valid; `cradle doctor` warns 7 days ahead. Workflow changes are pushed from the host with `cradle push`, which uses the host's own gh login.

## Secrets

Some projects need an API token of their own in the container, such as a model provider's. List its name under `secrets` in `cradle.json`, then store the value on the host: `cradle secret set CLOUDFLARE_API_TOKEN` (it asks for the value; from a pipe it reads stdin). `cradle claude` and `cradle shell` pass each declared secret into the session as an environment variable, by name (`podman exec -e NAME`): the value never appears on a command line, in `devcontainer.json` or in the volume. A secret that isn't stored stays unset; a variable of the same name in the host shell is never passed on. `cradle secret list` shows which declared secrets are stored; `cradle secret unset NAME` removes one. Values are per repository, like tokens. Give each the narrowest permission that does the job, because Claude in the container can read it.

## Tier-2 tests

1. List the job in `testJobs`. A job that installs packages needs `"network": true`.
2. Review and approve the workflows on the host: `cradle approve-workflows` shows the diff of `.github` since the last approval. The remote's default branch counts as reviewed.
3. Request a run: `cradle-request test` in the container, or `cradle test test` on the host. Both wait for the result and exit 0 only when the job passed; the log is in `~/.cradle/results/<id>/act.log` (container) or `~/.local/state/cradle/testd/<key>/results/<id>/act.log` (host).

Every change under `.github` needs a new approval; `runs-on` must be `ubuntu-latest` (the one platform cradle maps to a local image). Windows and macOS jobs run on GitHub only.
