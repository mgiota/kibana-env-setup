#!/usr/bin/env bash
# ============================================================
#  test-renew.sh — tests for the renew command
#
#  Tests argument parsing, config saving, error handling.
#  Does NOT call oblt-cli — mocks it with a simple script.
# ============================================================

_SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
source "$_SELF_DIR/test-helpers.sh"


# ── Mock oblt-cli ────────────────────────────────────────
# Creates a fake oblt-cli that writes a dummy kibana config
MOCK_BIN="$TEST_DIR/bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/oblt-cli" <<'MOCK'
#!/usr/bin/env bash
# Mock oblt-cli — parses all args, writes dummy kibana config
cluster_name="" output_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-name) cluster_name="$2"; shift 2 ;;
    --output-file)  output_file="$2"; shift 2 ;;
    *)              shift ;;
  esac
done
if [[ -z "$output_file" ]]; then exit 1; fi
if [[ "$cluster_name" == "bad-cluster" ]]; then
  echo "Error: cluster not found" >&2; exit 1
fi
cat > "$output_file" <<EOF
elasticsearch:
  hosts: https://${cluster_name}.es.elastic-cloud.com:443
  username: kibana_system_user
  password: mock-pw-123
  ssl:
    verificationMode: none
EOF
exit 0
MOCK
chmod +x "$MOCK_BIN/oblt-cli"
export PATH="$MOCK_BIN:$PATH"


# ── Helper: extract and run cmd_renew ────────────────────
# We source a minimal version that includes the config block + cmd_renew
setup_renew_env() {
  # Reset state
  REMOTE_ES_CONFIG="$TEST_DIR/remote-es.yml"
  KIBANA_DEV_CONF="$TEST_DIR/dev.conf"
  OBLT_CLUSTER_NAME=""
  rm -f "$REMOTE_ES_CONFIG" "$KIBANA_DEV_CONF"

  # Colors (needed by cmd_renew)
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  NC='\033[0m'
}

# Extract cmd_renew from dev-start.sh
eval "$(sed -n '/^cmd_renew()/,/^}/p' "$PROJECT_DIR/dev-start.sh")"


# ══════════════════════════════════════════════════════════
#  ARGUMENT PARSING
# ══════════════════════════════════════════════════════════

describe "renew — argument parsing"

it "requires --cluster-name when no saved name"
  setup_renew_env
  output=$(cmd_renew 2>&1) || true
  assert_contains "$output" "No cluster name provided"

it "rejects unknown flags"
  setup_renew_env
  output=$(cmd_renew --invalid 2>&1) || true
  assert_contains "$output" "Unknown argument"

it "accepts --cluster-name"
  setup_renew_env
  output=$(cmd_renew --cluster-name test-cluster 2>&1)
  assert_contains "$output" "test-cluster"


# ══════════════════════════════════════════════════════════
#  SAVED CLUSTER NAME
# ══════════════════════════════════════════════════════════

describe "renew — saved cluster name"

it "uses saved OBLT_CLUSTER_NAME when no --cluster-name"
  setup_renew_env
  OBLT_CLUSTER_NAME="saved-cluster"
  output=$(cmd_renew 2>&1)
  assert_file_contains "$REMOTE_ES_CONFIG" "saved-cluster.es.elastic-cloud.com"

it "CLI --cluster-name overrides saved name"
  setup_renew_env
  OBLT_CLUSTER_NAME="saved-cluster"
  cmd_renew --cluster-name override-cluster >/dev/null 2>&1
  assert_file_contains "$REMOTE_ES_CONFIG" "override-cluster.es.elastic-cloud.com"


# ══════════════════════════════════════════════════════════
#  --save FLAG
# ══════════════════════════════════════════════════════════

describe "renew — --save flag"

it "creates config file with cluster name"
  setup_renew_env
  cmd_renew --cluster-name new-cluster --save >/dev/null 2>&1
  assert_file_contains "$KIBANA_DEV_CONF" 'OBLT_CLUSTER_NAME="new-cluster"'

it "updates existing config file"
  setup_renew_env
  echo 'OBLT_CLUSTER_NAME="old-cluster"' > "$KIBANA_DEV_CONF"
  cmd_renew --cluster-name updated-cluster --save >/dev/null 2>&1
  assert_file_contains "$KIBANA_DEV_CONF" 'OBLT_CLUSTER_NAME="updated-cluster"'
  assert_file_not_contains "$KIBANA_DEV_CONF" "old-cluster"

it "uncomments existing commented entry"
  setup_renew_env
  echo '# OBLT_CLUSTER_NAME="placeholder"' > "$KIBANA_DEV_CONF"
  cmd_renew --cluster-name real-cluster --save >/dev/null 2>&1
  assert_file_contains "$KIBANA_DEV_CONF" 'OBLT_CLUSTER_NAME="real-cluster"'


# ── Print results ─────────────────────────────────────────
print_summary
