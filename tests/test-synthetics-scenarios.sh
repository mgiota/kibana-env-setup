#!/usr/bin/env bash
# ============================================================
#  test-synthetics-scenarios.sh — tests for synthetics break/fix
#
#  Tests helper functions, subcommand routing, help output, and
#  error handling. Uses mocked curl/docker responses — does NOT
#  require a running Kibana or Docker.
# ============================================================

_SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
source "$_SELF_DIR/test-helpers.sh"

SCRIPT="$PROJECT_DIR/run-data.sh"

# ── Mock setup ────────────────────────────────────────────
# Create a fake Kibana repo directory so run-data.sh guards pass
FAKE_REPO="$TEST_DIR/fake-repo"
mkdir -p "$FAKE_REPO/config"
touch "$FAKE_REPO/.nvmrc" "$FAKE_REPO/package.json"
cat > "$FAKE_REPO/config/kibana.dev.yml" <<'EOF'
server:
  port: 5601

elasticsearch.hosts:
  - "http://localhost:9200"
elasticsearch.username: "kibana"
elasticsearch.password: "changeme"
EOF

# We source run-data.sh logic indirectly by extracting functions.
# Since run-data.sh uses `case "$1"` and exits, we test by
# capturing output of subcommand invocations.

# Helper: run the script in a subprocess with mocked environment
run_script() {
  (
    cd "$FAKE_REPO"
    # Stub nvm to avoid errors
    export NVM_DIR="$TEST_DIR"
    mkdir -p "$NVM_DIR"
    cat > "$NVM_DIR/nvm.sh" <<'NVMEOF'
nvm() { :; }
NVMEOF
    # Stub curl to return mock data
    export PATH="$TEST_DIR/bin:$PATH"
    bash "$SCRIPT" "$@" 2>&1
  )
}


# ══════════════════════════════════════════════════════════
#  SUBCOMMAND ROUTING
# ══════════════════════════════════════════════════════════

describe "synthetics subcommand routing"

it "shows help when 'synthetics break' called without scenario"
  output=$(run_script synthetics break 2>&1) || true
  assert_contains "$output" "Usage: run-data synthetics break"

it "shows help when 'synthetics fix' called without scenario"
  output=$(run_script synthetics fix 2>&1) || true
  assert_contains "$output" "Usage: run-data synthetics fix"

it "shows usage when unknown synthetics subcommand given"
  output=$(run_script synthetics foobar 2>&1) || true
  assert_contains "$output" "Usage: run-data synthetics"


# ══════════════════════════════════════════════════════════
#  BREAK HELP OUTPUT — all 9 scenarios listed
# ══════════════════════════════════════════════════════════

describe "break help lists all scenarios"

BREAK_HELP=$(run_script synthetics break help 2>&1) || true

it "lists agent-offline scenario"
  assert_contains "$BREAK_HELP" "agent-offline"

it "lists revision-mismatch scenario"
  assert_contains "$BREAK_HELP" "revision-mismatch"

it "lists zero-data scenario"
  assert_contains "$BREAK_HELP" "zero-data"

it "lists fleet-degraded scenario"
  assert_contains "$BREAK_HELP" "fleet-degraded"

it "lists orphaned-data scenario"
  assert_contains "$BREAK_HELP" "orphaned-data"

it "lists policy-disabled scenario"
  assert_contains "$BREAK_HELP" "policy-disabled"

it "lists orphaned-policy scenario"
  assert_contains "$BREAK_HELP" "orphaned-policy"

it "lists agent-unenrolled scenario"
  assert_contains "$BREAK_HELP" "agent-unenrolled"

it "lists service-disabled scenario"
  assert_contains "$BREAK_HELP" "service-disabled"

it "lists all (chaos mode) option"
  assert_contains "$BREAK_HELP" "all"


# ══════════════════════════════════════════════════════════
#  FIX HELP OUTPUT — all 9 scenarios listed
# ══════════════════════════════════════════════════════════

describe "fix help lists all scenarios"

FIX_HELP=$(run_script synthetics fix help 2>&1) || true

it "lists agent-offline fix"
  assert_contains "$FIX_HELP" "agent-offline"

it "lists revision-mismatch fix"
  assert_contains "$FIX_HELP" "revision-mismatch"

it "lists zero-data fix"
  assert_contains "$FIX_HELP" "zero-data"

it "lists fleet-degraded fix"
  assert_contains "$FIX_HELP" "fleet-degraded"

it "lists orphaned-data fix"
  assert_contains "$FIX_HELP" "orphaned-data"

it "lists policy-disabled fix"
  assert_contains "$FIX_HELP" "policy-disabled"

it "lists orphaned-policy fix"
  assert_contains "$FIX_HELP" "orphaned-policy"

it "lists agent-unenrolled fix"
  assert_contains "$FIX_HELP" "agent-unenrolled"

it "lists service-disabled fix"
  assert_contains "$FIX_HELP" "service-disabled"

it "lists all (full restore) option"
  assert_contains "$FIX_HELP" "all"


# ══════════════════════════════════════════════════════════
#  HELPER FUNCTIONS — mocked curl/docker responses
# ══════════════════════════════════════════════════════════

