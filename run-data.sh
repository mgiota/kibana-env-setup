#!/usr/bin/env zsh
# ============================================================
#  run-data.sh — data ingestion helpers for Kibana dev
#
#  USAGE:
#    run-data slo <kibana_port> <es_port>   → ingest SLO fake_stack data
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

# ── Commands ──────────────────────────────────────────────
case "$1" in
  slo)
    local kibana_port="${2:?Missing kibana_port}"
    local es_port="${3:?Missing es_port}"
    node x-pack/scripts/data_forge.js \
      --events-per-cycle 50 \
      --lookback now-1d \
      --dataset fake_stack \
      --event-template good \
      --kibana-url "http://localhost:${kibana_port}" \
      --elasticsearch-host "http://localhost:${es_port}"
    ;;

  *)
    echo "Usage: run-data [slo] <kibana_port> <es_port>"
    exit 1
    ;;
esac
