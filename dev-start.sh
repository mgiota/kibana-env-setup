#!/usr/bin/env zsh
# ============================================================
#  dev-start.sh — tmux + git worktree manager for Kibana
#
#  USAGE:
#    ./dev-start.sh                        → start/attach permanent sessions
#    ./dev-start.sh switch <branch>          → switch kibana-feat to a new branch (local ES)
#    ./dev-start.sh switch <branch> --remote → switch with remote ES (~/.kibana-remote-es.yml)
#    ./dev-start.sh new <branch>             → create worktree + lightweight hotfix session
#    ./dev-start.sh new <branch> --full      → create worktree + full session
#    ./dev-start.sh new <branch> --remote    → create session with remote ES
#    ./dev-start.sh attach <branch>        → attach to existing session
#    ./dev-start.sh list                   → list sessions, worktrees & ports
#    ./dev-start.sh clean                  → list ES data folders + sizes
#    ./dev-start.sh clean main|feat|<name> → delete ES data for a session
#    ./dev-start.sh clean all              → delete ALL ES data
#    ./dev-start.sh setup                  → interactive config wizard (paths, ports, symlinks)
#    ./dev-start.sh kill <branch>          → kill session + remove worktree
#    ./dev-start.sh kill-all               → kill all kibana-* sessions
#
#  FILES:
#    ~/bin/kbn-start.sh        helper script (must be installed first)
#    ~/.kibana-dev-state       auto-managed state file (feat branch + dir)
#
#  GENERATED PER WORKTREE:
#    config/kibana.dev.yml     Kibana port config
#    .cursor/mcp.json          Playwright-mcp config with correct Kibana URL
#
#  WINDOWS PER SESSION (full):
#    0: servers   [left: ES+bootstrap  |  right: Kibana (auto-started)]
#    1: cursor    [left: cursor-agent  |  right: spare shell]
#    2: scripts   [left: synthetics    |  right: inject data]
#    3: git       [single pane]
#    4: editor    [single pane — vim, /etc/hosts, config files]
#    5: checks    [top-left: eslint | top-right: type check | bottom: jest]
#    6: ftr       [left: ftr server    |  right: ftr runner]
#
#  WINDOWS PER SESSION (lightweight):
#    0: servers   [left: ES+bootstrap  |  right: Kibana (auto-started)]
#    1: cursor    [left: cursor-agent  |  right: spare shell]
#    2: scripts   [left: synthetics    |  right: inject data]
#    3: git       [single pane]
#    4: editor    [single pane]
# ============================================================

# ── CONFIG ────────────────────────────────────────────────
# User overrides — sourced first so they take precedence
KIBANA_DEV_CONF="$HOME/.kibana-dev.conf"
[[ -f "$KIBANA_DEV_CONF" ]] && source "$KIBANA_DEV_CONF"

# Paths (defaults apply only if not set by user config)
KIBANA_MAIN_DIR="${KIBANA_MAIN_DIR:-$HOME/Documents/Development/kibana}"
WORKTREE_BASE="${WORKTREE_BASE:-$HOME/Documents/Development/worktrees}"
ES_DATA_BASE="${ES_DATA_BASE:-$HOME/Documents/Development/es_data}"
STATE_FILE="${STATE_FILE:-$HOME/.kibana-dev-state}"
KBN_START="${KBN_START:-$HOME/bin/kbn-start.sh}"
REMOTE_ES_CONFIG="${REMOTE_ES_CONFIG:-$HOME/.kibana-remote-es.yml}"

# Script-relative paths (always derived from install location, not configurable)
TEMPLATE="${0:A:h}/kibana.dev.yml.template"
REMOTE_ES_EXAMPLE="${0:A:h}/kibana-remote-es.yml.example"
CONF_EXAMPLE="${0:A:h}/kibana-dev.conf.example"
RUN_CHECKS="${0:A:h}/run-checks.sh"
RUN_DATA="${0:A:h}/run-data.sh"

# kibana-main — permanent, never changes
MAIN_KIBANA_PORT="${MAIN_KIBANA_PORT:-5602}"
MAIN_ES_PORT="${MAIN_ES_PORT:-9201}"
MAIN_HOST="${MAIN_HOST:-kibana-main.local}"
MAIN_DATA_FOLDER="${MAIN_DATA_FOLDER:-main-cluster}"

# kibana-feat — permanent slot, branch changes via `switch`
FEAT_KIBANA_PORT="${FEAT_KIBANA_PORT:-5601}"
FEAT_ES_PORT="${FEAT_ES_PORT:-9200}"
FEAT_HOST="${FEAT_HOST:-kibana-feat.local}"

# Hotfix sessions scan upward from these ports
HOTFIX_KIBANA_PORT_START="${HOTFIX_KIBANA_PORT_START:-5603}"
HOTFIX_ES_PORT_START="${HOTFIX_ES_PORT_START:-9202}"

# ── END CONFIG ────────────────────────────────────────────


# ── COLORS ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'
# ── END COLORS ────────────────────────────────────────────


# ── STATE FILE ────────────────────────────────────────────
load_feat_state() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "${RED}Error:${NC} No feat state found. Run this first:"
    echo ""
    echo "  ${GREEN}./dev-start.sh switch <your-feature-branch>${NC}"
    echo ""
    echo "  Example: ./dev-start.sh switch feature/slo-filters"
    exit 1
  fi
  source "$STATE_FILE"
}

save_feat_state() {
  local branch="$1" dir="$2"
  cat > "$STATE_FILE" <<EOF
# Auto-managed by dev-start.sh — do not edit manually
FEAT_BRANCH=$branch
FEAT_DIR=$dir
EOF
  echo "${GREEN}✓${NC} State saved → $STATE_FILE"
}
# ── END STATE FILE ────────────────────────────────────────


# ── PORT HELPERS ──────────────────────────────────────────
port_in_use() {
  lsof -i ":$1" &>/dev/null
}

find_free_ports() {
  local kibana_port=$HOTFIX_KIBANA_PORT_START
  local es_port=$HOTFIX_ES_PORT_START

  while true; do
    if [[ "$kibana_port" == "$MAIN_KIBANA_PORT" ]] || \
       [[ "$kibana_port" == "$FEAT_KIBANA_PORT" ]] || \
       [[ "$es_port"     == "$MAIN_ES_PORT"     ]] || \
       [[ "$es_port"     == "$FEAT_ES_PORT"     ]]; then
      (( kibana_port++ )); (( es_port++ ))
      continue
    fi
    if ! port_in_use "$kibana_port" && ! port_in_use "$es_port"; then
      echo "$kibana_port $es_port"
      return
    fi
    (( kibana_port++ )); (( es_port++ ))
  done
}

