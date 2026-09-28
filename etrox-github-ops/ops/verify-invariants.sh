#!/usr/bin/env bash
# Prüft die fünf Grenzen aus config/invariants.yaml.
# Läuft nächtlich. Signal = Delta / ein Tracking-Issue (kein täglicher Clone der gleichen ~45).
#
#   ./verify-invariants.sh              # prüfen; Issue upsert nur bei Delta
#   ./verify-invariants.sh --quiet      # nur Exit-Code (+ State)
#   ./verify-invariants.sh --dry-run    # prüfen + Allowlist/Delta zeigen; KEIN Issue, KEIN State-Write
#   ./verify-invariants.sh --no-issue   # prüfen + State schreiben; kein Issue
#
# Allowlist/Stale: config/invariants-allowlist.yaml (owner + ISO expiry Pflicht).
# Expired → Eintrag ignoriert, Violation resurfaced als NEW.
# State/Fingerprint: ~/agent-runs/state/verify-invariants.last.json
# Tracker-Titel-Marker: [invariant-tracker]
#
# Exit 0 = keine aktiven (nicht-allowlisteten) Verstöße
# Exit 1 = aktive Verstöße (SuccessExitStatus=0 1 am Unit behalten)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "$HERE")"
# shellcheck source=../lib/mint-token.sh
. "$ROOT/lib/mint-token.sh"

QUIET=0; DRY=0; NO_ISSUE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet)    QUIET=1 ;;
    --dry-run)  DRY=1 ;;
    --no-issue) NO_ISSUE=1 ;;
    -h|--help)
      sed -n '2,18p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) echo "unbekannte Option: $1" >&2; exit 2 ;;
  esac
  shift
done

: "${BACKUP_DIR:=/srv/backup/github}"
ISSUE_REPO="EtroxTaran/etrox-infra"
TRACKER_MARKER="[invariant-tracker]"
ALLOWLIST_FILE="${ROOT}/config/invariants-allowlist.yaml"
STATE_DIR="${HOME}/agent-runs/state"
STATE_FILE="${STATE_DIR}/verify-invariants.last.json"
TODAY="$(date -u +%F)"

raw_violations=()
allowlisted_violations=()
active_violations=()
expired_hits=()

say() { [ "$QUIET" = "1" ] || echo "$@"; }
viol_raw() { raw_violations+=("$1"); say " !! $1"; }

# --- Parse violation → kind + repo (owner/name) ---
# branch_safety_rules: EtroxTaran/foo/main — ...
# visibility_locked: EtroxTaran/foo ist ...
# no_deletion: EtroxTaran/foo ist ...
# backup_freshness: EtroxTaran/foo — ... / hat keinen Mirror
# queue_health: EtroxTaran/foo — ...
# storage_budget: ... (repo empty)
_parse_viol() {
  local v="$1" kind repo
  kind="${v%%:*}"
  case "$kind" in
    branch_safety_rules)
      repo="$(printf '%s' "$v" | sed -n 's/^branch_safety_rules: \([^/]*\/[^/]*\)\/.*/\1/p')" ;;
    visibility_locked|no_deletion|backup_freshness|queue_health)
      repo="$(printf '%s' "$v" | sed -n "s/^${kind}: \([^ /]*\/[^ /]*\).*/\1/p")" ;;
    *) repo="" ;;
  esac
  printf '%s\t%s' "$kind" "$repo"
}

# Build JSON allowlist index: active (non-expired) + expired, from allowlist+stale sections.
# Output file paths via globals _AL_ACTIVE_JSON _AL_EXPIRED_JSON
_load_allowlist() {
  _AL_ACTIVE_JSON='[]'
  _AL_EXPIRED_JSON='[]'
  if [ ! -f "$ALLOWLIST_FILE" ]; then
    say "  (keine Allowlist: $ALLOWLIST_FILE)"
    return 0
  fi
  local tmp
  tmp="$(mktemp)"
  # yq → JSON; python fallback on bb8 if needed
  if command -v yq >/dev/null 2>&1; then
    yq -o=json '.' "$ALLOWLIST_FILE" >"$tmp" 2>/dev/null || {
      python3 - "$ALLOWLIST_FILE" "$tmp" <<'PY'
import json, sys
try:
    import yaml
except ImportError:
    sys.exit(2)
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f) or {}
with open(sys.argv[2], "w") as out:
    json.dump(data, out)
PY
    }
  else
    python3 - "$ALLOWLIST_FILE" "$tmp" <<'PY'
