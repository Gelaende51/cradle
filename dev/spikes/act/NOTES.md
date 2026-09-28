# Spike B: act on rootless podman

Date: 2026-09-28 · act 0.2.89 · podman 6.1.2 (rootless) · image catthehacker/ubuntu:act-latest (1.66 GB)

Command:

```bash
export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/podman/podman.sock"
act -W .github/workflows/spike.yml -j hello \
  -P ubuntu-latest=catthehacker/ubuntu:act-latest \
  --container-daemon-socket - --network none
```

Output (tail):

```text
[spike/hello]   | kernel: 7.2.6-zen2-1-zen
[spike/hello]   | uid=0(root) gid=0(root) groups=0(root)
[spike/hello]   | NOSOCKET
[spike/hello]   | NONET
[spike/hello] 🏁  Job succeeded
```

**Result: works.** The job runs through the podman socket; inside the job there is
no container socket (`--container-daemon-socket -`) and no network
(`--network none`). The job runs as root inside its container, which rootless
podman maps to the host user; that is the isolation boundary for Plan 3.
