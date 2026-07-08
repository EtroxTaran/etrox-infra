# OS-SSD-Migration — von Single-Disk auf Split-Layout

> ⚠️ **OBSOLET / ERLEDIGT (Juni 2026).** Seit dem Board-Tausch (B850-F) sind beide NVMe
> verbaut und wir installieren **direkt** im `split_os_data`-Layout (1 TB OS + 4 TB data,
> siehe [`DISK-LAYOUT.md`](DISK-LAYOUT.md)). Dieser Umzug ist damit **nicht mehr nötig**.
> Das Runbook bleibt nur als Referenz / Notfall-Wissen stehen.

Runbook für den späteren Umzug, wenn die dedizierte OS-SSD physisch verfügbar ist. Vorbedingung: Server läuft aktuell mit Single-Disk-Layout (siehe [`DISK-LAYOUT.md`](DISK-LAYOUT.md)).

**Dauer:** ~90 min, davon ~20 min Service-Downtime.

**Risiko:** Mittel. Volles restic-Backup vorher → Rollback ist immer möglich.

---

## §0 — Voraussetzungen

- Neue NVMe-SSD (≥ 256 GB) im Server eingebaut, im BIOS sichtbar
- Live-USB mit Ubuntu 24.04 (oder beliebiges Linux mit `rsync`, `parted`, `e2fsprogs`, `efibootmgr`)
- restic-Backup ist aktuell (Phase 11 fertig, letzter Run grün)
- Mind. 200 GB freier Platz auf `/data` für den OS-Snapshot
- Wartungsfenster: Services dürfen ~20 min down sein

Identifizier die Disks vorab:
```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,LABEL
```
Notier: aktuelle 4 TB als `OLD_DISK` (z. B. `/dev/nvme1n1`), neue SSD als `NEW_DISK` (z. B. `/dev/nvme0n1`).

---

## §1 — Pre-Flight Backup (15 min)

### 1.1 Services stoppen
```bash
sudo systemctl stop docker n8n-private || true
sudo systemctl stop ollama || true
docker ps          # sollte leer sein
```

### 1.2 restic-Snapshot erzwingen
```bash
sudo systemctl start restic-backup.service
sudo journalctl -u restic-backup.service -f    # bis "snapshot created"
```

### 1.3 OS-Snapshot als tar
Sicherheitsnetz für Schritt 4. Liegt auf `/data`, also auf der 4 TB → wird beim OS-Umzug nicht angefasst.
```bash
sudo tar --xattrs --acls --numeric-owner \
    --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run \
    --exclude=/tmp --exclude=/mnt --exclude=/media --exclude=/data \
    --exclude=/swapfile \
    -cf - / | zstd -T0 -3 > /data/backups/os-pre-migration.tar.zst

ls -lh /data/backups/os-pre-migration.tar.zst
```

**Rollback-Punkt 1.** Wenn etwas in §2-§4 schiefgeht: `tar -xf` zurück nach `/`.

---

## §2 — Neue SSD partitionieren + OS klonen (30 min)

Boot vom Live-USB. **Nicht** vom installierten System aus, weil `/` aktiv ist.

### 2.1 Disks identifizieren
```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,LABEL
# OLD_DISK, NEW_DISK aus §0 verifizieren
```

### 2.2 Neue SSD partitionieren
```bash
sudo parted ${NEW_DISK} mklabel gpt
sudo parted ${NEW_DISK} mkpart EFI fat32 1MiB 1025MiB
sudo parted ${NEW_DISK} set 1 esp on
sudo parted ${NEW_DISK} mkpart os ext4 1025MiB 100%

sudo mkfs.fat -F32 -n EFI ${NEW_DISK}p1
sudo mkfs.ext4 -L os ${NEW_DISK}p2
```

### 2.3 Klonen
```bash
sudo mkdir -p /mnt/old /mnt/new
sudo mount LABEL=os /mnt/old              # alte Root-Partition auf 4 TB
sudo mount ${NEW_DISK}p2 /mnt/new

sudo rsync -aHAXxv --numeric-ids \
    --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run \
    --exclude=/tmp/* --exclude=/mnt --exclude=/media \
    /mnt/old/ /mnt/new/

sudo mkdir -p /mnt/new/boot/efi
```

EFI-Inhalt rüber:
```bash
sudo mkdir -p /mnt/old-efi /mnt/new-efi
sudo mount LABEL=EFI /mnt/old-efi          # alte EFI auf 4 TB (alter Label)
sudo mount ${NEW_DISK}p1 /mnt/new-efi
sudo cp -a /mnt/old-efi/. /mnt/new-efi/
```

### 2.4 fstab muss nicht angepasst werden
Da Labels (`os`, `EFI`, `data`) konsistent bleiben, bleibt `/etc/fstab` auf `/mnt/new/etc/fstab` korrekt — verifizieren:
```bash
grep -E '^LABEL=' /mnt/new/etc/fstab
```

### 2.5 Bootloader für neue SSD installieren (chroot)
```bash
for d in /dev /proc /sys /run; do sudo mount --bind $d /mnt/new$d; done
sudo mount ${NEW_DISK}p1 /mnt/new/boot/efi    # neuer EFI mount
sudo chroot /mnt/new bash <<'EOF'
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck
update-initramfs -u -k all
update-grub
efibootmgr -v
EOF

# Aushängen
sudo umount /mnt/new/boot/efi
for d in /run /sys /proc /dev; do sudo umount /mnt/new$d; done
sudo umount /mnt/new /mnt/old /mnt/new-efi /mnt/old-efi
```

