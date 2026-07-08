# CLAUDE.md — Auftrag an Claude Code

Du arbeitest im Provisioning-Repo für eine **AI-Workstation** (Ryzen 7 9700X / RTX 4070 Ti 12 GB / 64 GB / Ubuntu 24.04, Board ASUS ROG Strix B850-F Gaming WiFi). Sie ist **gleichzeitig** Desktop für zwei Menschen (nico, sabine — KDE, Gaming/Civ 7, DaVinci Resolve Studio) **und** headless AI-/Agent-Server. Du führst den User durch das vollständige Setup.

**Disk-Topologie:** `split_os_data` ab Tag 0 — beide NVMe verbaut: **1 TB = OS** (`os` + `EFI`), **4 TB = `/data`**. Der frühere OS-Umzug (`docs/OS-SSD-MIGRATION.md`) ist damit obsolet. Details: `docs/DISK-LAYOUT.md`.

**Agent-Stack:** **Hermes (Nous Research) ersetzt OpenClaw**; KI-Arbeit läuft über **Subscription-CLIs** (Claude Code = Default, dazu Codex/Cursor/Gemini/Grok) — **kein API-Billing** (Ausnahme: Perplexity). Ollama macht Gratis-Aux-Tasks. Details: `docs/AGENT-STACK.md`. Hardware/Board-Eigenheiten: `docs/HARDWARE-B850F.md`.

**Sprache:** Deutsch. Knapp und konkret.

## Dein Job in einem Satz

Lies `PROGRESS.md`, identifiziere die nächste offene Phase, stelle dem User genau die Fragen, die du für diese Phase brauchst (eine nach der anderen, mit Erklärung wo der Wert herkommt), führe die zugehörigen Befehle aus, hake die Phase in `PROGRESS.md` ab.

## Wenn du gerade neu gestartet bist

1. Lies in dieser Reihenfolge:
   - `PROGRESS.md` (Was ist erledigt? Was ist als Nächstes dran?)
   - `docs/MIGRATION-RUNBOOK.md` (Master-Reihenfolge)
   - `docs/ARCHITECTURE.md` (zur Begründung — nicht zum Vorlesen)
   - `docs/TRUST-BOUNDARY.md` (was ist sensitiv)
2. Sag dem User in **2-3 Sätzen**: aktuelle Phase, nächster konkreter Schritt, was du dafür brauchst.
3. Stoppe und warte auf seine Antwort. Niemals mehr als eine Phase auf einmal.

## Was du fragen darfst (und wo der User es herbekommt)

Für jede dieser Variablen, frage NUR wenn die zugehörige Phase aktiv wird, nicht alle auf einmal:

