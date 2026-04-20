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
# Mock oblt-cli — handles cluster secrets, cluster list, cluster create, cluster destroy
subcmd="" action=""
cluster_name="" output_file=""
# Parse subcommand and action
if [[ "$1" == "cluster" ]]; then
  subcmd="cluster"
  action="$2"
  shift 2
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-name) cluster_name="$2"; shift 2 ;;
    --output-file)  output_file="$2"; shift 2 ;;
    *)              shift ;;
  esac
done

# Handle cluster list — reads from MOCK_CLUSTER_LIST_FILE if set
if [[ "$action" == "list" ]]; then
  if [[ -n "${MOCK_CLUSTER_LIST_FILE:-}" && -f "$MOCK_CLUSTER_LIST_FILE" ]]; then
    cat "$MOCK_CLUSTER_LIST_FILE"
  else
    # Default: no clusters
    echo "┌──────────────┐"
    echo "│ CLUSTER NAME │"
    echo "├──────────────┤"
    echo "└──────────────┘"
  fi
  exit 0
fi

# Handle cluster destroy
if [[ "$action" == "destroy" ]]; then
  echo "Cluster '$cluster_name' destroyed"
  exit 0
fi

# Handle cluster create
if [[ "$action" == "create" ]]; then
  echo "Cluster creation is requested : mock-new-cluster"
  exit 0
fi

# Handle cluster secrets (default: kibana-config)
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

# Extract helper functions and cmd_renew from dev-start.sh
eval "$(sed -n '/^get_remote_es_version()/,/^}/p' "$PROJECT_DIR/dev-start.sh")"
eval "$(sed -n '/^get_kibana_version()/,/^}/p' "$PROJECT_DIR/dev-start.sh")"
eval "$(sed -n '/^major_minor()/,/^}/p' "$PROJECT_DIR/dev-start.sh")"
eval "$(sed -n '/^offer_cluster_create()/,/^}/p' "$PROJECT_DIR/dev-start.sh")"
eval "$(sed -n '/^offer_cluster_replace()/,/^}/p' "$PROJECT_DIR/dev-start.sh")"
eval "$(sed -n '/^handle_version_mismatch()/,/^}/p' "$PROJECT_DIR/dev-start.sh")"
eval "$(sed -n '/^save_cluster_name_to_conf()/,/^}/p' "$PROJECT_DIR/dev-start.sh")"
eval "$(sed -n '/^generate_remote_kibana_dev_yml()/,/^}/p' "$PROJECT_DIR/dev-start.sh")"
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


# ══════════════════════════════════════════════════════════
#  CLUSTER HEALTH CHECK
# ══════════════════════════════════════════════════════════

describe "renew — cluster health check"

# Helper: create a mock curl that returns a specific HTTP status code
mock_curl() {
  local status_code="$1"
  cat > "$MOCK_BIN/curl" <<CURLMOCK
#!/usr/bin/env bash
# Mock curl — returns a fixed HTTP status code
# Only respond to the -w "%{http_code}" pattern
for arg in "\$@"; do
  if [[ "\$arg" == "%{http_code}" ]]; then
    echo "$status_code"
    exit 0
  fi
done
exit 0
CURLMOCK
  chmod +x "$MOCK_BIN/curl"
}

# Helper: remove curl mock so real curl isn't shadowed in later tests
unmock_curl() {
  rm -f "$MOCK_BIN/curl"
}

# Helper: set up mock oblt-cli cluster list output
# Usage: mock_cluster_list "cluster-a" "cluster-b" ...
mock_cluster_list() {
  export MOCK_CLUSTER_LIST_FILE="$TEST_DIR/mock-cluster-list.txt"
  {
    echo "┌──────────────────────────┐"
    echo "│       CLUSTER NAME       │"
    echo "├──────────────────────────┤"
    for name in "$@"; do
      echo "│ $name │"
    done
    echo "└──────────────────────────┘"
  } > "$MOCK_CLUSTER_LIST_FILE"
}

# Helper: clear mock cluster list
unmock_cluster_list() {
  rm -f "$TEST_DIR/mock-cluster-list.txt"
  unset MOCK_CLUSTER_LIST_FILE
}

# Helper: create a fake Kibana dir with package.json
setup_fake_kibana() {
  local dir="$1" version="$2"
  mkdir -p "$dir"
  echo "{ \"name\": \"kibana\", \"version\": \"$version\" }" > "$dir/package.json"
}

