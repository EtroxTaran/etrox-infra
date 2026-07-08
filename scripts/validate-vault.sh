#!/usr/bin/env bash
# validate-vault.sh — sanity check der ansible-vault.
# Prüft, dass alle Pflichtfelder gesetzt und plausibel sind.
# Wird automatisch von secrets-init.sh nach dem Editor-Schließen aufgerufen.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VAULT_FILE="$REPO_ROOT/inventory/group_vars/all/vault.yml"
VAULT_PW_FILE="$REPO_ROOT/.vault-password"

if [[ ! -f "$VAULT_FILE" ]]; then
    echo "FATAL: $VAULT_FILE fehlt." >&2; exit 1
fi

# vault.yml entschlüsseln (wenn encrypted) und in temp file
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
if head -1 "$VAULT_FILE" | grep -q 'ANSIBLE_VAULT'; then
    if [[ -f "$VAULT_PW_FILE" ]]; then
        ansible-vault decrypt --vault-password-file "$VAULT_PW_FILE" --output "$TMP" "$VAULT_FILE" 2>/dev/null
    else
        ansible-vault decrypt --output "$TMP" "$VAULT_FILE"
    fi
else
    cp "$VAULT_FILE" "$TMP"
fi

ERRORS=0
warn() { echo "  ⚠️  $*"; ERRORS=$((ERRORS+1)); }
ok()   { echo "  ✅ $*"; }

# Helper: extrahiere via yq (falls da) oder grep
get() {
    if command -v yq >/dev/null 2>&1; then
        yq -r ".$1 // \"\"" "$TMP" 2>/dev/null || echo ""
    else
        grep -E "^${1//./_}:" "$TMP" | head -1 | sed 's/[^:]*: *//' | tr -d '"'
    fi
}

echo "Validating $VAULT_FILE..."

# --- Pflichtfelder ---
for k in vault_tailscale_authkey vault_public_domain vault_n8n_encryption_key \
         vault_n8n_edge_encryption_key vault_n8n_webhook_shared_secret \
         vault_restic_password vault_grafana_admin_password \
         vault_surrealdb_root_password; do
    v=$(get "$k")
    if [[ -z "$v" || "$v" == *"CHANGE_ME"* || "$v" == *"GENERATE"* || "$v" == *"STRONG_PASSWORD_HERE"* ]]; then
        warn "$k ist leer oder noch ein Platzhalter"
    else
        ok "$k gesetzt"
    fi
done

# --- Format-Plausibilität ---
TG=$(get "vault_telegram.nathan_bot_token")
if [[ -n "$TG" && ! "$TG" =~ ^[0-9]+:[A-Za-z0-9_-]{20,}$ ]]; then
    warn "vault_telegram.nathan_bot_token Format unplausibel (erwartet: '123456789:AABB...')"
fi

KEY=$(get "vault_n8n_encryption_key")
if [[ -n "$KEY" && ${#KEY} -lt 32 ]]; then
    warn "vault_n8n_encryption_key zu kurz (${#KEY} chars, erwartet >=32)"
fi

KEY2=$(get "vault_n8n_edge_encryption_key")
if [[ -n "$KEY" && -n "$KEY2" && "$KEY" == "$KEY2" ]]; then
    warn "vault_n8n_encryption_key UND vault_n8n_edge_encryption_key sind identisch — Trust-Boundary verlangt unterschiedliche Keys"
fi

PAT=$(get "vault_github.pat_token")
if [[ -n "$PAT" && ! "$PAT" =~ ^gh[ps]_[A-Za-z0-9]{20,}$ ]]; then
    warn "vault_github.pat_token Format unplausibel (erwartet: ghp_... oder ghs_...)"
fi

DOMAIN=$(get "vault_public_domain")
if [[ -n "$DOMAIN" && ! "$DOMAIN" =~ ^[a-z0-9.-]+\.[a-z]+$ ]]; then
    warn "vault_public_domain Format unplausibel: '$DOMAIN'"
fi

# --- Perplexity (optional, einzige erlaubte API): nur Format-Soft-Check ---
PPLX=$(get "vault_perplexity_api_key")
if [[ -n "$PPLX" && "$PPLX" != pplx-* ]]; then
    warn "vault_perplexity_api_key gesetzt, aber kein 'pplx-...'-Format (optional, nur Hinweis)"
fi

# --- Summary ---
echo
if [[ $ERRORS -eq 0 ]]; then
    echo "✅ Vault sieht gut aus."
else
    echo "❌ $ERRORS Probleme. Bitte vault.yml anpassen ($0 erneut ausführen)."
    exit 1
fi
