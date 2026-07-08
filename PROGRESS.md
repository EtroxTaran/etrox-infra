# PROGRESS

Phasen-Tracker für die Provisionierung. Claude Code aktualisiert diese Datei nach jeder abgeschlossenen Phase.

**Hostname dieses Systems:** _(beim ersten Run setzen)_
**Erster Lauf gestartet:** _(beim ersten Run setzen)_

## Phasen

- [ ] **0 — OS + Disks vorbereitet**
  Ubuntu **Desktop** 24.04 LTS liegt bereits auf der **1-TB-NVMe** (Erst-User `nico`, uid 1000); 4-TB-NVMe ist leer. Da der Ubuntu-Installer UUID-fstab + keine Labels setzt: **`sudo ./scripts/disk-prepare.sh`** ausführen (Root/EFI → LABEL=os/EFI, fstab → LABEL=, 4-TB → ext4 LABEL=data nach `/data`). BIOS nach `docs/HARDWARE-B850F.md` (Above 4G, ReBAR, IOMMU; Secure Boot empfohlen AUS). Danach `scripts/disk-layout-check.sh` grün.

- [ ] **1 — Bootstrap**
  `./bootstrap.sh` durchgelaufen. Installiert: git, gh, yq, node LTS, claude-code, ansible-core, tailscale.

- [ ] **2 — Secrets in Vault**
  `./scripts/secrets-init.sh` durchgelaufen. `inventory/group_vars/all/vault.yml` ist verschlüsselt. `validate-vault.sh` grün.

- [ ] **3 — Foundation (base + storage + users + slices)**
  `apt upgrade`, ufw aktiv, swap, B850-F-NIC/Sensors/Firmware. **8 User** mit fixen UIDs (inkl. `sabine` 1007), cgroup-Slices (Menschen unbegrenzt). `/data/{games,agent}` angelegt.

- [ ] **4 — NVIDIA (Desktop-Treiber!) + Docker (mit Reboot)**
  `nvidia-driver-570` (kein `-server`), Vulkan + 32-bit, `nvidia-smi` + `vulkaninfo` ok, Secure-Boot/MOK geklärt. Docker mit nvidia-runtime, Netzwerke existieren.

- [ ] **5 — Tailscale-Join**
  AI-Server im Tailnet, Subnet-Routes (LAN + Docker) im Admin approved. Tailscale-IP in `inventory/host_vars/ai-server.yml` persistiert.

- [ ] **6 — ACL gepasted**
  Inhalt von `roles/06_tailscale/files/tailscale-acl.hujson` im Tailscale-Admin-Console aktiv. Tags `tag:ai-server`, `tag:public-edge`, `tag:home-control` korrekt vergeben.

- [ ] **7 — Core Services (Ollama, SurrealDB, Postgres, n8n-private)**
  Ollama lädt Modelle (Qwen3 14B, Gemma3 12B, Llama3.2-Vision), n8n-private auf Tailscale-IP erreichbar, SurrealDB healthy.

- [ ] **8 — Tooling (Monitoring, GitHub-Runner, CLIs, Vault-MCP, Traefik)**
  Grafana erreichbar, **ephemeral** Runner registriert (eigene Group), Coding-CLIs nutzbar. Siehe `docs/CI-LOCAL.md`.

- [ ] **9 — Desktop + Gaming + GPU-Arbiter (mit Reboot)**
  KDE Plasma + SDDM (Wayland default), beide Logins (`nico`, `sabine`) erscheinen. Steam (.deb) + Proton-GE. `gpu-heavy on/off` schaltet Ollama. Siehe `docs/GAMING.md`.

- [ ] **10 — Agent-Stack + Browser-Session**
  Hermes installiert, isolierte Browser-Session (Xvfb :99 + Chrome/CDP) läuft. **Abo-Logins** als `agent` durchgeführt (claude/codex/cursor/gemini/grok — Status zeigt „subscription", KEINE API-Keys). Siehe `docs/AGENT-STACK.md`, `docs/AGENT-BROWSER.md`.

- [ ] **11 — R2D2-Migration**
  Pre-Snapshot in `/data/backups/r2d2-archive/`, OpenClaw-Workspace + 9 Vaults (Ownership: Sabine-Vaults → `sabine`) + n8n-Workflows+Credentials migriert, Pfade umgeschrieben.

- [ ] **12 — Hermes-Migration**
  `hermes claw migrate` (als `agent`) übernimmt die Fleet (Nathan/Lisa/Riker/Spock/Dax). Hermes-Gateway läuft, Ollama als Aux-Provider, Perplexity-MCP erreichbar.

- [ ] **13 — Hetzner Edge (n8n-edge)**
  `n8n-edge` als Dokploy-App auf Hetzner deployed, DNS für `n8n-gw.<domain>` aufgelöst, Telegram-Webhook gesetzt.

- [ ] **14 — Backups (restic + rclone)**
  restic-Repo initialisiert, erstes Backup durch (inkl. `/data/agent/hermes`), Restore-Smoke grün, systemd-Timer aktiv.

- [ ] **15 — Verify (E2E)**
  `playbooks/verify.yml` komplett grün. ACL-Selbsttest (Hetzner→AI-Server n8n) ok.

- [ ] **16 — DaVinci Resolve Studio (manuell)**
  Studio installiert (GLib-Fix greift), Lizenz aktiviert, Python-API getestet. H.264/H.265-Delivery via `resolve-transcode` (ffmpeg NVENC).

## Bekannte offene Fragen / Entscheidungen

(Hier trägt Claude Code Punkte ein, die der User noch beantworten muss, bevor weitergemacht werden kann.)

- _(noch keine)_

## Letzte Verifikation

```
nicht ausgeführt
```

(Hier trägt Claude die Ausgabe von `./scripts/post-install-check.sh` nach jeder größeren Phase ein.)
