#!/usr/bin/env bash
# Nächtliches Mirror-Backup aller Repos nach $BACKUP_DIR.
#
# Das ist der Grund, warum der Agent so viel Freiheit bekommen darf:
# Es verwandelt „Agent hat etwas kaputtgemacht" von einer Katastrophe
# in einen Ärger von 20 Minuten. Ohne dieses Backup wäre volle Autonomie
# nicht verantwortbar.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "$HERE")"
# shellcheck source=../lib/mint-token.sh
. "$ROOT/lib/mint-token.sh"

: "${BACKUP_DIR:=/srv/backup/github}"
mkdir -p "$BACKUP_DIR"

fail=0
mapfile -t ENTRIES < <("$ROOT/lib/list-repos.sh")

for entry in "${ENTRIES[@]}"; do
  read -r repo _profile owner _vis <<<"$entry"
  scope="$(scope_for_owner "$owner")"
  token="$(mint_token ops "$scope")"
  url="https://x-access-token:${token}@github.com/${owner}/${repo}.git"
  dest="$BACKUP_DIR/${owner}__${repo}.git"

  if [ -d "$dest" ]; then
    if git -C "$dest" remote set-url origin "$url" && git -C "$dest" remote update --prune >/dev/null 2>&1; then
      echo " ok $owner/$repo (aktualisiert)"
    else
      echo " !! $owner/$repo — fetch fehlgeschlagen"; fail=1
    fi
  else
    if git clone --mirror "$url" "$dest" >/dev/null 2>&1; then
      echo " ok $owner/$repo (neu gespiegelt)"
    else
      echo " !! $owner/$repo — clone fehlgeschlagen"; fail=1
    fi
  fi
  # Token nie in der Config zurücklassen
  [ -d "$dest" ] && git -C "$dest" remote set-url origin "https://github.com/${owner}/${repo}.git" || true
done

# Wochenschnappschuss, 30 Tage Aufbewahrung
STAMP="$(date -u +%Y-%m-%d)"
if [ "$(date -u +%u)" = "7" ]; then
  tar -C "$BACKUP_DIR" -czf "$BACKUP_DIR/../github-snapshot-$STAMP.tar.gz" . 2>/dev/null || true
  find "$BACKUP_DIR/.." -maxdepth 1 -name 'github-snapshot-*.tar.gz' -mtime +30 -delete 2>/dev/null || true
fi

echo
echo "Mirrors: $(find "$BACKUP_DIR" -maxdepth 1 -name '*.git' | wc -l)   Größe: $(du -sh "$BACKUP_DIR" | cut -f1)"
exit $fail
