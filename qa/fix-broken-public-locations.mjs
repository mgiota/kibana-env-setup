#!/usr/bin/env node
// ============================================================
//  fix-broken-public-locations.mjs
//
//  Implementation for migrating monitors off broken Elastic-managed
//  public Synthetics locations. Primary entry point:
//
//    run-data synthetics fix public-locations [--dry-run] [--reset]
//
//  Can also be invoked directly (same flags). See recipes/fix-broken-public-locations.md.
// ============================================================

import { fileURLToPath } from 'node:url';
import { info, ok, warn, err } from './lib/kibana.mjs';
import { createApi, PUBLIC_API_HEADERS } from './lib/synthetics.mjs';
import {
  DEFAULT_MANIFEST_URL,
  fetchManifestLocations,
  parseServiceCredsFromYaml,
  pickFallbackLocation,
  planMonitorMigrations,
  probeAllLocations,
} from './lib/public_locations.mjs';

function defaultArgs() {
  return {
    baseUrl: process.env.QA_BASE_URL || 'http://localhost:5602',
    user: process.env.QA_ADMIN_USERNAME || process.env.QA_KIBANA_USERNAME || 'elastic',
    pass: process.env.QA_ADMIN_PASSWORD || process.env.QA_KIBANA_PASSWORD || 'changeme',
    serviceUser: process.env.SYNTHETICS_SERVICE_USERNAME,
    servicePass: process.env.SYNTHETICS_SERVICE_PASSWORD,
    remoteConfig: process.env.KIBANA_REMOTE_ES_CONFIG,
    manifestUrl: process.env.SYNTHETICS_MANIFEST_URL || DEFAULT_MANIFEST_URL,
    fallback: process.env.SYNTHETICS_FALLBACK_LOCATION,
    dryRun: false,
    reset: false,
  };
}

export function parseFixArgs(argv, startIndex = 2) {
  const a = defaultArgs();
  for (let i = startIndex; i < argv.length; i++) {
    const t = argv[i];
    if (t === '--base-url') a.baseUrl = argv[++i];
    else if (t === '--user') a.user = argv[++i];
    else if (t === '--pass') a.pass = argv[++i];
    else if (t === '--service-user') a.serviceUser = argv[++i];
    else if (t === '--service-pass') a.servicePass = argv[++i];
    else if (t === '--remote-config') a.remoteConfig = argv[++i];
    else if (t === '--manifest-url') a.manifestUrl = argv[++i];
    else if (t === '--fallback') a.fallback = argv[++i];
    else if (t === '--dry-run') a.dryRun = true;
    else if (t === '--reset') a.reset = true;
    else if (t === '--help' || t === '-h') {
      printHelp();
      process.exit(0);
    } else {
      throw new Error(`Unknown arg: ${t}`);
    }
  }
  return a;
}

function printHelp() {
  console.log(`Primary: run-data synthetics fix public-locations [--dry-run] [--reset]

Direct:  node fix-broken-public-locations.mjs [options]

  --base-url URL          Kibana instance
  --user / --pass         Kibana admin credentials
  --service-user / --service-pass   Synthetics service basic-auth (for probing)
  --remote-config PATH    Parse service creds from YAML (default ~/.kibana-remote-es.yml)
  --manifest-url URL      Public locations manifest
  --fallback ID           Healthy location to migrate onto (default: first healthy QA)
  --dry-run               Print migration plan only
  --reset                 After migrate, bulk-reset affected public monitors`);
}

function resolveServiceAuth(args) {
  if (args.serviceUser && args.servicePass) {
    return { username: args.serviceUser, password: args.servicePass, source: 'cli' };
  }
  const fromYaml = parseServiceCredsFromYaml(args.remoteConfig);
  if (fromYaml) return fromYaml;
  throw new Error(
    'Synthetics service credentials required for probing. Set SYNTHETICS_SERVICE_USERNAME/PASSWORD, pass --service-user/--service-pass, or ensure ~/.kibana-remote-es.yml has xpack.uptime.service credentials.'
  );
}

async function fetchKibanaServiceLocations(request) {
  const data = await request('/internal/uptime/service/locations', {
    extraHeaders: { 'x-elastic-internal-origin': 'kibana' },
  });
  const locations = data?.locations ?? [];
  return new Map(locations.map((l) => [l.id, l]));
}

