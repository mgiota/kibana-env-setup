#!/usr/bin/env zsh
# ============================================================
#  run-data.sh — data ingestion helpers for Kibana dev
#
#  USAGE:
#    run-data slo                            → ingest SLO fake_stack data
#    run-data synthetics                     → create synthetics private location
#    run-data synthetics break <scenario>    → trigger a Synthetics failure scenario
#    run-data synthetics fix <scenario>      → restore from a failure scenario
#    run-data synthetics reset               → wipe all Fleet + Synthetics state
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
    local ES_AUTH="${DATA_USERNAME}:${DATA_PASSWORD}"

    # ── Helpers for synthetics break/fix ──────────────────────

    _synth_extract() {
      echo "$1" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    items = $2
    for item in items:
        val = item.get('$3', '')
        if val:
            print(val)
except: pass
" 2>/dev/null
    }

    _synth_find_agent() {
      curl -s "$KIBANA_URL/api/fleet/agents?perPage=100" \
        -H "kbn-xsrf: true" -u "$AUTH" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for a in data.get('items', []):
    if a.get('policy_id') != 'fleet-server-policy':
        print(a['id']); break
" 2>/dev/null
    }

    _synth_find_private_location() {
      curl -s "$KIBANA_URL/api/synthetics/private_locations" \
        -H "kbn-xsrf: true" -H "elastic-api-version: 2023-10-31" \
        -u "$AUTH" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
locs = data if isinstance(data, list) else []
for loc in locs:
    if not loc.get('isServiceManaged', True):
        print(loc['id']); break
" 2>/dev/null
    }

    _synth_find_agent_container() {
      # Find the synthetics agent container (not Fleet Server)
      docker ps -a --format '{{.ID}} {{.Names}} {{.Image}}' 2>/dev/null | while read cid cname cimg; do
        if [[ "$cname" != *"fleet"* && "$cname" != *"Fleet"* ]] && \
           [[ "$cimg" == *"elastic-agent"* || "$cname" == *"elastic-agent"* ]]; then
          echo "$cid"; return
        fi
      done
    }

    _synth_find_fleet_container() {
      docker ps -a --format '{{.ID}} {{.Names}}' 2>/dev/null | while read cid cname; do
        if [[ "$cname" == *"fleet-server"* || "$cname" == *"fleet_server"* ]]; then
          echo "$cid"; return
        fi
      done
    }

    _synth_find_package_policy() {
      curl -s "$KIBANA_URL/api/fleet/package_policies?kuery=fleet-package-policies.package.name:synthetics&perPage=10" \
        -H "kbn-xsrf: true" -u "$AUTH" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
items = data.get('items', [])
if items: print(items[0]['id'])
" 2>/dev/null
    }

    _synth_find_private_monitor() {
      curl -s "$KIBANA_URL/api/synthetics/monitors?perPage=100" \
        -H "kbn-xsrf: true" -H "elastic-api-version: 2023-10-31" \
        -u "$AUTH" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('monitors', []):
    for loc in m.get('locations', []):
        if not loc.get('isServiceManaged', True):
            print(m['config_id']); exit()
" 2>/dev/null
    }

    # ============================================================
    #  BREAK — inject Synthetics failure scenarios
    # ============================================================
    _synth_break() {
      local scenario="$1"
      case "$scenario" in

        agent-offline)
          echo "💥  Scenario: Agent Offline"
          echo "   Stopping the synthetics agent Docker container..."
          local cid
          cid=$(_synth_find_agent_container)
          if [[ -z "$cid" ]]; then
            echo "   ❌ No synthetics agent container found. Is it running?"
            return 1
          fi
          docker stop "$cid"
          echo "   ✅ Container $cid stopped. Agent will appear offline in ~5 min."
          echo "   Restore: run-data synthetics fix agent-offline"
          ;;

        revision-mismatch)
          echo "💥  Scenario: Policy Revision Mismatch"
          local cid
          cid=$(_synth_find_agent_container)
          if [[ -z "$cid" ]]; then
            echo "   ❌ No synthetics agent container found."
            return 1
          fi
          echo "   Step 1: Stopping agent container $cid..."
          docker stop "$cid"

          local loc_id
          loc_id=$(_synth_find_private_location)
          if [[ -z "$loc_id" ]]; then
            echo "   ❌ No private location found. Run 'run-data synthetics' first."
            return 1
          fi
          echo "   Step 2: Creating monitor to bump policy revision..."
          local resp
          resp=$(curl -s -X POST "$KIBANA_URL/api/synthetics/monitors" \
            -H "kbn-xsrf: true" -H "elastic-api-version: 2023-10-31" \
            -H "Content-Type: application/json" -u "$AUTH" \
            -d '{
              "type": "http",
              "name": "[BREAK] revision-mismatch probe",
              "urls": "https://example.com",
              "schedule": { "number": "10", "unit": "m" },
              "locations": [{ "id": "'"$loc_id"'", "isServiceManaged": false }]
            }' 2>/dev/null)
          local new_id
          new_id=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
          if [[ -n "$new_id" ]]; then
            echo "   ✅ Monitor $new_id created. Agent stopped on old policy revision → mismatch."
          else
            echo "   ❌ Failed to create monitor: $resp"
          fi
          echo "   Restore: run-data synthetics fix revision-mismatch"
          ;;

        zero-data)
          echo "💥  Scenario: Private Location Monitor with Zero Check Results"
          local cid
          cid=$(_synth_find_agent_container)
          if [[ -n "$cid" ]]; then
            echo "   Stopping agent to prevent data collection..."
            docker stop "$cid"
          fi
          local loc_id
          loc_id=$(_synth_find_private_location)
          if [[ -z "$loc_id" ]]; then
            echo "   ❌ No private location found. Run 'run-data synthetics' first."
            return 1
          fi
          echo "   Creating monitor on private location (agent down → zero data)..."
          local resp
          resp=$(curl -s -X POST "$KIBANA_URL/api/synthetics/monitors" \
            -H "kbn-xsrf: true" -H "elastic-api-version: 2023-10-31" \
            -H "Content-Type: application/json" -u "$AUTH" \
            -d '{
              "type": "browser",
              "name": "[BREAK] zero-data monitor",
              "urls": "https://elastic.co",
              "schedule": { "number": "10", "unit": "m" },
              "locations": [{ "id": "'"$loc_id"'", "isServiceManaged": false }]
            }' 2>/dev/null)
          local new_id
          new_id=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
          if [[ -n "$new_id" ]]; then
            echo "   ✅ Monitor $new_id created with no agent to run it → zero check results."
          else
            echo "   ❌ Failed to create monitor: $resp"
          fi
          echo "   Restore: run-data synthetics fix zero-data"
          ;;

        fleet-degraded)
          echo "💥  Scenario: Fleet Server Degraded"
          local cid
          cid=$(_synth_find_fleet_container)
          if [[ -z "$cid" ]]; then
            echo "   ❌ No Fleet Server container found."
            return 1
          fi
          echo "   Stopping Fleet Server container $cid..."
          docker stop "$cid"
          echo "   ✅ Fleet Server stopped. Agent will show DEGRADED/OFFLINE."
          echo "   Restore: run-data synthetics fix fleet-degraded"
          ;;

        orphaned-data)
          echo "💥  Scenario: Orphaned Monitor Data in ES"
          echo "   Creating temporary monitor on public location..."
          local resp
          resp=$(curl -s -X POST "$KIBANA_URL/api/synthetics/monitors" \
            -H "kbn-xsrf: true" -H "elastic-api-version: 2023-10-31" \
            -H "Content-Type: application/json" -u "$AUTH" \
            -d '{
              "type": "browser",
              "name": "[BREAK] orphan-data monitor",
              "urls": "https://google.com",
              "schedule": { "number": "3", "unit": "m" },
              "locations": [{ "id": "us_central_qa", "label": "US Central QA", "isServiceManaged": true }]
            }' 2>/dev/null)
          local new_id
          new_id=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
          if [[ -z "$new_id" ]]; then
            echo "   ❌ Failed to create monitor: $resp"
            return 1
          fi
          echo "   Monitor $new_id created. Waiting 3 minutes for data..."
          local elapsed=0
          while [[ $elapsed -lt 180 ]]; do
            sleep 30
            elapsed=$((elapsed + 30))
            echo "   ⏳ ${elapsed}s / 180s..."
          done
          echo "   Deleting monitor (data stays in ES)..."
          curl -s -X DELETE "$KIBANA_URL/api/synthetics/monitors/$new_id" \
            -H "kbn-xsrf: true" -H "elastic-api-version: 2023-10-31" \
            -u "$AUTH" > /dev/null 2>&1
          echo "   ✅ Monitor deleted. Orphaned data remains for monitor.id=$new_id."
          echo "   Restore: run-data synthetics fix orphaned-data"
          ;;

        policy-disabled)
          echo "💥  Scenario: Package Policy Disabled (Monitor-Fleet Desync)"
          local pp_id
          pp_id=$(_synth_find_package_policy)
          if [[ -z "$pp_id" ]]; then
            echo "   ❌ No synthetics package policies found."
            return 1
          fi
          echo "   Disabling package policy $pp_id via Fleet API..."
          local pp_body
          pp_body=$(curl -s "$KIBANA_URL/api/fleet/package_policies/$pp_id" \
            -H "kbn-xsrf: true" -u "$AUTH" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
item = data.get('item', data)
item['enabled'] = False
for k in ['revision', 'created_at', 'created_by', 'updated_at', 'updated_by',
           'version', 'spaceIds', 'elasticsearch']:
    item.pop(k, None)
json.dump(item, sys.stdout)
" 2>/dev/null)
          if [[ -z "$pp_body" ]]; then
            echo "   ❌ Failed to fetch package policy."
            return 1
          fi
          local put_resp
          put_resp=$(curl -s -X PUT "$KIBANA_URL/api/fleet/package_policies/$pp_id" \
            -H "kbn-xsrf: true" -H "Content-Type: application/json" \
            -H "elastic-api-version: 2023-10-31" \
            -u "$AUTH" -d "$pp_body" 2>/dev/null)
          if echo "$put_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'item' in d" 2>/dev/null; then
            echo "   ✅ Package policy $pp_id disabled. Monitor still shows enabled in Kibana."
          else
            echo "   ❌ Failed to disable: $(echo "$put_resp" | head -3)"
          fi
          echo "   Restore: run-data synthetics fix policy-disabled"
          ;;

        orphaned-policy)
          echo "💥  Scenario: Orphaned Package Policy"
          local monitor_id
          monitor_id=$(_synth_find_private_monitor)
          if [[ -z "$monitor_id" ]]; then
            echo "   ❌ No private location monitors found."
            return 1
          fi
          echo "   Deleting monitor SO from ES (bypassing Fleet cleanup)..."
          local del_resp
          del_resp=$(curl -s -X POST \
            "$KIBANA_URL/api/console/proxy?path=.kibana*%2F_delete_by_query&method=POST" \
            -H "kbn-xsrf: true" -H "Content-Type: application/json" \
            -u "$AUTH" \
            -d '{"query":{"bool":{"should":[
              {"term":{"synthetics-monitor.config_id":"'"$monitor_id"'"}},
              {"term":{"synthetics-monitor-multi-space.config_id":"'"$monitor_id"'"}}
            ]}}}' 2>/dev/null)
          local deleted
          deleted=$(echo "$del_resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('deleted',0))" 2>/dev/null)
          echo "   Deleted $deleted SO doc(s) for monitor $monitor_id."
          echo "   ✅ Package policy remains in Fleet but monitor is gone → orphaned."
          echo "   Restore: run-data synthetics fix orphaned-policy"
          ;;

        agent-unenrolled)
          echo "💥  Scenario: Agent Unenrolled (Monitors Still Configured)"
          local agent_id
          agent_id=$(_synth_find_agent)
          if [[ -z "$agent_id" ]]; then
            echo "   ❌ No synthetics agent found."
            return 1
          fi
          echo "   Force-unenrolling agent $agent_id..."
          curl -s -X POST "$KIBANA_URL/api/fleet/agents/$agent_id/unenroll" \
            -H "kbn-xsrf: true" -H "Content-Type: application/json" \
            -H "elastic-api-version: 2023-10-31" \
            -u "$AUTH" -d '{"force":true,"revoke":true}' > /dev/null 2>&1
          echo "   ✅ Agent unenrolled. Private location has 0 agents but monitors still exist."
          echo "   Restore: run-data synthetics fix agent-unenrolled"
          ;;

        service-disabled)
          echo "💥  Scenario: Synthetics Service Disabled"
          echo "   Disabling Synthetics service (invalidates API key)..."
          curl -s -X DELETE "$KIBANA_URL/internal/synthetics/service/enablement" \
            -H "kbn-xsrf: true" -u "$AUTH" > /dev/null 2>&1
          echo "   ✅ Synthetics service disabled. Public location monitors stop syncing."
          echo "   Restore: run-data synthetics fix service-disabled"
          ;;

        all)
          echo "💥💥💥  CHAOS MODE — triggering all failure scenarios"
          echo ""
          for s in agent-offline revision-mismatch zero-data fleet-degraded orphaned-data \
                   policy-disabled orphaned-policy agent-unenrolled service-disabled; do
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            _synth_break "$s"
            echo ""
          done
          echo "💥💥💥  All scenarios triggered."
          ;;

        help|*)
          echo "Available break scenarios:"
          echo "  agent-offline      Stop the synthetics agent container"
          echo "  revision-mismatch  Stop agent + add monitor (policy rev diverges)"
          echo "  zero-data          Create monitor on private loc with agent down"
          echo "  fleet-degraded     Stop Fleet Server container"
          echo "  orphaned-data      Create + delete monitor (data remains in ES)"
          echo "  policy-disabled    Disable Fleet package policy (monitor still enabled)"
          echo "  orphaned-policy    Delete monitor SO (package policy remains)"
          echo "  agent-unenrolled   Unenroll agent (monitors still configured)"
          echo "  service-disabled   Disable Synthetics service (API key invalidated)"
          echo "  all                Trigger all scenarios (chaos mode)"
          [[ "$scenario" != "help" ]] && return 1
          ;;
      esac
    }

    # ============================================================
    #  FIX — restore from Synthetics failure scenarios
    # ============================================================
    _synth_fix() {
      local scenario="$1"
      case "$scenario" in

        agent-offline)
          echo "🔧  Fix: Agent Offline"
          echo "   Starting stopped elastic-agent containers..."
          local started=0
          for cid in $(docker ps -a --filter "status=exited" --format '{{.ID}} {{.Image}}' 2>/dev/null \
                       | grep elastic-agent | awk '{print $1}'); do
            docker start "$cid"
            started=$((started + 1))
          done
          if [[ $started -gt 0 ]]; then
            echo "   ✅ Started $started container(s). Agent should come online within ~1 min."
          else
            echo "   ⚠ No stopped elastic-agent containers. May need: run-data synthetics"
          fi
          ;;

        revision-mismatch)
          echo "🔧  Fix: Policy Revision Mismatch"
          echo "   Cleaning up [BREAK] monitors..."
          curl -s "$KIBANA_URL/api/synthetics/monitors?perPage=100" \
            -H "kbn-xsrf: true" -H "elastic-api-version: 2023-10-31" \
            -u "$AUTH" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('monitors', []):
    if '[BREAK]' in m.get('name', ''):
        print(m['config_id'])
