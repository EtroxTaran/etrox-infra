#!/usr/bin/env bash
# Prägt ein GitHub-App-Installation-Token (gültig 1 h).
#
#   source lib/mint-token.sh
#   TOKEN=$(mint_token ops)     # oder: mint_token admin
#
# Kein Netzwerk-Dienst, keine gespeicherten Tokens: der Key bleibt auf der Platte,
# das Token lebt nur im Prozess. Deshalb muss nie etwas rotiert werden.
set -euo pipefail

: "${ETROX_ENV:=$HOME/.config/etrox/github.env}"
# shellcheck disable=SC1090
[ -f "$ETROX_ENV" ] && . "$ETROX_ENV"

_b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# _pem_source <role> <pem_path> — PEM nach stdout.
# Klartext, falls vorhanden; sonst sops-Decrypt von <pem_path>.enc mit dem
# rollen-eigenen age-Key (getrennte Recipients pro App, at-rest verschluesselt).
_pem_source() {
  local role="$1" pem="$2"
  if [ -r "$pem" ]; then cat "$pem"; return 0; fi
  if [ -r "${pem}.enc" ]; then
    SOPS_AGE_KEY_FILE="${ETROX_AGE_DIR:-$HOME/.config/etrox/age}/${role}.agekey" \
      sops decrypt --input-type binary --output-type binary "${pem}.enc"
    return $?
  fi
  echo "mint-token: Key nicht lesbar: $pem (auch ${pem}.enc fehlt)" >&2
  return 3
}

# _app_jwt <role> <app_id> <pem_path>
_app_jwt() {
  local role="$1" app_id="$2" pem="$3" now header payload h p sig
  now=$(date +%s)
  header='{"alg":"RS256","typ":"JWT"}'
  # iat 60 s in der Vergangenheit federt Uhrendrift ab; exp max. 10 min laut GitHub
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$app_id")
  h=$(printf '%s' "$header"  | _b64url)
  p=$(printf '%s' "$payload" | _b64url)
  sig=$(printf '%s' "$h.$p" | openssl dgst -sha256 -binary -sign <(_pem_source "$role" "$pem") | _b64url)
  printf '%s.%s.%s' "$h" "$p" "$sig"
}

# mint_token <ops|admin> [personal|org]
# Zweiter Parameter waehlt die Installation: persoenlicher Account oder Org coding-x.
# Beide zeigen auf dieselbe App und denselben Key — nur die Installation unterscheidet sich.
mint_token() {
  local role="${1:-ops}" scope="${2:-personal}" app_id inst_id pem jwt resp token

  case "$role" in
    ops)   app_id="${OPS_APP_ID:?OPS_APP_ID fehlt in github.env}"
           pem="${OPS_PEM:?OPS_PEM fehlt}"
           if [ "$scope" = "org" ]; then inst_id="${OPS_INSTALLATION_ID_ORG:?OPS_INSTALLATION_ID_ORG fehlt — App in der Org installiert?}"
           else                          inst_id="${OPS_INSTALLATION_ID:?OPS_INSTALLATION_ID fehlt}"; fi ;;
    admin) app_id="${ADMIN_APP_ID:?ADMIN_APP_ID fehlt in github.env}"
           pem="${ADMIN_PEM:?ADMIN_PEM fehlt}"
           if [ "$scope" = "org" ]; then inst_id="${ADMIN_INSTALLATION_ID_ORG:?ADMIN_INSTALLATION_ID_ORG fehlt}"
           else                          inst_id="${ADMIN_INSTALLATION_ID:?ADMIN_INSTALLATION_ID fehlt}"; fi ;;
    *)     echo "mint_token: unbekannte Rolle '$role' (erlaubt: ops, admin)" >&2; return 2 ;;
  esac

  # Owner -> Scope: hilft Aufrufern, die nur den Repo-Owner kennen
  :

  [ -r "$pem" ] || [ -r "${pem}.enc" ] || { echo "mint_token: Key nicht lesbar: $pem (auch .enc fehlt)" >&2; return 3; }

  jwt=$(_app_jwt "$role" "$app_id" "$pem")
  resp=$(curl -sS -X POST \
      -H "Authorization: Bearer $jwt" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/app/installations/${inst_id}/access_tokens")

  token=$(printf '%s' "$resp" | jq -r '.token // empty')
  if [ -z "$token" ]; then
    echo "mint_token: kein Token erhalten. Antwort:" >&2
    printf '%s\n' "$resp" | jq . >&2 || printf '%s\n' "$resp" >&2
    return 4
  fi
  printf '%s' "$token"
}

# gh_app_api <role> <method> <path> [curl-args...]
# App-JWT-Auth — noetig fuer /app/*-Endpunkte, die kein Installation-Token akzeptieren.
gh_app_api() {
  local role="$1" method="$2" path="$3"; shift 3
  local app_id pem jwt
  case "$role" in
    ops)   app_id="${OPS_APP_ID:?OPS_APP_ID fehlt in github.env}";   pem="${OPS_PEM:?OPS_PEM fehlt}" ;;
    admin) app_id="${ADMIN_APP_ID:?ADMIN_APP_ID fehlt in github.env}"; pem="${ADMIN_PEM:?ADMIN_PEM fehlt}" ;;
    *)     echo "gh_app_api: unbekannte Rolle '$role' (erlaubt: ops, admin)" >&2; return 2 ;;
  esac
  [ -r "$pem" ] || [ -r "${pem}.enc" ] || { echo "gh_app_api: Key nicht lesbar: $pem (auch .enc fehlt)" >&2; return 3; }
  jwt=$(_app_jwt "$role" "$app_id" "$pem")
  curl -sS -X "$method" \
    -H "Authorization: Bearer $jwt" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com${path}" "$@"
}

# scope_for_owner <owner>  ->  "org" | "personal"
scope_for_owner() {
  if [ -n "${GITHUB_ORG:-}" ] && [ "$1" = "$GITHUB_ORG" ]; then echo org; else echo personal; fi
}

# gh_api <role> <method> <path> [curl-args...]
# Beispiel: gh_api ops GET "/repos/EtroxTaran/x-ai-stack"
# Der Scope wird aus dem Owner im Pfad abgeleitet.
gh_api() {
  local role="$1" method="$2" path="$3"; shift 3
  local owner scope token
  owner="$(printf '%s' "$path" | sed -n 's#^/repos/\([^/]*\)/.*#\1#p')"
  scope="$(scope_for_owner "${owner:-$GITHUB_OWNER}")"
  token=$(mint_token "$role" "$scope")
  curl -sS -X "$method" \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com${path}" "$@"
}

# Direkt aufgerufen statt gesourct → Token auf stdout (praktisch für `gh` via GH_TOKEN)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  mint_token "${1:-ops}"; echo
fi
