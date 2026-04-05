#!/usr/bin/env bash
# ============================================================
#  test-arg-parsing.sh — tests for argument parsing in all scripts
#
#  Tests kbn-start.sh argument parsing (ports, data folder, flags),
#  dev-start.sh switch/new argument parsing (--remote, --full),
#  and port assignment logic.
# ============================================================

_SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
source "$_SELF_DIR/test-helpers.sh"


# ══════════════════════════════════════════════════════════
#  KBN-START.SH ARGUMENT PARSING
# ══════════════════════════════════════════════════════════

# Extract the argument parsing logic from kbn-start.sh into a testable function
parse_kbn_start_args() {
  # Reset defaults (same as kbn-start.sh)
  ES_DATA_FOLDER="main-cluster"
  KIBANA_PORT=5601
  ES_PORT=9200
  KIBANA_HOST="localhost"
  ES_FLAGS=""

  # Same parsing logic as kbn-start.sh
  if [[ $# -gt 0 && "$1" != -* ]]; then
    ES_DATA_FOLDER="$1"
    shift
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kibana-port) KIBANA_PORT="$2";  shift 2 ;;
      --es-port)     ES_PORT="$2";      shift 2 ;;
      --host)        KIBANA_HOST="$2";  shift 2 ;;
      -E)
        if [[ $# -gt 1 ]]; then
          ES_FLAGS="$ES_FLAGS -E $2"; shift 2
        else
          echo "Error: -E requires a value" >&2; return 1
        fi
        ;;
      *)
        echo "Error: Unknown argument '$1'" >&2
        return 1
        ;;
    esac
  done
}


describe "kbn-start.sh argument parsing — defaults"

it "uses main-cluster as default data folder"
  parse_kbn_start_args
  assert_eq "main-cluster" "$ES_DATA_FOLDER"

it "uses 5601 as default Kibana port"
  parse_kbn_start_args
  assert_eq "5601" "$KIBANA_PORT"

it "uses 9200 as default ES port"
  parse_kbn_start_args
  assert_eq "9200" "$ES_PORT"

it "uses localhost as default host"
  parse_kbn_start_args
  assert_eq "localhost" "$KIBANA_HOST"

it "has no ES flags by default"
  parse_kbn_start_args
  assert_eq "" "$ES_FLAGS"


describe "kbn-start.sh argument parsing — custom values"

it "accepts positional data folder"
  parse_kbn_start_args "my-cluster"
  assert_eq "my-cluster" "$ES_DATA_FOLDER"

it "accepts --kibana-port"
  parse_kbn_start_args --kibana-port 5603
  assert_eq "5603" "$KIBANA_PORT"

it "accepts --es-port"
  parse_kbn_start_args --es-port 9202
  assert_eq "9202" "$ES_PORT"

it "accepts --host"
  parse_kbn_start_args --host kibana-main.local
  assert_eq "kibana-main.local" "$KIBANA_HOST"

it "accepts -E flags"
  parse_kbn_start_args -E "node.name=test"
  assert_contains "$ES_FLAGS" "node.name=test"

it "accepts data folder with all flags"
  parse_kbn_start_args "slo-crash" --kibana-port 5603 --es-port 9202 --host kibana-feat.local
  assert_eq "slo-crash" "$ES_DATA_FOLDER"

it "rejects unknown flags"
  output=$(parse_kbn_start_args --invalid 2>&1) || true
  assert_contains "$output" "Unknown argument"


# ══════════════════════════════════════════════════════════
#  DEV-START.SH SWITCH / NEW ARGUMENT PARSING
# ══════════════════════════════════════════════════════════

# Simulate switch argument parsing (from dev-start.sh cmd_switch)
parse_switch_args() {
  local branch="" use_remote=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --remote) use_remote=true; shift ;;
      *)        branch="$1"; shift ;;
    esac
  done
  PARSED_BRANCH="$branch"
  PARSED_REMOTE="$use_remote"
}

