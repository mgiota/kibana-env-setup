#!/usr/bin/env zsh
# ============================================================
#  run-data.sh — data ingestion helpers for Kibana dev
#
#  USAGE:
#    run-data slo          → ingest SLO fake_stack data
#    run-data synthetics   → create synthetics private location
#
#  Reads Kibana port and ES host from config/kibana.dev.yml automatically.
#  Works with both local ES (localhost) and remote ES (oblt-cli / cloud).
#  Must be run from a Kibana repo directory (worktree or main checkout).
# ============================================================

# ── Guard: must be inside a Kibana repo ───────────────────
if [[ ! -f ".nvmrc" ]] || [[ ! -f "package.json" ]]; then
  echo "❌  Must be run from a Kibana repo directory (worktree or main checkout)."
  echo "    e.g. cd ~/Documents/Development/worktrees/<branch>"
  exit 1
fi

YML="config/kibana.dev.yml"
if [[ ! -f "$YML" ]]; then
  echo "❌  $YML not found. Run dev-start.sh to generate it."
  exit 1
fi

# ── Read Kibana port from config ──────────────────────────
KIBANA_PORT=$(grep -E "^ *port:" "$YML" 2>/dev/null | head -1 | awk '{print $2}')
if [[ -z "$KIBANA_PORT" ]]; then
  echo "❌  Could not read Kibana port from $YML."
  exit 1
fi

# ── Read ES host from config (local or remote) ───────────
# Match both formats:
#   Template format:  elasticsearch.hosts:\n  - "http://..."
#   oblt-cli format:  elasticsearch:\n  hosts: https://...
ES_HOST=$(grep -E "^ *(- \"?|hosts: *)https?://" "$YML" 2>/dev/null | head -1 | sed 's|^ *- *||; s|^ *hosts: *||' | tr -d '"' | tr -d ' ')
if [[ -z "$ES_HOST" ]]; then
  echo "❌  Could not read ES host from $YML."
  exit 1
fi

# ── Read ES password from config ──────────────────────────
# Supports both flat keys (elasticsearch.password:) and nested (password: under elasticsearch:)
ES_PASSWORD=$(grep -E "^ *(elasticsearch\.)?password:" "$YML" 2>/dev/null \
  | grep -v "^#" | grep -v "kibana.password" \
  | head -1 | sed 's|.*password: *||' | tr -d '"' | tr -d ' ')

# Defaults for local dev
ES_PASSWORD="${ES_PASSWORD:-changeme}"

# Detect if remote ES (not localhost)
IS_REMOTE=false
if [[ "$ES_HOST" != *"localhost"* && "$ES_HOST" != *"127.0.0.1"* ]]; then
  IS_REMOTE=true
fi

# For data ingestion we always use "elastic" superuser — service accounts
# like kibana_system_user don't have write permissions on data indices
DATA_USERNAME="elastic"
DATA_PASSWORD="${ES_PASSWORD}"

echo "📋  Config from $YML:"
echo "    Kibana → http://localhost:${KIBANA_PORT}"
echo "    ES     → ${ES_HOST}"
echo "    User   → ${DATA_USERNAME}"
if [[ "$IS_REMOTE" == true ]]; then
  echo "    Mode   → 🌐 Remote ES (concurrency reduced)"
fi
echo ""

# ── NVM setup ─────────────────────────────────────────────
export NVM_DIR="$HOME/.nvm"
[[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"
nvm use

# ── Wait for Kibana to be ready ───────────────────────────
wait_for_kibana() {
  local url="http://localhost:${KIBANA_PORT}/api/status"
  echo "⏳  Waiting for Kibana on port ${KIBANA_PORT}..."
  while ! curl -s -o /dev/null -w "%{http_code}" -u "${DATA_USERNAME}:${DATA_PASSWORD}" "$url" 2>/dev/null | grep -q "200"; do
    sleep 5
  done
  echo "✅  Kibana is ready on port ${KIBANA_PORT}."
}

# ── Commands ──────────────────────────────────────────────
case "$1" in
  slo)
    wait_for_kibana
    # Use gentler settings for remote ES to avoid timeouts
    local epc=50 payload=10000 conc=5
    if [[ "$IS_REMOTE" == true ]]; then
      epc=10 payload=1000 conc=1
    fi
    node x-pack/scripts/data_forge.js \
      --events-per-cycle "$epc" \
      --lookback now-1d \
      --dataset fake_stack \
      --event-template good \
      --payload-size "$payload" \
      --concurrency "$conc" \
      --kibana-url "http://localhost:${KIBANA_PORT}" \
      --kibana-username "${DATA_USERNAME}" \
      --kibana-password "${DATA_PASSWORD}" \
      --elasticsearch-host "${ES_HOST}" \
      --elasticsearch-username "${DATA_USERNAME}" \
      --elasticsearch-password "${DATA_PASSWORD}"
    ;;

  synthetics)
    if [[ "$IS_REMOTE" == true ]]; then
      echo "ℹ️  Remote ES detected — skipping private location setup."
      echo ""
      echo "   Elastic managed locations are already available on cloud clusters."
      echo "   Open Synthetics in Kibana and use the pre-populated locations dropdown."
      echo ""
      echo "   Private locations are only needed for local ES, where managed locations"
      echo "   don't exist. Switch to local ES and re-run if you need a private location."
      exit 0
    fi
    wait_for_kibana
    node x-pack/scripts/synthetics_private_location.js \
      --elasticsearch-host "${ES_HOST}" \
      --kibana-url "http://localhost:${KIBANA_PORT}" \
      --kibana-username "${DATA_USERNAME}" \
      --kibana-password "${DATA_PASSWORD}"
    ;;

  *)
    echo "Usage: run-data [slo|synthetics]"
    exit 1
    ;;
esac