generate_kibana_dev_yml() {
  local dir="$1" kibana_port="$2" es_port="$3"

  if [[ ! -f "$TEMPLATE" ]]; then
    echo "${RED}Error:${NC} Template not found at $TEMPLATE"
    exit 1
  fi

  mkdir -p "$dir/config"
  sed \
    -e "s/__KIBANA_PORT__/$kibana_port/g" \
    -e "s/__ES_PORT__/$es_port/g" \
    "$TEMPLATE" > "$dir/config/kibana.dev.yml"

  echo "${GREEN}✓${NC} config/kibana.dev.yml  → Kibana :$kibana_port  ES :$es_port"
}

generate_remote_kibana_dev_yml() {
  local dir="$1" kibana_port="$2"

  if [[ ! -f "$REMOTE_ES_CONFIG" ]]; then
    echo "${RED}Error:${NC} Remote ES config not found at $REMOTE_ES_CONFIG"
    echo ""
    echo "  Copy the example and fill in your cluster details:"
    echo "    ${GREEN}cp $REMOTE_ES_EXAMPLE $REMOTE_ES_CONFIG${NC}"
    echo "    ${GREEN}vim $REMOTE_ES_CONFIG${NC}"
    echo ""
    echo "  Get credentials from oblt-cli:"
    echo "    ${GREEN}oblt-cli cluster credentials${NC}"
    exit 1
  fi

  mkdir -p "$dir/config"
  {
    echo "server:"
    echo "  port: ${kibana_port}"
    echo "  restrictInternalApis: false"
    echo ""
    echo "# Remote ES — generated by dev-start.sh --remote"
    echo "# Source: $REMOTE_ES_CONFIG"
    echo ""
    # Strip any server: block from the remote config (dev-start.sh manages the port)
    awk '
      /^[[:space:]]*server:[[:space:]]*$/ { skipping=1; match($0,/^[[:space:]]*/); lvl=RLENGTH; next }
      skipping && /^[[:space:]]*$/ { next }
      skipping { match($0,/^[[:space:]]*/); if(RLENGTH>lvl){next} else {skipping=0} }
      {print}
    ' "$REMOTE_ES_CONFIG"
  } > "$dir/config/kibana.dev.yml"

  local remote_host
  remote_host=$(grep -E "^ *hosts:" "$REMOTE_ES_CONFIG" 2>/dev/null | head -1 | sed 's|.*hosts: *||' | tr -d '"' | tr -d ' ')
  echo "${GREEN}✓${NC} config/kibana.dev.yml  → Kibana :$kibana_port  ES: ${BLUE}${remote_host:-remote}${NC}"
}

