# Kibana Dev Environment

A tmux + git worktrees setup that eliminates context-switching overhead, runs multiple Kibana instances simultaneously, and automates the full bootstrap → ES → Kibana startup sequence.

<a href="https://mgiota.github.io/kibana-env-setup/kibana-dev-workflow.html" target="_blank">📊 Visual workflow guide</a>

## What it does

- Creates two permanent tmux sessions: `kibana-main` (main branch) and `kibana-feat` (your active feature branch)
- Auto-runs `yarn kbn bootstrap`, starts ES, and launches Kibana once ES is ready — all from a single command. Supports both local ES and remote ES (oblt-cli / Elastic Cloud)
- Manages git worktrees so each session has its own isolated checkout
- Assigns ports automatically — `kibana-feat` always gets the default ports (5601/9200) so you never need to remember them
- Spins up temporary sessions for PR reviews or hotfixes alongside your active work

---

## Prerequisites

**Kibana repo** cloned on your machine — either the main repo or your own fork:
```bash
# elastic/kibana directly
git clone https://github.com/elastic/kibana.git ~/Documents/Development/kibana

# or your fork
git clone https://github.com/<your-username>/kibana.git ~/Documents/Development/kibana
```
> The path above matches the default in `dev-start.sh`. If you clone elsewhere, update `KIBANA_MAIN_DIR` in the script.

**tmux**
```bash
brew install tmux
```

Set up `~/.tmux.conf`. Here's a recommended config (feel free to customise):
```bash
unbind-key C-b
set -g prefix C-a          # prefix is Ctrl-a
bind-key C-a send-prefix
set -g mouse on
set -g mode-keys vi
bind r source-file ~/.tmux.conf \; display-message "Reloaded!"
bind | split-window -h
bind - split-window -v
bind -T copy-mode-vi v send -X begin-selection
bind -T copy-mode-vi y send -X copy-pipe-and-cancel "pbcopy"
bind -T copy-mode-vi MouseDragEnd1Pane send -X copy-pipe-and-cancel "pbcopy"
```

**nvm** — the scripts use `nvm use` to load the correct Node version from `.nvmrc`. Make sure nvm is installed and working.

**`~/bin` on your PATH** — add this to `~/.zshrc` if not already there:
```bash
export PATH="$HOME/bin:$PATH"
```

**`/etc/hosts`** — add these entries for the local hostnames:
```
127.0.0.1 kibana-main.local
127.0.0.1 kibana-feat.local
```

---

## One-time setup

**1. Clone the repo** somewhere convenient, e.g.:
```bash
git clone <repo-url> ~/Documents/Development/AI_projects/kibana-env-setup
```

**2. Update paths in `dev-start.sh`** — open the file and update the config block at the top to match your machine:
```bash
KIBANA_MAIN_DIR="$HOME/Documents/Development/kibana"   # path to your Kibana checkout
WORKTREE_BASE="$HOME/Documents/Development/worktrees"  # where worktrees will be created
```

**3. Set up symlinks** so the scripts are available from their expected locations:
```bash
mkdir -p ~/bin
ln -s ~/Documents/Development/AI_projects/kibana-env-setup/dev-start.sh ~/dev-start.sh
ln -s ~/Documents/Development/AI_projects/kibana-env-setup/kbn-start.sh ~/bin/kbn-start.sh
ln -s ~/Documents/Development/AI_projects/kibana-env-setup/run-checks.sh ~/bin/run-checks
ln -s ~/Documents/Development/AI_projects/kibana-env-setup/run-data.sh ~/bin/run-data
chmod +x ~/Documents/Development/AI_projects/kibana-env-setup/dev-start.sh
chmod +x ~/Documents/Development/AI_projects/kibana-env-setup/kbn-start.sh
chmod +x ~/Documents/Development/AI_projects/kibana-env-setup/run-checks.sh
chmod +x ~/Documents/Development/AI_projects/kibana-env-setup/run-data.sh
```

