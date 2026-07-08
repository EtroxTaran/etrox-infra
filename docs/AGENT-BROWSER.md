# Agent-Browser — isolierte Session für volle Browser-Steuerung

Damit Agenten (Hermes-Personas, Claude „computer use" / Claude in Chrome, browser-use,
Playwright) einen **echten** Browser interaktiv steuern können — getrennt von den
menschlichen KDE-Sessions. Aufgesetzt von `roles/20_agent_desktop`.

## Architektur

```
agent-User (uid 1001, headless, 24/7 via linger)
  ├─ agent-xvfb.service   → Xvfb :99  (virtueller Display 1920x1080)
  ├─ agent-chrome.service → google-chrome-stable headed auf :99
  │                         --user-data-dir=/data/agent/chrome   (persistent!)
  │                         --remote-debugging-port=9222 (CDP, NUR localhost)
  │                         --disable-gpu --disable-dev-shm-usage  (Xvfb-Stabilität)
  └─ agent-vnc.service     → x11vnc auf :99 (localhost, view-only)
```

**Warum `google-chrome-stable` (echte .deb) statt `chromium-browser`:** Auf Ubuntu 24.04 ist
`chromium-browser` ein **Snap-Wrapper**. Unter strict confinement bricht der Zugriff auf ein
eigenes `--user-data-dir` außerhalb der Snap-Pfade und das Laufen als systemd-Service/unter Xvfb
ist unzuverlässig. Die Google-`.deb` aus dem offiziellen apt-Repo ist für einen 24/7-CDP-Dienst
die robuste Wahl. Da `agent` **non-root** läuft, bleibt die Chrome-Sandbox aktiv (kein `--no-sandbox`).

- **Isoliert**: eigener Display, eigener User, eigenes Chrome-Profil. Die menschlichen
  Sessions (nico/sabine, KDE/Wayland) werden nie berührt.
- **Persistent**: eingeloggte Web-Sessions/Cookies bleiben unter `/data/agent/chrome`
  über Neustarts erhalten.
- **CDP an localhost:9222**: hier docken Treiber an.

## Anbindung der Treiber

- **Playwright**: `connectOverCDP("http://127.0.0.1:9222")` → steuert den laufenden Browser.
- **Hermes**: nutzt Browser Use / Firecrawl nativ; kann auf denselben CDP-Endpoint zeigen.
- **browser-use / computer-use**: gegen `:99` (Display) bzw. CDP-Port konfigurieren.

## Zuschauen / Übernehmen

```bash
ssh -L 5900:localhost:5900 nico@<ai-server>
# dann lokal mit einem VNC-Viewer auf localhost:5900
```

So lässt sich live verfolgen, was der Agent im Browser tut.

## Sicherheit

- CDP- und VNC-Port sind **nur an localhost** gebunden (Zugriff via SSH-/Tailscale-Tunnel).
- `agent` hat kein sudo; Egress sollte (optional) begrenzt werden.
- Keine menschlichen Vaults im Zugriff des `agent`-Users außer explizit freigegebene.
- Profil enthält Login-Cookies → `/data/agent/chrome` ist `0700` und Teil der restic-Backups
  nur, wenn gewünscht (standardmäßig sichern wir `/data/agent/hermes`, nicht das Chrome-Profil).
