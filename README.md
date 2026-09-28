# cradle

**English** · [Deutsch](docs/i18n/README.de.md)

cradle runs Claude Code and a project's development inside a per-project dev container on one Linux PC, with rootless podman and the Dev Container CLI. Tests that start the built software run in separate, disposable containers through [act](https://github.com/nektos/act), or on GitHub Actions — the same workflow file for both. It works for any kind of project; the project stays where it is and is attached with one command.

## AI disclosure

- **Agent** — **Claude Opus 5.5** (Anthropic, via Claude Code): wrote the shell code, the tests, the images, the CI, the German catalog and the documentation; a separate Claude Opus reviewer checked each plan's branch before it was merged. The German texts are machine translations.
- **Usage** — 27 Sept 2026 – 28 Sept 2026, 1 session(s), \~458 responses: \~0.6 M tokens generated, \~2.3 M sent, \~117.5 M cached re-reads. Sessions inside cradle's own container are not counted yet.
- **Upstream** — the model learned from open source code and documentation published by others. Most of the credit goes there.
- **Author** — Vault51: set the goals and every design decision, approved the spec and the plans, directed the work.

## Features

- **One command to start.** `cradle init && cradle claude` in a project folder builds the container on first use, starts it and opens Claude Code inside it. The project folder is bind-mounted, so any editor on the host keeps working.
- **Isolation you can check.** Inside the container there is no podman or docker socket, no host home and no capability; `.personal/` and other listed paths are masked; the host's `.git/hooks`, `.git/config` and `.devcontainer/` are read-only. Network traffic leaves only through a per-project proxy that allows listed domains — `cradle net log` shows what it refused. Each promise has a test ([security model](docs/security.md)).
- **Tests in separate containers.** Claude runs `cradle-request <job>` in the container; the host runs that job of the project's GitHub Actions workflow with act, in throwaway containers without network (unless the job is marked) and without a container socket, and hands back a read-only result. Workflows run only after the operator approved them on the host (`cradle approve-workflows`).
- **Shared config, narrow tokens.** One `cradle-claude` volume holds Claude's config for every project; the kit's rules and settings are synced into it (`cradle config sync`). Each repository gets a fine-grained token from the keyring without the *workflows* permission; workflow changes are pushed from the host (`cradle push`).

## Installation

Requirements: Linux with a systemd user session, rootless podman 5 or later, act, the Dev Container CLI 0.89.0, jq, gh, secret-tool and python-yaml. `cradle setup` installs what it can without sudo and prints the rest.

```sh
git clone https://github.com/Gelaende51/cradle ~/cradle
ln -s ~/cradle/bin/cradle ~/.local/bin/cradle
cradle setup            # add --yes to run the steps it prints
cradle image build
cradle doctor
```

First project:

```sh
cd ~/code/my-project
cradle init
cradle token set owner/my-project    # paste a fine-grained token
cradle claude
```

## Documentation

- [Architecture](docs/architecture.md) — containers, networks, volumes and the test service
- [Security model](docs/security.md) — what is protected, how, which test checks it, and what is not
- [Attaching a project](docs/attaching.md) — `cradle.json`, tokens, approving workflows, tier-2 tests
- [Troubleshooting](docs/troubleshooting.md) — `cradle doctor`, refused requests, the proxy log
- [Takeaways](dev/takeaways.md) — quirks found in podman, act, the Dev Container CLI, squid and the punt tools

## Works with

- [punt-labs](https://github.com/punt-labs) tools, preinstalled in the image: punt-kit (`punt pii` in the pre-commit hook), beads (`bd`), quarry and ethos.
- [act](https://github.com/nektos/act), [the Dev Container CLI](https://github.com/devcontainers/cli), [podman](https://podman.io) and GitHub Actions.

## Similar projects

- **[DevPod](https://devpod.sh)** — dev environments on many providers; no egress allowlist and no split between the dev container and test containers.
- **[The Dev Container CLI](https://github.com/devcontainers/cli) on its own** — cradle wraps it and adds the proxy, the masks, the token handling and the test service.
- **[toolbx](https://containertoolbx.org) / [distrobox](https://distrobox.it)** — integrate with the host on purpose (shared home, devices); cradle does the opposite.
- **[Anthropic's reference Claude Code dev container](https://github.com/anthropics/claude-code/tree/main/.devcontainer)** — a firewall script inside one container; cradle keeps the firewall outside the dev container and runs tests in other containers.

## Contributing

Issues and pull requests: [github.com/Gelaende51/cradle/issues](https://github.com/Gelaende51/cradle/issues). Run `make check` (shellcheck, the German catalog check and the bats suite) before a pull request; `make integration`, `make proxy-smoke` and `make testd-integration` run the podman suites. There is no donation option yet.

## License

[AGPL-3.0](LICENSE).