# Simulate new argument parsing (from dev-start.sh cmd_new)
parse_new_args() {
  local branch="" use_remote=false full_session=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --remote) use_remote=true; shift ;;
      --full)   full_session=true; shift ;;
      *)        branch="$1"; shift ;;
    esac
  done
  PARSED_BRANCH="$branch"
  PARSED_REMOTE="$use_remote"
  PARSED_FULL="$full_session"
}


describe "dev-start switch — argument parsing"

it "parses branch name"
  parse_switch_args "feature/slo-filters"
  assert_eq "feature/slo-filters" "$PARSED_BRANCH"

it "parses --remote flag"
  parse_switch_args "my-branch" --remote
  assert_eq "true" "$PARSED_REMOTE"

it "defaults to local when no --remote"
  parse_switch_args "my-branch"
  assert_eq "false" "$PARSED_REMOTE"

it "handles --remote before branch name"
  parse_switch_args --remote "my-branch"
  assert_eq "my-branch" "$PARSED_BRANCH"

it "handles --remote after branch name"
  parse_switch_args "my-branch" --remote
  assert_eq "my-branch" "$PARSED_BRANCH"


describe "dev-start new — argument parsing"

it "parses branch with --full"
  parse_new_args "hotfix/crash" --full
  assert_eq "hotfix/crash" "$PARSED_BRANCH"

it "sets full session flag"
  parse_new_args "hotfix/crash" --full
  assert_eq "true" "$PARSED_FULL"

it "defaults to lightweight session"
  parse_new_args "hotfix/crash"
  assert_eq "false" "$PARSED_FULL"

it "combines --full and --remote"
  parse_new_args "hotfix/crash" --full --remote
  assert_eq "true:true" "$PARSED_FULL:$PARSED_REMOTE"

it "handles all flags in any order"
  parse_new_args --remote "hotfix/crash" --full
  assert_eq "hotfix/crash:true:true" "$PARSED_BRANCH:$PARSED_FULL:$PARSED_REMOTE"


# ══════════════════════════════════════════════════════════
#  PORT ASSIGNMENT
# ══════════════════════════════════════════════════════════

describe "port assignment — reserved ports"

# Constants from dev-start.sh
MAIN_KIBANA_PORT=5602
MAIN_ES_PORT=9201
FEAT_KIBANA_PORT=5601
FEAT_ES_PORT=9200
HOTFIX_KIBANA_PORT_START=5603
HOTFIX_ES_PORT_START=9202

it "main and feat Kibana ports don't overlap"
  assert_eq "false" "$([ "$MAIN_KIBANA_PORT" = "$FEAT_KIBANA_PORT" ] && echo true || echo false)"

it "main and feat ES ports don't overlap"
  assert_eq "false" "$([ "$MAIN_ES_PORT" = "$FEAT_ES_PORT" ] && echo true || echo false)"

it "hotfix ports start above both reserved ranges"
  result="true"
  [[ $HOTFIX_KIBANA_PORT_START -le $MAIN_KIBANA_PORT ]] && result="false"
  [[ $HOTFIX_KIBANA_PORT_START -le $FEAT_KIBANA_PORT ]] && result="false"
  [[ $HOTFIX_ES_PORT_START -le $MAIN_ES_PORT ]] && result="false"
  [[ $HOTFIX_ES_PORT_START -le $FEAT_ES_PORT ]] && result="false"
  assert_eq "true" "$result" "hotfix ports must start above all reserved ports"

it "ES transport port is ES port + 100"
  es_port=9200
  transport=$((es_port + 100))
  assert_eq "9300" "$transport"

it "Kibana and ES port pairs don't collide for main"
  assert_eq "false" "$([ "$MAIN_KIBANA_PORT" = "$MAIN_ES_PORT" ] && echo true || echo false)"

it "Kibana and ES port pairs don't collide for feat"
  assert_eq "false" "$([ "$FEAT_KIBANA_PORT" = "$FEAT_ES_PORT" ] && echo true || echo false)"


# ── Print results ─────────────────────────────────────────
print_summary
