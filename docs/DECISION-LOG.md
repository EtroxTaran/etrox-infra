# Decision Log

Architektur-Entscheidungen für dieses Provisioning-Repo.

## Known TODOs (vor erstem Bare-Metal-Run prüfen)

Diese Punkte sind nicht-blockierend — kann auch live korrigiert werden — aber gut zu wissen:

- [ ] **Test-VM-Trockenlauf:** Idealerweise einmal `playbooks/site.yml --check --diff --skip-tags nvidia,davinci` in einer libvirt/VBox-VM gegen ein leeres Ubuntu 24.04 laufen lassen. Repo enthält noch keinen Vagrantfile — manueller Spin-up nötig.
- [ ] **Tailscale ACL** muss manuell ins Admin-Console gepasted werden (siehe ADR-008). `verify.yml` testet das via Hetzner→AI-Server Webhook-Roundtrip — wenn der grün ist, ACL ist korrekt.
- [ ] **DNS-Records** für `n8n-gw.<domain>` und `portal.<domain>` und `api.<domain>` müssen vor `hetzner-edge.yml` zeigen auf die Hetzner-Public-IP (sonst Let's Encrypt schlägt fehl).
- [ ] **NVIDIA-Driver-Branch** wird seit ADR-011 auto-detected; Konfiguration `nvidia_driver_branch` in `inventory/group_vars/ai_server/main.yml` ist nur noch Hint.
- [ ] **Smart-Home-Tailscale-Tag** auf R2D2 sollte auf `tag:home-control` umgestellt werden (jetzt evtl. ohne Tag) — manuell im Tailscale-Admin.



## ADR-001: Hybrid Bash-Bootstrap + Ansible

**Datum:** 2026-05-06
**Status:** Akzeptiert
**Kontext:** Wahl zwischen reinem Bash, Ansible, NixOS, oder Hybrid.
**Entscheidung:** Bash-Bootstrap (~Phase 0) + Ansible für alles Andere.
**Warum:**
- Ein-Befehl-UX bleibt erhalten (`./bootstrap.sh`)
- Idempotente Re-runs für Drift-Recovery (Ansible)
- Multi-Host (AI-Server + Hetzner + R2D2-Migration) ohne neue Tools
- Keine Plattform-Migration auf NixOS nötig (DaVinci-Lizenz, NVIDIA-Treiber)
**Konsequenz:** Höhere Lernkurve als Bash-only; aber Standard-Pattern in der Branche, gut dokumentiert.

## ADR-002: Admin-User `nico` (uid 1000) auf dem AI-Server  — SUPERSEDED ADR-002a

**Datum:** 2026-05-06 (revidiert 2026-06)
**Kontext:** Masterplan v2 schlug `nico` vor; eine frühe Fassung wählte `etrox` für Host-Konsistenz.
**Revidierte Entscheidung (2026-06):** Die AI-Workstation wird mit **Ubuntu Desktop** neu
installiert; der dabei angelegte Erst-User (uid 1000) heißt **`nico`**. Wir nutzen diesen
direkt als primären Admin/Desktop-User statt ihn umzubenennen (Rename eines eingeloggten
Users ist riskant).
**Abgrenzung:** Die **Hetzner**-Identität bleibt `etrox` (VPS-Hostname, Tailnet-Host
`etrox.<tailnet>`, Tailscale-Login, Email-Domain `etrox.de`) — das ist bewusst getrennt vom
OS-User der Workstation.
**Konsequenz:** `admin_user: nico`, `hosts.yml ansible_user: nico`, `system_users[0].name: nico`.
Hetzner-`etrox`-Referenzen NICHT anfassen.

## ADR-003: PostgreSQL für n8n statt SQLite

**Datum:** 2026-05-06
**Kontext:** R2D2 hatte n8n mit SQLite (`/home/clawd/.n8n/database.sqlite`). Neuer Server: SQLite vs. Postgres.
**Entscheidung:** Postgres 16-alpine.
**Warum:**
- Bessere Concurrency unter Last (n8n-edge → n8n-private mit parallelen Webhooks)
- Sauberer für Backup/Restore (`pg_dump`)
- Migration via `n8n export` / `n8n import` ist DB-agnostisch
**Konsequenz:** Eine zusätzliche Komponente, aber Standard-Stack.

## ADR-004: n8n-Split (private + edge)

**Datum:** 2026-05-06
**Kontext:** Public Webhooks brauchen public URL, aber n8n-Editor + Vault-Zugriff darf nie public sein.
**Entscheidung:** Zwei n8n-Instanzen — private auf AI-Server (Tailscale-only), edge auf Hetzner (public, `N8N_DISABLE_UI`, kein Vault-Key).
**Warum:** Kommt direkt aus Hetzner-Addendum §3. Verhindert das Dokploy-`/register`-Problem auf einer Vault-Maschine.
**Konsequenz:** Zwei Encryption-Keys nötig (separate Vaults). Webhook-Forward via Shared-Secret-Header.

## ADR-005: R2D2 bleibt als Smart-Home-Hub

**Datum:** 2026-05-06
**Kontext:** Migration aller R2D2-Workloads auf neuen Server vs. R2D2 für IoT behalten.
**Entscheidung:** R2D2 bleibt — HomeAssistant + Matter-Server laufen weiter dort.
**Warum:**
- Matter-USB-Stick ist physisch in R2D2 (Re-Pairing wäre teuer)
- Mini-PC ist gut dimensioniert für 24/7 Smart-Home
- AI-Server kann ohne IoT-Verantwortung skalieren
- Saubere Trennung: `tag:ai-server` vs. `tag:home-control`
**Konsequenz:** Zwei Server statt einem. R2D2 bekommt minimale Wartung (`apt upgrade` weiterhin manuell).

## ADR-006: Ollama als systemd-Service, nicht Container

**Datum:** 2026-05-06
**Kontext:** Masterplan v2 zeigt Ollama als Container. Frage: lohnt sich das?
**Entscheidung:** Systemd-Service (kein Container).
**Warum:**
- Direkter GPU-Zugriff ohne nvidia-container-runtime-Layer
- Einfacheres Modell-Pulling (`ollama pull` direkt auf Host)
- Cleaner cgroup-Slice (`user-1004.slice` greift direkt)
**Konsequenz:** Eigene Drop-In `/etc/systemd/system/ollama.service.d/override.conf`. Kein Compose-Netzwerk für Ollama, andere Container müssen `host.docker.internal` oder Tailscale-IP nutzen.

## ADR-007: vaultctl als Placeholder zu Beginn

**Datum:** 2026-05-06
**Kontext:** Echtes vaultctl kommt aus `llm-wiki-system-plan` Repo, das nach Migration verfügbar wird.
**Entscheidung:** Role 16 installiert ein Stub-Script + Policy-File. Echtes Binary wird nach Phase 8 (R2D2-Migration) gebaut.
**Warum:** Bootstrap kann nicht von Repo abhängen, das noch nicht migriert ist. Reihenfolge: Provisioning → Migration → vaultctl-Build.
**Konsequenz:** Phase-9-TODO im Runbook: `cd /data/projects/llm-wiki-system-plan && make build && install -m 755 vaultctl /home/agent/.local/bin/`.

## ADR-009: Pre-Migration Tarball-Snapshot

**Datum:** 2026-05-06
**Kontext:** Migrations-Playbook zieht read-only von R2D2, aber bei Bash-Tippfehler in einem Pfad gäbe es kein Rollback.
**Entscheidung:** Vor jedem rsync ein vollständiger `tar.gz`-Snapshot von `/home/clawd/{.openclaw,.openclaw-companies,vaults,.n8n}` nach `/data/backups/r2d2-archive/` mit Timestamp.
**Warum:** Cheap insurance. ~6 MB Vaults + ~few-hundred-MB Workspace komprimiert klein, aber recovery-fähig.
**Konsequenz:** Erster Migrationslauf kostet 1–2 Min mehr. Snapshot bleibt liegen — Day-2-Ops kann ihn nach erfolgreicher Migration manuell löschen.

## ADR-010: n8n-Export-Version Pinning

**Datum:** 2026-05-06
**Kontext:** `npx n8n@latest export` gegen alte SQLite kann an Schema-Migrations scheitern.
**Entscheidung:** Migrations-Playbook liest die n8n-Version aus R2D2's `.n8n/package.json` und nutzt exakt diese.
**Konsequenz:** Bei sehr alten n8n-Versionen kann `npx` lange brauchen (kein Cache). Tradeoff akzeptiert für Schema-Sicherheit.

## ADR-011: NVIDIA Driver Branch Auto-Detection

**Datum:** 2026-05-06
**Kontext:** Driver-Branch `565` war hartcodiert. Wenn Ubuntu eine neuere Version pflegt oder 565 deprecated, schlägt `apt install nvidia-driver-565-server` fehl.
**Entscheidung:** Role 04 sucht via `apt-cache search` alle verfügbaren `nvidia-driver-N-server` Pakete. Wenn der konfigurierte Branch da ist, nimm den; sonst neueste verfügbare.
**Konsequenz:** Selbstheilend bei Ubuntu-Updates. Konfiguration `nvidia_driver_branch` ist jetzt nur noch ein "Wunsch", kein hartes Lock.

## ADR-008: ACL nicht via Tailscale-API automatisieren

**Datum:** 2026-05-06
**Kontext:** Tailscale-API kann ACLs schreiben. Aber: Schreibt man die ACL falsch, sperrt man sich selbst aus.
**Entscheidung:** ACL liegt als Datei (`roles/06_tailscale/files/tailscale-acl.json`) im Repo, wird **manuell** ins Tailscale-Admin gepasted.
**Warum:** Sicherheit > Automation.
**Konsequenz:** ACL-Updates erfordern manuellen Step im Runbook.
