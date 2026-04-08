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

# Scripts to include in the skill (source of truth is project root)
SCRIPTS=(
  dev-start.sh
  kbn-start.sh
  run-checks.sh
  run-data.sh
  kibana.dev.yml.template
  kibana-dev.conf.example
  kibana-remote-es.yml.example
)

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
  echo "  Skill:   ${BLUE}$SKILL_SRC${NC}"
  echo "  Scripts: ${BLUE}$SCRIPT_DIR/${NC} → ${BLUE}scripts/${NC}"
  echo "  Dest:    ${BLUE}$SKILL_DEST${NC}"
  echo ""

  if [[ ! -d "$SKILL_DEST" ]]; then
    echo "${YELLOW}Destination does not exist yet — all files would be new.${NC}"
    echo ""
    echo "Skill files:"
    find "$SKILL_SRC" -type f | while read -r f; do
      echo "  ${GREEN}+${NC} ${f#$SKILL_SRC/}"
    done
    echo ""
    echo "Scripts:"
    for s in "${SCRIPTS[@]}"; do
      echo "  ${GREEN}+${NC} scripts/$s"
    done
  else
    # Use diff to show what would change (skill content)
    diff -rq "$SKILL_SRC" "$SKILL_DEST" --exclude scripts 2>/dev/null || true
    # Compare scripts
    for s in "${SCRIPTS[@]}"; do
      if [[ ! -f "$SKILL_DEST/scripts/$s" ]]; then
        echo "Only in $SCRIPT_DIR: scripts/$s (new)"
      elif ! diff -q "$SCRIPT_DIR/$s" "$SKILL_DEST/scripts/$s" &>/dev/null; then
        echo "Files differ: scripts/$s"
      fi
    done
    # Check if everything is in sync
    local_changes=false
    diff -rq "$SKILL_SRC" "$SKILL_DEST" --exclude scripts &>/dev/null || local_changes=true
    for s in "${SCRIPTS[@]}"; do
      [[ -f "$SKILL_DEST/scripts/$s" ]] && diff -q "$SCRIPT_DIR/$s" "$SKILL_DEST/scripts/$s" &>/dev/null || local_changes=true
    done
    if [[ "$local_changes" == false ]]; then
      echo "${GREEN}✓ Already in sync — no changes needed.${NC}"
    fi
  fi
  exit 0
fi

# ── SYNC ──────────────────────────────────────────────────
echo "${BOLD}Syncing skill to team repo${NC}"
echo "  Skill:   ${BLUE}$SKILL_SRC${NC}"
echo "  Scripts: ${BLUE}$SCRIPT_DIR/${NC} → ${BLUE}scripts/${NC}"
echo "  Dest:    ${BLUE}$SKILL_DEST${NC}"
echo ""

# Create dest structure if needed
mkdir -p "$SKILL_DEST/scripts"

# Copy skill files (SKILL.md, references/) — delete stale files, but skip scripts/
rsync -av --delete --exclude scripts "$SKILL_SRC/" "$SKILL_DEST/"

# Clean scripts/ so removed scripts don't linger (|| true: glob fails in zsh if empty)
rm -f "$SKILL_DEST"/scripts/* 2>/dev/null || true

# Copy scripts from project root into scripts/ subfolder
for s in "${SCRIPTS[@]}"; do
  if [[ -f "$SCRIPT_DIR/$s" ]]; then
    cp "$SCRIPT_DIR/$s" "$SKILL_DEST/scripts/$s"
    echo "  scripts/$s"
  else
    echo "  ${YELLOW}⚠ Missing: $s${NC}"
  fi
done

echo ""
echo "${GREEN}✓ Skill + scripts synced.${NC}"
echo ""

# Show git status in team repo
echo "${BOLD}Changes in team repo:${NC}"
(cd "$TEAM_REPO" && git diff --stat -- "docs/actionable-obs/ai_helpers/skills/kibana-dev-env/")

echo ""
echo "${YELLOW}Next steps:${NC}"
echo "  cd $TEAM_REPO"
echo "  git diff -- docs/actionable-obs/ai_helpers/skills/kibana-dev-env/"
echo "  # review, commit, push, create PR"
