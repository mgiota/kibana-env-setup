#!/usr/bin/env bash
# ============================================================
#  test-clean.sh — tests for the clean command logic
#
#  Tests ES data listing, deletion by name, feat alias,
#  main alias, clean all, and edge cases.
# ============================================================

_SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
source "$_SELF_DIR/test-helpers.sh"

# ── Setup: extract cmd_clean from dev-start.sh ───────────
# Colors needed by the function
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# Config overrides — point at temp dirs so tests don't touch real data
ES_DATA_BASE="$TEST_DIR/es_data"
STATE_FILE="$TEST_DIR/kibana-dev-state"
MAIN_DATA_FOLDER="main-cluster"

# Extract cmd_clean from dev-start.sh
eval "$(sed -n '/^cmd_clean()/,/^}/p' "$PROJECT_DIR/dev-start.sh")"


# ══════════════════════════════════════════════════════════
#  CLEAN — LISTING (no argument)
# ══════════════════════════════════════════════════════════

describe "clean — listing"

it "shows usage when no data directory exists"
  rm -rf "$ES_DATA_BASE"
  output=$(cmd_clean 2>&1)
  assert_contains "$output" "no ES data directory found"

it "lists existing data folders"
  mkdir -p "$ES_DATA_BASE/main-cluster" "$ES_DATA_BASE/slo-filters"
  echo "test" > "$ES_DATA_BASE/main-cluster/data.bin"
  echo "test" > "$ES_DATA_BASE/slo-filters/data.bin"
  output=$(cmd_clean 2>&1)
  assert_contains "$output" "main-cluster"

it "lists multiple folders"
  output=$(cmd_clean 2>&1)
  assert_contains "$output" "slo-filters"

it "shows usage instructions"
  output=$(cmd_clean 2>&1)
  assert_contains "$output" "Usage:"


# ══════════════════════════════════════════════════════════
#  CLEAN — BY NAME
# ══════════════════════════════════════════════════════════

describe "clean — by name"

it "deletes a specific data folder"
  mkdir -p "$ES_DATA_BASE/test-cluster"
  echo "data" > "$ES_DATA_BASE/test-cluster/indices.bin"
  cmd_clean "test-cluster" > /dev/null 2>&1
  if [[ -d "$ES_DATA_BASE/test-cluster" ]]; then
    fail "folder should have been deleted"
  else
    pass
  fi

it "leaves other folders untouched"
  mkdir -p "$ES_DATA_BASE/keep-me" "$ES_DATA_BASE/delete-me"
  echo "data" > "$ES_DATA_BASE/keep-me/data.bin"
  echo "data" > "$ES_DATA_BASE/delete-me/data.bin"
  cmd_clean "delete-me" > /dev/null 2>&1
  assert_file_exists "$ES_DATA_BASE/keep-me/data.bin"

it "shows warning for nonexistent folder"
  output=$(cmd_clean "nonexistent-cluster" 2>&1)
  assert_contains "$output" "No data folder found"


# ══════════════════════════════════════════════════════════
#  CLEAN — MAIN ALIAS
# ══════════════════════════════════════════════════════════

describe "clean main"

it "deletes main-cluster data"
  mkdir -p "$ES_DATA_BASE/main-cluster"
  echo "data" > "$ES_DATA_BASE/main-cluster/nodes.bin"
  cmd_clean "main" > /dev/null 2>&1
  if [[ -d "$ES_DATA_BASE/main-cluster" ]]; then
    fail "main-cluster folder should have been deleted"
  else
    pass
  fi


# ══════════════════════════════════════════════════════════
#  CLEAN — FEAT ALIAS
# ══════════════════════════════════════════════════════════

describe "clean feat"

it "resolves feat branch from state file"
  mkdir -p "$ES_DATA_BASE/slo-filters"
  echo "data" > "$ES_DATA_BASE/slo-filters/data.bin"
  cat > "$STATE_FILE" <<EOF
FEAT_BRANCH=feature/slo-filters
FEAT_DIR=/tmp/worktrees/slo-filters
EOF
  cmd_clean "feat" > /dev/null 2>&1
  if [[ -d "$ES_DATA_BASE/slo-filters" ]]; then
    fail "slo-filters folder should have been deleted"
  else
    pass
  fi

it "handles branch with path prefix (e.g. feature/my-thing)"
  mkdir -p "$ES_DATA_BASE/my-thing"
  echo "data" > "$ES_DATA_BASE/my-thing/data.bin"
  cat > "$STATE_FILE" <<EOF
FEAT_BRANCH=feature/my-thing
FEAT_DIR=/tmp/worktrees/my-thing
EOF
  cmd_clean "feat" > /dev/null 2>&1
  if [[ -d "$ES_DATA_BASE/my-thing" ]]; then
    fail "my-thing folder should have been deleted"
  else
    pass
  fi

it "shows error when no state file exists"
  rm -f "$STATE_FILE"
  output=$(cmd_clean "feat" 2>&1) || true
  assert_contains "$output" "No feat state found"


# ══════════════════════════════════════════════════════════
#  CLEAN — ALL
# ══════════════════════════════════════════════════════════

describe "clean all"

it "deletes entire ES data directory"
  mkdir -p "$ES_DATA_BASE/main-cluster" "$ES_DATA_BASE/feat-a" "$ES_DATA_BASE/feat-b"
  echo "data" > "$ES_DATA_BASE/main-cluster/data.bin"
  echo "data" > "$ES_DATA_BASE/feat-a/data.bin"
  echo "data" > "$ES_DATA_BASE/feat-b/data.bin"
  cmd_clean "all" > /dev/null 2>&1
  if [[ -d "$ES_DATA_BASE" ]]; then
    fail "entire es_data directory should have been deleted"
  else
    pass
  fi

it "shows warning when no data directory exists"
  rm -rf "$ES_DATA_BASE"
  output=$(cmd_clean "all" 2>&1)
  assert_contains "$output" "No ES data directory found"


# ── Print results ─────────────────────────────────────────
print_summary
