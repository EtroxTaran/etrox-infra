#!/usr/bin/env bash
# secrets-init.sh — Interaktive Erstellung der Ansible-Vault.
#
# - Fragt alle Secrets ab
# - Schreibt unverschlüsselte vault.yml ins Repo
# - Verschlüsselt sie sofort mit ansible-vault
# - Speichert das Vault-Passwort in .vault-password (gitignored)
#
# Re-runs:
#   - bestehende verschlüsselte vault.yml wird zur Bearbeitung mit `ansible-vault edit` geöffnet.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VAULT_FILE="$REPO_ROOT/inventory/group_vars/all/vault.yml"
VAULT_TEMPLATE="$REPO_ROOT/inventory/group_vars/all/vault.yml.example"
VAULT_PW_FILE="$REPO_ROOT/.vault-password"

if ! command -v ansible-vault >/dev/null 2>&1; then
    echo "FATAL: ansible-vault nicht gefunden. Erst bootstrap.sh laufen lassen." >&2
    exit 1
fi

# --- Existing encrypted vault: edit mode ---------------------------------
if [[ -f "$VAULT_FILE" ]] && head -1 "$VAULT_FILE" | grep -q 'ANSIBLE_VAULT'; then
    echo "Verschlüsselte vault.yml existiert bereits. Öffne im Editor..."
    if [[ -f "$VAULT_PW_FILE" ]]; then
        ansible-vault edit --vault-password-file "$VAULT_PW_FILE" "$VAULT_FILE"
    else
        ansible-vault edit "$VAULT_FILE"
    fi
    exit 0
fi

# --- First-run: create vault password ------------------------------------
echo "Setze ein Vault-Passwort. Wird in .vault-password gespeichert (gitignored)."
read -rsp "Vault password: " VAULT_PW; echo
read -rsp "Repeat:         " VAULT_PW2; echo
[[ "$VAULT_PW" != "$VAULT_PW2" ]] && { echo "Passwörter unterschiedlich, abbruch." >&2; exit 1; }

umask 077
echo "$VAULT_PW" > "$VAULT_PW_FILE"
unset VAULT_PW VAULT_PW2

# --- Copy template -------------------------------------------------------
if [[ ! -f "$VAULT_FILE" ]]; then
    cp "$VAULT_TEMPLATE" "$VAULT_FILE"
    chmod 600 "$VAULT_FILE"
fi

cat <<EOF

Die vault.yml wurde aus der Vorlage erstellt. Öffne sie jetzt im Editor und
trage ALLE Secrets ein. Wichtigster Wert: vault_n8n_encryption_key
muss EXAKT übereinstimmen mit /home/clawd/.n8n/config:.encryptionKey auf R2D2.

Drücke Enter um den Editor zu öffnen (\$EDITOR oder vi)...
EOF
read -r

"${EDITOR:-vi}" "$VAULT_FILE"

# --- Validate before encrypting ------------------------------------------
if [[ -x "$REPO_ROOT/scripts/validate-vault.sh" ]]; then
    if ! "$REPO_ROOT/scripts/validate-vault.sh"; then
        echo
        echo "Validierung fehlgeschlagen. vault.yml ist noch UNVERSCHLÜSSELT — du kannst sie weiter bearbeiten:"
        echo "    \$EDITOR $VAULT_FILE"
        echo "    ./scripts/secrets-init.sh    # erneut zum Verschlüsseln"
        exit 1
    fi
fi

# --- Encrypt -------------------------------------------------------------
ansible-vault encrypt --vault-password-file "$VAULT_PW_FILE" "$VAULT_FILE"

echo "✅ vault.yml verschlüsselt. Bearbeiten künftig mit:"
echo "    ./scripts/secrets-init.sh   (oder)   ansible-vault edit $VAULT_FILE"