it "reports cluster reachable on HTTP 200"
  setup_renew_env
  mock_curl 200
  output=$(cmd_renew --cluster-name healthy-cluster 2>&1)
  assert_contains "$output" "reachable"
  unmock_curl

it "reports cluster reachable on HTTP 401 (auth required = ES is up)"
  setup_renew_env
  mock_curl 401
  output=$(cmd_renew --cluster-name auth-cluster 2>&1)
  assert_contains "$output" "reachable"
  unmock_curl

it "reports cluster unreachable on HTTP 000 (timeout/DNS failure)"
  setup_renew_env
  mock_curl 000
  output=$(cmd_renew --cluster-name dead-cluster 2>&1)
  assert_contains "$output" "unreachable"
  unmock_curl

it "falls back to authenticated request on 503 and reports reachable"
  setup_renew_env
  # Mock curl: unauthenticated → 503, authenticated (-u flag) → 200
  cat > "$MOCK_BIN/curl" <<'CURLMOCK'
#!/usr/bin/env bash
is_http_code=false
is_auth=false
for arg in "$@"; do
  [[ "$arg" == "%{http_code}" ]] && is_http_code=true
  [[ "$arg" == "-u" ]] && is_auth=true
done
if [[ "$is_http_code" == true ]]; then
  if [[ "$is_auth" == true ]]; then
    echo "200"
  else
    echo "503"
  fi
  exit 0
fi
echo '{ "version": { "number": "9.4.0" } }'
exit 0
CURLMOCK
  chmod +x "$MOCK_BIN/curl"
  KIBANA_MAIN_DIR="$TEST_DIR/kibana-main-503"
  setup_fake_kibana "$KIBANA_MAIN_DIR" "9.4.0"
  output=$(cmd_renew --cluster-name cloud-cluster 2>&1)
  assert_contains "$output" "reachable"
  unmock_curl

it "reports unhealthy when authenticated fallback also fails"
  setup_renew_env
  # Mock curl: both unauthenticated and authenticated → 503
  mock_curl 503
  output=$(cmd_renew --cluster-name sick-cluster 2>&1)
  assert_contains "$output" "unhealthy"
  unmock_curl

it "shows destroy command for unhealthy cluster"
  setup_renew_env
  mock_curl 503
  output=$(cmd_renew --cluster-name sick-cluster 2>&1)
  assert_contains "$output" "oblt-cli cluster destroy"
  unmock_curl


# ══════════════════════════════════════════════════════════
#  VERSION HELPERS (unit tests)
# ══════════════════════════════════════════════════════════

describe "version helpers"

it "major_minor extracts major.minor from semver"
  result=$(major_minor "9.5.0")
  assert_eq "9.5" "$result"

it "major_minor handles pre-release versions"
  result=$(major_minor "9.5.0-SNAPSHOT")
  # "9.5.0-SNAPSHOT" → strips last .component → "9.5"
  # Actually: ${1%.*} on "9.5.0-SNAPSHOT" gives "9.5"
  # Wait — no. "9.5.0-SNAPSHOT" → %.*  removes ".0-SNAPSHOT" → "9.5"  ✓
  assert_eq "9.5" "$result"

it "get_kibana_version reads version from package.json"
  test_kbn_dir="$TEST_DIR/fake-kibana"
  mkdir -p "$test_kbn_dir"
  echo '{ "name": "kibana", "version": "9.5.0" }' > "$test_kbn_dir/package.json"
  result=$(get_kibana_version "$test_kbn_dir")
  assert_eq "9.5.0" "$result"

it "get_kibana_version returns empty for missing package.json"
  result=$(get_kibana_version "$TEST_DIR/nonexistent")
  assert_eq "" "$result"


# ══════════════════════════════════════════════════════════
#  VERSION MISMATCH DETECTION
# ══════════════════════════════════════════════════════════

describe "renew — version mismatch detection"

# Helper: mock curl to return both HTTP status and authenticated JSON response
mock_curl_with_version() {
  local status_code="$1" es_version="$2"
  cat > "$MOCK_BIN/curl" <<CURLMOCK
#!/usr/bin/env bash
# Mock curl — returns HTTP status for -w and version JSON for -u
is_http_code=false
is_auth=false
for arg in "\$@"; do
  [[ "\$arg" == "%{http_code}" ]] && is_http_code=true
  [[ "\$arg" == *:* ]] && is_auth=true
done
# If checking HTTP code (unauthenticated health check), return status
if [[ "\$is_http_code" == true ]]; then
  echo "$status_code"
  exit 0
fi
# If authenticated request (version check), return ES root JSON
echo '{ "version": { "number": "$es_version" } }'
exit 0
CURLMOCK
  chmod +x "$MOCK_BIN/curl"
}

