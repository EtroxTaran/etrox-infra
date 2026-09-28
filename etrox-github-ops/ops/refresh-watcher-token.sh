#!/usr/bin/env bash
# Haelt das gh-Auth-Profil der ai-review-Watcher frisch: praegt ein
# etrox-ops-App-Token (1 h gueltig) und schreibt es atomar in ein dediziertes
# GH_CONFIG_DIR. gh liest hosts.yml bei jedem Aufruf neu — die Watcher-Prozesse
# muessen fuer den Refresh nicht neu gestartet werden.
#
# Aufruf: alle 45 min via etrox-watcher-token.timer (User-Unit, kein sudo).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "$HERE")"
# shellcheck source=../lib/mint-token.sh
. "$ROOT/lib/mint-token.sh"

GH_OPS_DIR="${ETROX_GH_OPS_DIR:-$HOME/.config/etrox/gh-ops}"
mkdir -p "$GH_OPS_DIR"; chmod 700 "$GH_OPS_DIR"

token="$(mint_token ops personal)"

tmp="$(mktemp "$GH_OPS_DIR/.hosts.yml.XXXXXX")"
cat > "$tmp" <<EOF
github.com:
    oauth_token: ${token}
    user: etrox-ops-bb8
    git_protocol: https
EOF
chmod 600 "$tmp"
mv -f "$tmp" "$GH_OPS_DIR/hosts.yml"

# gh >=2.40 ignoriert hosts.yml-Tokens, wenn config.yml fehlt -> minimal anlegen
if [ ! -f "$GH_OPS_DIR/config.yml" ]; then
  printf 'git_protocol: https\nprompt: disabled\n' > "$GH_OPS_DIR/config.yml"
  chmod 600 "$GH_OPS_DIR/config.yml"
fi

# Selbsttest: Installation-Tokens haben kein /user — /installation/repositories
# ist die verlaessliche Probe fuer App-Auth.
n="$(GH_CONFIG_DIR="$GH_OPS_DIR" gh api /installation/repositories --jq .total_count 2>/dev/null || true)"
if [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null; then
  echo "ok: gh-ops-Profil authentifiziert (Installation-Token, $n Repositories)"
else
  echo "!! gh-ops-Profil kann nicht authentifizieren" >&2; exit 1
fi
