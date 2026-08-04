# Recipe — fix Synthetics public-location sync errors

When Kibana logs recurring errors like:

```
[ERROR][plugins.synthetics] Error: certificate has expired
[ERROR][plugins.synthetics] AxiosError: Request failed with status code 401
```

the background **public Synthetics service sync** is failing — not the monitors UI itself.
Kibana pushes monitors assigned to Elastic-managed public locations (from
`manifest.synthetics.elastic.dev`) to external endpoints. If a location's TLS cert
expires or its service auth breaks, every sync cycle logs errors.

## Fix (integrated with run-data)

From a Kibana worktree (uses `config/kibana.dev.yml` for port and credentials):

```bash
# Preview what would change
DATA_USERNAME=admin DATA_PASSWORD='<admin-pw>' \
  run-data synthetics fix public-locations --dry-run

# Migrate + re-sync
DATA_USERNAME=admin DATA_PASSWORD='<admin-pw>' \
  run-data synthetics fix public-locations
```

On remote/oblt clusters, pass the superuser (`admin`) — same as other `run-data`
commands. The script probes locations using `xpack.uptime.service` credentials from
`~/.kibana-remote-es.yml`.

Direct invocation (e.g. from `qa/` with explicit `--base-url`) still works:

```bash
node qa/fix-broken-public-locations.mjs --base-url http://localhost:5602 --dry-run
```

## What it does

1. Fetches public locations from the manifest.
2. Probes each for TLS validity and service basic-auth.
3. Finds monitors still assigned to broken locations.
4. Removes broken locations and adds a healthy fallback (`us_central_qa` by default).
5. Bulk-resets migrated monitors so the next sync is clean.

## What it does *not* fix

This is a **cluster-data workaround** for your dev environment — not a Kibana code
change. The upstream infra issues (expired prod cert, broken staging auth) still need
Elastic to fix. After migration, avoid picking broken locations when creating monitors.

## Known broken locations (Aug 2026)

| Location | Endpoint | Issue |
|---|---|---|
| `us_central` | `us-central.synthetics.elastic.dev` | TLS cert expired Jul 12, 2026 |
| `us_central_staging` | `us-central1.synthetics.gcp.foundit.no` | Returns 401 even with valid basic auth |

`us_central_qa` is the usual fallback for oblt dev clusters.

## Why not in Kibana itself?

This is dev-environment repair for shared remote clusters — the same category as
`run-data synthetics fix agent-offline`, not product code. The Node module lives under
`qa/lib/` because it reuses the same Kibana API helpers as the seed scripts.
