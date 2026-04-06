# Kibana Pane Stuck After Restart

This is a known issue that happens when `kbn-start.sh` tries to send `yarn start` to pane 1, but the old Kibana process is still shutting down (Kibana's graceful shutdown can take up to 30 seconds). When this happens, the new command gets lost and pane 1 sits idle.

## Here's what to do:

**Run the restart command again:**
```bash
~/dev-start.sh restart feat
```

The `restart` command has built-in logic to handle this:
- It polls the ports to make sure they're fully released
- Force-kills any lingering processes
- Cleans up the pane before sending new commands

A second restart usually does the trick.

## If that doesn't work:

Attach to your session to manually check pane 1:
```bash
~/dev-start.sh attach feat
```

Once attached:
1. Press `Ctrl-a` followed by the right arrow to navigate to pane 1 (the Kibana pane)
2. Press `Ctrl-C` to clear any stuck process
3. Run `~/dev-start.sh restart feat` again

**Important:** Don't try to run `yarn start` manually — it needs port flags that `kbn-start.sh` handles automatically. Let `~/dev-start.sh restart feat` manage the startup.

Since ES is running fine, the issue is isolated to Kibana's startup on the restart. A fresh restart should get things moving again.