**4. Kibana config template**

`kibana.dev.yml.template` lives in this repo and is picked up automatically — no copying needed. When a session is created, the script generates a `config/kibana.dev.yml` in each worktree by replacing the `__KIBANA_PORT__` and `__ES_PORT__` placeholders with the correct values.

To customise defaults (credentials, Fleet config, remote ES, etc.), edit `kibana.dev.yml.template` in the repo directly.

> **Note on config regeneration:**
> - `switch` — preserves an existing `kibana.dev.yml` (so remote ES config is not overwritten). Delete the file and re-run `switch` to regenerate from the template.
> - `new` — if `kibana.dev.yml` already exists (e.g. from a previous run), it is left untouched and a warning is shown. Delete it and re-run if you want to regenerate from the template with fresh ports.
> - `dev-start.sh` (no args), `kibana-main` — only generates if the file doesn't exist. An existing config is always left untouched.
> - `dev-start.sh` (no args), `kibana-feat` — keeps the existing config if ports are correct. Regenerates automatically if ports are wrong.

**5. Switch to your first feature branch:**
```bash
~/dev-start.sh switch feature/your-branch
```

This creates the worktree, generates the config files, and sets up the `kibana-feat` session.

---

## Running

```bash
~/dev-start.sh
```

That's it for your morning start. It creates any missing sessions and attaches to `kibana-feat`. ES and Kibana start automatically.

---

## Commands

```bash
~/dev-start.sh                          # start/attach all sessions
~/dev-start.sh switch <branch>          # replace kibana-feat with a new branch
~/dev-start.sh new <branch>             # spin up a temporary session (PR review, hotfix)
~/dev-start.sh new <branch> --full      # temporary session with full layout (checks + ftr)
~/dev-start.sh kill <branch>            # kill session + remove worktree
~/dev-start.sh kill-all                 # kill all kibana-* sessions
~/dev-start.sh list                     # show sessions, worktrees, port assignments + warnings
~/dev-start.sh attach <branch>          # attach to an existing temporary session
~/dev-start.sh help                     # usage
```

### `switch` vs `new`

| Command | Use when |
|---|---|
| `switch <branch>` | Starting a new feature. Replaces `kibana-feat` — the new branch gets the default ports (5601/9200) automatically. |
| `new <branch>` | Need to run another branch alongside your current work — PR review, hotfix, testing a colleague's branch. |

Both commands auto-create the branch from `upstream/main` if it doesn't exist locally or on origin — no manual branch setup needed. For `switch`, the branch check happens before any session or worktree is torn down, so if it fails your current `kibana-feat` is left untouched.

---

## Port assignments

| Session | Kibana | ES | Host |
|---|---|---|---|
| `kibana-feat` | 5601 | 9200 | kibana-feat.local |
| `kibana-main` | 5602 | 9201 | kibana-main.local |
| `kibana-<branch>` | 5603+ (auto) | 9202+ (auto) | localhost |

`~/dev-start.sh list` shows current port assignments and warns if any `kibana.dev.yml` has mismatched ports.

---

## Session layout

Each session has the same window structure:

| # | Window | Panes |
|---|---|---|
| 0 | servers | left: ES + bootstrap · right: Kibana (auto-started). Detects remote ES and skips local ES. |
| 1 | cursor | left: cursor-agent · right: shell |
| 2 | scripts | left: `run-data synthetics` · right: `run-data slo` (pre-populated, press Enter to run) |
| 3 | git | single pane |
| 4 | editor | single pane |

Full sessions (`kibana-feat`, `kibana-main`, or `new --full`) also get:

| # | Window | Panes |
|---|---|---|
| 5 | checks | top-left: eslint · top-right: type check · bottom: jest |
| 6 | ftr | left: ftr server · right: ftr runner |

The `checks` window uses `run-checks.sh` — a helper script that scopes lint, type check, and jest to files/plugins changed on your branch (via `git merge-base HEAD upstream/main`). Press Enter in any pane to run that check.

