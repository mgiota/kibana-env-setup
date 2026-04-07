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
    wait_for_kibana
    local KIBANA_URL="http://localhost:${KIBANA_PORT}"
    local AUTH="${DATA_USERNAME}:${DATA_PASSWORD}"

    if [[ "$IS_REMOTE" == true ]]; then
      echo "🌐  Remote ES — creating private location via Kibana API"
      echo "    (managed locations are already available; this adds a private one alongside them)"
      echo ""

      # Check if a private location already exists
      local existing
      existing=$(curl -s "$KIBANA_URL/api/synthetics/private_locations" \
        -H "kbn-xsrf: true" \
        -u "$AUTH" 2>/dev/null)
      if echo "$existing" | grep -q '"label"'; then
        echo "ℹ️  Private locations already exist:"
        echo "$existing" | grep -o '"label":"[^"]*"' | sed 's/"label":"//;s/"/  → /' | while read -r loc; do
          echo "    • $loc"
        done
        echo ""
        echo "   Delete existing ones first if you want to recreate."
        exit 0
      fi

      # Find a suitable agent policy from Fleet
      echo "▶ Querying Fleet agent policies..."
      local policies_response
      policies_response=$(curl -s "$KIBANA_URL/api/fleet/agent_policies?perPage=50" \
        -H "kbn-xsrf: true" \
        -u "$AUTH" 2>/dev/null)

      # Try to find an existing policy we can use (prefer one not already tied to a private location)
      local policy_id
      policy_id=$(echo "$policies_response" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"//')

      if [[ -z "$policy_id" ]]; then
        # No policies exist — create a dedicated one
        echo "▶ No agent policies found — creating one for private location..."
        local create_response
        create_response=$(curl -s -X POST "$KIBANA_URL/api/fleet/agent_policies" \
          -H "kbn-xsrf: true" \
          -H "Content-Type: application/json" \
          -u "$AUTH" \
          -d '{
            "name": "Synthetics Private Location Policy",
            "description": "Agent policy for synthetics private location (dev)",
            "namespace": "default",
            "monitoring_enabled": ["logs", "metrics"]
          }' 2>/dev/null)
        policy_id=$(echo "$create_response" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"//')
        if [[ -z "$policy_id" ]]; then
          echo "❌  Failed to create agent policy:"
          echo "$create_response"
          exit 1
        fi
        echo "✅  Created agent policy: $policy_id"
      else
        local policy_name
        policy_name=$(echo "$policies_response" | grep -o '"name":"[^"]*"' | head -1 | sed 's/"name":"//;s/"//')
        echo "✅  Using existing agent policy: $policy_name ($policy_id)"
      fi

      # Create the private location
      echo "▶ Creating private location..."
      local location_response
      location_response=$(curl -s -X POST "$KIBANA_URL/api/synthetics/private_locations" \
        -H "kbn-xsrf: true" \
        -H "Content-Type: application/json" \
        -u "$AUTH" \
        -d "{
          \"label\": \"Dev Private Location\",
          \"agentPolicyId\": \"$policy_id\",
          \"geo\": { \"lat\": 41.12, \"lon\": -71.34 }
        }" 2>/dev/null)

      if echo "$location_response" | grep -q '"label"'; then
        echo "✅  Private location created: Dev Private Location"
        echo ""
        echo "    You now have both managed and private locations in Synthetics."
        echo "    Note: monitors on this private location won't run without an enrolled agent."
      else
        echo "❌  Failed to create private location:"
        echo "$location_response"
        exit 1
      fi
    else
      # Local ES — use the existing script (fleet-server-policy from kibana.dev.yml template)
      node x-pack/scripts/synthetics_private_location.js \
        --elasticsearch-host "${ES_HOST}" \
        --kibana-url "$KIBANA_URL" \
        --kibana-username "${DATA_USERNAME}" \
        --kibana-password "${DATA_PASSWORD}"
    fi
    ;;

  *)
    echo "Usage: run-data [slo|synthetics]"
    exit 1
    ;;
esac