async function fetchMonitors(request) {
  const data = await request('/api/synthetics/monitors?perPage=1000', {
    extraHeaders: PUBLIC_API_HEADERS,
  });
  return data?.monitors ?? [];
}

/** @returns {Promise<{ updated: number, skipped: number }>} */
export async function runFixBrokenPublicLocations(rawArgs = process.argv) {
  const args = Array.isArray(rawArgs) ? parseFixArgs(rawArgs) : { ...defaultArgs(), ...rawArgs };
  const serviceAuth = resolveServiceAuth(args);
  const auth = { username: args.user, password: args.pass };
  const request = createApi(args.baseUrl, auth);

  info(`Probing public locations from ${args.manifestUrl}`);
  info(`Service auth source: ${serviceAuth.source}`);

  const manifestLocations = await fetchManifestLocations(args.manifestUrl);
  const probed = await probeAllLocations(manifestLocations, serviceAuth);

  for (const loc of probed) {
    if (loc.healthy) {
      ok(`${loc.id} (${loc.url}): healthy`);
    } else {
      warn(`${loc.id} (${loc.url}): BROKEN — ${loc.issues.join(', ')}`);
    }
  }

  const broken = probed.filter((l) => !l.healthy);
  if (broken.length === 0) {
    ok('All manifest public locations are healthy — nothing to migrate.');
    return { updated: 0, skipped: 0 };
  }

  const fallback = pickFallbackLocation(probed, args.fallback);
  ok(`Fallback location: ${fallback.id} (${fallback.url})`);

  const [monitors, kibanaLocations] = await Promise.all([
    fetchMonitors(request),
    fetchKibanaServiceLocations(request),
  ]);

  const plans = planMonitorMigrations({
    monitors,
    brokenLocationIds: broken.map((l) => l.id),
    fallbackLocation: fallback,
    serviceLocationsById: kibanaLocations,
  });

  const actionable = plans.filter((p) => !p.skipped);
  const skippedPlans = plans.filter((p) => p.skipped);

  if (actionable.length === 0) {
    ok('No monitors are assigned to broken public locations.');
    for (const s of skippedPlans) warn(`Skipped ${s.monitor.name}: ${s.reason}`);
    return { updated: 0, skipped: skippedPlans.length };
  }

  info(`Migration plan (${actionable.length} monitor(s)):`);
  for (const p of actionable) {
    console.log(`  ${p.monitor.name}: ${p.before.join(',')} -> ${p.after.join(',')}`);
  }
  for (const s of skippedPlans) {
    warn(`Skipped ${s.monitor.name}: ${s.reason}`);
  }

  if (args.dryRun) {
    info('Dry run — no changes applied.');
    return { updated: 0, skipped: skippedPlans.length, planned: actionable.length };
  }

  const updates = actionable.map((p) => ({
    id: p.monitor.config_id ?? p.monitor.id,
    attributes: p.attributes,
  }));

  const bulk = await request('/api/synthetics/monitors/_bulk_update', {
    method: 'PUT',
    extraHeaders: PUBLIC_API_HEADERS,
    body: { updates },
  });

  const failed = (bulk.result ?? []).filter((r) => !r.updated);
  if (failed.length) {
    throw new Error(`Bulk update had failures: ${JSON.stringify(failed)}`);
  }
  ok(`Updated ${updates.length} monitor(s)`);

  if (bulk.errors?.length) {
    warn(`Sync warnings during update: ${JSON.stringify(bulk.errors)}`);
  }

  if (args.reset) {
    const publicIds = actionable
      .map((p) => p.monitor.config_id ?? p.monitor.id)
      .filter(Boolean);
    if (publicIds.length) {
      info(`Bulk-resetting ${publicIds.length} monitor(s) to re-sync...`);
      const reset = await request('/internal/synthetics/monitors/_bulk_reset', {
        method: 'POST',
        extraHeaders: { 'x-elastic-internal-origin': 'kibana' },
        body: { ids: publicIds },
      });
      if (reset.errors?.length) {
        warn(`Reset sync errors: ${JSON.stringify(reset.errors)}`);
      } else {
        ok('Bulk reset completed with no sync errors');
      }
    }
  }

  ok('Done. Avoid assigning new monitors to broken locations until infra is fixed.');
  return { updated: updates.length, skipped: skippedPlans.length };
}

async function main() {
  try {
    await runFixBrokenPublicLocations(process.argv);
  } catch (e) {
    err(e.message);
    process.exit(1);
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main();
}
