#!/usr/bin/env bash
# bootstrap.sh — Phase 0: Bringt einen frischen Ubuntu 24.04 LTS auf den Stand,
# ab dem Claude Code + Ansible das restliche Provisioning übernehmen können.
# Idempotent: kann beliebig oft erneut aufgerufen werden.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_PREFIX="[bootstrap]"

log()  { echo "$LOG_PREFIX $*"; }
warn() { echo "$LOG_PREFIX WARN: $*" >&2; }
die()  { echo "$LOG_PREFIX FATAL: $*" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1; }

# --- Sanity Checks ---------------------------------------------------------

if [[ "$(id -u)" -eq 0 ]]; then
    die "Bitte NICHT als root ausführen — als regulärer User mit sudo-Rechten."
fi

if ! require_cmd sudo; then
    die "sudo ist nicht installiert. Erst: 'su -c \"apt install sudo && usermod -aG sudo $USER\"'"
fi

if [[ ! -f /etc/os-release ]]; then
    die "Kein /etc/os-release — wahrscheinlich kein Ubuntu."
fi
. /etc/os-release
if [[ "$ID" != "ubuntu" ]]; then
    warn "Nicht-Ubuntu erkannt: $ID. Fortsetzung auf eigene Gefahr."
fi
if [[ "${VERSION_ID%%.*}" -lt 22 ]]; then
    die "Ubuntu < 22.04 wird nicht unterstützt. Erkannt: $VERSION_ID"
fi
log "OS: $PRETTY_NAME"

# Hardware-Plausibilität (warn-only, weil VMs zum Testen ok sind)
CPU_COUNT="$(nproc)"
MEM_GB="$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo)"
log "CPU=${CPU_COUNT} cores, RAM=${MEM_GB}GB"
if [[ "$MEM_GB" -lt 16 ]]; then
    warn "Weniger als 16 GB RAM — ein paar Rollen (ollama, n8n) werden klemmen."
fi

# GPU (nicht zwingend in Phase 0, NVIDIA wird erst in Role 04 installiert)
if lspci | grep -qi 'NVIDIA'; then
    log "NVIDIA-GPU erkannt: $(lspci | grep -i NVIDIA | head -1 | sed 's/.*: //')"
else
    warn "Keine NVIDIA-GPU sichtbar. Ollama+DaVinci-Rollen werden mit --skip-tags nvidia,davinci genutzt."
fi

# --- Pakete ---------------------------------------------------------------

log "apt update + base packages..."
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    git curl wget ca-certificates gnupg lsb-release \
    build-essential python3 python3-venv python3-pip pipx \
    rsync openssh-client jq yq unzip software-properties-common

# pipx PATH (für aktuelle Shell)
pipx ensurepath >/dev/null 2>&1 || true
export PATH="$HOME/.local/bin:$PATH"

# --- Node.js LTS via NodeSource ------------------------------------------

if ! require_cmd node || [[ "$(node -v 2>/dev/null | sed 's/v//;s/\..*//')" -lt 20 ]]; then
    log "Node.js LTS via NodeSource installieren..."
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    sudo apt-get install -y -qq nodejs
else
    log "Node.js bereits vorhanden: $(node -v)"
fi

# --- Claude Code CLI ------------------------------------------------------

if ! require_cmd claude; then
    log "Claude Code CLI installieren..."
    sudo npm install -g @anthropic-ai/claude-code
else
    log "Claude Code bereits vorhanden: $(claude --version 2>/dev/null || echo unknown)"
fi

# --- Ansible --------------------------------------------------------------

if ! require_cmd ansible; then
    log "Ansible via pipx installieren..."
    pipx install --include-deps ansible-core
else
    log "Ansible bereits vorhanden: $(ansible --version | head -1)"
fi

if [[ -f "$REPO_ROOT/requirements.yml" ]]; then
    log "Ansible-Collections installieren..."
    ansible-galaxy collection install -r "$REPO_ROOT/requirements.yml" >/dev/null
fi

# --- GitHub CLI -----------------------------------------------------------

if ! require_cmd gh; then
    log "GitHub CLI installieren..."
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq gh
else
    log "gh bereits vorhanden: $(gh --version | head -1)"
fi

# --- Tailscale ------------------------------------------------------------

if ! require_cmd tailscale; then
    log "Tailscale installieren..."
    curl -fsSL https://tailscale.com/install.sh | sh
else
    log "Tailscale bereits vorhanden: $(tailscale version | head -1)"
fi

# --- ansible-vault Passwort-Datei (Stub) ----------------------------------

VAULT_PW_FILE="$REPO_ROOT/.vault-password"
if [[ ! -f "$VAULT_PW_FILE" ]]; then
    log "WARN: Keine $VAULT_PW_FILE gefunden — wird beim ersten 'secrets-init.sh' angelegt."
fi

# --- Abschluss ------------------------------------------------------------

cat <<EOF

$LOG_PREFIX ✅ Bootstrap abgeschlossen.

Nächste Schritte:

  1. claude login                      # OAuth-Flow im Browser

  2. claude                            # Session starten und einfach sagen:

       "Lies docs/ARCHITECTURE.md und docs/MIGRATION-RUNBOOK.md.
        Führe scripts/secrets-init.sh interaktiv aus, danach
        playbooks/site.yml — Schritt für Schritt mit Bestätigung."

  Alternativ direkt:

  3. ./scripts/secrets-init.sh         # Secrets in Ansible-Vault legen
  4. ansible-playbook -i inventory/hosts.yml playbooks/site.yml \\
        --ask-vault-pass --check --diff           # Trockenlauf
  5. # Wenn ok, ohne --check echt ausführen.

EOF
