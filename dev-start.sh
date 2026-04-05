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
#    ./dev-start.sh sync                       → regenerate kibana.dev.yml from template (all sessions)
#    ./dev-start.sh sync main|feat|<branch>    → regenerate for a specific session
#    ./dev-start.sh status                     → health check all sessions (ping ES + Kibana)
#    ./dev-start.sh restart main|feat|<branch> → restart ES + Kibana in a running session
#    ./dev-start.sh renew --cluster-name X → refresh remote ES credentials from oblt-cli
#    ./dev-start.sh renew                  → refresh using saved cluster name
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
OBLT_CLUSTER_NAME="${OBLT_CLUSTER_NAME:-}"

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
  echo "  ${GREEN}./dev-start.sh sync${NC}                      Regenerate kibana.dev.yml from template (all sessions)"
  echo "  ${GREEN}./dev-start.sh sync main|feat|<branch>${NC}  Regenerate for a specific session"
  echo "  ${GREEN}./dev-start.sh status${NC}                    Health check all sessions (ping ES + Kibana)"
  echo "  ${GREEN}./dev-start.sh restart main|feat|<branch>${NC} Restart ES + Kibana in a running session"
  echo "  ${GREEN}./dev-start.sh renew --cluster-name <n>${NC} Refresh remote ES credentials from oblt-cli"
  echo "  ${GREEN}./dev-start.sh renew${NC}                   Refresh using saved cluster name"
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
  echo "    ./dev-start.sh sync                     # after editing the template"
  echo "    ./dev-start.sh restart feat"
  echo "    ./dev-start.sh renew --cluster-name edge-oblt --save"
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

  # ── Ask for remote ES (optional) ────────────────────────
  echo ""
  echo "  ${BOLD}Remote ES${NC} (optional — press Enter to skip)"

  local default_cluster="${OBLT_CLUSTER_NAME}"
  printf "  oblt-cli cluster name [${BLUE}${default_cluster:-none}${NC}]: "
  read -r input_cluster
  input_cluster="${input_cluster:-$default_cluster}"

  # ── Validate Kibana repo ───────────────────────────────
  echo ""
  if [[ -d "$input_kibana/.git" ]] || [[ -d "$input_kibana/package.json" ]]; then
    echo "  ${GREEN}✓${NC} Kibana repo found at $input_kibana"
  else
    echo "  ${YELLOW}⚠${NC} No git repo found at $input_kibana — make sure to clone Kibana there first."
  fi

  # ── Write config ───────────────────────────────────────
  {
    cat <<EOF
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
    if [[ -n "$input_cluster" ]]; then
      cat <<EOF

# Remote ES (oblt-cli)
OBLT_CLUSTER_NAME="$input_cluster"
EOF
    fi
  } > "$KIBANA_DEV_CONF"

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
  local wt_path
  git -C "$KIBANA_MAIN_DIR" worktree list 2>/dev/null | while read line; do
    wt_path=$(echo "$line" | awk '{print $1}')
    # Only show the main repo and worktrees under WORKTREE_BASE
    [[ "$wt_path" == "$KIBANA_MAIN_DIR" || "$wt_path" == "$WORKTREE_BASE"/* ]] || continue
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

cmd_status() {
  echo ""
  echo "${BOLD}Health check:${NC}"
  echo ""

  local has_sessions=false

  # Helper: check a single session
  check_session() {
    local label="$1" yml="$2"
    has_sessions=true

    local kibana_port es_port es_host is_remote
    kibana_port=$(grep -E "^ *port:" "$yml" 2>/dev/null | head -1 | awk '{print $2}')

    # Detect local vs remote
    es_port=$(grep -E "^ *- \"?http://localhost:" "$yml" 2>/dev/null | head -1 | sed 's|.*http://localhost:||' | tr -d ' "')
    es_host=$(grep -E "^ *hosts: https?://" "$yml" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')
    is_remote=false
    [[ -z "$es_port" ]] && is_remote=true

    # Check Kibana
    local kbn_status kbn_color
    local kbn_http
    kbn_http=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${kibana_port}/api/status" --max-time 3 2>/dev/null)
    [[ -z "$kbn_http" ]] && kbn_http="000"
    if [[ "$kbn_http" == "200" ]]; then
      kbn_status="up" ; kbn_color="$GREEN"
    elif [[ "$kbn_http" == "000" ]]; then
      kbn_status="down" ; kbn_color="$RED"
    else
      kbn_status="starting" ; kbn_color="$YELLOW"
    fi

    # Check ES
    local es_status es_color es_display
    if [[ "$is_remote" == true ]]; then
      es_display="$es_host"
      local es_http
      es_http=$(curl -s -o /dev/null -w "%{http_code}" "$es_host" --max-time 5 2>/dev/null)
      [[ -z "$es_http" ]] && es_http="000"
      if [[ "$es_http" == "200" ]]; then
        es_status="up" ; es_color="$GREEN"
      elif [[ "$es_http" == "401" ]]; then
        # 401 means ES is reachable but needs auth — that's up
        es_status="up" ; es_color="$GREEN"
      elif [[ "$es_http" == "000" ]]; then
        es_status="unreachable" ; es_color="$RED"
      else
        es_status="error ($es_http)" ; es_color="$YELLOW"
      fi
    else
      es_display=":$es_port"
      local es_http
      es_http=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${es_port}/" --max-time 3 2>/dev/null)
      [[ -z "$es_http" ]] && es_http="000"
      if [[ "$es_http" == "200" || "$es_http" == "401" ]]; then
        es_status="up" ; es_color="$GREEN"
      elif [[ "$es_http" == "000" ]]; then
        es_status="down" ; es_color="$RED"
      else
        es_status="starting" ; es_color="$YELLOW"
      fi
    fi

    echo "  ${BOLD}$label${NC}"
    echo "    Kibana :${kibana_port}  ${kbn_color}${kbn_status}${NC}"
    echo "    ES     ${es_display}  ${es_color}${es_status}${NC}"
    echo ""
  }

  # kibana-main
  if tmux has-session -t "kibana-main" 2>/dev/null && [[ -f "$KIBANA_MAIN_DIR/config/kibana.dev.yml" ]]; then
    check_session "kibana-main" "$KIBANA_MAIN_DIR/config/kibana.dev.yml"
  fi

  # kibana-feat
  if tmux has-session -t "kibana-feat" 2>/dev/null && [[ -f "$STATE_FILE" ]]; then
    source "$STATE_FILE"
    if [[ -f "$FEAT_DIR/config/kibana.dev.yml" ]]; then
      check_session "kibana-feat ($FEAT_BRANCH)" "$FEAT_DIR/config/kibana.dev.yml"
    fi
  fi

  # Hotfix sessions
  local wt_name session_name
  for yml in "$WORKTREE_BASE"/*/config/kibana.dev.yml; do
    [[ -f "$yml" ]] || continue
    wt_name=$(echo "$yml" | sed "s|$WORKTREE_BASE/||" | sed 's|/config/kibana.dev.yml||')
    [[ -n "${FEAT_DIR:-}" && "$WORKTREE_BASE/$wt_name" == "$FEAT_DIR" ]] && continue
    session_name=$(echo "kibana-$wt_name" | tr '.' '-')
    tmux has-session -t "$session_name" 2>/dev/null || continue
    check_session "$session_name" "$yml"
  done

  if [[ "$has_sessions" == false ]]; then
    echo "  ${YELLOW}No active sessions found.${NC}"
    echo "  Start with: ${GREEN}./dev-start.sh${NC}"
  fi

  echo ""
}

cmd_sync() {
  local target="${1:-all}"

  echo ""
  echo "${BOLD}Syncing kibana.dev.yml from template${NC}"
  echo ""

  local synced=0

  # Helper: sync a single worktree
  sync_one() {
    local label="$1" dir="$2" kibana_port="$3" es_port="$4"

    if [[ ! -d "$dir" ]]; then
      echo "  ${YELLOW}⚠${NC} $label — directory not found: $dir"
      return
    fi

    local yml="$dir/config/kibana.dev.yml"
    local is_remote=false
    if [[ -f "$yml" ]] && grep -q "Remote ES" "$yml" 2>/dev/null; then
      is_remote=true
    fi

    if [[ "$is_remote" == true ]]; then
      generate_remote_kibana_dev_yml "$dir" "$kibana_port"
    else
      generate_kibana_dev_yml "$dir" "$kibana_port" "$es_port"
    fi
    synced=$((synced + 1))
  }

  case "$target" in
    main)
      sync_one "kibana-main" "$KIBANA_MAIN_DIR" "$MAIN_KIBANA_PORT" "$MAIN_ES_PORT"
      ;;
    feat)
      if [[ -f "$STATE_FILE" ]]; then
        source "$STATE_FILE"
        sync_one "kibana-feat ($FEAT_BRANCH)" "$FEAT_DIR" "$FEAT_KIBANA_PORT" "$FEAT_ES_PORT"
      else
        echo "${RED}Error:${NC} No feat state found. Run ${GREEN}./dev-start.sh switch <branch>${NC} first."
        return 1
      fi
      ;;
    all)
      # kibana-main
      sync_one "kibana-main" "$KIBANA_MAIN_DIR" "$MAIN_KIBANA_PORT" "$MAIN_ES_PORT"

      # kibana-feat
      if [[ -f "$STATE_FILE" ]]; then
        source "$STATE_FILE"
        sync_one "kibana-feat ($FEAT_BRANCH)" "$FEAT_DIR" "$FEAT_KIBANA_PORT" "$FEAT_ES_PORT"
      fi

      # Hotfix sessions — only those with an active tmux session
      local wt_name session_name
      for yml in "$WORKTREE_BASE"/*/config/kibana.dev.yml; do
        [[ -f "$yml" ]] || continue
        wt_name=$(echo "$yml" | sed "s|$WORKTREE_BASE/||" | sed 's|/config/kibana.dev.yml||')
        [[ -n "${FEAT_DIR:-}" && "$WORKTREE_BASE/$wt_name" == "$FEAT_DIR" ]] && continue
        session_name=$(echo "kibana-$wt_name" | tr '.' '-')
        tmux has-session -t "$session_name" 2>/dev/null || continue
        local wt_port wt_es_port
        wt_port=$(grep -E "^ *port:" "$yml" 2>/dev/null | head -1 | awk '{print $2}')
        wt_es_port=$(grep -E "^ *- \"?http://localhost:" "$yml" 2>/dev/null | head -1 | sed 's|.*http://localhost:||' | tr -d ' "')
        sync_one "$session_name" "$WORKTREE_BASE/$wt_name" "${wt_port}" "${wt_es_port}"
      done
      ;;
    *)
      # Treat as branch name
      local short_name wt_dir
      short_name=$(echo "$target" | sed 's|.*/||')
      wt_dir="$WORKTREE_BASE/$short_name"
      if [[ -f "$wt_dir/config/kibana.dev.yml" ]]; then
        local wt_port wt_es_port
        wt_port=$(grep -E "^ *port:" "$wt_dir/config/kibana.dev.yml" 2>/dev/null | head -1 | awk '{print $2}')
        wt_es_port=$(grep -E "^ *- \"?http://localhost:" "$wt_dir/config/kibana.dev.yml" 2>/dev/null | head -1 | sed 's|.*http://localhost:||' | tr -d ' "')
        sync_one "kibana-$short_name" "$wt_dir" "${wt_port}" "${wt_es_port}"
      else
        echo "${RED}Error:${NC} No kibana.dev.yml found at $wt_dir/config/"
        return 1
      fi
      ;;
  esac

  if [[ $synced -gt 0 ]]; then
    echo ""
    echo "${GREEN}✓${NC} Synced $synced session(s). Run ${GREEN}./dev-start.sh restart <session>${NC} to apply."
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