generate_cursor_mcp_json() {
  local dir="$1" kibana_port="$2" host="$3"
  local kibana_url
  if [[ "$host" == "localhost" ]]; then
    kibana_url="http://localhost:${kibana_port}"
  else
    kibana_url="http://${host}:${kibana_port}"
  fi
  mkdir -p "$dir/.cursor"
  cat > "$dir/.cursor/mcp.json" <<EOF
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["@playwright/mcp@latest"],
      "env": {
        "KIBANA_URL": "$kibana_url"
      }
    }
  }
}
EOF
  echo "${GREEN}✓${NC} .cursor/mcp.json       → KIBANA_URL=$kibana_url"
}
get_es_display() {
  local yml="$1"
  [[ ! -f "$yml" ]] && echo ":unknown" && return
  local local_port
  local_port=$(grep -E "^ *- \"?http://localhost:" "$yml" 2>/dev/null | head -1 | sed 's|.*http://localhost:||' | tr -d ' "')
  if [[ -n "$local_port" ]]; then
    echo ":$local_port"
    return
  fi
  local remote_url
  remote_url=$(grep -E "^ *hosts: https?://" "$yml" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')
  if [[ -n "$remote_url" ]]; then
    echo "$remote_url"
    return
  fi
  echo ":unknown"
}
# ── END PORT HELPERS ──────────────────────────────────────


# ── SESSION BUILDERS ──────────────────────────────────────
setup_servers_window() {
  local session="$1" dir="$2" kibana_port="$3" es_port="$4" host="$5" data_folder="$6"

  tmux send-keys -t "${session}:servers" "cd $dir" Enter
  tmux split-window -h -c "$dir" -t "${session}:servers"
  tmux send-keys -t "${session}:servers" "cd $dir" Enter
  tmux select-pane -t "${session}:servers.0"
  tmux send-keys -t "${session}:servers.0" \
    "$KBN_START $data_folder --kibana-port $kibana_port --es-port $es_port --host $host" \
    Enter
}

# cursor window: left pane = cursor-agent (~60%), right pane = spare shell (~40%)
setup_cursor_window() {
  local session="$1" dir="$2"

  tmux new-window -t "$session" -n "cursor" -c "$dir"

  # Split: left gets ~60% of width
  tmux split-window -h -p 40 -c "$dir" -t "${session}:cursor"

  # Left pane: cursor-agent
  tmux send-keys -t "${session}:cursor.0" "cd $dir" Enter

  # Right pane: spare shell
  tmux send-keys -t "${session}:cursor.1" "cd $dir" Enter

  # Focus left (cursor-agent)
  tmux select-pane -t "${session}:cursor.0"
}

# Full session: all 7 windows
build_kibana_session() {
  local session="$1" dir="$2" kibana_port="$3" es_port="$4" host="$5" data_folder="$6"

  # 0: servers
  tmux rename-window -t "${session}:0" "servers"
  setup_servers_window "$session" "$dir" "$kibana_port" "$es_port" "$host" "$data_folder"

  # 1: cursor [left: cursor-agent | right: spare shell]
  setup_cursor_window "$session" "$dir"

  # 2: scripts
  tmux new-window -t "$session" -n "scripts" -c "$dir"
  tmux split-window -h -c "$dir" -t "${session}:scripts"
  # left pane — synthetics private location (with session-specific ports)
  tmux send-keys -t "${session}:scripts.0" "$RUN_DATA synthetics"
  # right pane — SLO data ingestion (data_forge with session-specific ports)
  tmux send-keys -t "${session}:scripts.1" "$RUN_DATA slo"
  tmux select-pane -t "${session}:scripts.0"

  # 3: git
  tmux new-window -t "$session" -n "git" -c "$dir"
  tmux send-keys -t "${session}:git" "cd $dir && git status" Enter

  # 4: editor (vim, single pane)
  tmux new-window -t "$session" -n "editor" -c "$dir"
  tmux send-keys -t "${session}:editor" "cd $dir" Enter

  # 5: checks [top-left: eslint | top-right: type check | bottom: jest]
  tmux new-window -t "$session" -n "checks" -c "$dir"
  tmux split-window -v -c "$dir" -t "${session}:checks"          # pane 1: bottom (jest)
  tmux split-window -h -c "$dir" -t "${session}:checks.0"        # pane 2: top-right (type check)
  tmux send-keys -t "${session}:checks.0" "$RUN_CHECKS lint"
  tmux send-keys -t "${session}:checks.2" "$RUN_CHECKS typecheck"
  tmux send-keys -t "${session}:checks.1" "$RUN_CHECKS jest"
  tmux select-pane -t "${session}:checks.0"

  # 6: ftr [left: ftr server | right: ftr runner]
  tmux new-window -t "$session" -n "ftr" -c "$dir"
  tmux split-window -h -c "$dir" -t "${session}:ftr"
  tmux send-keys -t "${session}:ftr.0" "export NVM_DIR=\"\$HOME/.nvm\" && [[ -s \"\$NVM_DIR/nvm.sh\" ]] && source \"\$NVM_DIR/nvm.sh\" && nvm use && yarn test:ftr:server"
  tmux send-keys -t "${session}:ftr.1" "export NVM_DIR=\"\$HOME/.nvm\" && [[ -s \"\$NVM_DIR/nvm.sh\" ]] && source \"\$NVM_DIR/nvm.sh\" && nvm use && yarn test:ftr:runner"
  tmux select-pane -t "${session}:ftr.0"

  tmux select-window -t "${session}:servers"
}

# Lightweight session: 5 windows
build_lightweight_session() {
  local session="$1" dir="$2" kibana_port="$3" es_port="$4" host="$5" data_folder="$6"

  # 0: servers
  tmux rename-window -t "${session}:0" "servers"
  setup_servers_window "$session" "$dir" "$kibana_port" "$es_port" "$host" "$data_folder"

  # 1: cursor [left: cursor-agent | right: spare shell]
  setup_cursor_window "$session" "$dir"

  # 2: scripts
  tmux new-window -t "$session" -n "scripts" -c "$dir"
  tmux split-window -h -c "$dir" -t "${session}:scripts"
  # left pane — synthetics private location (with session-specific ports)
  tmux send-keys -t "${session}:scripts.0" "$RUN_DATA synthetics"
  # right pane — SLO data ingestion (data_forge with session-specific ports)
  tmux send-keys -t "${session}:scripts.1" "$RUN_DATA slo"
  tmux select-pane -t "${session}:scripts.0"

  # 3: git
  tmux new-window -t "$session" -n "git" -c "$dir"
  tmux send-keys -t "${session}:git" "cd $dir && git status" Enter

  # 4: editor
  tmux new-window -t "$session" -n "editor" -c "$dir"
  tmux send-keys -t "${session}:editor" "cd $dir" Enter

  tmux select-window -t "${session}:servers"
}
# ── END SESSION BUILDERS ──────────────────────────────────


# ── COMMANDS ──────────────────────────────────────────────
branch_to_session() {
  echo "kibana-$(echo "$1" | sed 's|.*/||' | tr '/' '-' | tr '.' '-')"
}

print_help() {
  echo ""
  echo "${BOLD}dev-start.sh — Kibana tmux + worktree manager${NC}"
  echo ""
  echo "  ${GREEN}./dev-start.sh${NC}                         Start/attach permanent sessions"
  echo "  ${GREEN}./dev-start.sh switch <branch>${NC}         Switch kibana-feat to a new branch (local ES)"
  echo "  ${GREEN}./dev-start.sh switch <branch> --remote${NC} Switch to branch with remote ES (reads ~/.kibana-remote-es.yml)"
  echo "  ${GREEN}./dev-start.sh new <branch>${NC}            Create worktree + lightweight hotfix session"
  echo "  ${GREEN}./dev-start.sh new <branch> --full${NC}     Create worktree + full session"
  echo "  ${GREEN}./dev-start.sh new <branch> --remote${NC}   Create session with remote ES"
  echo "  ${GREEN}./dev-start.sh attach <branch>${NC}         Attach to existing session"
  echo "  ${GREEN}./dev-start.sh list${NC}                    List sessions, worktrees & ports"
  echo "  ${GREEN}./dev-start.sh clean${NC}                   List ES data folders + sizes"
  echo "  ${GREEN}./dev-start.sh clean main|feat|<name>${NC}  Delete ES data (start fresh)"
  echo "  ${GREEN}./dev-start.sh clean all${NC}               Delete ALL ES data"
  echo "  ${GREEN}./dev-start.sh setup${NC}                   Interactive config wizard (first-time setup)"
  echo "  ${GREEN}./dev-start.sh kill <branch>${NC}           Kill session + remove worktree"
  echo "  ${GREEN}./dev-start.sh kill-all${NC}                Kill ALL kibana-* sessions"
  echo ""
  echo "  ${YELLOW}First time setup:${NC}"
  echo "    ./dev-start.sh setup"
  echo "    ./dev-start.sh switch feature/my-first-feature"
  echo "    ./dev-start.sh"
  echo ""
  echo "  ${YELLOW}Examples:${NC}"
  echo "    ./dev-start.sh switch feature/slo-filters"
  echo "    ./dev-start.sh switch feature/slo-filters --remote"
  echo "    ./dev-start.sh new fix/slo-crash"
  echo "    ./dev-start.sh new fix/slo-crash --full --remote"
  echo "    ./dev-start.sh kill slo-crash"
  echo ""
}

cmd_setup() {
  echo ""
  echo "${BOLD}kibana-env-setup — configuration wizard${NC}"
  echo ""

  if [[ -f "$KIBANA_DEV_CONF" ]]; then
    echo "${YELLOW}⚠${NC}  Config file already exists at $KIBANA_DEV_CONF"
    echo "   Current values will be shown as defaults. Press Enter to keep them."
    echo ""
    source "$KIBANA_DEV_CONF"
  fi

  # ── Ask for paths ──────────────────────────────────────
  local default_kibana="${KIBANA_MAIN_DIR}"
  local default_worktrees="${WORKTREE_BASE}"
  local default_esdata="${ES_DATA_BASE}"

  printf "  Kibana repo path [${BLUE}${default_kibana}${NC}]: "
  read -r input_kibana
  input_kibana="${input_kibana:-$default_kibana}"

  printf "  Worktrees path   [${BLUE}${default_worktrees}${NC}]: "
  read -r input_worktrees
  input_worktrees="${input_worktrees:-$default_worktrees}"

  printf "  ES data path     [${BLUE}${default_esdata}${NC}]: "
  read -r input_esdata
  input_esdata="${input_esdata:-$default_esdata}"

  # ── Ask for ports ──────────────────────────────────────
  echo ""
  echo "  ${BOLD}Ports${NC} (press Enter to keep defaults)"

  printf "  kibana-main  Kibana port [${BLUE}${MAIN_KIBANA_PORT}${NC}]: "
  read -r input_main_kport
  input_main_kport="${input_main_kport:-$MAIN_KIBANA_PORT}"

  printf "  kibana-main  ES port     [${BLUE}${MAIN_ES_PORT}${NC}]: "
  read -r input_main_eport
  input_main_eport="${input_main_eport:-$MAIN_ES_PORT}"

  printf "  kibana-feat  Kibana port [${BLUE}${FEAT_KIBANA_PORT}${NC}]: "
  read -r input_feat_kport
  input_feat_kport="${input_feat_kport:-$FEAT_KIBANA_PORT}"

  printf "  kibana-feat  ES port     [${BLUE}${FEAT_ES_PORT}${NC}]: "
  read -r input_feat_eport
  input_feat_eport="${input_feat_eport:-$FEAT_ES_PORT}"

  # ── Validate Kibana repo ───────────────────────────────
  echo ""
  if [[ -d "$input_kibana/.git" ]] || [[ -d "$input_kibana/package.json" ]]; then
    echo "  ${GREEN}✓${NC} Kibana repo found at $input_kibana"
  else
    echo "  ${YELLOW}⚠${NC} No git repo found at $input_kibana — make sure to clone Kibana there first."
  fi

  # ── Write config ───────────────────────────────────────
  cat > "$KIBANA_DEV_CONF" <<EOF
# Generated by: dev-start.sh setup
# Edit this file or re-run setup to change settings.

# Paths
KIBANA_MAIN_DIR="$input_kibana"
WORKTREE_BASE="$input_worktrees"
ES_DATA_BASE="$input_esdata"

# Ports — kibana-main
MAIN_KIBANA_PORT=$input_main_kport
MAIN_ES_PORT=$input_main_eport

# Ports — kibana-feat
FEAT_KIBANA_PORT=$input_feat_kport
FEAT_ES_PORT=$input_feat_eport
EOF

  echo ""
  echo "${GREEN}✓${NC} Config written to $KIBANA_DEV_CONF"

  # ── Create directories if needed ───────────────────────
  mkdir -p "$input_worktrees" 2>/dev/null && \
    echo "${GREEN}✓${NC} Worktrees directory ready: $input_worktrees" || true
  mkdir -p "$input_esdata" 2>/dev/null && \
    echo "${GREEN}✓${NC} ES data directory ready: $input_esdata" || true

  # ── Set up symlinks ────────────────────────────────────
  echo ""
  echo "${BOLD}Symlinks${NC}"
  local script_dir="${0:A:h}"

  # kbn-start.sh → ~/bin/
  mkdir -p "$HOME/bin"
  if [[ -L "$HOME/bin/kbn-start.sh" ]]; then
    echo "  ${GREEN}✓${NC} ~/bin/kbn-start.sh already linked"
  elif [[ -f "$script_dir/kbn-start.sh" ]]; then
    ln -s "$script_dir/kbn-start.sh" "$HOME/bin/kbn-start.sh"
    chmod +x "$script_dir/kbn-start.sh"
    echo "  ${GREEN}✓${NC} ~/bin/kbn-start.sh → $script_dir/kbn-start.sh"
  fi

  # run-checks → ~/bin/
  if [[ -L "$HOME/bin/run-checks" ]]; then
    echo "  ${GREEN}✓${NC} ~/bin/run-checks already linked"
  elif [[ -f "$script_dir/run-checks.sh" ]]; then
    ln -s "$script_dir/run-checks.sh" "$HOME/bin/run-checks"
    chmod +x "$script_dir/run-checks.sh"
    echo "  ${GREEN}✓${NC} ~/bin/run-checks → $script_dir/run-checks.sh"
  fi

  # run-data → ~/bin/
  if [[ -L "$HOME/bin/run-data" ]]; then
    echo "  ${GREEN}✓${NC} ~/bin/run-data already linked"
  elif [[ -f "$script_dir/run-data.sh" ]]; then
    ln -s "$script_dir/run-data.sh" "$HOME/bin/run-data"
    chmod +x "$script_dir/run-data.sh"
    echo "  ${GREEN}✓${NC} ~/bin/run-data → $script_dir/run-data.sh"
  fi

  # dev-start.sh → ~/
  if [[ -L "$HOME/dev-start.sh" ]]; then
    echo "  ${GREEN}✓${NC} ~/dev-start.sh already linked"
  elif [[ -f "$script_dir/dev-start.sh" ]]; then
    ln -s "$script_dir/dev-start.sh" "$HOME/dev-start.sh"
    chmod +x "$script_dir/dev-start.sh"
    echo "  ${GREEN}✓${NC} ~/dev-start.sh → $script_dir/dev-start.sh"
  fi

  echo ""
  echo "${GREEN}✓ Setup complete!${NC}"
  echo ""
  echo "  Next steps:"
  echo "    ${GREEN}~/dev-start.sh switch feature/your-branch${NC}   ← set your first feature branch"
  echo "    ${GREEN}~/dev-start.sh${NC}                              ← start all sessions"
  echo ""
}

cmd_list() {
  echo ""
  echo "${BOLD}Active tmux sessions:${NC}"
  tmux list-sessions 2>/dev/null | grep "^kibana" | while read line; do
    echo "  ${GREEN}●${NC} $line"
  done

  echo ""
  echo "${BOLD}Git worktrees:${NC}"
  git -C "$KIBANA_MAIN_DIR" worktree list 2>/dev/null | while read line; do
    echo "  ${BLUE}↳${NC} $line"
  done

  echo ""
  echo "${BOLD}Port assignments:${NC}"
  local main_k_port main_es_display
  main_k_port=$(grep -E "^ *port:" "$KIBANA_MAIN_DIR/config/kibana.dev.yml" 2>/dev/null | head -1 | awk '{print $2}')
  main_es_display=$(get_es_display "$KIBANA_MAIN_DIR/config/kibana.dev.yml")
  printf "  %-30s →  Kibana :%-6s  ES %s\n" \
    "kibana-main" "${main_k_port:-$MAIN_KIBANA_PORT}" "$main_es_display"

  if [[ -f "$STATE_FILE" ]]; then
    source "$STATE_FILE"
    local feat_k_port feat_es_display
    feat_k_port=$(grep -E "^ *port:" "$FEAT_DIR/config/kibana.dev.yml" 2>/dev/null | head -1 | awk '{print $2}')
    feat_es_display=$(get_es_display "$FEAT_DIR/config/kibana.dev.yml")
    printf "  %-30s →  Kibana :%-6s  ES %s\n" \
      "kibana-feat ($FEAT_BRANCH)" "${feat_k_port:-$FEAT_KIBANA_PORT}" "$feat_es_display"
  else
    printf "  %-30s →  ${YELLOW}not configured — run: ./dev-start.sh switch <branch>${NC}\n" "kibana-feat"
  fi

  for yml in "$WORKTREE_BASE"/*/config/kibana.dev.yml; do
    [[ -f "$yml" ]] || continue
    wt_name=$(echo "$yml" | sed "s|$WORKTREE_BASE/||" | sed 's|/config/kibana.dev.yml||')
    # skip the current feat worktree — already shown above
    [[ "$WORKTREE_BASE/$wt_name" == "$FEAT_DIR" ]] && continue
    # skip if no active tmux session for this worktree
    session_name=$(echo "kibana-$wt_name" | tr '.' '-')
    tmux has-session -t "$session_name" 2>/dev/null || continue
    k_port=$(grep -E "^ *port:" "$yml" 2>/dev/null | head -1 | awk '{print $2}')
    local es_display
    es_display=$(get_es_display "$yml")
    printf "  %-30s →  Kibana :%-6s  ES %s\n" \
      "kibana-$wt_name" "$k_port" "$es_display"
  done

  # Port mismatch warnings
  local warnings=()

  # kibana-main
  if [[ -f "$KIBANA_MAIN_DIR/config/kibana.dev.yml" ]]; then
    local chk_main_k chk_main_es
    chk_main_k=$(grep -E "^ *port:" "$KIBANA_MAIN_DIR/config/kibana.dev.yml" 2>/dev/null | head -1 | awk '{print $2}')
    chk_main_es=$(grep -E "^ *- \"?http://localhost:" "$KIBANA_MAIN_DIR/config/kibana.dev.yml" 2>/dev/null | head -1 | sed 's|.*http://localhost:||' | tr -d ' "')
    if [[ -n "$chk_main_k" && "$chk_main_k" != "$MAIN_KIBANA_PORT" ]]; then
      warnings+=("kibana-main: kibana.dev.yml has Kibana port $chk_main_k but expected $MAIN_KIBANA_PORT — fix: manually update to $MAIN_KIBANA_PORT or delete the file and re-run: ~/dev-start.sh")
    fi
    if [[ -n "$chk_main_es" && "$chk_main_es" != "$MAIN_ES_PORT" ]]; then
      warnings+=("kibana-main: kibana.dev.yml has ES port $chk_main_es but expected $MAIN_ES_PORT — fix: manually update to $MAIN_ES_PORT or delete the file and re-run: ~/dev-start.sh")
    fi
  fi

  # kibana-feat
  if [[ -f "$STATE_FILE" ]]; then
    source "$STATE_FILE"
    if [[ -f "$FEAT_DIR/config/kibana.dev.yml" ]]; then
      existing_k=$(grep -E "^ *port:" "$FEAT_DIR/config/kibana.dev.yml" 2>/dev/null | head -1 | awk '{print $2}')
      existing_es=$(grep -E "^ *- \"?http://localhost:" "$FEAT_DIR/config/kibana.dev.yml" 2>/dev/null | head -1 | sed 's|.*http://localhost:||' | tr -d ' "')
      if [[ -n "$existing_k" && "$existing_k" != "$FEAT_KIBANA_PORT" ]]; then
        warnings+=("kibana-feat: kibana.dev.yml has Kibana port $existing_k but expected $FEAT_KIBANA_PORT — run: ~/dev-start.sh switch $FEAT_BRANCH")
      fi
      if [[ -n "$existing_es" && "$existing_es" != "$FEAT_ES_PORT" ]]; then
        warnings+=("kibana-feat: kibana.dev.yml has ES port $existing_es but expected $FEAT_ES_PORT — run: ~/dev-start.sh switch $FEAT_BRANCH")
      fi
    fi
  fi

  if [[ ${#warnings[@]} -gt 0 ]]; then
    echo ""
    echo "${BOLD}${YELLOW}⚠ Port mismatches detected:${NC}"
    for w in "${warnings[@]}"; do
      echo "  ${YELLOW}⚠${NC} $w"
    done
  fi

  echo ""
}

cmd_switch() {
  local branch="" use_remote=false

  # Parse arguments: branch name and optional --remote flag
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --remote) use_remote=true; shift ;;
      *)        branch="$1"; shift ;;
    esac
  done

  if [[ -z "$branch" ]]; then
    echo "${RED}Error:${NC} Please provide a branch name."
    echo "  Usage: ./dev-start.sh switch <branch> [--remote]"
    exit 1
  fi

  local short_name worktree_dir
  short_name=$(echo "$branch" | sed 's|.*/||')
  worktree_dir="$WORKTREE_BASE/$short_name"

  echo ""
  echo "${BOLD}Switching kibana-feat → $branch${NC}"
  echo ""

  # Auto-create branch from upstream main if it doesn't exist locally or on origin
  # Done first — before killing any session — so we fail safe if the branch can't be created
  if ! git -C "$KIBANA_MAIN_DIR" rev-parse --verify "$branch" &>/dev/null && \
     ! git -C "$KIBANA_MAIN_DIR" rev-parse --verify "refs/remotes/origin/$branch" &>/dev/null; then
    echo "${BLUE}→${NC} Branch '$branch' not found — fetching upstream and creating branch..."

    git -C "$KIBANA_MAIN_DIR" fetch upstream
    if [[ $? -ne 0 ]]; then
      echo "${RED}Error:${NC} Failed to fetch from upstream — check your upstream remote."
      exit 1
    fi

    git -C "$KIBANA_MAIN_DIR" branch "$branch" upstream/main
    if [[ $? -ne 0 ]]; then
      echo "${RED}Error:${NC} Failed to create branch '$branch'."
      exit 1
    fi
    echo "${GREEN}✓${NC} Branch '$branch' created from upstream/main"
  fi

  if tmux has-session -t "kibana-feat" 2>/dev/null; then
    echo "${BLUE}→${NC} Stopping current kibana-feat session..."
    tmux kill-session -t "kibana-feat"
    echo "${GREEN}✓${NC} Session stopped."
  fi

  if [[ -f "$STATE_FILE" ]]; then
    source "$STATE_FILE"
    if [[ -n "${FEAT_DIR:-}" && "$FEAT_DIR" != "$worktree_dir" && -d "$FEAT_DIR" ]]; then
      echo "${BLUE}→${NC} Removing old worktree at $FEAT_DIR..."
      git -C "$KIBANA_MAIN_DIR" worktree remove "$FEAT_DIR" --force
      echo "${GREEN}✓${NC} Old worktree removed."
    fi
  fi

  if [[ ! -d "$worktree_dir" ]]; then
    echo "${BLUE}→${NC} Creating worktree for ${BOLD}$branch${NC}..."
    mkdir -p "$WORKTREE_BASE"
    git -C "$KIBANA_MAIN_DIR" worktree add "$worktree_dir" "$branch"
    if [[ $? -ne 0 ]]; then
      echo "${RED}Error:${NC} Failed to create worktree."
      exit 1
    fi
    echo "${GREEN}✓${NC} Worktree created at $worktree_dir"
  else
    echo "${BLUE}→${NC} Worktree already exists at $worktree_dir, reusing."
  fi

  if [[ "$use_remote" == true ]]; then
    generate_remote_kibana_dev_yml "$worktree_dir" "$FEAT_KIBANA_PORT"
  else
    generate_kibana_dev_yml "$worktree_dir" "$FEAT_KIBANA_PORT" "$FEAT_ES_PORT"
  fi
  generate_cursor_mcp_json "$worktree_dir" "$FEAT_KIBANA_PORT" "$FEAT_HOST"
  save_feat_state "$branch" "$worktree_dir"

  echo "${BLUE}→${NC} Creating kibana-feat session..."
  tmux new-session -d -s "kibana-feat" -c "$worktree_dir"
  build_kibana_session "kibana-feat" "$worktree_dir" \
    "$FEAT_KIBANA_PORT" "$FEAT_ES_PORT" "$FEAT_HOST" "$short_name"

  echo ""
  echo "${GREEN}✓${NC} kibana-feat is now on ${BOLD}$branch${NC}"
  if [[ "$use_remote" == true ]]; then
    local remote_host
    remote_host=$(grep -E "^ *hosts:" "$REMOTE_ES_CONFIG" 2>/dev/null | head -1 | sed 's|.*hosts: *||' | tr -d '"' | tr -d ' ')
    echo "   Kibana  → http://localhost:${FEAT_KIBANA_PORT}  (auto-starts — remote ES)"
    echo "   ES      → ${BLUE}${remote_host}${NC}  (from ~/.kibana-remote-es.yml)"
  else
    echo "   Kibana  → http://localhost:${FEAT_KIBANA_PORT}  (auto-starts after ES is ready)"
    echo "   ES      → http://localhost:${FEAT_ES_PORT}"
  fi
  echo "   Cursor  → KIBANA_URL=http://${FEAT_HOST}:${FEAT_KIBANA_PORT}"
  echo ""

  tmux attach-session -t "kibana-feat"
}

cmd_new() {
  local branch="" mode="--lightweight" use_remote=false

  # Parse arguments: branch name, --full, --remote
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --full)   mode="--full"; shift ;;
      --remote) use_remote=true; shift ;;
      *)        branch="$1"; shift ;;
    esac
  done

  if [[ -z "$branch" ]]; then
    echo "${RED}Error:${NC} Please provide a branch name."
    echo "  Usage: ./dev-start.sh new <branch> [--full] [--remote]"
    exit 1
  fi

  local session short_name worktree_dir
  session=$(branch_to_session "$branch")
  short_name=$(echo "$branch" | sed 's|.*/||')
  worktree_dir="$WORKTREE_BASE/$short_name"

  if tmux has-session -t "$session" 2>/dev/null; then
    echo "${YELLOW}Session '$session' already exists. Attaching...${NC}"
    tmux attach-session -t "$session"
    exit 0
  fi

  # Auto-create branch from upstream main if it doesn't exist locally or on origin
  if ! git -C "$KIBANA_MAIN_DIR" rev-parse --verify "$branch" &>/dev/null && \
     ! git -C "$KIBANA_MAIN_DIR" rev-parse --verify "refs/remotes/origin/$branch" &>/dev/null; then
    echo "${BLUE}→${NC} Branch '$branch' not found — fetching upstream and creating branch..."

    git -C "$KIBANA_MAIN_DIR" fetch upstream
    if [[ $? -ne 0 ]]; then
      echo "${RED}Error:${NC} Failed to fetch from upstream — check your upstream remote."
      exit 1
    fi

    git -C "$KIBANA_MAIN_DIR" branch "$branch" upstream/main
    if [[ $? -ne 0 ]]; then
      echo "${RED}Error:${NC} Failed to create branch '$branch'."
      exit 1
    fi
    echo "${GREEN}✓${NC} Branch '$branch' created from upstream/main"
  fi

  if [[ ! -d "$worktree_dir" ]]; then
    echo "${BLUE}→${NC} Creating worktree for ${BOLD}$branch${NC}..."
    mkdir -p "$WORKTREE_BASE"
    git -C "$KIBANA_MAIN_DIR" worktree add "$worktree_dir" "$branch"
    if [[ $? -ne 0 ]]; then
      echo "${RED}Error:${NC} Failed to create worktree."
      exit 1
    fi
    echo "${GREEN}✓${NC} Worktree created at $worktree_dir"
  else
    echo "${BLUE}→${NC} Reusing existing worktree at $worktree_dir"
  fi

  local ports kibana_port es_port
  echo "${BLUE}→${NC} Finding available ports..."
  ports=$(find_free_ports)
  kibana_port=$(echo "$ports" | awk '{print $1}')
  es_port=$(echo "$ports" | awk '{print $2}')

  if [[ "$use_remote" == true ]]; then
    generate_remote_kibana_dev_yml "$worktree_dir" "$kibana_port"
  elif [[ -f "$worktree_dir/config/kibana.dev.yml" ]]; then
    echo "${YELLOW}⚠${NC} kibana.dev.yml already exists — keeping existing config."
    echo "${YELLOW}  Delete $worktree_dir/config/kibana.dev.yml and re-run to regenerate with fresh ports.${NC}"
    local existing_k
    existing_k=$(grep -E "^ *port:" "$worktree_dir/config/kibana.dev.yml" 2>/dev/null | head -1 | awk '{print $2}')
    local existing_es
    existing_es=$(grep -E "^ *- \"?http://localhost:" "$worktree_dir/config/kibana.dev.yml" 2>/dev/null | head -1 | sed 's|.*http://localhost:||' | tr -d ' "')
    [[ -n "$existing_k" ]] && kibana_port="$existing_k"
    [[ -n "$existing_es" ]] && es_port="$existing_es"
  else
    generate_kibana_dev_yml "$worktree_dir" "$kibana_port" "$es_port"
  fi
  generate_cursor_mcp_json "$worktree_dir" "$kibana_port" "localhost"

  echo "${BLUE}→${NC} Creating tmux session ${BOLD}$session${NC}..."
  tmux new-session -d -s "$session" -c "$worktree_dir"

  if [[ "$mode" == "--full" ]]; then
    build_kibana_session "$session" "$worktree_dir" "$kibana_port" "$es_port" "localhost" "$short_name"
  else
    build_lightweight_session "$session" "$worktree_dir" "$kibana_port" "$es_port" "localhost" "$short_name"
  fi

  echo ""
  echo "${GREEN}✓${NC} Session '${BOLD}$session${NC}' ready"
  if [[ "$use_remote" == true ]]; then
    local remote_host
    remote_host=$(grep -E "^ *hosts:" "$REMOTE_ES_CONFIG" 2>/dev/null | head -1 | sed 's|.*hosts: *||' | tr -d '"' | tr -d ' ')
    echo "   Kibana  → http://localhost:${kibana_port}  (auto-starts — remote ES)"
    echo "   ES      → ${BLUE}${remote_host}${NC}  (from ~/.kibana-remote-es.yml)"
  else
    echo "   Kibana  → http://localhost:${kibana_port}  (auto-starts after ES is ready)"
    echo "   ES      → http://localhost:${es_port}"
  fi
  echo "   Cursor  → KIBANA_URL set to http://localhost:${kibana_port}"
  echo ""
  echo "  Switch sessions:  Ctrl-a s"
  echo ""

  tmux attach-session -t "$session"
}

