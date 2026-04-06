#!/usr/bin/env zsh
# ============================================================
#  sync-skill.sh — sync kibana-dev-env skill to team repo
#
#  Copies the skill from this project (source of truth) to the
#  observability-dev repo for publishing to the team.
#
#  USAGE:
#    ./sync-skill.sh              copy + show diff
#    ./sync-skill.sh --dry-run    preview what would change
#
#  WORKFLOW:
#    1. Develop the skill here in kibana-env-setup
#    2. Run ./sync-skill.sh to copy to team repo
#    3. cd to team repo, review diff, commit, push, create PR
# ============================================================

set -euo pipefail

# ── CONFIG ────────────────────────────────────────────────
SCRIPT_DIR="${0:A:h}"
SKILL_SRC="$SCRIPT_DIR/kibana-dev-env"
TEAM_REPO="${TEAM_REPO:-$HOME/Documents/Development/observability-dev}"
SKILL_DEST="$TEAM_REPO/docs/actionable-obs/ai_helpers/skills/kibana-dev-env"

# ── COLOURS ───────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ── CHECKS ────────────────────────────────────────────────
if [[ ! -d "$SKILL_SRC" ]]; then
  echo "${RED}Error:${NC} Skill source not found: $SKILL_SRC"
  exit 1
fi

if [[ ! -d "$TEAM_REPO" ]]; then
  echo "${RED}Error:${NC} Team repo not found: $TEAM_REPO"
  echo "  Set TEAM_REPO to override: TEAM_REPO=/path/to/repo ./sync-skill.sh"
  exit 1
fi

# ── DRY RUN ───────────────────────────────────────────────
if [[ "${1:-}" == "--dry-run" ]]; then
  echo "${BOLD}Dry run — comparing:${NC}"
  echo "  Source: ${BLUE}$SKILL_SRC${NC}"
  echo "  Dest:   ${BLUE}$SKILL_DEST${NC}"
  echo ""

  if [[ ! -d "$SKILL_DEST" ]]; then
    echo "${YELLOW}Destination does not exist yet — all files would be new.${NC}"
    echo ""
    echo "Files to copy:"
    find "$SKILL_SRC" -type f | while read -r f; do
      echo "  ${GREEN}+${NC} ${f#$SKILL_SRC/}"
    done
  else
    # Use diff to show what would change
    diff -rq "$SKILL_SRC" "$SKILL_DEST" 2>/dev/null && \
      echo "${GREEN}✓ Already in sync — no changes needed.${NC}" || true
  fi
  exit 0
fi

# ── SYNC ──────────────────────────────────────────────────
echo "${BOLD}Syncing skill to team repo${NC}"
echo "  Source: ${BLUE}$SKILL_SRC${NC}"
echo "  Dest:   ${BLUE}$SKILL_DEST${NC}"
echo ""

# Create dest structure if needed
mkdir -p "$SKILL_DEST"

# Copy all skill files (preserving directory structure)
rsync -av --delete "$SKILL_SRC/" "$SKILL_DEST/"

echo ""
echo "${GREEN}✓ Skill synced.${NC}"
echo ""

# Show git status in team repo
echo "${BOLD}Changes in team repo:${NC}"
(cd "$TEAM_REPO" && git diff --stat -- "docs/actionable-obs/ai_helpers/skills/kibana-dev-env/")

echo ""
echo "${YELLOW}Next steps:${NC}"
echo "  cd $TEAM_REPO"
echo "  git diff -- docs/actionable-obs/ai_helpers/skills/kibana-dev-env/"
echo "  # review, commit, push, create PR"
