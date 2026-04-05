#!/usr/bin/env bash
# ============================================================
#  test-helpers.sh — lightweight test framework for kibana-env-setup
#
#  Provides assertion functions and test lifecycle management.
#  Sourced by individual test files.  Works in both bash and zsh.
# ============================================================

# ── Colors ────────────────────────────────────────────────
_RED='\033[0;31m'
_GREEN='\033[0;32m'
_YELLOW='\033[1;33m'
_BOLD='\033[1m'
_NC='\033[0m'

# ── Counters ──────────────────────────────────────────────
_TESTS_RUN=0
_TESTS_PASSED=0
_TESTS_FAILED=0
_CURRENT_TEST=""

# ── Test directory setup ──────────────────────────────────
TEST_DIR=$(mktemp -d)
# Resolve the real directory of this file (works in bash and zsh)
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  PROJECT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && cd .. && pwd)"
else
  PROJECT_DIR="${0:A:h:h}"  # zsh fallback
fi

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# ── Assertion functions ───────────────────────────────────

# describe <suite-name>
describe() {
  echo ""
  echo "${_BOLD}$1${_NC}"
}

# it <test-name>
it() {
  _CURRENT_TEST="$1"
  (( _TESTS_RUN++ ))
}

# pass — mark current test as passed
pass() {
  (( _TESTS_PASSED++ ))
  echo "  ${_GREEN}✓${_NC} $_CURRENT_TEST"
}

# fail <message>
fail() {
  (( _TESTS_FAILED++ ))
  echo "  ${_RED}✗${_NC} $_CURRENT_TEST"
  echo "    ${_RED}$1${_NC}"
}

# assert_eq <expected> <actual> [message]
assert_eq() {
  local expected="$1" actual="$2" msg="${3:-expected '$1' but got '$2'}"
  if [[ "$expected" == "$actual" ]]; then
    pass
  else
    fail "$msg (expected: '$expected', got: '$actual')"
  fi
}

# assert_contains <haystack> <needle> [message]
assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-expected output to contain '$2'}"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass
  else
    fail "$msg"
  fi
}

# assert_not_contains <haystack> <needle> [message]
assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-expected output to NOT contain '$2'}"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass
  else
    fail "$msg"
  fi
}

# assert_file_exists <path>
assert_file_exists() {
  local path="$1"
  if [[ -f "$path" ]]; then
    pass
  else
    fail "file not found: $path"
  fi
}

# assert_file_contains <file> <pattern> [message]
assert_file_contains() {
  local file="$1" pattern="$2" msg="${3:-expected file to contain '$2'}"
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    pass
  else
    fail "$msg"
  fi
}

# assert_file_not_contains <file> <pattern> [message]
assert_file_not_contains() {
  local file="$1" pattern="$2" msg="${3:-expected file to NOT contain '$2'}"
  if ! grep -qE "$pattern" "$file" 2>/dev/null; then
    pass
  else
    fail "$msg"
  fi
}

# assert_exit_code <expected> <actual>
assert_exit_code() {
  local expected="$1" actual="$2"
  if [[ "$expected" == "$actual" ]]; then
    pass
  else
    fail "expected exit code $expected but got $actual"
  fi
}

# ── Summary ───────────────────────────────────────────────
print_summary() {
  echo ""
  echo "─────────────────────────────────────────"
  if [[ $_TESTS_FAILED -eq 0 ]]; then
    echo "${_GREEN}${_BOLD}All $_TESTS_RUN tests passed${_NC}"
  else
    echo "${_RED}${_BOLD}$_TESTS_FAILED of $_TESTS_RUN tests failed${_NC}"
  fi
  echo "  passed: $_TESTS_PASSED  failed: $_TESTS_FAILED"
  echo "─────────────────────────────────────────"
  echo ""
  return $_TESTS_FAILED
}
