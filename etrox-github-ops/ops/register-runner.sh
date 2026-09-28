#!/usr/bin/env bash
# Self-Hosted-Runner auf bb8 verwalten.
#
#   ./register-runner.sh --status            # was läuft, wo ist ein Runner registriert
#   ./register-runner.sh --register <repo>   # Runner für ein Repo registrieren
#   ./register-runner.sh --register-org      # Runner org-weit registrieren (nur mit Org)
#
# Audit-Befund 28.07.2026: 0 registrierte Runner, während klubhaus-elf weiter Jobs
# mit self-hosted-Label startete -> Runs mit 2 h 34 m Wartezeit, ein Job dauerhaft
# "Queued". Das ist der Zustand, den --status künftig sofort sichtbar macht.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "$HERE")"
# shellcheck source=../lib/mint-token.sh
. "$ROOT/lib/mint-token.sh"

RUNNER_DIR="${RUNNER_DIR:-/opt/actions-runner}"
LABELS="${RUNNER_LABELS:-self-hosted,Linux,X64,bb8}"

status() {
  echo "=== lokale Runner-Dienste auf $(hostname) ==="
  systemctl list-units 'actions.runner.*' --all --no-pager 2>/dev/null | sed -n '1,20p' \
    || echo "  keine systemd-Units gefunden"
  echo
  echo "=== bei GitHub registrierte Runner ==="
  local any=0
  while read -r repo _profile owner _vis; do
    resp="$(gh_api admin GET "/repos/$owner/$repo/actions/runners" 2>/dev/null)"
    n="$(printf '%s' "$resp" | jq -r '.total_count // 0')"
    [ "$n" = "0" ] && continue
    any=1
    printf '  %-40s %s\n' "$owner/$repo" \
      "$(printf '%s' "$resp" | jq -r '.runners[] | "\(.name) [\(.status)] \(.labels|map(.name)|join(","))"' | paste -sd' | ')"
  done < <("$ROOT/lib/list-repos.sh")
  [ "$any" = "0" ] && echo "  KEINE. Jobs mit 'runs-on: self-hosted' werden ewig in der Queue hängen."

  echo
  echo "=== wartende Jobs ==="
  while read -r repo _profile owner _vis; do
    q="$(gh_api ops GET "/repos/$owner/$repo/actions/runs?status=queued&per_page=10" 2>/dev/null \
         | jq -r '.workflow_runs[]? | "\(.name) #\(.run_number) seit \(.created_at)"')"
    [ -n "$q" ] && printf '  %s\n%s\n' "$owner/$repo" "$(printf '%s' "$q" | sed 's/^/    /')"
  done < <("$ROOT/lib/list-repos.sh")
}

register_repo() {
  local repo="$1" owner token cfg
  owner="$("$ROOT/lib/list-repos.sh" | awk -v r="$repo" '$1==r{print $3}')"
  [ -n "$owner" ] || { echo "Repo '$repo' steht nicht in repos.yaml" >&2; exit 1; }

  token="$(gh_api admin POST "/repos/$owner/$repo/actions/runners/registration-token" | jq -r .token)"
  [ "$token" != "null" ] || { echo "Registration-Token konnte nicht geholt werden" >&2; exit 1; }

  cfg="$RUNNER_DIR/$repo"
  mkdir -p "$cfg"
  if [ ! -x "$cfg/config.sh" ]; then
    echo "Runner-Binary fehlt in $cfg."
    echo "Einmalig herunterladen: https://github.com/$owner/$repo/settings/actions/runners/new"
    exit 1
  fi
  ( cd "$cfg" && ./config.sh --unattended --replace \
      --url "https://github.com/$owner/$repo" --token "$token" \
      --name "bb8-$repo" --labels "$LABELS" --work _work )
  ( cd "$cfg" && sudo ./svc.sh install && sudo ./svc.sh start )
  echo "Runner bb8-$repo registriert und gestartet."
}

register_org() {
  : "${GITHUB_ORG:?GITHUB_ORG fehlt in github.env}"
  local token
  token="$(gh_api admin POST "/orgs/$GITHUB_ORG/actions/runners/registration-token" | jq -r .token)"
  [ "$token" != "null" ] || { echo "Kein Org-Registration-Token — ist die admin-App in der Org installiert?" >&2; exit 1; }
  ( cd "$RUNNER_DIR/_org" 2>/dev/null || { echo "Runner-Binary nach $RUNNER_DIR/_org entpacken"; exit 1; }
    ./config.sh --unattended --replace --url "https://github.com/$GITHUB_ORG" \
      --token "$token" --name "bb8-org" --labels "$LABELS" --work _work
    sudo ./svc.sh install && sudo ./svc.sh start )
  echo "Org-Runner bb8-org registriert — gilt für alle Repos der Org $GITHUB_ORG."
}

case "${1:---status}" in
  --status)       status ;;
  --register)     register_repo "${2:?Repo-Name fehlt}" ;;
  --register-org) register_org ;;
  *) echo "unbekannt: $1" >&2; exit 2 ;;
esac