it "shows version match when ES and Kibana are compatible"
  setup_renew_env
  KIBANA_MAIN_DIR="$TEST_DIR/kibana-main"
  setup_fake_kibana "$KIBANA_MAIN_DIR" "9.4.0"
  mock_curl_with_version 200 "9.4.0"
  output=$(cmd_renew --cluster-name compat-cluster 2>&1)
  assert_contains "$output" "Version check"
  unmock_curl

it "detects version mismatch between ES and Kibana (no ignoreVersionMismatch)"
  setup_renew_env
  KIBANA_MAIN_DIR="$TEST_DIR/kibana-main-95"
  setup_fake_kibana "$KIBANA_MAIN_DIR" "9.5.0"
  mock_curl_with_version 200 "9.4.0"
  output=$(echo "3" | cmd_renew --cluster-name mismatch-cluster 2>&1)
  assert_contains "$output" "Version mismatch"
  unmock_curl

it "shows info instead of warning when ignoreVersionMismatch is in session yml"
  setup_renew_env
  KIBANA_MAIN_DIR="$TEST_DIR/kibana-main-ignore2"
  setup_fake_kibana "$KIBANA_MAIN_DIR" "9.5.0"
  mkdir -p "$KIBANA_MAIN_DIR/config"
  printf "server:\n  port: 5602\nelasticsearch.ignoreVersionMismatch: true\n" \
    > "$KIBANA_MAIN_DIR/config/kibana.dev.yml"
  mock_curl_with_version 200 "9.4.0"
  output=$(cmd_renew --cluster-name ignore-cluster2 2>&1)
  assert_contains "$output" "Version note"
  assert_not_contains "$output" "Version mismatch"
  unmock_curl

it "offers destroy+create when no sessions are compatible (option chosen: skip)"
  setup_renew_env
  KIBANA_MAIN_DIR="$TEST_DIR/kibana-main-95b"
  setup_fake_kibana "$KIBANA_MAIN_DIR" "9.5.0"
  WORKTREE_BASE="$TEST_DIR/empty-worktrees"
  mkdir -p "$WORKTREE_BASE"
  STATE_FILE="$TEST_DIR/nonexistent-state"
  mock_curl_with_version 200 "9.4.0"
  output=$(echo "N" | cmd_renew --cluster-name old-cluster 2>&1)
  assert_contains "$output" "Destroy old cluster and create a new one"
  unmock_curl

it "shows compatible sessions when worktree matches ES version"
  setup_renew_env
  # Main is 9.5 (mismatched)
  KIBANA_MAIN_DIR="$TEST_DIR/kibana-main-mismatch"
  setup_fake_kibana "$KIBANA_MAIN_DIR" "9.5.0"
  # Hotfix worktree is 9.4 (compatible with ES)
  WORKTREE_BASE="$TEST_DIR/worktrees-compat"
  hotfix_dir="$WORKTREE_BASE/hotfix-94"
  mkdir -p "$hotfix_dir/config"
  setup_fake_kibana "$hotfix_dir" "9.4.0"
  printf "server:\n  port: 5603\n# Remote ES\nelasticsearch:\n  hosts: https://old.es.com:443\n" \
    > "$hotfix_dir/config/kibana.dev.yml"
  STATE_FILE="$TEST_DIR/nonexistent-state"
  FEAT_DIR=""
  mock_curl_with_version 200 "9.4.0"
  output=$(echo "3" | cmd_renew --cluster-name compat-wt-cluster 2>&1)
  assert_contains "$output" "still use this cluster"
  assert_contains "$output" "hotfix-94"
  unmock_curl

it "skips version check when ES version cannot be retrieved"
  setup_renew_env
  KIBANA_MAIN_DIR="$TEST_DIR/kibana-main-nocheck"
  setup_fake_kibana "$KIBANA_MAIN_DIR" "9.5.0"
  # Mock curl returns 401 for health but empty for auth request (can't get version)
  cat > "$MOCK_BIN/curl" <<'CURLMOCK'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == "%{http_code}" ]]; then
    echo "401"
    exit 0
  fi
done
echo ""
exit 1
CURLMOCK
  chmod +x "$MOCK_BIN/curl"
  output=$(cmd_renew --cluster-name no-version-cluster 2>&1)
  assert_contains "$output" "reachable"
  assert_not_contains "$output" "Version mismatch"
  unmock_curl



