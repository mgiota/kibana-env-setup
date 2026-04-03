#!/usr/bin/env zsh
# ============================================================
#  run-checks.sh — scoped lint, type check, and jest runner
#
#  USAGE:
#    run-checks lint        → eslint on changed TS/JS files
#    run-checks typecheck   → tsc on changed plugins
#    run-checks jest        → jest on changed plugins
#
#  Scope: all files changed on the current branch vs upstream/main
# ============================================================

# ── Guard: must be inside a Kibana repo ───────────────────
if [[ ! -f ".nvmrc" ]] || [[ ! -f "package.json" ]]; then
  echo "❌  Must be run from a Kibana repo directory (worktree or main checkout)."
  echo "    e.g. cd ~/Documents/Development/worktrees/<branch>"
  exit 1
fi

# ── NVM setup ─────────────────────────────────────────────
export NVM_DIR="$HOME/.nvm"
[[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"
nvm use

# ── Plugin path regex (matches Kibana's plugin structures) ─
PLUGIN_RE='(x-pack/solutions/[^/]+/plugins|x-pack/plugins|src/platform/plugins/(shared|private)|src/plugins|packages)/[^/]+'

# ── Gather changed files on this branch ───────────────────
MERGE_BASE=$(git merge-base HEAD upstream/main)
FILES=$({ git diff --name-only "$MERGE_BASE"; git ls-files --others --exclude-standard; })

if [[ -z "$FILES" ]]; then
  printf "\n✅  No changed files on this branch.\n"
  exit 0
fi

# ── Commands ──────────────────────────────────────────────
case "$1" in
  lint)
    TSFILES=$(echo "$FILES" | grep -E '\.(ts|tsx|js)$')
    if [[ -z "$TSFILES" ]]; then
      printf "\n✅  No changed TS/JS files to lint.\n"
    else
      echo "$TSFILES" | xargs node scripts/eslint
    fi
    ;;

  typecheck)
    PLUGINS=$(echo "$FILES" | grep -oE "$PLUGIN_RE" | sort -u)
    if [[ -z "$PLUGINS" ]]; then
      printf "\n✅  No changed plugins to type check.\n"
    else
      echo "$PLUGINS" | while read p; do
        if [[ -f "$p/tsconfig.json" ]]; then
          echo "→ Type checking $p..."
          node scripts/type_check --project "$p/tsconfig.json"
        fi
      done
    fi
    ;;

  jest)
    PLUGINS=$(echo "$FILES" | grep -oE "$PLUGIN_RE" | sort -u)
    if [[ -z "$PLUGINS" ]]; then
      printf "\n✅  No changed plugins to test.\n"
    else
      echo "$PLUGINS" | while read p; do
        if [[ -f "$p/jest.config.js" ]]; then
          echo "→ Testing $p..."
          node scripts/jest --config "$p/jest.config.js"
        fi
      done
    fi
    ;;

  *)
    echo "Usage: run-checks [lint|typecheck|jest]"
    exit 1
    ;;
esac
