# Migration Runbook — R2D2 → AI-Server

End-to-End Schritt-für-Schritt. Jeder Block hat einen Rollback-Pfad.

> ℹ️ **Stand Juni 2026 (Workstation-Umbau):** Die maßgebliche Phasenliste steht jetzt in
> [`../CLAUDE.md`](../CLAUDE.md) / [`../PROGRESS.md`](../PROGRESS.md). Neu seit diesem Runbook:
> direkt `split_os_data` (1 TB OS + 4 TB data, kein OS-Umzug mehr), **NVIDIA-Desktop-Treiber**,
> KDE-Desktop + Gaming ([`GAMING.md`](GAMING.md)), GPU-Arbiter, **Hermes statt OpenClaw** +
> Subscription-CLIs ([`AGENT-STACK.md`](AGENT-STACK.md)), isolierte Agent-Browser-Session
> ([`AGENT-BROWSER.md`](AGENT-BROWSER.md)). Der R2D2-Daten-Move unten gilt unverändert; danach
> `hermes claw migrate` für die Fleet-Übernahme.

## Voraussetzungen

- AI-Server hat Ubuntu 24.04 LTS (**Desktop**) frisch installiert
- Du hast SSH-Zugang als `nico` zum AI-Server (LAN oder Direktzugang)
- R2D2 ist eingeschaltet, erreichbar via 192.168.1.12 (LAN) und 100.64.0.20 (Tailscale)
- Hetzner-VPS läuft, Dokploy aktiv, Tailnet als `etrox` (100.64.0.10)
- Du hast einen Tailscale-Auth-Key (reusable, mit Tag `ai-server`)
- GitHub PAT mit `repo`, `workflow`, `admin:org_hook` Scopes
- Telegram Bot-Tokens + Chat-IDs zur Hand

---

## §1 — Hardware & OS Setup (manuell)

Aktuelle Topologie: **`single_disk_4tb`** — Ubuntu liegt mit auf der 4 TB, in einer eigenen Partition. Sobald die dedizierte OS-SSD physisch verfügbar ist, siehe [`OS-SSD-MIGRATION.md`](OS-SSD-MIGRATION.md) für den Umzug auf `split_os_data`.

Layout-Details und Begründung: [`DISK-LAYOUT.md`](DISK-LAYOUT.md).

### 1.1 Ubuntu Installation — Custom Storage Layout

Ubuntu Server 24.04 LTS Installer booten. Bei "Storage configuration" **"Custom storage layout"** wählen.

Auf `/dev/nvme0n1` (4 TB Samsung 9100 Pro) **drei** Partitionen anlegen — ältere Inhalte werden überschrieben:

| Slot | Größe   | Format                  | Label  | Mount       |
|------|---------|-------------------------|--------|-------------|
| 1    | 1 GiB   | FAT32 (EFI)             | `EFI`  | `/boot/efi` |
| 2    | 150 GiB | ext4                    | `os`   | `/`         |
| 3    | Rest    | ext4                    | `data` | `/data`     |

**Wichtig:** Im Installer für jede ext4-Partition unter "Format" → "ext4" das Feld **Label** ausfüllen (`os` bzw. `data`). Der Installer schreibt fstab dann automatisch mit `LABEL=…` statt UUID — und das ist der ganze Trick, der den späteren OS-Umzug schmerzfrei macht.

Falls der grafische Installer kein Label-Feld anbietet, später nachholen (siehe §1.3 unten).

Kein LUKS vorerst (vereinfacht den späteren Klon-Prozess auf die OS-SSD).

### 1.2 Erste Anmeldung
```bash
ssh nico@<lan-ip>
sudo apt update && sudo apt install -y git
```

### 1.3 Layout verifizieren (und ggf. Labels nachziehen)

```bash
lsblk -o NAME,SIZE,LABEL,MOUNTPOINT
findmnt /
findmnt /data
findmnt /boot/efi
```

Erwartung: `/` auf `…p2` mit Label `os`, `/data` auf `…p3` mit Label `data`, `/boot/efi` auf `…p1` mit Label `EFI`.

Falls Labels fehlen (Installer hat sie nicht gesetzt):
```bash
# Beispiel — die korrekten Devices aus lsblk übernehmen
sudo e2label /dev/nvme0n1p2 os
sudo e2label /dev/nvme0n1p3 data
sudo fatlabel /dev/nvme0n1p1 EFI
```

