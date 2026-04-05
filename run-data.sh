#!/usr/bin/env zsh
# ============================================================
#  run-data.sh — data ingestion helpers for Kibana dev
#
#  USAGE:
#    run-data slo <kibana_port> <es_port>          → ingest SLO fake_stack data
#    run-data synthetics <kibana_port> <es_port>   → create synthetics private location
#
#  Must be run from a Kibana repo directory (worktree or main checkout).
# ============================================================

# ── Guard: must be inside a Kibana repo ───────────────────
if [[ ! -f ".nvmrc" ]] || [[ ! -f "package.json" ]]; then
  echo "❌  Must be run from a Kibana repo directory (worktree or main checkout)."
  echo "    e.g. cd ~/Documents/Development/worktrees/<branch>"
  exit 1
fi

# ── NVM setup ─────────────────────────────────────────────
export NVM_DIR="$HOME/.nvm"
[[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"
nvm use

# ── Wait for Kibana to be ready ───────────────────────────
wait_for_kibana() {
  local port="$1"
  local url="http://localhost:${port}/api/status"
  echo "⏳  Waiting for Kibana on port ${port}..."
  while ! curl -s -o /dev/null -w "%{http_code}" -u elastic:changeme "$url" 2>/dev/null | grep -q "200"; do
    sleep 5
  done
  echo "✅  Kibana is ready on port ${port}."
}

# ── Commands ──────────────────────────────────────────────
case "$1" in
  slo)
    local kibana_port="${2:?Missing kibana_port}"
    local es_port="${3:?Missing es_port}"
    wait_for_kibana "$kibana_port"
    node x-pack/scripts/data_forge.js \
      --events-per-cycle 50 \
      --lookback now-1d \
      --dataset fake_stack \
      --event-template good \
      --kibana-url "http://localhost:${kibana_port}" \
      --elasticsearch-host "http://localhost:${es_port}"
    ;;

  synthetics)
    local kibana_port="${2:?Missing kibana_port}"
    local es_port="${3:?Missing es_port}"
    wait_for_kibana "$kibana_port"
    node x-pack/scripts/synthetics_private_location.js \
      --elasticsearch-host "http://localhost:${es_port}" \
      --kibana-url "http://localhost:${kibana_port}" \
      --kibana-username elastic
    ;;

  *)
    echo "Usage: run-data [slo|synthetics] <kibana_port> <es_port>"
    exit 1
    ;;
esac
