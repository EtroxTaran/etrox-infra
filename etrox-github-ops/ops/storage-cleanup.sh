#!/usr/bin/env bash
# Der Kostenfix. Setzt Artifact-/Log-Retention auf 7 Tage und löscht Alt-Artifacts.
#
#   ./storage-cleanup.sh --report          # nur zeigen: was liegt wo, wie groß
#   ./storage-cleanup.sh --retention       # Retention auf 7 Tage setzen (braucht admin)
#   ./storage-cleanup.sh --purge           # Artifacts älter als RETENTION_DAYS löschen
#   ./storage-cleanup.sh --purge --all     # ALLE Artifacts löschen (Erstbereinigung)
#
# Hintergrund (Audit 28.07.2026): 339,4 GB-hr/Tag = ~14 GB dauerhaft.
# Pro enthält 2 GB. Das sind ~$0.11/Tag = ~$40/Jahr — 100 % der GitHub-Rechnung.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "$HERE")"
# shellcheck source=../lib/mint-token.sh
. "$ROOT/lib/mint-token.sh"

RETENTION_DAYS="${RETENTION_DAYS:-7}"
MODE="report"; ALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --report) MODE=report ;; --retention) MODE=retention ;; --purge) MODE=purge ;;
    --all) ALL=1 ;;
    *) echo "unbekannt: $1" >&2; exit 2 ;;
  esac; shift
done

mapfile -t ENTRIES < <("$ROOT/lib/list-repos.sh")
cutoff=$(date -u -d "-${RETENTION_DAYS} days" +%s)
total=0

human() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1}B"; }

for entry in "${ENTRIES[@]}"; do
  read -r repo _profile owner _vis <<<"$entry"
  slug="$owner/$repo"

  case "$MODE" in
    retention)
      out="$(gh_api admin PUT "/repos/$slug/actions/permissions/artifact-and-log-retention" \
             -d "{\"days\":${RETENTION_DAYS}}" -w '\n%{http_code}' 2>/dev/null | tail -1)"
      if [ "$out" = "204" ] || [ "$out" = "200" ]; then echo " ok $slug: Retention = ${RETENTION_DAYS} Tage"
      else echo " !! $slug: Retention setzen fehlgeschlagen (HTTP $out)"; fi
      continue ;;
  esac

  # Artifacts einsammeln (paginiert)
  page=1; repo_bytes=0; old_ids=()
  while :; do
    resp="$(gh_api ops GET "/repos/$slug/actions/artifacts?per_page=100&page=$page")"
    count="$(printf '%s' "$resp" | jq -r '.artifacts | length // 0')"
    [ "$count" = "0" ] && break
    while IFS=$'\t' read -r id size created expired; do
      [ "$expired" = "true" ] && continue
      repo_bytes=$((repo_bytes + size))
      ts=$(date -u -d "$created" +%s 2>/dev/null || echo 0)
      if [ "$ALL" = "1" ] || { [ "$ts" -gt 0 ] && [ "$ts" -lt "$cutoff" ]; }; then old_ids+=("$id"); fi
    done < <(printf '%s' "$resp" | jq -r '.artifacts[] | [.id,.size_in_bytes,.created_at,.expired] | @tsv')
    page=$((page + 1)); [ "$count" -lt 100 ] && break
  done

  total=$((total + repo_bytes))
  [ "$repo_bytes" = "0" ] && [ "${#old_ids[@]}" = "0" ] && continue
  printf ' %-44s %10s   löschbar: %d\n' "$slug" "$(human $repo_bytes)" "${#old_ids[@]}"

  if [ "$MODE" = "purge" ]; then
    for id in "${old_ids[@]}"; do
      gh_api ops DELETE "/repos/$slug/actions/artifacts/$id" >/dev/null || true
    done
    [ "${#old_ids[@]}" -gt 0 ] && echo "    → ${#old_ids[@]} Artifacts gelöscht"
  fi
done

if [ "$MODE" != "retention" ]; then
  echo; echo "Gesamt aktiv gespeichert: $(human $total)   (Pro-Freikontingent: 2 GB)"
  awk -v b="$total" 'BEGIN{ gb=b/1073741824; over=gb-2; if(over<0)over=0;
    printf "Geschätzte Kosten: $%.2f/Tag  ≈  $%.0f/Jahr\n", over*24*0.000336, over*24*0.000336*365 }'
fi
