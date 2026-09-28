#!/usr/bin/env bash
# Prüft, ob das App-Setup korrekt ist. Muss grün sein, bevor der Agent übernimmt.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "$HERE")"
# shellcheck source=../lib/mint-token.sh
. "$ROOT/lib/mint-token.sh"
# mint-token.sh setzt beim Sourcen -e; dieses Skript sammelt Befunde und darf
# bei einem roten Check nicht abbrechen.
set +e

fail=0
ok()   { printf '  \033[32mok\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31m!!\033[0m  %s\n' "$1"; fail=1; }
info() { printf '      %s\n' "$1"; }

check_app() {  # check_app <role> <scope> <erwarte_admin: yes|no>
  local role="$1" scope="$2" want_admin="$3" tok perms n
  echo; echo "[$role / $scope]"

  if ! tok="$(mint_token "$role" "$scope" 2>/dev/null)"; then
    bad "Token konnte nicht geprägt werden — App-ID, Installation-ID oder Key prüfen"; return
  fi
  ok "Token geprägt (gültig 1 h)"

  local resp; resp="$(curl -sS -H "Authorization: Bearer $tok" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/installation/repositories?per_page=1")"

  n="$(printf '%s' "$resp" | jq -r '.total_count // empty')"
  if [ -n "$n" ] && [ "$n" -gt 0 ]; then ok "Zugriff auf $n Repositories"
  else bad "Keine Repositories sichtbar — ist die App auf 'All repositories' installiert?"; fi

  # Permissions der Installation gegenprüfen — /app/installations verlangt App-JWT-Auth
  perms="$(gh_app_api "$role" GET "/app/installations" 2>/dev/null \
    | jq -c 'if type=="array" then (.[0].permissions? // null) else null end' 2>/dev/null)"
  if [ -z "$perms" ] || [ "$perms" = "null" ]; then
    bad "Permissions nicht abrufbar — App-JWT-Auth prüfen (fail-closed)"; return
  fi

  local has_admin; has_admin="$(printf '%s' "$perms" | jq -r 'has("administration")')"
  if [ "$want_admin" = "yes" ]; then
    [ "$has_admin" = "true" ] && ok "Administration-Recht vorhanden (erwartet)" \
                              || info "Administration konnte nicht bestätigt werden — im UI gegenprüfen"
  else
    [ "$has_admin" = "true" ] && bad "etrox-ops hat Administration-Recht — das verletzt die Trennung! Permission entziehen." \
                              || ok "kein Administration-Recht (korrekt)"
  fi
}

echo "=== etrox github-ops · Setup-Verifikation ==="
for bin in curl jq openssl git; do
  command -v "$bin" >/dev/null || bad "fehlendes Programm: $bin"
done

check_app ops   personal no
check_app admin personal yes
if [ -n "${OPS_INSTALLATION_ID_ORG:-}" ]; then
  check_app ops   org no
  check_app admin org yes
else
  echo; info "Org-Installation noch nicht konfiguriert (OPS_INSTALLATION_ID_ORG leer) — ok, solange die Org nicht existiert."
fi

echo
if [ $fail -eq 0 ]; then echo "Alles grün. Der Agent kann übernehmen."; else
  echo "Es gibt Befunde. Erst beheben, dann weiter."; fi
exit $fail