| Wert | Wo ihn der User herbekommt |
|---|---|
| Vault-Passwort (frei wählbar) | merken oder in 1Password speichern |
| Tailscale Auth-Key (reusable, tag:ai-server) | https://login.tailscale.com/admin/settings/keys → "Generate auth key" → Reusable + Pre-approved + Tag `tag:ai-server` |
| Telegram Bot-Tokens (3) | https://t.me/BotFather → `/newbot` für jeden (NathanBot, LisaBot, SystemBot). Bot-Token Format: `123456789:AABBCCdd...` |
| Telegram Chat-IDs | An den Bot eine Nachricht schicken, dann `https://api.telegram.org/bot<TOKEN>/getUpdates` aufrufen, `chat.id` extrahieren |
| Discord Webhook-URLs | Discord-Server → Einstellungen → Integrationen → Webhooks → "Neuer Webhook" pro Channel (#ci-cd, #system-health, #n8n-errors) |
| GitHub PAT | https://github.com/settings/tokens/new?description=ai-server&scopes=repo,workflow,admin:org_hook,read:org → Format `ghp_...` |
| Domain | Beim DNS-Provider registriert; Subdomains `n8n-gw`, `portal`, `api`, `hooks` müssen auf Hetzner-IP zeigen |
| Cloudflare/DNS API-Token | Cloudflare-Dashboard → "My Profile" → "API Tokens" → "Edit zone DNS" für die Domain |
| n8n encryption key | **Aus R2D2:** `ssh clawd@192.168.1.12 'jq -r .encryptionKey /home/clawd/.n8n/config'` — exakt diesen Wert verwenden, sonst sind alle Credentials nach Migration unbrauchbar |
| restic Passwort (frei wählbar, MIN 32 Zeichen) | `openssl rand -base64 32` lokal generieren, in 1Password merken |
| rclone Drive Token | `rclone config` interaktiv lokal durchlaufen, dann `cat ~/.config/rclone/rclone.conf` |
| Abo-Logins der Coding-CLIs | **Kein API-Key!** Stattdessen als `agent` interaktiv: `claude login` (Claude Max), `codex login` (ChatGPT Plus/Pro privat), `cursor-agent login`, `gemini`, `grok login` (SuperGrok/X Premium+). Siehe `docs/AGENT-STACK.md` |
| Perplexity API-Key | Einzige erlaubte API-Abrechnung (Suche/Recherche). https://www.perplexity.ai/settings/api |

## Phasen-Reihenfolge (ENTSPRICHT MIGRATION-RUNBOOK)

Strikt eine nach der anderen, jede mit Verifikation bevor weiter:

| # | Phase | Hauptbefehl | User-Input am Anfang |
|---|---|---|---|
| 0 | OS + Disks vorbereitet | `sudo ./scripts/disk-prepare.sh` | Ubuntu **Desktop** liegt schon auf 1-TB (Erst-User `nico`). Skript setzt Labels (`os`/`EFI`), fstab→LABEL=, 4-TB→`data`/`/data`. Dann `./scripts/disk-layout-check.sh` grün. BIOS: `docs/HARDWARE-B850F.md` |
| 1 | Bootstrap | `./bootstrap.sh` | nichts |
| 2 | Secrets in Vault | `./scripts/secrets-init.sh` | alle Werte aus Tabelle oben |
| 3 | Foundation | `ansible-playbook playbooks/site.yml --ask-vault-pass --tags base,storage,users,slices` | nichts (legt auch `sabine` an) |
| 4 | NVIDIA (Desktop!) + Docker | `... --tags nvidia,docker` + reboot | Secure-Boot-Status klären (`docs/HARDWARE-B850F.md`) |
| 5 | Tailscale | `... --tags tailscale` + manuelle Route-Approval im Admin | Tailscale Admin Console offen |
| 6 | ACL pasten | (manuell) | `roles/06_tailscale/files/tailscale-acl.hujson` ins Admin-Console |
| 7 | Core Services | `... --tags ollama,surrealdb,postgres,n8n_private` | nichts (Modell-Pull dauert ~30min) |
| 8 | Monitoring + Runner + CLIs + Vault-MCP + Traefik | `... --tags monitoring,github_runner,cli,vault_mcp,traefik` | nichts |
| 9 | Desktop + Gaming + GPU-Arbiter | `... --tags desktop,gaming,gpu_arbiter` + reboot | nichts (KDE/Steam/Proton-GE) |
| 10 | Agent-Stack + Browser-Session | `... --tags agent_browser,agent_stack` | danach **Abo-Logins** als `agent` (claude/codex/cursor/gemini/grok login — KEINE API-Keys!) |
| 11 | R2D2-Migration | `ansible-playbook playbooks/migrate-r2d2.yml --ask-vault-pass` | R2D2 erreichbar, n8n auf R2D2 gestoppt |
| 12 | Hermes-Migration | `hermes claw migrate` (als `agent`) | OpenClaw-Workspace aus Phase 11 vorhanden |
| 13 | Hetzner Edge | `ansible-playbook playbooks/hetzner-edge.yml --ask-vault-pass` | DNS-Records aktiv |
| 14 | Restic + erstes Backup | `... --tags restic` | nichts |
| 15 | Verify | `ansible-playbook playbooks/verify.yml` | nichts |
| 16 | DaVinci Studio manuell | (manuell, siehe DAY-2-OPS / `roles/14_davinci_prep`) | DaVinci-Studio-Lizenz |

## Wie du arbeitest

- **Eine Phase, dann stop.** Niemals mehrere Phasen automatisch hintereinander. User muss zwischen Phasen Kontrolle haben.
- **Vor jedem destruktiven Befehl:** zeige den genauen Befehl, frage "ausführen? (j/n)". Idempotent oder reversibel? → kannst du direkt ausführen.
- **Vor `apt install`, `tailscale up`, `ansible-playbook` ohne `--check`:** zeige `--check --diff` zuerst, lass User den Diff abnehmen.
- **Nach jeder Phase:** verifiziere (passender Smoke-Test) → markiere in `PROGRESS.md` als done → fasse für User in 1 Satz zusammen.
- **Beim Hängen oder Fehler:** logs lesen, Hypothese formulieren, User fragen bevor du fix anwendest. Nicht raten.
- **Sekreten:** NIEMALS plain in Chat-Output schreiben. Auch nicht erste 4 Zeichen.

## Was du NICHT tun sollst

- Nicht ungefragt R2D2 anfassen — dort läuft HomeAssistant. Nur lesend.
- Nicht ungefragt Hetzner-Apps (Portal, API, Dokploy-bestehende) anfassen — Hetzner-Phase fügt nur n8n-edge hinzu.
- Nicht den n8n-encryption-key ändern, sobald migrate-r2d2 lief — das macht alle Credentials kaputt.
- Nicht das Vault-Passwort committen oder echoen.
- Nicht eigenmächtig ein Repo public machen.
- Bei "ich weiß nicht weiter": ehrlich sagen, nicht halluzinieren. Zeig mir den exakten Fehler-Output.

## Hilfreiche Quick-Lookups

```bash
# Wo bin ich?  (immer als erstes wenn unsicher)
cat PROGRESS.md
git log --oneline -5

# Was ist im Vault?
ansible-vault view inventory/group_vars/all/vault.yml --vault-password-file .vault-password | head -40

# n8n läuft?
curl -sf http://$(tailscale ip -4):5678/healthz && echo OK

# Ollama läuft + welche Modelle?
curl -s http://localhost:11434/api/tags | jq -r '.models[].name'

# Docker-Übersicht
docker ps --format 'table {{.Names}}\t{{.Status}}'

# Tailscale-Topologie
tailscale status
```

## Beziehung zu R2D2

R2D2 (clawd@192.168.1.12 / 100.64.0.20) ist die Migrations-Quelle. Sie bleibt aktiv für HomeAssistant + Matter. Nicht herunterfahren. Migration ist Cold-Move (n8n + OpenClaw vorher dort gestoppt).

## Beziehung zu Hetzner (etrox / 100.64.0.10)

Hetzner ist Public-Edge mit Dokploy. Bestehende Apps (Portal, API) bleiben unangetastet. Wir fügen NUR `n8n-edge` als neuen Dokploy-Service hinzu, plus UFW-Hardening.
