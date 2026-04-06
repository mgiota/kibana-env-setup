# Switching to feature/slo-burnrate with Remote ES

Great! I'll help you switch to the **feature/slo-burnrate** branch with remote ES support. Since you already have oblt-cli configured, the process is straightforward.

## Step-by-step commands

### 1. Switch to the new branch with remote ES enabled

```bash
~/dev-start.sh switch feature/slo-burnrate --remote
```

This command will:
- Create a git worktree for `feature/slo-burnrate` (in your configured `$WORKTREE_BASE`)
- Assign it to the **kibana-feat** tmux session (Kibana on 5602, ES on 9202 by default)
- Fetch remote ES credentials via `oblt-cli` and store them in `~/.kibana-remote-es.yml`
- Generate `config/kibana.dev.yml` with your remote ES connection details
- Skip local ES startup (since you're using remote ES)

### 2. Start your environment

```bash
~/dev-start.sh
```

This will:
- Attach to (or start) the **kibana-main** and **kibana-feat** sessions
- Launch Kibana on port 5602 connected to your remote ES cluster
- Set up the tmux layout with servers, cursor, scripts, git, and editor windows

### 3. Monitor the startup

Check the tmux session to ensure Kibana connects successfully:

```bash
tmux attach-session -t kibana-feat
```

Watch the Kibana pane (pane 1) for the message: `"Server running at http://localhost:5602"`

## If your remote credentials expire

Since remote ES credentials can expire, when that happens just run:

```bash
~/dev-start.sh renew
```

This will:
- Auto-detect your cluster name from oblt-cli
- Fetch fresh credentials
- Regenerate `kibana.dev.yml` with the new credentials

Then restart to pick them up:

```bash
~/dev-start.sh restart feat
```

## Ready to work

Once Kibana is running, you'll have:
- **Kibana URL:** `http://localhost:5602`
- **Remote ES:** connected via the credentials fetched from oblt-cli
- **Git worktree:** isolated at `$WORKTREE_BASE/feature/slo-burnrate`
- **All tmux windows set up:** servers, cursor, scripts, git, editor

You can now start working on your SLO burn rate feature!
