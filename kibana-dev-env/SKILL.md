---
name: kibana-dev-env
description: >
  Kibana local development environment manager — tmux sessions, git worktrees,
  ES + Kibana lifecycle, remote ES credentials, scoped checks, and data ingestion.
  Use this skill whenever the developer mentions: starting Kibana, switching branches,
  managing worktrees, running ES locally or remotely, creating SLOs, setting up
  synthetics private locations, ingesting test data, running scoped lint/typecheck/jest,
  checking session health, or anything related to their local Kibana dev workflow.
  Also trigger when the developer asks about ports, tmux sessions, kibana.dev.yml,
  remote ES configuration, oblt-cli credentials, or bootstrapping their environment.
---

# Kibana Dev Environment

This skill manages a tmux-based Kibana development environment that supports multiple
concurrent branches via git worktrees, each with isolated ES + Kibana instances on
separate ports. It handles the full lifecycle: session creation, branch switching,
server restart, credential renewal, health checks, data ingestion, and scoped code
quality checks.

## Important: always use `dev-start.sh`

Never suggest raw tmux commands (`tmux attach`, `tmux send-keys`, etc.) to the
developer. Always use the `dev-start.sh` CLI — it wraps all tmux operations and
handles port assignments, config generation, and process lifecycle automatically.
Similarly, `kbn-start.sh` handles `yarn start` with the correct port arguments —
never suggest running `yarn start` directly without port flags.

`kbn-start.sh` also handles Node version switching (`nvm use`) automatically before
starting ES or Kibana. Never tell the developer to run `nvm use` manually — the
scripts take care of it.

## Important: never hardcode paths

Always refer to paths using their config variable names (`KIBANA_MAIN_DIR`,
`WORKTREE_BASE`, etc.) from `~/.kibana-dev.conf`. Never hardcode paths like
`~/Documents/Development/kibana` in responses — the developer's paths may differ.

## Important: auto-detect, don't ask

When the developer asks to create resources (SLOs, private locations, etc.) or
interact with a running Kibana, read `config/kibana.dev.yml` and `~/.kibana-dev.conf`
automatically to get ports, credentials, and ES host. Don't ask the developer to
look these up — the config files have everything.

## Architecture

```
dev-start.sh (CLI router)
  ├── kbn-start.sh    (bootstrap ES + Kibana in tmux panes)
  ├── run-checks.sh   (scoped lint / typecheck / jest)
  └── run-data.sh     (SLO + synthetics data ingestion)
```

All scripts share config from `~/.kibana-dev.conf` (paths, ports, cluster name)
and per-worktree `config/kibana.dev.yml` (ES connection, Kibana settings).

### Session structure

Each tmux session has these windows:

| Window    | Purpose                                    |
|-----------|--------------------------------------------|
| servers   | Pane 0: ES (or kbn-start.sh), Pane 1: Kibana (`yarn start` with port flags) |
| cursor    | IDE MCP config, KIBANA_URL set              |
| scripts   | Pre-populated data ingestion commands       |
| git       | Git operations, branch management           |
| editor    | File editing                                |
| checks    | Lint / typecheck / jest (full sessions)     |
| ftr       | Functional test runner (full sessions)      |

Lightweight sessions (created with `new`) have: servers, cursor, scripts, git, editor.

### Port assignments

Ports are configurable in `~/.kibana-dev.conf`. The defaults are:

- **kibana-feat**: Kibana 5601, ES 9200 (the "primary" ports — feat is the active dev session)
- **kibana-main**: Kibana 5602, ES 9201 (secondary, for main branch)
- **Hotfix sessions**: auto-assigned starting from 5603/9202

Always read `~/.kibana-dev.conf` or `config/kibana.dev.yml` for the actual ports
rather than assuming defaults — the developer may have customized them.

## Commands

Run all commands as `~/dev-start.sh <command>`:

### Sessions
| Command | What it does |
|---------|-------------|
| *(no args)* | Start/attach kibana-main + kibana-feat |
| `switch <branch> [--remote]` | Switch kibana-feat to a branch |
| `new <branch> [--full] [--remote]` | Create worktree + hotfix session |
| `attach <branch>` | Attach to an existing session |
| `kill <branch>` | Kill session + remove worktree |
| `kill-all` | Kill ALL kibana-* sessions |

### Operations
| Command | What it does |
|---------|-------------|
| `restart <main\|feat\|branch>` | Restart ES + Kibana (handles graceful shutdown) |
| `renew [--cluster-name <n>] [--save]` | Refresh remote ES credentials (auto-detects cluster from oblt-cli) |
| `sync [main\|feat\|branch\|all]` | Regenerate kibana.dev.yml from template |
| `clean [main\|feat\|name\|all]` | List or delete ES data folders |

### Info
| Command | What it does |
|---------|-------------|
| `list` | Sessions, worktrees & port assignments |
| `status` | Health check — ping ES + Kibana |
| `setup` | Interactive config wizard |

### Navigating sessions

To switch between sessions and windows, the developer uses tmux shortcuts:
- **Ctrl-a s** — session switcher (pick kibana-main, kibana-feat, etc.)
- **Ctrl-a w** — window overview within a session

