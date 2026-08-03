# Recipe — Synthetics: maintenance windows shown in monitor details

Interaction flow + selectors for surfacing a monitor's **attached maintenance
windows** in the read-only monitor details panel (PR elastic/kibana#281853).
This is distinct from the bulk-edit flow (`maintenance-windows.md`): here we only
*view* the windows, we don't manage them.

- Driver: `qa/scenarios/maintenance-windows-details.json` (run by `qa/qa-feature.mjs`)
- Seed: `qa/seed-mw-details.mjs` (creates monitors **with** windows attached)

Selectors confirmed from branch source:
`common/components/monitor_details_panel.tsx` (the new `MAINTENANCE_WINDOWS_LABEL`
row + `MonitorMaintenanceWindows`), `overview/overview/overview_grid_item.tsx`
(`syntheticsOverviewGridItem`), and `overview/overview/monitor_detail_flyout.tsx`
(`syntheticsFlyoutTab-details`).

## Preconditions (data)

- Synthetics enabled; at least one **private location**.
- >= 1 maintenance window created (`POST /internal/alerting/rules/maintenance_window`).
- >= 1 `ui`-origin monitor **with `maintenance_windows` attached** — the row only
  renders when the monitor actually has windows. The seed attaches windows at
  monitor-create time via the public `POST /api/synthetics/monitors` body
  (`maintenance_windows: [ids]`).

## Steps + selectors

| # | Action | Selector / locator | Screenshot |
|---|--------|--------------------|------------|
| 1 | Monitor management list | `/app/synthetics/monitors`, wait `syntheticsMonitorList-loaded` | `00-management-active-mw-banner` |
| 2 | Overview page | `/app/synthetics`, wait `syntheticsOverviewSearchInput` | — |
| 3 | Search for the monitor | fill `syntheticsOverviewSearchInput` = `qa-mwd-monitor-1` | — |
| 4 | Open its overview card | click `[data-test-subj="syntheticsOverviewGridItem"]:has-text("qa-mwd-monitor-1")` | — |
| 5 | Details flyout tab shows the row | click `syntheticsFlyoutTab-details`, wait for text `Maintenance windows` | `01-flyout-details-mw-row` |

Both the monitor detail page (`MONITOR_ROUTE = /monitor/:monitorId` →
`MonitorDetailsPanelContainer`) and the overview flyout Details tab render the
same shared `MonitorDetailsPanel`. We assert via the **flyout Details tab**: the
detail *page* gates its panel on ping data (`isPingRelevant`), so a freshly
seeded monitor with no pings renders a skeleton there, whereas the flyout tab
renders straight from the saved object and shows the row immediately.

## Notes / gotchas

- The row renders only when `maintenance_windows` is non-empty — hence the seed
  attaches windows rather than just creating them.
- `MonitorMaintenanceWindows` resolves ids → titles via `useMaintenanceWindows()`
  and falls back to the raw id if a title can't be resolved (e.g. window deleted).
  PR #281853 (3rd commit) raised the `_find` `per_page` so >10 windows still
  resolve; with only 2 seeded windows the titles always resolve here.
- No masks are applied (`"masks": []`): the read-only details panel has no
  timestamps/charts in the captured region, so the screenshots stay stable
  without masking.
- The required assertion is the flyout Details tab row, reached through the
  overview search → grid-item → tab flow, all on stable `data-test-subj`
  selectors.
