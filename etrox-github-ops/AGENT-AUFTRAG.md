# Auftrag: GitHub-Ops für EtroxTaran

**Du** bist der GitHub-Ops-Agent auf `bb8`.
**Ab jetzt gehört GitHub dir.** Code, PRs, Issues, Merges, Dependencies, CI, Repo-Settings
und Merge-Gates. Nico klickt nichts mehr.

Dieses Dokument ist vollständig. Es enthält keine Aufgaben für Menschen.
Jeder Schritt ist von dir ausführbar und verifizierbar.
Stand: 2026-07-28.

---

## 0. Bootstrap — 3 Minuten

Alle Zugänge existieren bereits. Du musst nur die Konfiguration schreiben.

```bash
test -d ~/etrox-github-ops || { echo "Bundle fehlt"; exit 1; }
cd ~/etrox-github-ops
chmod +x lib/*.sh ops/*.sh rulesets/*.sh

cat > ~/.config/etrox/github.env <<'EOF'
OPS_APP_ID="4413799"
OPS_INSTALLATION_ID="149552788"
OPS_CLIENT_ID="Iv23li4KxW4aFfAJRxEI"
OPS_PEM="$HOME/.config/etrox/ops.pem"

ADMIN_APP_ID="4413819"
ADMIN_INSTALLATION_ID="149553563"
ADMIN_CLIENT_ID="Iv23litDFhb5hWCd71hF"
ADMIN_PEM="$HOME/.config/etrox/admin.pem"

GITHUB_OWNER="EtroxTaran"
BACKUP_DIR="/srv/backup/github"
EOF
chmod 600 ~/.config/etrox/github.env

./ops/verify-setup.sh
```

`verify-setup.sh` muss grün sein und ausdrücklich bestätigen:
**`etrox-ops` hat KEIN Administration-Recht.** Wenn doch, stoppe und melde es.

**Wenn die beiden `.pem` fehlen:** brich ab und melde
„`~/.config/etrox/ops.pem` und/oder `admin.pem` fehlen" — dann liegen sie noch auf
Nicos Windows-Rechner. Keine Ersatzkonstruktion bauen, keine PATs anlegen.

Danach: `sops`-Verschlüsselung nach eurem bestehenden sops+age-Muster anwenden,
beide Keys mit **unterschiedlichen** age-Recipients. Sonst hebelt ein einziger
kompromittierter Schlüssel die Trennung der beiden Apps wieder aus.

---

## 1. Warum das Setup so aussieht

Drei gemessene Befunde bestimmen alles Weitere:

**a) Die gesamte GitHub-Rechnung ist Artifact-Storage, nicht Rechenzeit.**
Messung 14.07.2026: `Actions Linux — 112 min, brutto $0.67, berechnet $0.00` ·
`Actions storage — 339,4 GB-hr, berechnet $0.11`. Letzteres fällt seit dem 05.07. an
*jedem* Tag an. Juli: $17.13 brutto, $2.53 berechnet — ausschließlich Storage.
339,4 GB-hr ÷ 24 h ≈ **14 GB dauerhaft**, Pro enthält 2 GB.
→ Compute ist gratis. Der Self-Hosted-Runner spart in dieser Rechnung exakt $0.
Er hat andere gute Gründe (lokale Secrets, LiteLLM, GPU) — aber keine finanziellen.

**b) Ein Classic-PAT „Computer claw" mit `admin:enterprise`, `admin:org`, `delete_repo`,
`repo`, `workflow`, `user` und ohne Ablaufdatum ist noch aktiv.** Das ist der Zugang,
den du ersetzt. Es wurde in der Woche vor dem Audit benutzt — niemand weiß aktuell,
welche Dienste daran hängen (n8n? Dokploy? lokale Skripte?).

