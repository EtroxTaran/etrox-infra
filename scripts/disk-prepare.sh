#!/usr/bin/env bash
# disk-prepare.sh — Phase-0-Disk-Vorbereitung für ein BEREITS installiertes Ubuntu.
#
# Bringt eine schon installierte Ubuntu-Desktop-Maschine auf das von diesem Repo
# erwartete LABEL-Layout (siehe docs/DISK-LAYOUT.md), OHNE Neuinstallation:
#   1. OS-Disk (trägt '/') erkennen; Root-Partition -> LABEL=os, EFI -> LABEL=EFI
#   2. /etc/fstab (mit Backup) für '/' und '/boot/efi' auf LABEL= umstellen
#   3. Die LEERE Daten-NVMe partitionieren, ext4 mit LABEL=data, /data mounten + fstab
#
# Sicherheit:
#   - Relabel + fstab-Umschreiben sind NICHT-destruktiv (UUIDs/Daten bleiben; GRUB
#     bootet weiter über seine eigene Config).
#   - Das Formatieren der Daten-Disk IST destruktiv -> doppelte Bestätigung + Anzeige.
#   - Idempotent: bereits gesetzte Labels / gemountetes /data werden übersprungen.
#
# Danach: ./scripts/disk-layout-check.sh  muss grün sein.

set -euo pipefail

