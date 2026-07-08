#!/usr/bin/env bash
# preflight.sh — Was VOR dem `git clone` gemacht werden muss.
# Installiert das Allernötigste, damit du das (private) Repo klonen kannst.
#
# Verwendung auf einem frisch installierten Ubuntu 24.04:
#   sudo apt update && sudo apt install -y curl
#   curl -fsSL https://raw.githubusercontent.com/EtroxTaran/ai-server-provisioning/main/preflight.sh | bash
#
# (Das Repo ist privat — der Inhalt von preflight.sh wird daher nur sichtbar,
#  wenn du eingeloggt bist oder das Repo public gemacht wurde. Alternative:
#  diesen File aus einem Gist holen oder per scp/USB rüberkopieren.)

set -euo pipefail
log() { echo "[preflight] $*"; }

if [[ "$(id -u)" -eq 0 ]]; then
    echo "Bitte NICHT als root, sondern als regulärer sudo-fähiger User." >&2
    exit 1
fi

log "1/4  apt update + git, curl, jq"
sudo apt update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl wget jq ca-certificates gnupg

log "2/4  GitHub CLI (gh)"
if ! command -v gh >/dev/null 2>&1; then
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg status=none
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq gh
fi
log "    gh: $(gh --version | head -1)"

log "3/4  GitHub login (interaktiv, einmalig)"
if gh auth status >/dev/null 2>&1; then
    log "    bereits angemeldet als $(gh api user -q .login)"
else
    echo
    echo "→ Es öffnet sich ein Browser-Login. Wähle:"
    echo "  • GitHub.com"
    echo "  • HTTPS"
    echo "  • Yes (Authenticate Git)"
    echo "  • Login with a web browser"
    echo
    gh auth login --hostname github.com --git-protocol https --web \
        --scopes "repo,workflow,admin:org_hook,read:org"
fi

log "4/4  Repo klonen"
TARGET="$HOME/ai-server-provisioning"
if [[ -d "$TARGET/.git" ]]; then
    log "    existiert schon, ziehe pull..."
    git -C "$TARGET" pull --ff-only
else
    gh repo clone EtroxTaran/ai-server-provisioning "$TARGET"
fi

cat <<EOF

✅ Preflight fertig.

Weitermachen:
    cd ~/ai-server-provisioning
    ./bootstrap.sh

Nach bootstrap.sh dann:
    claude login                # einmalig OAuth
    claude                      # → liest CLAUDE.md, führt dich durch alle Phasen
EOF
