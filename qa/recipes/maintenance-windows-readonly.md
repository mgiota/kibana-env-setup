# Recipe — Synthetics: read-only user sees maintenance windows on the overview

Interaction flow + selectors for the read-only maintenance-windows fix
(PR elastic/kibana#281894). This is distinct from:

- `maintenance-windows.md` — the bulk-edit *management* flow.
- `maintenance-windows-details.md` — viewing a monitor's attached windows **as an
  admin**.

Here the whole point is the **user role**: a Synthetics *read-only* user
(`uptime: ['read']`) who does **not** hold the standalone `read-maintenance-window`
privilege. Before the fix, the monitors overview called the alerting
`_active` / `_find` endpoints directly, got a `403`, and showed a
_"Failed to check if maintenance windows are active"_ toast; the active-MW banner
and the per-monitor state never rendered. The fix routes the read through a
Synthetics-owned internal endpoint (`GET /internal/synthetics/monitors/maintenance_windows`)
so read-only users are covered.

- Driver: `qa/scenarios/maintenance-windows-readonly.json` (run by `qa/qa-feature.mjs`)
- Seeds: `qa/seed-readonly-user.mjs` (role + user) then `qa/seed-mw-details.mjs`
  (monitors **with** windows attached)

## Why this needs its own scenario

Every other MW scenario authenticates as the superuser (`elastic` / the oblt
`admin`), who holds `read-maintenance-window` and therefore **never reproduces the
bug**. Run those as-is and `main` and the PR branch look identical. This scenario
logs the browser in as the seeded read-only user instead, so the difference is
visible.

## Preconditions (data)

- Synthetics enabled; at least one **private location**.
- >= 1 maintenance window, and >= 1 `ui`-origin monitor **with `maintenance_windows`
  attached** (so both the overview banner and the details row have something to
  show). `seed-mw-details.mjs` handles this.
- The read-only role + user must exist. `seed-readonly-user.mjs` creates:
  - role `qa_synthetics_read` → `{ kibana: [{ feature: { uptime: ['read'] }, spaces: ['*'] }] }`
  - user `qa-synthetics-readonly` / `qa-readonly-password`

## Auth model (important)

- **Browser session** (scenario `auth`) = the **read-only** user. Committed in the
  scenario JSON because it is a throwaway QA user.
- **Setup seeders** need **admin** creds to create the role/user/monitors. They are
  passed explicitly via `--user "$QA_ADMIN_USERNAME" --pass "$QA_ADMIN_PASSWORD"`
  in the scenario's `setup` commands, so export those before running:

```bash
export QA_ADMIN_USERNAME=admin
export QA_ADMIN_PASSWORD='<cluster admin password>'   # e.g. from config/kibana.dev.yml loginAssistanceMessage
```

`qa-feature.mjs` overwrites `QA_KIBANA_USERNAME/PASSWORD` with the scenario's
read-only auth for the browser login, but passes the rest of the environment
(including `QA_ADMIN_*`) through to the setup commands.

## Steps + selectors

| # | Action | Selector / locator | Screenshot |
|---|--------|--------------------|------------|
| 1 | Monitor management list | `/app/synthetics/monitors`, wait `syntheticsMonitorList-loaded` | `01-management-readonly` |
| 2 | (optional) catch the error toast | text `Failed to check if maintenance windows are active` | `02-error-toast-if-present` |
| 3 | Overview page | `/app/synthetics`, wait `syntheticsOverviewSearchInput` | — |
| 4 | Search for the monitor | fill `syntheticsOverviewSearchInput` = `qa-mwd-monitor-1` | — |
| 5 | Open its overview card | click `[data-test-subj="syntheticsOverviewGridItem"]:has-text("qa-mwd-monitor-1")` | — |
| 6 | Details flyout tab shows the row | click `syntheticsFlyoutTab-details`, wait text `Maintenance windows` | `03-flyout-details-mw-row` |

Steps 2 (the toast wait) and its screenshot are `optional: true`: on the **fixed**
(PR branch) run the toast never appears, so the run continues; on the **baseline**
(main / no-fix) run it appears and is captured.

## Running it (before/after)

Two scenarios — pick based on what you need:

| Scenario | Role | Use for |
|---|---|---|
| `maintenance-windows-readonly-minimal.json` | `uptime:read` only (Scout parity) | **Before/after MW error toast** comparison |
| `maintenance-windows-readonly-realistic.json` | `uptime:read` + `synthetics-*` ES read | **Clean UI** shots (management + overview flyout Details row) |

```bash
export QA_ADMIN_USERNAME=admin
export QA_ADMIN_PASSWORD='<from config/kibana.dev.yml loginAssistanceMessage>'

# Minimal — toast regression (fast, ~30s per instance)
node qa-feature.mjs --scenario scenarios/maintenance-windows-readonly-minimal.json \
                    --base-url http://localhost:5602   # before
node qa-feature.mjs --scenario scenarios/maintenance-windows-readonly-minimal.json \
                    --base-url http://localhost:5603   # after (PR branch)

# Realistic — hero screenshots (~1 min per instance)
node qa-feature.mjs --scenario scenarios/maintenance-windows-readonly-realistic.json \
                    --base-url http://localhost:5603
```

Expected difference:

| | Baseline (no fix) | Fixed (PR #281894) |
|---|---|---|
| Management page | "Failed to check…" error toast; **no** active-MW banner | no toast; active-MW banner renders |
| Details flyout row | titles fall back to raw ids (403 on `_find`) | `qa-mwd-window-1/2` titles resolve |
| Breakages | `403` on the alerting maintenance-window endpoints | none |

## Notes / gotchas

- The active-MW banner only shows while a seeded window is *running*. The seed's
  windows use `freq: 0, count: 1, duration: 1h` from `dtstart: now`, so they are
  active immediately after seeding — capture reasonably soon after `setup`.
- The details **page** (`/monitor/:id`) gates its panel on ping data
  (`isPingRelevant`); a freshly seeded monitor with no pings shows a skeleton there.
  We assert via the overview **flyout** Details tab, which renders straight from the
  saved object.
- All local sessions here share one remote CCS ES cluster, so the seeded role/user
  and monitors are visible to every instance; the idempotent seeders make re-running
  `setup` against each `--base-url` a no-op.
