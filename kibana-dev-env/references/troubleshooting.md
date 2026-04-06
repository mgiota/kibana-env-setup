# Troubleshooting

Common issues and their solutions when working with the Kibana dev environment.

## ES won't start

**Symptom:** ES hangs or fails to start in pane 0.

**Causes and fixes:**
- Port already in use: `lsof -ti :9200 | xargs kill -9` (replace with your ES port)
- Stale ES data: `~/dev-start.sh clean main` to wipe data and start fresh
- Wrong Node version: check `.nvmrc` and run `nvm use`
- ES data directory permissions: check `~/Documents/Development/es_data/` is writable

## Kibana pane is blank after restart

**Symptom:** After `restart`, ES starts but pane 1 (Kibana) doesn't run anything.

**Cause:** `kbn-start.sh` sends `yarn start` to pane 1 via `tmux send-keys`. If pane 1
still has a dying process (Kibana's 30-second graceful shutdown), the command gets lost.

**Fix:** Run `~/dev-start.sh restart feat` again — it handles port polling, force-kill,
and pane cleanup automatically. If it still happens, attach to the session with
`~/dev-start.sh attach feat`, navigate to pane 1 (Ctrl-a followed by arrow key), press
`Ctrl-C` to clear the old process. Note: don't just run `yarn start` manually — the
correct command includes port flags that `kbn-start.sh` sets automatically. Run
`~/dev-start.sh restart feat` instead.

## kibana_system_user can't write data

**Symptom:** 401 or 403 errors when ingesting data via `run-data.sh`.

**Cause:** The `kibana_system_user` account doesn't have write permissions on data indices.

**Fix:** `run-data.sh` automatically uses the `elastic` superuser. If you're running
ingestion manually, use `-u "elastic:changeme"` (local) or the elastic user password
from your remote config.

## Remote ES: connection refused

**Symptom:** Kibana can't connect to remote ES after `switch --remote`.

**Checks:**
1. Verify credentials are fresh: `~/dev-start.sh renew`
2. Check `~/.kibana-remote-es.yml` exists and has valid content
3. Check `config/kibana.dev.yml` has the remote URL (not localhost)
4. Verify the cluster is still running: `oblt-cli cluster list`

## Port mismatch warnings in `list`

**Symptom:** `list` shows port mismatch warnings.

**Cause:** `kibana.dev.yml` was manually edited or regenerated with different ports
than `~/.kibana-dev.conf` expects.

**Fix:** `~/dev-start.sh sync <session>` to regenerate from template, or manually
update the port in `config/kibana.dev.yml`.

## run-checks finds no changed files

**Symptom:** `run-checks lint` says "No changed files" even though you have changes.

**Cause:** `run-checks.sh` compares against `upstream/main` via `git merge-base`. If
your upstream remote isn't set up or hasn't been fetched recently, the comparison fails.

**Fix:** `git fetch upstream` before running checks. Make sure you have an `upstream`
remote pointing to the main Kibana repo.

## tmux sessions lost after reboot

**Symptom:** All sessions disappear after Mac restart.

**Cause:** tmux sessions are in-memory and don't survive reboots.

**Fix:** Re-run `~/dev-start.sh` to recreate sessions. Your worktrees and config files
are preserved on disk — only the tmux sessions need to be recreated. (tmux-resurrect
integration is on the roadmap.)

## oblt-cli: "not found" or auth errors

**Symptom:** `renew` fails with "oblt-cli not found" or Google Cloud auth errors.

**Fix:**
- Install oblt-cli: https://github.com/elastic/observability-test-environments
- Auth: `gcloud auth login` and `gcloud auth application-default login`
- Verify: `oblt-cli cluster list` should show your clusters
