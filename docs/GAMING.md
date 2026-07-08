# Gaming — Steam / Proton / Civilization VII

Setup durch `roles/19_gaming` (Steam .deb, gamemode, mangohud, Proton-GE) und
`roles/21_gpu_arbiter` (VRAM freigeben). Gilt für die menschlichen User `nico` und `sabine`.

## Warum Steam als `.deb` (nicht Flatpak/Snap)

Proton braucht engen Zugriff auf die System-NVIDIA/Vulkan-Treiber und die 32-bit-Libs.
Die `.deb`/apt-Variante integriert sauber mit dem systemweiten Treiber-Stack; Flatpak/Snap
bringen eigene Runtimes mit, die beim Treiber-Support hinterherhinken können.

## Steam-Library auf `/data/games`

`roles/01_storage` legt `/data/games` (Gruppe `games`, setgid) an. In Steam:
**Einstellungen → Speicher → Laufwerk hinzufügen → `/data/games`**. Große Libraries +
Shader-Caches gehören auf die 4 TB, nicht auf die 1-TB-OS-SSD.

## Proton / Proton-GE

`roles/19_gaming` installiert die neueste **Proton-GE** pro User nach
`~/.steam/root/compatibilitytools.d`. In Steam pro Spiel wählbar via
**Eigenschaften → Kompatibilität → Proton-GE … erzwingen**.

Leiter bei Problemen mit einem Titel:
1. Aktuelles offizielles **Proton** (z.B. 9.x)
2. **Proton Experimental**
3. **Proton-GE** (oft schnellste Fixes für neue AAA-Titel)

## Civilization VII

- Civ-Reihe nutzt historisch **kein** Kernel-Anti-Cheat → Proton-tauglich erwartbar.
- Vor dem ersten Start **ProtonDB** prüfen (Rating + empfohlene Proton-Version + Launch-Optionen):
  https://www.protondb.com/ → „Civilization VII".
- Falls 2K-Launcher/EOS zickt: Proton-GE wählen, ggf. Launch-Option `PROTON_USE_WINED3D=0`
  bzw. die in ProtonDB genannten Optionen setzen.
- `mangohud %command%` als Launch-Option zeigt FPS/Frametimes.

## GPU teilen (12 GB VRAM)

Ollama, DaVinci und Civ 7 konkurrieren um 12 GB. Vor dem Spielen VRAM freigeben:

```bash
gpu-heavy on      # stoppt Ollama, wartet bis VRAM frei
# … Civ 7 spielen …
gpu-heavy off     # Ollama wieder hochfahren
```

Oder als KDE-Launcher „GPU für Spiele/Render freigeben". Gamer (Gruppe `games`) dürfen das
ohne volles sudo (eng begrenzte sudoers-Regel, siehe `roles/21_gpu_arbiter`).
