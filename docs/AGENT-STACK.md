# Agent-Stack — Hermes + Subscription-CLIs

Die KI-/Agent-Schicht des Servers. Aufgesetzt von `roles/22_agent_stack`.

## Entscheidung: Hermes statt OpenClaw

**Hermes Agent (Nous Research)** löst **OpenClaw** als Orchestrierungs-Layer ab:

- **Zukunftssicherheit & Momentum**: schnellst wachsendes Open-Source-Agent-Framework 2026,
  MIT-Lizenz.
- **Sicherheit**: keine bekannten Agent-CVEs; OpenClaw hatte **CVE-2026-25253 (CVSS 8.8)**.
  Hermes v0.13: Secret-Redaction default-on, MCP-OAuth 2.1.
- **Selbstlernend**: geschlossene Skill-Loop (agentskills.io), 3-Schicht-Memory
  (`MEMORY.md`/`USER.md` + SQLite-FTS + pluggable external memory).
- **Robustheit**: durable Kanban, Zombie-Detection, `/goal` gegen Context-Drift.
- **Browser-Automation** out-of-the-box (Browser Use + Firecrawl) → siehe
  [`AGENT-BROWSER.md`](AGENT-BROWSER.md).
- **Migration eingebaut**: `hermes claw migrate` übernimmt die OpenClaw-Fleet
  (Nathan/Lisa/Riker/Spock/Dax).

Mentales Modell: **Hermes orchestriert** (always-on, multichannel, Memory, Routing) und ist
**kein** Coding-Tool — die eigentliche Modell-/Coding-Arbeit delegiert es an die CLIs unten.

## Subscriptions statt API-Abrechnung

Ziel: KI-Nutzung läuft über **Abos** (OAuth-Login), nicht über pay-per-token-APIs.
Einzige bewusste Ausnahme: **Perplexity** (API erlaubt, für Suche/Recherche).

| CLI | Abo-Login | genutztes Abo |
|---|---|---|
| **Claude Code** (`claude`) | `claude login` | Claude **Max** (Default-Coder) |
| **Codex** (`codex`) | „Sign in with ChatGPT" | ChatGPT **Plus/Pro** (privat!) |
| **Cursor** (`cursor-agent`) | `cursor-agent login` | Cursor **Pro** |
| **Gemini** (`gemini`) | Google-Login | Google AI |
| **Grok Build** (`grok`) | `grok login` | **SuperGrok / X Premium+** (Beta) |

**KRITISCH — kein API-Billing:** Für den `agent`-User dürfen **keine** `*_API_KEY`-Env-Vars
gesetzt sein (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, `XAI_API_KEY`,
`GROK_CODE_XAI_API_KEY`, …). Sonst schalten die CLIs auf API-Abrechnung um. `roles/22_agent_stack`
schreibt einen Guard in `~agent/.profile`, der diese Variablen defensiv `unset`t.
Prüfen: `claude` / `codex` / `grok` Status muss „signed in / subscription" zeigen.

> ⚠️ ChatGPT **Team/Enterprise** unterstützt den Codex-Abo-Login NICHT — privates Plus/Pro nötig.
> Grok Build ist **early beta**.

### Perplexity — die eine erlaubte API

Suche/Recherche läuft über die **Perplexity-API** (`vault_perplexity_api_key`, Quelle:
https://www.perplexity.ai/settings/api). Das ist die **einzige** bewusste Ausnahme von der
Subscription-only-Regel. Die Modell-API-Keys (`vault_anthropic_api_key`, `vault_openai_api_key`,
`vault_google_ai_api_key`) bleiben im Vault standardmäßig **leer** und sind nur für den Fall
gedacht, dass ein einzelner n8n-Workflow/Tool einen Key braucht — sie dürfen **nie** in den
Shell-Env des `agent`-Users gelangen (sonst laufen die Coding-CLIs auf API-Billing statt Abo).
Der Guard in `roles/22_agent_stack` (`unset …` in `~agent/.profile`) und der `verify.yml`-Check
erzwingen das.

## Delegation & Routing

- **Default-Coder = Claude Code.** Hermes ruft die CLIs headless als Tools/ACP-Agents:
  `claude -p "…"`, `codex exec`, `grok -p "…"`, `cursor-agent …`.
- **Ollama** ist der Gratis-Provider für Hintergrund-/Routing-/Klassifikations-Tasks
  (kostet nichts, läuft lokal auf der GPU — weicht aber bei `gpu-heavy.target`).
- **Perplexity-MCP** für Web-Suche/Recherche.
- Bei Abo-Rate-Limit kann Hermes auf eine andere CLI / Ollama umrouten.

## Caveats (akzeptiert)

- Abo-Rate-Limits (Claude Max gibt den höchsten Durchsatz).
- Dauerbetrieb von Abo-CLIs durch einen Orchestrator ist eine **ToS-Grauzone**.
- Grok Build = Beta → einzelne Pakete dürfen fehlen (Rolle ist `failed_when: false`).

## State & Backup

- Hermes-State: `/data/agent/hermes` (restic-gesichert).
- Chrome-Profil der Agent-Session: `/data/agent/chrome` (Login-Cookies; standardmäßig
  nicht im Backup).
