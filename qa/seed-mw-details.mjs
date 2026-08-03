#!/usr/bin/env node
// ============================================================
//  seed-mw-details.mjs — deterministic data for the Synthetics
//  "maintenance windows shown in monitor details" feature (PR
//  elastic/kibana#281853).
//
//  Unlike seed-maintenance-windows.mjs (which only ensures windows
//  EXIST so the bulk-edit flyout has options), this ATTACHES windows
//  to the monitors at creation time, so the read-only monitor
//  details panel actually renders the new "Maintenance windows" row.
//
//  Ensures the target Kibana has:
//    - Synthetics enabled
//    - a private location
//    - a couple of maintenance windows
//    - ui-origin HTTP monitors with those windows attached
//
//  Idempotent-ish: monitors/windows are matched by a name prefix and
//  only created when missing.
//
//  USAGE:
//    node seed-mw-details.mjs --base-url http://localhost:5611
//    node seed-mw-details.mjs --base-url ... --monitors 2 --windows 2
//    (auth defaults to elastic/changeme; override with --user/--pass
//     or QA_BASE_URL / QA_KIBANA_USERNAME / QA_KIBANA_PASSWORD env so
//     it can run as a qa-feature.mjs `setup` step)
// ============================================================

import { info, warn, err, ok } from './lib/kibana.mjs';
import {
  createApi,
  ensureEnabled,
  ensurePrivateLocation,
  ensureUiMonitors,
} from './lib/synthetics.mjs';
import { ensureMaintenanceWindows } from './lib/maintenance_windows.mjs';

const NAME_PREFIX = 'qa-mwd';

function parseArgs(argv) {
  const a = {
    baseUrl: process.env.QA_BASE_URL || 'http://localhost:5611',
    user: process.env.QA_KIBANA_USERNAME || 'elastic',
    pass: process.env.QA_KIBANA_PASSWORD || 'changeme',
    monitors: 2,
    windows: 2,
  };
  for (let i = 2; i < argv.length; i++) {
    const t = argv[i];
    if (t === '--base-url') a.baseUrl = argv[++i];
    else if (t === '--user') a.user = argv[++i];
    else if (t === '--pass') a.pass = argv[++i];
    else if (t === '--monitors') a.monitors = Number(argv[++i]);
    else if (t === '--windows') a.windows = Number(argv[++i]);
    else if (t === '--help' || t === '-h') {
      console.log(
        'seed-mw-details --base-url URL [--monitors N] [--windows N] [--user U] [--pass P]'
      );
      process.exit(0);
    } else {
      err(`Unknown arg: ${t}`);
      process.exit(2);
    }
  }
  return a;
}

async function main() {
  const args = parseArgs(process.argv);
  const auth = { username: args.user, password: args.pass };
  const request = createApi(args.baseUrl, auth);

  info(`Seeding ${args.baseUrl} (monitors=${args.monitors}, windows=${args.windows}, attach=on)`);

  try {
    await ensureEnabled(request);
  } catch (e) {
    warn(`enablement call failed (may already be enabled): ${e.message}`);
  }

  const location = await ensurePrivateLocation(request, NAME_PREFIX);
  const windows = await ensureMaintenanceWindows(request, {
    count: args.windows,
    prefix: NAME_PREFIX,
  });
  const mwIds = windows.map((w) => w.id);
  if (!mwIds.length) {
    err('no maintenance windows available to attach — aborting');
    process.exit(1);
  }
  const monitors = await ensureUiMonitors(request, {
    location,
    count: args.monitors,
    namePrefix: NAME_PREFIX,
    maintenanceWindows: mwIds,
  });

  ok(
    `Done. ${monitors.length} monitors with ${mwIds.length} maintenance window(s) attached ` +
      `(${windows.map((w) => w.title).join(', ')}).`
  );
}

main().catch((e) => {
  err(e.stack || e.message || String(e));
  process.exit(1);
});