cmd_restart() {
  local target="${1:-}"

  if [[ -z "$target" ]]; then
    echo "${RED}Error:${NC} Please specify which session to restart."
    echo ""
    echo "  Usage: ${GREEN}./dev-start.sh restart main|feat|<branch>${NC}"
    echo ""
    echo "  Examples:"
    echo "    ${GREEN}./dev-start.sh restart feat${NC}"
    echo "    ${GREEN}./dev-start.sh restart main${NC}"
    echo "    ${GREEN}./dev-start.sh restart slo-crash${NC}"
    return 1
  fi

  # Resolve target → session name + directory
  local session="" dir=""
  case "$target" in
    main)
      session="kibana-main"
      dir="$KIBANA_MAIN_DIR"
      ;;
    feat)
      session="kibana-feat"
      if [[ -f "$STATE_FILE" ]]; then
        source "$STATE_FILE"
        dir="$FEAT_DIR"
      else
        echo "${RED}Error:${NC} No feat state found. Run ${GREEN}./dev-start.sh switch <branch>${NC} first."
        return 1
      fi
      ;;
    *)
      session=$(branch_to_session "$target")
      local short_name
      short_name=$(echo "$target" | sed 's|.*/||')
      dir="$WORKTREE_BASE/$short_name"
      ;;
  esac

  # Verify the session exists
  if ! tmux has-session -t "$session" 2>/dev/null; then
    echo "${RED}Error:${NC} Session '$session' is not running."
    echo "  Check active sessions with: ${GREEN}./dev-start.sh list${NC}"
    return 1
  fi

  # Read ports and detect local vs remote from existing config
  local yml="$dir/config/kibana.dev.yml"
  if [[ ! -f "$yml" ]]; then
    echo "${RED}Error:${NC} No kibana.dev.yml found at $dir/config/"
    return 1
  fi

  local kibana_port es_port host data_folder is_remote
  kibana_port=$(grep -E "^ *port:" "$yml" 2>/dev/null | head -1 | awk '{print $2}')
  es_port=$(grep -E "^ *- \"?http://localhost:" "$yml" 2>/dev/null | head -1 | sed 's|.*http://localhost:||' | tr -d ' "')
  is_remote=false

  if [[ -z "$es_port" ]]; then
    is_remote=true
    es_port="remote"
  fi

  # Determine host and data folder based on session type
  case "$target" in
    main) host="$MAIN_HOST"; data_folder="$MAIN_DATA_FOLDER" ;;
    feat)
      host="$FEAT_HOST"
      data_folder=$(echo "$FEAT_BRANCH" | sed 's|.*/||')
      ;;
    *)
      host="localhost"
      data_folder=$(echo "$target" | sed 's|.*/||')
      ;;
  esac

  echo ""
  echo "${BOLD}Restarting $session${NC}"

  # Kill Kibana first (pane 1), then ES (pane 0)
  echo "${BLUE}→${NC} Stopping Kibana..."
  tmux send-keys -t "${session}:servers.1" C-c
  echo "${BLUE}→${NC} Stopping ES..."
  tmux send-keys -t "${session}:servers.0" C-c

  # Wait for Kibana port to be released (this is the slow one — up to 30s graceful shutdown)
  echo "${BLUE}→${NC} Waiting for Kibana to exit..."
  local wait_count=0
  while lsof -ti :${kibana_port} &>/dev/null && [[ $wait_count -lt 20 ]]; do
    sleep 2
    wait_count=$((wait_count + 1))
  done

  # If Kibana is still hanging, force-kill it
  if lsof -ti :${kibana_port} &>/dev/null; then
    echo "${YELLOW}⚠${NC} Kibana didn't exit cleanly, force-killing..."
    lsof -ti :${kibana_port} | xargs kill -9 2>/dev/null || true
    sleep 1
  fi

  # Wait for ES port too (if local)
  if [[ "$is_remote" != true ]]; then
    wait_count=0
    while lsof -ti :${es_port} &>/dev/null && [[ $wait_count -lt 10 ]]; do
      sleep 2
      wait_count=$((wait_count + 1))
    done
  fi

  # Make sure pane 1 (Kibana) is at a clean shell prompt
  tmux send-keys -t "${session}:servers.1" C-c
  sleep 1
  tmux send-keys -t "${session}:servers.1" "" Enter

  # Re-launch kbn-start in the left pane
  echo "${BLUE}→${NC} Re-launching kbn-start..."
  tmux send-keys -t "${session}:servers.0" \
    "$KBN_START $data_folder --kibana-port $kibana_port --es-port ${es_port} --host $host" \
    Enter

  echo ""
  echo "${GREEN}✓${NC} Restart initiated for ${BOLD}$session${NC}"
  if [[ "$is_remote" == true ]]; then
    echo "   Kibana  → http://localhost:${kibana_port}  (remote ES)"
  else
    echo "   Kibana  → http://localhost:${kibana_port}"
    echo "   ES      → http://localhost:${es_port}"
  fi
  echo ""
}

