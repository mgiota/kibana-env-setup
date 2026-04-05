#!/usr/bin/env bash
# ============================================================
#  test-es-detection.sh — tests for remote ES detection logic
#
#  Tests the grep pattern used by both kbn-start.sh and run-data.sh
#  to detect whether kibana.dev.yml points to local or remote ES.
#  Covers both YAML formats (template + oblt-cli).
# ============================================================

_SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
source "$_SELF_DIR/test-helpers.sh"

# ── Helper: run the detection pattern against a config ────
# This mirrors the exact grep pipeline from kbn-start.sh lines 109-113
detect_remote_es() {
  local yml="$1"
  local es_host_line
  es_host_line=$(grep -E "^ *(- \"?|hosts: *)https?://" "$yml" 2>/dev/null \
    | grep -v "localhost" \
    | grep -v "127\.0\.0\.1" \
    | head -1 \
    | sed 's|^ *- *||; s|^ *hosts: *||' | tr -d '"' | tr -d ' ' || true)
  echo "$es_host_line"
}

# ── Helper: run the run-data.sh ES host extraction ────────
# Mirrors run-data.sh line 38
extract_es_host() {
  local yml="$1"
  grep -E "^ *(- \"?|hosts: *)https?://" "$yml" 2>/dev/null \
    | head -1 \
    | sed 's|^ *- *||; s|^ *hosts: *||' | tr -d '"' | tr -d ' '
}

# ── Helper: run the run-data.sh password extraction ───────
# Mirrors run-data.sh lines 46-48
extract_es_password() {
  local yml="$1"
  grep -E "^ *(elasticsearch\.)?password:" "$yml" 2>/dev/null \
    | grep -v "^#" | grep -v "kibana.password" \
    | head -1 | sed 's|.*password: *||' | tr -d '"' | tr -d ' '
}


# ══════════════════════════════════════════════════════════
#  TEMPLATE FORMAT (elasticsearch.hosts: array style)
# ══════════════════════════════════════════════════════════

describe "template format — local ES"

TEMPLATE_LOCAL="$TEST_DIR/template-local.yml"
cat > "$TEMPLATE_LOCAL" <<'EOF'
server:
  port: 5601
  restrictInternalApis: false

# localhost
elasticsearch.hosts:
  - "http://localhost:9200"
elasticsearch.username: "kibana"
elasticsearch.password: "changeme"
EOF

it "detects localhost as local (empty result)"
  result=$(detect_remote_es "$TEMPLATE_LOCAL")
  assert_eq "" "$result" "localhost should not be detected as remote"


describe "template format — remote ES (edited template)"

TEMPLATE_REMOTE="$TEST_DIR/template-remote.yml"
cat > "$TEMPLATE_REMOTE" <<'EOF'
server:
  port: 5601
  restrictInternalApis: false

# localhost
# elasticsearch.hosts:
#   - "http://localhost:9200"
# elasticsearch.username: "kibana"
# elasticsearch.password: "changeme"

elasticsearch.hosts:
  - "https://my-cluster.es.us-west2.gcp.elastic-cloud.com:443"
elasticsearch.username: "kibana_system_user"
elasticsearch.password: "super-secret"
EOF

it "detects remote ES host from template array format"
  result=$(detect_remote_es "$TEMPLATE_REMOTE")
  assert_eq "https://my-cluster.es.us-west2.gcp.elastic-cloud.com:443" "$result"


describe "template format — commented localhost with remote"

TEMPLATE_COMMENTED="$TEST_DIR/template-commented.yml"
cat > "$TEMPLATE_COMMENTED" <<'EOF'
server:
  port: 5601

# localhost (commented out)
# elasticsearch.hosts:
#   - "http://localhost:9200"

elasticsearch.hosts:
  - "https://remote.es.cloud:443"
elasticsearch.username: "kibana_system_user"
elasticsearch.password: "pw123"
EOF

it "ignores commented localhost lines"
  result=$(detect_remote_es "$TEMPLATE_COMMENTED")
  assert_eq "https://remote.es.cloud:443" "$result"


# ══════════════════════════════════════════════════════════
#  OBLT-CLI FORMAT (nested elasticsearch: block)
# ══════════════════════════════════════════════════════════

describe "oblt-cli format — remote ES"

