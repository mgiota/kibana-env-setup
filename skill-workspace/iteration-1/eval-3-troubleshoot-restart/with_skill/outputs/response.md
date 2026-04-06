# Kibana Pane Not Starting After Restart

Based on what you're describing, this is a known issue with the `restart` command. Here's what's happening:

## The Problem

When you run `restart feat`, the command sends a restart signal to both panes in your Kibana session. However, pane 1 (where Kibana runs) may still have a dying Kibana process in the middle of its 30-second graceful shutdown. When `kbn-start.sh` tries to send the `yarn start` command to that pane via tmux, the command gets lost because the pane is still occupied by the old process.

This leaves the pane sitting idle—ES is fine in pane 0, but Kibana never actually starts in pane 1.

## The Solution

**Quick fix:** Go into pane 1 manually and restart Kibana:

1. Attach to your feat session: `tmux attach -t kibana-feat`
2. Navigate to pane 1 (the Kibana pane)
3. Press `Ctrl-C` to stop the old process
4. Run `yarn start` to start Kibana fresh

That should get Kibana running again within a few seconds.

## Why This Happens

The `restart` command is supposed to handle this automatically with port polling and force-kill logic, but edge cases can still slip through—particularly if the graceful shutdown is taking longer than expected or if there's a timing issue with how the command is sent to the pane.

## Prevention

For now, if you need a clean restart, the manual approach above is the most reliable. In the future, if this becomes frequent, you might also try killing the entire session and recreating it with `dev-start.sh new`, but that's more heavy-handed.
