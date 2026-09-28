# Takeaways

Distinct challenges, oddities and insights met while building cradle, kept
for reference and for bug reports, feature requests or pull requests upstream.

## act: runs on rootless podman through the Docker-compatible socket
act 0.2.89 needs only `DOCKER_HOST=unix://$XDG_RUNTIME_DIR/podman/podman.sock`.
`--container-daemon-socket -` keeps the socket out of job containers and
`--network none` cuts egress; both verified. The medium runner image
`catthehacker/ubuntu:act-latest` is 1.66 GB, which matters with 47 GB free.
Not worth an upstream report.
