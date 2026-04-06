# Switching to feature/slo-burnrate with Remote ES

Perfect! Since you already have oblt-cli configured, here's how to set up your new branch with remote ES:

## Step 1: Switch to the branch with remote ES

```bash
~/dev-start.sh switch feature/slo-burnrate --remote
```

This command will:
- Create a git worktree for `feature/slo-burnrate`
- Fetch your remote ES credentials from `oblt-cli` (auto-detecting your cluster)
- Generate `config/kibana.dev.yml` with the remote ES connection
- Set up the tmux session `kibana-feat` on your configured ports

## Step 2: Verify the setup

Once the session is running, check that everything is healthy:

```bash
~/dev-start.sh status
```

This will ping both ES and Kibana to confirm:
- Remote ES is reachable
- Kibana is running and responding
- Your credentials are valid

## Step 3: Access Kibana

Your Kibana instance will be available on the port configured in `~/.kibana-dev.conf`. The typical default for the `feat` session is port 5601, but always check the actual port from your config.

## Need to switch between sessions?

While you're working, you can switch between your feature branch and main using:
- **Ctrl-a s** — tmux session switcher (pick kibana-feat or kibana-main)
- **Ctrl-a w** — window overview within the current session

Or attach from outside tmux with:
```bash
~/dev-start.sh attach feat
```

## Credential renewal

If your remote ES credentials expire while working, renew them with:

```bash
~/dev-start.sh renew
~/dev-start.sh restart feat
```

The `renew` command will auto-detect your cluster from oblt-cli, fetch fresh credentials, and `restart` will pick them up.

---

You're all set! Your feature branch is now running with remote ES, and you can start developing.