Falls `/etc/fstab` noch UUID-Einträge enthält, auf Labels umstellen:
```bash
sudo cp /etc/fstab /etc/fstab.bak
sudo sed -i \
    -e "s|^UUID=$(blkid -s UUID -o value /dev/nvme0n1p2).*/ |LABEL=os / |" \
    -e "s|^UUID=$(blkid -s UUID -o value /dev/nvme0n1p3).*/data |LABEL=data /data |" \
    -e "s|^UUID=$(blkid -s UUID -o value /dev/nvme0n1p1).*/boot/efi |LABEL=EFI /boot/efi |" \
    /etc/fstab
sudo mount -a    # darf keinen Fehler werfen
grep -E '^LABEL=' /etc/fstab
```

### 1.4 Repo klonen + Bootstrap
```bash
# Optional: scripts/disk-layout-check.sh läuft auch ohne Repo,
# wenn du die Datei manuell kopierst. Ansonsten erst nach dem Klon:
git clone https://github.com/<dein-org>/ai-server-provisioning ~/ai-server-provisioning
cd ~/ai-server-provisioning
./scripts/disk-layout-check.sh    # muss grün sein
./bootstrap.sh
```

**Rollback:** Disk-Layout neu aufsetzen ist destruktiv und bedeutet OS-Neuinstallation. Da §1 vor jedem Service-Setup läuft, ist der "Rollback" einfach Ubuntu-Installer nochmal.

---

## §2 — Secrets initialisieren

```bash
./scripts/secrets-init.sh
```

Trage ein:
- Vault-Passwort (merken!)
- Tailscale Auth-Key
- Telegram-Bot-Tokens, Chat-IDs
- GitHub PAT, Org-Name
- Domain, DNS-Token
- restic-Passwort, rclone-Config
- **WICHTIG:** `vault_n8n_encryption_key` = Wert aus R2D2 `/home/clawd/.n8n/config:.encryptionKey`

R2D2-Wert holen:
```bash
ssh clawd@192.168.1.12 'jq -r .encryptionKey /home/clawd/.n8n/config'
```

**Rollback:** `rm inventory/group_vars/all/vault.yml .vault-password && ./scripts/secrets-init.sh` neu.

---

## §3 — Provisioning Phase 1 (Foundation)

```bash
ansible-playbook playbooks/site.yml \
    --ask-vault-pass \
    --tags base,storage,users,slices \
    --check --diff           # Trockenlauf
ansible-playbook playbooks/site.yml --ask-vault-pass --tags base,storage,users,slices
```

Verifikation:
```bash
id nico agent n8n devrunner ollama davinci surreal sabine   # alle existieren
findmnt /data                                            # gemountet
systemctl is-active user-1004.slice                       # ollama-slice aktiv
```

---

## §4 — NVIDIA + Docker (Reboot)

```bash
ansible-playbook playbooks/site.yml --ask-vault-pass --tags nvidia,docker
sudo reboot
```

Nach Reboot:
```bash
nvidia-smi                                                # GPU + Driver-Version
docker run --rm --gpus all nvidia/cuda:12.6.0-base-ubuntu24.04 nvidia-smi
```

**Rollback:** `sudo apt purge 'nvidia-*' 'cuda-*' && sudo reboot` (extrem destruktiv).

---

## §5 — Tailscale Subnet-Router

```bash
ansible-playbook playbooks/site.yml --ask-vault-pass --tags tailscale
```

Im Tailscale-Admin:
1. Approve advertised routes (192.168.1.0/24, Docker-Subnet)
2. ACL aus `roles/06_tailscale/files/tailscale-acl.json` ins Admin-Console übernehmen
3. Tag `tag:ai-server` und `tag:public-edge` und `tag:home-control` korrekt zugewiesen

Verifikation:
```bash
tailscale status                                          # alle 3 Hosts online
tailscale ping etrox                                      # Hetzner reachable
```

---

## §6 — Core Services

```bash
ansible-playbook playbooks/site.yml --ask-vault-pass \
    --tags ollama,surrealdb,postgres,n8n_private
```

Lange Modell-Pulls (~30 min für Qwen3 14B). Parallel weitermachen.

---

