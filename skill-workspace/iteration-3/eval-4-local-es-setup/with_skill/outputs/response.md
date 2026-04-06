# Starting Fresh with Local ES on main Branch

I'll walk you through setting up a complete local Elasticsearch + Kibana environment from scratch on your main branch.

## Step 1: Clean any stale data

If you want a truly fresh start, wipe the existing ES data first:

```bash
~/dev-start.sh clean main
```

This removes the ES data folder for the main branch, ensuring a completely clean slate.

## Step 2: Start everything with dev-start.sh

```bash
~/dev-start.sh
```

That's it. The script handles everything automatically:
- Creates/attaches tmux sessions for both kibana-main and kibana-feat
- Switches to the correct Node version via `nvm use` (reads `.nvmrc`)
- Starts Elasticsearch via `yarn es snapshot` in pane 0
- Waits for ES to be ready, then starts Kibana with the correct port flags in pane 1
- Generates `config/kibana.dev.yml` from the template
- Sets up all panes: servers, cursor (with KIBANA_URL), scripts, git, editor

Port assignments and paths are auto-detected from `~/.kibana-dev.conf`. Default ports for main: Kibana 5602, ES 9201.

## Step 3: Verify everything is running

```bash
~/dev-start.sh status
```

Expected output:
```
kibana-main:
  ES (localhost:9201): up
  Kibana (localhost:5602): up
```

## Step 4: Access Kibana

Your local Kibana is now running at `http://localhost:5602` (or whatever port is configured in `~/.kibana-dev.conf`).

Default credentials (local ES): `elastic` / `changeme`

## Session navigation

Once inside tmux:
- **Ctrl-a s** — switch between sessions (kibana-main, kibana-feat)
- **Ctrl-a w** — view windows within the current session
- **Ctrl-a [arrow]** — move between panes

Or attach from outside tmux:
```bash
~/dev-start.sh attach main
```

## Next steps

- **Ingest test data**: The `scripts` window has ready-to-run data ingestion commands
- **Switch to a feature branch**: `~/dev-start.sh switch feature/my-branch`
- **Run code quality checks**: `run-checks lint`, `run-checks typecheck`, `run-checks jest`

## Troubleshooting

If Elasticsearch won't start:
1. Check the port isn't in use: `lsof -ti :9201`
2. Run `~/dev-start.sh clean main` to remove stale data

If Kibana pane is blank after restart:
- Run `~/dev-start.sh restart main` — it handles process cleanup and port polling automatically
- Don't run `yarn start` manually — the script sets the correct port flags

For more help, see `references/troubleshooting.md`.
