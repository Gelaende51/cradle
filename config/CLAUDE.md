# cradle dev container

- You run inside a rootless podman dev container managed by cradle. The project is at `$CRADLE_WORKSPACE`.
- Host credentials are not available here: `.personal/` is masked. When a task needs an account or a secret, ask the operator.
- GitHub: `gh` and `git push` use a token for this repository only. It cannot change `.github/workflows/`: commit workflow changes and ask the operator to run `cradle push` on the host.
- Tests: unit tests, lint and build run here. Anything that starts the built software runs in isolated test containers or on GitHub Actions.
- Host-only tools (the usage scripts under `~/building_stuff/scripts`, Obsidian, browsers) are not reachable from here.

@cradle-rules/planning.md
@cradle-rules/project_guidelines.md
@cradle-rules/orchestrator.md
@cradle-rules/extension_guidelines.md
@cradle-rules/ux_guidelines.md
