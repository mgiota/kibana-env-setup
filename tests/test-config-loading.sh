#!/usr/bin/env bash
# ============================================================
#  test-config-loading.sh — tests for ~/.kibana-dev.conf loading
#
#  Tests that user config overrides defaults, defaults work
#  without a config file, and partial configs merge correctly.
# ============================================================

_SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
source "$_SELF_DIR/test-helpers.sh"


# ── Helper: simulate the config loading pattern ──────────
# This mirrors the exact pattern from dev-start.sh
load_config() {
  local conf_file="$1"

  # Reset all variables (simulate fresh script start)
  unset KIBANA_MAIN_DIR WORKTREE_BASE ES_DATA_BASE STATE_FILE KBN_START
  unset REMOTE_ES_CONFIG MAIN_KIBANA_PORT MAIN_ES_PORT MAIN_HOST
  unset MAIN_DATA_FOLDER FEAT_KIBANA_PORT FEAT_ES_PORT FEAT_HOST
  unset HOTFIX_KIBANA_PORT_START HOTFIX_ES_PORT_START

  # Source user config if it exists
  [[ -f "$conf_file" ]] && source "$conf_file"

  # Apply defaults (same as dev-start.sh)
  KIBANA_MAIN_DIR="${KIBANA_MAIN_DIR:-$HOME/Documents/Development/kibana}"
  WORKTREE_BASE="${WORKTREE_BASE:-$HOME/Documents/Development/worktrees}"
  ES_DATA_BASE="${ES_DATA_BASE:-$HOME/Documents/Development/es_data}"
  STATE_FILE="${STATE_FILE:-$HOME/.kibana-dev-state}"
  KBN_START="${KBN_START:-$HOME/bin/kbn-start.sh}"
  REMOTE_ES_CONFIG="${REMOTE_ES_CONFIG:-$HOME/.kibana-remote-es.yml}"
  MAIN_KIBANA_PORT="${MAIN_KIBANA_PORT:-5602}"
  MAIN_ES_PORT="${MAIN_ES_PORT:-9201}"
  MAIN_HOST="${MAIN_HOST:-kibana-main.local}"
  MAIN_DATA_FOLDER="${MAIN_DATA_FOLDER:-main-cluster}"
  FEAT_KIBANA_PORT="${FEAT_KIBANA_PORT:-5601}"
  FEAT_ES_PORT="${FEAT_ES_PORT:-9200}"
  FEAT_HOST="${FEAT_HOST:-kibana-feat.local}"
  HOTFIX_KIBANA_PORT_START="${HOTFIX_KIBANA_PORT_START:-5603}"
  HOTFIX_ES_PORT_START="${HOTFIX_ES_PORT_START:-9202}"
}


# ══════════════════════════════════════════════════════════
#  NO CONFIG FILE — DEFAULTS
# ══════════════════════════════════════════════════════════

describe "no config file — defaults apply"

it "uses default path when no config exists"
  load_config "$TEST_DIR/nonexistent.conf"
  assert_contains "$KIBANA_MAIN_DIR" "kibana"

it "uses default ports when no config exists"
  load_config "$TEST_DIR/nonexistent.conf"
  assert_eq "5602" "$MAIN_KIBANA_PORT"


# ══════════════════════════════════════════════════════════
#  FULL CONFIG — ALL OVERRIDES
# ══════════════════════════════════════════════════════════

describe "full config — all values overridden"

FULL_CONF="$TEST_DIR/full.conf"
cat > "$FULL_CONF" <<'EOF'
KIBANA_MAIN_DIR="$HOME/src/kibana"
WORKTREE_BASE="$HOME/src/worktrees"
ES_DATA_BASE="$HOME/src/es_data"
MAIN_KIBANA_PORT=6602
MAIN_ES_PORT=10201
FEAT_KIBANA_PORT=6601
FEAT_ES_PORT=10200
MAIN_HOST="my-main.local"
FEAT_HOST="my-feat.local"
MAIN_DATA_FOLDER="custom-cluster"
EOF

it "overrides paths"
  load_config "$FULL_CONF"
  assert_contains "$KIBANA_MAIN_DIR" "src/kibana"

it "overrides ports"
  load_config "$FULL_CONF"
  assert_eq "6602" "$MAIN_KIBANA_PORT"

it "overrides hosts"
  load_config "$FULL_CONF"
  assert_eq "my-main.local" "$MAIN_HOST"

it "overrides data folder name"
  load_config "$FULL_CONF"
  assert_eq "custom-cluster" "$MAIN_DATA_FOLDER"


# ══════════════════════════════════════════════════════════
#  PARTIAL CONFIG — ONLY SOME OVERRIDES
# ══════════════════════════════════════════════════════════

describe "partial config — mix of overrides and defaults"

PARTIAL_CONF="$TEST_DIR/partial.conf"
cat > "$PARTIAL_CONF" <<'EOF'
KIBANA_MAIN_DIR="$HOME/code/kibana"
FEAT_KIBANA_PORT=7777
EOF

it "applies specified overrides"
  load_config "$PARTIAL_CONF"
  assert_contains "$KIBANA_MAIN_DIR" "code/kibana"

it "keeps defaults for unspecified values"
  load_config "$PARTIAL_CONF"
  assert_eq "5602" "$MAIN_KIBANA_PORT"


# ══════════════════════════════════════════════════════════
#  EMPTY CONFIG FILE
# ══════════════════════════════════════════════════════════

describe "empty config file"

EMPTY_CONF="$TEST_DIR/empty.conf"
touch "$EMPTY_CONF"

it "falls back to all defaults with empty file"
  load_config "$EMPTY_CONF"
  assert_eq "5601" "$FEAT_KIBANA_PORT"


# ── Print results ─────────────────────────────────────────
print_summary
