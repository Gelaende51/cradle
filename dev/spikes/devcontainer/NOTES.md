# Spike A: devcontainer CLI on rootless podman

Date: 2026-09-28 · @devcontainers/cli 0.89.0 · podman 6.1.2 rootless · host user uid 1000

Fixture: `.devcontainer/devcontainer.json` (base:debian + node feature,
`--userns=keep-id:uid=1000,gid=1000 --security-opt=no-new-privileges --cap-drop=ALL --memory=3g`).

Probe output inside the container:

```text
uid=1000(vscode) gid=1000(vscode) groups=1000(vscode),999(nvm)
v24.21.0
CapEff:	0000000000000000
3221225472
-rw-r--r-- 1 1000 1000 0 … /workspaces/cradle/dev/spikes/devcontainer/owned-by-container
ls: cannot access '/run/podman': No such file or directory
```

On the host: `<user>:<group> owned-by-container`. Label:
`devcontainer.local_folder=~/building_stuff/cradle/dev/spikes/devcontainer`.

**Result: works with `--userns=keep-id:uid=1000,gid=1000`.** Ownership on the
bind mount is correct, all capabilities are dropped, the 3 GiB memory limit
applies, no podman socket is visible, and `devcontainer.local_folder` is the
label that identifies a project's container.

Other findings:
- The CLI adds its own `--userns=keep-id` for podman; ours comes later on the
  command line and wins.
- Without `workspaceMount`, the CLI mounts the enclosing git repository's root
  (here the whole cradle repo) at `/workspaces/<repo>`. cradle sets
  `workspaceMount` explicitly.
- The first `up` took ~19 minutes (image pull + node feature build via
  `podman buildx`, with two other downloads competing); the second, cached,
  ~2 minutes.
