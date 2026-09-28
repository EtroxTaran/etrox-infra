#!/usr/bin/env bash
# Rollt die Ruleset-Baselines auf alle Repos aus config/repos.yaml aus.
# Idempotent: existiert ein Ruleset gleichen Namens, wird es aktualisiert (PUT), nicht dupliziert.
#
#   ./apply-rulesets.sh --dry-run     # nur zeigen, was passieren würde
#   ./apply-rulesets.sh               # anwenden
#   ./apply-rulesets.sh --repo x-ai-stack
#
# Nutzt den ADMIN-Key (Administration:write). Der ops-Key kann das absichtlich nicht.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
# shellcheck source=../lib/mint-token.sh
. "$ROOT/lib/mint-token.sh"

DRY=0; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --repo)    ONLY="${2:?--repo braucht einen Namen}"; shift ;;
    *) echo "unbekannte Option: $1" >&2; exit 2 ;;
  esac
  shift
done

OWNER="${GITHUB_OWNER:?GITHUB_OWNER fehlt in github.env}"
: "${OPS_APP_ID:?}"; : "${ADMIN_APP_ID:?}"

# repos.yaml ohne yq parsen.
# Zeilenform: "  <repo>: <profil> [| owner=<owner>] [| visibility=<v>]"
# Ergebnis je Zeile: "<repo> <profil> <owner>"
mapfile -t ENTRIES < <(
  awk -v def="$OWNER" '
    /^archived:/ { inrepos=0 }
    /^repos:/    { inrepos=1; next }
    !inrepos     { next }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]+[A-Za-z0-9._-]+:[[:space:]]*[a-z-]+/ {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      split(line, kv, ":")
      repo=kv[1]
      rest=substr(line, index(line,":")+1)
      owner=def
      n=split(rest, parts, /\|/)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", parts[1])
      profile=parts[1]
      for (i=2; i<=n; i++) {
        p=parts[i]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", p)
        if (p ~ /^owner=/) { sub(/^owner=/, "", p); owner=p }
      }
      print repo, profile, owner
    }' "$ROOT/config/repos.yaml"
)

[ ${#ENTRIES[@]} -gt 0 ] || { echo "Keine Repos in config/repos.yaml gefunden." >&2; exit 1; }

render() {  # render <profile> -> JSON auf stdout (IDs sind bereits eingetragen)
  sed -e "s/__ADMIN_APP_ID__/$ADMIN_APP_ID/g" \
      -e "s/__OPS_APP_ID__/$OPS_APP_ID/g" \
      "$HERE/$1.json"
}

rc=0
for entry in "${ENTRIES[@]}"; do
  read -r repo profile owner <<<"$entry"
  [ -n "$ONLY" ] && [ "$ONLY" != "$repo" ] && continue
  [ -f "$HERE/$profile.json" ] || { echo " !! $repo: Profil '$profile' existiert nicht"; rc=1; continue; }

  body="$(render "$profile")"
  name="$(printf '%s' "$body" | jq -r .name)"

  existing="$(gh_api admin GET "/repos/$owner/$repo/rulesets" \
              | jq -r --arg n "$name" '.[]? | select(.name==$n) | .id' | head -1)"

  if [ "$DRY" = "1" ]; then
    if [ -n "$existing" ]; then echo "    $owner/$repo: '$name' (id $existing) würde aktualisiert"
    else                        echo "  + $owner/$repo: '$name' würde angelegt"; fi
    continue
  fi

  if [ -n "$existing" ]; then
    out="$(gh_api admin PUT "/repos/$owner/$repo/rulesets/$existing" -d "$body")"; verb="aktualisiert"
  else
    out="$(gh_api admin POST "/repos/$owner/$repo/rulesets" -d "$body")";          verb="angelegt"
  fi

  if printf '%s' "$out" | jq -e '.id' >/dev/null 2>&1; then
    echo " ok $owner/$repo: '$name' $verb"
  else
    echo " !! $owner/$repo: fehlgeschlagen"; printf '%s\n' "$out" | jq -r '.message? // .' >&2; rc=1
  fi
done

# Legacy Branch Protection laeuft parallel weiter und ueberlagert Rulesets additiv:
# die strengere Regel gewinnt. Solange beide aktiv sind, jagst du Phantome.
cat <<'TXT'

Nächster Schritt nach erfolgreichem Rollout — Legacy-Regeln entfernen:
  gh_api admin DELETE "/repos/<owner>/<repo>/branches/<branch>/protection"

Bekannte Altlasten aus dem Audit vom 28.07.2026:
  EtroxTaran/x-ai-stack   branch_protection_rule 79030397  (main)
  coding-x/klubhaus-elf   branch_protection_rule 77710451  (main)
Erst löschen, wenn ein Test-PR mit rotem Check nachweislich nicht mergebar ist.
TXT
exit $rc