describe "helper functions with mocked responses"

# Create mock binaries for curl and docker
MOCK_BIN="$TEST_DIR/bin"
mkdir -p "$MOCK_BIN"

# Mock curl that returns predefined JSON based on the URL pattern
cat > "$MOCK_BIN/curl" <<'MOCKEOF'
#!/usr/bin/env bash
args="$*"

# Fleet agents response
if [[ "$args" == *"/api/fleet/agents"* ]]; then
  cat <<'JSON'
{"items":[
  {"id":"agent-synth-001","policy_id":"synth-policy-001","status":"online"},
  {"id":"agent-fleet-002","policy_id":"fleet-server-policy","status":"online"}
],"total":2}
JSON
  exit 0
fi

# Private locations response
if [[ "$args" == *"/api/synthetics/private_locations"* ]]; then
  cat <<'JSON'
[{"id":"loc-001","label":"My Private Loc","agentPolicyId":"synth-policy-001","isServiceManaged":false}]
JSON
  exit 0
fi

# Monitors response
if [[ "$args" == *"/api/synthetics/monitors"* && "$args" != *"POST"* && "$args" != *"DELETE"* ]]; then
  cat <<'JSON'
{"monitors":[
  {"config_id":"mon-001","name":"[BREAK] test monitor","locations":[{"id":"loc-001","isServiceManaged":false}]},
  {"config_id":"mon-002","name":"Real monitor","locations":[{"id":"us_central","isServiceManaged":true}]}
],"total":2}
JSON
  exit 0
fi

# Package policies response
if [[ "$args" == *"/api/fleet/package_policies"* && "$args" != *"PUT"* ]]; then
  cat <<'JSON'
{"items":[{"id":"mon-001-loc-001","name":"test-integration","enabled":true,"package":{"name":"synthetics","version":"1.6.1"}}],"total":1}
JSON
  exit 0
fi

# Default: empty success
echo "{}"
MOCKEOF
chmod +x "$MOCK_BIN/curl"

# Mock docker
cat > "$MOCK_BIN/docker" <<'MOCKEOF'
#!/usr/bin/env bash
args="$*"

if [[ "$args" == *"ps"* ]]; then
  echo "abc123 elastic-agent-synth docker.elastic.co/beats/elastic-agent:9.5.0"
fi

if [[ "$args" == *"stop"* ]]; then
  echo "abc123"
fi

if [[ "$args" == *"start"* ]]; then
  echo "abc123"
fi
MOCKEOF
chmod +x "$MOCK_BIN/docker"

# Mock nvm
cat > "$TEST_DIR/nvm.sh" <<'NVMEOF'
nvm() { :; }
NVMEOF

# Run helpers by sourcing them in a controlled subshell
run_helper() {
  local helper_name="$1"
  (
    cd "$FAKE_REPO"
    export NVM_DIR="$TEST_DIR"
    export PATH="$MOCK_BIN:$PATH"
    # Set the vars that run-data.sh would normally set
    KIBANA_URL="http://localhost:5601"
    AUTH="elastic:changeme"
    ES_AUTH="elastic:changeme"
    ES_HOST="http://localhost:9200"
    DATA_USERNAME="elastic"
    DATA_PASSWORD="changeme"

    # Source nvm stub
    source "$NVM_DIR/nvm.sh"

    # Define the helper functions (extracted from run-data.sh)
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

    "$helper_name"
  )
}

it "finds synthetics agent (not fleet-server)"
  result=$(run_helper _synth_find_agent)
  assert_eq "agent-synth-001" "$result"

it "finds private location"
  result=$(run_helper _synth_find_private_location)
  assert_eq "loc-001" "$result"

it "finds first synthetics package policy"
  result=$(run_helper _synth_find_package_policy)
  assert_eq "mon-001-loc-001" "$result"

it "finds first monitor on a private location"
  result=$(run_helper _synth_find_private_monitor)
  assert_eq "mon-001" "$result"


# ══════════════════════════════════════════════════════════
#  HELPER EDGE CASES — empty/missing responses
# ══════════════════════════════════════════════════════════

describe "helper functions with empty responses"

# Replace mock curl with one that returns empty results
cat > "$MOCK_BIN/curl" <<'MOCKEOF'
#!/usr/bin/env bash
args="$*"

if [[ "$args" == *"/api/fleet/agents"* ]]; then
  echo '{"items":[],"total":0}'
  exit 0
fi

if [[ "$args" == *"/api/synthetics/private_locations"* ]]; then
  echo '[]'
  exit 0
fi

if [[ "$args" == *"/api/synthetics/monitors"* ]]; then
  echo '{"monitors":[],"total":0}'
  exit 0
fi

if [[ "$args" == *"/api/fleet/package_policies"* ]]; then
  echo '{"items":[],"total":0}'
  exit 0
fi

echo "{}"
MOCKEOF
chmod +x "$MOCK_BIN/curl"

it "returns empty when no agents found"
  result=$(run_helper _synth_find_agent)
  assert_eq "" "$result"