" 2>/dev/null | while read mid; do
            curl -s -X DELETE "$KIBANA_URL/api/synthetics/monitors/$mid" \
              -H "kbn-xsrf: true" -H "elastic-api-version: 2023-10-31" \
              -u "$AUTH" > /dev/null 2>&1
            echo "   Deleted monitor $mid"
          done
          echo "   Restarting agent containers..."
          _synth_fix agent-offline
          echo "   ✅ Agent will sync to latest policy revision on next check-in."
          ;;

        zero-data)
          echo "🔧  Fix: Zero Check Results"
          _synth_fix revision-mismatch
          echo "   ✅ Agent will produce data on next schedule interval."
          ;;

        fleet-degraded)
          echo "🔧  Fix: Fleet Server Degraded"
          echo "   Starting stopped Fleet Server containers..."
          local started=0
          for cid in $(docker ps -a --filter "status=exited" --format '{{.ID}} {{.Names}}' 2>/dev/null \
                       | grep -i fleet | awk '{print $1}'); do
            docker start "$cid"
            started=$((started + 1))
          done
          if [[ $started -gt 0 ]]; then
            echo "   ✅ Started $started Fleet Server container(s)."
          else
            echo "   ⚠ No stopped Fleet Server containers. May need: run-data synthetics"
          fi
          ;;

        orphaned-data)
          echo "🔧  Fix: Orphaned Monitor Data"
          echo "   Finding monitor IDs in ES with no matching Kibana config..."
          local active_ids
          active_ids=$(curl -s "$KIBANA_URL/api/synthetics/monitors?perPage=100" \
            -H "kbn-xsrf: true" -H "elastic-api-version: 2023-10-31" \
            -u "$AUTH" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('monitors', []): print(m['config_id'])
" 2>/dev/null)

          local es_ids
          es_ids=$(curl -s -k "$ES_HOST/synthetics-*/_search" \
            -H "Content-Type: application/json" -u "$ES_AUTH" \
            -d '{"size":0,"aggs":{"ids":{"terms":{"field":"monitor.id","size":200}}}}' 2>/dev/null \
            | python3 -c "
import sys, json
data = json.load(sys.stdin)
for b in data.get('aggregations',{}).get('ids',{}).get('buckets',[]): print(b['key'])
" 2>/dev/null)

          local cleaned=0
          for eid in ${(f)es_ids}; do
            [[ -z "$eid" ]] && continue
            if ! echo "$active_ids" | grep -q "$eid"; then
              echo "   Deleting orphaned data for monitor.id=$eid..."
              curl -s -k -X POST "$ES_HOST/synthetics-*/_delete_by_query" \
                -H "Content-Type: application/json" -u "$ES_AUTH" \
                -d '{"query":{"term":{"monitor.id":"'"$eid"'"}}}' > /dev/null 2>&1
              cleaned=$((cleaned + 1))
            fi
          done
          echo "   ✅ Cleaned $cleaned orphaned monitor dataset(s)."
          ;;

        policy-disabled)
          echo "🔧  Fix: Package Policy Disabled"
          echo "   Re-enabling disabled synthetics package policies..."
          curl -s "$KIBANA_URL/api/fleet/package_policies?kuery=fleet-package-policies.package.name:synthetics&perPage=100" \
            -H "kbn-xsrf: true" -u "$AUTH" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('items', []):
    if not item.get('enabled', True):
        print(item['id'])
" 2>/dev/null | while read pp_id; do
            local body
            body=$(curl -s "$KIBANA_URL/api/fleet/package_policies/$pp_id" \
              -H "kbn-xsrf: true" -u "$AUTH" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
item = data.get('item', data)
item['enabled'] = True
for k in ['revision', 'created_at', 'created_by', 'updated_at', 'updated_by',
           'version', 'spaceIds', 'elasticsearch']:
    item.pop(k, None)
json.dump(item, sys.stdout)
" 2>/dev/null)
            curl -s -X PUT "$KIBANA_URL/api/fleet/package_policies/$pp_id" \
              -H "kbn-xsrf: true" -H "Content-Type: application/json" \
              -H "elastic-api-version: 2023-10-31" \
              -u "$AUTH" -d "$body" > /dev/null 2>&1
            echo "   Re-enabled $pp_id"
          done
          echo "   ✅ Package policies re-enabled."
          ;;

        orphaned-policy)
          echo "🔧  Fix: Orphaned Package Policy"
          echo "   Finding package policies with no matching monitor..."
          local monitor_ids
          monitor_ids=$(curl -s "$KIBANA_URL/api/synthetics/monitors?perPage=100" \
            -H "kbn-xsrf: true" -H "elastic-api-version: 2023-10-31" \
            -u "$AUTH" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('monitors', []): print(m['config_id'])
" 2>/dev/null)

          curl -s "$KIBANA_URL/api/fleet/package_policies?kuery=fleet-package-policies.package.name:synthetics&perPage=100" \
            -H "kbn-xsrf: true" -u "$AUTH" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('items', []):
    print(item['id'])
" 2>/dev/null | while read pp_id; do
            # Package policy ID pattern: {monitorConfigId}-{locationId}
            # Check if any active monitor ID is a prefix of this package policy ID
            local is_orphan=true
            for mid in ${(f)monitor_ids}; do
              [[ -z "$mid" ]] && continue
              if [[ "$pp_id" == "$mid"* ]]; then
                is_orphan=false
                break
              fi
            done
            if [[ "$is_orphan" == true ]]; then
              echo "   Deleting orphaned package policy $pp_id..."
              curl -s -X DELETE "$KIBANA_URL/internal/synthetics/monitor/policy/$pp_id" \
                -H "kbn-xsrf: true" -u "$AUTH" > /dev/null 2>&1
            fi
          done
          echo "   ✅ Orphaned package policies cleaned."
          ;;

        agent-unenrolled)
          echo "🔧  Fix: Agent Unenrolled"
          echo "   Re-enrolling requires the full synthetics setup..."
          node x-pack/scripts/synthetics_private_location.js \
            --elasticsearch-host "${ES_HOST}" \
            --kibana-url "$KIBANA_URL" \
            --kibana-username "${DATA_USERNAME}" \
            --kibana-password "${DATA_PASSWORD}"
          echo "   ✅ Agent re-enrolled."
          ;;

        service-disabled)
          echo "🔧  Fix: Synthetics Service Disabled"
          echo "   Re-enabling Synthetics service..."
          curl -s -X PUT "$KIBANA_URL/internal/synthetics/service/enablement" \
            -H "kbn-xsrf: true" -u "$AUTH" > /dev/null 2>&1
          echo "   ✅ Synthetics service re-enabled. Public location monitors will resume."
          ;;

        all)
          echo "🔧🔧🔧  FULL RESTORE — fixing all scenarios"
          echo ""
          # Order matters: re-enable service first, fix policies, then restart containers last
          for s in service-disabled policy-disabled orphaned-policy orphaned-data \
                   fleet-degraded agent-offline revision-mismatch zero-data agent-unenrolled; do
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            _synth_fix "$s"
            echo ""
          done
          echo "🔧🔧🔧  All scenarios restored."
          ;;

        help|*)
          echo "Available fix scenarios:"
          echo "  agent-offline      Restart stopped agent containers"
          echo "  revision-mismatch  Clean [BREAK] monitors + restart agent"
          echo "  zero-data          Clean [BREAK] monitors + restart agent"
          echo "  fleet-degraded     Restart Fleet Server containers"
          echo "  orphaned-data      Delete orphaned check data from ES"
          echo "  policy-disabled    Re-enable disabled package policies"
          echo "  orphaned-policy    Delete package policies with no monitor"
          echo "  agent-unenrolled   Re-enroll agent (full synthetics setup)"
          echo "  service-disabled   Re-enable Synthetics service"
          echo "  all                Fix everything"
          [[ "$scenario" != "help" ]] && return 1
          ;;
      esac
    }

    # ── Route synthetics subcommands ──────────────────────────
    case "$2" in
      break)
        if [[ -z "$3" ]]; then
          echo "Usage: run-data synthetics break <scenario>"
          _synth_break help
          exit 1
        fi
        _synth_break "$3"
        ;;
      fix)
        if [[ -z "$3" ]]; then
          echo "Usage: run-data synthetics fix <scenario>"
          _synth_fix help
          exit 1
        fi
        _synth_fix "$3"
        ;;
      reset)
        echo "🧹  Reset — clearing all Fleet + Synthetics state"
        echo ""

        # Helper: extract IDs from JSON using python3 (avoids fragile grep on nested JSON)
        extract_ids() {
          echo "$1" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    items = $2
    for item in items:
        val = item.get('$3', '')
        if val:
            print(val)
except: pass
" 2>/dev/null
        }

        # 1. Delete all synthetics monitors (via Kibana API)
        echo "▶ Deleting synthetics monitors..."
        local monitors_response monitor_count=0
        monitors_response=$(curl -s "$KIBANA_URL/api/synthetics/monitors?perPage=100" \
          -H "kbn-xsrf: true" -u "$AUTH" 2>/dev/null)
        local monitor_ids
        monitor_ids=$(extract_ids "$monitors_response" "data.get('monitors', [])" "config_id")
        for mid in ${(f)monitor_ids}; do
          [[ -z "$mid" ]] && continue
          curl -s -X DELETE "$KIBANA_URL/api/synthetics/monitors/$mid" \
            -H "kbn-xsrf: true" -u "$AUTH" > /dev/null 2>&1
          monitor_count=$((monitor_count + 1))
        done
        echo "   Deleted $monitor_count monitor(s)"

        # 2. Delete synthetics private locations (via Kibana API)
        echo "▶ Deleting synthetics private locations..."
        local locations loc_count=0
        locations=$(curl -s "$KIBANA_URL/api/synthetics/private_locations" \
          -H "kbn-xsrf: true" -u "$AUTH" 2>/dev/null)
        local loc_ids
        loc_ids=$(extract_ids "$locations" "data if isinstance(data, list) else []" "id")
        for loc_id in ${(f)loc_ids}; do
          [[ -z "$loc_id" ]] && continue
          curl -s -X DELETE "$KIBANA_URL/api/synthetics/private_locations/$loc_id" \
            -H "kbn-xsrf: true" -u "$AUTH" > /dev/null 2>&1
          loc_count=$((loc_count + 1))
        done
        echo "   Deleted $loc_count private location(s)"

        # 3. Force-unenroll all Fleet agents (via Fleet API)
        echo "▶ Unenrolling Fleet agents..."
        local all_agents_response agent_count=0
        all_agents_response=$(curl -s "$KIBANA_URL/api/fleet/agents?perPage=1000" \
          -H "kbn-xsrf: true" -u "$AUTH" 2>/dev/null)
        local all_agent_ids
        all_agent_ids=$(extract_ids "$all_agents_response" "data.get('items', data.get('list', []))" "id")
        for aid in ${(f)all_agent_ids}; do
          [[ -z "$aid" ]] && continue
          curl -s -X POST "$KIBANA_URL/api/fleet/agents/$aid/unenroll" \
            -H "kbn-xsrf: true" -H "Content-Type: application/json" \
            -u "$AUTH" -d '{"force":true,"revoke":true}' > /dev/null 2>&1
          agent_count=$((agent_count + 1))
        done
        echo "   Unenrolled $agent_count agent(s)"

        # 3b. Delete stale agent records from .fleet-agents (restricted system index — must use console proxy)
        echo "   Deleting stale agent records from .fleet-agents..."
        local fleet_agents_del
        fleet_agents_del=$(curl -s -X POST \
          "$KIBANA_URL/api/console/proxy?path=.fleet-agents-7%2F_delete_by_query%3Fconflicts%3Dproceed&method=POST" \
          -H "kbn-xsrf: true" -H "Content-Type: application/json" \
          -u "$AUTH" -d '{"query":{"match_all":{}}}' 2>/dev/null)
        local agents_deleted
        agents_deleted=$(echo "$fleet_agents_del" | python3 -c "import sys,json; print(json.load(sys.stdin).get('deleted',0))" 2>/dev/null)
        echo "   Deleted $agents_deleted stale agent record(s)"

        # 4. Delete Fleet agent policies (via Fleet API)
        echo "▶ Deleting Fleet agent policies..."
        local policies_response policy_count=0
        policies_response=$(curl -s "$KIBANA_URL/api/fleet/agent_policies?perPage=100" \
          -H "kbn-xsrf: true" -u "$AUTH" 2>/dev/null)
        local policy_ids
        policy_ids=$(extract_ids "$policies_response" "data.get('items', [])" "id")
        for pid in ${(f)policy_ids}; do
          [[ -z "$pid" ]] && continue
          curl -s -X POST "$KIBANA_URL/api/fleet/agent_policies/delete" \
            -H "kbn-xsrf: true" -H "Content-Type: application/json" \
            -u "$AUTH" -d "{\"agentPolicyId\":\"$pid\",\"force\":true}" > /dev/null 2>&1
          policy_count=$((policy_count + 1))
        done
        echo "   Deleted $policy_count agent policy/policies"

        # 5. Delete Fleet internal state from ES system indices
        echo ""
        echo "▶ Clearing Fleet system index data..."
        local proxy_response
        proxy_response=$(curl -s -X POST \
          "$KIBANA_URL/api/console/proxy?path=.kibana_ingest_*%2F_delete_by_query&method=POST" \
          -H "kbn-xsrf: true" -H "Content-Type: application/json" \
          -u "$AUTH" \
          -d '{"query":{"prefix":{"type":"fleet"}}}' 2>/dev/null)
        if echo "$proxy_response" | grep -q '"deleted"'; then
          local deleted_count
          deleted_count=$(echo "$proxy_response" | grep -o '"deleted":[0-9]*' | sed 's/"deleted"://')
          echo "   Deleted $deleted_count Fleet record(s) from .kibana_ingest_*"
        else
          echo "   ⚠ Could not clear .kibana_ingest_* — Fleet signing keys may still exist."
          echo "     Run manually in Dev Tools (http://localhost:${KIBANA_PORT}/app/dev_tools#/console):"
          echo "     POST .kibana_ingest_*/_delete_by_query"
          echo '     {"query":{"prefix":{"type":"fleet"}}}'
        fi

        # 6. Delete .fleet-* ES indices and data streams
        echo ""
        echo "▶ Deleting .fleet-* ES indices and data streams..."
        local idx_count=0

        local fleet_ds
        fleet_ds=$(curl -s -k "$ES_HOST/_data_stream/.fleet*" -u "$ES_AUTH" 2>/dev/null \
          | python3 -c "import sys,json; [print(ds['name']) for ds in json.load(sys.stdin).get('data_streams',[])]" 2>/dev/null)
        for ds in ${(f)fleet_ds}; do
          [[ -z "$ds" ]] && continue
          curl -s -k -X DELETE "$ES_HOST/_data_stream/$ds" \
            -H "X-elastic-product-origin: fleet" -u "$ES_AUTH" > /dev/null 2>&1
          idx_count=$((idx_count + 1))
        done

        local fleet_indices
        fleet_indices=$(curl -s -k "$ES_HOST/_cat/indices/.fleet*?h=index" \
          -u "$ES_AUTH" 2>/dev/null | tr -d ' ')
        for idx in ${(f)fleet_indices}; do
          [[ -z "$idx" ]] && continue
          curl -s -k -X DELETE "$ES_HOST/$idx" -u "$ES_AUTH" > /dev/null 2>&1
          idx_count=$((idx_count + 1))
        done

        if [[ $idx_count -gt 0 ]]; then
          echo "   Deleted $idx_count .fleet-* index/data stream(s)"
        else
          echo "   No .fleet-* indices found"
        fi

        # 7. Disable Synthetics service (invalidate API key)
        echo ""
        echo "▶ Disabling Synthetics service (invalidating API key)..."
        local synth_http
        synth_http=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
          "$KIBANA_URL/internal/synthetics/service/enablement" \
          -H "kbn-xsrf: true" -u "$AUTH" 2>/dev/null)
        if [[ "$synth_http" == "200" ]]; then
          echo "   Synthetics service disabled and API key invalidated."
        elif [[ "$synth_http" == "404" ]]; then
          echo "   Synthetics service was not enabled (nothing to disable)."
        else
          echo "   ⚠ Could not disable Synthetics service (HTTP $synth_http)."
        fi

        # 8. Delete orphaned synthetics data from ES
        echo ""
        echo "▶ Cleaning orphaned synthetics data..."
        local synth_doc_count
        synth_doc_count=$(curl -s -k "$ES_HOST/synthetics-*/_count" -u "$ES_AUTH" 2>/dev/null \
          | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null)
        if [[ "$synth_doc_count" -gt 0 ]] 2>/dev/null; then
          echo "   Found $synth_doc_count orphaned doc(s). Deleting..."
          curl -s -k -X POST "$ES_HOST/synthetics-*/_delete_by_query?conflicts=proceed" \
            -H "Content-Type: application/json" -u "$ES_AUTH" \
            -d '{"query":{"match_all":{}}}' > /dev/null 2>&1
          echo "   Deleted $synth_doc_count doc(s) from synthetics-* data streams."
        else
          echo "   No orphaned synthetics data found."
        fi

        echo ""
        echo "✅  Fleet + Synthetics state cleared. Restart Kibana so preconfiguration runs fresh:"
        echo "    ~/dev-start.sh restart main    # or feat, or <branch>"
        ;;
      "")
        echo "DEBUG ES_HOST=${ES_HOST}"
        node x-pack/scripts/synthetics_private_location.js \
          --elasticsearch-host "${ES_HOST}" \
          --kibana-url "$KIBANA_URL" \
          --kibana-username "${DATA_USERNAME}" \
          --kibana-password "${DATA_PASSWORD}"
        ;;
      *)
        echo "Usage: run-data synthetics [break|fix|reset] [scenario]"
        echo ""
        echo "  (no args)  Create private location (default setup)"
        echo "  break <s>  Trigger failure scenario <s>"
        echo "  fix <s>    Restore from failure scenario <s>"
        echo "  reset      Wipe all Fleet + Synthetics state"
        echo ""
        echo "Run 'run-data synthetics break help' for scenario list."
        exit 1
        ;;
    esac
    ;;

  *)
    echo "Usage: run-data [slo|synthetics]"
    exit 1
    ;;
esac
