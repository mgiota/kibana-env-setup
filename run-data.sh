#!/usr/bin/env zsh
# ============================================================
#  run-data.sh — data ingestion helpers for Kibana dev
#
#  USAGE:
#    run-data slo          → ingest SLO fake_stack data
#    run-data synthetics   → create synthetics private location
#    run-data fleet-reset  → wipe all Fleet state (monitors, private locations, agents, policies, .fleet-* indices)
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

    # Uses the Kibana script which handles Fleet Server, agent enrollment,
    # and private location creation. Works for both local and remote ES
    # now that the script properly passes --kibana-password to Docker.

    echo "DEBUG ES_HOST=${ES_HOST}"
    node x-pack/scripts/synthetics_private_location.js \
      --elasticsearch-host "${ES_HOST}" \
      --kibana-url "$KIBANA_URL" \
      --kibana-username "${DATA_USERNAME}" \
      --kibana-password "${DATA_PASSWORD}"
    ;;

  fleet-reset)
    wait_for_kibana
    local KIBANA_URL="http://localhost:${KIBANA_PORT}"
    local AUTH="${DATA_USERNAME}:${DATA_PASSWORD}"
    local ES_AUTH="${DATA_USERNAME}:${DATA_PASSWORD}"

    echo "🧹  Fleet reset — clearing all Fleet state"
    echo ""

    # 1. Delete all synthetics monitors (via Kibana API)
    echo "▶ Deleting synthetics monitors..."
    local monitors_response monitor_count=0
    monitors_response=$(curl -s "$KIBANA_URL/api/synthetics/monitors?perPage=100" \
      -H "kbn-xsrf: true" -u "$AUTH" 2>/dev/null)
    if echo "$monitors_response" | grep -q '"id"'; then
      local monitor_ids
      monitor_ids=$(echo "$monitors_response" | grep -o '"id":"[^"]*"' | sed 's/"id":"//;s/"//')
      for mid in $monitor_ids; do
        curl -s -X DELETE "$KIBANA_URL/api/synthetics/monitors/$mid" \
          -H "kbn-xsrf: true" -u "$AUTH" > /dev/null 2>&1
        monitor_count=$((monitor_count + 1))
      done
    fi
    echo "   Deleted $monitor_count monitor(s)"

    # 2. Delete synthetics private locations (via Kibana API)
    echo "▶ Deleting synthetics private locations..."
    local locations loc_count=0
    locations=$(curl -s "$KIBANA_URL/api/synthetics/private_locations" \
      -H "kbn-xsrf: true" -u "$AUTH" 2>/dev/null)
    if echo "$locations" | grep -q '"id"'; then
      local loc_ids
      loc_ids=$(echo "$locations" | grep -o '"id":"[^"]*"' | sed 's/"id":"//;s/"//')
      for loc_id in $loc_ids; do
        curl -s -X DELETE "$KIBANA_URL/api/synthetics/private_locations/$loc_id" \
          -H "kbn-xsrf: true" -u "$AUTH" > /dev/null 2>&1
        loc_count=$((loc_count + 1))
      done
    fi
    echo "   Deleted $loc_count private location(s)"

    # 3. Force-unenroll all Fleet agents (via Fleet API)
    echo "▶ Unenrolling Fleet agents..."
    local all_agents_response agent_count=0
    all_agents_response=$(curl -s "$KIBANA_URL/api/fleet/agents?perPage=1000" \
      -H "kbn-xsrf: true" -u "$AUTH" 2>/dev/null)
    if echo "$all_agents_response" | grep -q '"id"'; then
      local all_agent_ids
      all_agent_ids=$(echo "$all_agents_response" | grep -o '"id":"[^"]*"' | sed 's/"id":"//;s/"//')
      for aid in $all_agent_ids; do
        curl -s -X POST "$KIBANA_URL/api/fleet/agents/$aid/unenroll" \
          -H "kbn-xsrf: true" -H "Content-Type: application/json" \
          -u "$AUTH" -d '{"force":true,"revoke":true}' > /dev/null 2>&1
        agent_count=$((agent_count + 1))
      done
    fi
    echo "   Unenrolled $agent_count agent(s)"

    # 4. Delete Fleet agent policies (via Fleet API)
    #    Use force:true to also delete managed/preconfigured policies
    #    (e.g. fleet-server-policy from kibana.dev.yml xpack.fleet.agentPolicies)
    echo "▶ Deleting Fleet agent policies..."
    local policies_response policy_count=0
    policies_response=$(curl -s "$KIBANA_URL/api/fleet/agent_policies?perPage=100" \
      -H "kbn-xsrf: true" -u "$AUTH" 2>/dev/null)
    if echo "$policies_response" | grep -q '"id"'; then
      local policy_ids
      policy_ids=$(echo "$policies_response" | grep -o '"id":"[^"]*"' | sed 's/"id":"//;s/"//')
      for pid in $policy_ids; do
        curl -s -X POST "$KIBANA_URL/api/fleet/agent_policies/delete" \
          -H "kbn-xsrf: true" -H "Content-Type: application/json" \
          -u "$AUTH" -d "{\"agentPolicyId\":\"$pid\",\"force\":true}" > /dev/null 2>&1
        policy_count=$((policy_count + 1))
      done
    fi
    echo "   Deleted $policy_count agent policy/policies"

    # 5. Delete Fleet internal state from ES system indices
    #    Signing keys, preconfiguration records, and other hidden Fleet types live in
    #    .kibana_ingest_* — a restricted system index that can only be written through
    #    Kibana's internal ES client (Dev Tools console). External curl calls are blocked.
    #    We open Dev Tools in the browser and run the cleanup automatically.
    echo ""
    echo "▶ Clearing Fleet system index data via Dev Tools..."
    local dev_tools_query='POST .kibana_ingest_*/_delete_by_query\n{"query":{"prefix":{"type":"fleet"}}}'
    local encoded_query
    encoded_query=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$dev_tools_query'''))" 2>/dev/null)
    local dev_tools_url="http://localhost:${KIBANA_PORT}/app/dev_tools#/console?load_from=data:text/plain,${encoded_query}"

    # Try to open Dev Tools in the browser automatically
    if command -v open &>/dev/null; then
      open "$dev_tools_url" 2>/dev/null
      echo "   ⚠ Dev Tools opened in your browser."
      echo "   Press ▶ (Ctrl+Enter) to run the delete query, then come back here."
      echo ""
      echo "   If it didn't open, run this manually in Dev Tools (http://localhost:${KIBANA_PORT}/app/dev_tools#/console):"
    else
      echo "   Run this in Dev Tools (http://localhost:${KIBANA_PORT}/app/dev_tools#/console):"
    fi
    echo ""
    echo "     POST .kibana_ingest_*/_delete_by_query"
    echo '     {"query":{"prefix":{"type":"fleet"}}}'
    echo ""
    read -r "?   Press Enter once you've run it (or 's' to skip): " confirm
    if [[ "$confirm" != "s" ]]; then
      echo "   ✅  Continuing..."
    else
      echo "   ⚠ Skipped — Fleet signing keys and preconfig records may still exist."
      echo "     Preconfiguration may not run on restart."
    fi

    # 6. Delete .fleet-* ES indices (final sweep for any leftover data)
    echo ""
    echo "▶ Deleting .fleet-* ES indices..."
    local fleet_indices
    fleet_indices=$(curl -s "$ES_HOST/_cat/indices/.fleet*?h=index" \
      -u "$ES_AUTH" 2>/dev/null | tr -d ' ')
    if [[ -n "$fleet_indices" ]]; then
      local idx_count=0
      for idx in ${(f)fleet_indices}; do
        [[ -z "$idx" ]] && continue
        curl -s -X DELETE "$ES_HOST/$idx" -u "$ES_AUTH" > /dev/null 2>&1
        idx_count=$((idx_count + 1))
      done
      echo "   Deleted $idx_count .fleet-* index/indices"
    else
      echo "   No .fleet-* indices found"
    fi

    echo ""
    echo "✅  Fleet state cleared. Restart Kibana so preconfiguration runs fresh:"
    echo "    ~/dev-start.sh restart main    # or feat, or <branch>"
    ;;

  *)
    echo "Usage: run-data [slo|synthetics|fleet-reset]"
    exit 1
    ;;
esac