cmd_renew() {
  local cluster_name=""
  local save_config=false

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cluster-name) cluster_name="$2"; shift 2 ;;
      --save)         save_config=true; shift ;;
      *)
        echo "${RED}Error:${NC} Unknown argument '$1'"
        echo "  Usage: ${GREEN}./dev-start.sh renew --cluster-name <name> [--save]${NC}"
        return 1
        ;;
    esac
  done

  # Fall back to saved cluster name from config
  if [[ -z "$cluster_name" ]]; then
    cluster_name="$OBLT_CLUSTER_NAME"
  fi

  if [[ -z "$cluster_name" ]]; then
    echo "${RED}Error:${NC} No cluster name provided."
    echo ""
    echo "  Usage: ${GREEN}./dev-start.sh renew --cluster-name <name>${NC}"
    echo ""
    echo "  To save the cluster name for future renewals:"
    echo "    ${GREEN}./dev-start.sh renew --cluster-name <name> --save${NC}"
    echo ""
    echo "  Find your cluster name with:"
    echo "    ${GREEN}oblt-cli cluster list${NC}"
    return 1
  fi

  # Check that oblt-cli is available
  if ! command -v oblt-cli &>/dev/null; then
    echo "${RED}Error:${NC} oblt-cli not found in PATH."
    echo "  Install it first: ${GREEN}https://github.com/elastic/observability-test-environments${NC}"
    return 1
  fi

  echo "${BLUE}→${NC} Fetching kibana config from cluster '${BOLD}$cluster_name${NC}'..."

  # Fetch fresh kibana config from oblt-cli
  if ! oblt-cli cluster secrets kibana-config \
    --cluster-name "$cluster_name" \
    --output-file "$REMOTE_ES_CONFIG" 2>/dev/null; then
    echo "${RED}Error:${NC} Failed to fetch kibana config for cluster '$cluster_name'."
    echo ""
    echo "  Check the cluster name is correct:"
    echo "    ${GREEN}oblt-cli cluster list${NC}"
    echo ""
    echo "  Or check your Google Cloud auth:"
    echo "    ${GREEN}gcloud auth login${NC}"
    return 1
  fi

  echo "${GREEN}✓${NC} Remote ES config updated: $REMOTE_ES_CONFIG"

  # Save cluster name to config if requested
  if [[ "$save_config" == true ]]; then
    if [[ -f "$KIBANA_DEV_CONF" ]]; then
      # Update existing config file (portable sed: write to tmp then move)
      if grep -q "^OBLT_CLUSTER_NAME=" "$KIBANA_DEV_CONF" 2>/dev/null; then
        sed "s|^OBLT_CLUSTER_NAME=.*|OBLT_CLUSTER_NAME=\"$cluster_name\"|" "$KIBANA_DEV_CONF" > "$KIBANA_DEV_CONF.tmp" && mv "$KIBANA_DEV_CONF.tmp" "$KIBANA_DEV_CONF"
      elif grep -q "^# *OBLT_CLUSTER_NAME=" "$KIBANA_DEV_CONF" 2>/dev/null; then
        sed "s|^# *OBLT_CLUSTER_NAME=.*|OBLT_CLUSTER_NAME=\"$cluster_name\"|" "$KIBANA_DEV_CONF" > "$KIBANA_DEV_CONF.tmp" && mv "$KIBANA_DEV_CONF.tmp" "$KIBANA_DEV_CONF"
      else
        echo "" >> "$KIBANA_DEV_CONF"
        echo "# Remote ES (oblt-cli)" >> "$KIBANA_DEV_CONF"
        echo "OBLT_CLUSTER_NAME=\"$cluster_name\"" >> "$KIBANA_DEV_CONF"
      fi
    else
      # Create minimal config with just the cluster name
      echo "# ~/.kibana-dev.conf — generated by dev-start.sh renew" > "$KIBANA_DEV_CONF"
      echo "OBLT_CLUSTER_NAME=\"$cluster_name\"" >> "$KIBANA_DEV_CONF"
    fi
    echo "${GREEN}✓${NC} Saved cluster name to $KIBANA_DEV_CONF"
    echo "  Next time you can just run: ${GREEN}./dev-start.sh renew${NC}"
  fi

  # Regenerate kibana.dev.yml for any active remote sessions
  local regenerated=()

  # Check kibana-main
  if [[ -f "$KIBANA_MAIN_DIR/config/kibana.dev.yml" ]] && \
     grep -q "Remote ES" "$KIBANA_MAIN_DIR/config/kibana.dev.yml" 2>/dev/null; then
    local main_port
    main_port=$(grep -E "^ *port:" "$KIBANA_MAIN_DIR/config/kibana.dev.yml" 2>/dev/null | head -1 | awk '{print $2}')
    generate_remote_kibana_dev_yml "$KIBANA_MAIN_DIR" "${main_port:-$MAIN_KIBANA_PORT}"
    regenerated+=("kibana-main")
  fi

  # Check kibana-feat
  if [[ -f "$STATE_FILE" ]]; then
    source "$STATE_FILE"
    if [[ -n "${FEAT_DIR:-}" && -f "$FEAT_DIR/config/kibana.dev.yml" ]] && \
       grep -q "Remote ES" "$FEAT_DIR/config/kibana.dev.yml" 2>/dev/null; then
      local feat_port
      feat_port=$(grep -E "^ *port:" "$FEAT_DIR/config/kibana.dev.yml" 2>/dev/null | head -1 | awk '{print $2}')
      generate_remote_kibana_dev_yml "$FEAT_DIR" "${feat_port:-$FEAT_KIBANA_PORT}"
      regenerated+=("kibana-feat")
    fi
  fi

  # Check hotfix sessions
  for yml in "$WORKTREE_BASE"/*/config/kibana.dev.yml; do
    [[ -f "$yml" ]] || continue
    grep -q "Remote ES" "$yml" 2>/dev/null || continue
    local wt_dir wt_name wt_port
    wt_dir=$(dirname "$(dirname "$yml")")
    wt_name=$(basename "$wt_dir")
    # Skip feat worktree (already handled above)
    [[ -n "${FEAT_DIR:-}" && "$wt_dir" == "$FEAT_DIR" ]] && continue
    wt_port=$(grep -E "^ *port:" "$yml" 2>/dev/null | head -1 | awk '{print $2}')
    generate_remote_kibana_dev_yml "$wt_dir" "${wt_port}"
    regenerated+=("kibana-$wt_name")
  done

  if [[ ${#regenerated[@]} -gt 0 ]]; then
    echo ""
    echo "${GREEN}✓${NC} Regenerated kibana.dev.yml for remote sessions:"
    for s in "${regenerated[@]}"; do
      echo "  ${BLUE}↳${NC} $s"
    done
    echo ""
    echo "  Run ${GREEN}./dev-start.sh restart <session>${NC} to pick up the new credentials."
  fi

  echo ""
  echo "${GREEN}Done!${NC} Use ${GREEN}--remote${NC} to connect:"
  echo "  ${GREEN}./dev-start.sh switch <branch> --remote${NC}"
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
if [[ ! -f "$KIBANA_DEV_CONF" && "${1:-main}" != "setup" && "${1:-main}" != "renew" && "${1:-main}" != "restart" && "${1:-main}" != "help" && "${1:-}" != "--help" ]]; then
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
  restart)     cmd_restart "$2" ;;
  renew)       shift; cmd_renew "$@" ;;
  switch)      shift; cmd_switch "$@" ;;
  new)         shift; cmd_new "$@" ;;
  attach)      cmd_attach "$2" ;;
  list)        cmd_list ;;
  status)      cmd_status ;;
  sync)        cmd_sync "$2" ;;
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