ok()   { echo "  ✓ $*"; }
info() { echo "[disk-prepare] $*"; }
warn() { echo "[disk-prepare] WARN: $*" >&2; }
die()  { echo "[disk-prepare] FATAL: $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "Bitte mit sudo ausführen:  sudo $0"

confirm() {
    local prompt="$1"
    read -rp "$prompt [tippe genau 'JA']: " ans
    [[ "$ans" == "JA" ]] || die "Abgebrochen."
}

# --- Prereqs -------------------------------------------------------------
info "Prüfe Tools (e2fsprogs, dosfstools, parted)..."
need_pkgs=()
command -v e2label  >/dev/null || need_pkgs+=(e2fsprogs)
command -v fatlabel >/dev/null || need_pkgs+=(dosfstools)
command -v parted   >/dev/null || need_pkgs+=(parted)
if [[ ${#need_pkgs[@]} -gt 0 ]]; then
    info "Installiere: ${need_pkgs[*]}"
    apt-get update -qq && apt-get install -y -qq "${need_pkgs[@]}"
fi

# --- 1) OS-Disk + Partitionen erkennen -----------------------------------
ROOT_SRC=$(findmnt -n -o SOURCE /)              || die "Konnte '/' nicht finden"
EFI_SRC=$(findmnt -n -o SOURCE /boot/efi 2>/dev/null || true)
OS_DISK="/dev/$(lsblk -no pkname "$ROOT_SRC" | head -1)"

info "OS-Disk:        $OS_DISK"
info "Root-Partition: $ROOT_SRC"
info "EFI-Partition:  ${EFI_SRC:-<keine /boot/efi gemountet>}"
echo

# --- 2) Labels setzen ----------------------------------------------------
root_label=$(blkid -s LABEL -o value "$ROOT_SRC" 2>/dev/null || true)
if [[ "$root_label" == "os" ]]; then
    ok "Root hat bereits LABEL=os"
else
    info "Setze LABEL=os auf $ROOT_SRC (online, nicht-destruktiv)"
    e2label "$ROOT_SRC" os
    ok "LABEL=os gesetzt"
fi

if [[ -n "${EFI_SRC:-}" ]]; then
    efi_label=$(blkid -s LABEL -o value "$EFI_SRC" 2>/dev/null || true)
    if [[ "$efi_label" == "EFI" ]]; then
        ok "EFI hat bereits LABEL=EFI"
    else
        info "Setze LABEL=EFI auf $EFI_SRC"
        if ! fatlabel "$EFI_SRC" EFI 2>/dev/null; then
            warn "fatlabel scheiterte (ESP evtl. busy). Manuell: 'sudo umount /boot/efi && sudo fatlabel $EFI_SRC EFI && sudo mount /boot/efi'"
        else
            ok "LABEL=EFI gesetzt"
        fi
    fi
else
    warn "Keine /boot/efi gemountet — EFI-Label übersprungen."
fi

# --- 3) /etc/fstab auf LABEL= umstellen (mit Backup) ---------------------
TS=$(date +%Y%m%d-%H%M%S)
cp -a /etc/fstab "/etc/fstab.bak.$TS"
ok "fstab gesichert: /etc/fstab.bak.$TS"

# Ersetzt das erste Feld (Quelle) für die Mountpoints / und /boot/efi durch LABEL=.
awk '
  BEGIN { OFS="\t" }
  /^[[:space:]]*#/ { print; next }
  NF < 2           { print; next }
  $2 == "/"        { $1 = "LABEL=os";  print; next }
  $2 == "/boot/efi"{ $1 = "LABEL=EFI"; print; next }
  { print }
' /etc/fstab > /etc/fstab.new && mv /etc/fstab.new /etc/fstab
ok "fstab: '/' -> LABEL=os, '/boot/efi' -> LABEL=EFI"
grep -E '^\s*LABEL=(os|EFI)\s' /etc/fstab || warn "Konnte LABEL-Zeilen nicht verifizieren — fstab prüfen!"

# --- 4) Daten-Disk (4 TB, leer) vorbereiten ------------------------------
echo
if findmnt -n /data >/dev/null 2>&1; then
    data_src=$(findmnt -n -o SOURCE /data)
    data_label=$(blkid -s LABEL -o value "$data_src" 2>/dev/null || true)
    if [[ "$data_label" == "data" ]]; then
        ok "/data ist bereits gemountet (LABEL=data) — überspringe Daten-Disk-Setup"
        DATA_DONE=1
    else
        warn "/data ist gemountet, aber Label='$data_label' (erwartet 'data'). Manuell prüfen."
        DATA_DONE=1
    fi
else
    DATA_DONE=0
fi

if [[ "${DATA_DONE:-0}" -eq 0 ]]; then
    # Kandidaten: echte 'disk'-Typen außer der OS-Disk (zram/loop/sr ausschließen —
    # Ubuntu nutzt z.B. zram-Swap, das sonst fälschlich als Disk zählt).
    mapfile -t other_disks < <(lsblk -dn -o NAME,TYPE \
        | awk '$2=="disk" && $1 !~ /^(zram|loop|sr)/ {print "/dev/"$1}' \
        | grep -v "^${OS_DISK}$" || true)
    if [[ ${#other_disks[@]} -ne 1 ]]; then
        warn "Erwartet GENAU eine weitere Disk, gefunden: ${other_disks[*]:-keine}"
        die "Daten-Disk nicht eindeutig — bitte manuell partitionieren (siehe docs/DISK-LAYOUT.md)."
    fi
    DATA_DISK="${other_disks[0]}"

    echo
    warn "================= DESTRUKTIVER SCHRITT ================="
    lsblk "$DATA_DISK"
    echo
    warn "Die GESAMTE Disk $DATA_DISK wird gelöscht und als ext4 (LABEL=data) für /data formatiert."
    confirm "Disk $DATA_DISK wirklich löschen?"

    info "Partitioniere $DATA_DISK (GPT, eine Partition)..."
    parted -s "$DATA_DISK" mklabel gpt
    parted -s "$DATA_DISK" mkpart data ext4 1MiB 100%
    udevadm settle || true; sleep 1

    DATA_PART=$(lsblk -lnp -o NAME,TYPE "$DATA_DISK" | awk '$2=="part"{print $1}' | head -1)
    [[ -n "$DATA_PART" ]] || die "Konnte neue Partition auf $DATA_DISK nicht finden"
    info "Formatiere $DATA_PART als ext4 (LABEL=data)..."
    mkfs.ext4 -F -L data "$DATA_PART"

    mkdir -p /data
    if ! grep -qE '^\s*LABEL=data\s' /etc/fstab; then
        echo -e "LABEL=data\t/data\text4\tdefaults,noatime\t0\t2" >> /etc/fstab
        ok "fstab: LABEL=data /data hinzugefügt"
    fi
    systemctl daemon-reload || true
    mount /data
    ok "/data gemountet: $(findmnt -n -o SOURCE,SIZE /data)"
fi

# --- 5) Abschluss --------------------------------------------------------
echo
info "Fertig. Verifikation:"
echo
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$OS_DISK" ${DATA_DISK:-}
echo
info "Jetzt prüfen:  ./scripts/disk-layout-check.sh"
info "Bei Problemen: fstab-Backup unter /etc/fstab.bak.$TS"