**c) 0 Self-Hosted-Runner sind registriert**, während `klubhaus-elf` weiter Jobs mit
`self-hosted`-Label startet. Belege: Runners-Seite meldet „0 available runners";
Usage-Metriken Juli zeigen dieselben Workflows *teils* hosted, *teils* self-hosted
(docs-check 5 min hosted / 2 self-hosted, linear-link-check 5/4, redeploy-docs 6/1);
Laufzeiten von **2 h 34 m** und **1 h 42 m** für einen Docs-Check; `Redeploy docs site #218`
steht dauerhaft auf **„Queued"**. Das sind keine langsamen Jobs — das sind Jobs, die auf
einen Runner warten, den es nicht gibt.

---

## 2. Was bereits erledigt ist — nicht wiederholen

Am 28.07.2026 über die Weboberfläche geändert und verifiziert:

| Änderung | Wo |
|---|---|
| Artifact-/Log-Retention 90 → 7 Tage | `x-ai-stack`, `klubhaus-elf` |
| Copilot „use my data for AI model training" → Disabled | Account |
| Copilot „Suggestions matching public code" → Blocked | Account |
| Grouped security updates → alle Repos + Auto-Enable für neue | Account |
| Dependabot malware alerts → an | beide Repos |
| Allow auto-merge → an | `x-ai-stack` (war aus) |
| Automatically delete head branches → an | `x-ai-stack` (war aus) |
| Always suggest updating PR branches → an | beide Repos |
| Budget `Sandbox` $0 + Stop-Usage | Account |
| Budget `Spark` $0 + Stop-Usage | Account |
| GitHub Apps `etrox-ops-bb8` + `etrox-admin-bb8` angelegt und installiert | Account |

**Korrektur zum Audit:** Für `Models` lässt sich kein Budget anlegen, weil Models-Billing
gar nicht aktiviert ist. Damit kann dort nichts anfallen. **Nicht aktivieren.**

**Wichtig:** Die 7-Tage-Retention gilt nur für **neue** Artifacts. Die vorhandenen ~14 GB
behalten ihre 90-Tage-Frist. Sie zu löschen ist deine Aufgabe 3.1.

---

## 3. Deine Aufgaben

### Phase 1 — Kosten stoppen

**3.1 Storage sanieren.**
```bash
./ops/storage-cleanup.sh --report        # wo liegen die GB
./ops/storage-cleanup.sh --retention     # 7 Tage auf die übrigen 25 Repos
./ops/storage-cleanup.sh --purge --all   # Erstbereinigung
./ops/storage-cleanup.sh --report        # Gegenprobe
```
**Fertig, wenn:** Report meldet < 2 GB. Erwartete Einsparung ~$40/Jahr.

**3.2** Auf jedem `upload-artifact`-Step `retention-days: 3` setzen.
Vorlage: `templates/ci-template.yml`. Sonst kommt das Problem in 90 Tagen zurück.

---

### Phase 2 — Runner reparieren

**3.3 Zustand feststellen.**
```bash
systemctl status 'actions.runner.*'
./ops/register-runner.sh --status    # registrierte Runner UND wartende Jobs
```

**3.4 Entscheiden statt mischen.** Der aktuelle Zustand — dieselben Workflows laufen mal
hosted, mal self-hosted — ist die Ursache der Queue-Hänger. Ab jetzt:

- `ubuntu-latest`: alles ohne lokale Secrets/Modelle. Auf public Repos kostenlos, auf
  private innerhalb der 3.000 Pro-Freiminuten. Keine Queue, keine Wartezeit.
- `self-hosted`: **nur** Jobs, die LiteLLM, lokale Modelle oder das Vault brauchen.

Konkret in `klubhaus-elf`: `docs-check`, `linear-link-check`, `redeploy-docs`,
`notebooklm-export` → `ubuntu-latest`. AI-Review → bb8.

**3.5** `timeout-minutes` auf **jeden** Job. Ohne Ausnahme.

**3.6** Runner registrieren, falls er fehlt:
```bash
./ops/register-runner.sh --register klubhaus-elf
```

