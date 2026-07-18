#!/usr/bin/env bash
# ============================================================
#  run.sh — convenience wrapper for qa-shots.mjs
#
#  Installs deps + chromium on first run, then captures
#  screenshots and builds the comparison report.
#
#  USAGE:
#    ./run.sh                       # capture all instances/routes from config.json
#    ./run.sh --only slo-list       # subset of routes
#    ./run.sh --instances feat      # capture one instance, no compare
#    ./run.sh --headed              # watch the browser
#    (all flags are passed straight through to qa-shots.mjs)
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -d node_modules ]]; then
  echo "→ Installing dependencies (first run)..."
  npm install
fi

# Ensure the Chromium binary Playwright needs is present.
if ! node -e "require('playwright').chromium.executablePath()" >/dev/null 2>&1; then
  echo "→ Installing Chromium for Playwright..."
  npx playwright install chromium
fi

node qa-shots.mjs "$@"
