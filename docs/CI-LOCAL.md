# CI lokal — Self-hosted Runner + Claude Code, weg von GitHub-hosted Actions

Ziel: Build/Test/AI-Review laufen auf eigener Hardware statt auf GitHub-hosted Runnern.
Aufgesetzt von `roles/13_github_runner` (User `devrunner`, uid 1003).

## Härtung (Default)

- **Ephemeral** Runner (`--ephemeral`): meldet sich nach **einem** Job ab → kein
  persistenter Backdoor. Steuerbar via `github_runner_ephemeral` (Default `true`).
- **Eigene Runner-Group** (`github_runner_group`, Default `ai-server-trusted`): nur für
  **trusted** Repos/Branches freigeben.
- **Keine untrusted PRs / Public-Repos** auf diesem Runner. Kein `pull_request_target` mit
  Secrets. Keine Prod-Secrets im Runner-Kontext.
- **non-root** (`devrunner`), eigene cgroup-Slice (800% CPU / 24G).

> Hintergrund: GitHub warnt ausdrücklich, dass self-hosted Runner durch untrusted Workflow-Code
> dauerhaft kompromittiert werden können (vgl. „Shai-Hulud"-Worm, Manipulation von
> `RUNNER_TRACKING_ID`). Ephemeral + trusted-only ist die Gegenmaßnahme.

## Respawn-Loop (implementiert)

Ein ephemerer Runner verarbeitet genau einen Job und dereg. sich. Für Dauerbetrieb installiert
`roles/13_github_runner` einen **Respawn-Loop** als systemd-Service `github-runner-ephemeral`:

- Loop-Skript `/home/devrunner/actions-runner/run-ephemeral.sh` holt pro Durchlauf einen
  frischen **JIT-Registration-Token** (via `gh api …/registration-token`), konfiguriert den
  Runner `--ephemeral --replace`, läuft **einen** Job, räumt die lokale Config weg, registriert
  neu. `Restart=always`.
- Der PAT liegt dafür `0600` beim `devrunner` unter `~/.runner-pat`. Für mehr Isolation einen
  **fine-grained PAT** nutzen, der nur `self-hosted runners: write` darf.
- Umschalten auf den klassischen, dauerhaft registrierten Runner: `github_runner_ephemeral: false`
  (nutzt dann `svc.sh`).

Steuervariablen (in `inventory/group_vars/ai_server/main.yml`): `github_runner_ephemeral`,
`github_runner_group`. Status prüfen: `systemctl status github-runner-ephemeral`.

## Claude Code als Coding-Agent auf dem Runner (Abo statt API)

Der Runner trägt das Label `claude-code`. Workflows können Claude Code als Step nutzen.
Damit das über das **Abo** (Claude Max) statt API läuft:

1. Einmalig einen OAuth-Token erzeugen: `claude setup-token` (als `devrunner`).
2. Token als **scoped GitHub Secret** hinterlegen (z.B. `CLAUDE_CODE_OAUTH_TOKEN`), nur für
   trusted Repos.
3. Im Workflow den Token statt `ANTHROPIC_API_KEY` nutzen.

So entsteht ein **lokaler Agent-Runner**: GitHub-Issue/PR → self-hosted Runner →
Claude Code (Abo) → Tests/Build → Push. Keine Abhängigkeit von GitHub-hosted Compute.

## Ausbaustufe: ARC (optional, nicht installiert)

Für saubere Pod-pro-Job-Isolation + Autoscaling: **Actions Runner Controller (ARC)** auf
einem Single-Node-k3s. Pro Job ein ephemerer Pod, NetworkPolicies, Harden-Runner (eBPF).
Mehr Komplexität (Kubernetes) — erst sinnvoll, wenn der Single-Host-Pfad nicht reicht.