**3.7 Monitoring.** Ein Runner, der 6 Monate weg ist, ohne dass es jemand merkt, ist das
eigentliche Problem. Nimm in den Nightly-Lauf eine Prüfung auf: gibt es Jobs, die
> 15 min in der Queue stehen → Issue.

---

### Phase 3 — Zugang scharf schalten

**3.8 Watcher auf App-Token umstellen.** `ai-review-watch@klubhaus-elf.service` und das
Pendant in `x-ai-stack` posten `ai-review/consensus` künftig über das ops-Token statt
über das Classic-PAT:
```bash
GH_TOKEN="$(./lib/mint-token.sh ops)"    # gültig 1 h, bei jedem Aufruf neu
```

**3.9 Status-Quelle festnageln.** In `x-ai-stack` steht der Required Check
`ai-review/consensus` auf **„any source"** — jeder Token mit `repo:status` kann das Tor
auf grün setzen. Nach 3.8 die Quelle auf `etrox-ops-bb8` fixieren; `integration_id`
in `rulesets/baseline-code.json` ist dafür vorbereitet (App ID 4413799).

---

### Phase 4 — Gates

**3.10 Rulesets ausrollen.**
```bash
./rulesets/apply-rulesets.sh --dry-run
./rulesets/apply-rulesets.sh
```

Modell (von Nico entschieden): **voll autonomer Self-Merge.**
`required_approving_review_count: 0`, Tor ist der Status-Check.
**`etrox-ops` ist bewusst KEIN Bypass-Actor.** Du merged nicht, indem du das Gate
umgehst, sondern weil dein eigener Check grün ist. Break-Glass läuft über `etrox-admin`.

**Du darfst die Gates ändern.** Sie liegen als JSON in `rulesets/`. Ändern, committen,
ausrollen. Mit den fünf Grenzen aus Abschnitt 4.

**3.11 Beweisen, nicht behaupten.**
- Test-PR mit grünem Check → du merged ihn ohne Nico. Muss klappen.
- Test-PR mit rotem Check → **nicht** mergebar. Muss scheitern.

Erst wenn beides stimmt, Legacy-Branch-Protection löschen:
`x-ai-stack` Regel `79030397`, `klubhaus-elf` Regel `77710451`.
Vorher nicht — Legacy und Rulesets gelten additiv, die strengere gewinnt, und du
jagst sonst Phantome.

**3.12 Dependabot entrümpeln.** 5 von 6 offenen PRs in `x-ai-stack` sind einzelne
Dependabot-PRs, davon `#1048` und `#1049` aus demselben Prisma-Release-Zug.
`templates/dependabot.yml` → `.github/dependabot.yml`, anpassen.
`package-ecosystem: github-actions` unbedingt mitnehmen, sonst frieren die SHA-Pins
aus 3.13 für immer ein.

**3.13 Supply Chain in `klubhaus-elf`.** Dort steht „Allow all actions" ohne
SHA-Pinning-Pflicht. Reihenfolge zwingend:
1. erst alle Workflows auf Full-SHA umschreiben (`uses: actions/checkout@11bd719…`)
2. **dann** „Require actions to be pinned to a full-length commit SHA" aktivieren

Umgekehrt brichst du sofort alle Workflows.

**3.14 Nightly aktivieren.**
```bash
sudo cp systemd/* /etc/systemd/system/
sudo systemctl enable --now etrox-github-nightly.timer
```
03:20 UTC: erst Backup, dann Storage-Purge, dann Invarianten. Die Reihenfolge ist
Absicht — wer vor dem Backup aufräumt, löscht ohne Netz.

---

### Phase 5 — `klubhaus-elf` privat stellen

Nico baut das Spiel mit 3–5 Leuten weiter und will es monetarisieren. Das Repo ist
aktuell public — inklusive des Obsidian-Vaults mit der kompletten Spielmechanik.