cmd_attach() {
  local branch="$1"
  if [[ -z "$branch" ]]; then
    echo "${RED}Error:${NC} Please provide a branch name."
    exit 1
  fi

  local session
  session=$(branch_to_session "$branch")

  if ! tmux has-session -t "$session" 2>/dev/null; then
    echo "${RED}Error:${NC} No session found for '$branch' (looked for '$session')."
    echo "  Run ${GREEN}./dev-start.sh list${NC} to see active sessions."
    echo "  Run ${GREEN}./dev-start.sh new $branch${NC} to create one."
    exit 1
  fi

  tmux attach-session -t "$session"
}

cmd_kill() {
  local branch="$1"
  if [[ -z "$branch" ]]; then
    echo "${RED}Error:${NC} Please provide a branch name."
    exit 1
  fi

  local session short_name worktree_dir
  session=$(branch_to_session "$branch")
  short_name=$(echo "$branch" | sed 's|.*/||')
  # Find worktree by matching branch name in git worktree list
  worktree_dir=$(git -C "$KIBANA_MAIN_DIR" worktree list 2>/dev/null \
    | grep "\[$short_name\]\|\[$branch\]" \
    | awk '{print $1}' | head -1)
  # Fall back to derived path if not found via git
  [[ -z "$worktree_dir" ]] && worktree_dir="$WORKTREE_BASE/$short_name"

  if tmux has-session -t "$session" 2>/dev/null; then
    tmux kill-session -t "$session"
    echo "${GREEN}✓${NC} Killed session '$session'."
  else
    echo "${YELLOW}⚠${NC} No session found for '$session'."
  fi

  if [[ -d "$worktree_dir" ]]; then
    echo "${BLUE}→${NC} Removing worktree at $worktree_dir..."
    git -C "$KIBANA_MAIN_DIR" worktree remove "$worktree_dir" --force
    echo "${GREEN}✓${NC} Worktree removed."
  else
    echo "${YELLOW}⚠${NC} No worktree found at $worktree_dir."
  fi
}

