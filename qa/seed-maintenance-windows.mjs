#!/usr/bin/env node
// ============================================================
//  seed-maintenance-windows.mjs — deterministic data for the
//  Synthetics "Manage maintenance windows" feature-acceptance run.
//
//  Ensures the target Kibana has what the flyout needs:
//    - Synthetics enabled
//    - a private location
//    - a few ui-origin HTTP monitors on that location
//    - a couple of maintenance windows (so the flyout combobox
//      actually has options to pick)
//
//  Idempotent-ish: monitors/windows are matched by a name prefix
//  and only created when missing.
//
//  USAGE:
//    node seed-maintenance-windows.mjs --base-url http://kibana-feat.local:5601
//    node seed-maintenance-windows.mjs --base-url ... --monitors 4 --windows 2
//    (auth defaults to elastic/changeme; override with --user/--pass)
// ============================================================

import { info, warn, err, ok } from './lib/kibana.mjs';
import {
  createApi,
  ensureEnabled,
  ensurePrivateLocation,
  ensureUiMonitors,
} from './lib/synthetics.mjs';
import { ensureMaintenanceWindows } from './lib/maintenance_windows.mjs';

const NAME_PREFIX = 'qa-mw';

function parseArgs(argv) {
  const a = {
    baseUrl: 'http://kibana-feat.local:5601',
    user: 'elastic',
    pass: 'changeme',
    monitors: 3,
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
        'seed-maintenance-windows --base-url URL [--monitors N] [--windows N] [--user U] [--pass P]'
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

  info(`Seeding ${args.baseUrl} (monitors=${args.monitors}, windows=${args.windows})`);

  try {
    await ensureEnabled(request);
  } catch (e) {
    warn(`enablement call failed (may already be enabled): ${e.message}`);
  }

  const location = await ensurePrivateLocation(request, NAME_PREFIX);
  const monitors = await ensureUiMonitors(request, {
    location,
    count: args.monitors,
    namePrefix: NAME_PREFIX,
  });
  const windows = await ensureMaintenanceWindows(request, {
    count: args.windows,
    prefix: NAME_PREFIX,
  });

  ok(`Done. ${monitors.length} monitors, ${windows.length} maintenance windows ready.`);
}

main().catch((e) => {
  err(e.stack || e.message || String(e));
  process.exit(1);
});
