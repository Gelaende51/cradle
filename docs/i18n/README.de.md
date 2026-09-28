# cradle

[English](../../README.md) · **Deutsch**

cradle führt Claude Code und die Entwicklung eines Projekts in einem eigenen Dev-Container pro Projekt auf einem Linux-PC aus, mit rootless podman und der Dev-Container-CLI. Tests, die die gebaute Software starten, laufen in getrennten Wegwerf-Containern über [act](https://github.com/nektos/act) oder auf GitHub Actions — mit derselben Workflow-Datei. Es funktioniert für jede Art von Projekt; das Projekt bleibt, wo es ist, und wird mit einem Befehl angebunden.

## KI-Offenlegung

- **Agent** — **Claude Opus 5.5** (Anthropic, über Claude Code): hat den Shell-Code, die Tests, die Images, die CI, den deutschen Katalog und die Dokumentation geschrieben; ein separater Claude-Opus-Reviewer hat den Branch jedes Plans vor dem Merge geprüft. Die deutschen Texte sind maschinell übersetzt.
- **Nutzung** — 27. Sept. 2026 – 28. Sept. 2026, 1 Sitzung(en), \~458 Antworten: \~0,6 M Tokens erzeugt, \~2,3 M gesendet, \~117,5 M aus dem Cache erneut gelesen. Sitzungen im eigenen cradle-Container sind noch nicht mitgezählt.
- **Vorarbeit** — das Modell hat aus Open-Source-Code und Dokumentation gelernt, die andere veröffentlicht haben. Der größte Teil des Verdiensts gehört ihnen.
- **Autor** — Vault51: hat die Ziele und jede Designentscheidung festgelegt, Spezifikation und Pläne freigegeben und die Arbeit gesteuert.

## Funktionen

- **Ein Befehl zum Start.** `cradle init && cradle claude` im Projektordner baut beim ersten Mal den Container, startet ihn und öffnet darin Claude Code. Der Projektordner ist per Bind-Mount eingebunden, jeder Editor auf dem Host funktioniert weiter.
- **Überprüfbare Isolation.** Im Container gibt es keinen podman- oder docker-Socket, kein Home-Verzeichnis des Hosts und keine Capabilities; `.personal/` und weitere gelistete Pfade sind ausgeblendet; `.git/hooks`, `.git/config` und `.devcontainer/` des Hosts sind schreibgeschützt. Netzwerkverkehr verlässt den Container nur über einen Proxy pro Projekt, der gelistete Domains erlaubt — `cradle net log` zeigt, was er abgewiesen hat. Jede Zusage hat einen Integrationstest.
- **Tests in getrennten Containern.** Claude ruft im Container `cradle-request <job>` auf; der Host führt diesen Job aus dem GitHub-Actions-Workflow des Projekts mit act aus, in Wegwerf-Containern ohne Netzwerk (außer der Job ist dafür markiert) und ohne Container-Socket, und gibt ein schreibgeschütztes Ergebnis zurück. Workflows laufen erst, nachdem sie auf dem Host freigegeben wurden (`cradle approve-workflows`).
- **Gemeinsame Konfiguration, schmale Tokens.** Ein Volume `cradle-claude` hält die Claude-Konfiguration für alle Projekte; Regeln und Einstellungen des Kits werden hineinsynchronisiert (`cradle config sync`). Jedes Repository bekommt ein fein granuliertes Token aus dem Schlüsselbund ohne die Berechtigung *workflows*; Workflow-Änderungen werden vom Host gepusht (`cradle push`).

## Installation

Voraussetzungen: Linux mit systemd-Benutzersitzung, rootless podman ab Version 5, act, die Dev-Container-CLI 0.89.0, jq, gh, secret-tool und python-yaml. `cradle setup` installiert, was ohne sudo geht, und gibt den Rest aus.

```sh
git clone https://github.com/Gelaende51/cradle ~/cradle
ln -s ~/cradle/bin/cradle ~/.local/bin/cradle
cradle setup            # mit --yes werden die ausgegebenen Schritte ausgeführt
cradle image build
cradle doctor
```

Erstes Projekt:

```sh
cd ~/code/mein-projekt
cradle init
cradle token set owner/mein-projekt    # ein fein granuliertes Token einfügen
cradle claude
```

Die Meldungen der CLI erscheinen auf Deutsch, wenn die Locale deutsch ist (`LANG=de_DE.UTF-8`).

## Dokumentation (englisch)

- [Architektur](../architecture.md) — Container, Netzwerke, Volumes und der Testdienst
- [Sicherheitsmodell](../security.md) — was geschützt ist, wie, welcher Test es prüft und was nicht geschützt ist
- [Projekt anbinden](../attaching.md) — `cradle.json`, Tokens, Freigabe von Workflows, Tier-2-Tests
- [Fehlersuche](../troubleshooting.md) — `cradle doctor`, abgewiesene Anfragen, das Proxy-Log
- [Erkenntnisse](../../dev/takeaways.md) — Eigenheiten von podman, act, der Dev-Container-CLI, squid und den punt-Werkzeugen

## Arbeitet zusammen mit

- Werkzeugen von [punt-labs](https://github.com/punt-labs), im Image vorinstalliert: punt-kit (`punt pii` im pre-commit-Hook), beads (`bd`), quarry und ethos.
- [act](https://github.com/nektos/act), [der Dev-Container-CLI](https://github.com/devcontainers/cli), [podman](https://podman.io) und GitHub Actions.

## Ähnliche Projekte

- **[DevPod](https://devpod.sh)** — Entwicklungsumgebungen bei vielen Anbietern; keine Allowlist für ausgehenden Verkehr und keine Trennung zwischen Dev-Container und Test-Containern.
- **[Die Dev-Container-CLI](https://github.com/devcontainers/cli) allein** — cradle baut auf ihr auf und ergänzt Proxy, Ausblendungen, Token-Verwaltung und den Testdienst.
- **[toolbx](https://containertoolbx.org) / [distrobox](https://distrobox.it)** — binden den Host absichtlich ein (gemeinsames Home, Geräte); cradle macht das Gegenteil.
- **[Anthropics Referenz-Dev-Container für Claude Code](https://github.com/anthropics/claude-code/tree/main/.devcontainer)** — ein Firewall-Skript in einem einzigen Container; cradle hält die Firewall außerhalb des Dev-Containers und führt Tests in anderen Containern aus.

## Mitwirken

Issues und Pull Requests: [github.com/Gelaende51/cradle/issues](https://github.com/Gelaende51/cradle/issues). Vor einem Pull Request `make check` ausführen (shellcheck, die Prüfung des deutschen Katalogs und die bats-Suite); `make integration`, `make proxy-smoke` und `make testd-integration` führen die podman-Suiten aus. Eine Spendenmöglichkeit gibt es noch nicht.

## Lizenz

[AGPL-3.0](../../LICENSE).
