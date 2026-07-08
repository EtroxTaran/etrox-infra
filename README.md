# AI-Workstation Provisioning

Automatisiertes Setup für die AI-Workstation (Ryzen 7 9700X / RTX 4070 Ti 12 GB / 64 GB / 1 TB OS-NVMe + 4 TB data-NVMe / Board ASUS ROG Strix B850-F / Ubuntu 24.04 LTS). **Dual-Use**: KDE-Desktop für zwei Menschen (nico, sabine — Gaming/Civ 7, DaVinci Resolve Studio) **und** headless AI-/Agent-Server.

**Architektur:** lokal AI-Workstation (private), Hetzner+Dokploy (public edge), R2D2 (smart-home, bleibt). Verbindung über Tailscale. Agent-Layer: **Hermes** (ersetzt OpenClaw) + Subscription-CLIs. Siehe [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), [`docs/AGENT-STACK.md`](docs/AGENT-STACK.md), [`docs/TRUST-BOUNDARY.md`](docs/TRUST-BOUNDARY.md).

**Disk-Layout:** `split_os_data` ab Tag 0 — **1 TB = OS** (`os` + `EFI`), **4 TB = `/data`** (Modelle, Vaults, DaVinci, Games, Agent-State, Backups). Mount-Strategie (LABEL-basiert): [`docs/DISK-LAYOUT.md`](docs/DISK-LAYOUT.md). Board-Eigenheiten: [`docs/HARDWARE-B850F.md`](docs/HARDWARE-B850F.md).

## Quickstart (auf dem neuen AI-Server)

Drei Phasen — jede ein Block.

### A. Preflight (vor dem Repo-Clone, weil Repo privat)

Auf dem installierten Ubuntu 24.04 als Erst-User `nico`:

```bash
sudo apt update && sudo apt install -y git curl

# GitHub CLI installieren + interaktiv anmelden
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list
sudo apt update && sudo apt install -y gh
gh auth login --hostname github.com --git-protocol https --web \
  --scopes "repo,workflow,admin:org_hook,read:org"

# Repo klonen
gh repo clone EtroxTaran/ai-server-provisioning ~/ai-server-provisioning
cd ~/ai-server-provisioning
```

(Alternativ: alles obige steht auch als `preflight.sh` im Repo. Wenn du die Datei
auf anderem Weg auf den Server bringst — USB, scp, public Gist — reicht
`./preflight.sh`.)

### B. Disk vorbereiten (Ubuntu ist schon installiert)

Der Ubuntu-Installer setzt UUID-fstab und keine Labels. Einmalig auf das LABEL-Layout bringen
und die leere 4-TB-NVMe als `/data` einrichten:

```bash
sudo ./scripts/disk-prepare.sh    # relabelt OS/EFI, fstab→LABEL=, 4 TB → /data
./scripts/disk-layout-check.sh    # muss grün sein
```

### C. Bootstrap (alles weitere automatisch)

```bash
./bootstrap.sh
```

Installiert: Node LTS, Claude Code CLI, Ansible-core, Tailscale, alle Ansible-Collections.

### D. Claude Code übernimmt

```bash
claude login          # einmalig OAuth
claude                # session in diesem Verzeichnis starten
```

Sobald die Session steht, sag einfach:

> _Los — fang mit der nächsten offenen Phase an._

Claude Code liest automatisch [`CLAUDE.md`](CLAUDE.md) (Auftrag) und [`PROGRESS.md`](PROGRESS.md) (wo wir stehen), fragt dich nach allen Inputs, die für die nächste Phase fehlen (mit Link wo du den Wert herbekommst), führt die Befehle aus, hakt die Phase ab, und stoppt vor der nächsten zur Bestätigung.

## Inhalt