OBLT_REMOTE="$TEST_DIR/oblt-remote.yml"
cat > "$OBLT_REMOTE" <<'EOF'
elasticsearch:
  hosts: https://edge-oblt.es.us-west2.gcp.elastic-cloud.com:443
  username: kibana_system_user
  password: oblt-password-456
  ssl:
    verificationMode: none

server:
  host: 0.0.0.0
  restrictInternalApis: false

monitoring.ui.logs.index: remote_cluster:filebeat-*,filebeat-*
EOF

it "detects remote ES host from oblt-cli nested format"
  result=$(detect_remote_es "$OBLT_REMOTE")
  assert_eq "https://edge-oblt.es.us-west2.gcp.elastic-cloud.com:443" "$result"

it "extracts full ES host URL"
  result=$(extract_es_host "$OBLT_REMOTE")
  assert_eq "https://edge-oblt.es.us-west2.gcp.elastic-cloud.com:443" "$result"

it "extracts ES password from nested format"
  result=$(extract_es_password "$OBLT_REMOTE")
  assert_eq "oblt-password-456" "$result"


# ══════════════════════════════════════════════════════════
#  MIXED / EDGE CASES
# ══════════════════════════════════════════════════════════

describe "edge cases"

BOTH_COMMENTED="$TEST_DIR/both-commented.yml"
cat > "$BOTH_COMMENTED" <<'EOF'
server:
  port: 5601

# elasticsearch.hosts:
#   - "http://localhost:9200"
# elasticsearch.hosts:
#   - "https://remote.es.cloud:443"
EOF

it "returns empty when all ES lines are commented"
  result=$(detect_remote_es "$BOTH_COMMENTED")
  assert_eq "" "$result" "all commented lines should be ignored"

NO_ES="$TEST_DIR/no-es.yml"
cat > "$NO_ES" <<'EOF'
server:
  port: 5601
  restrictInternalApis: false
EOF

it "returns empty when no ES config exists"
  result=$(detect_remote_es "$NO_ES")
  assert_eq "" "$result"

LOOPBACK="$TEST_DIR/loopback.yml"
cat > "$LOOPBACK" <<'EOF'
server:
  port: 5601

elasticsearch.hosts:
  - "http://127.0.0.1:9200"
elasticsearch.username: "kibana"
elasticsearch.password: "changeme"
EOF

it "treats 127.0.0.1 as local"
  result=$(detect_remote_es "$LOOPBACK")
  assert_eq "" "$result" "127.0.0.1 should be treated as local"

HTTPS_LOCAL="$TEST_DIR/https-local.yml"
cat > "$HTTPS_LOCAL" <<'EOF'
server:
  port: 5601

elasticsearch.hosts:
  - "https://localhost:9200"
elasticsearch.username: "kibana_system"
elasticsearch.password: "changeme"
EOF

it "treats https://localhost as local"
  result=$(detect_remote_es "$HTTPS_LOCAL")
  assert_eq "" "$result" "https://localhost should still be local"

MISSING_FILE="$TEST_DIR/nonexistent.yml"

it "handles missing config file gracefully"
  result=$(detect_remote_es "$MISSING_FILE")
  assert_eq "" "$result"

EMPTY_FILE="$TEST_DIR/empty.yml"
touch "$EMPTY_FILE"

it "handles empty config file"
  result=$(detect_remote_es "$EMPTY_FILE")
  assert_eq "" "$result"


# ══════════════════════════════════════════════════════════
#  PASSWORD EXTRACTION
# ══════════════════════════════════════════════════════════

describe "password extraction"

FLAT_PW="$TEST_DIR/flat-password.yml"
cat > "$FLAT_PW" <<'EOF'
server:
  port: 5601
elasticsearch.hosts:
  - "http://localhost:9200"
elasticsearch.username: "kibana"
elasticsearch.password: "changeme"
EOF

it "extracts password from flat key format"
  result=$(extract_es_password "$FLAT_PW")
  assert_eq "changeme" "$result"

QUOTED_PW="$TEST_DIR/quoted-password.yml"
cat > "$QUOTED_PW" <<'EOF'
elasticsearch:
  hosts: https://remote.es.cloud:443
  username: kibana_system_user
  password: "quoted-pw-value"
EOF

it "strips quotes from password"
  result=$(extract_es_password "$QUOTED_PW")
  assert_eq "quoted-pw-value" "$result"


# ── Print results ─────────────────────────────────────────
print_summary