### 2.6 BIOS-Boot-Order
Neustart, ins BIOS, neue SSD als ersten Boot-Eintrag setzen. Live-USB raus.

**Rollback-Punkt 2.** Wenn das Live-System nicht klont: nichts angefasst, alte Disk bootet weiter.

---

## §3 — Boot-Test (5 min)

```bash
ssh nico@<lan-ip>
findmnt /                  # SOURCE muss auf NEW_DISK p2 zeigen
findmnt /boot/efi          # SOURCE muss auf NEW_DISK p1 zeigen
findmnt /data              # SOURCE muss auf OLD_DISK p3 zeigen (alte data-Partition)
sudo systemctl start docker
sudo systemctl start n8n-private ollama
docker ps
```

Wenn alles grün → weiter zu §4. Wenn nicht → BIOS zurück auf alte Disk, alter Stand läuft weiter.

**Rollback-Punkt 3.** Bis hier ist die alte 4 TB unangetastet — BIOS-Boot-Order zurück, du bist im alten Zustand.

---

## §4 — Alte OS-Partitionen löschen, /data erweitern (15 min)

Ab hier wird die alte Disk **destruktiv** angefasst. Tar-Snapshot aus §1.3 muss existieren.

### 4.1 Services nochmal stoppen
```bash
sudo systemctl stop docker n8n-private ollama
sudo umount /data
```

### 4.2 Alte Partitionen entfernen
```bash
# OLD_DISK = die ursprüngliche 4 TB
sudo parted ${OLD_DISK} print          # Layout merken
# Annahme: p1=EFI, p2=os, p3=data — beide ersten weg
sudo parted ${OLD_DISK} rm 1
sudo parted ${OLD_DISK} rm 2
```

### 4.3 data-Partition vergrößern
Variante A — `parted` resizepart (online, einfach):
```bash
# data ist jetzt p3 — auf den ganzen Disk-Anfang verschieben geht NICHT mit parted.
# Wir lassen p3 wo es ist und nutzen einfach den Platz NACH p3 — geht hier nicht,
# weil p1+p2 VOR p3 liegen. → Korrekter Weg:
```

Variante B — Partition neu anlegen mit gleichem Start (gefährlich, nur wenn `e2fsck` sauber ist). Sicherer Weg ist:

```bash
sudo e2fsck -f ${OLD_DISK}p3
# parted: alte data-Partition auf gleicher Position löschen, neu anlegen mit Start=1MiB
sudo parted ${OLD_DISK} rm 3
sudo parted ${OLD_DISK} mkpart data ext4 1MiB 100%
# Das Filesystem ist intakt, weil mkpart nur die Partitionstabelle ändert.
# Aber der Filesystem-Start muss zur neuen Partitions-Start-LBA passen.
```

⚠️ **Stop.** Variante B ist nur sicher, wenn der Filesystem-Anfang auf LBA 2048 (1 MiB) liegt — was bei `parted ... mkpart ... 0%` mit modernen parted-Versionen automatisch gilt. **Vorher mit `dumpe2fs -h ${OLD_DISK}p3 | grep "First block"` verifizieren** und mit dem alten Start-Offset abgleichen (`parted ${OLD_DISK} unit s print` vor dem Löschen).

Wenn Filesystem-Start ≠ neuer Partitions-Start → Variante C: Daten via rsync auf temporären Speicher, neu formatieren, zurück.

Nach erfolgreichem `mkpart`:
```bash
sudo e2label ${OLD_DISK}p1 data         # Label sicherstellen (parted vergibt evtl. neu)
sudo resize2fs ${OLD_DISK}p1            # auf volle Partition wachsen
```

### 4.4 Wieder mounten
```bash
sudo mount /data
df -h /data            # sollte jetzt ~3.99 TiB zeigen
```

### 4.5 Services starten
```bash
sudo systemctl start docker n8n-private ollama
ansible-playbook playbooks/verify.yml
```

---

## §5 — Verifikation + Cleanup

```bash
./scripts/disk-layout-check.sh
findmnt /
findmnt /data
df -h
lsblk -o NAME,SIZE,LABEL,MOUNTPOINT
```

`storage_topology` in `inventory/group_vars/all/main.yml` von `single_disk_4tb` auf `split_os_data` umstellen, committen.

OS-Snapshot wegräumen (erst NACH erfolgreichem Verify):
```bash
ls -lh /data/backups/os-pre-migration.tar.zst
# Optional ein paar Tage stehen lassen, dann:
sudo rm /data/backups/os-pre-migration.tar.zst
```

---

## Rollback-Übersicht

| Bis Schritt | Rollback                                                      |
|-------------|---------------------------------------------------------------|
| Ende §1     | Services starten, alles unverändert                           |
| Ende §2     | BIOS-Boot-Order zurück auf 4 TB                               |
| Ende §3     | BIOS-Boot-Order zurück, neue SSD optional ausbauen            |
| Ende §4     | Live-USB → tar-Snapshot zurück auf neuer SSD ODER auf 4 TB    |

---

## Notfall: Boot von neuer SSD schlägt fehl

1. Live-USB booten
2. `mount LABEL=os /mnt && mount LABEL=EFI /mnt/boot/efi`
3. Chroot rein, `update-grub` und `grub-install` wiederholen
4. Wenn das nicht hilft: tar-Snapshot zurück nach `/mnt`, dann erneut `grub-install`