import json, sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f) or {}
with open(sys.argv[2], "w") as out:
    json.dump(data, out)
PY
  fi

  local split
  split="$(mktemp)"
  jq --arg today "$TODAY" '
    def entries:
      ((.allowlist // []) | map(. + {section:"allowlist"}))
      + ((.stale // []) | map(. + {section:"stale"}));
    def ok_entry:
      (.owner | type == "string" and length > 0)
      and (.expiry | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
      and (.kind | type == "string" and length > 0);
    [entries[] | select(ok_entry)] as $all
    | {
        active:  [$all[] | select(.expiry >= $today)],
        expired: [$all[] | select(.expiry <  $today)]
      }
  ' "$tmp" >"$split"
  _AL_ACTIVE_JSON="$(jq -c '.active' "$split")"
  _AL_EXPIRED_JSON="$(jq -c '.expired' "$split")"
  rm -f "$tmp" "$split"
  say "  Allowlist aktiv: $(printf '%s' "$_AL_ACTIVE_JSON" | jq 'length') · abgelaufen: $(printf '%s' "$_AL_EXPIRED_JSON" | jq 'length')"
}

# Returns 0 if violation matches an active allowlist/stale entry.
_is_allowlisted() {
  local v="$1" kind repo
  IFS=$'\t' read -r kind repo < <(_parse_viol "$v")
  printf '%s' "$_AL_ACTIVE_JSON" | jq -e --arg k "$kind" --arg r "$repo" '
    map(select(.kind == $k)
        | select((.repo // "") == "" or .repo == $r))
    | length > 0
  ' >/dev/null 2>&1
}

# Note expired matches (for resurface reporting) — does not suppress.
_note_expired_hit() {
  local v="$1" kind repo
  IFS=$'\t' read -r kind repo < <(_parse_viol "$v")
  if printf '%s' "$_AL_EXPIRED_JSON" | jq -e --arg k "$kind" --arg r "$repo" '
    map(select(.kind == $k)
        | select((.repo // "") == "" or .repo == $r))
    | length > 0
  ' >/dev/null 2>&1; then
    expired_hits+=("$v")
  fi
}

_fingerprint() {
  # Stable hash of sorted active violation lines
  if [ "$#" -eq 0 ]; then
    printf 'empty' | sha256sum | awk '{print $1}'
    return
  fi
  printf '%s\n' "$@" | sort -u | sha256sum | awk '{print $1}'
}

_load_last_state() {
  if [ -f "$STATE_FILE" ]; then
    cat "$STATE_FILE"
  else
    echo '{"fingerprint":"","active":[],"tracker_issue":null}'
  fi
}

# --- Collect violations (same checks as before) ---
say "=== Invarianten-Prüfung $(date -u '+%Y-%m-%d %H:%M UTC') ==="
[ "$DRY" = "1" ] && say "  MODE: --dry-run (kein Issue, kein State-Write)"
_load_allowlist

mapfile -t ENTRIES < <("$ROOT/lib/list-repos.sh")

for entry in "${ENTRIES[@]}"; do
  read -r repo _profile owner want_vis <<<"$entry"
  slug="$owner/$repo"

  meta="$(gh_api ops GET "/repos/$slug" 2>/dev/null)"

  # --- no_deletion ---
  if ! printf '%s' "$meta" | jq -e '.id' >/dev/null 2>&1; then
    viol_raw "no_deletion: $slug ist über die API nicht auffindbar (gelöscht? umbenannt? Zugriff entzogen?)"
    continue
  fi

  # --- visibility_locked ---
  is_priv="$(printf '%s' "$meta" | jq -r '.private')"
  actual=$([ "$is_priv" = "true" ] && echo private || echo public)
  if [ "$want_vis" != "unknown" ] && [ "$actual" != "$want_vis" ]; then
    viol_raw "visibility_locked: $slug ist $actual, soll $want_vis sein"
  fi

  # --- branch_safety_rules ---
  branch="$(printf '%s' "$meta" | jq -r '.default_branch')"
  rules="$(gh_api ops GET "/repos/$slug/rules/branches/$branch" 2>/dev/null)"
  for needed in deletion non_fast_forward; do
    if ! printf '%s' "$rules" | jq -e --arg t "$needed" 'map(.type) | index($t)' >/dev/null 2>&1; then
      viol_raw "branch_safety_rules: $slug/$branch — Regel '$needed' fehlt"
    fi
  done

  # --- backup_freshness ---
  dest="$BACKUP_DIR/${owner}__${repo}.git"
  if [ ! -d "$dest" ]; then
    viol_raw "backup_freshness: $slug hat keinen Mirror in $BACKUP_DIR"
  else
    age_h=$(( ( $(date +%s) - $(stat -c %Y "$dest/FETCH_HEAD" 2>/dev/null || stat -c %Y "$dest") ) / 3600 ))
    [ "$age_h" -gt 48 ] && viol_raw "backup_freshness: $slug — Mirror ist ${age_h} h alt (Grenze 48 h)"
  fi
done

# --- queue_health ---
now=$(date +%s)
for entry in "${ENTRIES[@]}"; do
  read -r repo _p owner _v <<<"$entry"
  while IFS=$'\t' read -r name created; do
    [ -n "$name" ] || continue
    ts=$(date -u -d "$created" +%s 2>/dev/null || echo "$now")
    age_min=$(( (now - ts) / 60 ))
    [ "$age_min" -gt 15 ] && viol_raw "queue_health: $owner/$repo — '$name' wartet seit ${age_min} min auf einen Runner"
  done < <(gh_api ops GET "/repos/$owner/$repo/actions/runs?status=queued&per_page=10" 2>/dev/null \
           | jq -r '.workflow_runs[]? | [.name, .created_at] | @tsv')
done

# --- storage_budget ---
bytes=0
for entry in "${ENTRIES[@]}"; do
  read -r repo _p owner _v <<<"$entry"
  n="$(gh_api ops GET "/repos/$owner/$repo/actions/artifacts?per_page=100" 2>/dev/null \
       | jq -r '[.artifacts[]? | select(.expired==false) | .size_in_bytes] | add // 0')"
  bytes=$((bytes + ${n:-0}))
done
gb=$(awk -v b="$bytes" 'BEGIN{printf "%.2f", b/1073741824}')
say "  Actions-Storage gesamt: ${gb} GB (Grenze 2 GB)"
awk -v g="$gb" 'BEGIN{exit !(g>2)}' && viol_raw "storage_budget: ${gb} GB überschreiten das Pro-Freikontingent von 2 GB"

# --- Partition allowlist ---
for v in "${raw_violations[@]+"${raw_violations[@]}"}"; do
  if _is_allowlisted "$v"; then
    allowlisted_violations+=("$v")
  else
    active_violations+=("$v")
    _note_expired_hit "$v"
  fi
done

raw_n=${#raw_violations[@]}
al_n=${#allowlisted_violations[@]}
active_n=${#active_violations[@]}
exp_n=${#expired_hits[@]}

say
say "Roh-Verstöße: $raw_n · Allowlist/Stale (aktiv): $al_n · Aktiv (signal): $active_n · Expired-resurface: $exp_n"

if [ "$active_n" -gt 0 ]; then
  say "Aktive Verstöße:"
  for v in "${active_violations[@]}"; do say "  ** $v"; done
fi
if [ "$exp_n" -gt 0 ]; then
  say "Expired-Allowlist (wieder offen):"
  for v in "${expired_hits[@]}"; do say "  !!expired $v"; done
fi

fp="$(_fingerprint "${active_violations[@]+"${active_violations[@]}"}")"
last_json="$(_load_last_state)"
last_fp="$(printf '%s' "$last_json" | jq -r '.fingerprint // empty')"
last_active="$(printf '%s' "$last_json" | jq -c '.active // []')"
tracker_issue="$(printf '%s' "$last_json" | jq -r '.tracker_issue // empty')"

# Deltas vs last run
new_deltas_json="$(printf '%s\n' "${active_violations[@]+"${active_violations[@]}"}" \
  | jq -R -s --argjson last "$last_active" '
      [split("\n")[] | select(length>0)] as $cur
      | $cur - $last
    ')"
resolved_json="$(printf '%s\n' "${active_violations[@]+"${active_violations[@]}"}" \
  | jq -R -s --argjson last "$last_active" '
      [split("\n")[] | select(length>0)] as $cur
      | $last - $cur
    ')"
new_n="$(printf '%s' "$new_deltas_json" | jq 'length')"
resolved_n="$(printf '%s' "$resolved_json" | jq 'length')"

say "Fingerprint: ${fp:0:12}… · last: ${last_fp:0:12}… · new: $new_n · resolved: $resolved_n"

# --- Persist state (unless dry-run) ---
write_state() {
  local issue_num="${1:-}"
  mkdir -p "$STATE_DIR"
  jq -n \
    --arg run_at "$(date -Iseconds)" \
    --arg fp "$fp" \
    --argjson raw "$raw_n" \
    --argjson allowlisted "$al_n" \
    --argjson active_n "$active_n" \
    --argjson new_n "$new_n" \
    --argjson resolved_n "$resolved_n" \
    --argjson active "$(printf '%s\n' "${active_violations[@]+"${active_violations[@]}"}" | jq -R -s '[split("\n")[]|select(length>0)]')" \
    --argjson allowlisted_list "$(printf '%s\n' "${allowlisted_violations[@]+"${allowlisted_violations[@]}"}" | jq -R -s '[split("\n")[]|select(length>0)]')" \
    --argjson new_deltas "$new_deltas_json" \
    --argjson resolved "$resolved_json" \
    --argjson expired "$(printf '%s\n' "${expired_hits[@]+"${expired_hits[@]}"}" | jq -R -s '[split("\n")[]|select(length>0)]')" \
    --arg issue "$issue_num" \
    '{
      run_at:$run_at,
      fingerprint:$fp,
      counts:{raw:$raw, allowlisted:$allowlisted, active:$active_n, new:$new_n, resolved:$resolved_n},
      active:$active,
      allowlisted:$allowlisted_list,
      new_deltas:$new_deltas,
      resolved_since_last:$resolved,
      expired_allowlist_hits:$expired,
      tracker_issue:(if $issue == "" then null else ($issue|tonumber) end)
    }' >"$STATE_FILE"
  say "State: $STATE_FILE"
}

# --- Issue upsert (one tracker) ---
find_tracker() {
  # Search open issues with marker in title
  local resp num
  resp="$(gh_api ops GET "/repos/$ISSUE_REPO/issues?state=open&labels=governance&per_page=50" 2>/dev/null)"
  num="$(printf '%s' "$resp" | jq -r --arg m "$TRACKER_MARKER" '
    [.[] | select(.title | contains($m)) | .number] | first // empty
  ')"
  printf '%s' "$num"
}

build_body() {
  local body
  body="Automatische Invarianten-Prüfung (Delta/Upsert) · $(date -u '+%Y-%m-%d %H:%M UTC')"$'\n\n'
  body+="**Marker:** \`$TRACKER_MARKER\` · Quelle: \`ops/verify-invariants.sh\` · Allowlist: \`config/invariants-allowlist.yaml\`"$'\n\n'
  body+="| Metric | Count |"$'\n'"|--------|------:|"$'\n'
  body+="| Roh-Verstöße | $raw_n |"$'\n'
  body+="| Allowlist/Stale (aktiv, unterdrückt) | $al_n |"$'\n'
  body+="| **Aktiv (Signal)** | **$active_n** |"$'\n'
  body+="| Neu seit letztem Lauf | $new_n |"$'\n'
  body+="| Behoben seit letztem Lauf | $resolved_n |"$'\n'
  body+="| Expired-Allowlist resurfaced | $exp_n |"$'\n\n'
  body+="Fingerprint: \`$fp\`"$'\n\n'
  if [ "$new_n" -gt 0 ]; then
    body+="### Neu (Deltas)"$'\n'
    body+="$(printf '%s' "$new_deltas_json" | jq -r '.[] | "- \(.)"')"$'\n\n'
  fi
  if [ "$resolved_n" -gt 0 ]; then
    body+="### Behoben seit letztem Lauf"$'\n'
    body+="$(printf '%s' "$resolved_json" | jq -r '.[] | "- \(.)"')"$'\n\n'
  fi
  if [ "$active_n" -gt 0 ]; then
    body+="### Aktive Verstöße (nicht allowlistet)"$'\n'
    for v in "${active_violations[@]}"; do body+="- $v"$'\n'; done
    body+=$'\n'
  else
    body+="_Keine aktiven Verstöße. Bekannte Schuld liegt in Allowlist/Stale (mit Owner+Expiry)._"$'\n\n'
  fi
  if [ "$al_n" -gt 0 ] && [ "$QUIET" != "1" ]; then
    body+="<details><summary>Allowlistet ($al_n) — ausgeklappt nur zur Audit</summary>"$'\n\n'
    for v in "${allowlisted_violations[@]}"; do body+="- $v"$'\n'; done
    body+=$'\n'"</details>"$'\n\n'
  fi
  body+="Grenzen darf der Agent nicht selbst ändern. Allowlist-Expiry erzwingen Review (Geordi/Nico)."
  printf '%s' "$body"
}

upsert_tracker() {
  local body title payload existing num comment
  body="$(build_body)"
  title="$TRACKER_MARKER Invarianten — aktiv $active_n · neu $new_n · $(date -u +%F)"

  existing="$(find_tracker)"
  if [ -z "$existing" ] && [ -n "$tracker_issue" ] && [ "$tracker_issue" != "null" ]; then
    # last-known may still be open under older title shape
    existing="$tracker_issue"
  fi

  if [ -n "$existing" ]; then
    payload="$(jq -n --arg t "$title" --arg b "$body" '{title:$t, body:$b, state:"open"}')"
    if gh_api ops PATCH "/repos/$ISSUE_REPO/issues/$existing" -d "$payload" >/dev/null 2>&1; then
      say "Tracker-Issue #$existing aktualisiert (upsert)."
      if [ "$new_n" -gt 0 ] || [ "$resolved_n" -gt 0 ]; then
        comment="$(jq -n --arg b "**Delta-Update** $(date -u +%F): neu=$new_n resolved=$resolved_n active=$active_n fp=\`${fp:0:12}…\`" '{body:$b}')"
        gh_api ops POST "/repos/$ISSUE_REPO/issues/$existing/comments" -d "$comment" >/dev/null 2>&1 || true
      fi
      printf '%s' "$existing"
      return 0
    fi
    say "PATCH #$existing fehlgeschlagen — versuche Create."
  fi

  # Only create when there is an active signal (never for allowlist-only debt)
  if [ "$active_n" -eq 0 ]; then
    say "Kein neuer Tracker (active=0)."
    printf ''
    return 0
  fi

  payload="$(jq -n --arg t "$title" --arg b "$body" '{title:$t, body:$b, labels:["governance","automated"]}')"
  num="$(gh_api ops POST "/repos/$ISSUE_REPO/issues" -d "$payload" 2>/dev/null | jq -r '.number // empty')"
  if [ -n "$num" ]; then
    say "Tracker-Issue #$num geöffnet (einmalig upsert)."
    printf '%s' "$num"
  else
    say "Issue konnte nicht geöffnet werden."
    printf ''
  fi
}

# Decision: spam-guard — max one tracker; never daily clone of identical set
should_touch_issue=0
if [ "$DRY" = "1" ] || [ "$NO_ISSUE" = "1" ]; then
  should_touch_issue=0
  say "Issue-Pfad übersprungen (--dry-run/--no-issue)."
elif [ "$active_n" -eq 0 ] && [ "$resolved_n" -eq 0 ]; then
  # Allowlist-only debt or all-green: no tracker create/spam (first run or stable)
  should_touch_issue=0
  say "Keine aktiven Verstöße / keine Resolved-Deltas — kein Issue-API-Call."
elif [ "$fp" = "$last_fp" ] && [ -n "$last_fp" ]; then
  should_touch_issue=0
  say "Fingerprint unverändert — kein Issue-API-Call (Anti-Spam)."
else
  # active>0 with new/changed fp, or resolved deltas worth updating tracker
  should_touch_issue=1
fi

issue_num=""
if [ "$should_touch_issue" = "1" ]; then
  issue_num="$(upsert_tracker)"
elif [ -n "$tracker_issue" ] && [ "$tracker_issue" != "null" ]; then
  issue_num="$tracker_issue"
fi

if [ "$DRY" != "1" ]; then
  write_state "$issue_num"
else
  say "Dry-run: State nicht geschrieben. Würde Issue touch=$should_touch_issue tracker=${issue_num:-none}"
fi

# Exit: active signal
if [ "$active_n" -eq 0 ]; then
  say "Alle Signal-Invarianten grün (Allowlist-Schuld ggf. bewusst)."
  exit 0
fi
say "$active_n aktive Verstöße (Signal)."
exit 1
