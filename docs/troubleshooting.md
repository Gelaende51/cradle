# Troubleshooting

Start with `cradle doctor` in the project folder. Each line is `ok`, `warn` or `fail` with the fix:

| Line | Fix |
|---|---|
| `subuid` fail | `sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER && podman system migrate` |
| `rootless` fail | podman must run as your user, not root |
| `cgroup-memory` warn | memory limits are ignored until the memory controller is delegated to your user session |
| `devcontainer`, `act`, `gh`, `jq`, `secret-tool`, `python-yaml` | install the tool; `cradle setup` prints the commands |
| `image` warn | `cradle image build` |
| `config` warn | `cradle config sync` |
| `proxy` warn | `cradle up` |
| `testd` warn | `cradle init --force` re-installs and starts the project's path unit |
| `token` warn | `cradle token set owner/repo` |
| `disk` warn | under 15 GB free; remove old images (`podman images`, `podman image prune`) |

## A request was refused

Read the reason: `jq -r .reason ~/.cradle/results/<id>/status.json` (container) or under `~/.local/state/cradle/testd/<key>/results/` (host). Typical reasons: the job is not in `testJobs`; `.github` at that commit is not approved (run `cradle approve-workflows <ref>` on the host); the job uses container options, volumes, a reusable workflow, another `runs-on`; the commit has a symlink leading out of the tree.

## Requests are not picked up

`systemctl --user status cradle-testd@<key>.path`. After many failed starts systemd stops it: `systemctl --user reset-failed cradle-testd@<key>.service` and `cradle init --force`.

## A download fails in the container

`cradle net log` lists what the proxy refused. Add the domain to `allowedDomains` in `cradle.json` and run `cradle up` again.

## `devcontainer.json was edited by hand`

Move the change into `cradle.json`, delete `.devcontainer/devcontainer.json`, run `cradle up`.
