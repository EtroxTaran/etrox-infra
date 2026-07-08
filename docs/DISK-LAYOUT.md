# Disk Layout — Strategie

Single Source of Truth für die Festplatten-Topologie des AI-Servers. Alle Mount-Entscheidungen, fstab-Einträge und Migrations-Pfade verweisen hierhin zurück.

## Grundprinzip: Label-basiertes Mounting

Mounts werden **immer** per `LABEL=…` referenziert, nie per `/dev/…` und nie per UUID.

**Warum:**
- `/dev/nvme0n1` vs. `/dev/nvme1n1` ändert sich, sobald eine Platte rein oder raus kommt.
- UUIDs ändern sich, sobald ein Filesystem neu angelegt wird (z. B. beim OS-Klon auf eine neue SSD).
- Labels sind stabil über Hardware-Wechsel hinweg, solange wir sie konsequent setzen.

**Konsequenz:** Jede ext4-Partition, die wir mounten, hat einen Label, der ihre **Rolle** beschreibt — nicht ihren Standort.

## Aktuelle Topologie: `split_os_data` (ab Juni 2026)

Seit dem Board-Tausch (ASUS ROG Strix B850-F) sind **beide NVMe verbaut**. Wir starten
direkt im Split-Layout: **1 TB NVMe trägt das OS**, die **4 TB (Samsung 9100 Pro)** trägt `/data`.
Der frühere Single-Disk-Start und die OS-Umzug-Migration entfallen damit.

| Disk           | Partition | Größe   | FS    | Label  | Mountpoint  | Zweck                          |
|----------------|-----------|---------|-------|--------|-------------|--------------------------------|
| 1 TB (OS-SSD)  | `…p1`     | 1 GiB   | FAT32 | `EFI`  | `/boot/efi` | EFI System Partition           |
| 1 TB (OS-SSD)  | `…p2`     | Rest    | ext4  | `os`   | `/`         | Ubuntu+KDE, `/home`, Docker, `/opt/*`, swap |
| 4 TB (9100)    | `…p1`     | ~4 TiB  | ext4  | `data` | `/data`     | Models, Vaults, DaVinci, Games, Backups, Repos |

`/etc/fstab` (Auszug):
```
LABEL=os    /         ext4 defaults,errors=remount-ro 0 1
LABEL=EFI   /boot/efi vfat umask=0077                 0 1
LABEL=data  /data     ext4 defaults,noatime           0 2
```

**Warum 1 TB fürs OS statt 256–500 GB:** Reichlich Headroom für zwei menschliche `/home`
(KDE, Caches), Steam-Shader-Caches und temporäre Builds. Große Daten (Spiele-Libraries,
DaVinci-Media, LLM-Modelle) liegen bewusst auf der 4 TB unter `/data`.

## Legacy: `single_disk_4tb`

Das frühere Start-Layout (OS+`/data` auf einer 4 TB, `os` ~150 GiB) wird nicht mehr genutzt.
Es bleibt nur als Fallback dokumentiert; `storage_topology` steht jetzt auf `split_os_data`.

## Was wo liegen darf

`/` (Label `os`):
- System (`/usr`, `/var`, `/etc`, `/home`)
- Docker-Daemon-Daten (`/var/lib/docker`)
- Service-Konfiguration und kleine persistente Daten unter `/opt/*` (n8n, Postgres-Daten von n8n, SurrealDB, Ollama-Service-Files)
- Swapfile (`/swapfile`)

`/data` (Label `data`):
- LLM-Modelle (`/data/models`)
- Obsidian-Vaults (`/data/vaults`)
- Git-Repos und Build-Artefakte (`/data/projects`, `/data/builds`)
- DaVinci-Scratch + Media (`/data/davinci`)
- Steam-Libraries + Proton (`/data/games`, Gruppe `games`, setgid)
- Hermes-Agent-State + Chrome-Profil (`/data/agent`)
- restic-Backup-Repo (`/data/backups/local`)
- R2D2-Pre-Migration-Snapshots (`/data/backups/r2d2-archive`)

## Sizing-Begründung

**150 GiB für `/`** ist großzügig dimensioniert für den langfristigen Lauf:
- Ubuntu Base + System-Tools: ~10 GiB
- Docker-Images (n8n, Postgres, SurrealDB, Ollama-Container, Monitoring-Stack): ~30 GiB
- Logs, apt-Cache, Snap: ~10 GiB
- Headroom für Updates und temporäre Builds: ~100 GiB

Wenn die spätere OS-SSD nur 256 GB hat, ist 150 GiB Klon-Footprint bequem klonbar (`rsync` über alles unter `/` außer `/data`, `/proc`, `/sys`, `/tmp`).

**3.85 TiB für `/data`** ist der gesamte Rest der 4 TB minus 150 GiB für `os` minus 1 GiB für EFI.

## Verifikation

```bash
# Labels existieren?
blkid -L os && blkid -L data && echo "labels ok"

# Mounts korrekt?
findmnt /
findmnt /data
findmnt /boot/efi

# fstab korrekt?
grep -E '^LABEL=(os|data|EFI)' /etc/fstab
```

Skript-Variante: [`scripts/disk-layout-check.sh`](../scripts/disk-layout-check.sh).