cmd_kill_all() {
  echo "${YELLOW}Killing all kibana-* sessions...${NC}"
  tmux list-sessions 2>/dev/null | grep "^kibana" | cut -d: -f1 | while read s; do
    tmux kill-session -t "$s"
    echo "${GREEN}✓${NC} Killed: $s"
  done
}

cmd_clean() {
  local target="${1:-}"

  if [[ -z "$target" ]]; then
    echo ""
    echo "${BOLD}ES data folders in $ES_DATA_BASE:${NC}"
    if [[ -d "$ES_DATA_BASE" ]]; then
      local total_size
      total_size=$(du -sh "$ES_DATA_BASE" 2>/dev/null | awk '{print $1}')
      for folder in "$ES_DATA_BASE"/*/; do
        [[ -d "$folder" ]] || continue
        local name size
        name=$(basename "$folder")
        size=$(du -sh "$folder" 2>/dev/null | awk '{print $1}')
        echo "  ${BLUE}↳${NC} $name  ($size)"
      done
      echo ""
      echo "  Total: $total_size"
    else
      echo "  ${YELLOW}(no ES data directory found)${NC}"
    fi
    echo ""
    echo "Usage:"
    echo "  ${GREEN}./dev-start.sh clean main${NC}     → delete main-cluster data"
    echo "  ${GREEN}./dev-start.sh clean feat${NC}     → delete feat worktree data"
    echo "  ${GREEN}./dev-start.sh clean <name>${NC}   → delete specific data folder"
    echo "  ${GREEN}./dev-start.sh clean all${NC}      → delete ALL ES data"
    echo ""
    return
  fi

  local folder_name
  case "$target" in
    main)
      folder_name="$MAIN_DATA_FOLDER"
      ;;
    feat)
      if [[ -f "$STATE_FILE" ]]; then
        source "$STATE_FILE"
        folder_name=$(echo "$FEAT_BRANCH" | sed 's|.*/||')
      else
        echo "${RED}Error:${NC} No feat state found. Provide the folder name directly."
        echo "  Run ${GREEN}./dev-start.sh clean${NC} to see available folders."
        return 1
      fi
      ;;
    all)
      if [[ -d "$ES_DATA_BASE" ]]; then
        local total_size
        total_size=$(du -sh "$ES_DATA_BASE" 2>/dev/null | awk '{print $1}')
        echo "${BLUE}→${NC} Removing ALL ES data ($total_size)..."
        rm -rf "$ES_DATA_BASE"
        echo "${GREEN}✓${NC} All ES data deleted. Clusters will start fresh."
      else
        echo "${YELLOW}⚠${NC} No ES data directory found at $ES_DATA_BASE"
      fi
      return
      ;;
    *)
      folder_name="$target"
      ;;
  esac

  local data_dir="$ES_DATA_BASE/$folder_name"
  if [[ -d "$data_dir" ]]; then
    local size
    size=$(du -sh "$data_dir" 2>/dev/null | awk '{print $1}')
    echo "${BLUE}→${NC} Removing ES data for '$folder_name' ($size)..."
    rm -rf "$data_dir"
    echo "${GREEN}✓${NC} Deleted $data_dir — ES will start with a fresh cluster."
  else
    echo "${YELLOW}⚠${NC} No data folder found at $data_dir"
    echo "  Run ${GREEN}./dev-start.sh clean${NC} to see available folders."
  fi
}

