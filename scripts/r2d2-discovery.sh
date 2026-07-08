#!/usr/bin/env bash
# r2d2-discovery.sh — Read-only Inventar von R2D2.
#
# Ausführen ON R2D2 (lokal oder via SSH):
#   ssh clawd@192.168.1.12 'bash -s' < scripts/r2d2-discovery.sh > inventory/r2d2-snapshot.json
#
# Sammelt: Users, Container, n8n encryptionKey, Vaults, installierte CLIs, Crons.
# Schreibt KEINE Tokens, nur deren Hashes (für Verifikation in der Migration).

set -euo pipefail

emit() { jq -n "$@"; }
hash() { sha256sum 2>/dev/null | awk '{print $1}'; }

if ! command -v jq >/dev/null 2>&1; then
    echo '{"error":"jq missing on R2D2 — sudo apt install jq"}'
    exit 1
fi

# --- gather --------------------------------------------------------------

HOSTNAME_VAL="$(hostname)"
KERNEL="$(uname -r)"
DISTRO="$(lsb_release -ds 2>/dev/null || echo unknown)"

USERS_JSON="$(awk -F: '$3 >= 1000 && $3 < 65000 {printf "{\"name\":\"%s\",\"uid\":%s,\"home\":\"%s\",\"shell\":\"%s\"}\n", $1, $3, $6, $7}' /etc/passwd | jq -s .)"

DOCKER_PS="$(docker ps --format '{{json .}}' 2>/dev/null | jq -s . || echo '[]')"
DOCKER_VOLS="$(docker volume ls --format '{{.Name}}' 2>/dev/null | jq -R . | jq -s . || echo '[]')"
DOCKER_NETS="$(docker network ls --format '{{.Name}}' 2>/dev/null | jq -R . | jq -s . || echo '[]')"

TAILSCALE_STATUS="$(tailscale status --json 2>/dev/null || echo '{}')"

# n8n encryption key (kritisch für Migration!)
N8N_KEY=""
N8N_KEY_HASH=""
if [[ -f /home/clawd/.n8n/config ]]; then
    N8N_KEY="$(jq -r .encryptionKey /home/clawd/.n8n/config 2>/dev/null || true)"
    N8N_KEY_HASH="$(echo -n "$N8N_KEY" | hash)"
fi

# Vaults: nur Namen + Größe + git status
VAULTS_JSON="[]"
if [[ -d /home/clawd/vaults ]]; then
    VAULTS_JSON="$(for v in /home/clawd/vaults/*/; do
        [[ -d "$v" ]] || continue
        name="$(basename "$v")"
        size="$(du -sb "$v" | awk '{print $1}')"
        has_git=$([[ -d "$v/.git" ]] && echo true || echo false)
        commits=$([[ -d "$v/.git" ]] && (cd "$v" && git rev-list --count HEAD 2>/dev/null) || echo 0)
        printf '{"name":"%s","size_bytes":%s,"git":%s,"commits":%s}\n' "$name" "$size" "$has_git" "$commits"
    done | jq -s .)"
fi

# OpenClaw workspace
OPENCLAW_JSON="{}"
if [[ -d /home/clawd/.openclaw/workspace ]]; then
    OPENCLAW_JSON="$(jq -n \
        --arg path "/home/clawd/.openclaw/workspace" \
        --arg files "$(find /home/clawd/.openclaw/workspace -maxdepth 2 -type f 2>/dev/null | wc -l)" \
        --arg memory_size "$(du -sh /home/clawd/.openclaw/workspace/memory 2>/dev/null | awk '{print $1}')" \
        --arg reports_count "$(find /home/clawd/.openclaw/workspace/reports -name '*.md' 2>/dev/null | wc -l)" \
        '{path:$path, total_files:($files|tonumber), memory_size:$memory_size, reports_count:($reports_count|tonumber)}')"
fi

# Installierte CLIs
declare -a CLIS=(claude codex cursor gemini gh gcloud gog node bun pnpm npm python3 ansible tailscale docker pm2 restic rclone)
CLI_JSON="$(for c in "${CLIS[@]}"; do
    if command -v "$c" >/dev/null 2>&1; then
        ver="$($c --version 2>/dev/null | head -1 | tr -d '\n' || echo unknown)"
        path="$(command -v "$c")"
        printf '{"name":"%s","version":"%s","path":"%s"}\n' "$c" "${ver//\"/\\\"}" "$path"
    fi
done | jq -s .)"

# CLI configs presence
CLI_CFG_JSON="$(for cfg in .claude .codex .cursor .gemini .config/gh .config/gcloud .config/gog .gnupg .ssh .npmrc .gitconfig; do
    p="/home/clawd/$cfg"
    [[ -e "$p" ]] && printf '{"path":"%s","size_kb":%s}\n' "$cfg" "$(du -sk "$p" 2>/dev/null | awk '{print $1}')"
done | jq -s .)"

# Crontab clawd
CRONTAB="$(crontab -l 2>/dev/null | jq -Rs . || echo '""')"

# Projects
PROJECTS_JSON="$([[ -d /home/clawd/projects ]] && ls -1 /home/clawd/projects/ | jq -R . | jq -s . || echo '[]')"

# --- emit ----------------------------------------------------------------

jq -n \
    --arg hostname "$HOSTNAME_VAL" \
    --arg kernel "$KERNEL" \
    --arg distro "$DISTRO" \
    --argjson users "$USERS_JSON" \
    --argjson docker_ps "$DOCKER_PS" \
    --argjson docker_volumes "$DOCKER_VOLS" \
    --argjson docker_networks "$DOCKER_NETS" \
    --argjson tailscale "$TAILSCALE_STATUS" \
    --arg n8n_encryption_key "$N8N_KEY" \
    --arg n8n_encryption_key_sha256 "$N8N_KEY_HASH" \
    --argjson vaults "$VAULTS_JSON" \
    --argjson openclaw "$OPENCLAW_JSON" \
    --argjson clis "$CLI_JSON" \
    --argjson cli_configs "$CLI_CFG_JSON" \
    --argjson projects "$PROJECTS_JSON" \
    --argjson crontab "$CRONTAB" \
    --arg discovered_at "$(date -u +%FT%TZ)" \
    '{
        meta: {discovered_at:$discovered_at, hostname:$hostname, kernel:$kernel, distro:$distro},
        users: $users,
        docker: {containers:$docker_ps, volumes:$docker_volumes, networks:$docker_networks},
        tailscale: $tailscale,
        n8n: {encryption_key:$n8n_encryption_key, encryption_key_sha256:$n8n_encryption_key_sha256},
        vaults: $vaults,
        openclaw: $openclaw,
        clis: $clis,
        cli_configs: $cli_configs,
        projects: $projects,
        crontab: $crontab
    }'
