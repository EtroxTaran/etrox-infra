# etrox-github-ops

GitHub-Verwaltung für `EtroxTaran`, ausgeführt vom lokalen Agenten auf `bb8`.
Basis: vollständiges Audit der Account- und Repo-Einstellungen vom 28.07.2026.

**Einstieg: [`AGENT-AUFTRAG.md`](AGENT-AUFTRAG.md).** Dort steht alles — Bootstrap,
Aufgaben, Grenzen, Dauerbetrieb. Kein Schritt darin verlangt einen Menschen.

---

## Voraussetzung

Genau eine: die beiden App-Keys liegen auf bb8.

```
~/.config/etrox/ops.pem      etrox-ops-bb8   (App 4413799, Installation 149552788)
~/.config/etrox/admin.pem    etrox-admin-bb8 (App 4413819, Installation 149553563)
```

Beide Apps sind bereits angelegt, mit Keys versehen und auf **alle** Repositories
installiert — inklusive künftiger. Es ist nichts mehr zu registrieren.

Fehlen die `.pem`-Dateien, bricht `ops/verify-setup.sh` mit klarer Meldung ab.

## Ablage

```
~/etrox-github-ops/            dieses Bundle (gehört versioniert nach etrox-infra)
~/.config/etrox/github.env     IDs — legt der Agent in Schritt 0 selbst an
/srv/backup/github/            nächtliche Mirrors
/opt/actions-runner/           Runner-Binaries
```

## Struktur

| Pfad | Zweck |
|---|---|
| `AGENT-AUFTRAG.md` | **Der Auftrag.** Vollständig, ohne manuelle Schritte |
| `lib/mint-token.sh` | Installation-Tokens prägen (1 h), `gh_api`-Wrapper |
| `lib/list-repos.sh` | Einzige Parsing-Stelle für `repos.yaml` |
| `rulesets/*.json` | Merge-Gates als Code, App-IDs eingetragen. **Darf der Agent ändern.** |
| `rulesets/apply-rulesets.sh` | Rollt Rulesets idempotent aus (nutzt admin-Key) |
| `ops/verify-setup.sh` | Prüft das App-Setup inkl. Rechtetrennung |
| `ops/storage-cleanup.sh` | Der Kostenfix: Retention + Artifact-Purge |
| `ops/register-runner.sh` | Runner-Status, wartende Jobs, Registrierung |
| `ops/backup-mirror.sh` | Nächtliche Mirrors — Grundlage der Autonomie |
| `ops/verify-invariants.sh` | Prüft die fünf Grenzen, öffnet bei Verstoß ein Issue |
| `config/repos.yaml` | Repo → Profil, Owner, Soll-Sichtbarkeit |
| `config/invariants.yaml` | Die fünf Grenzen. **Darf der Agent nicht ändern.** |
| `templates/` | `dependabot.yml` mit Gruppen, CI mit Timeout/Retention/SHA-Pins |
| `systemd/` | Nightly-Timer (Backup → Purge → Invarianten) |

## Das Wesentliche in zwei Sätzen

**Der Agent darf die Merge-Gates selbst definieren** — sie liegen als JSON in `rulesets/`.
**Er darf `config/invariants.yaml` nicht ändern:** keine Visibility-Wechsel, keine
Repo-Löschung, `deletion` und `non_fast_forward` bleiben aktiv, keine Classic-PATs,
keine Secrets im Repo. Hält er eine Grenze für falsch — Issue mit Begründung.