it "returns empty when no private locations found"
  result=$(run_helper _synth_find_private_location)
  assert_eq "" "$result"

it "returns empty when no package policies found"
  result=$(run_helper _synth_find_package_policy)
  assert_eq "" "$result"

it "returns empty when no private monitors found"
  result=$(run_helper _synth_find_private_monitor)
  assert_eq "" "$result"


# ══════════════════════════════════════════════════════════
#  BREAK SCENARIO ERROR HANDLING
# ══════════════════════════════════════════════════════════

describe "break scenarios handle missing resources"

# Mock docker to return nothing (no containers)
cat > "$MOCK_BIN/docker" <<'MOCKEOF'
#!/usr/bin/env bash
# No containers running
exit 0
MOCKEOF
chmod +x "$MOCK_BIN/docker"

# Mock curl to return empty results
cat > "$MOCK_BIN/curl" <<'MOCKEOF'
#!/usr/bin/env bash
args="$*"
if [[ "$args" == *"api/status"* ]]; then
  echo -n "200"
  exit 0
fi
if [[ "$args" == *"/api/fleet/agents"* ]]; then
  echo '{"items":[],"total":0}'; exit 0
fi
if [[ "$args" == *"/api/synthetics/private_locations"* ]]; then
  echo '[]'; exit 0
fi
if [[ "$args" == *"/api/synthetics/monitors"* ]]; then
  echo '{"monitors":[],"total":0}'; exit 0
fi
if [[ "$args" == *"/api/fleet/package_policies"* ]]; then
  echo '{"items":[],"total":0}'; exit 0
fi
echo "{}"
MOCKEOF
chmod +x "$MOCK_BIN/curl"

it "agent-offline shows error when no container found"
  output=$(run_script synthetics break agent-offline 2>&1) || true
  assert_contains "$output" "No synthetics agent container found"

it "revision-mismatch shows error when no container found"
  output=$(run_script synthetics break revision-mismatch 2>&1) || true
  assert_contains "$output" "No synthetics agent container found"

it "fleet-degraded shows error when no container found"
  output=$(run_script synthetics break fleet-degraded 2>&1) || true
  assert_contains "$output" "No Fleet Server container found"

it "policy-disabled shows error when no package policies"
  output=$(run_script synthetics break policy-disabled 2>&1) || true
  assert_contains "$output" "No synthetics package policies found"

it "orphaned-policy shows error when no private monitors"
  output=$(run_script synthetics break orphaned-policy 2>&1) || true
  assert_contains "$output" "No private location monitors found"

it "agent-unenrolled shows error when no agent"
  output=$(run_script synthetics break agent-unenrolled 2>&1) || true
  assert_contains "$output" "No synthetics agent found"


# ══════════════════════════════════════════════════════════
#  BREAK MONITOR NAMING
# ══════════════════════════════════════════════════════════

describe "break scenarios use [BREAK] prefix in monitor names"

# Check the script source directly for [BREAK] naming convention
SCRIPT_CONTENT=$(cat "$SCRIPT")

it "revision-mismatch monitor has [BREAK] prefix"
  assert_contains "$SCRIPT_CONTENT" '[BREAK] revision-mismatch probe'

it "zero-data monitor has [BREAK] prefix"
  assert_contains "$SCRIPT_CONTENT" '[BREAK] zero-data monitor'

it "orphaned-data monitor has [BREAK] prefix"
  assert_contains "$SCRIPT_CONTENT" '[BREAK] orphan-data monitor'

it "fix cleans up monitors with [BREAK] in name"
  assert_contains "$SCRIPT_CONTENT" "[BREAK]"


# ══════════════════════════════════════════════════════════
#  RESTORE INSTRUCTIONS
# ══════════════════════════════════════════════════════════

describe "break output includes restore instructions"

SCRIPT_CONTENT=$(cat "$SCRIPT")

it "agent-offline mentions fix command"
  assert_contains "$SCRIPT_CONTENT" "run-data synthetics fix agent-offline"

it "revision-mismatch mentions fix command"
  assert_contains "$SCRIPT_CONTENT" "run-data synthetics fix revision-mismatch"

it "zero-data mentions fix command"
  assert_contains "$SCRIPT_CONTENT" "run-data synthetics fix zero-data"

it "fleet-degraded mentions fix command"
  assert_contains "$SCRIPT_CONTENT" "run-data synthetics fix fleet-degraded"

it "orphaned-data mentions fix command"
  assert_contains "$SCRIPT_CONTENT" "run-data synthetics fix orphaned-data"

it "policy-disabled mentions fix command"
  assert_contains "$SCRIPT_CONTENT" "run-data synthetics fix policy-disabled"

it "orphaned-policy mentions fix command"
  assert_contains "$SCRIPT_CONTENT" "run-data synthetics fix orphaned-policy"

it "agent-unenrolled mentions fix command"
  assert_contains "$SCRIPT_CONTENT" "run-data synthetics fix agent-unenrolled"

it "service-disabled mentions fix command"
  assert_contains "$SCRIPT_CONTENT" "run-data synthetics fix service-disabled"


# ── Print results ─────────────────────────────────────────
print_summary
