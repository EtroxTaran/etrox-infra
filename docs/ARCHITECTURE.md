# Architecture

Die Gesamtarchitektur folgt dem Masterplan v2 + Hetzner-Addendum. Diese Datei
fasst die Implementierung in diesem Repo zusammen — für die Designentscheidungen
selbst siehe die Quelldokumente in `~/Downloads/`:

- `AI-Server-Master-Architektur-v2.md`
- `AI-Server-Addendum-Hetzner-Notifications.md`
- `KI-Workstation Setup ...md`

## Drei-Zonen-Topologie

```
                        INTERNET
                            │
                            ▼
   ┌──────────────────────────────────────────────────┐
   │  HETZNER VPS  ·  hostname: etrox  ·  100.64.0.10
   │  Tags: tag:public-edge
   │
   │  Public:        80, 443 (Traefik via Dokploy)
   │  Tailscale-only: 3000 (Dokploy admin)
   │
   │  Apps:  Nexus Portal · Portal API · n8n-edge ·
   │         Better Auth · SurrealDB Plugin-NS · Miniflux
   └──────────────────┬───────────────────────────────┘
                      │ Tailscale WireGuard
                      │ example-net.ts.net
                      ▼
   ┌──────────────────────────────────────────────────┐
   │  AI-WORKSTATION  ·  hostname: ai-server  ·  Tag: tag:ai-server
   │
   │  Hardware: Ryzen 9700X · RTX 4070 Ti 12GB · 64 GB · 1 TB OS + 4 TB data NVMe
   │  Board: ASUS ROG Strix B850-F Gaming WiFi (AM5)
   │
   │  Desktop (am Monitor, KDE Plasma / Wayland):
   │    nico           — Login: Desktop, Civ 7, DaVinci, Admin/Dev
   │    sabine         — Login: Desktop, Civ 7, DaVinci, eigene Vaults
   │
   │  Services (headless, Tailscale-only):
   │    Hermes (Nous Research) + Personas  (agent user)  ← ersetzt OpenClaw
   │      + ISOLIERTE Browser-Session (Xvfb :99 + Chrome/CDP, VNC)
   │    Subscription-CLIs (claude/codex/cursor/gemini/grok) als Execution-Layer
   │    Ollama  (ollama user, GPU; weicht bei gpu-heavy.target)
   │    n8n-private + Postgres  (n8n user)
   │    SurrealDB  (surreal user)
   │    GitHub Self-Hosted Runner — ephemeral  (devrunner user)
   │    DaVinci Resolve Studio  (Desktop-App + davinci Service-User)
   │    Traefik (intern, ACME via DNS-01)
   │    Monitoring: Prometheus, Grafana, Loki, nvidia-exporter
   │  GPU-Arbiter: gpu-heavy.target (Conflicts=ollama) — VRAM-Sharing 12 GB
   │  Storage: /data/{vaults,projects,builds,models,davinci,games,agent,backups}
   │  Backups: restic → /data/backups/local + rclone → Google Drive
   └──────────────────┬───────────────────────────────┘
                      │ Tailscale (existing)
                      ▼
   ┌──────────────────────────────────────────────────┐
   │  R2D2 (BLEIBT)  ·  hostname: r2d2  ·  100.64.0.20
   │  Tag: tag:home-control
   │
   │  - HomeAssistant + Matter-Server (Smart-Home Hub)
   │  - Bleibt für IoT, kein KI-Workload mehr
   │  - Migrations-Quelle für /home/clawd/{vaults,.openclaw,.n8n}
   └──────────────────────────────────────────────────┘
```

## Trust-Boundary kurz

- **Lokal nur (AI-Server):** Vaults, OAuth-Tokens (Abo-CLIs!), Agent-Memory, Ollama, n8n-Editor
- **Public (Hetzner):** Portal UI/API, n8n-Webhook-Endpoints, Public-Health, nicht-sensitive Plugin-Daten
- **R2D2 (unverändert):** Smart-Home, Matter-Stick
- **Menschen vs. Agenten:** `nico`/`sabine` haben sichtbare KDE-Sessions; der `agent`-User
  läuft headless in eigener Xvfb-Session mit eigenem Chrome-Profil — keine Vermischung.
  Sabines high-tier Vaults (`sabine-jobs-design`, `sabine-lisa`) gehören `sabine`, nicht `agent`.

