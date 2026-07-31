#!/usr/bin/env node
// ============================================================
//  seed-local-monitors.mjs — deterministic "Local monitors" for
//  the group-by-monitor-source scenario (and any test that needs
//  a non-empty Local bucket).
//
//  Idempotent: ensures synthetics is enabled, a private location
//  exists, and N ui-origin HTTP monitors are present (by name).
//  Re-running is a no-op once they exist.
//
//  Auth/target default to the env the qa-feature `setup` hook sets
//  (QA_BASE_URL / QA_KIBANA_USERNAME / QA_KIBANA_PASSWORD) so it can
//  run with no flags; override with --base-url / --user / --pass.
//
//  USAGE:
//    node seed-local-monitors.mjs --base-url http://localhost:5602
//    node seed-local-monitors.mjs --count 3 --user admin --pass ...
// ============================================================

import { info, err, ok } from './lib/kibana.mjs';
import {
  createApi,
  ensureEnabled,
  ensurePrivateLocation,
  listMonitors,
  createUiMonitor,
} from './lib/synthetics.mjs';

const NAME_PREFIX = 'qa-local';

function parseArgs(argv) {
  const a = {
    baseUrl: process.env.QA_BASE_URL || 'http://localhost:5602',
    user: process.env.QA_KIBANA_USERNAME || 'elastic',
    pass: process.env.QA_KIBANA_PASSWORD || 'changeme',
    count: 2,
    // Isolate seeded monitors in a dedicated space so they never pollute the
    // real monitor list — wiping = deleting the space. Use 'default' to opt out.
    space: 'qa',
  };
  for (let i = 2; i < argv.length; i++) {
    const t = argv[i];
    if (t === '--base-url') a.baseUrl = argv[++i];
    else if (t === '--user') a.user = argv[++i];
    else if (t === '--pass') a.pass = argv[++i];
    else if (t === '--count') a.count = Number(argv[++i]);
    else if (t === '--space') a.space = argv[++i];
    else if (t === '--help' || t === '-h') {
      console.log('seed-local-monitors --base-url URL [--count N] [--space ID] [--user U] [--pass P]');
      process.exit(0);
    } else {
      err(`Unknown arg: ${t}`);
      process.exit(2);
    }
  }
  return a;
}

async function ensureSpace(rootRequest, spaceId) {
  const existing = await rootRequest(`/api/spaces/space/${spaceId}`).catch(() => undefined);
  if (existing?.id) {
    ok(`space "${spaceId}" already exists`);
    return;
  }
  await rootRequest('/api/spaces/space', {
    method: 'POST',
    body: { id: spaceId, name: spaceId },
  });
  ok(`created space "${spaceId}"`);
}

async function main() {
  const args = parseArgs(process.argv);
  const auth = { username: args.user, password: args.pass };
  const rootRequest = createApi(args.baseUrl, auth);

  const isDefault = !args.space || args.space === 'default';
  if (!isDefault) {
    await ensureSpace(rootRequest, args.space);
  }
  // Scope every synthetics call to the target space by pointing the API base at
  // it; the space prefix flows into all lib helpers automatically.
  const request = isDefault ? rootRequest : createApi(`${args.baseUrl}/s/${args.space}`, auth);

  info(`Seeding ${args.count} local monitor(s) on ${args.baseUrl} (space=${args.space})`);

  await ensureEnabled(request);
  const location = await ensurePrivateLocation(request, NAME_PREFIX);

  const existing = await listMonitors(request, NAME_PREFIX);
  const existingNames = new Set(existing.map((m) => m.name));

  let created = 0;
  for (let i = 1; i <= args.count; i++) {
    const name = `${NAME_PREFIX}-${i}`;
    if (existingNames.has(name)) {
      ok(`monitor "${name}" already exists — skipping`);
      continue;
    }
    await createUiMonitor(request, {
      name,
      url: `https://example.com/${i}`,
      locationId: location.id,
    });
    created++;
  }

  ok(`Done. ${created} created, ${args.count - created} already present.`);
}

main().catch((e) => {
  err(e.stack || e.message || String(e));
  process.exit(1);
});