| Pfad | Zweck |
|---|---|
| [`CLAUDE.md`](CLAUDE.md) | Auftrag an Claude Code (auto-geladen beim `claude`-Start) |
| [`PROGRESS.md`](PROGRESS.md) | Phasen-Tracker — was ist fertig, was kommt als nächstes |
| [`preflight.sh`](preflight.sh) | Optional: alles vor dem Repo-Clone (gh install + auth + clone) |
| [`bootstrap.sh`](bootstrap.sh) | Phase 1 — installiert node, claude-code, ansible, tailscale, gh, yq |
| [`playbooks/site.yml`](playbooks/site.yml) | Volles Server-Setup |
| [`playbooks/migrate-r2d2.yml`](playbooks/migrate-r2d2.yml) | Datenmigration von R2D2 |
| [`playbooks/hetzner-edge.yml`](playbooks/hetzner-edge.yml) | n8n-Edge auf Hetzner |
| [`playbooks/update.yml`](playbooks/update.yml) | Idempotente Re-runs |
| [`playbooks/verify.yml`](playbooks/verify.yml) | Health-Checks |
| [`scripts/r2d2-discovery.sh`](scripts/r2d2-discovery.sh) | R2D2 inventarisieren (read-only) |
| [`scripts/secrets-init.sh`](scripts/secrets-init.sh) | Ansible-Vault interaktiv anlegen |
| [`scripts/disk-prepare.sh`](scripts/disk-prepare.sh) | Phase 0: bereits installiertes Ubuntu auf LABEL-Layout bringen + 4 TB als `/data` |
| [`scripts/disk-layout-check.sh`](scripts/disk-layout-check.sh) | Pre-Flight: Labels + Mounts entsprechen `docs/DISK-LAYOUT.md` |
| [`docs/AGENT-STACK.md`](docs/AGENT-STACK.md) | Hermes + Subscription-CLIs (kein API-Billing) |
| [`docs/AGENT-BROWSER.md`](docs/AGENT-BROWSER.md) | Isolierte Agent-Browser-Session (Xvfb/CDP/VNC) |
| [`docs/GAMING.md`](docs/GAMING.md) · [`docs/HARDWARE-B850F.md`](docs/HARDWARE-B850F.md) | Steam/Proton/Civ 7 · Board/BIOS/NIC/NVIDIA |
| [`docs/CI-LOCAL.md`](docs/CI-LOCAL.md) | Self-hosted Runner + Claude Code statt GitHub-Actions |
| [`docs/`](docs/) | Architektur, Trust-Boundary, Runbooks |

## Phasen-Roadmap

Vollständige Phasenliste in [`CLAUDE.md`](CLAUDE.md) / [`PROGRESS.md`](PROGRESS.md). Kurzfassung:

1. Bootstrap (15 min)
2. Base + Storage + Users (+sabine) + Slices (20 min)
3. NVIDIA **Desktop-Treiber** + Docker (20 min, reboot)
4. Tailscale-Join + ACL (15 min)
5. Core Services: Ollama, SurrealDB, Postgres, n8n-private (30 min)
6. Monitoring + ephemeral GitHub-Runner + CLIs + Vault-MCP (20 min)
7. **Desktop (KDE) + Gaming (Steam/Proton-GE) + GPU-Arbiter** (20 min, reboot)
8. **Agent-Stack (Hermes) + isolierte Browser-Session** + Abo-CLI-Logins (20 min)
9. R2D2-Migration + `hermes claw migrate` (40 min)
10. Hetzner Edge (20 min)
11. Verify + erstes Backup (20 min)
12. DaVinci Resolve Studio (manuell, Lizenz)

## Sicherheit

- Secrets liegen in `inventory/group_vars/all/vault.yml` (ansible-vault encrypted, NIE committen unencrypted)
- `.vault-password` ist gitignored
- Tailscale-only für n8n-Editor, Ollama, Hermes/Agent, DaVinci-API, Dokploy-Admin
- **Subscription statt API**: Coding-CLIs laufen per OAuth-Abo (kein `*_API_KEY` im agent-Kontext); einzige API-Ausnahme ist Perplexity. Siehe [`docs/AGENT-STACK.md`](docs/AGENT-STACK.md)
- Menschliche Desktop-Sessions (nico/sabine) sind vom headless `agent`-Browser isoliert
- R2D2 wird im Inventory als read-only behandelt — Migration fasst keine R2D2-Configs an

## Lizenz

Privat. Nicht öffentlich teilen ohne Anonymisierung der Hostnames/IPs.
