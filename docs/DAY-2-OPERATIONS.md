# Day-2 Operations

> ℹ️ **Workstation-Ergänzungen (Juni 2026):**
> - GPU teilen (12 GB): vor DaVinci-Render/Civ 7 `gpu-heavy on` (stoppt Ollama, gibt VRAM frei),
>   danach `gpu-heavy off`. Oder `gpu-heavy run -- <cmd>`. Details: [`GAMING.md`](GAMING.md).
> - H.264/H.265-Delivery aus DaVinci: extern via `resolve-transcode <in> h265` (ffmpeg NVENC),
>   weil Resolve das auf Linux nicht selbst rendert.
> - Agent-Layer ist **Hermes** ([`AGENT-STACK.md`](AGENT-STACK.md)); KI-CLIs laufen auf Abo
>   (kein API-Key im agent-Kontext). Browser-Session: [`AGENT-BROWSER.md`](AGENT-BROWSER.md).

## Routine-Wartung

### Wöchentliches Update
```bash
cd ~/ai-server-provisioning
git pull
ansible-playbook playbooks/update.yml --ask-vault-pass
ansible-playbook playbooks/verify.yml
```

### Modell-Updates
```bash
sudo -u ollama ollama pull qwen3:14b
sudo -u ollama ollama pull gemma3:12b
```

### Docker-Image-Updates
```bash
cd /opt/n8n && docker compose pull && docker compose up -d
cd /opt/monitoring && docker compose pull && docker compose up -d
```

## Backup-Operations

### Backup-Status prüfen
```bash
sudo restic -r /data/backups/local --password-file /etc/restic/password snapshots
```

### Manuelles Off-Site-Backup
```bash
sudo /usr/local/sbin/restic-backup
sudo rclone sync /data/backups/local gdrive:ai-server-backups/
```

### Restore eines einzelnen Vaults
```bash
sudo restic -r /data/backups/local --password-file /etc/restic/password \
    restore latest --target /tmp/restore --include /data/vaults/research-core
```

### Disaster-Recovery
1. Neuer Server, frisches Ubuntu 24.04
2. `git clone` dieses Repo, `bootstrap.sh`, `secrets-init.sh` (mit altem restic-Passwort!)
3. `ansible-playbook playbooks/site.yml` — bis Role 15
4. Statt Migration aus R2D2: Restore aus Off-Site:
   ```bash
   rclone sync gdrive:ai-server-backups/ /data/backups/local/
   restic restore latest --target /
   ```
5. n8n + Postgres neu starten — Daten sind im restic-Backup

## DaVinci Resolve Installation

DaVinci kann nicht via Ansible installiert werden (Lizenz, GUI-Wizard).

```bash
# 1. Studio Edition runterladen (manuell, https://www.blackmagicdesign.com/)
sudo apt install -y libssl3 libgtk-3-0 libxkbcommon0
sudo dpkg -i ~/Downloads/DaVinci_Resolve_Studio_*.deb || sudo apt -f install -y

# 2. Lizenz aktivieren (interaktiv)
sudo -u davinci /opt/resolve/bin/resolve

# 3. Python API testen
sudo -u davinci python3 -c "
import os
os.environ['RESOLVE_SCRIPT_API']='/opt/resolve/Developer/Scripting/'
os.environ['RESOLVE_SCRIPT_LIB']='/opt/resolve/libs/Fusion/fusionscript.so'
import sys; sys.path.append('/opt/resolve/Developer/Scripting/Modules/')
import DaVinciResolveScript as dvr
print(dvr.scriptapp('Resolve').GetVersionString())
"
```

### Ollama vs. DaVinci Resource-Sharing

GPU hat 12 GB VRAM — beide gleichzeitig geht knapp. Workflow-Pattern:
```bash
# Vor DaVinci-Render
sudo systemctl stop ollama
# nach Render
sudo systemctl start ollama
```

Oder als n8n-Workflow: Pre/Post-Render-Hooks, die `systemctl` per SSH triggern.

## Logs

| Service | Log-Pfad |
|---|---|
| Ollama | `journalctl -u ollama -f` |
| n8n-private | `docker logs -f n8n-private` |
| SurrealDB | `docker logs -f surrealdb` |
| Traefik | `docker logs -f traefik` |
| GitHub Runner | `journalctl -u actions.runner.* -f` |
| restic-backup | `journalctl -u restic-backup.service` |

## Service-Restart

```bash
sudo systemctl restart ollama
docker compose -f /opt/n8n/docker-compose.yml restart n8n-private
docker compose -f /opt/monitoring/docker-compose.yml restart grafana
```

## Vault-MCP Build (nach R2D2-Migration)

```bash
cd /data/projects/llm-wiki-system-plan
make build
sudo install -m 755 ./vaultctl /home/agent/.local/bin/vaultctl
sudo -u agent vaultctl status
```

## Tailscale Auth-Key Rotation

Auth-Keys haben Ablaufdatum. Wenn AI-Server nach Rotation aus dem Tailnet fällt:
```bash
# Im Tailscale-Admin: neuen reusable key mit tag:ai-server generieren
sudo tailscale up --authkey=tskey-... --advertise-routes=192.168.1.0/24,172.17.0.0/16 --reset
```

Update auch in `vault.yml`:
```bash
./scripts/secrets-init.sh   # → vault_tailscale_authkey aktualisieren
```

## Monitoring-Alerts

Grafana Alert-Channels (zu konfigurieren):
- GPU temperature > 85°C → Telegram SystemBot
- Disk /data > 85% → Telegram + Discord #system-health
- Ollama unreachable > 5 min → Telegram (sofort)
- restic backup failed → Telegram (sofort)

## Known Issues / Gotchas

1. **Kernel 6.17 + NVIDIA**: Nicht alle NVIDIA-Driver-Versionen kompilieren. Falls nach `apt upgrade` der Driver bricht: `sudo apt install nvidia-driver-565-server-open` als Fallback.
2. **Bun + Node co-exist**: pnpm ist primär; bun nur für AI-Portal-Tooling. Nicht beide für gleiches `node_modules` mischen.
3. **Tailscale + Docker**: Wenn ein Container hinter Tailscale erreichbar sein soll, muss Docker-Subnet im `--advertise-routes` stehen. Schon im `06_tailscale` enthalten.
4. **DaVinci + Python 3.13**: Nicht installieren auf `davinci` user. ABI-Crash mit fusionscript.

## Referenz: Phasen-Reihenfolge bei vollständigem Reaufbau

Falls jemals von Null neu:
1. `bootstrap.sh`
2. `secrets-init.sh`
3. `playbooks/site.yml --tags base,storage,users,slices`
4. `playbooks/site.yml --tags nvidia,docker` + reboot
5. `playbooks/site.yml --tags tailscale` + ACL approven
6. `playbooks/site.yml --tags ollama,surrealdb,postgres,n8n_private`
7. `playbooks/site.yml --tags monitoring,github_runner,cli,vault_mcp,traefik`
8. `playbooks/migrate-r2d2.yml` ODER restic-Restore
9. `playbooks/hetzner-edge.yml`
10. `playbooks/site.yml --tags restic` (erstes Backup)
11. DaVinci manuell (siehe oben)
12. `playbooks/verify.yml` → grün
