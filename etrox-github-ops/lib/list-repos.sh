#!/usr/bin/env bash
# Gibt je Zeile aus: "<repo> <profil> <owner> <soll-visibility>"
# Einzige Parsing-Stelle für config/repos.yaml — alle anderen Scripts nutzen diese.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "$HERE")"
: "${ETROX_ENV:=$HOME/.config/etrox/github.env}"
# shellcheck disable=SC1090
[ -f "$ETROX_ENV" ] && . "$ETROX_ENV"
: "${GITHUB_OWNER:=EtroxTaran}"

awk -v def="$GITHUB_OWNER" '
  /^archived:/ { inrepos=0 }
  /^repos:/    { inrepos=1; next }
  !inrepos     { next }
  /^[[:space:]]*#/ { next }
  /^[[:space:]]+[A-Za-z0-9._-]+:[[:space:]]*[a-z-]+/ {
    line=$0; sub(/^[[:space:]]+/, "", line)
    split(line, kv, ":"); repo=kv[1]
    rest=substr(line, index(line,":")+1)
    owner=def; vis="unknown"
    n=split(rest, parts, /\|/)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", parts[1]); profile=parts[1]
    for (i=2; i<=n; i++) {
      p=parts[i]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", p)
      if (p ~ /^owner=/)      { sub(/^owner=/, "", p);      owner=p }
      if (p ~ /^visibility=/) { sub(/^visibility=/, "", p); vis=p }
    }
    print repo, profile, owner, vis
  }' "$ROOT/config/repos.yaml"
