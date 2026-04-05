#!/usr/bin/env bash
# ============================================================
#  run-tests.sh — run all tests for kibana-env-setup
#
#  USAGE:
#    ./tests/run-tests.sh              → run all tests
#    ./tests/run-tests.sh <pattern>    → run tests matching pattern
#
#  EXAMPLES:
#    ./tests/run-tests.sh              → all test suites
#    ./tests/run-tests.sh config       → only config generation tests
#    ./tests/run-tests.sh detection    → only ES detection tests
#    ./tests/run-tests.sh run-data     → only run-data tests
#    ./tests/run-tests.sh arg          → only argument parsing tests
# ============================================================
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

PATTERN="${1:-}"
TOTAL_PASSED=0
TOTAL_FAILED=0
TOTAL_SUITES=0
FAILED_SUITES=()

echo ""
echo "${BOLD}═══════════════════════════════════════════${NC}"
echo "${BOLD}  kibana-env-setup test suite${NC}"
echo "${BOLD}═══════════════════════════════════════════${NC}"

for test_file in "$SELF_DIR"/test-*.sh; do
  [[ "$(basename "$test_file")" == "test-helpers.sh" ]] && continue

  # Filter by pattern if provided
  if [[ -n "$PATTERN" && "$(basename "$test_file")" != *"$PATTERN"* ]]; then
    continue
  fi

  suite_name=$(basename "$test_file" .sh | sed 's/^test-//')
  TOTAL_SUITES=$((TOTAL_SUITES + 1))

  echo ""
  echo "${BOLD}── $suite_name ──${NC}"

  # Run the test and capture output
  output=$(bash "$test_file" 2>&1) || true
  echo "$output"

  # Extract pass/fail counts from the summary line
  passed=$(echo "$output" | grep "passed:" | tail -1 | sed 's/.*passed: *\([0-9]*\).*/\1/')
  failed=$(echo "$output" | grep "failed:" | tail -1 | sed 's/.*failed: *\([0-9]*\).*/\1/')

  TOTAL_PASSED=$((TOTAL_PASSED + ${passed:-0}))
  TOTAL_FAILED=$((TOTAL_FAILED + ${failed:-0}))

  if [[ "${failed:-0}" -gt 0 ]]; then
    FAILED_SUITES+=("$suite_name")
  fi
done

TOTAL_TESTS=$((TOTAL_PASSED + TOTAL_FAILED))

echo ""
echo "${BOLD}═══════════════════════════════════════════${NC}"
if [[ $TOTAL_FAILED -eq 0 ]]; then
  echo "${GREEN}${BOLD}  ALL TESTS PASSED${NC}"
else
  echo "${RED}${BOLD}  SOME TESTS FAILED${NC}"
  echo ""
  echo "  Failed suites:"
  for suite in "${FAILED_SUITES[@]}"; do
    echo "    ${RED}✗${NC} $suite"
  done
fi
echo ""
echo "  Suites: $TOTAL_SUITES    Tests: $TOTAL_TESTS"
echo "  Passed: $TOTAL_PASSED    Failed: $TOTAL_FAILED"
echo "${BOLD}═══════════════════════════════════════════${NC}"
echo ""

exit $TOTAL_FAILED
