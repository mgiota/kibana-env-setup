# Recipe — Synthetics bulk "Manage maintenance windows"

Canonical interaction flow + selectors for the Maintenance Windows bulk-edit
feature (PR / branch `synthetics-bulk-edit-maintenance-windows`). This is the
single source of truth that both codified drivers encode:

- Track A (in-repo, durable): `test/scout/ui/tests/bulk_edit_maintenance_windows.spec.ts`
- Track B (workflow): `qa/scenarios/maintenance-windows.json` (run by `qa/qa-feature.mjs`)

Selectors were confirmed from the branch source
(`bulk_operations.tsx`, `bulk_maintenance_windows_flyout.tsx`,
`monitor_list.tsx`, `maintenance_windows.tsx`). Playwright MCP was not available
in this environment, so the flow was authored from source + a scripted Playwright
smoke run rather than an MCP browsing session; re-validate live with
`qa/qa-feature.mjs --headed` when the feat instance is up.

## Preconditions (data)

- Synthetics enabled; at least one **private location**.
- >= 2 `ui`-origin monitors (project/terraform monitors are skipped by the flyout).
- >= 1 **maintenance window** must exist, otherwise the flyout combobox has no
  options. Create via `POST /internal/alerting/rules/maintenance_window`
  (see `qa/seed-maintenance-windows.mjs`).

## Steps + selectors

| # | Action | Selector / locator | Screenshot |
|---|--------|--------------------|------------|
| 1 | Navigate to monitor management | `/app/synthetics/monitors`, wait for `syntheticsMonitorList-loaded` | — |
| 2 | Select all monitors | `data-test-subj="checkboxSelectAll"` (per-row: `checkboxSelectRow-<config_id>`) | `01-monitors-selected` |
| 3 | Open the Bulk actions menu | `data-test-subj="syntheticsBulkActionsButton"` (only rendered once rows are selected) | `02-bulk-menu-open` |
| 4 | Click "Manage maintenance windows" | `data-test-subj="syntheticsBulkMaintenanceWindowsItem"` | — |
| 5 | Flyout opens (Apply/Remove) | flyout `data-test-subj="syntheticsBulkMaintenanceWindowsFlyout"`; mode group `syntheticsBulkMaintenanceWindowsModeGroup` (default `apply`) | `03-flyout-empty` |
| 6 | Pick a maintenance window | the `EuiComboBox` inside the flyout (placeholder "Select maintenance windows"; no dedicated test-subj) — click `.euiComboBox` then the option by text | `04-flyout-filled` |
| 7 | Save | `data-test-subj="syntheticsBulkMaintenanceWindowsSave"` (disabled until a window is selected in `apply` mode) | — |
| 8 | Success toast | `.euiToast` (success) | `05-success-toast` |
| 9 | Table reloads | `syntheticsMonitorList-loaded` | `06-result-table` |

Cancel button: `data-test-subj="syntheticsBulkMaintenanceWindowsCancel"`.

## Notes / gotchas

- The bulk API only patches `ui`-origin monitors; the flyout shows a "will not be
  updated" callout listing skipped project/terraform monitors.
- In `apply` mode the flyout unions the selected windows with each monitor's
  existing set and only patches monitors whose set actually changes (no-op
  monitors are skipped server-side to avoid a Fleet re-sync).
- Mask timestamps (`last-run-time`, `monitorLastRunTime`) and charts (`.echChart`)
  before screenshotting for stable images.
