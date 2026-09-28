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
