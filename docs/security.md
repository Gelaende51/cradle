# Security model

The dev container is where Claude works, so cradle treats everything the container can write as untrusted: the project files, the parts of `.git` it can reach, the request queue. The host side (the operator, `bin/cradle`, `cradle-testd`) is trusted.

## Promises and their checks

| Promise | Mechanism | Checked by |
|---|---|---|
| No container socket, no capabilities, no host home | runArgs `--cap-drop=ALL`, `--security-opt=no-new-privileges`, only the project folder and named volumes are mounted | `tests/integration/foundation.sh` |
| Masked paths (`.personal/` by default) | tmpfs or `/dev/null` over each `maskPaths` entry | `foundation.sh`, `tests/render.bats` |
| Host git never runs container-written code | `.git/hooks`, `.git/config`, `.devcontainer/` mounted read-only; the container's hooks live in the data volume; host git runs with `core.hooksPath=/dev/null` and no fsmonitor | `foundation.sh`, `tests/session.bats` |
| Egress only to listed domains | internal network + squid allowlist (`dstdomain`), local and private destinations refused | `tests/integration/proxy.sh`, `tests/proxy.bats` |
| Tokens never in argv or files | the token is read from the keyring and passed through the environment | `tests/session.bats`, `tests/token.bats` |
| A tier-2 request cannot reach outside its sandbox | maildir taken by rename; strict request schema; commits read from a host-private mirror; approved `.github` tree; job allowlist (`runs-on: ubuntu-latest`, no container options or volumes, no services with volumes or options, no reusable workflows, local actions only under `.github`, no expressions in `container`/`services`); no symlink under `.github` or leading out of the tree; act without socket, without network, without the commit's `.actrc` or env files | `tests/testd*.bats`, `tests/integration/testd.sh` |
| A request never disappears | every rejection, timeout or crash writes `status.json`; leftovers are reported `aborted` on the next start | `tests/testd-run.bats` |

## Not protected

- A job marked `"network": true` in `cradle.json` has internet access (podman's bridge) while it runs.
- Approved workflows are trusted: approval is the operator's review of the `.github` diff.
- quarry writes session transcripts to `.punt-labs/quarry/captures/` in the project; the container adds that path to `.git/info/exclude` on every start, so `git add -A` leaves them out — a project that force-adds them publishes them.
- Local docker actions under `.github` are built by the host's podman with network access.
- act's job containers can outlive a runner that is killed (`systemctl stop`, a timeout).
- Pushing a workflow change with the container's token must fail because the token lacks the *workflows* permission; this depends on how the token was created and is checked by hand: in the container, change a file under `.github/workflows/`, commit and `git push` — GitHub refuses it.