Details: [`TRUST-BOUNDARY.md`](TRUST-BOUNDARY.md).

## User-Isolation via systemd-Slices

7 dedizierte Linux-User mit fixen UIDs (1000–1006). Jeder bekommt eine
cgroup-v2 Slice mit eigenen CPU/RAM-Limits. Damit blockiert ein npm-Build
unter `devrunner` nie den `ollama`-Service.

| User | UID | CPU | Mem | Zweck |
|---|---|---|---|---|
| nico | 1000 | – | – | Admin / SSH / **Desktop (Mensch)** |
| sabine | 1007 | – | – | **Desktop (Mensch)** — Gaming + DaVinci |
| agent | 1001 | 400% | 20G | Hermes + Agents + Browser-Session |
| n8n | 1002 | 200% | 6G | n8n-private |
| devrunner | 1003 | 800% | 24G | GitHub Runner (ephemeral), npm |
| ollama | 1004 | 200% | 16G | Ollama LLM (GPU) |
| davinci | 1005 | 400% | 12G | Resolve Render/API (Service) |
| surreal | 1006 | 200% | 8G | SurrealDB |

Menschliche Desktop-User (`nico`, `sabine`) bleiben bewusst **ohne** cgroup-Limit, damit
die interaktive Oberfläche inkl. Gaming/DaVinci nie gedrosselt wird.

## Storage-Layout

Zwei logische Filesystems mit stabilen Labels (`os`, `data`), unabhängig
davon, ob sie auf einer oder zwei physischen Platten liegen. Details in
[`DISK-LAYOUT.md`](DISK-LAYOUT.md).

- **`os` (Label):** OS, Docker images, `/opt/{n8n,ollama,surreal}`, Swap
- **`data` (Label):** `/data/{projects,builds,vaults,models,davinci,backups}`

**Topologie heute (`single_disk_4tb`):** beide Partitionen auf der 9100 Pro
4 TB (`os` ~150 GiB, `data` ~3.85 TiB). Genug, um sofort produktiv zu starten.

**Topologie Ziel (`split_os_data`):** OS auf dedizierter NVMe-SSD
(256–500 GB), `/data` weiterhin auf der 9100 Pro. Build-Hot-Set vom OS
getrennt, PCIe-5-Bandbreite für DaVinci-Scratch und Modelle reserviert.
Umzug per [`OS-SSD-MIGRATION.md`](OS-SSD-MIGRATION.md) — Service-Downtime
~20 min, kein Eingriff in fstab oder Service-Configs nötig (Label-stabil).

## Datenfluss-Beispiele

**Telegram-Nachricht von Nico:**
```
Telegram → api.telegram.org → n8n-edge (Hetzner public)
       → POST via Tailscale → n8n-private (AI-Server)
       → Whitelist Check → Nathan (Hermes persona, agent user)
       → Hermes delegiert: Ollama (Aux) oder Claude Code (Abo) → Antwort → Telegram-Reply
```

**Code-Änderung im AI-Portal:**
```
Nico/Nathan → GitHub Issue/PR → GitHub Actions
   → Self-Hosted Runner (devrunner @ AI-Server)
   → Tests + AI-Review (Claude Code CLI mit n8n-MCP)
   → Build + Push → ghcr.io
   → Webhook → Dokploy (Hetzner) → Deploy → Production
   → Status-Embed → Discord #ci-cd-logs
```

**Vault-Write (sicher):**
```
Agent intent → MCP-Server → vaultctl
   → Tier-Check (high-tier blockiert)
   → Frontmatter validation
   → git commit (audit trail in /data/vaults/<v>/.git)
   → optional SurrealDB index update
```
