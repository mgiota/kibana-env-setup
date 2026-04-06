# Kibana Pane Stuck After Restart

This is a known issue. When you run `restart`, the Kibana pane sometimes gets stuck because the previous process hasn't fully cleared out yet.

## What's likely happening

`kbn-start.sh` is trying to send `yarn start` to pane 1, but the old Kibana process (which takes about 30 seconds to shut down gracefully) is still dying in that pane. The new command gets lost, leaving the pane blank.

## Try this

Run the restart again:

```bash
~/dev-start.sh restart feat
```

The script handles port polling, force-killing stale processes, and pane cleanup automatically. This usually clears it right up.

## If it still gets stuck

1. Attach to the session:
   ```bash
   ~/dev-start.sh attach feat
   ```

2. In the tmux pane, press **Ctrl-a** followed by an arrow key to navigate to pane 1 (the Kibana pane)

3. Press **Ctrl-C** to kill any lingering process

4. Run the restart again:
   ```bash
   ~/dev-start.sh restart feat
   ```

(Don't run `yarn start` manually — it needs port flags that `kbn-start.sh` handles automatically)

## Verify everything is healthy

Once Kibana is running, check both services:

```bash
~/dev-start.sh status
```

This will ping ES and Kibana and confirm they're both up. Since ES is already running fine, Kibana should come right up.
