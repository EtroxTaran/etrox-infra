#!/usr/bin/env bash
# post-install-check.sh — schneller Smoke-Test nach Provisioning.
# Nicht ersatz für playbooks/verify.yml, aber hilfreich vor jedem Commit.

set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "  ✅ $*"; PASS=$((PASS+1)); }
fail() { echo "  ❌ $*"; FAIL=$((FAIL+1)); }

echo "== System =="
nproc | xargs -I{} echo "CPU cores: {}"
free -h | grep Mem

echo "== GPU =="
if command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null 2>&1; then
    ok "nvidia-smi works"
    nvidia-smi --query-gpu=name,driver_version,temperature.gpu,memory.used,memory.total --format=csv,noheader
else
    fail "nvidia-smi failed"
fi

echo "== Docker =="
docker info >/dev/null 2>&1 && ok "Docker daemon up" || fail "Docker not running"
docker run --rm --gpus all nvidia/cuda:12.6.0-base-ubuntu24.04 nvidia-smi >/dev/null 2>&1 \
    && ok "Docker GPU passthrough" || fail "Docker GPU passthrough"

echo "== Tailscale =="
tailscale status >/dev/null 2>&1 && ok "Tailscale connected" || fail "Tailscale not up"

echo "== Services =="
for svc in ollama n8n surrealdb traefik; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        ok "$svc active (systemd)"
    elif docker ps --format '{{.Names}}' | grep -q "$svc"; then
        ok "$svc running (docker)"
    else
        fail "$svc neither systemd nor docker"
    fi
done

echo "== Endpoints =="
curl -sf http://localhost:11434/api/tags >/dev/null && ok "Ollama API"     || fail "Ollama API"
curl -sf http://localhost:5678/healthz   >/dev/null && ok "n8n /healthz"   || fail "n8n /healthz"
curl -sf http://localhost:8000/health    >/dev/null && ok "SurrealDB /health" || fail "SurrealDB /health"

echo "== Disks =="
df -h /data /opt 2>/dev/null | tail -n +2

echo
echo "Pass: $PASS   Fail: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