---

## Daily workflow

**Morning:**
```bash
~/dev-start.sh
```

**Switch between sessions:**
```
Ctrl-a s  →  select kibana-main or kibana-feat
```

**Review a colleague's PR:**
```bash
~/dev-start.sh new feat/colleague-branch
# when done:
~/dev-start.sh kill colleague-branch
```

**Start a new feature:**
```bash
~/dev-start.sh switch feature/new-feature
```

**End of day:**
```
Ctrl-a d   # detach — sessions keep running
```

---

## Key tmux shortcuts

| Shortcut | Action |
|---|---|
| `Ctrl-a s` | Session switcher |
| `Ctrl-a w` | Window overview |
| `Ctrl-a d` | Detach |
| `Ctrl-a [` | Scroll / copy mode |
| `Ctrl-a 0-9` | Jump to window by number |
| `Ctrl-a \|` | Split pane vertically |
| `Ctrl-a -` | Split pane horizontally |

---

## Remote ES (oblt-cli / Elastic Cloud)

`kbn-start.sh` auto-detects when `kibana.dev.yml` points to a remote ES cluster and skips starting local ES. To use a remote cluster, edit `config/kibana.dev.yml` in your worktree. Both YAML formats are supported:

**Template format** (local ES):
```yaml
elasticsearch.hosts:
  - "http://localhost:9200"
elasticsearch.username: "kibana"
elasticsearch.password: "changeme"
```

**oblt-cli format** (remote ES):
```yaml
elasticsearch:
  hosts: https://my-cluster.elastic.co:443
  username: kibana_system_user
  password: <from oblt-cli>
```

When remote ES is detected, `kbn-start.sh` starts Kibana directly without running `yarn es snapshot`. The `switch` command preserves an existing `kibana.dev.yml`, so your remote config won't be overwritten.

---

## Data ingestion (run-data.sh)

The scripts window has pre-populated commands for data ingestion. Press Enter when Kibana is ready — the script waits automatically by polling `/api/status`.

```bash
run-data.sh slo          # ingest SLO fake_stack data via data_forge.js
run-data.sh synthetics   # create synthetics private location
```

`run-data.sh` reads ES host and credentials from `config/kibana.dev.yml` at runtime, so it works with both local and remote ES. For remote clusters, it automatically reduces concurrency and payload size to avoid timeouts. Data ingestion always uses the `elastic` superuser (same password as in the config) since service accounts like `kibana_system_user` lack write permissions on data indices.

**Synthetics and remote ES:** `run-data.sh synthetics` only runs on local ES. On remote ES (oblt-cli / Elastic Cloud), Elastic managed locations are already available in the Synthetics locations dropdown — no private location setup needed. The script detects this and shows an informational message instead of running.

---

## Branch-scoped checks (run-checks.sh)

The checks window runs lint, type check, and jest scoped to files and plugins changed on your branch (compared to `upstream/main` via `git merge-base`). Each check is in its own pane — press Enter to run.

```bash
run-checks.sh lint       # eslint on changed .ts/.tsx/.js files
run-checks.sh typecheck  # tsc per changed plugin
run-checks.sh jest       # jest per changed plugin
```

---

## Known behaviours & gotchas

- **Branch names with dots** (e.g. `9.3`) — tmux can't use dots in session names. The script converts them to hyphens: `kibana-9-3`. The worktree folder keeps the original name.
- **Sessions survive terminal close** — tmux keeps everything running. Only a machine reboot kills sessions.
- **`list` only shows active sessions** — dead sessions are filtered out of the port assignments table automatically.
- **Remote ES: `kibana_system_user` can't write data** — `run-data.sh` uses the `elastic` superuser automatically. If you get 401 errors, verify the `elastic` user has the same password as your config.
- **encryptedSavedObjects errors with remote ES** — expected. Alerts from a different Kibana instance were encrypted with a different key. Harmless — new rules you create locally work fine.