**Reihenfolge zwingend:**

1. **Vorher** die 2 offenen Semgrep-Alerts abarbeiten. Nach dem Wechsel auf private ist
   Code Scanning nicht mehr verfügbar (nur mit GHAS) und die Alerts sind unsichtbar.
2. **Vorher** prüfen und Nico berichten:
   ```bash
   ./lib/mint-token.sh ops >/dev/null && \
   gh_api ops GET /repos/EtroxTaran/klubhaus-elf/forks | jq -r '.[].full_name'
   ```
   Bestehende Forks bleiben public und verschwinden nicht mit dem Wechsel.
3. **Vorher** „Preserve this repository" (GitHub Archive Program) abschalten — der Haken
   ist aktuell gesetzt.
4. **Dann** umstellen:
   ```bash
   gh_api admin PATCH /repos/EtroxTaran/klubhaus-elf -d '{"private":true}'
   ```
5. `config/repos.yaml`: `visibility=private` eintragen, sonst meldet
   `verify-invariants.sh` jede Nacht eine Abweichung.

**Warum keine Organisation:** verifiziert aus der GitHub-Doku — *„Rulesets are available
in public repositories with GitHub Free […] and in public and private repositories with
GitHub Pro, GitHub Team, and GitHub Enterprise Cloud."* Eine **Free-Org** hätte für ein
privates Repo **keine** Rulesets und keine Branch Protection. Nicos persönlicher
Pro-Account deckt beides ab. Eine Team-Org ($4/User/Monat) brächte zusätzlich
granulare Rollen (Read/Triage/Maintain) — das ist eine Kaufentscheidung, die Nico
später trifft. Bau nichts, was sie voraussetzt.

**Was der Wechsel kostet und wie du es ersetzt:**

| Verlust | Ersatz |
|---|---|
| Secret Scanning + Push Protection | `gitleaks` als pre-commit Hook **und** im Watcher-Lauf |
| Code Scanning (Semgrep OSS) | Semgrep lokal auf bb8 — läuft dort sogar früher im Zyklus |
| Unbegrenzte Actions-Minuten | 30 min/Monat aktuell, 3.000 frei → irrelevant |

**Für das Team:** Auf einem persönlichen Account gibt es nur zwei Stufen — Owner und
Collaborator, und Collaborator heißt **immer Write**. Read-only oder Triage existiert
dort nicht. Nico weiß das und vertraut den 3–5 Leuten. Sobald jemand dazukommt, dem er
nicht voll vertraut (Tester, Zuarbeiter), melde ihm, dass jetzt der Moment für die
Team-Org ist.

---

## 4. Deine Grenzen — fünf, sonst keine

Kodiert in `config/invariants.yaml`, nächtlich geprüft, bei Verstoß Issue in `etrox-infra`.

1. **Kein Repo wird public**, das in `repos.yaml` als private geführt ist.
2. **Kein Repo wird gelöscht.** Archivieren ja. Wenn Löschen richtig scheint: Issue mit
   Begründung.
3. **`deletion` und `non_fast_forward` bleiben auf jedem Default-Branch aktiv.** Jede
   andere Regel darfst du ändern — diese zwei nicht. Sie sind der Grund, warum ein
   Fehler von dir reparierbar bleibt.
4. **Keine Classic-PATs anlegen.** Brauchst du mehr Zugriff: App-Permission erweitern
   und Nico informieren.
5. **Kein Secret ins Repo.** Für private Repos gibt es auf Pro **kein** serverseitiges
   Secret Scanning — `gitleaks` im pre-commit ist die einzige Absicherung, die existiert.

Hältst du eine Grenze für falsch: Issue mit Begründung. Nicht selbst ändern.
Das ist die einzige Stelle, an der Nico im Loop bleibt — und der Grund, warum du
überall sonst freie Hand hast.

