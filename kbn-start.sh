#!/usr/bin/env bash
# ============================================================
#  kbn-start.sh — Bootstrap + start ES, then auto-launch Kibana
#                 once ES is ready.
#
#  Called automatically by dev-start.sh. Run from the LEFT pane
#  of a servers window. Kibana fires in the RIGHT pane once ES
#  reports ready.
#
#  USAGE:
#    kbn-start.sh [data-folder] [-E key=value ...]
#                 [--kibana-port N] [--es-port N] [--host hostname]
#
#  EXAMPLES:
#    kbn-start.sh main-cluster --kibana-port 5602 --es-port 9201 --host kibana-main.local
#    kbn-start.sh feat-cluster --kibana-port 5601 --es-port 9200 --host kibana-feat.local
#    kbn-start.sh slo-crash    --kibana-port 5603 --es-port 9202
# ============================================================
set -euo pipefail

TRIGGER_STRING="succ kbn/es setup complete"

# ── DEFAULTS ──────────────────────────────────────────────
ES_DATA_FOLDER="main-cluster"
KIBANA_PORT=5601
ES_PORT=9200
KIBANA_HOST="localhost"
ES_FLAGS=""
# ── END DEFAULTS ──────────────────────────────────────────

# ── ARGUMENT PARSING ──────────────────────────────────────
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
        echo "Error: -E requires a value" >&2; exit 1
      fi
      ;;
    *)
      echo "Error: Unknown argument '$1'" >&2
      echo "Usage: kbn-start.sh [data-folder] [-E key=value ...] [--kibana-port N] [--es-port N] [--host hostname]" >&2
      exit 1
      ;;
  esac
done

ES_DATA_PATH="$HOME/Documents/Development/kibana/es_data/$ES_DATA_FOLDER"
LOGFILE="/tmp/es-${ES_DATA_FOLDER}.log"
ES_TRANSPORT_PORT=$((ES_PORT + 100))
# ── END ARGUMENT PARSING ──────────────────────────────────


# ── TMUX PANE DETECTION ───────────────────────────────────
TMUX_CURRENT_INDEX=$(tmux display-message -p '#{pane_index}')

TMUX_TARGET_PANE=$(tmux list-panes -F '#{pane_index} #{pane_id}' | awk -v current="$TMUX_CURRENT_INDEX" '
  $1 > current {
    if (target == "" || $1 < best) { target = $2; best = $1 }
  }
  END { if (target != "") print target }
')

if [[ -z "${TMUX_TARGET_PANE:-}" ]]; then
  TMUX_TARGET_PANE=$(tmux list-panes -F '#{pane_index} #{pane_id}' | awk -v current="$TMUX_CURRENT_INDEX" '
    $1 != current { print $2; exit }
  ')
fi

if [[ -z "${TMUX_TARGET_PANE:-}" ]]; then
  TMUX_TARGET_PANE=$(tmux display-message -p '#{pane_id}')
fi
# ── END TMUX PANE DETECTION ───────────────────────────────


echo ""
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │  kbn-start                                          │"
echo "  │  ES     → http://localhost:${ES_PORT}                    │"
echo "  │  Kibana → http://${KIBANA_HOST}:${KIBANA_PORT}           │"
echo "  │  Data   → ${ES_DATA_PATH}     │"
echo "  └─────────────────────────────────────────────────────┘"
echo ""

echo "▶ Switching node version..."
export NVM_DIR="$HOME/.nvm"
[[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"
nvm use

echo "▶ Running yarn kbn bootstrap..."
yarn kbn bootstrap

# ── Detect remote ES from kibana.dev.yml ──────────────────
KIBANA_DEV_YML="config/kibana.dev.yml"
USE_REMOTE_ES=false
if [[ -f "$KIBANA_DEV_YML" ]]; then
  # Match both formats:
  #   Template format:  elasticsearch.hosts:\n  - "http://..."
  #   oblt-cli format:  elasticsearch:\n  hosts: https://...
  ES_HOST_LINE=$(grep -E "^ *(- \"?|hosts: *)https?://" "$KIBANA_DEV_YML" 2>/dev/null \
    | grep -v "localhost" \
    | grep -v "127\.0\.0\.1" \
    | head -1 \
    | sed 's|^ *- *||; s|^ *hosts: *||' | tr -d '"' | tr -d ' ' || true)
  if [[ -n "$ES_HOST_LINE" ]]; then
    USE_REMOTE_ES=true
  fi
fi

if [[ "$USE_REMOTE_ES" == true ]]; then
  echo "▶ Remote ES detected: ${ES_HOST_LINE}"
  echo "  Skipping local ES — starting Kibana directly..."
  echo ""
  tmux send-keys -t "$TMUX_TARGET_PANE" \
    "export NVM_DIR=\"\$HOME/.nvm\" && [[ -s \"\$NVM_DIR/nvm.sh\" ]] && source \"\$NVM_DIR/nvm.sh\" && nvm use" \
    C-m
  sleep 2
  tmux send-keys -t "$TMUX_TARGET_PANE" \
    "yarn start --no-base-path --host=${KIBANA_HOST} --port=${KIBANA_PORT}" \
    C-m
  echo "✅  Kibana starting on http://${KIBANA_HOST}:${KIBANA_PORT} → ES: ${ES_HOST_LINE}"
  echo "    (ES host is configured in ${KIBANA_DEV_YML})"
else
  echo "▶ Starting local ES... (Kibana will auto-start once ES is ready)"
  (
    tail -n 0 -F "$LOGFILE" | while read -r line; do
      if [[ "$line" == *"$TRIGGER_STRING"* ]]; then
        tmux send-keys -t "$TMUX_TARGET_PANE" \
          "export NVM_DIR=\"\$HOME/.nvm\" && [[ -s \"\$NVM_DIR/nvm.sh\" ]] && source \"\$NVM_DIR/nvm.sh\" && nvm use" \
          C-m
        sleep 2
        tmux send-keys -t "$TMUX_TARGET_PANE" \
          "yarn start --no-base-path --host=${KIBANA_HOST} --port=${KIBANA_PORT} --elasticsearch.hosts=http://localhost:${ES_PORT}" \
          C-m
        break
      fi
    done
  ) &

  yarn es snapshot \
    --license trial \
    -E node.name="${ES_DATA_FOLDER}" \
    -E http.port="${ES_PORT}" \
    -E transport.port="${ES_TRANSPORT_PORT}" \
    -E discovery.type=single-node \
    -E path.data="${ES_DATA_PATH}" \
    ${ES_FLAGS} \
    2>&1 | tee -a "$LOGFILE"
fi
