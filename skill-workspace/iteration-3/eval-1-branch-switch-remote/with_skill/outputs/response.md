# Switching to feature/slo-burnrate with Remote ES

Great! I'll help you switch to the `feature/slo-burnrate` branch and set up remote ES. Since you already have oblt-cli configured, this should be smooth.

Here's what I'll do:

## 1. Switch to the feature branch with remote ES

```bash
~/dev-start.sh switch feature/slo-burnrate --remote
```

This command will:
- Create or update the git worktree for `feature/slo-burnrate`
- Fetch fresh remote ES credentials from oblt-cli (auto-detects your cluster)
- Generate `config/kibana.dev.yml` with the remote ES connection
- Assign the kibana-feat session to your configured ports

## 2. Start the development environment

```bash
~/dev-start.sh
```

This will:
- Attach or create the kibana-main and kibana-feat sessions
- Skip local ES startup (since you're using remote ES)
- Start Kibana on your configured ports
- Set up the cursor, scripts, git, and editor windows

## 3. Verify everything is healthy

```bash
~/dev-start.sh status
```

This will ping your remote ES and Kibana to confirm they're running.

## Session Navigation

Once you're in tmux:
- **Ctrl-a s** — switch between sessions (kibana-main, kibana-feat, etc.)
- **Ctrl-a w** — view windows within the current session
- **Ctrl-a [** — scroll through pane output

Or attach from outside tmux anytime with:
```bash
~/dev-start.sh attach feat
```

## If credentials expire later

Remote ES credentials have an expiration. When that happens, simply run:

```bash
~/dev-start.sh renew
~/dev-start.sh restart feat
```

The `renew` command auto-detects your cluster from oblt-cli, fetches fresh credentials, and regenerates the config. Then restart to pick them up.

---

**Note:** All port assignments, ES hosts, and credentials are read automatically from your configured files (`~/.kibana-dev.conf` and `~/.kibana-remote-es.yml`). You're all set to start!
