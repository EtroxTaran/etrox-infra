#!/usr/bin/env bash
# disk-layout-check.sh — Verifiziert das erwartete Disk-Layout.
# Funktioniert für beide Topologien (single_disk_4tb und split_os_data),
# weil beide die gleichen Labels verwenden: os, data, EFI.
#
# Exit 0 = Layout ok. Exit != 0 = mindestens ein Problem.
#
# Siehe docs/DISK-LAYOUT.md.

set -uo pipefail

errors=0
ok()   { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; errors=$((errors + 1)); }

echo "[disk-layout-check] Labels"
for label in os data EFI; do
    if dev=$(blkid -L "$label" 2>/dev/null); then
        ok "LABEL=$label  →  $dev"
    else
        fail "LABEL=$label nicht gefunden"
    fi
done

echo "[disk-layout-check] Mounts"
declare -A expected=(
    [/]=os
    [/data]=data
    [/boot/efi]=EFI
)
for mp in "${!expected[@]}"; do
    label="${expected[$mp]}"
    src=$(findmnt -n -o SOURCE "$mp" 2>/dev/null || true)
    if [[ -z "$src" ]]; then
        fail "$mp ist nicht gemountet"
        continue
    fi
    actual_label=$(blkid -s LABEL -o value "$src" 2>/dev/null || true)
    if [[ "$actual_label" == "$label" ]]; then
        ok "$mp  ←  $src  (LABEL=$label)"
    else
        fail "$mp ist gemountet von $src, aber Label='$actual_label' (erwartet '$label')"
    fi
done

echo "[disk-layout-check] fstab nutzt LABEL="
for label in os data EFI; do
    if grep -qE "^[[:space:]]*LABEL=$label[[:space:]]" /etc/fstab; then
        ok "/etc/fstab enthält LABEL=$label"
    else
        fail "/etc/fstab enthält keinen LABEL=$label Eintrag (Stabilität nicht garantiert)"
    fi
done

echo "[disk-layout-check] /data Subdirs"
for d in projects builds vaults models davinci games agent backups; do
    if [[ -d "/data/$d" ]]; then
        ok "/data/$d existiert"
    else
        fail "/data/$d fehlt — Ansible-Phase 'storage' noch nicht gelaufen?"
    fi
done

echo
if [[ $errors -eq 0 ]]; then
    echo "[disk-layout-check] OK — Layout entspricht docs/DISK-LAYOUT.md"
    exit 0
else
    echo "[disk-layout-check] $errors Problem(e) gefunden — siehe oben."
    exit 1
fi