## §7 — Monitoring + Runner + CLI Tools

```bash
ansible-playbook playbooks/site.yml --ask-vault-pass \
    --tags monitoring,github_runner,cli,vault_mcp,traefik
```

Grafana: `http://<tailscale-ip>:3000` — Login: admin / `vault_grafana_admin_password`

---

## §8 — R2D2 Migration (Cold-Move)

### 8.0 Pre-Flight (R2D2 stoppen)
```bash
ssh clawd@192.168.1.12 'pm2 stop all 2>/dev/null; pkill -f "n8n start" || true'
ssh clawd@192.168.1.12 'pgrep -af n8n || echo "n8n stopped"'
```

### 8.1 Discovery
```bash
ssh clawd@192.168.1.12 'bash -s' < scripts/r2d2-discovery.sh \
    > inventory/r2d2-snapshot.json
jq '.openclaw, .vaults, .clis' inventory/r2d2-snapshot.json
```

### 8.2 Migration
```bash
ansible-playbook playbooks/migrate-r2d2.yml --ask-vault-pass
# Optional CLI-Configs (sicherheitssensitiv):
ansible-playbook playbooks/migrate-r2d2.yml --ask-vault-pass \
    --extra-vars 'migrate_cli_configs=true'
```

### 8.3 Verifikation
```bash
ls /home/agent/.openclaw/workspace/AGENTS.md            # vorhanden
ls /data/vaults/research-core/.git                       # alle 9 Vaults
docker exec n8n-private n8n list:credentials            # zeigt importierte Creds
diff -r /home/clawd/vaults/research-core/ /data/vaults/research-core/  # leer (auf R2D2 prüfen)
```

**Rollback:** Migration ist additiv. Bei Problemen: `rm -rf /home/agent/.openclaw/workspace/* /data/vaults/*` und neu ausführen. R2D2 bleibt unangetastet.

---

## §9 — Hetzner Edge

```bash
ansible-playbook playbooks/hetzner-edge.yml --ask-vault-pass
```

Manuell:
1. DNS: `n8n-gw.<domain>` → Hetzner-Public-IP
2. Bot-Webhook setzen:
   ```bash
   for BOT in NATHAN LISA SYSTEM; do
     TOKEN=$(yq ".vault_telegram.${BOT,,}_bot_token" inventory/group_vars/all/vault.yml)
     curl -s "https://api.telegram.org/bot${TOKEN}/setWebhook?url=https://n8n-gw.<domain>/webhook/telegram-${BOT,,}"
   done
   ```

---

## §10 — Verify

```bash
ansible-playbook playbooks/verify.yml
./scripts/post-install-check.sh
```

Manuell:
- Telegram an SystemBot: `/ping` → Antwort < 10s
- n8n öffnen: `http://<tailscale-ip>:5678` → Workflows + Credentials sichtbar
- AI-Portal Plugin lokal testen via `tailscale ping etrox` und HTTP-Call

---

## §11 — DaVinci Resolve (manuell, Lizenz)

Siehe [`DAY-2-OPERATIONS.md`](DAY-2-OPERATIONS.md#davinci-resolve-installation).

---

## §12 — R2D2 finalisieren

R2D2 NICHT abschalten — HomeAssistant + Matter laufen weiter. Aber:
1. n8n und OpenClaw deaktivieren (waren eh schon gestoppt)
2. Optional: GitHub-Self-Hosted-Runner auf R2D2 deregistrieren
   ```bash
   ssh clawd@192.168.1.12 'cd actions-runner && ./config.sh remove --token <token>'
   ```
3. R2D2 als "home-control only" im Tailscale-Admin taggen (sollte schon so sein)

---

## Notfall-Cheatsheet

| Problem | Quickfix |
|---|---|
| Tailscale tot | `sudo systemctl restart tailscaled` |
| Ollama hängt | `sudo systemctl restart ollama` |
| GPU verschwunden | `sudo rmmod nvidia_uvm nvidia && sudo modprobe nvidia_uvm` |
| n8n credentials nicht entschlüsselbar | encryption-key in vault.yml falsch — verbessern und n8n-private restart |
| Disk voll | `restic forget --keep-daily 3 && restic prune` |
| Webhook von außen kommt nicht an | UFW prüfen + Tailscale-ACL prüfen + n8n-edge logs |