# ══════════════════════════════════════════════════════════
#  EXISTING CLUSTER DETECTION
# ══════════════════════════════════════════════════════════

describe "renew — existing cluster detection on version mismatch"

it "offers to switch to an existing cluster when one is available"
  setup_renew_env
  KIBANA_MAIN_DIR="$TEST_DIR/kibana-main-switch"
  setup_fake_kibana "$KIBANA_MAIN_DIR" "9.5.0"
  WORKTREE_BASE="$TEST_DIR/empty-worktrees-switch"
  mkdir -p "$WORKTREE_BASE"
  STATE_FILE="$TEST_DIR/nonexistent-state"
  mock_cluster_list "old-cluster" "new-cluster-95"
  mock_curl_with_version 200 "9.4.0"
  output=$(echo "3" | cmd_renew --cluster-name old-cluster 2>&1)
  assert_contains "$output" "Switch to"
  assert_contains "$output" "new-cluster-95"
  unmock_curl
  unmock_cluster_list

it "excludes the current mismatched cluster from the switch list"
  setup_renew_env
  KIBANA_MAIN_DIR="$TEST_DIR/kibana-main-exclude"
  setup_fake_kibana "$KIBANA_MAIN_DIR" "9.5.0"
  WORKTREE_BASE="$TEST_DIR/empty-worktrees-exclude"
  mkdir -p "$WORKTREE_BASE"
  STATE_FILE="$TEST_DIR/nonexistent-state"
  mock_cluster_list "current-cluster" "other-cluster"
  mock_curl_with_version 200 "9.4.0"
  output=$(echo "3" | cmd_renew --cluster-name current-cluster 2>&1)
  assert_not_contains "$output" "Switch to.*current-cluster"
  assert_contains "$output" "other-cluster"
  unmock_curl
  unmock_cluster_list

it "falls back to destroy+create when no other clusters exist"
  setup_renew_env
  KIBANA_MAIN_DIR="$TEST_DIR/kibana-main-noother"
  setup_fake_kibana "$KIBANA_MAIN_DIR" "9.5.0"
  WORKTREE_BASE="$TEST_DIR/empty-worktrees-noother"
  mkdir -p "$WORKTREE_BASE"
  STATE_FILE="$TEST_DIR/nonexistent-state"
  mock_cluster_list "only-cluster"
  mock_curl_with_version 200 "9.4.0"
  output=$(echo "N" | cmd_renew --cluster-name only-cluster 2>&1)
  assert_contains "$output" "Destroy old cluster and create a new one"
  assert_not_contains "$output" "Switch to"
  unmock_curl
  unmock_cluster_list

it "shows switch option alongside compatible sessions"
  setup_renew_env
  KIBANA_MAIN_DIR="$TEST_DIR/kibana-main-both"
  setup_fake_kibana "$KIBANA_MAIN_DIR" "9.5.0"
  # Hotfix worktree is 9.4 (compatible with ES)
  WORKTREE_BASE="$TEST_DIR/worktrees-both"
  hotfix_dir="$WORKTREE_BASE/hotfix-94"
  mkdir -p "$hotfix_dir/config"
  setup_fake_kibana "$hotfix_dir" "9.4.0"
  printf "server:\n  port: 5603\n# Remote ES\nelasticsearch:\n  hosts: https://old.es.com:443\n" \
    > "$hotfix_dir/config/kibana.dev.yml"
  STATE_FILE="$TEST_DIR/nonexistent-state"
  FEAT_DIR=""
  mock_cluster_list "old-cluster" "shiny-new-cluster"
  mock_curl_with_version 200 "9.4.0"
  output=$(echo "4" | cmd_renew --cluster-name old-cluster 2>&1)
  assert_contains "$output" "still use this cluster"
  assert_contains "$output" "Switch to"
  assert_contains "$output" "shiny-new-cluster"
  unmock_curl
  unmock_cluster_list



# ══════════════════════════════════════════════════════════
#  VERSION-AWARE SESSION REGENERATION
# ══════════════════════════════════════════════════════════

describe "renew — version-aware session regeneration"

