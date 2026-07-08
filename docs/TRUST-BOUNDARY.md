# Trust Boundary

## Kernregel

> **Private Daten und Agent Control bleiben lokal (AI-Server). Remote UI/API
> läuft auf Hetzner. Integration über typisierte Contracts via Tailscale.**

## Was lebt wo?

| Datentyp | Sensitivity | Standort | Backup | Remote-Sync |
|---|---|---|---|---|
| Obsidian Vault `personal-reflection` | 🔴 lock | AI-Server only | restic local | NIE |
| Vault `nico-operations` | 🔴 high | AI-Server only | restic + Drive | NIE |
| Vault `sabine-jobs-design` | 🔴 high | AI-Server only | restic + Drive | NIE |
| Vault `family-business` | 🟠 mid | AI-Server only | restic + Drive | nur Metadaten |
| Vault `real-estate-knowledge` | 🟠 mid | AI-Server only | restic | Index only |
| Vault `research-core` | 🟢 low | AI-Server + Git | restic + git push | read-only Sync |
| Vault `claude-code-research` | 🟢 low | AI-Server + Git | restic + git push | read-only Sync |
| OpenClaw / Agent Memory | 🔴 high | AI-Server only | restic | NIE |
| Agent OAuth Tokens, API Keys | 🔴 high | AI-Server (Vault.yml) | restic | NIE |
| n8n-private Credentials | 🔴 high | AI-Server (encrypted) | restic | NIE |
| n8n-edge Credentials | 🟢 low | Hetzner (encrypted, separate Key) | Dokploy | NIE |
| SurrealDB Vault-Index | 🟠 mid | AI-Server only | restic | NIE |
| SurrealDB Plugin-Namespaces | 🟢 low | Hetzner | Dokploy | – |
| Better Auth User-DB | 🟠 mid | Hetzner Postgres | Dokploy | – |
| Code-Repos | 🟢 low | GitHub + AI-Server clone | git | – |
| Build artifacts (node_modules, dist) | 🟢 low | AI-Server `/data/builds` | – | – |
| Smart-Home (HomeAssistant) | 🟠 mid | R2D2 only | local | – |

## Verbotene Verbindungen

- **Hetzner darf nicht** direkt auf SurrealDB-Vault-Index, Vaults, OAuth-Stores zugreifen.
- **n8n-edge darf nicht** mit dem `vault_n8n_encryption_key` der Private-Instanz konfiguriert werden — separater `vault_n8n_edge_encryption_key`.
- **Vault-Dateien dürfen nicht** in Hetzner-Container gemountet werden.
- **Public-Endpoints** dürfen keine OAuth-Token-Exchanges für Agent-Stores ausführen — nur User-Logins (Better Auth) sind public.

## Erlaubte Verbindungen

- AI-Server → Hetzner (Tailscale): Portal-API für Plugin-Daten, ghcr-pulls, Deployments
- Hetzner → AI-Server (Tailscale, Port 5678): Webhook-Forward zu n8n-private, mit Shared-Secret-Header
- R2D2 → Tailnet: nur SSH (Owner)
- Local-LAN → AI-Server: SSH (Owner)
- Public → Hetzner: 80/443 für Portal/API/Webhooks; KEIN direkter Zugriff auf 3000 (Dokploy admin)

## Write-Path zu Vaults (immer)

```
Intent (Agent oder Portal)
  ↓
MCP-Server / vaultctl API (typisiert, mit API-Key aus Ansible-Vault)
  ↓
Tier-Policy-Check (vault-policy.yml: low=write, mid=read, high=read-only ausser admin, lock=verboten)
  ↓
Frontmatter-Validation
  ↓
git commit (audit trail bleibt lokal)
  ↓
optional SurrealDB-Index update
```

Direkter Filesystem-Write ohne diese Kette ist Verstoß gegen die Trust-Boundary.

## Audit-Trail

- `/data/vaults/.audit.jsonl` — vaultctl write events
- `journalctl -u ollama` — alle Modell-Calls (mit OLLAMA_KEEP_ALIVE)
- n8n execution log (in Postgres)
- restic snapshot list — Backup-Verlauf

## Wenn etwas leakt

1. SSH-Zugang sperren: `tailscale set --shields-up=true`
2. Tailscale ACL anpassen, Tag-Owner reduzieren
3. Affekted Tokens in Vault rotieren: `./scripts/secrets-init.sh`
4. n8n-Encryption-Key NICHT rotieren — würde alle Credentials zerstören;
   stattdessen alle Credentials einzeln neu eingeben.