cmd_main() {
  if [[ ! -f "$KBN_START" ]]; then
    echo "${RED}Error:${NC} kbn-start.sh not found at $KBN_START"
    echo ""
    echo "  Install it first:"
    echo "    mkdir -p ~/bin"
    echo "    cp kbn-start.sh ~/bin/kbn-start.sh"
    echo "    chmod +x ~/bin/kbn-start.sh"
    exit 1
  fi

  load_feat_state

  # kibana-main
  if ! tmux has-session -t "kibana-main" 2>/dev/null; then
    echo "${BLUE}→${NC} Creating ${BOLD}kibana-main${NC}  Kibana :$MAIN_KIBANA_PORT  ES :$MAIN_ES_PORT..."
    [[ ! -f "$KIBANA_MAIN_DIR/config/kibana.dev.yml" ]] && \
      generate_kibana_dev_yml "$KIBANA_MAIN_DIR" "$MAIN_KIBANA_PORT" "$MAIN_ES_PORT"
    generate_cursor_mcp_json "$KIBANA_MAIN_DIR" "$MAIN_KIBANA_PORT" "$MAIN_HOST"
    tmux new-session -d -s "kibana-main" -c "$KIBANA_MAIN_DIR"
    build_kibana_session "kibana-main" "$KIBANA_MAIN_DIR" \
      "$MAIN_KIBANA_PORT" "$MAIN_ES_PORT" "$MAIN_HOST" "$MAIN_DATA_FOLDER"
    echo "${GREEN}✓${NC} Session: kibana-main"
  else
    echo "${YELLOW}↩${NC} Session kibana-main already running, skipping."
  fi

  # kibana-feat
  if ! tmux has-session -t "kibana-feat" 2>/dev/null; then
    local feat_short
    feat_short=$(echo "$FEAT_BRANCH" | sed 's|.*/||')
    echo "${BLUE}→${NC} Creating ${BOLD}kibana-feat${NC} ($FEAT_BRANCH)  Kibana :$FEAT_KIBANA_PORT  ES :$FEAT_ES_PORT..."
    if [[ -f "$FEAT_DIR/config/kibana.dev.yml" ]]; then
      local existing_k existing_es
      existing_k=$(grep -E "^ *port:" "$FEAT_DIR/config/kibana.dev.yml" 2>/dev/null | head -1 | awk '{print $2}')
      existing_es=$(grep -E "^ *- \"?http://localhost:" "$FEAT_DIR/config/kibana.dev.yml" 2>/dev/null | head -1 | sed 's|.*http://localhost:||' | tr -d ' "')
      if { [[ -n "$existing_k" && "$existing_k" != "$FEAT_KIBANA_PORT" ]] || \
           [[ -n "$existing_es" && "$existing_es" != "$FEAT_ES_PORT" ]]; }; then
        echo "${YELLOW}⚠ Warning:${NC} kibana.dev.yml has wrong ports (Kibana: $existing_k, ES: $existing_es) — regenerating..."
        generate_kibana_dev_yml "$FEAT_DIR" "$FEAT_KIBANA_PORT" "$FEAT_ES_PORT"
      fi
    else
      generate_kibana_dev_yml "$FEAT_DIR" "$FEAT_KIBANA_PORT" "$FEAT_ES_PORT"
    fi
    generate_cursor_mcp_json "$FEAT_DIR" "$FEAT_KIBANA_PORT" "$FEAT_HOST"
    tmux new-session -d -s "kibana-feat" -c "$FEAT_DIR"
    build_kibana_session "kibana-feat" "$FEAT_DIR" \
      "$FEAT_KIBANA_PORT" "$FEAT_ES_PORT" "$FEAT_HOST" "$feat_short"
    echo "${GREEN}✓${NC} Session: kibana-feat"
  else
    echo "${YELLOW}↩${NC} Session kibana-feat already running, skipping."
  fi

  echo ""
  echo "${GREEN}✓${NC} All sessions ready:"
  echo "   kibana-feat  ($FEAT_BRANCH)"
  echo "     Kibana  → http://localhost:${FEAT_KIBANA_PORT}"
  echo "     Cursor  → KIBANA_URL=http://${FEAT_HOST}:${FEAT_KIBANA_PORT}"
  echo "   kibana-main"
  echo "     Kibana  → http://localhost:${MAIN_KIBANA_PORT}"
  echo "     Cursor  → KIBANA_URL=http://${MAIN_HOST}:${MAIN_KIBANA_PORT}"
  echo ""
  echo "  Kibana auto-starts in each session once ES is ready."
  echo ""
  echo "  ${BOLD}Ctrl-a s${NC}  → session switcher"
  echo "  ${BOLD}Ctrl-a w${NC}  → window overview"
  echo ""

  tmux attach-session -t "kibana-feat"
}
# ── END COMMANDS ──────────────────────────────────────────


# ── FIRST-RUN DETECTION ───────────────────────────────────
# If no config file and not running setup/help, nudge the user
if [[ ! -f "$KIBANA_DEV_CONF" && "${1:-main}" != "setup" && "${1:-main}" != "help" && "${1:-}" != "--help" ]]; then
  echo ""
  echo "${YELLOW}⚠${NC}  No config file found. Run the setup wizard to configure paths and ports:"
  echo "     ${GREEN}./dev-start.sh setup${NC}"
  echo ""
  echo "   Using defaults for now. Press Ctrl-C to cancel, or wait to continue..."
  sleep 3
fi

# ── ROUTER ────────────────────────────────────────────────
case "${1:-main}" in
  main)        cmd_main ;;
  setup)       cmd_setup ;;
  switch)      shift; cmd_switch "$@" ;;
  new)         shift; cmd_new "$@" ;;
  attach)      cmd_attach "$2" ;;
  list)        cmd_list ;;
  clean)       cmd_clean "$2" ;;
  kill)        cmd_kill "$2" ;;
  kill-all)    cmd_kill_all ;;
  help|--help) print_help ;;
  *)
    echo "${RED}Unknown command:${NC} $1"
    print_help
    exit 1
    ;;
esac
