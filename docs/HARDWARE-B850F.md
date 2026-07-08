# Hardware — ASUS ROG Strix B850-F Gaming WiFi (AM5)

Hardware-spezifische Hinweise für Ubuntu 24.04 auf diesem Board. Ergänzt von
`roles/00_base` (Sensors/NIC/Firmware) und `roles/04_nvidia_cuda` (GPU).

## BIOS-Settings (vor der OS-Installation setzen)

| Setting | Wert | Warum |
|---|---|---|
| Above 4G Decoding | **Enabled** | Korrekte BAR-Allokation für die GPU |
| Re-Size BAR (SAM) | **Enabled** | Etwas mehr GPU-Performance (RTX 30/40) |
| IOMMU / SVM | **Enabled** | Virtualisierung, Geräte-Isolation; kein Nachteil |
| Secure Boot | **Disabled** (empfohlen) | Sonst MOK-Enrollment für NVIDIA-DKMS nötig (s.u.) |
| XMP/EXPO | nach RAM-Spec | RAM auf beworbenem Takt |

## Secure Boot + NVIDIA-DKMS

**Empfehlung für diese Workstation: Secure Boot AUS.** Es laufen mehrere Out-of-Tree-DKMS-Module
(NVIDIA-Treiber, ggf. `r8125`); mit Secure Boot AUS laden die ohne Signatur-Aufwand — der Weg,
den praktisch alle NVIDIA-Desktop-Guides gehen. Wer Boot-Integrität priorisiert, nimmt Secure
Boot AN + einmaliges **MOK-Enrollment** (s.u.) — muss das aber ggf. bei jedem neuen DKMS-Modul/
Kernel wiederholen.

Der proprietäre NVIDIA-Treiber baut DKMS-Kernelmodule. Bei aktivem Secure Boot werden
unsignierte Module **nicht geladen**. Optionen:

1. **Secure Boot aus** (einfachster Weg) — `roles/04_nvidia_cuda` warnt, wenn aktiv.
2. **MOK-Enrollment**: Beim Treiber-Install MOK-Passwort setzen → nach Reboot im blauen
   *MokManager*-Menü Key enrollen → danach lädt das signierte Modul.
3. Canonical-signierte Archiv-Pakete nutzen (`ubuntu-drivers autoinstall`) — Module oft
   vorsigniert.

Status prüfen: `mokutil --sb-state`.

## Realtek 2.5GbE (RTL8125)

Der In-Kernel-Treiber `r8169` erkennt den Chip, ist auf 24.04 aber teils instabil
(Link da, aber kein DHCP/Traffic). **Fallback**: in `inventory/group_vars/ai_server/main.yml`

```yaml
b850f_install_r8125_dkms: true
```

setzen → `roles/00_base` installiert `r8125-dkms` und blacklistet `r8169` (Reboot nötig).
Erst probieren, ob der Stock-Treiber stabil läuft; nur bei Problemen aktivieren.

## WiFi 7 / Bluetooth

Combo-Modul (Intel/MediaTek). Auf 24.04 i.d.R. plug-and-play mit aktuellem
`linux-firmware` und ggf. **HWE-Kernel (6.11+)**. `b850f_install_linux_firmware_latest`
hält die Firmware aktuell. Bei flakigem BT zuerst `linux-firmware` updaten.

## lm-sensors

`roles/00_base` installiert `lm-sensors`. Einmalig interaktiv `sudo sensors-detect`
laufen lassen (NCT-Superio-Chip erkennen), dann `sensors`.

## NVIDIA-Treiber

Desktop-Workstation → **Desktop-Branch** (`nvidia-driver-570`, kein `-server`!), damit der
volle Vulkan/GLX-GUI-Stack für KDE + Steam/Proton da ist. CUDA 12.8 dazu. Wayland ist
Default-Session (KDE), X11 bleibt als Fallback wählbar. Siehe `roles/04_nvidia_cuda`.

**Wayland-KMS:** Die Rolle schreibt `/etc/modprobe.d/nvidia-kms.conf` mit
`options nvidia-drm modeset=1 fbdev=1` und ruft `update-initramfs -u`. `modeset=1` ist Pflicht
für die KDE-Wayland-Session (Ubuntu setzt es meist schon per Paket; wir setzen es defensiv
selbst), `fbdev=1` sorgt für sauberen Konsolen-Handoff (weniger Black-Screen/Flicker beim Boot).
Prüfen: `cat /sys/module/nvidia_drm/parameters/modeset` → `Y`.
