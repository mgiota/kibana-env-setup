#!/usr/bin/env node
// ============================================================
//  seed-bulk-enable-disable.mjs — deterministic data for the
//  Synthetics "bulk enable/disable" feature-acceptance run.
//
//  Creates a mix that exercises the bulk-actions eligibility rules:
//    - Synthetics enabled
//    - a private location
//    - N ui-origin HTTP monitors (alternating enabled/disabled)
//    - M project-origin HTTP monitors (alternating enabled/disabled)
//
//  The project monitors are the interesting bit: the bulk menu must
//  exclude them from the enable/disable counts and surface them as
//  "skipped" in the confirm modal.
//
//  Idempotent-ish: ui monitors are matched by a name prefix; project
//  monitors use stable journey ids under a fixed project, so re-pushing
//  updates in place instead of duplicating.
//
//  USAGE:
//    node seed-bulk-enable-disable.mjs --base-url http://kibana-feat.local:5601
//    node seed-bulk-enable-disable.mjs --base-url ... --ui-monitors 4 --project-monitors 2
//    (auth defaults to elastic/changeme; override with --user/--pass)
// ============================================================

import { info, warn, err, ok } from './lib/kibana.mjs';
import {
  createApi,
  ensureEnabled,
  ensurePrivateLocation,
  listMonitors,
  createUiMonitor,
  pushProjectMonitors,
} from './lib/synthetics.mjs';

const NAME_PREFIX = 'qa-ed';
const PROJECT_NAME = 'qa-ed-project';

function parseArgs(argv) {
  const a = {
    baseUrl: 'http://kibana-feat.local:5601',
    user: 'elastic',
    pass: 'changeme',
    uiMonitors: 4,
    projectMonitors: 2,
  };
  for (let i = 2; i < argv.length; i++) {
    const t = argv[i];
    if (t === '--base-url') a.baseUrl = argv[++i];
    else if (t === '--user') a.user = argv[++i];
    else if (t === '--pass') a.pass = argv[++i];
    else if (t === '--ui-monitors') a.uiMonitors = Number(argv[++i]);
    else if (t === '--project-monitors') a.projectMonitors = Number(argv[++i]);
    else if (t === '--help' || t === '-h') {
      console.log(
        'seed-bulk-enable-disable --base-url URL [--ui-monitors N] [--project-monitors N] [--user U] [--pass P]'
      );
      process.exit(0);
    } else {
      err(`Unknown arg: ${t}`);
      process.exit(2);
    }
  }
  return a;
}

async function ensureUiMonitors(request, location, count) {
  const existing = await listMonitors(request, NAME_PREFIX);
  if (existing.length >= count) {
    ok(`${existing.length} qa ui monitors already present`);
    return existing;
  }
  for (let i = existing.length; i < count; i++) {
    await createUiMonitor(request, {
      name: `${NAME_PREFIX}-ui-${i + 1}`,
      url: `https://example.com/${i + 1}`,
      locationId: location.id,
      // Alternate so there's always something to both enable and disable.
      enabled: i % 2 === 0,
    });
  }
  return listMonitors(request, NAME_PREFIX);
}

function buildProjectMonitors(location, count) {
  const monitors = [];
  for (let i = 0; i < count; i++) {
    monitors.push({
      type: 'http',
      id: `${NAME_PREFIX}-project-${i + 1}`,
      name: `${NAME_PREFIX}-project-${i + 1}`,
      urls: ['https://elastic.co'],
      schedule: 10,
      enabled: i % 2 === 0,
      locations: [],
      privateLocations: [location.label],
      hash: `qa-ed-hash-${i + 1}`,
    });
  }
  return monitors;
}

async function main() {
  const args = parseArgs(process.argv);
  const auth = { username: args.user, password: args.pass };
  const request = createApi(args.baseUrl, auth);

  info(`Seeding ${args.baseUrl} (ui=${args.uiMonitors}, project=${args.projectMonitors})`);

  try {
    await ensureEnabled(request);
  } catch (e) {
    warn(`enablement call failed (may already be enabled): ${e.message}`);
  }

  const location = await ensurePrivateLocation(request, NAME_PREFIX);
  const uiMonitors = await ensureUiMonitors(request, location, args.uiMonitors);
  const projectMonitors = await pushProjectMonitors(
    request,
    PROJECT_NAME,
    buildProjectMonitors(location, args.projectMonitors)
  );

  ok(`Done. ${uiMonitors.length} ui monitors, ${projectMonitors.length} project monitors ready.`);
}

main().catch((e) => {
  err(e.stack || e.message || String(e));
  process.exit(1);
});