it "skips incompatible sessions during credential regeneration"
  setup_renew_env
  TEMPLATE="$TEST_DIR/fake-template.yml"
  echo "# empty template" > "$TEMPLATE"
  # Main is 9.5 (matches new cluster)
  KIBANA_MAIN_DIR="$TEST_DIR/kibana-regen-main"
  setup_fake_kibana "$KIBANA_MAIN_DIR" "9.5.0"
  mkdir -p "$KIBANA_MAIN_DIR/config"
  printf "server:\n  port: 5602\n# Remote ES\nelasticsearch:\n  hosts: https://old.es.com:443\n" \
    > "$KIBANA_MAIN_DIR/config/kibana.dev.yml"
  # Hotfix worktree is 9.4 (should NOT be regenerated)
  WORKTREE_BASE="$TEST_DIR/worktrees-regen"
  hotfix_dir="$WORKTREE_BASE/hotfix-94"
  mkdir -p "$hotfix_dir/config"
  setup_fake_kibana "$hotfix_dir" "9.4.0"
  printf "server:\n  port: 5603\n# Remote ES\nelasticsearch:\n  hosts: https://old.es.com:443\n" \
    > "$hotfix_dir/config/kibana.dev.yml"
  STATE_FILE="$TEST_DIR/nonexistent-state"
  FEAT_DIR=""
  # Mock curl: return 9.5 for the new cluster (authenticated version check)
  mock_curl_with_version 200 "9.5.0"
  output=$(cmd_renew --cluster-name new-cluster-95 2>&1)
  assert_contains "$output" "Regenerated"
  assert_contains "$output" "kibana-main"
  unmock_curl

it "reports skipped incompatible sessions"
  setup_renew_env
  TEMPLATE="$TEST_DIR/fake-template.yml"
  echo "# empty template" > "$TEMPLATE"
  KIBANA_MAIN_DIR="$TEST_DIR/kibana-regen-main2"
  setup_fake_kibana "$KIBANA_MAIN_DIR" "9.5.0"
  mkdir -p "$KIBANA_MAIN_DIR/config"
  printf "server:\n  port: 5602\n# Remote ES\nelasticsearch:\n  hosts: https://old.es.com:443\n" \
    > "$KIBANA_MAIN_DIR/config/kibana.dev.yml"
  WORKTREE_BASE="$TEST_DIR/worktrees-regen2"
  hotfix_dir="$WORKTREE_BASE/hotfix-94b"
  mkdir -p "$hotfix_dir/config"
  setup_fake_kibana "$hotfix_dir" "9.4.0"
  printf "server:\n  port: 5603\n# Remote ES\nelasticsearch:\n  hosts: https://old.es.com:443\n" \
    > "$hotfix_dir/config/kibana.dev.yml"
  STATE_FILE="$TEST_DIR/nonexistent-state"
  FEAT_DIR=""
  mock_curl_with_version 200 "9.5.0"
  output=$(cmd_renew --cluster-name new-cluster-95b 2>&1)
  assert_contains "$output" "Skipped sessions incompatible"
  assert_contains "$output" "hotfix-94b"
  unmock_curl

it "does not skip sessions when ES version cannot be determined"
  setup_renew_env
  TEMPLATE="$TEST_DIR/fake-template.yml"
  echo "# empty template" > "$TEMPLATE"
  KIBANA_MAIN_DIR="$TEST_DIR/kibana-regen-nocheck"
  setup_fake_kibana "$KIBANA_MAIN_DIR" "9.5.0"
  mkdir -p "$KIBANA_MAIN_DIR/config"
  printf "server:\n  port: 5602\n# Remote ES\nelasticsearch:\n  hosts: https://old.es.com:443\n" \
    > "$KIBANA_MAIN_DIR/config/kibana.dev.yml"
  WORKTREE_BASE="$TEST_DIR/worktrees-regen-nocheck"
  hotfix_dir="$WORKTREE_BASE/hotfix-old"
  mkdir -p "$hotfix_dir/config"
  setup_fake_kibana "$hotfix_dir" "9.4.0"
  printf "server:\n  port: 5603\n# Remote ES\nelasticsearch:\n  hosts: https://old.es.com:443\n" \
    > "$hotfix_dir/config/kibana.dev.yml"
  STATE_FILE="$TEST_DIR/nonexistent-state"
  FEAT_DIR=""
  # Mock curl: returns 401 for health but empty for version
  cat > "$MOCK_BIN/curl" <<'CURLMOCK'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == "%{http_code}" ]]; then echo "200"; exit 0; fi
done
echo ""
exit 1
CURLMOCK
  chmod +x "$MOCK_BIN/curl"
  output=$(cmd_renew --cluster-name unknown-ver-cluster 2>&1)
  # Both sessions should be regenerated (no skipping)
  assert_contains "$output" "kibana-main"
  assert_contains "$output" "hotfix-old"
  assert_not_contains "$output" "Skipped incompatible"
  unmock_curl


# ── Print results ─────────────────────────────────────────
print_summary
