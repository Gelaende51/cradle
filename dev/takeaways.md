# Takeaways

Distinct challenges, oddities and insights met while building cradle, kept
for reference and for bug reports, feature requests or pull requests upstream.

## act: runs on rootless podman through the Docker-compatible socket
act 0.2.89 needs only `DOCKER_HOST=unix://$XDG_RUNTIME_DIR/podman/podman.sock`.
`--container-daemon-socket -` keeps the socket out of job containers and
`--network none` cuts egress; both verified. The medium runner image
`catthehacker/ubuntu:act-latest` is 1.66 GB, which matters with 47 GB free.
Not worth an upstream report.

## devcontainer CLI: mounts the enclosing git root unless workspaceMount is set
With `--workspace-folder` pointing at a subdirectory of a git repository, the
CLI mounts the repository root, not the folder. cradle always sets
`workspaceMount`. Documented behaviour (`mountWorkspaceGitRoot`), not a bug.

## devcontainer CLI on podman: adds --userns=keep-id itself
The CLI injects `--userns=keep-id` for podman; a later
`--userns=keep-id:uid=1000,gid=1000` in `runArgs` overrides it and is needed
here because the host gid (1001) differs from the container user's gid (1000).

## devcontainer CLI: first up is slow on this host
Image pull plus the node feature build took ~19 minutes on the first run
(network shared with other pulls); cached runs take ~2 minutes. Never wrap
`devcontainer up` in a short timeout.

## Debian sudo: purge needs SUDO_FORCE_REMOVE=yes
Removing sudo from the devcontainers Debian image fails ("Refusing to remove
sudo") because root has no password; `SUDO_FORCE_REMOVE=yes apt-get purge -y sudo`
is Debian's documented switch.

## quarry 3.4.0: only indexes directories under $HOME
`quarry register` and `quarry enable` refuse any path outside the home
directory ("directory '/tmp/ws' is outside '/home/dev'"). The Dev Container
convention `/workspaces/<name>` is therefore unusable with quarry; cradle mounts
projects at `/home/dev/src/<slug>`. Candidate feature request: an allowlist of
extra roots (containers, monorepos on other disks).

## quarry 3.4.0 in a container: runs without systemd
`quarryd` in the foreground answers `quarry status` after ~4 s, needs no TLS
setup on loopback, and uses ~320 MB RSS idle and ~500 MB while indexing
(measured under a 3 GB limit). The build-time model download through
`OnnxEmbeddingBackend.download_model_files()` works with `HF_HUB_OFFLINE=1` at
runtime.

## ethos 4.19.1: no --version flag
`ethos version` prints the version; `ethos --version` is an unknown flag.

## cradle-base build: 7.5 min, 2.1 GB peak memory, 3.17 GB image
A background build started from Claude Code's shell was killed once for low
memory; running it as `systemd-run --user` detached it from the session.

## devcontainer CLI 0.89.0 + podman journald events: `up` can hang forever
The CLI starts `podman events --filter event=start` a few ms *after*
`podman run` and waits for the start event. With podman's journald events
backend the subscription is not ready ~0.4 s later when the container starts,
the event is lost, and `devcontainer up` never returns (reproduced 2/2; the
spike passed by luck). cradle calls the CLI with
`CONTAINERS_CONF_OVERRIDE=lib/podman-events.conf` (`events_logger = "file"`).
Worth an upstream report: subscribe before `run`, or use `--since`.

## ethos 4.19.1: setup --file needs `ethos seed` first; whoami needs git email
`ethos setup --file` fails with "references personality … not installed; run
ethos seed first" on a fresh home. `ethos whoami` resolves by git user/email,
so it fails in a repo without git identity; the identity file
(`~/.punt-labs/ethos/identities/<handle>.yaml`) is the reliable guard.
`ethos enable` in a fresh repo wrote no hooks (neither core.hooksPath nor
.git/hooks) and printed "next: run ethos setup" — open point for Plan 2+.

## podman 6 `ps --format` cannot index labels
- `podman ps --format '{{index .Labels "x"}}'` fails with "cannot index slice/array with type string" on podman 6.1.2; `podman inspect --format '{{index .Config.Labels "x"}}' <id>` works. cradle reads its `cradle.render` label that way.

## devcontainer exec puts remoteEnv values on podman's command line
- `devcontainer exec` runs `podman exec -e GH_TOKEN=<value> …`, so the token is visible in the host's process list. cradle runs `claude`/`shell` through `podman exec -e GH_TOKEN` (name only, value from the environment) instead. Candidate issue for devcontainers/cli: pass remoteEnv through the environment.

## Read-only .git/hooks and .git/config inside the container
- Bind-mounting both read-only over the workspace bind mount works on rootless podman; git's lockfile rename onto the mounted config fails, so `git config` in the container is refused. `bd init` (beads 1.3.0) and `ethos enable` still succeed with it.