To attach to a session from outside tmux: `~/dev-start.sh attach feat`

## Local vs Remote ES

**Local ES** — `kbn-start.sh` runs `yarn es snapshot` in pane 0, watches for the
trigger string `"succ kbn/es setup complete"`, then sends `yarn start` (with correct
port arguments) to pane 1.

**Remote ES** — When `--remote` is passed, `dev-start.sh` generates `kibana.dev.yml`
using credentials from `~/.kibana-remote-es.yml` (fetched via `oblt-cli` or pasted
manually). `kbn-start.sh` detects the remote URL and skips local ES startup.

### Credential renewal flow

When remote ES credentials expire:

```bash
~/dev-start.sh renew              # auto-detects cluster, fetches fresh creds
~/dev-start.sh restart feat       # restart to pick up new credentials
```

`renew` auto-detects the cluster name from `oblt-cli cluster list`, fetches
credentials via `oblt-cli cluster secrets kibana-config`, writes to
`~/.kibana-remote-es.yml`, and regenerates `kibana.dev.yml` for active remote
sessions if credentials changed.

## Data Ingestion

`run-data` must be run from within a Kibana repo directory. Auto-detect the correct
directory from `~/.kibana-dev.conf` (KIBANA_MAIN_DIR or WORKTREE_BASE) — don't tell
the developer to navigate there manually.

```bash
run-data slo          # Ingest SLO fake_stack data via data_forge.js
run-data synthetics   # Create synthetics private location (local ES only)
```

`run-data.sh` reads ES host and credentials from `config/kibana.dev.yml`,
waits for Kibana readiness via `/api/status`, and uses the `elastic` superuser
(not `kibana_system_user`, which lacks write permissions).

For remote ES, it auto-reduces concurrency (payload 1000, concurrency 1,
events-per-cycle 10) to avoid timeouts.

### Data generated by `run-data slo`

The `slo` command uses `kbn-data-forge` (`x-pack/scripts/data_forge.js`) with the
`fake_stack` dataset and `good` event template. This generates data in the
`high-volume-metrics` index with fields like `http.response.status_code`,
`service.name`, etc.

### Creating SLOs

Data ingestion must happen **before** creating SLOs — there must be data in the
target index first. The standard workflow is:

1. Run `run-data slo` to ingest fake_stack data
2. Create an SLO via the Kibana API (see `references/kibana-api.md`)

When creating SLOs on data_forge data, ALWAYS use the **Admin Console Availability** pattern:
- **Indicator type**: `sli.kql.custom` (NOT `sli.apm.transactionDuration`)
- **Good query**: `http.response.status_code < 500`
- **Total query**: `http.response.status_code : *`
- **Index**: `high-volume-metrics` (NOT `metrics-apm*`)

This measures availability (% of non-5xx responses). This is the only SLO type that
works with kbn-data-forge fake_stack data. Do NOT use APM latency indicators
(`sli.apm.transactionDuration`) — the fake_stack dataset does not generate APM data,
so APM-based SLOs will have no matching data and will fail silently.

### Kibana API operations

For creating SLOs, private locations, or other resources via the Kibana API,
read `references/kibana-api.md` for endpoint details, required headers, and
example request bodies. When making API calls:

1. Read `config/kibana.dev.yml` to get the Kibana port and ES credentials
2. Verify Kibana is ready with `~/dev-start.sh status`
3. Use the `elastic` superuser for authentication
4. Always include `kbn-xsrf: true` header

## Code Quality Checks

```bash
run-checks lint       # ESLint on changed files (vs upstream/main)
run-checks typecheck  # TypeScript check on changed plugins
run-checks jest       # Unit tests on changed plugins
```

`run-checks.sh` uses `git merge-base` to scope checks to only the files and
plugins you've actually changed on your branch. It handles both committed and
untracked files.

## Configuration

### ~/.kibana-dev.conf

User-specific paths and ports. Created by `setup` wizard. Uses `${VAR:-default}`
pattern so every value is overridable:

```bash
KIBANA_MAIN_DIR="$HOME/Documents/Development/kibana"
WORKTREE_BASE="$HOME/Documents/Development/worktrees"
ES_DATA_BASE="$HOME/Documents/Development/es_data"
MAIN_KIBANA_PORT="5602"
MAIN_ES_PORT="9201"
FEAT_KIBANA_PORT="5601"
FEAT_ES_PORT="9200"
OBLT_CLUSTER_NAME="my-cluster"   # optional, for renew auto-detect
```

### config/kibana.dev.yml

Per-worktree Kibana config. Generated from `kibana.dev.yml.template` (local ES)
or from `~/.kibana-remote-es.yml` (remote ES). Contains server port, ES hosts,
and any custom Kibana settings (logging, feature flags, etc.).

## Troubleshooting

For common issues and their solutions, read `references/troubleshooting.md`.

Key principle: always suggest `dev-start.sh` commands for fixes, not raw tmux
commands or manual `yarn start`. The scripts handle port assignments and process
management automatically.

## First-time setup

```bash
~/dev-start.sh setup                    # config wizard: paths, ports, symlinks
~/dev-start.sh switch feature/my-branch # set your first feature branch
~/dev-start.sh                          # start everything
```