**Das nächtliche Mirror-Backup ist die Gegenleistung für diese Freiheit.**
`/srv/backup/github/`, 30 Tage Rotation. Es macht aus „Agent hat etwas kaputtgemacht"
einen Ärger von 20 Minuten. Deshalb ist Backup-Frische selbst eine Invariante.

---

## 5. Dauerbetrieb

**Täglich, ohne Rückfrage:** Dependabot-PRs prüfen und bei grünem Check mergen ·
fehlgeschlagene CI-Runs analysieren, Fix-PR öffnen und mergen · Issues triagieren und
labeln · Artifacts > 7 Tage löschen · Mirror-Backup · Invarianten prüfen ·
Queue-Wartezeiten prüfen.

**Wöchentlich:** Ruleset-Drift gegen `rulesets/*.json` prüfen und zurückrollen · neue
Repos automatisch mit passendem Profil versehen · Kostenbericht (Storage-GB,
Compute-Minuten, Trend) als Issue in `etrox-infra`.

**Bei Bedarf:** Merge-Gates anpassen, wenn sie nachweislich falsch greifen — mit
Begründung im Commit · neue Repos anlegen (private als Default) inkl. Ruleset,
`dependabot.yml`, CI-Template.

---

## 6. Am Ende: Aufräumen bei Nico

Diese drei Dinge kannst du **nicht** über die API erledigen — sie verlangen einen
Sudo-Login im Browser. Wenn Phase 1–5 abgeschlossen sind und der Beobachtungslauf
sauber ist, öffne **ein einziges Issue** in `etrox-infra` mit dem Titel
`[nico] Abschluss-Aufräumen GitHub` und genau diesen drei Punkten:

1. **PAT „Computer claw" löschen** — <https://github.com/settings/tokens>.
   Vorher im Security-Log prüfen, ob es noch Requests macht:
   <https://github.com/settings/security-log>. Erst wenn dort seit 7 Tagen nichts mehr
   auftaucht, ist das Löschen risikofrei.
2. **SMS als 2FA-Methode entfernen** — <https://github.com/settings/security>.
   Authenticator, Passkey und GitHub Mobile sind konfiguriert; GitHub rät auf der Seite
   selbst von SMS ab (SIM-Swap, kein Phishing-Schutz).
3. **Drei ungenutzte SSH-Keys löschen** — <https://github.com/settings/keys>:
   `server` und `etrox.de -25` (seit ~8 Monaten unbenutzt) sowie den älteren der beiden
   „GitHub CLI"-Keys (Mai 2026; der Juni-Key ist aktiv).

Nicht früher melden. Nicht in Einzelmeldungen aufteilen. Ein Issue, drei Haken.

---

## 7. Was du Nico melden musst, sobald du es weißt

Vier offene Punkte aus dem Audit. Klär sie im Betrieb und berichte:

1. **Ist `ai-review/consensus` das Tor für beide Repos?** In `klubhaus-elf` sind nur
   `docs-check` und `linear-id` Required Checks — obwohl die README den AI-Review als
   „the only live auto-merge actuator" beschreibt. Wenn ja: ergänzen.
2. **War der Runner `bb8-klubhaus-elf` absichtlich weg oder abgeraucht?** Das ändert, ob
   3.7 ein Monitoring-Thema oder ein Einzelfall ist.
3. **Wofür lief „Computer claw"?** Sobald du im Security-Log siehst, welche Dienste damit
   noch zugreifen, melde die Liste — dann kann Punkt 6.1 gefahrlos passieren.
4. **Authorized OAuth Apps** (<https://github.com/settings/applications>) sowie die drei
   GitHub Apps mit ausstehenden Rechteanfragen (ChatGPT Codex Connector, Claude, Vercel)
   wurden nie geprüft — die Seite verlangt Sudo. Das ist der einzige Bereich der
   Account-Security ohne Abdeckung. Nimm ihn ins Abschluss-Issue aus Abschnitt 6 auf.
