# Recipe — Synthetics: maintenance windows shown in monitor details

Interaction flow + selectors for surfacing a monitor's **attached maintenance
windows** in the read-only monitor details panel (PR elastic/kibana#281853).
This is distinct from the bulk-edit flow (`maintenance-windows.md`): here we only
*view* the windows, we don't manage them.

- Driver: `qa/scenarios/maintenance-windows-details.json` (run by `qa/qa-feature.mjs`)
- Seed: `qa/seed-mw-details.mjs` (creates monitors **with** windows attached)

Selectors confirmed from branch source:
`common/components/monitor_details_panel.tsx` (the new `MAINTENANCE_WINDOWS_LABEL`
row + `MonitorMaintenanceWindows`), `monitor_list_table/monitor_details_link.tsx`
(`syntheticsMonitorDetailsLinkLink`), and
`overview/overview/monitor_detail_flyout.tsx` (`syntheticsFlyoutTab-details`).

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
| 1 | Monitor management list | `/app/synthetics/monitors`, wait `syntheticsMonitorList-loaded` | `00-monitor-list` |
| 2 | Open a monitor's details page | `[data-test-subj="syntheticsMonitorDetailsLinkLink"]:has-text("qa-mwd-monitor-1")` | — |
| 3 | Details panel shows the row | wait for text `Maintenance windows` | `01-monitor-details-page` |
| 4 | (optional) Overview flyout | `/app/synthetics` → click monitor card → tab `syntheticsFlyoutTab-details` | `02-flyout-details` |

The monitor detail page (`MONITOR_ROUTE = /monitor/:monitorId`) renders
`MonitorDetailsPanelContainer` → the shared `MonitorDetailsPanel`, so the row
appears in both the page and the overview flyout Details tab.

## Notes / gotchas

- The row renders only when `maintenance_windows` is non-empty — hence the seed
  attaches windows rather than just creating them.
- `MonitorMaintenanceWindows` resolves ids → titles via `useMaintenanceWindows()`
  and falls back to the raw id if a title can't be resolved (e.g. window deleted).
  PR #281853 (3rd commit) raised the `_find` `per_page` so >10 windows still
  resolve; with only 2 seeded windows the titles always resolve here.
- Mask timestamps (`last-run-time`, `monitorLastRunTime`) and charts (`.echChart`)
  for stable screenshots.
- The overview-flyout steps are best-effort (`optional`): the required assertion
  is the details **page** row, which uses stable `data-test-subj` selectors.
